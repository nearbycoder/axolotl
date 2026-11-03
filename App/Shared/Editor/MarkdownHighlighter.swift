import Foundation
import AxolotlKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// Bool: checked state of a todo marker (`- [ ]`), drawn as a checkbox.
    static let axTodo = NSAttributedString.Key("axTodo")
    /// Bullet marker character, drawn as a dot.
    static let axBullet = NSAttributedString.Key("axBullet")
    /// Fenced code block line; contiguous runs get one rounded background.
    static let axCodeBlock = NSAttributedString.Key("axCodeBlock")
    /// Blockquote line; value is the bar color.
    static let axQuote = NSAttributedString.Key("axQuote")
    /// Horizontal rule line.
    static let axRule = NSAttributedString.Key("axRule")
    /// Inline code span (rounded background).
    static let axInlineCode = NSAttributedString.Key("axInlineCode")
    /// Tag name for `#tags` (rounded background, tap to filter).
    static let axTag = NSAttributedString.Key("axTag")
    /// Wiki link target title.
    static let axWiki = NSAttributedString.Key("axWiki")
    /// URL string for links.
    static let axLink = NSAttributedString.Key("axLink")
    /// Original Markdown for an inline attachment character.
    static let axAttachmentSource = NSAttributedString.Key("axAttachmentSource")
    /// Attachment id for file links.
    static let axFile = NSAttributedString.Key("axFile")
    /// Markdown syntax that is hidden unless the caret is on its line.
    static let axHidden = NSAttributedString.Key("axHidden")
}

/// Appearance inputs for highlighting.
struct EditorStyle {
    var theme: Theme
    var font: EditorFont
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var paragraphSpacing: CGFloat
    var dimMarkdown: Bool
    var hideMarkdown: Bool = true

    var bodyFont: PlatformFont { font.font(size: fontSize) }
    var codeFont: PlatformFont { .monospaced(size: fontSize * 0.88) }

    func headingFont(_ level: Int) -> PlatformFont {
        let scale: [CGFloat] = [1.75, 1.45, 1.25, 1.1, 1.0, 0.95]
        return font.font(size: fontSize * scale[min(max(level, 1), 6) - 1]).withTraits(bold: true)
    }

    var markerColor: PlatformColor { dimMarkdown ? theme.secondaryColor.withAlpha(0.75) : theme.secondaryColor }
}

/// Applies live Markdown styling to a text storage.
enum MarkdownHighlighter {
    static let keywordRegex = try! NSRegularExpression(pattern:
        #"\b(func|let|var|const|if|else|for|while|return|class|struct|enum|import|from|def|fn|pub|static|public|private|protocol|extension|switch|case|break|continue|new|this|self|true|false|nil|null|None|async|await|try|catch|throw|in|of|interface|type|package|go|defer|match|impl|use|mod|where|guard|do|lambda|yield|function|export|default)\b"#)
    static let stringRegex = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#)
    static let commentRegex = try! NSRegularExpression(pattern: #"(//|#(?!!)|--)[^\n]*|/\*[\s\S]*?\*/"#)
    static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#)

    static func paragraphStyle(_ style: EditorStyle, headIndent: CGFloat = 0, firstIndent: CGFloat = 0, spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = style.lineHeight
        p.paragraphSpacing = style.paragraphSpacing
        p.paragraphSpacingBefore = spacingBefore
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstIndent
        return p
    }

    /// Re-styles `range` (expanded to whole paragraphs). Attachments are preserved.
    static func highlight(_ storage: NSMutableAttributedString, range requested: NSRange, style: EditorStyle) {
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        let range = text.paragraphRange(for: NSRange(location: min(requested.location, text.length), length: min(requested.length, text.length - min(requested.location, text.length))))
        let theme = style.theme
        let body = style.bodyFont

        // Preserve attachments while resetting.
        var attachments: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttribute(.attachment, in: range) { value, r, _ in
            guard value != nil else { return }
            var attrs: [NSAttributedString.Key: Any] = [.attachment: value!]
            if let src = storage.attribute(.axAttachmentSource, at: r.location, effectiveRange: nil) { attrs[.axAttachmentSource] = src }
            attachments.append((r, attrs))
        }
        storage.setAttributes([.font: body, .foregroundColor: theme.textColor, .paragraphStyle: paragraphStyle(style)], range: range)
        for (r, attrs) in attachments { storage.addAttributes(attrs, range: r) }

        let codeRanges = MarkdownSyntax.codeRanges(in: text)
        let fencedBlocks = MarkdownSyntax.fencedBlocks(in: text)
        let inlineCode = codeRanges.filter { r in !fencedBlocks.contains { NSEqualRanges($0, r) } }

        func inFence(_ loc: Int) -> Bool { fencedBlocks.contains { NSLocationInRange(loc, $0) } }
        func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }
        let marker = style.markerColor
        func hide(_ r: NSRange) {
            guard style.hideMarkdown, r.length > 0, r.location != NSNotFound else { return }
            storage.addAttribute(.axHidden, value: true, range: r)
        }

        // Block-level styling, paragraph by paragraph.
        var loc = range.location
        while loc < NSMaxRange(range) {
            let para = text.paragraphRange(for: NSRange(location: loc, length: 0))
            defer { loc = NSMaxRange(para) }
            let line = text.substring(with: para)
            let content = line.trimmingCharacters(in: .newlines)
            let contentRange = NSRange(location: para.location, length: (content as NSString).length)

            if inFence(para.location) {
                storage.addAttributes([.font: style.codeFont, .foregroundColor: theme.textColor, .axCodeBlock: true,
                                       .paragraphStyle: paragraphStyle(style, headIndent: 12, firstIndent: 12)], range: para)
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    storage.addAttribute(.foregroundColor, value: marker, range: contentRange)
                    // The fence itself hides; a language name stays as a small label.
                    let leading = (content.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
                    hide(NSRange(location: contentRange.location + leading, length: 3))
                    storage.addAttributes([.font: PlatformFont.systemFont(ofSize: style.fontSize * 0.72, weight: .semibold), .kern: 0.6],
                                          range: NSRange(location: contentRange.location + leading + 3, length: max(0, contentRange.length - leading - 3)))
                } else {
                    highlightCode(storage, contentRange, style)
                }
                continue
            }

            if let m = MarkdownSyntax.heading.firstMatch(in: text as String, range: contentRange), m.range.location == para.location {
                let level = m.range(at: 1).length
                storage.addAttributes([.font: style.headingFont(level), .foregroundColor: theme.headingColor,
                                       .paragraphStyle: paragraphStyle(style, spacingBefore: style.paragraphSpacing * (level <= 2 ? 1.5 : 0.8))], range: para)
                storage.addAttributes([.foregroundColor: marker, .font: style.headingFont(level).withSize(style.fontSize * 0.8)],
                                      range: NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length + 1))
                hide(NSRange(location: m.range(at: 1).location, length: m.range(at: 2).location - m.range(at: 1).location))
            } else if MarkdownSyntax.hr.firstMatch(in: text as String, range: contentRange) != nil {
                storage.addAttributes([.foregroundColor: PlatformColor.clear, .axRule: true], range: contentRange)
            } else if let q = MarkdownSyntax.quote.firstMatch(in: text as String, range: contentRange), q.range.location == para.location {
                var barColor = theme.accentColor
                if let c = MarkdownSyntax.callout.firstMatch(in: text as String, range: contentRange) {
                    barColor = calloutColor(text.substring(with: c.range(at: 1)), theme)
                    storage.addAttributes([.foregroundColor: barColor, .font: body.withTraits(bold: true)], range: c.range)
                    let kind = c.range(at: 1)
                    hide(NSRange(location: kind.location - 2, length: 2))
                    hide(NSRange(location: NSMaxRange(kind), length: 1))
                } else if let kind = calloutKind(endingBefore: para.location, in: text) {
                    // Continuation line of a callout keeps its color.
                    barColor = calloutColor(kind, theme)
                }
                let prefixWidth = ((content.prefix { $0 == " " || $0 == "\t" || $0 == ">" }) + "").size(withAttributes: [.font: body]).width
                storage.addAttributes([.foregroundColor: theme.quoteColor, .axQuote: barColor,
                                       .paragraphStyle: paragraphStyle(style, headIndent: 16 + prefixWidth, firstIndent: 16)], range: para)
                if let gt = content.firstIndex(of: ">") {
                    let offset = content.utf16.distance(from: content.utf16.startIndex, to: gt.samePosition(in: content.utf16)!)
                    storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: NSRange(location: para.location + offset, length: 1))
                }
            } else if let m = MarkdownSyntax.todo.firstMatch(in: text as String, range: contentRange), m.range.location == para.location {
                let checked = text.substring(with: m.range(at: 3)) != " "
                let indentWidth = indentPoints(text.substring(with: m.range(at: 1)), body)
                let markerRange = NSRange(location: m.range(at: 2).location, length: NSMaxRange(m.range) - m.range(at: 2).location)
                let markerWidth = (text.substring(with: markerRange) + " ").size(withAttributes: [.font: body]).width
                storage.addAttributes([.paragraphStyle: paragraphStyle(style, headIndent: indentWidth + markerWidth, firstIndent: 0)], range: para)
                storage.addAttributes([.foregroundColor: PlatformColor.clear, .axTodo: checked], range: markerRange)
                if checked {
                    var start = NSMaxRange(markerRange)
                    while start < NSMaxRange(contentRange), text.character(at: start) == 32 { start += 1 }
                    let rest = NSRange(location: start, length: NSMaxRange(contentRange) - start)
                    if rest.length > 0 {
                        storage.addAttributes([.foregroundColor: theme.secondaryColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                               .strikethroughColor: theme.secondaryColor], range: rest)
                    }
                }
            } else if let m = MarkdownSyntax.listItem.firstMatch(in: text as String, range: contentRange), m.range.location == para.location {
                let indentWidth = indentPoints(text.substring(with: m.range(at: 1)), body)
                let markerText = text.substring(with: m.range(at: 2))
                let markerWidth = (text.substring(with: NSRange(location: m.range(at: 2).location, length: NSMaxRange(m.range) - m.range(at: 2).location)))
                    .size(withAttributes: [.font: body]).width
                storage.addAttributes([.paragraphStyle: paragraphStyle(style, headIndent: indentWidth + markerWidth, firstIndent: 0)], range: para)
                if markerText.first?.isNumber == true {
                    storage.addAttribute(.foregroundColor, value: theme.accentColor, range: m.range(at: 2))
                } else {
                    storage.addAttributes([.foregroundColor: PlatformColor.clear, .axBullet: true], range: m.range(at: 2))
                }
            } else if MarkdownSyntax.tableRow.firstMatch(in: text as String, range: contentRange) != nil {
                storage.addAttribute(.font, value: style.codeFont, range: contentRange)
                var i = contentRange.location
                while i < NSMaxRange(contentRange) {
                    let ch = text.character(at: i)
                    if ch == 124 /* | */ || ch == 45 /* - */ && content.contains("---") { storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: i, length: 1)) }
                    i += 1
                }
            }
        }

        // Inline styling.
        let s = text as String
        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: s, range: range) { m, _, _ in
                guard let m, !inCode(m.range) else { return }
                body(m)
            }
        }
        func dimMarkers(_ m: NSTextCheckingResult, _ length: Int) {
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: m.range.location, length: length))
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: NSMaxRange(m.range) - length, length: length))
            hide(NSRange(location: m.range.location, length: length))
            hide(NSRange(location: NSMaxRange(m.range) - length, length: length))
        }
        func addTrait(_ r: NSRange, bold: Bool = false, italic: Bool = false) {
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                let f = (value as? PlatformFont) ?? body
                storage.addAttribute(.font, value: f.withTraits(bold: bold, italic: italic), range: sub)
            }
        }

        each(MarkdownSyntax.bold) { m in addTrait(m.range, bold: true); dimMarkers(m, 2) }
        each(MarkdownSyntax.italic) { m in addTrait(m.range, italic: true); dimMarkers(m, 1) }
        each(MarkdownSyntax.strike) { m in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: theme.secondaryColor], range: m.range)
            dimMarkers(m, 2)
        }
        each(MarkdownSyntax.underline) { m in
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            dimMarkers(m, 1)
        }
        each(MarkdownSyntax.highlight) { m in
            storage.addAttribute(.backgroundColor, value: theme.highlightColor, range: m.range)
            dimMarkers(m, 2)
        }
        each(MarkdownSyntax.mathInline) { m in
            storage.addAttributes([.font: style.codeFont, .foregroundColor: theme.codeColor], range: m.range)
            dimMarkers(m, 1)
        }
        each(MarkdownSyntax.footnote) { m in
            storage.addAttributes([.foregroundColor: theme.accentColor, .baselineOffset: style.fontSize * 0.3,
                                   .font: body.withSize(style.fontSize * 0.75)], range: m.range)
        }
        each(MarkdownSyntax.bareURL) { m in
            let url = text.substring(with: m.range)
            storage.addAttributes([.foregroundColor: theme.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .underlineColor: theme.linkColor.withAlpha(0.4), .axLink: url], range: m.range)
        }
        each(MarkdownSyntax.link) { m in
            let url = text.substring(with: m.range(at: 2))
            storage.addAttribute(.foregroundColor, value: marker, range: m.range)
            if url.hasPrefix("attachment:") {
                storage.addAttributes([.foregroundColor: theme.linkColor, .axFile: String(url.dropFirst("attachment:".count))], range: m.range(at: 1))
            } else {
                storage.addAttributes([.foregroundColor: theme.linkColor, .axLink: url, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: theme.linkColor.withAlpha(0.4)], range: m.range(at: 1))
                storage.removeAttribute(.underlineStyle, range: m.range(at: 2))
            }
            hide(NSRange(location: m.range.location, length: 1))
            hide(NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))))
        }
        each(MarkdownSyntax.image) { m in
            storage.addAttribute(.foregroundColor, value: marker, range: m.range)
            storage.addAttribute(.axLink, value: text.substring(with: m.range(at: 2)), range: m.range)
        }
        each(MarkdownSyntax.wikiLink) { m in
            let target = NoteParser.wikiTarget(text.substring(with: m.range(at: 1)))
            storage.addAttributes([.foregroundColor: theme.linkColor, .axWiki: target, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .underlineColor: theme.linkColor.withAlpha(0.35)], range: m.range(at: 1))
            dimMarkers(m, 2)
        }
        for t in MarkdownSyntax.tags(in: text, codeRanges: codeRanges) where NSIntersectionRange(t.range, range).length > 0 {
            storage.addAttributes([.foregroundColor: theme.accentColor, .axTag: t.name], range: t.range)
        }
        for r in inlineCode where NSIntersectionRange(r, range).length > 0 {
            storage.addAttributes([.font: style.codeFont, .foregroundColor: theme.codeColor, .axInlineCode: true], range: r)
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: r.location, length: 1))
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: NSMaxRange(r) - 1, length: 1))
            hide(NSRange(location: r.location, length: 1))
            hide(NSRange(location: NSMaxRange(r) - 1, length: 1))
        }
    }

    private static func highlightCode(_ storage: NSMutableAttributedString, _ range: NSRange, _ style: EditorStyle) {
        let s = storage.string
        let theme = style.theme
        numberRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            if let m { storage.addAttribute(.foregroundColor, value: theme.codeColor, range: m.range) }
        }
        keywordRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            if let m { storage.addAttributes([.foregroundColor: theme.headingColor, .font: style.codeFont.withTraits(bold: true)], range: m.range) }
        }
        stringRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            if let m { storage.addAttribute(.foregroundColor, value: theme.linkColor, range: m.range) }
        }
        commentRegex.enumerateMatches(in: s, range: range) { m, _, _ in
            if let m { storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: m.range) }
        }
    }

    /// The callout type of the quote block containing the line before `location`, if any.
    static func calloutKind(endingBefore location: Int, in text: NSString) -> String? {
        var loc = location
        while loc > 0 {
            let prev = text.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            let line = text.substring(with: prev)
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix(">") else { return nil }
            if let m = MarkdownSyntax.callout.firstMatch(in: text as String, range: prev) { return text.substring(with: m.range(at: 1)) }
            loc = prev.location
        }
        return nil
    }

    static func calloutColor(_ kind: String, _ theme: Theme) -> PlatformColor {
        switch kind.lowercased() {
        case "note", "info": return PlatformColor(hex: "#3B82F6")
        case "tip", "success", "hint": return PlatformColor(hex: "#16A34A")
        case "warning", "caution", "important": return PlatformColor(hex: "#D97706")
        case "danger", "error", "bug": return PlatformColor(hex: "#DC2626")
        default: return theme.accentColor
        }
    }

    private static func indentPoints(_ whitespace: String, _ font: PlatformFont) -> CGFloat {
        guard !whitespace.isEmpty else { return 0 }
        return whitespace.replacingOccurrences(of: "\t", with: "    ").size(withAttributes: [.font: font]).width
    }
}

extension PlatformFont {
    func withSize(_ size: CGFloat) -> PlatformFont {
        #if os(macOS)
        return NSFont(descriptor: fontDescriptor, size: size) ?? self
        #else
        return UIFont(descriptor: fontDescriptor, size: size)
        #endif
    }
}
