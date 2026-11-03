import Foundation

/// What changed after a mutation, so observers can refresh only what they need.
public struct ReplicaChange: Sendable {
    public var notes = Set<String>()
    public var tags = Set<String>()
    public var attachments = Set<String>()
    public var config = Set<String>()
    /// New rows were written locally (edits or merge results) that peers do not have yet.
    public var hasLocalRows = false
    /// The change came from another device.
    public var isRemote = false
    public var isEmpty: Bool { notes.isEmpty && tags.isEmpty && attachments.isEmpty && config.isEmpty }
}

public struct Revision: Identifiable, Hashable, Sendable {
    public var id: String
    public var date: Date
    public var text: String
}

/// A local-first replica of the note database.
///
/// State is a map of `(entity, id, field) -> value` where every value is stamped with a hybrid
/// logical clock. Ordinary fields resolve concurrent writes last-writer-wins. Note bodies carry
/// their revision lineage so concurrent edits are three-way merged instead of overwritten.
/// Only the latest row for each field is kept, which doubles as the sync log: a peer that sends
/// its version vector receives every row it has not seen.
@MainActor
public final class Replica {
    public static let maxAncestors = 160
    static let amendWindow: TimeInterval = 600

    public let deviceId: String
    public let clock: HybridClock
    public let blobDirectory: URL
    let db: SQLiteDB

    public private(set) var notes: [String: Note] = [:]
    public private(set) var tagMeta: [String: TagMeta] = [:]
    public private(set) var attachments: [String: Attachment] = [:]
    private var config: [String: [String: String]] = [:]

    struct Key: Hashable { var entity: String; var id: String; var field: String }
    struct Info { var hlc: String; var origin: String; var sent: Bool }
    private var info: [Key: Info] = [:]
    private var seen: [String: String] = [:]
    private var seq: Int64 = 0
    private var pending = ReplicaChange()

    public var onChange: ((ReplicaChange) -> Void)?
    /// Called when a new attachment blob is stored (locally or from sync).
    public var onBlob: ((String) -> Void)?

    public init(directory: URL, deviceId: String? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        blobDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        db = try SQLiteDB(path: directory.appendingPathComponent("axolotl.sqlite").path)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS records(entity TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, value TEXT NOT NULL,
          hlc TEXT NOT NULL, origin TEXT NOT NULL, seq INTEGER NOT NULL, dirty INTEGER NOT NULL DEFAULT 1,
          sent INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(entity, id, field));
        CREATE INDEX IF NOT EXISTS records_dirty ON records(seq) WHERE dirty = 1;
        CREATE INDEX IF NOT EXISTS records_origin_hlc ON records(origin, hlc);
        CREATE TABLE IF NOT EXISTS seen(origin TEXT PRIMARY KEY, hlc TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS known_revs(note TEXT NOT NULL, rev TEXT NOT NULL, PRIMARY KEY(note, rev));
        CREATE TABLE IF NOT EXISTS revisions(note TEXT NOT NULL, rev TEXT NOT NULL, text TEXT NOT NULL, date REAL NOT NULL, PRIMARY KEY(note, rev));
        CREATE TABLE IF NOT EXISTS uploaded_blobs(hash TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)

        let storedDevice = try db.query("SELECT value FROM kv WHERE key='device'").first?.first?.string
        if let storedDevice {
            self.deviceId = storedDevice
        } else {
            let id = deviceId ?? Self.makeDeviceId()
            try db.run("INSERT INTO kv(key, value) VALUES('device', ?)", [.text(id)])
            self.deviceId = id
        }

        for row in try db.query("SELECT origin, hlc FROM seen") {
            if let o = row[0].string, let h = row[1].string { seen[o] = h }
        }
        seq = try db.query("SELECT MAX(seq) FROM records").first?.first?.int ?? 0
        clock = HybridClock(node: self.deviceId, last: seen.values.max())

        for row in try db.query("SELECT entity, id, field, value, hlc, origin, sent FROM records") {
            let r = SyncRow(entity: row[0].string!, id: row[1].string!, field: row[2].string!, value: row[3].string!,
                            hlc: row[4].string!, origin: row[5].string!)
            info[Key(entity: r.entity, id: r.id, field: r.field)] = Info(hlc: r.hlc, origin: r.origin, sent: row[6].int == 1)
            materialize(r, recomputeMeta: false)
        }
        parseAllMetadata()
        pending = ReplicaChange()
    }

    /// Parses every note's metadata in parallel; the parser is pure and its regexes are thread-safe.
    private func parseAllMetadata() {
        let ids = Array(notes.keys)
        let bodies = ids.map { notes[$0]!.body }
        var metas = [NoteMeta](repeating: NoteMeta(), count: ids.count)
        metas.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            DispatchQueue.concurrentPerform(iterations: ids.count) { i in
                let body = bodies[i]
                out[i] = NoteCrypto.isEncrypted(body) ? NoteMeta() : NoteParser.parse(body)
            }
        }
        for (i, id) in ids.enumerated() { notes[id]?.meta = metas[i] }
    }

    static func makeDeviceId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12).description
    }

    // MARK: - Reading

    public func config(_ id: String, _ field: String) -> String? {
        config[id]?[field].flatMap { JSON.decode(String.self, $0) }
    }

    public var liveNotes: [Note] { notes.values.filter { !$0.deleted } }

    public func revisions(for noteId: String) -> [Revision] {
        let rows = (try? db.query("SELECT rev, date, text FROM revisions WHERE note=? ORDER BY rev DESC", [.text(noteId)])) ?? []
        return rows.compactMap { r in
            guard let rev = r[0].string, let date = r[1].double, let text = r[2].string else { return nil }
            return Revision(id: rev, date: Date(timeIntervalSince1970: date), text: text)
        }
    }

    // MARK: - Local mutations

    @discardableResult
    public func createNote(body: String = "", id: String = UUID().uuidString, created: Date = Date(), conflictOf: String? = nil) -> String {
        transact {
            let now = Self.secs(created)
            write(Entity.note, id, "created", now)
            write(Entity.note, id, "modified", now)
            if let conflictOf { write(Entity.note, id, "conflictOf", JSON.encode(conflictOf)) }
            let row = write(Entity.note, id, "body", JSON.encode(BodyValue(t: body, a: [])))
            saveRevision(id, row.hlc, body)
        }
        return id
    }

    public func updateBody(_ id: String, _ text: String, date: Date = Date()) {
        guard let note = notes[id], note.body != text else { return }
        transact {
            let key = Key(entity: Entity.note, id: id, field: "body")
            if let cur = info[key], cur.origin == deviceId, !cur.sent,
               let revDate = HLC(cur.hlc)?.date, date.timeIntervalSince(revDate) < Self.amendWindow {
                // Nobody has seen the current revision yet: amend it in place instead of growing the lineage.
                let value = JSON.encode(BodyValue(t: text, a: note.ancestors))
                seq += 1
                try? db.run("UPDATE records SET value=?, seq=?, dirty=1 WHERE entity=? AND id=? AND field='body'",
                            [.text(value), .int(seq), .text(Entity.note), .text(id)])
                try? db.run("UPDATE revisions SET text=? WHERE note=? AND rev=?", [.text(text), .text(id), .text(cur.hlc)])
                if NoteCrypto.isEncrypted(text) { purgePlaintextRevisions(id) }
                materialize(SyncRow(entity: Entity.note, id: id, field: "body", value: value, hlc: cur.hlc, origin: deviceId))
                pending.hasLocalRows = true
            } else {
                let lineage = Array(([note.bodyRev] + note.ancestors).filter { !$0.isEmpty }.prefix(Self.maxAncestors))
                let row = write(Entity.note, id, "body", JSON.encode(BodyValue(t: text, a: lineage)))
                saveRevision(id, row.hlc, text)
            }
            write(Entity.note, id, "modified", Self.secs(date))
        }
    }

    public func setPinned(_ id: String, _ value: Bool) { transact { write(Entity.note, id, "pinned", Self.bool(value)) } }
    public func setArchived(_ id: String, _ value: Bool) { transact { write(Entity.note, id, "archived", Self.bool(value)) } }
    public func setTrashed(_ id: String, _ value: Bool) {
        transact { write(Entity.note, id, "trashed", value ? Self.secs(Date()) : "null") }
    }
    public func setLockedTitle(_ id: String, _ title: String?) { transact { write(Entity.note, id, "lockedTitle", JSON.encode(title)) } }
    public func setCreated(_ id: String, _ date: Date) { transact { write(Entity.note, id, "created", Self.secs(date)) } }

    /// Permanently deletes a note: its body is erased, history dropped and a tombstone kept for sync.
    public func deleteForever(_ id: String) {
        guard let note = notes[id] else { return }
        transact {
            let lineage = Array(([note.bodyRev] + note.ancestors).filter { !$0.isEmpty }.prefix(Self.maxAncestors))
            write(Entity.note, id, "body", JSON.encode(BodyValue(t: "", a: lineage)))
            write(Entity.note, id, "deleted", Self.bool(true))
            try? db.run("DELETE FROM revisions WHERE note=?", [.text(id)])
            for a in attachments.values where a.noteId == id && !a.deleted {
                write(Entity.attachment, a.id, "deleted", Self.bool(true))
            }
        }
    }

    public func setTagIcon(_ path: String, _ icon: String?) { transact { write(Entity.tag, path.lowercased(), "icon", JSON.encode(icon)) } }
    public func setTagPinned(_ path: String, _ pinned: Bool) { transact { write(Entity.tag, path.lowercased(), "pinned", Self.bool(pinned)) } }

    public func setConfig(_ id: String, _ field: String, _ value: String?) {
        transact { write(Entity.config, id, field, JSON.encode(value)) }
    }

    @discardableResult
    public func addAttachment(data: Data, name: String, mime: String, noteId: String, id: String = UUID().uuidString) throws -> Attachment {
        let hash = try putBlob(data)
        transact {
            write(Entity.attachment, id, "note", JSON.encode(noteId))
            write(Entity.attachment, id, "name", JSON.encode(name))
            write(Entity.attachment, id, "mime", JSON.encode(mime))
            write(Entity.attachment, id, "size", String(data.count))
            write(Entity.attachment, id, "hash", JSON.encode(hash))
        }
        return attachments[id]!
    }

    public func setAttachmentOCR(_ id: String, _ text: String) { transact { write(Entity.attachment, id, "ocr", JSON.encode(text)) } }
    public func deleteAttachment(_ id: String) { transact { write(Entity.attachment, id, "deleted", Self.bool(true)) } }

    // MARK: - Blobs

    public static func isValidBlobHash(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy(\.isHexDigit) }
    public func blobURL(_ hash: String) -> URL { blobDirectory.appendingPathComponent(Self.isValidBlobHash(hash) ? hash : "invalid") }
    public func hasBlob(_ hash: String) -> Bool { Self.isValidBlobHash(hash) && FileManager.default.fileExists(atPath: blobURL(hash).path) }
    public func blob(_ hash: String) -> Data? { Self.isValidBlobHash(hash) ? try? Data(contentsOf: blobURL(hash)) : nil }

    @discardableResult
    public func putBlob(_ data: Data, expectedHash: String? = nil) throws -> String {
        let hash = data.sha256
        if let expectedHash, expectedHash != hash { throw CocoaError(.fileReadCorruptFile) }
        let url = blobURL(hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            onBlob?(hash)
        }
        return hash
    }

    /// Blob hashes referenced by live attachments but not stored locally.
    public var missingBlobs: [String] {
        Array(Set(attachments.values.filter { !$0.deleted && !$0.hash.isEmpty && !hasBlob($0.hash) }.map(\.hash)))
    }

    public var blobsToUpload: [String] {
        let uploaded = Set(((try? db.query("SELECT hash FROM uploaded_blobs")) ?? []).compactMap { $0[0].string })
        return Array(Set(attachments.values.filter { !$0.deleted && !$0.hash.isEmpty && hasBlob($0.hash) && !uploaded.contains($0.hash) }.map(\.hash)))
    }

    public func markBlobUploaded(_ hash: String) {
        try? db.run("INSERT OR IGNORE INTO uploaded_blobs(hash) VALUES(?)", [.text(hash)])
    }

    // MARK: - Sync

    public var vector: [String: String] { seen }

    public func kv(_ key: String) -> String? { try? db.query("SELECT value FROM kv WHERE key=?", [.text(key)]).first?.first?.string }
    public func setKV(_ key: String, _ value: String?) {
        if let value {
            try? db.run("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
        } else {
            try? db.run("DELETE FROM kv WHERE key=?", [.text(key)])
        }
    }

    /// Every row the holder of `vector` has not seen, oldest first.
    ///
    /// One indexed query per origin, so a caught-up peer costs a handful of empty lookups rather
    /// than a scan of the whole table on every broadcast.
    public func rows(after vector: [String: String]) -> [SyncRow] {
        var out: [SyncRow] = []
        func decode(_ r: [SQLValue]) -> SyncRow {
            SyncRow(entity: r[0].string!, id: r[1].string!, field: r[2].string!, value: r[3].string!, hlc: r[4].string!, origin: r[5].string!)
        }
        // `seen` holds every origin that has rows here.
        for origin in seen.keys {
            let rows: [[SQLValue]]
            if let have = vector[origin] {
                rows = (try? db.query("SELECT entity, id, field, value, hlc, origin FROM records WHERE origin=? AND hlc>?", [.text(origin), .text(have)])) ?? []
            } else {
                rows = (try? db.query("SELECT entity, id, field, value, hlc, origin FROM records WHERE origin=?", [.text(origin)])) ?? []
            }
            out.append(contentsOf: rows.map(decode))
        }
        return out.sorted { $0.hlc < $1.hlc }
    }

    /// Deletes blob files that no live attachment references and forgets their upload state.
    @discardableResult
    public func collectGarbageBlobs() -> Int {
        let referenced = Set(attachments.values.filter { !$0.deleted && !$0.hash.isEmpty }.map(\.hash))
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: blobDirectory.path) else { return 0 }
        var removed = 0
        for name in files where name.count == 64 && !referenced.contains(name) {
            guard (try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(name))) != nil else { continue }
            try? db.run("DELETE FROM uploaded_blobs WHERE hash=?", [.text(name)])
            removed += 1
        }
        return removed
    }

    /// Records that `rows` left this device, which freezes local revisions against amendment.
    public func markSent(_ rows: [SyncRow]) {
        try? db.transaction {
            for row in rows where row.origin == deviceId {
                let key = Key(entity: row.entity, id: row.id, field: row.field)
                guard var cur = info[key], cur.hlc == row.hlc, !cur.sent else { continue }
                cur.sent = true
                info[key] = cur
                try db.run("UPDATE records SET sent=1 WHERE entity=? AND id=? AND field=? AND hlc=?",
                           [.text(row.entity), .text(row.id), .text(row.field), .text(row.hlc)])
            }
        }
    }

    public struct PendingRow { public var row: SyncRow; public var seq: Int64 }

    /// Rows the sync server has not acknowledged yet, oldest first. Marks them sent.
    public func takeDirtyRows(limit: Int = 400) -> [PendingRow] {
        let all = (try? db.query("SELECT entity, id, field, value, hlc, origin, seq FROM records WHERE dirty=1 ORDER BY seq LIMIT ?", [.int(Int64(limit))])) ?? []
        let result = all.map { r in
            PendingRow(row: SyncRow(entity: r[0].string!, id: r[1].string!, field: r[2].string!, value: r[3].string!, hlc: r[4].string!, origin: r[5].string!),
                       seq: r[6].int!)
        }
        markSent(result.map(\.row))
        return result
    }

    public func markClean(_ rows: [PendingRow]) {
        try? db.transaction {
            for p in rows {
                try db.run("UPDATE records SET dirty=0 WHERE entity=? AND id=? AND field=? AND seq=?",
                           [.text(p.row.entity), .text(p.row.id), .text(p.row.field), .int(p.seq)])
            }
        }
    }

    public var dirtyCount: Int { Int((try? db.query("SELECT COUNT(*) FROM records WHERE dirty=1").first?.first?.int) ?? 0) }

    /// Marks every row dirty, e.g. after connecting to a new sync server.
    public func markAllDirty() { try? db.run("UPDATE records SET dirty=1") }

    /// Applies rows from another device. `markDirty` should be true when the rows did not come from
    /// the sync server, so they are forwarded to it.
    public func apply(_ rows: [SyncRow], markDirty: Bool) {
        guard !rows.isEmpty else { return }
        transact(remote: true) {
            for row in rows.sorted(by: { $0.hlc < $1.hlc }) {
                clock.observe(row.hlc)
                bumpSeen(row.origin, row.hlc)
                if row.entity == Entity.note && row.field == "body" {
                    applyBody(row, markDirty: markDirty)
                    continue
                }
                if let cur = info[Key(entity: row.entity, id: row.id, field: row.field)], cur.hlc >= row.hlc { continue }
                store(row, dirty: markDirty)
                materialize(row)
            }
        }
    }

    private func applyBody(_ row: SyncRow, markDirty: Bool) {
        guard let remote = JSON.decode(BodyValue.self, row.value) else { return }
        let id = row.id
        guard let local = notes[id], !local.bodyRev.isEmpty else {
            adopt(row, remote, markDirty: markDirty)
            return
        }
        if row.hlc == local.bodyRev || isKnown(id, row.hlc) { return }
        if remote.a.contains(local.bodyRev) {
            adopt(row, remote, markDirty: markDirty)
            return
        }

        // Concurrent edits.
        let remoteWins = row.hlc > local.bodyRev
        saveRevision(id, row.hlc, remote.t)
        markKnown(id, row.hlc)
        if local.body == remote.t {
            if remoteWins { adopt(row, remote, markDirty: markDirty) }
            return
        }

        var base: String?
        if !NoteCrypto.isEncrypted(local.body) && !NoteCrypto.isEncrypted(remote.t) {
            let remoteLineage = Set(remote.a)
            for rev in local.ancestors where remoteLineage.contains(rev) {
                if let text = revisionText(id, rev) { base = text; break }
            }
        }
        guard let base else {
            // The remote lineage is truncated and entirely newer than our revision, and we hold no
            // unsent local edits: we are a stale replica catching up, so fast-forward.
            let cur = info[Key(entity: Entity.note, id: id, field: "body")]
            let localClean = cur.map { $0.origin != deviceId || $0.sent } ?? true
            if localClean, remote.a.count >= Self.maxAncestors, let oldest = remote.a.last, oldest > local.bodyRev {
                adopt(row, remote, markDirty: markDirty)
                return
            }
            // No shared history to merge from: keep the newer revision and preserve the other as a copy.
            if remoteWins {
                createConflictCopy(of: local, text: local.body, rev: local.bodyRev)
                adopt(row, remote, markDirty: markDirty)
            } else {
                createConflictCopy(of: local, text: remote.t, rev: row.hlc)
            }
            return
        }

        let merged = TextMerge.merge(base: base, ours: local.body, theirs: remote.t, oursIsPrimary: !remoteWins)
        if merged == remote.t {
            adopt(row, remote, markDirty: markDirty)
        } else if merged != local.body {
            var lineage: [String] = []
            var seenRevs = Set<String>()
            let a = [local.bodyRev] + local.ancestors, b = [row.hlc] + remote.a
            for i in 0..<max(a.count, b.count) {
                for list in [a, b] where i < list.count && seenRevs.insert(list[i]).inserted { lineage.append(list[i]) }
            }
            let newRow = write(Entity.note, id, "body", JSON.encode(BodyValue(t: merged, a: Array(lineage.prefix(Self.maxAncestors)))))
            saveRevision(id, newRow.hlc, merged)
        }
    }

    private func adopt(_ row: SyncRow, _ value: BodyValue, markDirty: Bool) {
        store(row, dirty: markDirty)
        materialize(row)
        saveRevision(row.id, row.hlc, value.t)
    }

    private func createConflictCopy(of note: Note, text: String, rev: String) {
        guard !text.isEmpty else { return }
        let id = "conflict-" + Data("\(note.id)|\(rev)".utf8).sha256.prefix(24)
        guard notes[id] == nil else { return }
        write(Entity.note, id, "created", Self.secs(note.created))
        write(Entity.note, id, "modified", Self.secs(HLC(rev)?.date ?? Date()))
        write(Entity.note, id, "conflictOf", JSON.encode(note.id))
        if let t = note.lockedTitle { write(Entity.note, id, "lockedTitle", JSON.encode(t)) }
        let row = write(Entity.note, id, "body", JSON.encode(BodyValue(t: text, a: [])))
        saveRevision(id, row.hlc, text)
    }

    // MARK: - Storage internals

    private func transact(remote: Bool = false, _ body: () -> Void) {
        do {
            try db.transaction { body() }
        } catch {
            assertionFailure("Replica transaction failed: \(error)")
        }
        if remote { pending.isRemote = true }
        flush()
    }

    private func flush() {
        let change = pending
        pending = ReplicaChange()
        if !change.isEmpty || change.hasLocalRows { onChange?(change) }
    }

    @discardableResult
    private func write(_ entity: String, _ id: String, _ field: String, _ value: String) -> SyncRow {
        let row = SyncRow(entity: entity, id: id, field: field, value: value, hlc: clock.now(), origin: deviceId)
        store(row, dirty: true)
        bumpSeen(deviceId, row.hlc)
        materialize(row)
        pending.hasLocalRows = true
        return row
    }

    private func store(_ row: SyncRow, dirty: Bool) {
        seq += 1
        try? db.run("""
        INSERT INTO records(entity, id, field, value, hlc, origin, seq, dirty, sent) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(entity, id, field) DO UPDATE SET value=excluded.value, hlc=excluded.hlc, origin=excluded.origin,
          seq=excluded.seq, dirty=excluded.dirty, sent=0
        """, [.text(row.entity), .text(row.id), .text(row.field), .text(row.value), .text(row.hlc), .text(row.origin), .int(seq), .int(dirty ? 1 : 0)])
        info[Key(entity: row.entity, id: row.id, field: row.field)] = Info(hlc: row.hlc, origin: row.origin, sent: false)
    }

    private func bumpSeen(_ origin: String, _ hlc: String) {
        if let cur = seen[origin], cur >= hlc { return }
        seen[origin] = hlc
        try? db.run("INSERT INTO seen(origin, hlc) VALUES(?, ?) ON CONFLICT(origin) DO UPDATE SET hlc=excluded.hlc", [.text(origin), .text(hlc)])
    }

    private func isKnown(_ note: String, _ rev: String) -> Bool {
        ((try? db.query("SELECT 1 FROM known_revs WHERE note=? AND rev=?", [.text(note), .text(rev)])) ?? []).isEmpty == false
    }

    private func markKnown(_ note: String, _ rev: String) {
        try? db.run("INSERT OR IGNORE INTO known_revs(note, rev) VALUES(?, ?)", [.text(note), .text(rev)])
    }

    private func revisionText(_ note: String, _ rev: String) -> String? {
        try? db.query("SELECT text FROM revisions WHERE note=? AND rev=?", [.text(note), .text(rev)]).first?.first?.string
    }

    private var revisionWrites = 0

    private func saveRevision(_ note: String, _ rev: String, _ text: String) {
        markKnown(note, rev)
        let date = HLC(rev)?.date.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        try? db.run("INSERT OR IGNORE INTO revisions(note, rev, text, date) VALUES(?, ?, ?, ?)", [.text(note), .text(rev), .text(text), .double(date)])
        if NoteCrypto.isEncrypted(text) { purgePlaintextRevisions(note) }
        revisionWrites += 1
        if revisionWrites % 25 == 0 { pruneRevisions(note) }
    }

    /// Once a note is locked, its earlier plaintext history must not stay readable on disk
    /// (or on any other device that receives the encrypted body).
    private func purgePlaintextRevisions(_ note: String) {
        try? db.run("DELETE FROM revisions WHERE note=? AND substr(text, 1, ?) != ?",
                    [.text(note), .int(Int64(NoteCrypto.prefix.count)), .text(NoteCrypto.prefix)])
    }

    /// Keeps the most recent revisions (merge bases) plus one per hour for older history.
    func pruneRevisions(_ note: String) {
        let rows = (try? db.query("SELECT rev, date FROM revisions WHERE note=? ORDER BY rev DESC", [.text(note)])) ?? []
        guard rows.count > Self.maxAncestors + 20 else { return }
        var buckets = Set<Int>()
        for (i, r) in rows.enumerated() {
            guard let rev = r[0].string, let date = r[1].double else { continue }
            if i < Self.maxAncestors { continue }
            if buckets.insert(Int(date / 3600)).inserted { continue }
            try? db.run("DELETE FROM revisions WHERE note=? AND rev=?", [.text(note), .text(rev)])
        }
    }

    private func materialize(_ row: SyncRow, recomputeMeta: Bool = true) {
        let v = row.value
        switch row.entity {
        case Entity.note:
            var note = notes[row.id] ?? Note(id: row.id)
            switch row.field {
            case "body":
                if let b = JSON.decode(BodyValue.self, v) {
                    note.body = b.t
                    note.bodyRev = row.hlc
                    note.ancestors = b.a
                }
            case "created": note.created = Self.date(v) ?? note.created
            case "modified": note.modified = Self.date(v) ?? note.modified
            case "pinned": note.pinned = v == "true"
            case "archived": note.archived = v == "true"
            case "trashed": note.trashedAt = Self.date(v)
            case "lockedTitle": note.lockedTitle = JSON.decode(String.self, v)
            case "conflictOf": note.conflictOf = JSON.decode(String.self, v)
            case "deleted": note.deleted = v == "true"
            default: break
            }
            notes[row.id] = note
            if row.field == "body" && recomputeMeta { refreshMeta(row.id) }
            pending.notes.insert(row.id)
        case Entity.tag:
            var meta = tagMeta[row.id] ?? TagMeta(path: row.id)
            switch row.field {
            case "icon": meta.icon = JSON.decode(String.self, v)
            case "pinned": meta.pinned = v == "true"
            default: break
            }
            tagMeta[row.id] = meta
            pending.tags.insert(row.id)
        case Entity.attachment:
            var a = attachments[row.id] ?? Attachment(id: row.id)
            switch row.field {
            case "note": a.noteId = JSON.decode(String.self, v) ?? ""
            case "name": a.name = JSON.decode(String.self, v) ?? ""
            case "mime": a.mime = JSON.decode(String.self, v) ?? a.mime
            case "hash": a.hash = JSON.decode(String.self, v) ?? ""
            case "size": a.size = Int(v) ?? 0
            case "ocr": a.ocr = JSON.decode(String.self, v) ?? ""
            case "deleted": a.deleted = v == "true"
            default: break
            }
            attachments[row.id] = a
            pending.attachments.insert(row.id)
        case Entity.config:
            config[row.id, default: [:]][row.field] = v
            pending.config.insert(row.id)
        default:
            break
        }
    }

    private func refreshMeta(_ id: String) {
        guard var note = notes[id] else { return }
        note.meta = note.isEncrypted ? NoteMeta() : NoteParser.parse(note.body)
        notes[id] = note
    }

    static func secs(_ date: Date) -> String { String(date.timeIntervalSince1970) }
    static func bool(_ b: Bool) -> String { b ? "true" : "false" }
    static func date(_ v: String) -> Date? { Double(v).map { Date(timeIntervalSince1970: $0) } }
}
