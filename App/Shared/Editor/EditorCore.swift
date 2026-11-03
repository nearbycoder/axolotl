import Foundation
import AxolotlKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias TextStorageEditActions = NSTextStorageEditActions
#else
typealias TextStorageEditActions = NSTextStorage.EditActions
#endif

/// Restyles Markdown as the text storage is edited.
///
/// A delegate on a plain `NSTextStorage` rather than a subclass: a Swift subclass pays
/// Objective-C bridging on every attribute lookup, which made layout of long notes about
/// 45× slower and every keystroke several times slower.
final class MarkdownStorageDelegate: NSObject, NSTextStorageDelegate {
    var style: EditorStyle
    /// Fenced-block count after the last pass; nil until the first pass.
    private var fenceCount: Int?
    /// Set while a document is loaded, so the bulk replacement is styled once by `rehighlight`.
    var suspended = false

    init(style: EditorStyle) {
        self.style = style
        super.init()
    }

    /// Styles the edited paragraphs inside the storage's own processing pass. TextKit allows
    /// attribute changes here ("delegates can change the characters or attributes"), and doing
    /// the work in this pass means the layout manager is invalidated once per keystroke rather
    /// than once for the characters and again for the attributes.
    func textStorage(_ storage: NSTextStorage, willProcessEditing editedMask: TextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard !suspended, editedMask.contains(.editedCharacters) else { return }
        let text = Self.snapshot(storage)
        guard text.length > 0 else { return }
        let fences = MarkdownSyntax.fencedBlocks(in: text)
        let location = min(editedRange.location, text.length)
        var range = text.paragraphRange(for: NSRange(location: location, length: min(editedRange.length, text.length - location)))
        let paragraph = text.substring(with: range)
        if let known = fenceCount, known != fences.count || paragraph.contains("```") || paragraph.contains("~~~") {
            range = NSRange(location: 0, length: text.length)
        } else {
            for f in fences where NSIntersectionRange(f, range).length > 0 || NSLocationInRange(range.location, f) {
                range = NSUnionRange(range, f)
            }
            // Callout colouring flows down a quote block, so restyle the whole block.
            range = Self.quoteBlock(around: range, in: text)
        }
        fenceCount = fences.count
        if range.length > 0 {
            MarkdownHighlighter.highlight(storage, range: range, style: style, fencedBlocks: fences, text: text)
        }
    }

    func rehighlight(_ storage: NSTextStorage) {
        guard storage.length > 0 else { return }
        let text = Self.snapshot(storage)
        let fences = MarkdownSyntax.fencedBlocks(in: text)
        fenceCount = fences.count
        storage.beginEditing()
        MarkdownHighlighter.highlight(storage, range: NSRange(location: 0, length: storage.length), style: style, fencedBlocks: fences, text: text)
        storage.endEditing()
    }

    /// A real Foundation string. Regexes over a bridged Swift string re-transcode the whole
    /// document on every call; one memcpy here makes every match afterwards cheap.
    static func snapshot(_ storage: NSMutableAttributedString) -> NSString {
        storage.mutableString.copy() as! NSString
    }

    /// Extends `range` to the contiguous run of `>` paragraphs around it.
    static func quoteBlock(around range: NSRange, in text: NSString) -> NSRange {
        func isQuote(_ r: NSRange) -> Bool { text.substring(with: r).trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        guard isQuote(range) else { return range }
        var result = range
        while result.location > 0 {
            let prev = text.paragraphRange(for: NSRange(location: result.location - 1, length: 0))
            guard isQuote(prev) else { break }
            result = NSUnionRange(result, prev)
        }
        while NSMaxRange(result) < text.length {
            let next = text.paragraphRange(for: NSRange(location: NSMaxRange(result), length: 0))
            guard isQuote(next) else { break }
            result = NSUnionRange(result, next)
        }
        return result
    }
}

/// Hides Markdown syntax glyphs outside the paragraph being edited.
final class MarkupHider: NSObject, NSLayoutManagerDelegate {
    /// Character range shown with full syntax (the caret's paragraph), or NSNotFound.
    var revealed = NSRange(location: NSNotFound, length: 0)

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: PlatformFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        // Look at attribute runs once per glyph run instead of one lookup per character.
        let first = charIndexes[0], last = charIndexes[glyphRange.length - 1]
        let span = NSIntersectionRange(NSRange(location: first, length: max(1, last - first + 1)), NSRange(location: 0, length: storage.length))
        guard span.length > 0 else { return 0 }
        var hidden: [NSRange] = []
        storage.enumerateAttribute(.axHidden, in: span, options: .longestEffectiveRangeNotRequired) { value, r, _ in
            guard value != nil else { return }
            guard revealed.location != NSNotFound else { hidden.append(r); return }
            let shown = NSIntersectionRange(r, revealed)
            guard shown.length > 0 else { hidden.append(r); return }
            if r.location < shown.location { hidden.append(NSRange(location: r.location, length: shown.location - r.location)) }
            if NSMaxRange(shown) < NSMaxRange(r) { hidden.append(NSRange(location: NSMaxRange(shown), length: NSMaxRange(r) - NSMaxRange(shown))) }
        }
        guard !hidden.isEmpty else { return 0 }
        var changed = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            if hidden.contains(where: { NSLocationInRange(ci, $0) }) { changed[i] = .null }
        }
        changed.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }
}

/// Inline image that scales to the text column.
final class ImageAttachment: NSTextAttachment {
    var attachmentId = ""
    var maxHeight: CGFloat = 520

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        guard let image else { return CGRect(x: 0, y: 0, width: 240, height: 140) }
        let padding = (textContainer?.lineFragmentPadding ?? 5) * 2
        let maxWidth = max(40, lineFrag.width - padding)
        var size = image.size
        if size.width > maxWidth {
            size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }
        if size.height > maxHeight {
            size = CGSize(width: size.width * maxHeight / size.height, height: maxHeight)
        }
        return CGRect(origin: .zero, size: size)
    }
}

/// Draws checkboxes, bullets, code block and quote backgrounds, rules, inline code and tag pills.
final class MarkdownLayoutManager: NSLayoutManager {
    var style: EditorStyle

    init(style: EditorStyle) {
        self.style = style
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var context: CGContext? {
        #if os(macOS)
        return NSGraphicsContext.current?.cgContext
        #else
        return UIGraphicsGetCurrentContext()
        #endif
    }

    private func lineRects(for charRange: NSRange, in container: NSTextContainer) -> [CGRect] {
        var rects: [CGRect] = []
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in rects.append(rect) }
        return rects
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let ctx = context, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let padding = container.lineFragmentPadding
        let full = NSRange(location: 0, length: storage.length)

        ctx.saveGState()
        defer { ctx.restoreGState() }

        var handledBlocks = Set<Int>()
        storage.enumerateAttribute(.axCodeBlock, in: charRange) { value, range, _ in
            guard value != nil else { return }
            var block = NSRange()
            _ = storage.attribute(.axCodeBlock, at: range.location, longestEffectiveRange: &block, in: full)
            guard handledBlocks.insert(block.location).inserted else { return }
            let rects = lineRects(for: block, in: container)
            guard let first = rects.first, let last = rects.last else { return }
            let box = CGRect(x: origin.x + first.minX + padding, y: origin.y + first.minY,
                             width: first.width - padding * 2, height: last.maxY - first.minY).insetBy(dx: 0, dy: 1)
            ctx.setFillColor(style.codeBackgroundColor.cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
        }

        var handledQuotes = Set<Int>()
        storage.enumerateAttribute(.axQuote, in: charRange) { value, range, _ in
            guard let color = value as? PlatformColor else { return }
            // One continuous bar per quote block, spanning paragraph spacing between its lines.
            var block = NSRange()
            _ = storage.attribute(.axQuote, at: range.location, longestEffectiveRange: &block, in: full)
            guard handledQuotes.insert(block.location).inserted else { return }
            let rects = lineRects(for: block, in: container)
            guard let first = rects.first, let last = rects.last else { return }
            let bottom = last.maxY - ((storage.attribute(.paragraphStyle, at: max(block.location, NSMaxRange(block) - 1), effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? 0)
            let bar = CGRect(x: origin.x + first.minX + padding + 2, y: origin.y + first.minY + 3, width: 3, height: max(4, bottom - first.minY - 6))
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
        }

        storage.enumerateAttribute(.axRule, in: charRange) { value, range, _ in
            guard value != nil else { return }
            for r in lineRects(for: range, in: container) {
                ctx.setFillColor(style.secondaryColor.withAlpha(0.35).cgColor)
                ctx.fill(CGRect(x: origin.x + r.minX + padding, y: origin.y + r.midY, width: r.width - padding * 2, height: 1))
            }
        }

        func pill(_ range: NSRange, _ color: PlatformColor) {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // One pill per line fragment, so wrapped spans don't stretch to the line end.
            var rects: [CGRect] = []
            enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                if part.length > 0 { rects.append(self.boundingRect(forGlyphRange: part, in: container)) }
            }
            for rect in rects {
                let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont) ?? self.style.bodyFont
                let h = font.ascender - font.descender + 4
                let r = CGRect(x: origin.x + rect.minX - 2, y: origin.y + rect.maxY - h - (rect.height - h) * 0.25, width: rect.width + 4, height: h)
                ctx.setFillColor(color.cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()
            }
        }
        storage.enumerateAttribute(.axInlineCode, in: charRange) { value, range, _ in
            if value != nil { pill(range, style.codeBackgroundColor) }
        }
        storage.enumerateAttribute(.axTag, in: charRange) { value, range, _ in
            if value != nil { pill(range, style.accentColor.withAlpha(0.12)) }
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let ctx = context, let container = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        ctx.saveGState()
        defer { ctx.restoreGState() }

        storage.enumerateAttribute(.axTodo, in: charRange) { value, range, _ in
            guard let checked = value as? Bool else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyphs, in: container)
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont) ?? style.bodyFont
            let side = min(font.pointSize * 0.95, rect.height)
            let line = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let baselineY = line.minY + (location(forGlyphAt: glyphs.location).y)
            let centerY = baselineY - font.xHeight / 2 - 0.5
            let box = CGRect(x: origin.x + rect.minX + 1, y: origin.y + centerY - side / 2, width: side, height: side)
            let path = CGPath(roundedRect: box, cornerWidth: side * 0.28, cornerHeight: side * 0.28, transform: nil)
            if checked {
                ctx.setFillColor(style.accentColor.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.setStrokeColor(style.backgroundColor.cgColor)
                ctx.setLineWidth(max(1.6, side * 0.12))
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: CGPoint(x: box.minX + side * 0.26, y: box.midY + side * 0.02))
                ctx.addLine(to: CGPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.72))
                ctx.addLine(to: CGPoint(x: box.minX + side * 0.76, y: box.minY + side * 0.3))
                ctx.strokePath()
            } else {
                ctx.setStrokeColor(style.secondaryColor.cgColor)
                ctx.setLineWidth(1.4)
                ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 0.7, dy: 0.7), cornerWidth: side * 0.26, cornerHeight: side * 0.26, transform: nil))
                ctx.strokePath()
            }
        }

        storage.enumerateAttribute(.axBullet, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyphs, in: container)
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont) ?? style.bodyFont
            let d = max(4, font.pointSize * 0.3)
            let line = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let baselineY = line.minY + location(forGlyphAt: glyphs.location).y
            let center = CGPoint(x: origin.x + rect.midX, y: origin.y + baselineY - font.xHeight / 2)
            ctx.setFillColor(style.accentColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))
        }
    }
}

/// Converts between stored Markdown and the editor's attributed text, where image references
/// are shown inline as attachments.
enum EditorDocument {
    static func attributed(from markdown: String, style: EditorStyle, image: (String) -> PlatformImage?) -> NSAttributedString {
        let ns = markdown as NSString
        let result = NSMutableAttributedString()
        var last = 0
        let base: [NSAttributedString.Key: Any] = [.font: style.bodyFont, .foregroundColor: style.theme.textColor]
        for m in MarkdownSyntax.attachmentRef.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) where m.range(at: 1).length > 0 {
            result.append(NSAttributedString(string: ns.substring(with: NSRange(location: last, length: m.range.location - last)), attributes: base))
            result.append(attachmentString(id: ns.substring(with: m.range(at: 3)), source: ns.substring(with: m.range), image: image))
            last = NSMaxRange(m.range)
        }
        result.append(NSAttributedString(string: ns.substring(from: last), attributes: base))
        return result
    }

    static func attachmentString(id: String, source: String, image: (String) -> PlatformImage?) -> NSAttributedString {
        let attachment = ImageAttachment()
        attachment.attachmentId = id
        attachment.image = image(id) ?? placeholder
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttribute(.axAttachmentSource, value: source, range: NSRange(location: 0, length: s.length))
        return s
    }

    static func markdown(from text: NSAttributedString) -> String {
        var out = ""
        let ns = text.string as NSString
        var last = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            out += ns.substring(with: NSRange(location: last, length: range.location - last))
            out += (text.attribute(.axAttachmentSource, at: range.location, effectiveRange: nil) as? String) ?? ""
            last = NSMaxRange(range)
        }
        out += ns.substring(from: last)
        return out
    }

    static let placeholder: PlatformImage = {
        let size = CGSize(width: 320, height: 180)
        #if os(macOS)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10).fill()
        img.unlockFocus()
        return img
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.secondaryLabel.withAlphaComponent(0.12).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10).fill()
        }
        #endif
    }()
}

enum CompletionKind: Equatable { case tag, wiki }

struct CompletionState: Equatable {
    var kind: CompletionKind
    var query: String
    /// Range in the editor text to replace, including the trigger (`#` or `[[`).
    var range: NSRange
}

enum FormatCommand: Hashable {
    case bold, italic, strike, highlight, underline, code
    case heading(Int)
    case bulletList, numberedList, todo, quote
    case codeBlock, link, wikiLink, tag, rule, table
    case indent, outdent
}

/// Pure text transformations for formatting commands.
enum Formatter {
    struct Edit {
        var range: NSRange
        var replacement: String
        var selection: NSRange
    }

    static func wrapMarker(_ cmd: FormatCommand) -> String? {
        switch cmd {
        case .bold: return "**"
        case .italic: return "*"
        case .strike: return "~~"
        case .highlight: return "=="
        case .underline: return "~"
        case .code: return "`"
        default: return nil
        }
    }

    static func edit(for cmd: FormatCommand, text: NSString, selection sel: NSRange) -> Edit? {
        if let marker = wrapMarker(cmd) { return wrap(text, sel, marker) }
        let lines = text.lineRange(for: sel)
        switch cmd {
        case .heading(let level):
            return transformLines(text, lines, sel) { line in
                var stripped = line
                if let r = line.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression) {
                    let existing = line[r].filter { $0 == "#" }.count
                    stripped = String(line[r.upperBound...])
                    if existing == level { return stripped }
                }
                return level == 0 ? stripped : String(repeating: "#", count: level) + " " + stripped
            }
        case .bulletList: return togglePrefix(text, lines, sel, "- ", pattern: #"^([ \t]*)([-*+]|\d+[.)])( \[[ xX]\])? "#)
        case .numberedList:
            var n = 0
            return transformLines(text, lines, sel) { line in
                if let r = line.range(of: #"^([ \t]*)\d+[.)] "#, options: .regularExpression) { return String(line[r.upperBound...]) }
                n += 1
                let body = line.replacingOccurrences(of: #"^([ \t]*)[-*+]( \[[ xX]\])? "#, with: "$1", options: .regularExpression)
                return "\(n). " + body
            }
        case .todo: return togglePrefix(text, lines, sel, "- [ ] ", pattern: #"^([ \t]*)([-*+]|\d+[.)]) (\[[ xX]\] )?"#)
        case .quote: return togglePrefix(text, lines, sel, "> ", pattern: #"^>[ \t]?"#)
        case .indent:
            return transformLines(text, lines, sel) { "\t" + $0 }
        case .outdent:
            return transformLines(text, lines, sel) { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
                if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
                return line
            }
        case .codeBlock:
            let selected = text.substring(with: sel)
            let prefix = sel.location > 0 && text.character(at: sel.location - 1) != 10 ? "\n" : ""
            let replacement = "\(prefix)```\n\(selected)\n```\n"
            let caret = sel.location + (prefix as NSString).length + 4
            return Edit(range: sel, replacement: replacement, selection: NSRange(location: caret, length: (selected as NSString).length))
        case .link:
            let selected = text.substring(with: sel)
            if selected.hasPrefix("http") {
                return Edit(range: sel, replacement: "[](\(selected))", selection: NSRange(location: sel.location + 1, length: 0))
            }
            let replacement = "[\(selected)](https://)"
            let urlStart = sel.location + (selected as NSString).length + 3
            return Edit(range: sel, replacement: replacement, selection: NSRange(location: urlStart, length: 8))
        case .wikiLink:
            let selected = text.substring(with: sel)
            return Edit(range: sel, replacement: "[[\(selected)]]", selection: NSRange(location: sel.location + 2 + (selected as NSString).length, length: 0))
        case .tag:
            let selected = text.substring(with: sel)
            let needsSpace = sel.location > 0 && !(CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: sel.location - 1)) ?? " "))
            let tag = selected.contains(" ") ? "#\(selected)#" : "#\(selected)"
            let replacement = (needsSpace ? " " : "") + tag
            return Edit(range: sel, replacement: replacement, selection: NSRange(location: sel.location + (replacement as NSString).length, length: 0))
        case .rule:
            let prefix = sel.location > 0 && text.character(at: sel.location - 1) != 10 ? "\n" : ""
            let replacement = "\(prefix)---\n"
            return Edit(range: sel, replacement: replacement, selection: NSRange(location: sel.location + (replacement as NSString).length, length: 0))
        case .table:
            let prefix = sel.location > 0 && text.character(at: sel.location - 1) != 10 ? "\n" : ""
            let replacement = "\(prefix)| Column | Column |\n| --- | --- |\n|  |  |\n"
            return Edit(range: sel, replacement: replacement, selection: NSRange(location: sel.location + (prefix as NSString).length + 2, length: 6))
        default:
            return nil
        }
    }

    static func wrap(_ text: NSString, _ sel: NSRange, _ marker: String) -> Edit {
        let m = (marker as NSString).length
        // Unwrap if the selection is already surrounded by the marker.
        if sel.location >= m, NSMaxRange(sel) + m <= text.length,
           text.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let range = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            return Edit(range: range, replacement: text.substring(with: sel), selection: NSRange(location: sel.location - m, length: sel.length))
        }
        var target = sel
        if target.length == 0 {
            // Wrap the word under the caret, if any.
            let word = wordRange(text, at: sel.location)
            if word.length > 0 { target = word }
        }
        let selected = text.substring(with: target)
        if selected.hasPrefix(marker) && selected.hasSuffix(marker) && (selected as NSString).length >= 2 * m {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: (selected as NSString).length - 2 * m))
            return Edit(range: target, replacement: inner, selection: NSRange(location: target.location, length: (inner as NSString).length))
        }
        let replacement = marker + selected + marker
        let selection = target.length == 0
            ? NSRange(location: target.location + m, length: 0)
            : NSRange(location: target.location + m, length: target.length)
        return Edit(range: target, replacement: replacement, selection: selection)
    }

    static func wordRange(_ text: NSString, at location: Int) -> NSRange {
        var start = location, end = location
        func isWord(_ i: Int) -> Bool {
            guard i >= 0 && i < text.length, let scalar = UnicodeScalar(text.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    static func transformLines(_ text: NSString, _ lines: NSRange, _ sel: NSRange, _ transform: (String) -> String) -> Edit {
        let original = text.substring(with: lines)
        let hasTrailingNewline = original.hasSuffix("\n")
        var parts = original.components(separatedBy: "\n")
        if hasTrailingNewline { parts.removeLast() }
        let transformed = parts.map(transform).joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let delta = (transformed as NSString).length - (original as NSString).length
        let selection: NSRange
        if sel.length == 0 {
            // Keep the caret at the end of the line content when the prefix changes.
            let lineEnd = lines.location + (transformed as NSString).length - (hasTrailingNewline ? 1 : 0)
            selection = NSRange(location: max(lines.location, min(sel.location + delta, lineEnd)), length: 0)
        } else {
            selection = NSRange(location: lines.location, length: (transformed as NSString).length - (hasTrailingNewline ? 1 : 0))
        }
        return Edit(range: lines, replacement: transformed, selection: selection)
    }

    static func togglePrefix(_ text: NSString, _ lines: NSRange, _ sel: NSRange, _ prefix: String, pattern: String) -> Edit {
        let original = text.substring(with: lines)
        let all = original.components(separatedBy: "\n").filter { !$0.isEmpty }
        let allHave = !all.isEmpty && all.allSatisfy { $0.hasPrefix(prefix) || $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
        return transformLines(text, lines, sel) { line in
            if allHave {
                if let r = line.range(of: prefix) { return line.replacingCharacters(in: r, with: "") }
                return line
            }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let body = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            let stripped = body.hasPrefix(indent) ? String(body.dropFirst(indent.count)) : body
            return indent + prefix + stripped
        }
    }

    /// What Return should insert to continue a list, or nil for a plain newline.
    /// Returns an edit that may also end the list when the current item is empty.
    static func newlineEdit(text: NSString, selection sel: NSRange) -> Edit? {
        guard sel.length == 0 else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: sel.location, length: 0))
        var line = text.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        let caretInLine = sel.location - lineRange.location
        guard caretInLine == (line as NSString).length || caretInLine > 0 else { return nil }
        guard let m = line.firstMatch(of: #/^([ \t]*)((?:[-*+]|\d+[.)])(?: \[[ xX]\])?|>)[ \t]+/#) else { return nil }
        let markerLength = (String(line[m.range]) as NSString).length
        guard caretInLine >= markerLength else { return nil }
        let content = line[m.range.upperBound...].trimmingCharacters(in: .whitespaces)
        if content.isEmpty {
            // Empty item: end the list.
            let range = NSRange(location: lineRange.location, length: (line as NSString).length)
            return Edit(range: range, replacement: "", selection: NSRange(location: lineRange.location, length: 0))
        }
        let indent = String(m.1)
        var marker = String(m.2)
        if let num = marker.firstMatch(of: #/^(\d+)([.)])/#), let n = Int(num.1) {
            marker = "\(n + 1)\(num.2)"
        } else if marker.hasSuffix("]") {
            marker = String(marker.prefix(1)) + " [ ]"
        }
        let insertion = "\n" + indent + marker + " "
        return Edit(range: sel, replacement: insertion, selection: NSRange(location: sel.location + (insertion as NSString).length, length: 0))
    }

    /// Detects whether the caret is completing a `#tag` or `[[wiki link`.
    static func completion(text: NSString, caret: Int) -> CompletionState? {
        guard caret <= text.length else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: max(0, caret - 1), length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        if let open = before.range(of: "[[", options: .backwards), !before[open.upperBound...].contains("]]") {
            let query = String(before[open.upperBound...])
            guard !query.contains("\n") else { return nil }
            let loc = lineStart + (String(before[..<open.lowerBound]) as NSString).length
            return CompletionState(kind: .wiki, query: query, range: NSRange(location: loc, length: caret - loc))
        }
        if let m = before.firstMatch(of: #/(?:^|[\s(])#([\p{L}\p{N}_\-/]*)$/#) {
            let query = String(m.1)
            if before.hasSuffix("# ") { return nil }
            let loc = caret - (query as NSString).length - 1
            // Not a heading marker at line start followed by nothing yet.
            if loc == lineStart && query.isEmpty { return nil }
            return CompletionState(kind: .tag, query: query, range: NSRange(location: loc, length: caret - loc))
        }
        return nil
    }

    /// Toggles `- [ ]` / `- [x]` on the line containing `location`.
    static func toggleTodo(text: NSString, at location: Int) -> Edit? {
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        let line = text.substring(with: lineRange)
        guard let m = line.firstMatch(of: #/^[ \t]*[-*+] \[([ xX])\]/#) else { return nil }
        let boxOffset = (String(line[..<m.1.startIndex]) as NSString).length
        let checked = m.1 != " "
        return Edit(range: NSRange(location: lineRange.location + boxOffset, length: 1), replacement: checked ? " " : "x",
                    selection: NSRange(location: NSNotFound, length: 0))
    }
}
