import SwiftUI
import CryptoKit
import AxolotlKit
import Vision

enum SidebarItem: Hashable, Codable {
    case notes, todo, today, locked, untagged, archive, trash
    case tag(String)

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .todo: return "Todo"
        case .today: return "Today"
        case .locked: return "Locked"
        case .untagged: return "Untagged"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .tag(let path): return path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    var symbol: String {
        switch self {
        case .notes: return "note.text"
        case .todo: return "checklist"
        case .today: return "calendar"
        case .locked: return "lock"
        case .untagged: return "tag.slash"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .tag: return "number"
        }
    }
}

struct TagNode: Identifiable, Hashable {
    var path: String
    var name: String
    var count: Int
    var children: [TagNode]
    var id: String { path.lowercased() }
    var childNodes: [TagNode]? { children.isEmpty ? nil : children }
}

struct NavigationRequest: Equatable {
    var id = UUID()
    var sidebar: SidebarItem?
    var noteId: String?
    var search: String?
}

/// App-wide state shared by every window.
@MainActor
@Observable
final class AppModel {
    let replica: Replica
    let sync: SyncManager
    let settings = AppSettings()

    private(set) var notes: [String: Note] = [:]
    private(set) var attachments: [String: Attachment] = [:]
    private(set) var tagMeta: [String: TagMeta] = [:]
    private(set) var tagTree: [TagNode] = []
    private(set) var imagesVersion = 0
    private(set) var encryptionConfigured = false
    var navigationRequest: NavigationRequest?
    var errorMessage: String?

    // Locking
    var isAppLocked = false
    private(set) var encryptionKey: SymmetricKey?
    @ObservationIgnored private var decrypted: [String: String] = [:]
    @ObservationIgnored var backgroundedAt: Date?

    @ObservationIgnored private var imageCache = NSCache<NSString, PlatformImage>()

    static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Axolotl", isDirectory: true)
    }()

    init() {
        let replica: Replica
        do {
            replica = try Replica(directory: Self.dataDirectory)
        } catch {
            fatalError("Could not open the note database: \(error)")
        }
        self.replica = replica
        sync = SyncManager(replica: replica, deviceName: DeviceInfo.name)
        isAppLocked = settings.appLock
        reloadAll()
        replica.onChange = { [weak self] change in self?.replicaChanged(change) }
        replica.onBlob = { [weak self] _ in self?.imagesVersion += 1 }
        if replica.notes.isEmpty && replica.kv("seeded") == nil {
            seedWelcomeNotes()
            replica.setKV("seeded", "1")
        }
    }

    private func reloadAll() {
        notes = replica.notes
        attachments = replica.attachments
        tagMeta = replica.tagMeta
        encryptionConfigured = replica.config("encryption", "salt") != nil
        rebuildTags()
    }

    private func replicaChanged(_ change: ReplicaChange) {
        if !change.notes.isEmpty {
            notes = replica.notes
            for id in change.notes where notes[id]?.isEncrypted == true { decrypted.removeValue(forKey: id) }
            rebuildTags()
        }
        if !change.attachments.isEmpty {
            attachments = replica.attachments
            imagesVersion += 1
        }
        if !change.tags.isEmpty {
            tagMeta = replica.tagMeta
            rebuildTags()
        }
        if !change.config.isEmpty {
            encryptionConfigured = replica.config("encryption", "salt") != nil
        }
        sync.replicaChanged(change)
    }

    // MARK: Derived data

    var liveNotes: [Note] { notes.values.filter { !$0.deleted } }

    private func rebuildTags() {
        var counts: [String: (display: String, count: Int)] = [:]
        for note in notes.values where !note.deleted && !note.isTrashed && !note.archived {
            var seen = Set<String>()
            for tag in note.meta.tags {
                let parts = tag.split(separator: "/").map(String.init)
                for i in 1...parts.count {
                    let path = parts[0..<i].joined(separator: "/")
                    let key = path.lowercased()
                    guard seen.insert(key).inserted else { continue }
                    counts[key, default: (path, 0)].count += 1
                }
            }
        }
        func children(of parent: String?) -> [TagNode] {
            counts.filter { key, _ in
                let depth = key.split(separator: "/").count
                if let parent { return key.hasPrefix(parent + "/") && depth == parent.split(separator: "/").count + 1 }
                return depth == 1
            }
            .map { key, v in TagNode(path: v.display, name: String(v.display.split(separator: "/").last ?? ""), count: v.count, children: children(of: key)) }
            .sorted { a, b in
                let pa = tagMeta[a.id]?.pinned ?? false, pb = tagMeta[b.id]?.pinned ?? false
                if pa != pb { return pa }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        tagTree = children(of: nil)
    }

    var allTagPaths: [String] {
        func flatten(_ nodes: [TagNode]) -> [String] { nodes.flatMap { [$0.path] + flatten($0.children) } }
        return flatten(tagTree)
    }

    func icon(forTag path: String) -> String {
        tagMeta[path.lowercased()]?.icon ?? (tagMeta[path.lowercased()]?.pinned == true ? "pin" : "number")
    }

    func count(for item: SidebarItem) -> Int {
        notes(for: item, search: "", sort: settings.sortOrder).count
    }

    func notes(for item: SidebarItem, search: String, sort: SortOrder) -> [Note] {
        let calendar = Calendar.current
        var list = liveNotes.filter { note in
            switch item {
            case .notes: return !note.isTrashed && !note.archived
            case .todo: return !note.isTrashed && !note.archived && note.meta.openTodos > 0
            case .today: return !note.isTrashed && calendar.isDateInToday(note.modified)
            case .locked: return !note.isTrashed && note.isEncrypted
            case .untagged: return !note.isTrashed && !note.archived && note.meta.tags.isEmpty
            case .archive: return note.archived && !note.isTrashed
            case .trash: return note.isTrashed
            case .tag(let path):
                let p = path.lowercased()
                return !note.isTrashed && !note.archived && note.meta.tags.contains { $0.lowercased() == p || $0.lowercased().hasPrefix(p + "/") }
            }
        }
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let query = SearchQuery(trimmed)
            let ctx = SearchContext(backlinked: backlinkedIds, attachments: attachments)
            list = list.filter { query.matches(note(withDecryptedTitle: $0), context: ctx) }
        }
        return list.sorted { a, b in
            if item != .trash && a.pinned != b.pinned { return a.pinned }
            switch sort {
            case .modified: return a.modified > b.modified
            case .created: return a.created > b.created
            case .title: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    private func note(withDecryptedTitle note: Note) -> Note { note }

    var backlinkedIds: Set<String> {
        var titles: [String: String] = [:]
        for n in liveNotes where !n.isTrashed { titles[n.title.lowercased()] = n.id }
        var result = Set<String>()
        for n in liveNotes where !n.isTrashed {
            for link in n.meta.wikiLinks { if let id = titles[link.lowercased()] { result.insert(id) } }
        }
        return result
    }

    func note(titled title: String) -> Note? {
        let t = title.lowercased()
        return liveNotes.filter { !$0.isTrashed && $0.title.lowercased() == t }.sorted { $0.modified > $1.modified }.first
    }

    func backlinks(to note: Note) -> [Note] {
        let title = note.title.lowercased()
        guard !title.isEmpty else { return [] }
        return liveNotes.filter { n in n.id != note.id && !n.isTrashed && n.meta.wikiLinks.contains { $0.lowercased() == title } }
            .sorted { $0.modified > $1.modified }
    }

    func outgoingLinks(from note: Note) -> [(title: String, note: Note?)] {
        note.meta.wikiLinks.map { ($0, self.note(titled: $0)) }
    }

    func noteTitles(matching query: String) -> [String] {
        let q = query.lowercased()
        return liveNotes.filter { !$0.isTrashed && !$0.title.isEmpty && (q.isEmpty || $0.title.lowercased().contains(q)) }
            .sorted { $0.modified > $1.modified }.prefix(20).map(\.title)
    }

    func tagSuggestions(matching query: String) -> [String] {
        let q = query.lowercased()
        return allTagPaths.filter { q.isEmpty || $0.lowercased().contains(q) }
            .sorted { a, b in
                let pa = a.lowercased().hasPrefix(q), pb = b.lowercased().hasPrefix(q)
                if pa != pb { return pa }
                return a.count < b.count
            }
            .prefix(20).map { $0 }
    }

    // MARK: Note editing

    @discardableResult
    func createNote(in item: SidebarItem? = nil, body: String? = nil) -> String {
        var text = body ?? ""
        if body == nil, case .tag(let path) = item {
            text = "\n\n" + (path.contains(" ") ? "#\(path)#" : "#\(path)")
        }
        let id = replica.createNote(body: text)
        if item == .archive { replica.setArchived(id, true) }
        return id
    }

    /// Text shown in the editor: the body, or its decryption when unlocked. Nil when locked.
    func editableText(for id: String) -> String? {
        guard let note = notes[id] else { return nil }
        guard note.isEncrypted else { return note.body }
        if let cached = decrypted[id] { return cached }
        guard let key = encryptionKey, let plain = try? NoteCrypto.decrypt(note.body, key: key) else { return nil }
        decrypted[id] = plain
        return plain
    }

    func updateText(_ id: String, _ text: String) {
        guard let note = notes[id] else { return }
        if note.isEncrypted {
            guard let key = encryptionKey, let cipher = try? NoteCrypto.encrypt(text, key: key) else { return }
            decrypted[id] = text
            replica.updateBody(id, cipher)
            let title = NoteParser.parse(text).title
            if title != note.lockedTitle { replica.setLockedTitle(id, title) }
        } else {
            replica.updateBody(id, text)
        }
    }

    func togglePinned(_ id: String) { if let n = notes[id] { replica.setPinned(id, !n.pinned) } }
    func setArchived(_ id: String, _ value: Bool) { replica.setArchived(id, value) }
    func trash(_ id: String) { replica.setTrashed(id, true) }
    func restore(_ id: String) { replica.setTrashed(id, false) }
    func deleteForever(_ id: String) { replica.deleteForever(id) }

    func emptyTrash() {
        for n in liveNotes where n.isTrashed { replica.deleteForever(n.id) }
    }

    @discardableResult
    func duplicate(_ id: String) -> String? {
        guard let text = editableText(for: id), let note = notes[id] else { return nil }
        let newId = replica.createNote(body: text)
        if note.isEncrypted, let key = encryptionKey, let cipher = try? NoteCrypto.encrypt(text, key: key) {
            replica.updateBody(newId, cipher)
            replica.setLockedTitle(newId, note.lockedTitle)
        }
        return newId
    }

    func revisions(for id: String) -> [Revision] { replica.revisions(for: id) }

    func restore(revision: Revision, of id: String) {
        guard let note = notes[id] else { return }
        if NoteCrypto.isEncrypted(revision.text) || !note.isEncrypted {
            replica.updateBody(id, revision.text)
        } else {
            updateText(id, revision.text)
        }
        decrypted.removeValue(forKey: id)
    }

    // MARK: Tags

    func renameTag(_ old: String, to new: String) {
        let newName = MarkdownSyntax.normalizeTag(new.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
        guard !newName.isEmpty, newName != old else { return }
        for note in liveNotes where !note.isEncrypted && note.meta.tags.contains(where: { $0.lowercased() == old.lowercased() || $0.lowercased().hasPrefix(old.lowercased() + "/") }) {
            replica.updateBody(note.id, Self.replacingTag(old, with: newName, in: note.body))
        }
        if let meta = tagMeta[old.lowercased()] {
            replica.setTagIcon(newName, meta.icon)
            replica.setTagPinned(newName, meta.pinned)
        }
    }

    func deleteTag(_ path: String) {
        for note in liveNotes where !note.isEncrypted && note.meta.tags.contains(where: { $0.lowercased() == path.lowercased() || $0.lowercased().hasPrefix(path.lowercased() + "/") }) {
            replica.updateBody(note.id, Self.replacingTag(path, with: nil, in: note.body))
        }
    }

    /// Rewrites `#old` and `#old/child` occurrences, skipping code.
    static func replacingTag(_ old: String, with new: String?, in body: String) -> String {
        let ns = body as NSString
        var result = body
        for t in MarkdownSyntax.tags(in: ns).reversed() {
            let lower = t.name.lowercased(), o = old.lowercased()
            guard lower == o || lower.hasPrefix(o + "/") else { continue }
            let replacement: String
            if let new {
                let renamed = new + t.name.dropFirst(old.count)
                replacement = renamed.contains(" ") ? "#\(renamed)#" : "#\(renamed)"
            } else {
                replacement = ""
            }
            result = (result as NSString).replacingCharacters(in: t.range, with: replacement)
        }
        return result
    }

    func setTagIcon(_ path: String, _ icon: String?) { replica.setTagIcon(path, icon) }
    func toggleTagPinned(_ path: String) { replica.setTagPinned(path, !(tagMeta[path.lowercased()]?.pinned ?? false)) }

    // MARK: Attachments

    func addFiles(_ files: [(data: Data, name: String, mime: String)], to noteId: String) -> [String] {
        var snippets: [String] = []
        for file in files {
            var data = file.data
            var mime = file.mime
            var name = file.name
            // HEIC and very large images are re-encoded for portability.
            if mime.hasPrefix("image/"), mime != "image/gif", let img = PlatformImage.fromData(data),
               mime == "image/heic" || data.count > 4_000_000 {
                let scaled = img.thumbnail(maxDimension: 2400)
                if let jpg = scaled.jpegData(quality: 0.85) {
                    data = jpg
                    mime = "image/jpeg"
                    name = (name as NSString).deletingPathExtension + ".jpg"
                }
            }
            guard let attachment = try? replica.addAttachment(data: data, name: name, mime: mime, noteId: noteId) else { continue }
            let label = name.replacingOccurrences(of: "]", with: "")
            snippets.append(attachment.isImage ? "![\(label)](attachment:\(attachment.id))" : "[\(label)](attachment:\(attachment.id))")
            if attachment.isImage { recognizeText(in: attachment) }
        }
        return snippets
    }

    func image(for attachmentId: String) -> PlatformImage? {
        guard let a = attachments[attachmentId], !a.hash.isEmpty else { return nil }
        if let cached = imageCache.object(forKey: a.hash as NSString) { return cached }
        guard let data = replica.blob(a.hash), let img = PlatformImage.fromData(data) else { return nil }
        let display = img.thumbnail(maxDimension: 1600)
        imageCache.setObject(display, forKey: a.hash as NSString)
        return display
    }

    func attachmentData(_ id: String) -> Data? {
        guard let a = attachments[id] else { return nil }
        return replica.blob(a.hash)
    }

    /// Writes an attachment to a temporary file (for Quick Look and sharing).
    func attachmentFileURL(_ id: String) -> URL? {
        guard let a = attachments[id], let data = replica.blob(a.hash) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attachments/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(a.name.isEmpty ? "Attachment" : a.name)
        try? data.write(to: url)
        return url
    }

    /// Runs on-device text recognition so text inside images is searchable.
    func recognizeText(in attachment: Attachment) {
        guard let data = replica.blob(attachment.hash) else { return }
        let id = attachment.id
        Task.detached(priority: .utility) {
            guard let image = PlatformImage.fromData(data)?.cgImageValue else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            await MainActor.run { [weak self] in self?.replica.setAttachmentOCR(id, text) }
        }
    }

    // MARK: Encryption

    func setEncryptionPassword(_ password: String) {
        let salt = NoteCrypto.makeSalt()
        let key = NoteCrypto.deriveKey(password: password, salt: salt)
        replica.setConfig("encryption", "salt", salt.base64EncodedString())
        replica.setConfig("encryption", "check", NoteCrypto.makeCheck(key: key))
        encryptionKey = key
        Keychain.save(password, account: "encryption-\(replica.deviceId)")
    }

    @discardableResult
    func unlockNotes(password: String) -> Bool {
        guard let saltString = replica.config("encryption", "salt"), let salt = Data(base64Encoded: saltString),
              let check = replica.config("encryption", "check") else { return false }
        let key = NoteCrypto.deriveKey(password: password, salt: salt)
        guard NoteCrypto.verify(key: key, check: check) else { return false }
        encryptionKey = key
        Keychain.save(password, account: "encryption-\(replica.deviceId)")
        return true
    }

    func unlockNotesWithBiometrics() async -> Bool {
        guard let password = Keychain.load(account: "encryption-\(replica.deviceId)") else { return false }
        guard await Biometrics.authenticate(reason: "Unlock your locked notes") else { return false }
        return unlockNotes(password: password)
    }

    var canUseBiometricUnlock: Bool { Keychain.load(account: "encryption-\(replica.deviceId)") != nil && Biometrics.isAvailable }

    func relockNotes() {
        encryptionKey = nil
        decrypted.removeAll()
    }

    func encrypt(_ id: String) {
        guard let note = notes[id], !note.isEncrypted, let key = encryptionKey,
              let cipher = try? NoteCrypto.encrypt(note.body, key: key) else { return }
        replica.setLockedTitle(id, note.meta.title)
        decrypted[id] = note.body
        replica.updateBody(id, cipher)
    }

    func decrypt(_ id: String) {
        guard let note = notes[id], note.isEncrypted, let text = editableText(for: id) else { return }
        decrypted.removeValue(forKey: id)
        replica.updateBody(id, text)
        replica.setLockedTitle(id, nil)
    }

    // MARK: App lock

    func didEnterBackground() {
        backgroundedAt = Date()
        sync.deactivate()
    }

    func didBecomeActive() {
        sync.activate()
        if settings.appLock, let at = backgroundedAt, Date().timeIntervalSince(at) > Double(settings.autoLockMinutes * 60) {
            isAppLocked = true
            relockNotes()
        }
        backgroundedAt = nil
    }

    func unlockApp() async {
        if await Biometrics.authenticate(reason: "Unlock Axolotl", allowPasscode: true) { isAppLocked = false }
    }

    // MARK: URL scheme

    /// Handles `axolotl://` links, including Bear-style x-callback-url actions.
    func handle(url: URL) {
        guard url.scheme == "axolotl" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let action = url.host == "x-callback-url" ? url.lastPathComponent : (url.host ?? "")
        switch action {
        case "create":
            var text = q("text") ?? ""
            if let title = q("title") { text = "# \(title)\n\n" + text }
            if let tags = q("tags") {
                let rendered = tags.split(separator: ",").map { t in
                    let s = t.trimmingCharacters(in: .whitespaces)
                    return s.contains(" ") ? "#\(s)#" : "#\(s)"
                }
                text += "\n\n" + rendered.joined(separator: " ")
            }
            let id = createNote(body: text)
            if q("pin") == "yes" { replica.setPinned(id, true) }
            navigationRequest = NavigationRequest(sidebar: .notes, noteId: id)
        case "open-note", "note":
            let id = q("id") ?? (url.host == "note" ? url.lastPathComponent : nil)
            if let id, notes[id] != nil {
                navigationRequest = NavigationRequest(noteId: id)
            } else if let title = q("title"), let n = note(titled: title) {
                navigationRequest = NavigationRequest(noteId: n.id)
            }
        case "add-text":
            guard let id = q("id") ?? q("title").flatMap({ note(titled: $0)?.id }), let current = editableText(for: id) else { return }
            let text = q("text") ?? ""
            updateText(id, q("mode") == "prepend" ? text + "\n" + current : current + "\n" + text)
            navigationRequest = NavigationRequest(noteId: id)
        case "search":
            navigationRequest = NavigationRequest(sidebar: .notes, search: q("term") ?? "")
        case "open-tag":
            if let name = q("name") { navigationRequest = NavigationRequest(sidebar: .tag(name)) }
        case "today":
            navigationRequest = NavigationRequest(sidebar: .today)
        case "todo":
            navigationRequest = NavigationRequest(sidebar: .todo)
        default:
            break
        }
    }

    static func link(for noteId: String) -> String { "axolotl://x-callback-url/open-note?id=\(noteId)" }

    // MARK: Welcome

    private func seedWelcomeNotes() {
        let welcome = """
        # Welcome to Axolotl

        Axolotl is a fast, private, Markdown-first notes app for **Mac**, **iPhone** and **iPad**. Your notes live on your devices and sync between them end to end encrypted.

        ## The basics
        - Write in *Markdown* and see it styled as you type
        - Organize with tags like #axolotl, including nested ones like #axolotl/getting-started
        - Link notes together with [[Markdown Cheatsheet]]
        - Pin, archive and lock notes from the note menu

        ## Things to try
        - [x] Open this note
        - [ ] Tap a checkbox to complete it
        - [ ] Search with filters like `@todo`, `@today` or `#tag`
        - [ ] Set up sync in **Settings → Sync**

        > [!TIP]
        > Press ⌘O (or swipe to Quick Open on iPad) to jump to any note.

        #axolotl/getting-started
        """
        let cheatsheet = """
        # Markdown Cheatsheet

        ## Text
        **Bold**, *italic*, ~~strikethrough~~, ==highlight==, ~underline~ and `inline code`.

        ## Headings
        Start a line with `#` through `######`.

        ## Lists
        - Bullets with `-`
        1. Numbers with `1.`
        - [ ] Todos with `- [ ]`

        ## Quotes and callouts
        > A quote starts with `>`

        > [!WARNING]
        > Callouts use `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]` or `> [!DANGER]`.

        ## Code
        ```swift
        let greeting = "Hello, Axolotl"
        print(greeting)
        ```

        ## Tables
        | Shortcut | Action |
        | --- | --- |
        | ⌘B | Bold |
        | ⌘I | Italic |

        ## Links
        [Websites](https://nearbycoder.github.io/axolotl), [[Welcome to Axolotl]] wiki links, and tags like #axolotl.

        ---
        Math like $E = mc^2$ and footnotes[^1] are styled too.

        #axolotl
        """
        // Fixed ids so a second device merges these instead of duplicating them.
        replica.createNote(body: cheatsheet, id: "welcome-cheatsheet", created: Date().addingTimeInterval(-60))
        let id = replica.createNote(body: welcome, id: "welcome-axolotl")
        replica.setPinned(id, true)
    }
}
