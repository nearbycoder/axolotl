import Foundation
import AxolotlKit
#if os(macOS)
import AppKit
#endif

typealias JSONObject = [String: Any]

struct AgentActivity: Identifiable, Hashable {
    let id = UUID()
    var date: Date
    var tool: String
    var client: String
    var summary: String
    var failed: Bool
}

struct AgentError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Content blocks for results that are not plain JSON (for example images).
struct ToolContent {
    var blocks: [JSONObject]
    var structured: Any?
}

/// Validated access to a tool call's arguments.
struct ToolArgs {
    let raw: JSONObject

    func string(_ key: String) throws -> String {
        guard let v = raw[key] as? String, !v.isEmpty else { throw AgentError("Missing required argument '\(key)'.") }
        return v
    }
    func optString(_ key: String) -> String? { (raw[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    /// Text arguments may legitimately be empty.
    func text(_ key: String) -> String? { raw[key] as? String }
    func bool(_ key: String) -> Bool? {
        if let b = raw[key] as? Bool { return b }
        if let s = raw[key] as? String { return ["true", "yes", "1"].contains(s.lowercased()) ? true : (["false", "no", "0"].contains(s.lowercased()) ? false : nil) }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let n = raw[key] as? NSNumber { return n.intValue }
        if let s = raw[key] as? String { return Int(s) }
        return nil
    }
    func strings(_ key: String) -> [String] {
        if let a = raw[key] as? [String] { return a.filter { !$0.isEmpty } }
        if let s = raw[key] as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return []
    }
}

struct AgentTool {
    let name: String
    let title: String
    let description: String
    let properties: JSONObject
    let required: [String]
    let readOnly: Bool
    let destructive: Bool
    let idempotent: Bool
    let handler: @MainActor (ToolArgs) async throws -> Any

    var definition: JSONObject {
        var schema: JSONObject = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": schema,
            "annotations": [
                "title": title,
                "readOnlyHint": readOnly,
                "destructiveHint": destructive,
                "idempotentHint": idempotent,
                "openWorldHint": false,
            ] as JSONObject,
        ]
    }
}

/// Every action the app supports, exposed to agents (MCP, the `axolotl` CLI).
/// Handlers run on the main actor against the same model the UI uses, so changes appear instantly
/// and sync like any edit made by hand.
@MainActor
final class AgentToolbox {
    let model: AppModel
    private(set) var tools: [AgentTool] = []
    private var byName: [String: AgentTool] = [:]

    init(model: AppModel) {
        self.model = model
        tools = makeTools()
        for t in tools { byName[t.name] = t }
    }

    func tool(named name: String) -> AgentTool? { byName[name] }

    static let instructions = """
    Axolotl is a Markdown notes app. Notes are plain Markdown; the first line is the title (usually "# Title").
    Tags are written inline as #tag or #nested/tag (use #multi word tag# for spaces). Link notes with [[Note Title]].
    Todos are "- [ ] item" / "- [x] item". Callouts are "> [!NOTE]" blocks. Highlight with ==text==.
    Identify notes by id (preferred) or exact title. Search supports words, "phrases", -exclusions, #tag, !#exact-tag,
    OR, and filters such as @todo @done @today @yesterday @last7days @created7days @date(>2025-01-01) @images @files
    @code @locked @pinned @untagged @untitled @wikilinks @backlinks @title.
    Prefer edit_note or append_to_note for small changes instead of replacing a whole note. Every change is kept in
    version history and can be restored with restore_revision. Locked (encrypted) notes are hidden from agents unless
    the user allows it in Settings → Agents and has unlocked them in the app.
    """

    // MARK: Helpers

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var canReadLocked: Bool { model.settings.agentsReadLockedNotes && model.encryptionKey != nil }

    func resolveNote(_ args: ToolArgs, key: String = "note") throws -> Note {
        let ref = try args.string(key).trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = model.notes[ref], !n.deleted { return n }
        let lower = ref.lowercased()
        let matches = model.liveNotes.filter { $0.title.lowercased() == lower }
        if let n = matches.sorted(by: { ($0.isTrashed ? 1 : 0, -$0.modified.timeIntervalSince1970) < ($1.isTrashed ? 1 : 0, -$1.modified.timeIntervalSince1970) }).first {
            return n
        }
        throw AgentError("No note with id or title '\(ref)'. Use search_notes to find it.")
    }

    /// Readable Markdown of a note, or an error explaining why it is not available.
    func readableText(_ note: Note) throws -> String {
        guard note.isEncrypted else { return note.body }
        guard model.settings.agentsReadLockedNotes else {
            throw AgentError("'\(note.title)' is locked. The user has not allowed agents to read locked notes (Settings → Agents).")
        }
        guard let text = model.editableText(for: note.id) else {
            throw AgentError("'\(note.title)' is locked. Ask the user to unlock it in Axolotl first.")
        }
        return text
    }

    func write(_ note: Note, _ text: String) throws {
        if note.isEncrypted {
            guard model.settings.agentsReadLockedNotes, model.encryptionKey != nil else {
                throw AgentError("'\(note.title)' is locked and cannot be edited by agents right now.")
            }
        }
        // Each agent edit becomes its own entry in version history, so it can always be undone.
        model.replica.checkpoint(note.id)
        model.updateText(note.id, text)
        model.replica.checkpoint(note.id)
    }

    /// Where text "at the end" goes: above a trailing line of #tags, which conventionally stays last.
    static func endLocation(in text: String) -> Int {
        let ns = text as NSString
        var end = ns.length
        while end > 0, let scalar = UnicodeScalar(ns.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
        guard end > 0 else { return ns.length }
        let lastLine = ns.lineRange(for: NSRange(location: end - 1, length: 0))
        let content = ns.substring(with: lastLine).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = content.split(separator: " ")
        let tagOnly = !words.isEmpty && words.allSatisfy { $0.hasPrefix("#") && $0.count > 1 } &&
            MarkdownSyntax.tags(in: NSString(string: content)).count > 0 && !content.hasPrefix("# ")
        return tagOnly && lastLine.location > 0 ? lastLine.location : ns.length
    }

    /// Removes tag markup, dropping a line that ends up empty.
    static func removingTag(_ tag: String, from text: String) -> String {
        let wanted = MarkdownSyntax.normalizeTag(tag.trimmingCharacters(in: CharacterSet(charactersIn: "# "))).lowercased()
        var out = text
        for t in MarkdownSyntax.tags(in: NSString(string: out)).reversed() where t.name.lowercased() == wanted {
            let ns = out as NSString
            let line = ns.lineRange(for: t.range)
            let remainder = (ns.substring(with: line) as NSString).replacingCharacters(in: NSRange(location: t.range.location - line.location, length: t.range.length), with: "")
            if remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out = ns.replacingCharacters(in: line, with: "")
            } else {
                out = ns.replacingCharacters(in: t.range, with: "").replacingOccurrences(of: "  ", with: " ")
            }
        }
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out
    }

    func summary(_ n: Note) -> JSONObject {
        let hidden = n.isEncrypted && !canReadLocked
        let meta = hidden ? NoteMeta() : (n.isEncrypted ? NoteParser.parse(model.editableText(for: n.id) ?? "") : n.meta)
        var out: JSONObject = [
            "id": n.id,
            "title": n.isUntitled ? "Untitled" : n.title,
            "tags": meta.tags,
            "pinned": n.pinned,
            "archived": n.archived,
            "trashed": n.isTrashed,
            "locked": n.isEncrypted,
            "created": Self.iso.string(from: n.created),
            "modified": Self.iso.string(from: n.modified),
            "open_todos": meta.openTodos,
            "done_todos": meta.doneTodos,
            "link": AppModel.link(for: n.id),
        ]
        if !hidden { out["preview"] = meta.preview }
        if n.conflictOf != nil { out["conflicted_copy_of"] = n.conflictOf! }
        return out
    }

    func detail(_ n: Note) throws -> JSONObject {
        var out = summary(n)
        let text = try readableText(n)
        let meta = n.isEncrypted ? NoteParser.parse(text) : n.meta
        out["text"] = text
        out["headings"] = meta.headings.map { ["level": $0.level, "text": $0.text] as JSONObject }
        out["links_to"] = meta.wikiLinks.map { title -> JSONObject in
            var o: JSONObject = ["title": title]
            if let target = model.note(titled: title) { o["id"] = target.id }
            return o
        }
        out["backlinks"] = model.backlinks(to: n).map { ["id": $0.id, "title": $0.title] as JSONObject }
        out["attachments"] = (meta.imageIds + meta.fileIds).compactMap { model.attachments[$0] }.map(attachmentInfo)
        out["word_count"] = TextStats(NoteParser.cleanInline(text)).words
        return out
    }

    func attachmentInfo(_ a: Attachment) -> JSONObject {
        ["id": a.id, "name": a.name, "mime": a.mime, "size": a.size, "note_id": a.noteId,
         "markdown": a.isImage ? "![\(a.name)](attachment:\(a.id))" : "[\(a.name)](attachment:\(a.id))",
         "available": model.replica.hasBlob(a.hash)]
    }

    static func section(_ raw: String?) throws -> SidebarItem {
        switch (raw ?? "notes").lowercased() {
        case "notes", "all", "": return .notes
        case "todo", "todos": return .todo
        case "today": return .today
        case "locked": return .locked
        case "untagged": return .untagged
        case "archive", "archived": return .archive
        case "trash", "trashed": return .trash
        default: throw AgentError("Unknown section '\(raw!)'. Use notes, todo, today, locked, untagged, archive or trash.")
        }
    }

    static func sort(_ raw: String?) -> SortOrder {
        switch raw?.lowercased() {
        case "created": return .created
        case "title": return .title
        default: return .modified
        }
    }

    static func tagMarkup(_ tag: String) -> String {
        let t = MarkdownSyntax.normalizeTag(tag.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
        return t.contains(" ") ? "#\(t)#" : "#\(t)"
    }

    /// Range of the section under a heading: from the end of the heading line to the next heading of the same or higher level.
    static func sectionEnd(in text: NSString, heading: String) -> Int? {
        let headings = NoteParser.parse(text as String).headings
        let wanted = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard let i = headings.firstIndex(where: { $0.text.lowercased() == wanted }) else { return nil }
        let h = headings[i]
        if let next = headings[(i + 1)...].first(where: { $0.level <= h.level }) { return next.location }
        return text.length
    }

    static func isListLine(_ line: Substring) -> Bool {
        line.range(of: #"^\s*([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
    }

    static func sectionStart(in text: NSString, heading: String) -> Int? {
        let wanted = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        return NoteParser.parse(text as String).headings.first { $0.text.lowercased() == wanted }?.location
    }

    /// Inserts a block at a location with Markdown-friendly spacing: a blank line around paragraphs,
    /// none between consecutive list items.
    static func insert(_ block: String, into text: String, at location: Int) -> String {
        let ns = text as NSString
        let before = ns.substring(to: location).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let after = ns.substring(from: location).replacingOccurrences(of: #"^\n+"#, with: "", options: .regularExpression)
        let body = block.trimmingCharacters(in: .newlines)
        let firstOfBlock = body.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let lastOfBlock = body.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        var out = before
        if !before.isEmpty {
            let prev = before.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            out += isListLine(prev) && isListLine(firstOfBlock) ? "\n" : "\n\n"
        }
        out += body
        if !after.isEmpty {
            let next = after.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
            out += isListLine(lastOfBlock) && isListLine(next) ? "\n" : "\n\n"
            out += after
        } else {
            out += "\n"
        }
        return out
    }

    /// Adds tags on the note's trailing tag line, or on a new last line.
    static func appendingTags(_ tags: [String], to text: String) -> String {
        let existing = Set(NoteParser.parse(text).tags.map { $0.lowercased() })
        let add = tags.map { MarkdownSyntax.normalizeTag($0.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) }
            .filter { !$0.isEmpty && !existing.contains($0.lowercased()) }
        guard !add.isEmpty else { return text }
        let markup = add.map(tagMarkup).joined(separator: " ")
        let trimmed = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let tagLineStart = endLocation(in: trimmed)
        if tagLineStart < (trimmed as NSString).length { return trimmed + " " + markup + "\n" }
        return trimmed.isEmpty ? markup + "\n" : trimmed + "\n\n" + markup + "\n"
    }

    struct TodoItem {
        var index: Int
        var text: String
        var done: Bool
        var range: NSRange   // range of the checkbox character
    }

    static func todos(in text: String) -> [TodoItem] {
        let ns = NSString(string: text)
        let code = MarkdownSyntax.codeIndex(in: ns)
        var items: [TodoItem] = []
        MarkdownSyntax.todo.enumerateMatches(in: ns as String, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, !code.contains(m.range.location) else { return }
            let line = ns.lineRange(for: m.range)
            let rest = ns.substring(with: NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range)))
            items.append(TodoItem(index: items.count, text: rest.trimmingCharacters(in: .whitespacesAndNewlines),
                                  done: ns.substring(with: m.range(at: 3)) != " ", range: m.range(at: 3)))
        }
        return items
    }

    // MARK: Tool definitions

    private func makeTools() -> [AgentTool] {
        let noteArg: JSONObject = ["type": "string", "description": "Note id, or the exact note title."]
        let sectionArg: JSONObject = ["type": "string", "enum": ["notes", "todo", "today", "locked", "untagged", "archive", "trash"],
                                      "description": "Sidebar section. Default notes (everything not archived or trashed)."]
        let sortArg: JSONObject = ["type": "string", "enum": ["modified", "created", "title"], "description": "Sort order. Default modified (newest first)."]
        let tagsArg: JSONObject = ["type": "array", "items": ["type": "string"], "description": "Tags without the leading #, e.g. work/projects."]
        let m = model

        func listResult(_ notes: [Note], limit: Int?, offset: Int?) -> JSONObject {
            let off = max(0, offset ?? 0), lim = min(max(1, limit ?? 50), 500)
            let page = notes.dropFirst(off).prefix(lim)
            return ["total": notes.count, "offset": off, "notes": page.map(summary)]
        }

        return [
            // ---- Reading
            AgentTool(name: "list_notes", title: "List notes",
                      description: "List notes in a sidebar section or tag, with titles, previews, tags, dates and todo counts.",
                      properties: ["section": sectionArg, "tag": ["type": "string", "description": "Only notes with this tag (or its subtags)."],
                                   "sort": sortArg, "limit": ["type": "integer", "description": "Max results (default 50, max 500)."],
                                   "offset": ["type": "integer", "description": "Skip this many results."]],
                      required: [], readOnly: true, destructive: false, idempotent: true) { a in
                let item: SidebarItem = try a.optString("tag").map { .tag(MarkdownSyntax.normalizeTag($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")))) } ?? Self.section(a.optString("section"))
                return listResult(m.notes(for: item, search: "", sort: Self.sort(a.optString("sort"))), limit: a.int("limit"), offset: a.int("offset"))
            },
            AgentTool(name: "search_notes", title: "Search notes",
                      description: "Search notes with Axolotl's query language: words, \"phrases\", -exclude, #tag, !#exact-tag, a OR b, and filters like @todo @done @today @last7days @date(>2025-06-01) @images @code @pinned @untagged @backlinks @title. Text inside images is searched too.",
                      properties: ["query": ["type": "string", "description": "The search query."], "section": sectionArg, "sort": sortArg,
                                   "limit": ["type": "integer", "description": "Max results (default 50)."]],
                      required: ["query"], readOnly: true, destructive: false, idempotent: true) { a in
                let notes = m.notes(for: try Self.section(a.optString("section")), search: try a.string("query"), sort: Self.sort(a.optString("sort")))
                return listResult(notes, limit: a.int("limit"), offset: nil)
            },
            AgentTool(name: "get_note", title: "Read a note",
                      description: "Read a note's full Markdown with its tags, headings, outgoing links, backlinks, attachments and dates.",
                      properties: ["note": noteArg], required: ["note"], readOnly: true, destructive: false, idempotent: true) { [unowned self] a in
                try self.detail(try self.resolveNote(a))
            },
            AgentTool(name: "list_todos", title: "List todos",
                      description: "List checkbox items across all notes (or one note), with their note and position, so they can be ticked off with set_todo.",
                      properties: ["note": ["type": "string", "description": "Limit to this note (id or title)."],
                                   "include_done": ["type": "boolean", "description": "Include completed items. Default false."],
                                   "tag": ["type": "string", "description": "Only notes with this tag."]],
                      required: [], readOnly: true, destructive: false, idempotent: true) { [unowned self] a in
                let includeDone = a.bool("include_done") ?? false
                var notes: [Note]
                if a.optString("note") != nil { notes = [try self.resolveNote(a)] }
                else if let tag = a.optString("tag") { notes = m.notes(for: .tag(MarkdownSyntax.normalizeTag(tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")))), search: "", sort: .modified) }
                else { notes = m.notes(for: includeDone ? .notes : .todo, search: "", sort: .modified) }
                var out: [JSONObject] = []
                for n in notes {
                    guard let text = try? self.readableText(n) else { continue }
                    for t in Self.todos(in: text) where includeDone || !t.done {
                        out.append(["note_id": n.id, "note_title": n.title, "index": t.index, "text": t.text, "done": t.done])
                    }
                }
                return ["count": out.count, "todos": out]
            },
            AgentTool(name: "list_tags", title: "List tags",
                      description: "List all tags as a tree with note counts, icons and pinned state.",
                      properties: [:], required: [], readOnly: true, destructive: false, idempotent: true) { _ in
                @MainActor func node(_ t: TagNode) -> JSONObject {
                    var o: JSONObject = ["tag": t.path, "name": t.name, "count": t.count, "pinned": m.tagMeta[t.id]?.pinned ?? false]
                    if let icon = m.tagMeta[t.id]?.icon { o["icon"] = icon }
                    if !t.children.isEmpty { o["children"] = t.children.map(node) }
                    return o
                }
                return ["tags": m.tagTree.map(node)]
            },
            AgentTool(name: "get_library_stats", title: "Library statistics",
                      description: "Counts of notes per section, tags, attachments and their total size, plus sync status.",
                      properties: [:], required: [], readOnly: true, destructive: false, idempotent: true) { _ in
                let attachments = m.attachments.values.filter { !$0.deleted }
                var counts: JSONObject = [:]
                for s: SidebarItem in [.notes, .todo, .today, .locked, .untagged, .archive, .trash] { counts[s.title.lowercased()] = m.count(for: s) }
                return ["sections": counts, "tags": m.allTagPaths.count, "attachments": attachments.count,
                        "attachment_bytes": attachments.reduce(0) { $0 + $1.size }]
            },

            // ---- Writing
            AgentTool(name: "create_note", title: "Create a note",
                      description: "Create a note from Markdown. If title is given and the text does not start with a heading, the title becomes '# title'. Tags are appended as #tags.",
                      properties: ["text": ["type": "string", "description": "Markdown body."], "title": ["type": "string"], "tags": tagsArg,
                                   "pinned": ["type": "boolean"], "open": ["type": "boolean", "description": "Show the new note in the app."]],
                      required: [], readOnly: false, destructive: false, idempotent: false) { [unowned self] a in
                var body = a.text("text") ?? ""
                if let title = a.optString("title"), !body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
                    body = "# \(title)\n\n" + body
                }
                body = Self.appendingTags(a.strings("tags"), to: body)
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError("Provide text or a title.") }
                let id = m.createNote(body: body)
                if a.bool("pinned") == true { m.replica.setPinned(id, true) }
                if a.bool("open") == true { self.reveal(noteId: id) }
                return self.summary(m.notes[id]!)
            },
            AgentTool(name: "edit_note", title: "Find and replace in a note",
                      description: "Replace exact text inside a note. Fails if the text is not found (or is ambiguous when all is false and it appears more than once).",
                      properties: ["note": noteArg, "find": ["type": "string", "description": "Exact text to find."],
                                   "replace": ["type": "string", "description": "Replacement text (may be empty)."],
                                   "all": ["type": "boolean", "description": "Replace every occurrence. Default false."]],
                      required: ["note", "find", "replace"], readOnly: false, destructive: false, idempotent: false) { [unowned self] a in
                let note = try self.resolveNote(a)
                let text = try self.readableText(note)
                let find = try a.string("find")
                let replace = a.text("replace") ?? ""
                let count = text.components(separatedBy: find).count - 1
                guard count > 0 else { throw AgentError("The text to find was not found in '\(note.title)'.") }
                let all = a.bool("all") ?? false
                if count > 1 && !all { throw AgentError("The text appears \(count) times; add more context or set all to true.") }
                let updated: String
                if all { updated = text.replacingOccurrences(of: find, with: replace) }
                else { updated = text.replacingCharacters(in: text.range(of: find)!, with: replace) }
                try self.write(note, updated)
                return ["id": note.id, "replacements": all ? count : 1]
            },
            AgentTool(name: "append_to_note", title: "Add text to a note",
                      description: "Add Markdown to the end or start of a note, or at the end of the section under a heading.",
                      properties: ["note": noteArg, "text": ["type": "string"],
                                   "position": ["type": "string", "enum": ["end", "start", "after_heading"], "description": "Default end."],
                                   "heading": ["type": "string", "description": "Heading text, for after_heading."]],
                      required: ["note", "text"], readOnly: false, destructive: false, idempotent: false) { [unowned self] a in
                let note = try self.resolveNote(a)
                let text = try self.readableText(note)
                let block = try a.string("text")
                let updated: String
                switch a.optString("position") ?? (a.optString("heading") != nil ? "after_heading" : "end") {
                case "start":
                    // After the title line, so the note keeps its title.
                    let ns = text as NSString
                    let titleEnd = text.hasPrefix("#") ? NSMaxRange(ns.lineRange(for: NSRange(location: 0, length: 0))) : 0
                    updated = Self.insert(block, into: text, at: titleEnd)
                case "after_heading":
                    let heading = try a.string("heading")
                    guard let loc = Self.sectionEnd(in: text as NSString, heading: heading) else { throw AgentError("No heading '\(heading)' in '\(note.title)'.") }
                    updated = Self.insert(block, into: text, at: loc)
                default:
                    updated = Self.insert(block, into: text, at: Self.endLocation(in: text))
                }
                try self.write(note, updated)
                return ["id": note.id, "title": note.title]
            },
            AgentTool(name: "replace_note_text", title: "Replace a note's text",
                      description: "Replace a note's entire Markdown. The previous version stays in version history.",
                      properties: ["note": noteArg, "text": ["type": "string"]],
                      required: ["note", "text"], readOnly: false, destructive: true, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                _ = try self.readableText(note)
                try self.write(note, a.text("text") ?? "")
                return self.summary(m.notes[note.id]!)
            },
            AgentTool(name: "update_note", title: "Pin, archive, trash or restore",
                      description: "Change a note's state: pinned, archived, or trashed (false restores from the Trash).",
                      properties: ["note": noteArg, "pinned": ["type": "boolean"], "archived": ["type": "boolean"], "trashed": ["type": "boolean"]],
                      required: ["note"], readOnly: false, destructive: false, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                if let p = a.bool("pinned") { m.replica.setPinned(note.id, p) }
                if let ar = a.bool("archived") { m.setArchived(note.id, ar) }
                if let t = a.bool("trashed") { t ? m.trash(note.id) : m.restore(note.id) }
                return self.summary(m.notes[note.id]!)
            },
            AgentTool(name: "duplicate_note", title: "Duplicate a note",
                      description: "Make a copy of a note.", properties: ["note": noteArg],
                      required: ["note"], readOnly: false, destructive: false, idempotent: false) { [unowned self] a in
                let note = try self.resolveNote(a)
                _ = try self.readableText(note)
                guard let id = m.duplicate(note.id) else { throw AgentError("Could not duplicate the note.") }
                return self.summary(m.notes[id]!)
            },
            AgentTool(name: "delete_note_permanently", title: "Delete a note permanently",
                      description: "Permanently delete a note and its history on every synced device. This cannot be undone; prefer update_note with trashed=true.",
                      properties: ["note": noteArg], required: ["note"], readOnly: false, destructive: true, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                m.deleteForever(note.id)
                return ["deleted": note.id, "title": note.title]
            },
            AgentTool(name: "empty_trash", title: "Empty the Trash",
                      description: "Permanently delete every note in the Trash. Cannot be undone.",
                      properties: [:], required: [], readOnly: false, destructive: true, idempotent: true) { _ in
                let count = m.count(for: .trash)
                m.emptyTrash()
                return ["deleted": count]
            },

            // ---- Todos
            AgentTool(name: "add_todo", title: "Add a todo",
                      description: "Add a '- [ ]' checkbox item to a note, at the end or under a heading.",
                      properties: ["note": noteArg, "text": ["type": "string"], "heading": ["type": "string", "description": "Add to the section under this heading."],
                                   "done": ["type": "boolean"]],
                      required: ["note", "text"], readOnly: false, destructive: false, idempotent: false) { [unowned self] a in
                let note = try self.resolveNote(a)
                let text = try self.readableText(note)
                let line = "- [\((a.bool("done") ?? false) ? "x" : " ")] " + (try a.string("text"))
                let loc: Int
                if let h = a.optString("heading") {
                    guard let end = Self.sectionEnd(in: text as NSString, heading: h) else { throw AgentError("No heading '\(h)' in '\(note.title)'.") }
                    // Join the section's existing checklist rather than going after whatever follows it.
                    let start = Self.sectionStart(in: text as NSString, heading: h) ?? 0
                    let lastTodo = Self.todos(in: text).last { $0.range.location >= start && $0.range.location < end }
                    loc = lastTodo.map { NSMaxRange((text as NSString).lineRange(for: $0.range)) } ?? end
                } else {
                    loc = Self.endLocation(in: text)
                }
                let updated = Self.insert(line, into: text, at: loc)
                try self.write(note, updated)
                return ["id": note.id, "added": line]
            },
            AgentTool(name: "set_todo", title: "Check or uncheck a todo",
                      description: "Mark a checkbox item done or not done, by its index (from list_todos/get_note) or by matching its text.",
                      properties: ["note": noteArg, "index": ["type": "integer"], "match": ["type": "string", "description": "Text contained in the item."],
                                   "done": ["type": "boolean", "description": "Default true."]],
                      required: ["note"], readOnly: false, destructive: false, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                let text = try self.readableText(note)
                let items = Self.todos(in: text)
                let done = a.bool("done") ?? true
                var target: TodoItem?
                if let i = a.int("index") { target = items.first { $0.index == i } }
                else if let match = a.optString("match")?.lowercased() {
                    let candidates = items.filter { $0.text.lowercased().contains(match) }
                    target = candidates.first { $0.done != done } ?? candidates.first
                } else { throw AgentError("Provide index or match.") }
                guard let item = target else { throw AgentError("No matching todo in '\(note.title)'.") }
                let updated = (text as NSString).replacingCharacters(in: item.range, with: done ? "x" : " ")
                try self.write(note, updated)
                return ["id": note.id, "todo": item.text, "done": done]
            },

            // ---- Tags
            AgentTool(name: "tag_note", title: "Add or remove tags",
                      description: "Add tags to a note (appended as #tags) and/or remove tags from it.",
                      properties: ["note": noteArg, "add": tagsArg, "remove": tagsArg],
                      required: ["note"], readOnly: false, destructive: false, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                var text = try self.readableText(note)
                for tag in a.strings("remove") { text = Self.removingTag(tag, from: text) }
                text = Self.appendingTags(a.strings("add"), to: text)
                try self.write(note, text)
                return self.summary(m.notes[note.id]!)
            },
            AgentTool(name: "rename_tag", title: "Rename a tag",
                      description: "Rename a tag (and its subtags) in every note.",
                      properties: ["tag": ["type": "string"], "new_name": ["type": "string"]],
                      required: ["tag", "new_name"], readOnly: false, destructive: false, idempotent: true) { a in
                let old = MarkdownSyntax.normalizeTag(try a.string("tag").trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
                let affected = m.notes(for: .tag(old), search: "", sort: .modified).count
                m.renameTag(old, to: try a.string("new_name"))
                return ["renamed": old, "to": try a.string("new_name"), "notes": affected]
            },
            AgentTool(name: "delete_tag", title: "Delete a tag",
                      description: "Remove a tag (and its subtags) from every note. The notes themselves are kept.",
                      properties: ["tag": ["type": "string"]], required: ["tag"], readOnly: false, destructive: true, idempotent: true) { a in
                let tag = MarkdownSyntax.normalizeTag(try a.string("tag").trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
                let affected = m.notes(for: .tag(tag), search: "", sort: .modified).count
                m.deleteTag(tag)
                return ["deleted": tag, "notes": affected]
            },
            AgentTool(name: "set_tag_appearance", title: "Tag icon and pinning",
                      description: "Set a tag's sidebar icon (an SF Symbol name such as briefcase, airplane, book) and whether it is pinned to the top.",
                      properties: ["tag": ["type": "string"], "icon": ["type": "string", "description": "SF Symbol name, or empty to reset."], "pinned": ["type": "boolean"]],
                      required: ["tag"], readOnly: false, destructive: false, idempotent: true) { a in
                let tag = MarkdownSyntax.normalizeTag(try a.string("tag").trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
                if let icon = a.text("icon") { m.setTagIcon(tag, icon.isEmpty ? nil : icon) }
                if let pinned = a.bool("pinned"), pinned != (m.tagMeta[tag.lowercased()]?.pinned ?? false) { m.toggleTagPinned(tag) }
                return ["tag": tag, "icon": m.tagMeta[tag.lowercased()]?.icon as Any, "pinned": m.tagMeta[tag.lowercased()]?.pinned ?? false]
            },

            // ---- History
            AgentTool(name: "list_revisions", title: "Version history",
                      description: "List saved versions of a note, newest first.",
                      properties: ["note": noteArg, "limit": ["type": "integer", "description": "Default 30."]],
                      required: ["note"], readOnly: true, destructive: false, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                _ = try self.readableText(note)
                let revisions = m.revisions(for: note.id).prefix(max(1, a.int("limit") ?? 30))
                return ["note_id": note.id, "revisions": revisions.map { r -> JSONObject in
                    let text = m.revisionText(r) ?? ""
                    return ["revision": r.id, "date": Self.iso.string(from: r.date), "title": NoteParser.parse(text).title,
                            "characters": text.count]
                }]
            },
            AgentTool(name: "get_revision", title: "Read an old version",
                      description: "Read the Markdown of one saved version of a note.",
                      properties: ["note": noteArg, "revision": ["type": "string"]],
                      required: ["note", "revision"], readOnly: true, destructive: false, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                _ = try self.readableText(note)
                let id = try a.string("revision")
                guard let r = m.revisions(for: note.id).first(where: { $0.id == id }), let text = m.revisionText(r) else {
                    throw AgentError("No readable revision '\(id)' for '\(note.title)'.")
                }
                return ["revision": r.id, "date": Self.iso.string(from: r.date), "text": text]
            },
            AgentTool(name: "restore_revision", title: "Restore an old version",
                      description: "Restore a note to a saved version. The current text is kept in history.",
                      properties: ["note": noteArg, "revision": ["type": "string"]],
                      required: ["note", "revision"], readOnly: false, destructive: false, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                _ = try self.readableText(note)
                let id = try a.string("revision")
                guard let r = m.revisions(for: note.id).first(where: { $0.id == id }) else { throw AgentError("No revision '\(id)'.") }
                m.replica.checkpoint(note.id)
                m.restore(revision: r, of: note.id)
                m.replica.checkpoint(note.id)
                return self.summary(m.notes[note.id]!)
            },

            // ---- Attachments
            AgentTool(name: "add_attachment", title: "Attach a file or image",
                      description: "Attach a file to a note from a local path (or base64 data). Images display inline. The Markdown reference is appended to the note unless insert is false.",
                      properties: ["note": noteArg, "path": ["type": "string", "description": "Absolute path to a local file."],
                                   "base64": ["type": "string", "description": "File contents, base64-encoded (alternative to path)."],
                                   "name": ["type": "string", "description": "File name (required with base64)."],
                                   "heading": ["type": "string", "description": "Insert under this heading."],
                                   "insert": ["type": "boolean", "description": "Add the reference to the note text. Default true."]],
                      required: ["note"], readOnly: false, destructive: false, idempotent: false) { [unowned self] a in
                let note = try self.resolveNote(a)
                let text = try self.readableText(note)
                let data: Data, name: String
                if let path = a.optString("path") {
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    guard let d = try? Data(contentsOf: url) else { throw AgentError("Can't read \(url.path).") }
                    data = d
                    name = a.optString("name") ?? url.lastPathComponent
                } else if let b64 = a.optString("base64"), let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                    data = d
                    name = try a.string("name")
                } else {
                    throw AgentError("Provide path or base64.")
                }
                guard data.count <= 200 * 1024 * 1024 else { throw AgentError("Attachments are limited to 200 MB.") }
                let mime = UTTypeHelper.mime(forExtension: (name as NSString).pathExtension)
                guard let snippet = m.addFiles([(data, name, mime)], to: note.id).first else { throw AgentError("Could not store the attachment.") }
                if a.bool("insert") ?? true {
                    var loc = Self.endLocation(in: text)
                    if let h = a.optString("heading") {
                        guard let l = Self.sectionEnd(in: text as NSString, heading: h) else { throw AgentError("No heading '\(h)'.") }
                        loc = l
                    }
                    try self.write(note, Self.insert(snippet, into: text, at: loc))
                }
                return ["note_id": note.id, "markdown": snippet]
            },
            AgentTool(name: "get_attachment", title: "Read an attachment",
                      description: "Get an attachment's contents. Text files are returned inline, images as image content; anything else, or anything given save_to, is written to disk and its path returned.",
                      properties: ["attachment": ["type": "string", "description": "Attachment id (from get_note)."],
                                   "save_to": ["type": "string", "description": "Optional file or folder path to write it to."]],
                      required: ["attachment"], readOnly: true, destructive: false, idempotent: true) { [unowned self] a in
                let id = try a.string("attachment")
                guard let att = m.attachments[id], !att.deleted else { throw AgentError("No attachment '\(id)'.") }
                if let note = m.notes[att.noteId] { _ = try self.readableText(note) }
                guard let data = m.attachmentData(id) else { throw AgentError("'\(att.name)' hasn't finished syncing to this device yet.") }
                if let save = a.optString("save_to") {
                    var url = URL(fileURLWithPath: (save as NSString).expandingTildeInPath)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { url.appendPathComponent(att.name) }
                    try data.write(to: url)
                    return ["path": url.path, "size": data.count, "mime": att.mime]
                }
                if att.mime.hasPrefix("text/"), data.count <= 512 * 1024, let s = String(data: data, encoding: .utf8) {
                    return ["name": att.name, "mime": att.mime, "text": s]
                }
                if att.isImage, data.count <= 4 * 1024 * 1024 {
                    let mime = ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(att.mime) ? att.mime : "image/jpeg"
                    let payload = mime == att.mime ? data : (ImageLoader.reencodedJPEG(data, maxPixels: 2400, quality: 0.85) ?? data)
                    return ToolContent(blocks: [["type": "text", "text": "\(att.name) (\(att.mime), \(data.count) bytes)"],
                                                ["type": "image", "data": payload.base64EncodedString(), "mimeType": mime]],
                                       structured: self.attachmentInfo(att))
                }
                guard let url = m.attachmentFileURL(id) else { throw AgentError("Could not write the attachment.") }
                return ["path": url.path, "size": data.count, "mime": att.mime]
            },

            // ---- Import / export
            AgentTool(name: "export_note", title: "Export a note",
                      description: "Export a note as markdown, text, html, pdf, rtf, docx (Mac) or textbundle. Writes to path if given (a folder or a file), otherwise returns markdown/text/html inline and writes other formats to a temporary file.",
                      properties: ["note": noteArg, "format": ["type": "string", "enum": ExportFormat.available.map(\.rawValue)],
                                   "path": ["type": "string"]],
                      required: ["note", "format"], readOnly: true, destructive: false, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                let text = try self.readableText(note)
                guard let format = ExportFormat(rawValue: try a.string("format")), ExportFormat.available.contains(format) else {
                    throw AgentError("Unsupported format. Use one of: \(ExportFormat.available.map(\.rawValue).joined(separator: ", ")).")
                }
                let file = try await ExportService.export(note: note, text: text, format: format, model: m)
                if let path = a.optString("path") {
                    var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { url.appendPathComponent(file.filename) }
                    try file.wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
                    return ["path": url.path]
                }
                if [.markdown, .text, .html].contains(format), let data = file.wrapper.regularFileContents, let s = String(data: data, encoding: .utf8) {
                    return ["filename": file.filename, "content": s]
                }
                return ["path": try file.writeTemporary().path]
            },
            AgentTool(name: "export_library", title: "Export all notes",
                      description: "Export every note as Markdown files with an assets folder, zipped. Returns the zip path (moved to path if given).",
                      properties: ["path": ["type": "string"]], required: [], readOnly: true, destructive: false, idempotent: true) { a in
                var zip = try ExportService.exportAll(model: m)
                if let path = a.optString("path") {
                    var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { url.appendPathComponent(zip.lastPathComponent) }
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: zip, to: url)
                    zip = url
                }
                return ["path": zip.path]
            },
            AgentTool(name: "import_files", title: "Import files",
                      description: "Import Markdown, text, TextBundle or Bear notes (files or folders of them) as new notes.",
                      properties: ["paths": ["type": "array", "items": ["type": "string"]]],
                      required: ["paths"], readOnly: false, destructive: false, idempotent: false) { a in
                let urls = a.strings("paths").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                guard !urls.isEmpty else { throw AgentError("Provide at least one path.") }
                return ["imported": ImportService.importFiles(urls, into: m)]
            },

            // ---- Locking
            AgentTool(name: "lock_note", title: "Lock (encrypt) a note",
                      description: "Encrypt a note with the user's lock password. Locked notes must be unlocked in the app before they can be locked or read here.",
                      properties: ["note": noteArg], required: ["note"], readOnly: false, destructive: false, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                guard !note.isEncrypted else { return self.summary(note) }
                guard m.encryptionKey != nil else {
                    throw AgentError(m.encryptionConfigured ? "Locked notes are not unlocked in Axolotl right now." : "No lock password is set up yet (Settings → Security).")
                }
                m.encrypt(note.id)
                return self.summary(m.notes[note.id]!)
            },
            AgentTool(name: "unlock_note", title: "Remove a note's lock",
                      description: "Permanently decrypt a locked note (remove its lock). Requires the user to allow agents to read locked notes and to have unlocked them in the app.",
                      properties: ["note": noteArg], required: ["note"], readOnly: false, destructive: false, idempotent: true) { [unowned self] a in
                let note = try self.resolveNote(a)
                guard note.isEncrypted else { return self.summary(note) }
                _ = try self.readableText(note)
                m.decrypt(note.id)
                return self.summary(m.notes[note.id]!)
            },

            // ---- App
            AgentTool(name: "open_in_app", title: "Show in Axolotl",
                      description: "Bring Axolotl to the front showing a note, a section, a tag, or search results.",
                      properties: ["note": ["type": "string"], "section": sectionArg, "tag": ["type": "string"], "search": ["type": "string"]],
                      required: [], readOnly: true, destructive: false, idempotent: true) { [unowned self] a in
                var request = NavigationRequest()
                if a.optString("note") != nil { request.noteId = try self.resolveNote(a).id }
                if let tag = a.optString("tag") { request.sidebar = .tag(MarkdownSyntax.normalizeTag(tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")))) }
                else if a.optString("section") != nil { request.sidebar = try Self.section(a.optString("section")) }
                if let search = a.optString("search") { request.search = search; request.sidebar = request.sidebar ?? .notes }
                m.navigationRequest = request
                self.activateApp()
                return ["shown": true]
            },
            AgentTool(name: "get_settings", title: "Read settings",
                      description: "Read appearance and editor settings, and the available themes and fonts.",
                      properties: [:], required: [], readOnly: true, destructive: false, idempotent: true) { _ in
                let s = m.settings
                return ["appearance": s.appearance.rawValue, "light_theme": s.lightThemeId, "dark_theme": s.darkThemeId,
                        "font": s.fontId, "font_size": s.fontSize, "line_height": s.lineHeight, "line_width": s.lineWidth,
                        "paragraph_spacing": s.paragraphSpacing, "typewriter_mode": s.typewriterMode, "hide_markdown": s.hideMarkdown,
                        "spell_check": s.spellCheck, "sort_order": s.sortOrder.rawValue, "preview_lines": s.previewLines,
                        "themes": Theme.all.map { ["id": $0.id, "name": $0.name, "dark": $0.isDark] as JSONObject },
                        "fonts": EditorFont.all.map { ["id": $0.id, "name": $0.name] as JSONObject }]
            },
            AgentTool(name: "update_settings", title: "Change settings",
                      description: "Change appearance and editor settings. Security settings can only be changed by the user in the app.",
                      properties: ["appearance": ["type": "string", "enum": ["system", "light", "dark"]],
                                   "light_theme": ["type": "string"], "dark_theme": ["type": "string"], "font": ["type": "string"],
                                   "font_size": ["type": "number"], "line_height": ["type": "number"], "line_width": ["type": "number"],
                                   "paragraph_spacing": ["type": "number"], "typewriter_mode": ["type": "boolean"], "hide_markdown": ["type": "boolean"],
                                   "spell_check": ["type": "boolean"], "sort_order": sortArg, "preview_lines": ["type": "integer"]],
                      required: [], readOnly: false, destructive: false, idempotent: true) { a in
                let s = m.settings
                func num(_ k: String) -> Double? { (a.raw[k] as? NSNumber)?.doubleValue }
                if let v = a.optString("appearance") { guard let mode = AppearanceMode(rawValue: v) else { throw AgentError("Bad appearance.") }; s.appearance = mode }
                for (key, dark) in [("light_theme", false), ("dark_theme", true)] {
                    guard let id = a.optString(key) else { continue }
                    guard let theme = Theme.all.first(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) else { throw AgentError("Unknown theme '\(id)'.") }
                    guard theme.isDark == dark else { throw AgentError("'\(theme.name)' is a \(theme.isDark ? "dark" : "light") theme.") }
                    if dark { s.darkThemeId = theme.id } else { s.lightThemeId = theme.id }
                }
                if let f = a.optString("font") {
                    guard let font = EditorFont.all.first(where: { $0.id == f || $0.name.lowercased() == f.lowercased() }) else { throw AgentError("Unknown font '\(f)'.") }
                    s.fontId = font.id
                }
                if let v = num("font_size") { s.fontSize = min(28, max(12, v)) }
                if let v = num("line_height") { s.lineHeight = min(2, max(1, v)) }
                if let v = num("line_width") { s.lineWidth = min(1400, max(480, v)) }
                if let v = num("paragraph_spacing") { s.paragraphSpacing = min(24, max(0, v)) }
                if let v = a.bool("typewriter_mode") { s.typewriterMode = v }
                if let v = a.bool("hide_markdown") { s.hideMarkdown = v }
                if let v = a.bool("spell_check") { s.spellCheck = v }
                if let v = a.optString("sort_order") { s.sortOrder = Self.sort(v) }
                if let v = a.int("preview_lines") { s.previewLines = min(4, max(0, v)) }
                return ["updated": true]
            },
            AgentTool(name: "get_sync_status", title: "Sync status",
                      description: "Whether sync is set up, nearby devices, the sync server state, pending changes and the last sync time.",
                      properties: [:], required: [], readOnly: true, destructive: false, idempotent: true) { _ in
                let s = m.sync
                var server: String
                switch s.serverState {
                case .notConfigured: server = "not configured"
                case .connecting: server = "connecting"
                case .connected: server = "connected"
                case .error(let e): server = "error: \(e)"
                }
                var out: JSONObject = ["configured": s.isConfigured, "local_network": s.lanEnabled, "nearby_devices": s.peers.map(\.name),
                                       "server": server, "pending_changes": s.pendingChanges]
                if let url = s.serverURL { out["server_url"] = url.absoluteString }
                if let last = s.lastSync { out["last_sync"] = Self.iso.string(from: last) }
                return out
            },
            AgentTool(name: "sync_now", title: "Sync now",
                      description: "Push and pull changes with nearby devices and the sync server immediately.",
                      properties: [:], required: [], readOnly: false, destructive: false, idempotent: true) { _ in
                guard m.sync.isConfigured else { throw AgentError("Sync is not set up on this device.") }
                m.sync.syncNow()
                return ["started": true]
            },
        ]
    }

    func reveal(noteId: String) {
        model.navigationRequest = NavigationRequest(noteId: noteId)
        activateApp()
    }

    func activateApp() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        #endif
    }
}
