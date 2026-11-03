import SwiftUI
import AxolotlKit

/// ⌘O: jump to any note by title, or create one.
struct QuickOpenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let nav: NavigationModel
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let notes = model.liveNotes.filter { !$0.isTrashed }
        guard !q.isEmpty else { return Array(notes.sorted { $0.modified > $1.modified }.prefix(12)) }
        let lower = q.lowercased()
        let titleHits = notes.filter { $0.title.lowercased().contains(lower) }
            .sorted { a, b in
                let pa = a.title.lowercased().hasPrefix(lower), pb = b.title.lowercased().hasPrefix(lower)
                return pa != pb ? pa : a.modified > b.modified
            }
        let search = SearchQuery(q)
        let ctx = SearchContext(attachments: model.attachments)
        let bodyHits = notes.filter { n in !titleHits.contains { $0.id == n.id } && search.matches(n, context: ctx) }
            .sorted { $0.modified > $1.modified }
        return Array((titleHits + bodyHits).prefix(30))
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Open note…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { open(items) }
                    #if os(macOS)
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, items.count); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    #endif
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, note in
                        Button { select(note.id) } label: {
                            HStack {
                                Image(systemName: note.isEncrypted ? "lock" : "doc.text").foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(note.isUntitled ? "Untitled" : note.title).lineLimit(1)
                                    if !note.meta.preview.isEmpty {
                                        Text(note.meta.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(i == highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
                        .id(i)
                    }
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button { create() } label: {
                            Label("Create “\(query)”", systemImage: "plus.circle").contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(highlighted == items.count ? Color.accentColor.opacity(0.18) : Color.clear)
                        .id(items.count)
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .onChange(of: query) { highlighted = 0 }
        .onAppear { focused = true }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func open(_ items: [Note]) {
        if highlighted < items.count { select(items[highlighted].id) } else if !query.isEmpty { create() }
    }

    private func select(_ id: String) {
        if let note = model.notes[id] {
            if note.isTrashed { nav.sidebar = .trash } else if note.archived { nav.sidebar = .archive }
        }
        nav.open(id)
        dismiss()
    }

    private func create() {
        nav.open(model.createNote(body: "# \(query)\n\n"))
        nav.focusNewNote = true
        dismiss()
    }
}
