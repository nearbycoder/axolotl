import SwiftUI
import AxolotlKit

struct NoteListView: View {
    @Environment(AppModel.self) private var model
    let nav: NavigationModel
    @State private var confirmEmptyTrash = false
    @State private var showSearchHelp = false

    var body: some View {
        @Bindable var nav = nav
        let item = nav.sidebar ?? .notes
        let notes = model.notes(for: item, search: nav.search, sort: model.settings.sortOrder)
        List(selection: $nav.selectedNoteId) {
            ForEach(notes) { note in
                NoteRow(note: note)
                    .tag(note.id)
                    .draggable(note.id)
                    .contextMenu { NoteMenu(noteId: note.id, nav: nav) }
                    .swipeActions(edge: .leading) {
                        if !note.isTrashed {
                            Button { model.togglePinned(note.id) } label: {
                                Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if note.isTrashed {
                            Button(role: .destructive) { model.deleteForever(note.id) } label: { Label("Delete", systemImage: "trash.slash") }
                            Button { model.restore(note.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.green)
                        } else {
                            Button(role: .destructive) { model.trash(note.id) } label: { Label("Trash", systemImage: "trash") }
                            Button { model.setArchived(note.id, !note.archived) } label: {
                                Label(note.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
                            }
                            .tint(.indigo)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle(item.title)
        #if os(iOS)
        .searchable(text: $nav.search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes")
        #else
        .searchable(text: $nav.search, placement: .toolbar, prompt: "Search notes")
        #endif
        .searchSuggestions {
            if nav.search.hasPrefix("@") || nav.search.isEmpty {
                ForEach(SearchHelp.specials.filter { nav.search.isEmpty || $0.0.hasPrefix(nav.search) }.prefix(8), id: \.0) { s in
                    Label { Text(s.0) + Text("  \(s.1)").foregroundStyle(.secondary) } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        .searchCompletion(s.0 + " ")
                }
            } else if nav.search.hasPrefix("#") {
                ForEach(model.tagSuggestions(matching: String(nav.search.dropFirst())).prefix(8), id: \.self) { tag in
                    Label("#\(tag)", systemImage: "number").searchCompletion("#\(tag) ")
                }
            }
        }
        .overlay {
            if notes.isEmpty {
                if nav.search.isEmpty {
                    ContentUnavailableView(emptyTitle(item), systemImage: item.symbol, description: Text(emptyMessage(item)))
                } else {
                    ContentUnavailableView.search(text: nav.search)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if item == .trash {
                    Button("Empty Trash", systemImage: "trash.slash", role: .destructive) { confirmEmptyTrash = true }
                        .disabled(notes.isEmpty)
                } else {
                    Button {
                        nav.search = ""
                        nav.open(model.createNote(in: item))
                        nav.focusNewNote = true
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                @Bindable var settings = model.settings
                Menu {
                    Picker("Sort By", selection: $settings.sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                    Button("Search Tips", systemImage: "questionmark.circle") { showSearchHelp = true }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .confirmationDialog("Permanently delete all notes in the Trash?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
        }
        .sheet(isPresented: $showSearchHelp) { SearchHelp() }
    }

    private func emptyTitle(_ item: SidebarItem) -> String {
        switch item {
        case .trash: return "Trash is Empty"
        case .archive: return "No Archived Notes"
        case .todo: return "Nothing To Do"
        case .locked: return "No Locked Notes"
        default: return "No Notes"
        }
    }

    private func emptyMessage(_ item: SidebarItem) -> String {
        switch item {
        case .todo: return "Notes with unchecked todos (- [ ]) appear here."
        case .today: return "Notes you edit today appear here."
        case .locked: return "Lock a note from its menu to encrypt it."
        case .archive: return "Archived notes are kept out of the way but still searchable."
        case .trash: return "Deleted notes stay here until you empty the Trash."
        default: return "Create a note with ⌘N or the compose button."
        }
    }
}

struct NoteRow: View {
    @Environment(AppModel.self) private var model
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    if note.isEncrypted { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                    if note.conflictOf != nil { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.yellow) }
                    Text(note.isUntitled ? "Untitled" : note.title)
                        .font(.headline)
                        .foregroundStyle(note.isUntitled ? .secondary : .primary)
                        .lineLimit(1)
                }
                if model.settings.previewLines > 0 {
                    Text(note.isEncrypted ? "Locked" : (note.meta.preview.isEmpty ? " " : note.meta.preview))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(model.settings.previewLines)
                }
                HStack(spacing: 6) {
                    Text(Calendar.current.isDateInToday(note.modified)
                         ? note.modified.formatted(date: .omitted, time: .shortened)
                         : note.modified.formatted(.dateTime.month(.abbreviated).day().year()))
                        .layoutPriority(1)
                    let todos = note.meta.openTodos + note.meta.doneTodos
                    if todos > 0 {
                        Label("\(note.meta.doneTodos)/\(todos)", systemImage: "checkmark.square").labelStyle(.titleAndIcon)
                    }
                    if !note.meta.tags.isEmpty {
                        Text(note.meta.tags.prefix(3).map { "#\($0)" }.joined(separator: " ")).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.settings.showListImages, let first = note.meta.imageIds.first, let img = model.image(for: first) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 4)
    }
}

/// Context and toolbar menu for a note.
struct NoteMenu: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    let noteId: String
    let nav: NavigationModel

    var body: some View {
        if let note = model.notes[noteId] {
            if note.isTrashed {
                Button("Restore", systemImage: "arrow.uturn.backward") { model.restore(noteId) }
                Button("Delete Permanently", systemImage: "trash.slash", role: .destructive) {
                    if nav.selectedNoteId == noteId { nav.selectedNoteId = nil }
                    model.deleteForever(noteId)
                }
            } else {
                Button(note.pinned ? "Unpin" : "Pin to Top", systemImage: note.pinned ? "pin.slash" : "pin") { model.togglePinned(noteId) }
                Button(note.archived ? "Unarchive" : "Archive", systemImage: "archivebox") { model.setArchived(noteId, !note.archived) }
                if note.isEncrypted {
                    Button("Remove Lock", systemImage: "lock.open") { model.decrypt(noteId) }
                        .disabled(model.editableText(for: noteId) == nil)
                } else {
                    Button("Lock Note", systemImage: "lock") {
                        if model.encryptionKey != nil {
                            model.encrypt(noteId)
                        } else if model.encryptionConfigured {
                            nav.pendingLockNoteId = noteId
                            nav.showUnlockPrompt = true
                        } else {
                            nav.pendingLockNoteId = noteId
                            nav.showPasswordSetup = true
                        }
                    }
                }
                Button("Duplicate", systemImage: "plus.square.on.square") { if let id = model.duplicate(noteId) { nav.open(id) } }
                Button("Copy Link", systemImage: "link") { copyToPasteboard(AppModel.link(for: noteId)) }
                #if os(macOS)
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(value: noteId) }
                #endif
                Divider()
                Button("Move to Trash", systemImage: "trash", role: .destructive) { model.trash(noteId) }
            }
        }
    }
}

struct SearchHelp: View {
    @Environment(\.dismiss) private var dismiss

    static let specials: [(String, String)] = [
        ("@todo", "notes with open todos"), ("@done", "all todos completed"), ("@task", "notes with any todos"),
        ("@today", "edited today"), ("@yesterday", "edited yesterday"), ("@ctoday", "created today"),
        ("@last7days", "edited in the last N days"), ("@created7days", "created in the last N days"),
        ("@date(2025-01-31)", "edited on a day; also < and >"), ("@cdate(>2025-01-01)", "created relative to a day"),
        ("@tagged", "notes with tags"), ("@untagged", "notes without tags"), ("@pinned", "pinned notes"),
        ("@locked", "encrypted notes"), ("@images", "notes with images"), ("@files", "notes with files"),
        ("@attachments", "images or files"), ("@code", "notes with code"), ("@wikilinks", "notes linking to others"),
        ("@backlinks", "notes linked from others"), ("@untitled", "notes without a title"), ("@empty", "empty notes"),
        ("@ocr", "notes with recognized image text"), ("@title", "match following words in titles only"),
        ("@conflict", "conflicted copies from sync"),
    ]

    static let operators: [(String, String)] = [
        ("word", "notes containing the word"), ("\"exact phrase\"", "the exact phrase"), ("-word", "exclude a word"),
        ("#tag", "notes with the tag or its subtags"), ("!#tag", "only the tag itself, not subtags"), ("-#tag", "exclude a tag"),
        ("#*/child", "any tag ending in /child"), ("a OR b", "either term"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Operators") {
                    ForEach(Self.operators, id: \.0) { row($0) }
                }
                Section("Special searches") {
                    ForEach(Self.specials, id: \.0) { row($0) }
                }
            }
            .navigationTitle("Search Tips")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func row(_ item: (String, String)) -> some View {
        HStack {
            Text(item.0).font(.body.monospaced())
            Spacer()
            Text(item.1).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
