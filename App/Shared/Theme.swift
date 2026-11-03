import SwiftUI

struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    let isDark: Bool
    let background: String
    let sidebar: String
    let text: String
    let secondary: String
    let accent: String
    let heading: String
    let code: String
    let codeBackground: String
    let highlight: String
    let link: String
    let quote: String

    var backgroundColor: PlatformColor { PlatformColor(hex: background) }
    var textColor: PlatformColor { PlatformColor(hex: text) }
    var secondaryColor: PlatformColor { PlatformColor(hex: secondary) }
    var accentColor: PlatformColor { PlatformColor(hex: accent) }
    var headingColor: PlatformColor { PlatformColor(hex: heading) }
    var codeColor: PlatformColor { PlatformColor(hex: code) }
    var codeBackgroundColor: PlatformColor { PlatformColor(hex: codeBackground) }
    var highlightColor: PlatformColor { PlatformColor(hex: highlight) }
    var linkColor: PlatformColor { PlatformColor(hex: link) }
    var quoteColor: PlatformColor { PlatformColor(hex: quote) }

    var accentSwiftUI: Color { Color(accentColor) }
    var backgroundSwiftUI: Color { Color(backgroundColor) }
    var sidebarSwiftUI: Color { Color(PlatformColor(hex: sidebar)) }
    var textSwiftUI: Color { Color(textColor) }
    var secondarySwiftUI: Color { Color(secondaryColor) }

    static let all: [Theme] = [
        Theme(id: "axolotl", name: "Axolotl", isDark: false, background: "#FFFFFF", sidebar: "#F7F4F6", text: "#2F2B33", secondary: "#9A929D",
              accent: "#E14F78", heading: "#1E1A22", code: "#C2386A", codeBackground: "#F6F2F4", highlight: "#FFEAA6", link: "#D9466F", quote: "#7C7380"),
        Theme(id: "axolotl-night", name: "Axolotl Night", isDark: true, background: "#1C1620", sidebar: "#151018", text: "#E7DFEA", secondary: "#8A7E8F",
              accent: "#FF7A9C", heading: "#FFFFFF", code: "#FFA3BA", codeBackground: "#271E2B", highlight: "#5E4320", link: "#FF8FAD", quote: "#A396A8"),
        Theme(id: "red-graphite", name: "Red Graphite", isDark: false, background: "#FFFFFF", sidebar: "#F4F4F4", text: "#404040", secondary: "#9C9C9C",
              accent: "#DD4C4F", heading: "#2F2F2F", code: "#D0484B", codeBackground: "#F5F5F5", highlight: "#FFF09A", link: "#DD4C4F", quote: "#7A7A7A"),
        Theme(id: "dark-graphite", name: "Dark Graphite", isDark: true, background: "#232325", sidebar: "#1B1B1D", text: "#D9D9D9", secondary: "#7E7E82",
              accent: "#E5605F", heading: "#F2F2F2", code: "#F28B82", codeBackground: "#2E2E31", highlight: "#6B5B1E", link: "#E5605F", quote: "#9A9AA0"),
        Theme(id: "high-contrast", name: "High Contrast", isDark: false, background: "#FFFFFF", sidebar: "#EFEFEF", text: "#000000", secondary: "#5A5A5A",
              accent: "#C8102E", heading: "#000000", code: "#9E0E25", codeBackground: "#EEEEEE", highlight: "#FFE600", link: "#0040C1", quote: "#333333"),
        Theme(id: "charcoal", name: "Charcoal", isDark: true, background: "#1A1A1A", sidebar: "#121212", text: "#CFCFCF", secondary: "#6E6E6E",
              accent: "#F0A04B", heading: "#FFFFFF", code: "#F0A04B", codeBackground: "#262626", highlight: "#5C4B12", link: "#F0A04B", quote: "#8C8C8C"),
        Theme(id: "solarized-light", name: "Solarized Light", isDark: false, background: "#FDF6E3", sidebar: "#EEE8D5", text: "#586E75", secondary: "#93A1A1",
              accent: "#CB4B16", heading: "#073642", code: "#D33682", codeBackground: "#EEE8D5", highlight: "#F5E3A1", link: "#268BD2", quote: "#839496"),
        Theme(id: "solarized-dark", name: "Solarized Dark", isDark: true, background: "#002B36", sidebar: "#00212B", text: "#93A1A1", secondary: "#586E75",
              accent: "#CB4B16", heading: "#EEE8D5", code: "#D33682", codeBackground: "#073642", highlight: "#5B4A00", link: "#268BD2", quote: "#839496"),
        Theme(id: "dracula", name: "Dracula", isDark: true, background: "#282A36", sidebar: "#21222C", text: "#F8F8F2", secondary: "#6272A4",
              accent: "#FF79C6", heading: "#BD93F9", code: "#50FA7B", codeBackground: "#343746", highlight: "#6A5E2A", link: "#8BE9FD", quote: "#9EA8C7"),
        Theme(id: "nord", name: "Nord", isDark: true, background: "#2E3440", sidebar: "#272C36", text: "#D8DEE9", secondary: "#6B7589",
              accent: "#88C0D0", heading: "#ECEFF4", code: "#A3BE8C", codeBackground: "#3B4252", highlight: "#5E5A3A", link: "#81A1C1", quote: "#9AA5B8"),
        Theme(id: "tokyo-night", name: "Tokyo Night", isDark: true, background: "#1A1B26", sidebar: "#16161E", text: "#C0CAF5", secondary: "#565F89",
              accent: "#7AA2F7", heading: "#BB9AF7", code: "#9ECE6A", codeBackground: "#24283B", highlight: "#4F4A2A", link: "#7DCFFF", quote: "#8189AF"),
        Theme(id: "gruvbox", name: "Gruvbox", isDark: true, background: "#282828", sidebar: "#1D2021", text: "#EBDBB2", secondary: "#928374",
              accent: "#FE8019", heading: "#FABD2F", code: "#B8BB26", codeBackground: "#32302F", highlight: "#5F4F1A", link: "#83A598", quote: "#A89984"),
        Theme(id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false, background: "#EFF1F5", sidebar: "#E6E9EF", text: "#4C4F69", secondary: "#9CA0B0",
              accent: "#8839EF", heading: "#1E66F5", code: "#D20F39", codeBackground: "#E6E9EF", highlight: "#F9E2AF", link: "#1E66F5", quote: "#7C7F93"),
        Theme(id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true, background: "#1E1E2E", sidebar: "#181825", text: "#CDD6F4", secondary: "#6C7086",
              accent: "#CBA6F7", heading: "#89B4FA", code: "#F38BA8", codeBackground: "#313244", highlight: "#5A4F2E", link: "#89B4FA", quote: "#9399B2"),
        Theme(id: "everforest", name: "Everforest", isDark: true, background: "#2D353B", sidebar: "#272E33", text: "#D3C6AA", secondary: "#859289",
              accent: "#A7C080", heading: "#DBBC7F", code: "#E69875", codeBackground: "#343F44", highlight: "#5A5430", link: "#7FBBB3", quote: "#9DA9A0"),
        Theme(id: "rose-pine", name: "Rosé Pine", isDark: true, background: "#191724", sidebar: "#1F1D2E", text: "#E0DEF4", secondary: "#6E6A86",
              accent: "#EBBCBA", heading: "#C4A7E7", code: "#F6C177", codeBackground: "#26233A", highlight: "#5A4A33", link: "#9CCFD8", quote: "#908CAA"),
        Theme(id: "rose-pine-dawn", name: "Rosé Pine Dawn", isDark: false, background: "#FAF4ED", sidebar: "#F2E9E1", text: "#575279", secondary: "#9893A5",
              accent: "#D7827E", heading: "#907AA9", code: "#B4637A", codeBackground: "#F2E9E1", highlight: "#F6E1B5", link: "#286983", quote: "#797593"),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
    var label: String {
        switch self {
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .title: return "Title"
        }
    }
}

struct EditorFont: Identifiable, Hashable {
    let id: String
    let name: String
    static let all: [EditorFont] = [
        EditorFont(id: "system", name: "System"),
        EditorFont(id: "serif", name: "New York"),
        EditorFont(id: "rounded", name: "SF Rounded"),
        EditorFont(id: "Avenir Next", name: "Avenir Next"),
        EditorFont(id: "Georgia", name: "Georgia"),
        EditorFont(id: "Charter", name: "Charter"),
        EditorFont(id: "Helvetica Neue", name: "Helvetica Neue"),
        EditorFont(id: "mono", name: "SF Mono"),
        EditorFont(id: "Menlo", name: "Menlo"),
    ]

    func font(size: CGFloat) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size)
        switch id {
        case "system": return base
        case "mono": return .monospaced(size: size)
        case "serif", "rounded":
            #if os(macOS)
            let design: NSFontDescriptor.SystemDesign = id == "serif" ? .serif : .rounded
            #else
            let design: UIFontDescriptor.SystemDesign = id == "serif" ? .serif : .rounded
            #endif
            guard let d = base.fontDescriptor.withDesign(design) else { return base }
            #if os(macOS)
            return NSFont(descriptor: d, size: size) ?? base
            #else
            return UIFont(descriptor: d, size: size)
            #endif
        default:
            return PlatformFont(name: id, size: size) ?? base
        }
    }
}

/// User preferences, persisted in UserDefaults. Device-local by design (not synced).
@MainActor
@Observable
final class AppSettings {
    /// Unit tests run inside the app; give them their own preferences so they never touch the user's.
    private let defaults: UserDefaults = {
        let env = ProcessInfo.processInfo.environment
        guard env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil else { return .standard }
        let suite = UserDefaults(suiteName: "com.nearbycoder.axolotl.tests")!
        suite.removePersistentDomain(forName: "com.nearbycoder.axolotl.tests")
        return suite
    }()

    var lightThemeId: String { didSet { defaults.set(lightThemeId, forKey: "lightTheme") } }
    var darkThemeId: String { didSet { defaults.set(darkThemeId, forKey: "darkTheme") } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var fontId: String { didSet { defaults.set(fontId, forKey: "font") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var lineHeight: Double { didSet { defaults.set(lineHeight, forKey: "lineHeight") } }
    var paragraphSpacing: Double { didSet { defaults.set(paragraphSpacing, forKey: "paragraphSpacing") } }
    var lineWidth: Double { didSet { defaults.set(lineWidth, forKey: "lineWidth") } }
    var typewriterMode: Bool { didSet { defaults.set(typewriterMode, forKey: "typewriter") } }
    var spellCheck: Bool { didSet { defaults.set(spellCheck, forKey: "spellCheck") } }
    var dimMarkdown: Bool { didSet { defaults.set(dimMarkdown, forKey: "dimMarkdown") } }
    var hideMarkdown: Bool { didSet { defaults.set(hideMarkdown, forKey: "hideMarkdown") } }
    var sortOrder: SortOrder { didSet { defaults.set(sortOrder.rawValue, forKey: "sortOrder") } }
    var previewLines: Int { didSet { defaults.set(previewLines, forKey: "previewLines") } }
    var showListImages: Bool { didSet { defaults.set(showListImages, forKey: "showListImages") } }
    var appLock: Bool { didSet { defaults.set(appLock, forKey: "appLock") } }
    var autoLockMinutes: Int { didSet { defaults.set(autoLockMinutes, forKey: "autoLockMinutes") } }
    var keepTagsOnExport: Bool { didSet { defaults.set(keepTagsOnExport, forKey: "keepTagsOnExport") } }
    var biometricUnlock: Bool { didSet { defaults.set(biometricUnlock, forKey: "biometricUnlock") } }
    /// Lets local AI agents and the `axolotl` command line tool talk to the app (macOS).
    var agentAccess: Bool { didSet { defaults.set(agentAccess, forKey: "agentAccess") } }
    /// Lets agents read and edit locked notes while they are unlocked in the app.
    var agentsReadLockedNotes: Bool { didSet { defaults.set(agentsReadLockedNotes, forKey: "agentsReadLockedNotes") } }

    init() {
        defaults.register(defaults: [
            "lightTheme": "axolotl", "darkTheme": "axolotl-night", "appearance": "system", "font": "system",
            "fontSize": 17.0, "lineHeight": 1.35, "paragraphSpacing": 6.0, "lineWidth": 720.0, "typewriter": false,
            "spellCheck": true, "dimMarkdown": true, "hideMarkdown": true, "sortOrder": "modified", "previewLines": 2, "showListImages": true,
            "appLock": false, "autoLockMinutes": 5, "keepTagsOnExport": true, "biometricUnlock": true,
            "agentAccess": true, "agentsReadLockedNotes": false,
        ])
        lightThemeId = defaults.string(forKey: "lightTheme")!
        darkThemeId = defaults.string(forKey: "darkTheme")!
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance")!) ?? .system
        fontId = defaults.string(forKey: "font")!
        fontSize = defaults.double(forKey: "fontSize")
        lineHeight = defaults.double(forKey: "lineHeight")
        paragraphSpacing = defaults.double(forKey: "paragraphSpacing")
        lineWidth = defaults.double(forKey: "lineWidth")
        typewriterMode = defaults.bool(forKey: "typewriter")
        spellCheck = defaults.bool(forKey: "spellCheck")
        dimMarkdown = defaults.bool(forKey: "dimMarkdown")
        hideMarkdown = defaults.bool(forKey: "hideMarkdown")
        sortOrder = SortOrder(rawValue: defaults.string(forKey: "sortOrder")!) ?? .modified
        previewLines = defaults.integer(forKey: "previewLines")
        showListImages = defaults.bool(forKey: "showListImages")
        appLock = defaults.bool(forKey: "appLock")
        autoLockMinutes = defaults.integer(forKey: "autoLockMinutes")
        keepTagsOnExport = defaults.bool(forKey: "keepTagsOnExport")
        biometricUnlock = defaults.bool(forKey: "biometricUnlock")
        agentAccess = defaults.bool(forKey: "agentAccess")
        agentsReadLockedNotes = defaults.bool(forKey: "agentsReadLockedNotes")
    }

    func theme(dark: Bool) -> Theme {
        switch appearance {
        case .light: return Theme.named(lightThemeId)
        case .dark: return Theme.named(darkThemeId)
        case .system: return Theme.named(dark ? darkThemeId : lightThemeId)
        }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var editorFont: EditorFont { EditorFont.all.first { $0.id == fontId } ?? EditorFont.all[0] }
}
