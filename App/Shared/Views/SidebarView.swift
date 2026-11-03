import SwiftUI
import AxolotlKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let nav: NavigationModel
    @State private var renaming: String?
    @State private var newTagName = ""
    @State private var iconTag: String?
    @State private var deletingTag: String?

    var body: some View {
        @Bindable var nav = nav
        List(selection: $nav.sidebar) {
            Section {
                row(.notes)
                row(.todo)
                row(.today)
                row(.locked)
            }
            if !model.tagTree.isEmpty {
                Section("Tags") {
                    OutlineGroup(model.tagTree, children: \.childNodes) { node in
                        Label {
                            HStack {
                                Text(node.name).lineLimit(1)
                                Spacer()
                                Text("\(node.count)").foregroundStyle(.secondary).font(.caption).monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: model.icon(forTag: node.path))
                        }
                        .tag(SidebarItem.tag(node.path))
                        .contextMenu { tagMenu(node.path) }
                        .dropDestination(for: String.self) { ids, _ in
                            for id in ids { addTag(node.path, to: id) }
                            return true
                        }
                    }
                }
            }
            Section {
                row(.untagged)
                row(.archive)
                row(.trash)
            }
        }
        .navigationTitle("Axolotl")
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        .safeAreaInset(edge: .bottom) { SyncStatusBar() }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button { nav.showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            #endif
        }
        .alert("Rename Tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Tag name", text: $newTagName)
            Button("Rename") {
                if let old = renaming { model.renameTag(old, to: newTagName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Every note using this tag will be updated.")
        }
        .confirmationDialog("Delete Tag?", isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } })) {
            Button("Remove Tag from Notes", role: .destructive) {
                if let t = deletingTag { model.deleteTag(t) }
                deletingTag = nil
            }
        } message: {
            Text("The tag is removed from all notes. The notes themselves are kept.")
        }
        .sheet(item: Binding(get: { iconTag.map(IdentifiedString.init) }, set: { iconTag = $0?.value })) { item in
            TagIconPicker(selected: model.tagMeta[item.value.lowercased()]?.icon) { icon in
                model.setTagIcon(item.value, icon)
            }
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(item == .notes || item == .todo || item == .today ? model.count(for: item) : 0)
            .tag(item)
            .contextMenu {
                if item == .trash {
                    Button("Empty Trash", role: .destructive) { model.emptyTrash() }
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                for id in ids {
                    switch item {
                    case .trash: model.trash(id)
                    case .archive: model.setArchived(id, true)
                    case .notes: model.restore(id); model.setArchived(id, false)
                    default: break
                    }
                }
                return true
            }
    }

    @ViewBuilder
    private func tagMenu(_ path: String) -> some View {
        let pinned = model.tagMeta[path.lowercased()]?.pinned ?? false
        Button(pinned ? "Unpin Tag" : "Pin Tag", systemImage: pinned ? "pin.slash" : "pin") { model.toggleTagPinned(path) }
        Button("Change Icon…", systemImage: "face.smiling") { iconTag = path }
        Button("Rename…", systemImage: "pencil") {
            newTagName = path
            renaming = path
        }
        Button("New Note in Tag", systemImage: "square.and.pencil") {
            nav.sidebar = .tag(path)
            nav.open(model.createNote(in: .tag(path)))
            nav.focusNewNote = true
        }
        Divider()
        Button("Delete Tag…", systemImage: "trash", role: .destructive) { deletingTag = path }
    }

    private func addTag(_ tag: String, to id: String) {
        guard let text = model.editableText(for: id) else { return }
        let rendered = tag.contains(" ") ? "#\(tag)#" : "#\(tag)"
        if model.notes[id]?.meta.tags.contains(where: { $0.lowercased() == tag.lowercased() }) == true { return }
        model.updateText(id, text + (text.hasSuffix("\n") ? "" : "\n") + rendered)
    }
}

struct IdentifiedString: Identifiable {
    var value: String
    var id: String { value }
}

struct SyncStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: sync.isSyncing || sync.serverState == .connecting)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if sync.isConfigured {
                Button { sync.syncNow() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderless)
                    .help("Sync now")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var icon: String {
        let sync = model.sync
        guard sync.isConfigured else { return "icloud.slash" }
        if case .error = sync.serverState { return "exclamationmark.icloud" }
        return sync.peers.isEmpty && sync.serverState != .connected ? "antenna.radiowaves.left.and.right" : "checkmark.icloud"
    }

    private var color: Color {
        let sync = model.sync
        guard sync.isConfigured else { return .secondary }
        if case .error = sync.serverState { return .orange }
        return .accentColor
    }

    private var title: String {
        let sync = model.sync
        guard sync.isConfigured else { return "Sync off" }
        if case .error = sync.serverState { return "Server unreachable" }
        if sync.serverState == .connected { return sync.peers.isEmpty ? "Synced" : "Synced · \(sync.peers.count) nearby" }
        if !sync.peers.isEmpty { return "\(sync.peers.count) device\(sync.peers.count == 1 ? "" : "s") nearby" }
        return "Looking for devices…"
    }

    private var detail: String? {
        let sync = model.sync
        guard sync.isConfigured else { return "Set up in Settings" }
        if let last = sync.lastSync { return "Updated \(last.formatted(.relative(presentation: .named)))" }
        return sync.pendingChanges > 0 ? "\(sync.pendingChanges) changes waiting" : nil
    }
}

struct TagIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    var selected: String?
    var onPick: (String?) -> Void

    static let symbols = [
        "number", "star", "heart", "bookmark", "flag", "pin", "bolt", "lightbulb", "brain", "book", "books.vertical", "graduationcap",
        "briefcase", "building.2", "house", "cart", "creditcard", "banknote", "chart.bar", "chart.pie", "calendar", "clock", "alarm",
        "checklist", "list.bullet", "folder", "tray", "archivebox", "doc.text", "pencil", "paintbrush", "paintpalette", "camera",
        "photo", "film", "music.note", "headphones", "gamecontroller", "sportscourt", "figure.run", "dumbbell", "bicycle", "car",
        "airplane", "map", "globe", "leaf", "tree", "flame", "drop", "sun.max", "moon", "cloud", "snowflake", "pawprint", "fish",
        "bird", "tortoise", "ladybug", "ant", "fork.knife", "cup.and.saucer", "wineglass", "birthday.cake", "gift", "bag",
        "person", "person.2", "figure.2.and.child.holdinghands", "stethoscope", "pills", "cross.case", "terminal",
        "chevron.left.forwardslash.chevron.right", "cpu", "server.rack", "desktopcomputer", "iphone", "keyboard", "hammer",
        "wrench.and.screwdriver", "gearshape", "lock", "key", "shield", "envelope", "phone", "message", "quote.bubble", "sparkles",
        "wand.and.stars", "atom", "function", "sum", "testtube.2", "globe.americas", "mountain.2", "beach.umbrella", "tent",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button {
                            onPick(symbol == "number" ? nil : symbol)
                            dismiss()
                        } label: {
                            Image(systemName: symbol)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(RoundedRectangle(cornerRadius: 10).fill(symbol == (selected ?? "number") ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Tag Icon")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .frame(minWidth: 380, minHeight: 360)
    }
}
