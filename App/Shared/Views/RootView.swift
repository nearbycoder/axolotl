import SwiftUI
import AxolotlKit

/// Per-window navigation state.
@MainActor
@Observable
final class NavigationModel {
    var sidebar: SidebarItem? = .notes
    var selectedNoteId: String?
    var search = ""
    var columnVisibility: NavigationSplitViewVisibility = .all
    var showInspector = false
    var showQuickOpen = false
    var showSettings = false
    var showHistory = false
    var showPasswordSetup = false
    var showUnlockPrompt = false
    var pendingLockNoteId: String?
    var focusNewNote = false

    func open(_ noteId: String) {
        selectedNoteId = noteId
    }
}

struct NavigationKey: FocusedValueKey { typealias Value = NavigationModel }
struct EditorControllerKey: FocusedValueKey { typealias Value = EditorController }

extension FocusedValues {
    var navigation: NavigationModel? {
        get { self[NavigationKey.self] }
        set { self[NavigationKey.self] = newValue }
    }
    var editorController: EditorController? {
        get { self[EditorControllerKey.self] }
        set { self[EditorControllerKey.self] = newValue }
    }
}

extension AppModel {
    func theme(for scheme: ColorScheme) -> Theme { settings.theme(dark: scheme == .dark) }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var nav = NavigationModel()

    private var restoresSelection: Bool {
        #if os(iOS)
        return sizeClass == .regular
        #else
        return true
        #endif
    }

    var body: some View {
        @Bindable var nav = nav
        let theme = model.theme(for: scheme)
        NavigationSplitView(columnVisibility: $nav.columnVisibility) {
            SidebarView(nav: nav)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            NoteListView(nav: nav)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            NoteDetailView(nav: nav)
        }
        .tint(theme.accentSwiftUI)
        .overlay {
            if model.isAppLocked { LockScreen() }
        }
        .sheet(isPresented: $nav.showQuickOpen) {
            QuickOpenView(nav: nav)
        }
        .sheet(isPresented: $nav.showPasswordSetup) {
            PasswordSetupView { password in
                model.setEncryptionPassword(password)
                if let id = nav.pendingLockNoteId { model.encrypt(id) }
                nav.pendingLockNoteId = nil
            }
        }
        .sheet(isPresented: $nav.showUnlockPrompt) {
            UnlockPromptView { password in
                guard model.unlockNotes(password: password) else { return false }
                if let id = nav.pendingLockNoteId { model.encrypt(id) }
                nav.pendingLockNoteId = nil
                return true
            }
        }
        #if os(iOS)
        .sheet(isPresented: $nav.showSettings) {
            NavigationStack { SettingsView() }
        }
        #endif
        .onChange(of: model.navigationRequest) { _, request in
            guard let request else { return }
            if let s = request.sidebar { nav.sidebar = s }
            if let search = request.search { nav.search = search }
            if let id = request.noteId { nav.open(id) }
            model.navigationRequest = nil
        }
        .focusedSceneValue(\.navigation, nav)
        .onAppear {
            // Reopen the last note on wide layouts, like Bear.
            guard restoresSelection, nav.selectedNoteId == nil else { return }
            let last = UserDefaults.standard.string(forKey: "lastNoteId")
            if let last, let note = model.notes[last], !note.deleted, !note.isTrashed {
                nav.selectedNoteId = last
            } else {
                nav.selectedNoteId = model.notes(for: .notes, search: "", sort: model.settings.sortOrder).first?.id
            }
        }
        .onChange(of: nav.selectedNoteId) { _, id in
            if let id { UserDefaults.standard.set(id, forKey: "lastNoteId") }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct NoteDetailView: View {
    @Environment(AppModel.self) private var model
    let nav: NavigationModel

    var body: some View {
        if let id = nav.selectedNoteId, let note = model.notes[id], !note.deleted {
            EditorScreen(noteId: id, nav: nav)
                .id(id)
        } else {
            ContentUnavailableView {
                Label("No Note Selected", systemImage: "note.text")
            } description: {
                Text("Choose a note, or create a new one.")
            } actions: {
                Button("New Note") {
                    nav.open(model.createNote(in: nav.sidebar))
                    nav.focusNewNote = true
                }
            }
        }
    }
}

/// Covers the app until the user authenticates.
struct LockScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                AppGlyph(size: 84)
                Text("Axolotl is locked").font(.title2.weight(.semibold))
                Button {
                    Task { await model.unlockApp() }
                } label: {
                    Label("Unlock with \(Biometrics.label)", systemImage: "lock.open")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .task { await model.unlockApp() }
    }
}

/// The app icon drawn in SwiftUI for in-app use.
struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        Image("Glyph")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: size * 0.08, y: size * 0.03)
    }
}

struct PasswordSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    var onSave: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                    SecureField("Confirm password", text: $confirm)
                } header: {
                    Text("Encryption password")
                } footer: {
                    Text("Locked notes are encrypted on this device with AES-256 using a key derived from this password. It is shared by all your devices and cannot be recovered if you forget it.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Set Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(password)
                        dismiss()
                    }
                    .disabled(password.count < 4 || password != confirm)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 280)
    }
}

struct UnlockPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var failed = false
    var onUnlock: (String) -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Encryption password", text: $password)
                        .onSubmit(submit)
                } footer: {
                    Text(failed ? "That password is not correct." : "Enter the password you use for locked notes.")
                        .foregroundStyle(failed ? .red : .secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Unlock Notes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Unlock", action: submit).disabled(password.isEmpty) }
            }
        }
        .frame(minWidth: 340, minHeight: 200)
    }

    private func submit() {
        if onUnlock(password) { dismiss() } else { failed = true }
    }
}
