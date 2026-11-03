import SwiftUI
import UniformTypeIdentifiers
import AxolotlKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown, text, textbundle, html, pdf, rtf, docx

    var id: String { rawValue }

    var label: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .text: return "Plain Text (.txt)"
        case .textbundle: return "TextBundle"
        case .html: return "HTML"
        case .pdf: return "PDF"
        case .rtf: return "Rich Text (.rtf)"
        case .docx: return "Word (.docx)"
        }
    }

    var symbol: String {
        switch self {
        case .markdown: return "number.square"
        case .text: return "doc.plaintext"
        case .textbundle: return "shippingbox"
        case .html: return "globe"
        case .pdf: return "doc.richtext"
        case .rtf: return "doc.text"
        case .docx: return "doc"
        }
    }

    var ext: String {
        switch self {
        case .markdown: return "md"
        case .text: return "txt"
        case .textbundle: return "textbundle"
        case .html: return "html"
        case .pdf: return "pdf"
        case .rtf: return "rtf"
        case .docx: return "docx"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: return UTType("net.daringfireball.markdown") ?? .plainText
        case .text: return .plainText
        case .textbundle: return UTType("org.textbundle.package") ?? .package
        case .html: return .html
        case .pdf: return .pdf
        case .rtf: return .rtf
        case .docx: return UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        }
    }

    static var available: [ExportFormat] {
        #if os(macOS)
        return allCases
        #else
        return allCases.filter { $0 != .docx }
        #endif
    }
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var wrapper: FileWrapper
    var contentType: UTType
    var filename: String

    init(wrapper: FileWrapper, contentType: UTType, filename: String) {
        self.wrapper = wrapper
        self.contentType = contentType
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { wrapper }

    func writeTemporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }
}

@MainActor
enum ExportService {
    static func filename(for note: Note) -> String {
        let base = note.title.isEmpty ? "Untitled" : note.title
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined(separator: "-")
        return String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    static func prepare(_ text: String, note: Note, model: AppModel) -> String {
        guard !model.settings.keepTagsOnExport else { return text }
        var out = text
        for tag in note.meta.tags { out = AppModel.replacingTag(tag, with: nil, in: out) }
        return out
    }

    static func html(for note: Note, text: String, model: AppModel, embedImages: Bool = true) -> String {
        var renderer = MarkdownHTML()
        renderer.keepTags = model.settings.keepTagsOnExport
        renderer.attachmentURL = { id in
            guard embedImages, let a = model.attachments[id], let data = model.attachmentData(id) else { return nil }
            return "data:\(a.mime);base64,\(data.base64EncodedString())"
        }
        renderer.wikiLinkURL = { title in model.note(titled: title).map { AppModel.link(for: $0.id) } }
        return renderer.document(title: note.title, body: text)
    }

    static func attributed(fromHTML html: String) throws -> NSAttributedString {
        try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                                  .characterEncoding: String.Encoding.utf8.rawValue],
                               documentAttributes: nil)
    }

    static func export(note: Note, text raw: String, format: ExportFormat, model: AppModel) async throws -> ExportFile {
        let text = prepare(raw, note: note, model: model)
        let name = filename(for: note) + "." + format.ext
        func file(_ data: Data) -> ExportFile {
            let w = FileWrapper(regularFileWithContents: data)
            w.preferredFilename = name
            return ExportFile(wrapper: w, contentType: format.contentType, filename: name)
        }
        switch format {
        case .markdown:
            return file(Data(rewriteAttachments(text, model: model) { a in a.name }.utf8))
        case .text:
            return file(Data(try attributed(fromHTML: html(for: note, text: text, model: model, embedImages: false)).string.utf8))
        case .html:
            return file(Data(html(for: note, text: text, model: model).utf8))
        case .rtf:
            let attr = try attributed(fromHTML: html(for: note, text: text, model: model, embedImages: false))
            return file(try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        case .docx:
            #if os(macOS)
            let attr = try attributed(fromHTML: html(for: note, text: text, model: model, embedImages: false))
            return file(try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]))
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        case .pdf:
            return file(try pdf(html: html(for: note, text: text, model: model)))
        case .textbundle:
            return ExportFile(wrapper: textBundle(note: note, text: text, model: model), contentType: format.contentType, filename: name)
        }
    }

    /// Rewrites `attachment:ID` references using `path(for:)`.
    static func rewriteAttachments(_ text: String, model: AppModel, path: (Attachment) -> String) -> String {
        let ns = text as NSString
        var out = text
        for m in MarkdownSyntax.attachmentRef.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let id = ns.substring(with: m.range(at: 3))
            guard let a = model.attachments[id] else { continue }
            let encoded = path(a).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path(a)
            let replacement = "\(ns.substring(with: m.range(at: 1)))[\(ns.substring(with: m.range(at: 2)))](\(encoded))"
            out = (out as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return out
    }

    static func textBundle(note: Note, text: String, model: AppModel) -> FileWrapper {
        var assets: [String: FileWrapper] = [:]
        var names: [String: String] = [:]
        let rewritten = rewriteAttachments(text, model: model) { a in
            if let n = names[a.id] { return "assets/\(n)" }
            var n = a.name.isEmpty ? a.id : a.name
            var i = 2
            while assets[n] != nil {
                n = "\((a.name as NSString).deletingPathExtension) \(i).\((a.name as NSString).pathExtension)"
                i += 1
            }
            names[a.id] = n
            if let data = model.attachmentData(a.id) {
                let w = FileWrapper(regularFileWithContents: data)
                w.preferredFilename = n
                assets[n] = w
            }
            return "assets/\(n)"
        }
        let info = #"{"version":2,"type":"net.daringfireball.markdown","transient":false,"creatorIdentifier":"com.nearbycoder.axolotl"}"#
        var children: [String: FileWrapper] = [
            "text.markdown": FileWrapper(regularFileWithContents: Data(rewritten.utf8)),
            "info.json": FileWrapper(regularFileWithContents: Data(info.utf8)),
        ]
        if !assets.isEmpty { children["assets"] = FileWrapper(directoryWithFileWrappers: assets) }
        let bundle = FileWrapper(directoryWithFileWrappers: children)
        bundle.preferredFilename = filename(for: note) + ".textbundle"
        return bundle
    }

    static func pdf(html: String) throws -> Data {
        #if os(macOS)
        let attr = try attributed(fromHTML: html)
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.topMargin = 54; printInfo.bottomMargin = 54; printInfo.leftMargin = 54; printInfo.rightMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(attr)
        view.sizeToFit()
        if let lm = view.layoutManager, let tc = view.textContainer {
            lm.ensureLayout(for: tc)
            view.frame.size.height = lm.usedRect(for: tc).height + 20
        }
        let data = NSMutableData()
        let op = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: data, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
        #else
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 54, dy: 54), forKey: "printableRect")
        let pdf = UIGraphicsPDFRenderer(bounds: page)
        return pdf.pdfData { ctx in
            renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
            for i in 0..<renderer.numberOfPages {
                ctx.beginPage()
                renderer.drawPage(at: i, in: ctx.pdfContextBounds)
            }
        }
        #endif
    }

    static func print(note: Note, text: String, model: AppModel) {
        let html = html(for: note, text: prepare(text, note: note, model: model), model: model)
        #if os(macOS)
        guard let attr = try? attributed(fromHTML: html) else { return }
        let info = NSPrintInfo.shared
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: info.paperSize.width - info.leftMargin - info.rightMargin, height: 100))
        view.textStorage?.setAttributedString(attr)
        view.sizeToFit()
        NSPrintOperation(view: view, printInfo: info).run()
        #else
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = note.title
        info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
        controller.present(animated: true)
        #endif
    }

    /// Exports every live note as Markdown plus attachments, zipped.
    static func exportAll(model: AppModel) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Axolotl Export \(Date().formatted(.iso8601.year().month().day()))", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        var used = Set<String>()
        for note in model.liveNotes where !note.isTrashed {
            guard let text = model.editableText(for: note.id) else { continue }
            var name = filename(for: note)
            var i = 2
            while used.contains(name.lowercased()) { name = "\(filename(for: note)) \(i)"; i += 1 }
            used.insert(name.lowercased())
            let rewritten = rewriteAttachments(text, model: model) { a in
                let fileName = "\(a.id.prefix(8))-\(a.name)"
                if let data = model.attachmentData(a.id) { try? data.write(to: assets.appendingPathComponent(fileName)) }
                return "assets/\(fileName)"
            }
            let url = root.appendingPathComponent(name + ".md")
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.creationDate: note.created, .modificationDate: note.modified], ofItemAtPath: url.path)
        }
        var zipURL: URL?
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordError) { tmp in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(root.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: tmp, to: dest); zipURL = dest } catch { copyError = error }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        guard let zipURL else { throw CocoaError(.fileWriteUnknown) }
        return zipURL
    }
}

@MainActor
enum ImportService {
    static let types: [UTType] = [.plainText, UTType("net.daringfireball.markdown") ?? .plainText, UTType("org.textbundle.package") ?? .package,
                                  UTType(filenameExtension: "bearnote") ?? .package, .folder]

    /// Imports Markdown, text and TextBundle files. Returns the number of notes created.
    @discardableResult
    static func importFiles(_ urls: [URL], into model: AppModel) -> Int {
        var count = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            count += importItem(url, into: model)
        }
        return count
    }

    private static func importItem(_ url: URL, into model: AppModel) -> Int {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let ext = url.pathExtension.lowercased()
        if isDir.boolValue && ext != "textbundle" && ext != "bearnote" {
            let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return children.filter { ["md", "markdown", "txt", "textbundle", "bearnote"].contains($0.pathExtension.lowercased()) }
                .reduce(0) { $0 + importItem($1, into: model) }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = attrs?[.creationDate] as? Date ?? Date()
        if ext == "textbundle" || ext == "bearnote" {
            let textURL = ["text.markdown", "text.md", "text.txt"].map { url.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
            guard let textURL, var text = try? String(contentsOf: textURL, encoding: .utf8) else { return 0 }
            let id = model.replica.createNote(body: "", created: created)
            let ns = text as NSString
            for m in MarkdownSyntax.image.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let path = ns.substring(with: m.range(at: 2)).removingPercentEncoding ?? ""
                // Only files inside the bundle's assets folder; a crafted bundle must not read anything else.
                let assets = url.standardizedFileURL.appendingPathComponent("assets", isDirectory: true).path + "/"
                let fileURL = url.appendingPathComponent(path).standardizedFileURL
                guard path.hasPrefix("assets/"), !path.contains(".."), fileURL.path.hasPrefix(assets),
                      let data = try? Data(contentsOf: fileURL) else { continue }
                let name = (path as NSString).lastPathComponent
                if let snippet = model.addFiles([(data, name, UTTypeHelper.mime(forExtension: (name as NSString).pathExtension))], to: id).first {
                    text = (text as NSString).replacingCharacters(in: m.range, with: snippet)
                }
            }
            model.replica.updateBody(id, text)
            return 1
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var body = text
        let title = url.deletingPathExtension().lastPathComponent
        if NoteParser.parse(text).title.isEmpty || !text.hasPrefix("#") && NoteParser.parse(text).title != title {
            body = "# \(title)\n\n" + text
        }
        model.replica.createNote(body: body, created: created)
        return 1
    }
}
