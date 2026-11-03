import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import AxolotlKit

struct EditorScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let noteId: String
    let nav: NavigationModel

    @State private var controller = EditorController()
    @State private var exportFile: ExportFile?
    @State private var showExporter = false
    @State private var shareURL: URL?
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showSketch = false
    @State private var showScanner = false
    @State private var quickLookURL: URL?

    var body: some View {
        @Bindable var nav = nav
        let theme = model.theme(for: scheme)
        VStack(spacing: 0) {
            banners
            if let text = model.editableText(for: noteId) {
                MarkdownEditor(noteId: noteId, markdown: text, config: config(theme), controller: controller,
                               callbacks: callbacks, onAttachRequest: { showPhotoPicker = true })
                    .overlay(alignment: .bottomLeading) { completionPopup(theme) }
            } else {
                LockedNoteView(noteId: noteId)
            }
        }
        .background(theme.backgroundSwiftUI)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.backgroundSwiftUI, for: .navigationBar)
        #endif
        #if os(macOS)
        .navigationTitle(model.notes[noteId]?.title ?? "")
        #endif
        .toolbar { toolbar }
        .inspector(isPresented: $nav.showInspector) {
            InspectorView(noteId: noteId, nav: nav, controller: controller)
                .inspectorColumnWidth(min: 240, ideal: 290, max: 380)
        }
        .focusedSceneValue(\.editorController, controller)
        .sheet(isPresented: $nav.showHistory) { HistoryView(noteId: noteId) }
        .fileExporter(isPresented: $showExporter, document: exportFile, contentType: exportFile?.contentType ?? .plainText,
                      defaultFilename: exportFile?.filename) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var files: [(data: Data, name: String, mime: String)] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    files.append((data, url.lastPathComponent, UTTypeHelper.mime(forExtension: url.pathExtension)))
                }
            }
            controller.attach(files)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var files: [(data: Data, name: String, mime: String)] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let type = item.supportedContentTypes.first
                        let ext = type?.preferredFilenameExtension ?? "jpg"
                        files.append((data, "Photo.\(ext)", type?.preferredMIMEType ?? "image/jpeg"))
                    }
                }
                photoItems = []
                controller.attach(files)
            }
        }
        .quickLookPreview($quickLookURL)
        #if os(iOS)
        .sheet(item: Binding(get: { shareURL.map(IdentifiedURL.init) }, set: { shareURL = $0?.url })) { item in
            ActivityView(items: [item.url]).ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showSketch) {
            SketchView { png in controller.attach([(png, "Sketch.png", "image/png")]) }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { images in
                controller.attach(images.enumerated().compactMap { i, img in
                    img.jpegData(compressionQuality: 0.8).map { ($0, "Scan \(i + 1).jpg", "image/jpeg") }
                })
            }
            .ignoresSafeArea()
        }
        #endif
        .task {
            if nav.focusNewNote {
                nav.focusNewNote = false
                try? await Task.sleep(for: .milliseconds(250))
                controller.focus()
            }
        }
        .onDisappear { controller.flush() }
    }

    private func config(_ theme: Theme) -> EditorConfig {
        let s = model.settings
        return EditorConfig(
            style: EditorStyleKey(themeId: theme.id, fontId: s.fontId, fontSize: s.fontSize, lineHeight: s.lineHeight,
                                  paragraphSpacing: s.paragraphSpacing, dimMarkdown: s.dimMarkdown),
            typewriter: s.typewriterMode, spellCheck: s.spellCheck, lineWidth: s.lineWidth, imagesVersion: model.imagesVersion)
    }

    private var callbacks: EditorCallbacks {
        var c = EditorCallbacks()
        let id = noteId
        c.onChange = { [model] text in model.updateText(id, text) }
        c.onOpenURL = { [model] string in
            if string.hasPrefix("axolotl://"), let url = URL(string: string) {
                model.handle(url: url)
            } else if let url = URL(string: string), url.scheme != nil {
                openExternalURL(url)
            }
        }
        c.onOpenWiki = { [model, nav] title in
            if let target = model.note(titled: title) {
                nav.open(target.id)
            } else {
                nav.open(model.createNote(body: "# \(title)\n\n"))
            }
        }
        c.onTag = { [nav] tag in
            nav.sidebar = .tag(tag)
            nav.search = ""
        }
        c.onOpenAttachment = { [model] attachmentId in quickLookURL = model.attachmentFileURL(attachmentId) }
        c.onAttachFiles = { [model] files in model.addFiles(files, to: id) }
        c.suggestions = { [model] state in
            switch state.kind {
            case .tag: return model.tagSuggestions(matching: state.query)
            case .wiki: return model.noteTitles(matching: state.query).filter { $0 != model.notes[id]?.title }
            }
        }
        c.image = { [model] attachmentId in model.image(for: attachmentId) }
        return c
    }

    @ViewBuilder
    private var banners: some View {
        if let note = model.notes[noteId] {
            if note.isTrashed {
                Banner(text: "This note is in the Trash", symbol: "trash", tint: .red) {
                    Button("Restore") { model.restore(noteId) }
                    Button("Delete", role: .destructive) {
                        nav.selectedNoteId = nil
                        model.deleteForever(noteId)
                    }
                }
            } else if let original = note.conflictOf {
                Banner(text: "Conflicted copy created during sync", symbol: "exclamationmark.triangle", tint: .yellow) {
                    if model.notes[original]?.deleted == false { Button("Open Original") { nav.open(original) } }
                    Button("Discard Copy", role: .destructive) { model.trash(noteId) }
                }
            } else if note.archived {
                Banner(text: "Archived", symbol: "archivebox", tint: .indigo) {
                    Button("Unarchive") { model.setArchived(noteId, false) }
                }
            }
        }
    }

    @ViewBuilder
    private func completionPopup(_ theme: Theme) -> some View {
        #if os(macOS)
        if let c = controller.completion, !controller.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(controller.suggestions.prefix(8).enumerated()), id: \.offset) { i, s in
                    Button { controller.accept(s) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: c.kind == .tag ? "number" : "doc.text").foregroundStyle(.secondary)
                            Text(s).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(i == controller.highlightedSuggestion ? theme.accentSwiftUI.opacity(0.18) : .clear)
                    }
                    .buttonStyle(.plain)
                }
                Text("↑↓ to choose · ↩ to insert · esc to dismiss").font(.caption2).foregroundStyle(.tertiary).padding(8)
            }
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(16)
        }
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(ExportFormat.available) { format in
                    Button(format.label, systemImage: format.symbol) { export(format) }
                }
                Divider()
                Button("Print…", systemImage: "printer") { print() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                nav.showInspector.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            Menu {
                NoteMenu(noteId: noteId, nav: nav)
                Divider()
                Button("Version History", systemImage: "clock.arrow.circlepath") { nav.showHistory = true }
                Menu("Attach", systemImage: "paperclip") {
                    Button("Photo", systemImage: "photo") { showPhotoPicker = true }
                    Button("File", systemImage: "doc") { showFileImporter = true }
                    #if os(iOS)
                    Button("Sketch", systemImage: "pencil.tip.crop.circle") { showSketch = true }
                    if DocumentScannerView.isSupported {
                        Button("Scan Document", systemImage: "doc.viewfinder") { showScanner = true }
                    }
                    #endif
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func export(_ format: ExportFormat) {
        guard let note = model.notes[noteId] else { return }
        Task {
            do {
                let file = try await ExportService.export(note: note, text: model.editableText(for: noteId) ?? "", format: format, model: model)
                #if os(iOS)
                shareURL = try file.writeTemporary()
                #else
                exportFile = file
                showExporter = true
                #endif
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func print() {
        guard let note = model.notes[noteId] else { return }
        ExportService.print(note: note, text: model.editableText(for: noteId) ?? "", model: model)
    }
}

struct IdentifiedURL: Identifiable {
    var url: URL
    var id: String { url.absoluteString }
}

struct Banner<Actions: View>: View {
    var text: String
    var symbol: String
    var tint: Color
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout.weight(.medium))
            Spacer()
            actions.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }
}

struct LockedNoteView: View {
    @Environment(AppModel.self) private var model
    let noteId: String
    @State private var password = ""
    @State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(model.notes[noteId]?.title ?? "Locked Note").font(.title2.weight(.semibold))
            Text("This note is encrypted. Enter your password to read it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock).buttonStyle(.borderedProminent)
            }
            if failed { Text("Incorrect password").foregroundStyle(.red).font(.callout) }
            if model.canUseBiometricUnlock {
                Button {
                    Task { _ = await model.unlockNotesWithBiometrics() }
                } label: {
                    Label("Unlock with \(Biometrics.label)", systemImage: "faceid")
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if model.canUseBiometricUnlock { _ = await model.unlockNotesWithBiometrics() }
        }
    }

    private func unlock() {
        failed = !model.unlockNotes(password: password)
        if !failed { password = "" }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let noteId: String
    let nav: NavigationModel
    let controller: EditorController
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Info").tag(0)
                Text("Contents").tag(1)
                Text("Links").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            if let note = model.notes[noteId] {
                switch tab {
                case 0: info(note)
                case 1: contents(note)
                default: links(note)
                }
            }
        }
    }

    private func info(_ note: Note) -> some View {
        let text = model.editableText(for: noteId) ?? ""
        let stats = TextStats(NoteParser.cleanInline(text))
        return Form {
            Section("Statistics") {
                LabeledContent("Words", value: "\(stats.words)")
                LabeledContent("Characters", value: "\(stats.characters)")
                LabeledContent("Without spaces", value: "\(stats.charactersNoSpaces)")
                LabeledContent("Paragraphs", value: "\(stats.paragraphs)")
                LabeledContent("Read time", value: "\(stats.readingMinutes) min")
                if note.meta.openTodos + note.meta.doneTodos > 0 {
                    LabeledContent("Todos", value: "\(note.meta.doneTodos) of \(note.meta.openTodos + note.meta.doneTodos) done")
                }
            }
            Section("Dates") {
                LabeledContent("Created", value: note.created.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Modified", value: note.modified.formatted(date: .abbreviated, time: .shortened))
            }
            if !note.meta.tags.isEmpty {
                Section("Tags") {
                    ForEach(note.meta.tags, id: \.self) { tag in
                        Button { nav.sidebar = .tag(tag) } label: { Label(tag, systemImage: model.icon(forTag: tag)) }
                            .buttonStyle(.plain)
                    }
                }
            }
            let files = (note.meta.imageIds + note.meta.fileIds).compactMap { model.attachments[$0] }
            if !files.isEmpty {
                Section("Attachments") {
                    ForEach(files) { a in
                        LabeledContent(a.name, value: ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func contents(_ note: Note) -> some View {
        let headings = NoteParser.parse(model.editableText(for: noteId) ?? "").headings
        return List {
            if headings.isEmpty {
                Text("Add headings with # to build a table of contents.").foregroundStyle(.secondary)
            }
            ForEach(headings) { h in
                Button {
                    controller.scroll(toMarkdownLocation: h.location)
                } label: {
                    Text(h.text)
                        .font(h.level == 1 ? .headline : .body)
                        .padding(.leading, CGFloat(h.level - 1) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func links(_ note: Note) -> some View {
        let back = model.backlinks(to: note)
        let out = model.outgoingLinks(from: note)
        return List {
            Section("Backlinks") {
                if back.isEmpty { Text("No notes link here yet.").foregroundStyle(.secondary) }
                ForEach(back) { n in
                    Button { nav.open(n.id) } label: { Label(n.title, systemImage: "arrow.uturn.left") }.buttonStyle(.plain)
                }
            }
            Section("Links in this note") {
                if out.isEmpty { Text("Use [[Note Title]] to link notes.").foregroundStyle(.secondary) }
                ForEach(out, id: \.title) { link in
                    Button {
                        if let target = link.note { nav.open(target.id) } else { nav.open(model.createNote(body: "# \(link.title)\n\n")) }
                    } label: {
                        Label(link.title, systemImage: link.note == nil ? "plus.circle" : "arrow.right")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let noteId: String
    @State private var selection: String?

    var body: some View {
        let revisions = model.revisions(for: noteId)
        NavigationStack {
            HStack(spacing: 0) {
                List(revisions, selection: $selection) { r in
                    VStack(alignment: .leading) {
                        Text(r.date.formatted(date: .abbreviated, time: .shortened))
                        Text(NoteCrypto.isEncrypted(r.text) ? "Encrypted" : NoteParser.parse(r.text).title)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(r.id)
                }
                .frame(minWidth: 200, maxWidth: 260)
                Divider()
                ScrollView {
                    if let r = revisions.first(where: { $0.id == selection }) {
                        Text(NoteCrypto.isEncrypted(r.text) ? "This revision is encrypted." : r.text)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        Text("Select a version to preview it.").foregroundStyle(.secondary).padding()
                    }
                }
            }
            .navigationTitle("Version History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") {
                        if let r = revisions.first(where: { $0.id == selection }) { model.restore(revision: r, of: noteId) }
                        dismiss()
                    }
                    .disabled(selection == nil || selection == revisions.first?.id)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { selection = revisions.dropFirst().first?.id ?? revisions.first?.id }
    }
}
