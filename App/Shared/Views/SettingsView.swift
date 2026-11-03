import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import AxolotlKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(macOS)
        TabView {
            Form { GeneralSettings() }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form { AppearanceSettings() }.formStyle(.grouped).tabItem { Label("Appearance", systemImage: "paintpalette") }
            Form { SyncSettings() }.formStyle(.grouped).tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            Form { SecuritySettings() }.formStyle(.grouped).tabItem { Label("Security", systemImage: "lock") }
            Form { DataSettings(); AboutSection() }.formStyle(.grouped).tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 560)
        #else
        Form {
            Section {
                NavigationLink { Form { AppearanceSettings() }.navigationTitle("Appearance") } label: { Label("Appearance", systemImage: "paintpalette") }
                NavigationLink { Form { SyncSettings() }.navigationTitle("Sync") } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                NavigationLink { Form { SecuritySettings() }.navigationTitle("Security") } label: { Label("Security", systemImage: "lock") }
                NavigationLink { Form { DataSettings() }.navigationTitle("Import & Export") } label: { Label("Import & Export", systemImage: "externaldrive") }
            }
            GeneralSettings()
            AboutSection()
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { DismissButton() }
        }
        #endif
    }
}

private struct DismissButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button("Done") { dismiss() } }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Section("Note List") {
            Picker("Sort notes by", selection: $s.sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
            Stepper("Preview lines: \(s.previewLines)", value: $s.previewLines, in: 0...4)
            Toggle("Show image thumbnails", isOn: $s.showListImages)
        }
        Section {
            Toggle("Typewriter mode", isOn: $s.typewriterMode)
            Toggle("Check spelling", isOn: $s.spellCheck)
            Toggle("Hide Markdown syntax", isOn: $s.hideMarkdown)
            Toggle("Dim Markdown markers", isOn: $s.dimMarkdown)
        } header: {
            Text("Editor")
        } footer: {
            Text("With syntax hidden, Markdown characters like ** and # appear only on the line you're editing.")
        }
    }
}

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Section("Theme") {
            Picker("Appearance", selection: $s.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            ThemeGrid(title: "Light theme", themes: Theme.all.filter { !$0.isDark }, selection: $s.lightThemeId)
            ThemeGrid(title: "Dark theme", themes: Theme.all.filter { $0.isDark }, selection: $s.darkThemeId)
        }
        Section("Typography") {
            Picker("Font", selection: $s.fontId) {
                ForEach(EditorFont.all) { f in Text(f.name).tag(f.id) }
            }
            LabeledSlider(title: "Font size", value: $s.fontSize, range: 12...28, step: 1, format: { "\(Int($0)) pt" })
            LabeledSlider(title: "Line height", value: $s.lineHeight, range: 1.0...2.0, step: 0.05, format: { String(format: "%.2f×", $0) })
            LabeledSlider(title: "Paragraph spacing", value: $s.paragraphSpacing, range: 0...24, step: 1, format: { "\(Int($0)) pt" })
            LabeledSlider(title: "Line width", value: $s.lineWidth, range: 480...1400, step: 20, format: { "\(Int($0)) pt" })
        }
    }
}

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct ThemeGrid: View {
    var title: String
    var themes: [Theme]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(themes) { theme in
                    Button { selection = theme.id } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Aa").font(.system(size: 18, weight: .bold)).foregroundStyle(Color(theme.headingColor))
                            HStack(spacing: 3) {
                                Circle().fill(theme.accentSwiftUI).frame(width: 8, height: 8)
                                Capsule().fill(theme.textSwiftUI.opacity(0.5)).frame(height: 4)
                            }
                            Capsule().fill(theme.secondarySwiftUI.opacity(0.6)).frame(width: 40, height: 4)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(theme.backgroundSwiftUI))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selection == theme.id ? theme.accentSwiftUI : Color.secondary.opacity(0.25),
                                                                                  lineWidth: selection == theme.id ? 2.5 : 1))
                        .overlay(alignment: .bottomTrailing) {
                            Text(theme.name).font(.system(size: 8, weight: .medium)).foregroundStyle(theme.secondarySwiftUI).padding(5)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.name)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct SyncSettings: View {
    @Environment(AppModel.self) private var model
    @State private var joinCode = ""
    @State private var server = ""
    @State private var revealCode = false
    @State private var confirmLeave = false
    @State private var joinFailed = false
    @State private var showScanner = false

    var body: some View {
        let sync = model.sync
        if let keys = sync.keys {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    if let qr = QRCode.image(for: keys.code) {
                        Image(platformImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                            .blur(radius: revealCode ? 0 : 6)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(revealCode ? keys.code : String(keys.code.prefix(8)) + "-••••-••••-••••-••••-••••-••••-••••")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        HStack {
                            Button(revealCode ? "Hide" : "Reveal") { revealCode.toggle() }
                            Button("Copy") { copyToPasteboard(keys.code) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Sync code")
            } footer: {
                Text("Enter or scan this code on your other devices. It is the encryption key for your notes: anyone with it can read them, so keep it private.")
            }

            Section {
                Toggle("Sync with nearby devices", isOn: Binding(get: { sync.lanEnabled }, set: { sync.setLANEnabled($0) }))
                if sync.lanEnabled {
                    if sync.peers.isEmpty {
                        Label("Looking for devices on this network…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                    }
                    ForEach(sync.peers) { peer in
                        LabeledContent {
                            Text(peer.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "Connected").foregroundStyle(.secondary)
                        } label: {
                            Label(peer.name, systemImage: "laptopcomputer.and.iphone")
                        }
                    }
                }
            } header: {
                Text("Local network")
            } footer: {
                Text("Devices with the same sync code on the same Wi-Fi sync directly with each other, end to end encrypted, with no server.")
            }

            Section {
                HStack {
                    TextField("https://sync.example.com", text: $server)
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit { sync.setServer(server) }
                    Button("Save") { sync.setServer(server) }
                        .disabled(server == (sync.serverURL?.absoluteString ?? ""))
                }
                LabeledContent("Status") { serverStatus(sync.serverState) }
                if sync.serverURL != nil && sync.pendingChanges > 0 { LabeledContent("Waiting to upload", value: "\(sync.pendingChanges)") }
                if let last = sync.lastSync { LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .standard)) }
                Button("Sync Now") { sync.syncNow() }
            } header: {
                Text("Sync server (optional)")
            } footer: {
                Text("A sync server relays encrypted changes when your devices are not on the same network. Run your own with the open-source axolotl-sync server; it only ever sees ciphertext.")
            }
            .onAppear { server = sync.serverURL?.absoluteString ?? "" }

            Section {
                Button("Stop Syncing This Device", role: .destructive) { confirmLeave = true }
            }
            .confirmationDialog("Stop syncing?", isPresented: $confirmLeave) {
                Button("Stop Syncing", role: .destructive) { sync.leaveVault() }
            } message: {
                Text("Notes stay on this device. You can join again with your sync code.")
            }
        } else {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sync is off", systemImage: "icloud.slash").font(.headline)
                    Text("Axolotl syncs end to end encrypted, directly between your devices on the same network and, optionally, through a sync server you run.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Button("Start Syncing on This Device") { sync.createVault() }
                    .buttonStyle(.borderedProminent)
            } header: {
                Text("New")
            } footer: {
                Text("Creates a sync code you then enter on your other devices.")
            }
            Section {
                TextField("AXO-XXXX-XXXX-…", text: $joinCode)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                HStack {
                    Button("Join") { joinFailed = !sync.join(code: joinCode) }
                        .disabled(joinCode.count < 20)
                    #if os(iOS)
                    if QRScannerView.isSupported {
                        Button("Scan QR Code", systemImage: "qrcode.viewfinder") { showScanner = true }
                    }
                    #endif
                }
                if joinFailed { Text("That doesn't look like a valid sync code.").foregroundStyle(.red) }
            } header: {
                Text("Already using Axolotl on another device?")
            } footer: {
                Text("Find the code in Settings → Sync on that device.")
            }
            #if os(iOS)
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    joinCode = code
                    joinFailed = !sync.join(code: code)
                }
                .ignoresSafeArea()
            }
            #endif
        }
    }

    @ViewBuilder
    private func serverStatus(_ state: SyncManager.ServerState) -> some View {
        switch state {
        case .notConfigured: Text("Not configured").foregroundStyle(.secondary)
        case .connecting: Text("Connecting…").foregroundStyle(.secondary)
        case .connected: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .error(let message): Text(message).foregroundStyle(.orange).lineLimit(2)
        }
    }
}

struct SecuritySettings: View {
    @Environment(AppModel.self) private var model
    @State private var showPassword = false

    var body: some View {
        @Bindable var s = model.settings
        Section {
            Toggle("Require \(Biometrics.label) to open", isOn: $s.appLock)
            if s.appLock {
                Picker("Lock after", selection: $s.autoLockMinutes) {
                    Text("Immediately").tag(0)
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("1 hour").tag(60)
                }
            }
        } header: {
            Text("App lock")
        }
        Section {
            if model.encryptionConfigured {
                LabeledContent("Encryption password", value: "Set")
                if model.encryptionKey != nil {
                    Button("Lock Notes Now") { model.relockNotes() }
                }
            } else {
                Button("Set Encryption Password…") { showPassword = true }
            }
        } header: {
            Text("Locked notes")
        } footer: {
            Text("Locked notes are encrypted with AES-256-GCM before they are stored or synced. The password is shared by all your devices.")
        }
        .sheet(isPresented: $showPassword) {
            PasswordSetupView { model.setEncryptionPassword($0) }
        }
    }
}

struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var imported: Int?
    @State private var exportURL: URL?
    @State private var showExporter = false

    var body: some View {
        Section {
            Button("Import Markdown, Text or TextBundle…", systemImage: "square.and.arrow.down") { importing = true }
            if let imported { Text("Imported \(imported) note\(imported == 1 ? "" : "s").").foregroundStyle(.secondary) }
            Button("Export All Notes…", systemImage: "square.and.arrow.up") {
                do {
                    exportURL = try ExportService.exportAll(model: model)
                    showExporter = true
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            }
            Toggle("Keep tags when exporting", isOn: Binding(get: { model.settings.keepTagsOnExport }, set: { model.settings.keepTagsOnExport = $0 }))
        } header: {
            Text("Import & export")
        } footer: {
            Text("Exports a .zip of Markdown files with an assets folder. Imports work with Bear, Obsidian, Ulysses and other Markdown apps.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ImportService.types, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { imported = ImportService.importFiles(urls, into: model) }
        }
        #if os(iOS)
        .sheet(isPresented: $showExporter) {
            if let exportURL { ActivityView(items: [exportURL]).ignoresSafeArea() }
        }
        #else
        .fileExporter(isPresented: $showExporter, document: exportURL.flatMap { try? FileWrapper(url: $0) }.map {
            ExportFile(wrapper: $0, contentType: .zip, filename: exportURL?.lastPathComponent ?? "Axolotl.zip")
        }, contentType: .zip, defaultFilename: exportURL?.lastPathComponent) { _ in }
        #endif
    }
}

struct AboutSection: View {
    var body: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            Link("Website", destination: URL(string: "https://nearbycoder.github.io/axolotl/")!)
            Link("Source code & sync server", destination: URL(string: "https://github.com/nearbycoder/axolotl")!)
        }
    }
}

enum QRCode {
    static func image(for string: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width / 2, height: output.extent.height / 2))
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}
