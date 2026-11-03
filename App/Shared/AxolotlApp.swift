import SwiftUI
import AxolotlKit

@main
struct AxolotlApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.settings.colorScheme)
                .onOpenURL { model.handle(url: $0) }
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 480)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 780)
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.didBecomeActive()
            case .background: model.didEnterBackground()
            default: break
            }
        }
        .commands { AppCommands(model: model) }

        #if os(macOS)
        WindowGroup("Note", id: "note", for: String.self) { $noteId in
            if let noteId {
                NoteWindow(noteId: noteId)
                    .environment(model)
                    .preferredColorScheme(model.settings.colorScheme)
            }
        }
        .defaultSize(width: 720, height: 640)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.settings.colorScheme)
        }
        #endif
    }
}

#if os(macOS)
/// A single note in its own window.
struct NoteWindow: View {
    @Environment(AppModel.self) private var model
    let noteId: String
    @State private var nav = NavigationModel()

    var body: some View {
        NavigationStack {
            NoteDetailView(nav: nav)
        }
        .onAppear { nav.selectedNoteId = noteId }
        .focusedSceneValue(\.navigation, nav)
        .navigationTitle(model.notes[noteId]?.title ?? "Note")
    }
}
#endif

struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.navigation) private var nav
    @FocusedValue(\.editorController) private var editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                guard let nav else { return }
                nav.search = ""
                if nav.sidebar == .trash { nav.sidebar = .notes }
                nav.open(model.createNote(in: nav.sidebar))
                nav.focusNewNote = true
            }
            .keyboardShortcut("n")
            Button("Quick Open…") { nav?.showQuickOpen = true }
                .keyboardShortcut("o")
        }

        CommandMenu("Format") {
            Group {
                Button("Bold") { editor?.perform(.bold) }.keyboardShortcut("b")
                Button("Italic") { editor?.perform(.italic) }.keyboardShortcut("i")
                Button("Underline") { editor?.perform(.underline) }.keyboardShortcut("u")
                Button("Strikethrough") { editor?.perform(.strike) }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Highlight") { editor?.perform(.highlight) }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Inline Code") { editor?.perform(.code) }.keyboardShortcut("c", modifiers: [.command, .option])
            }
            Divider()
            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { editor?.perform(.heading(level)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: .command)
                }
                Button("Body Text") { editor?.perform(.heading(0)) }.keyboardShortcut("0", modifiers: .command)
            }
            Group {
                Button("Todo") { editor?.perform(.todo) }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Bulleted List") { editor?.perform(.bulletList) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Numbered List") { editor?.perform(.numberedList) }.keyboardShortcut("l", modifiers: [.command, .option])
                Button("Quote") { editor?.perform(.quote) }.keyboardShortcut("'", modifiers: [.command, .option])
                Button("Code Block") { editor?.perform(.codeBlock) }.keyboardShortcut("b", modifiers: [.command, .option])
            }
            Divider()
            Group {
                Button("Link") { editor?.perform(.link) }.keyboardShortcut("k")
                Button("Note Link") { editor?.perform(.wikiLink) }.keyboardShortcut("k", modifiers: [.command, .option])
                Button("Tag") { editor?.perform(.tag) }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Table") { editor?.perform(.table) }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("Separator") { editor?.perform(.rule) }.keyboardShortcut("-", modifiers: [.command, .option])
            }
            Divider()
            Button("Indent") { editor?.perform(.indent) }.keyboardShortcut("]")
            Button("Outdent") { editor?.perform(.outdent) }.keyboardShortcut("[")
        }

        CommandMenu("Note") {
            Button("Pin / Unpin") { if let id = nav?.selectedNoteId { model.togglePinned(id) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Archive / Unarchive") {
                if let id = nav?.selectedNoteId, let n = model.notes[id] { model.setArchived(id, !n.archived) }
            }
            Button("Duplicate") { if let nav, let id = nav.selectedNoteId, let new = model.duplicate(id) { nav.open(new) } }
                .keyboardShortcut("d")
            Button("Copy Link") { if let id = nav?.selectedNoteId { copyToPasteboard(AppModel.link(for: id)) } }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            Divider()
            Button("Show Info") { nav?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Version History…") { nav?.showHistory = true }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
            Button("Move to Trash") {
                if let nav, let id = nav.selectedNoteId { model.trash(id) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Focus Mode") {
                guard let nav else { return }
                nav.columnVisibility = nav.columnVisibility == .detailOnly ? .all : .detailOnly
            }
            .keyboardShortcut("f", modifiers: [.command, .control, .shift])
            Button("Search Notes") {
                guard let nav else { return }
                if nav.columnVisibility == .detailOnly { nav.columnVisibility = .all }
                nav.showQuickOpen = true
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
            Button("Notes") { nav?.sidebar = .notes }.keyboardShortcut("1", modifiers: [.command, .control])
            Button("Todo") { nav?.sidebar = .todo }.keyboardShortcut("2", modifiers: [.command, .control])
            Button("Today") { nav?.sidebar = .today }.keyboardShortcut("3", modifiers: [.command, .control])
            Button("Archive") { nav?.sidebar = .archive }.keyboardShortcut("4", modifiers: [.command, .control])
            Button("Trash") { nav?.sidebar = .trash }.keyboardShortcut("5", modifiers: [.command, .control])
        }
    }
}
