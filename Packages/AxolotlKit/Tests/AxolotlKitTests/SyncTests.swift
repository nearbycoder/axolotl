import XCTest
@testable import AxolotlKit

@MainActor
final class SyncTests: XCTestCase {
    var dirs: [URL] = []

    func makeReplica(_ name: String) throws -> Replica {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-tests-\(UUID().uuidString)")
        dirs.append(dir)
        return try Replica(directory: dir, deviceId: name)
    }

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    /// One LAN-style exchange in both directions.
    func exchange(_ a: Replica, _ b: Replica) {
        let toB = a.rows(after: b.vector)
        a.markSent(toB)
        b.apply(toB, markDirty: true)
        let toA = b.rows(after: a.vector)
        b.markSent(toA)
        a.apply(toA, markDirty: true)
    }

    func settle(_ replicas: [Replica]) {
        for _ in 0..<6 {
            for i in replicas.indices { for j in replicas.indices where i < j { exchange(replicas[i], replicas[j]) } }
        }
    }

    func testMergeCombinesNonOverlappingEdits() {
        let base = "The quick brown fox jumps over the lazy dog."
        let ours = "The quick red fox jumps over the lazy dog."
        let theirs = "The quick brown fox jumps over the sleepy dog."
        XCTAssertEqual(TextMerge.merge(base: base, ours: ours, theirs: theirs, oursIsPrimary: true),
                       "The quick red fox jumps over the sleepy dog.")
    }

    func testMergeKeepsBothSidesOfConflict() {
        let merged = TextMerge.merge(base: "a cat", ours: "a dog", theirs: "a bird", oursIsPrimary: false)
        XCTAssertEqual(merged, "a bird dog")
        XCTAssertEqual(TextMerge.merge(base: "a cat", ours: "a bird", theirs: "a dog", oursIsPrimary: true), merged)
    }

    func testMergeInsertionsAtEnd() {
        let merged = TextMerge.merge(base: "List\n- one\n", ours: "List\n- one\n- two\n", theirs: "List\n- one\n- three\n", oursIsPrimary: true)
        XCTAssertTrue(merged.contains("- two") && merged.contains("- three"), merged)
    }

    func testFieldsAndBodiesReplicate() throws {
        let a = try makeReplica("aaaa"), b = try makeReplica("bbbb")
        let id = a.createNote(body: "# Hello\nWorld #tag/sub")
        a.setPinned(id, true)
        exchange(a, b)
        XCTAssertEqual(b.notes[id]?.body, "# Hello\nWorld #tag/sub")
        XCTAssertEqual(b.notes[id]?.pinned, true)
        XCTAssertEqual(b.notes[id]?.meta.title, "Hello")
        XCTAssertEqual(b.notes[id]?.meta.tags, ["tag/sub"])

        b.setPinned(id, false)
        a.setArchived(id, true)
        exchange(a, b)
        XCTAssertEqual(a.notes[id]?.pinned, false)
        XCTAssertEqual(b.notes[id]?.archived, true)
    }

    func testConcurrentBodyEditsMerge() throws {
        let a = try makeReplica("aaaa"), b = try makeReplica("bbbb")
        let id = a.createNote(body: "Groceries\n- milk\n- eggs\n- bread\n")
        exchange(a, b)
        a.updateBody(id, "Groceries\n- oat milk\n- eggs\n- bread\n")
        b.updateBody(id, "Groceries\n- milk\n- eggs\n- sourdough bread\n- apples\n")
        exchange(a, b)
        exchange(a, b)
        XCTAssertEqual(a.notes[id]?.body, b.notes[id]?.body)
        XCTAssertEqual(a.notes[id]?.body, "Groceries\n- oat milk\n- eggs\n- sourdough bread\n- apples\n")
        XCTAssertTrue(a.liveNotes.count == 1, "no conflict copies expected")
    }

    func testFastForwardAfterManyRevisions() throws {
        let a = try makeReplica("aaaa"), b = try makeReplica("bbbb")
        let id = a.createNote(body: "start")
        exchange(a, b)
        var text = "start"
        for i in 0..<300 {
            text += " \(i)"
            a.updateBody(id, text)
            a.markSent(a.rows(after: [:])) // simulate each revision being pushed
        }
        exchange(a, b)
        XCTAssertEqual(b.notes[id]?.body, text)
        XCTAssertEqual(b.liveNotes.count, 1)
    }

    func testRandomizedConvergence() throws {
        var rng = SystemRandomNumberGenerator()
        for round in 0..<8 {
            let rs = try (0..<3).map { try makeReplica("r\(round)\($0)") }
            let id = rs[0].createNote(body: "alpha beta gamma delta epsilon zeta eta theta")
            settle(rs)
            var markers: [String] = []
            for step in 0..<60 {
                let r = rs[Int.random(in: 0..<3, using: &rng)]
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<7:
                    var words = r.notes[id]!.body.split(separator: " ").map(String.init)
                    let marker = "m\(round)x\(step)"
                    markers.append(marker)
                    words.insert(marker, at: Int.random(in: 0...words.count, using: &rng))
                    r.updateBody(id, words.joined(separator: " "))
                case 7: r.setPinned(id, Bool.random(using: &rng))
                case 8: r.setTagPinned("work", Bool.random(using: &rng))
                default:
                    let i = Int.random(in: 0..<3, using: &rng), j = Int.random(in: 0..<3, using: &rng)
                    if i != j { exchange(rs[i], rs[j]) }
                }
            }
            settle(rs)
            let bodies = Set(rs.map { $0.notes[id]!.body })
            XCTAssertEqual(bodies.count, 1, "bodies diverged: \(bodies)")
            XCTAssertEqual(Set(rs.map { $0.notes[id]!.pinned }).count, 1)
            XCTAssertEqual(Set(rs.map { $0.tagMeta["work"]?.pinned }).count, 1)
            let body = rs[0].notes[id]!.body
            for m in markers { XCTAssertTrue(body.contains(m), "lost \(m) in \(body)") }
            XCTAssertEqual(rs[0].liveNotes.count, 1, "unexpected conflict copies")
        }
    }

    func testServerStyleRelay() throws {
        // A minimal in-memory model of the sync server: latest row per key, monotonically sequenced.
        var store: [String: (seq: Int, hlc: String, row: SyncRow)] = [:]
        var seq = 0
        func push(_ r: Replica) {
            while true {
                let rows = r.takeDirtyRows(limit: 50)
                if rows.isEmpty { break }
                for p in rows {
                    let key = "\(p.row.entity)|\(p.row.id)|\(p.row.field)"
                    if let cur = store[key], cur.hlc >= p.row.hlc { continue }
                    seq += 1
                    store[key] = (seq, p.row.hlc, p.row)
                }
                r.markClean(rows)
            }
        }
        var cursors: [String: Int] = [:]
        func pull(_ r: Replica) {
            let since = cursors[r.deviceId] ?? 0
            let rows = store.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
            r.apply(rows.map(\.row), markDirty: false)
            cursors[r.deviceId] = seq
        }
        let a = try makeReplica("aaaa"), b = try makeReplica("bbbb")
        let id = a.createNote(body: "one two three")
        push(a); pull(b)
        XCTAssertEqual(b.notes[id]?.body, "one two three")
        a.updateBody(id, "zero one two three")
        b.updateBody(id, "one two three four")
        push(a); push(b); pull(a); pull(b); push(a); push(b); pull(a); pull(b)
        XCTAssertEqual(a.notes[id]?.body, "zero one two three four")
        XCTAssertEqual(b.notes[id]?.body, "zero one two three four")
    }

    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-persist-\(UUID().uuidString)")
        dirs.append(dir)
        var id = ""
        do {
            let r = try Replica(directory: dir)
            id = r.createNote(body: "Persist me #keep")
            r.setPinned(id, true)
            _ = try r.addAttachment(data: Data("hello".utf8), name: "a.txt", mime: "text/plain", noteId: id)
        }
        let r2 = try Replica(directory: dir)
        XCTAssertEqual(r2.notes[id]?.body, "Persist me #keep")
        XCTAssertEqual(r2.notes[id]?.pinned, true)
        XCTAssertEqual(r2.attachments.values.first?.name, "a.txt")
        XCTAssertTrue(r2.hasBlob(r2.attachments.values.first!.hash))
    }

    func testEncryptionRoundTrip() throws {
        let salt = NoteCrypto.makeSalt()
        let key = NoteCrypto.deriveKey(password: "hunter2", salt: salt)
        let check = NoteCrypto.makeCheck(key: key)
        XCTAssertTrue(NoteCrypto.verify(key: key, check: check))
        XCTAssertFalse(NoteCrypto.verify(key: NoteCrypto.deriveKey(password: "nope", salt: salt), check: check))
        let enc = try NoteCrypto.encrypt("secret note", key: key)
        XCTAssertTrue(NoteCrypto.isEncrypted(enc))
        XCTAssertEqual(try NoteCrypto.decrypt(enc, key: key), "secret note")
    }

    func testSyncCode() throws {
        let code = VaultKeys.generateCode()
        let keys = try XCTUnwrap(VaultKeys(syncCode: code))
        let again = try XCTUnwrap(VaultKeys(syncCode: code.lowercased().replacingOccurrences(of: "-", with: " ")))
        XCTAssertEqual(keys.vaultId, again.vaultId)
        XCTAssertEqual(keys.code, code)
        let sealed = try keys.seal(Data("hi".utf8))
        XCTAssertEqual(try again.open(sealed), Data("hi".utf8))
        XCTAssertNil(VaultKeys(syncCode: "nonsense"))
    }
}
