import AppIntents
import Foundation
import AxolotlKit

// App Intents expose Axolotl to Siri, Shortcuts, Spotlight and Apple Intelligence on iPhone,
// iPad and Mac. They call the same toolbox the MCP server uses, so behaviour (locked-note
// rules, tag handling, todo editing) is identical everywhere.

struct NoteEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Note" }
    static var defaultQuery = NoteQuery()

    var id: String
    @Property(title: "Title") var title: String
    @Property(title: "Preview") var preview: String
    @Property(title: "Tags") var tags: [String]
    @Property(title: "Modified") var modified: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: preview.isEmpty ? nil : "\(preview)")
    }

    init(_ note: Note) {
        id = note.id
        title = note.isUntitled ? "Untitled" : note.title
        preview = note.isEncrypted ? "Locked" : note.meta.preview
        tags = note.isEncrypted ? [] : note.meta.tags
        modified = note.modified
    }
}

struct NoteQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        identifiers.compactMap { AppModel.shared.notes[$0] }.filter { !$0.deleted }.map(NoteEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [NoteEntity] {
        AppModel.shared.notes(for: .notes, search: string, sort: .modified).prefix(30).map(NoteEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [NoteEntity] {
        AppModel.shared.notes(for: .notes, search: "", sort: .modified).prefix(20).map(NoteEntity.init)
    }
}

/// Runs a toolbox tool from an intent and returns its JSON result.
@MainActor
private func run(_ tool: String, _ args: JSONObject) async throws -> JSONObject {
    let toolbox = AgentToolbox(model: AppModel.shared)
    guard let t = toolbox.tool(named: tool) else { throw AgentError("Missing tool \(tool)") }
    let result = try await t.handler(ToolArgs(raw: args))
    AppModel.shared.recordAgentActivity(tool, client: "Shortcuts", summary: MCPSession.describe(ToolArgs(raw: args)), failed: false)
    return result as? JSONObject ?? [:]
}

struct CreateNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Note"
    static var description = IntentDescription("Creates a note in Axolotl from Markdown text.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Parameter(title: "Title") var noteTitle: String?
    @Parameter(title: "Tags", default: []) var tags: [String]
    @Parameter(title: "Pin", default: false) var pinned: Bool
    @Parameter(title: "Open in Axolotl", default: false) var open: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Create note \(\.$text)") {
            \.$noteTitle
            \.$tags
            \.$pinned
            \.$open
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        var args: JSONObject = ["text": text, "tags": tags, "pinned": pinned, "open": open]
        if let noteTitle { args["title"] = noteTitle }
        let result = try await run("create_note", args)
        let id = result["id"] as? String ?? ""
        guard let note = AppModel.shared.notes[id] else { throw AgentError("The note was not created.") }
        return .result(value: NoteEntity(note), dialog: "Created “\(NoteEntity(note).title)”.")
    }
}

struct AppendToNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Note"
    static var description = IntentDescription("Adds text to the end of a note, or under one of its headings.")

    @Parameter(title: "Note") var note: NoteEntity
    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) var text: String
    @Parameter(title: "Under Heading") var heading: String?
    @Parameter(title: "As Todo", default: false) var asTodo: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$note)") {
            \.$heading
            \.$asTodo
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var args: JSONObject = ["note": note.id, "text": text]
        if let heading { args["heading"] = heading }
        _ = try await run(asTodo ? "add_todo" : "append_to_note", args)
        return .result(dialog: "Added to “\(note.title)”.")
    }
}

struct OpenNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Note"
    static var description = IntentDescription("Opens a note in Axolotl.")
    static var openAppWhenRun = true

    @Parameter(title: "Note") var note: NoteEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$note)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.navigationRequest = NavigationRequest(noteId: note.id)
        return .result()
    }
}

struct SearchNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Notes"
    static var description = IntentDescription("Finds notes using Axolotl search, including #tags and filters like @todo or @today.")

    @Parameter(title: "Search") var query: String
    @Parameter(title: "Limit", default: 20) var limit: Int

    static var parameterSummary: some ParameterSummary { Summary("Search notes for \(\.$query)") { \.$limit } }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> {
        let notes = AppModel.shared.notes(for: .notes, search: query, sort: .modified).prefix(max(1, limit))
        return .result(value: notes.map(NoteEntity.init))
    }
}

struct GetNoteTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Note Text"
    static var description = IntentDescription("Returns a note's Markdown.")

    @Parameter(title: "Note") var note: NoteEntity

    static var parameterSummary: some ParameterSummary { Summary("Get the text of \(\.$note)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await run("get_note", ["note": note.id])
        return .result(value: result["text"] as? String ?? "")
    }
}

struct ListTodosIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Open Todos"
    static var description = IntentDescription("Returns unchecked todo items across your notes.")

    @Parameter(title: "Tag") var tag: String?

    static var parameterSummary: some ParameterSummary { Summary("Get open todos") { \.$tag } }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        var args: JSONObject = [:]
        if let tag { args["tag"] = tag }
        let result = try await run("list_todos", args)
        let items = (result["todos"] as? [JSONObject] ?? []).compactMap { $0["text"] as? String }
        return .result(value: items)
    }
}

enum NoteStateChange: String, AppEnum {
    case pin, unpin, archive, unarchive, trash, restore

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Change" }
    static var caseDisplayRepresentations: [NoteStateChange: DisplayRepresentation] {
        [.pin: "Pin", .unpin: "Unpin", .archive: "Archive", .unarchive: "Unarchive", .trash: "Move to Trash", .restore: "Restore from Trash"]
    }
}

struct ChangeNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Pin, Archive or Trash Note"
    static var description = IntentDescription("Pins, archives, trashes or restores a note.")

    @Parameter(title: "Change") var change: NoteStateChange
    @Parameter(title: "Note") var note: NoteEntity

    static var parameterSummary: some ParameterSummary { Summary("\(\.$change) \(\.$note)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let args: JSONObject
        switch change {
        case .pin: args = ["note": note.id, "pinned": true]
        case .unpin: args = ["note": note.id, "pinned": false]
        case .archive: args = ["note": note.id, "archived": true]
        case .unarchive: args = ["note": note.id, "archived": false]
        case .trash: args = ["note": note.id, "trashed": true]
        case .restore: args = ["note": note.id, "trashed": false]
        }
        _ = try await run("update_note", args)
        return .result(dialog: "Done.")
    }
}

struct TagNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Tag Note"
    static var description = IntentDescription("Adds a tag to a note.")

    @Parameter(title: "Tag") var tag: String
    @Parameter(title: "Note") var note: NoteEntity

    static var parameterSummary: some ParameterSummary { Summary("Tag \(\.$note) with \(\.$tag)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run("tag_note", ["note": note.id, "add": [tag]])
        return .result()
    }
}

struct AxolotlShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateNoteIntent(), phrases: ["Create a note in \(.applicationName)", "New \(.applicationName) note"],
                    shortTitle: "Create Note", systemImageName: "square.and.pencil")
        AppShortcut(intent: AppendToNoteIntent(), phrases: ["Add to \(\.$note) in \(.applicationName)", "Add to a note in \(.applicationName)"],
                    shortTitle: "Add to Note", systemImageName: "text.append")
        AppShortcut(intent: OpenNoteIntent(), phrases: ["Open \(\.$note) in \(.applicationName)", "Open a note in \(.applicationName)"],
                    shortTitle: "Open Note", systemImageName: "doc.text")
        AppShortcut(intent: SearchNotesIntent(), phrases: ["Search \(.applicationName)", "Search notes in \(.applicationName)"],
                    shortTitle: "Search Notes", systemImageName: "magnifyingglass")
        AppShortcut(intent: ListTodosIntent(), phrases: ["What's on my \(.applicationName) todo list", "Get my todos from \(.applicationName)"],
                    shortTitle: "Open Todos", systemImageName: "checklist")
    }
}
