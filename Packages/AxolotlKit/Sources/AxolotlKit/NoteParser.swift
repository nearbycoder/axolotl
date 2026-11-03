import Foundation

/// Regular expressions for the Markdown dialect Axolotl understands.
/// Shared by the metadata parser, the editor highlighter and the HTML exporter.
public enum MarkdownSyntax {
    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// `#multi word tag#`
    public static let multiWordTag = re(#"(?<![\w#/&])#([\p{L}\p{N}_][^#\n]*?[^\s#])#(?![\w#])"#)
    /// `#tag` and `#nested/tag`
    public static let tag = re(#"(?<![\w#/&:])#([\p{L}\p{N}_][\p{L}\p{N}_\-/.]*)"#)
    public static let wikiLink = re(#"\[\[([^\[\]\n]+?)\]\]"#)
    public static let heading = re(#"^(#{1,6})[ \t]+(.+?)[ \t#]*$"#, .anchorsMatchLines)
    public static let todo = re(#"^([ \t]*)([-*+]) \[([ xX])\](?=\s|$)"#, .anchorsMatchLines)
    public static let fence = re(#"^[ \t]*(```|~~~)"#, .anchorsMatchLines)
    public static let inlineCode = re(#"`[^`\n]+`"#)
    public static let attachmentRef = re(#"(!?)\[([^\]\n]*)\]\(attachment:([A-Za-z0-9\-]+)\)"#)
    public static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    public static let italic = re(#"(?<![\*\w])(\*|_)(?=[^\s\*_])(.+?)(?<=[^\s\*_])\1(?![\*\w])"#)
    public static let strike = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    public static let highlight = re(#"==(?=\S)(.+?)(?<=\S)=="#)
    public static let underline = re(#"(?<!~)~(?=[^\s~])([^~\n]+?)(?<=[^\s~])~(?!~)"#)
    public static let link = re(#"(?<!!)\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    public static let image = re(#"!\[([^\]\n]*)\]\(([^)\s]+)\)"#)
    public static let bareURL = re(#"\bhttps?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#)
    public static let quote = re(#"^[ \t]*>.*$"#, .anchorsMatchLines)
    public static let callout = re(#"^[ \t]*>[ \t]*\[!(\w+)\]"#, .anchorsMatchLines)
    public static let listItem = re(#"^([ \t]*)([-*+]|\d+[.)])[ \t]+"#, .anchorsMatchLines)
    public static let hr = re(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#, .anchorsMatchLines)
    public static let tableRow = re(#"^[ \t]*\|.*\|[ \t]*$"#, .anchorsMatchLines)
    public static let mathInline = re(#"(?<![\\$])\$(?=\S)[^$\n]+?(?<=\S)\$(?!\$)"#)
    public static let footnote = re(#"\[\^[^\]\s]+\]"#)

    /// UTF-16 ranges of fenced code blocks (including fences) and inline code spans.
    public static func codeRanges(in text: NSString) -> [NSRange] {
        let fenced = fencedBlocks(in: text)
        var ranges = fenced
        inlineCode.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { m, _, _ in
            guard let m, !fenced.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return }
            ranges.append(m.range)
        }
        return ranges
    }

    /// UTF-16 ranges of fenced code blocks, from the opening fence line through the closing one.
    public static func fencedBlocks(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var openStart: Int?
        var openMarker = ""
        fence.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { m, _, _ in
            guard let m else { return }
            let marker = text.substring(with: m.range(at: 1))
            let line = text.lineRange(for: NSRange(location: m.range.location, length: 0))
            if let start = openStart {
                if marker == openMarker {
                    ranges.append(NSRange(location: start, length: NSMaxRange(line) - start))
                    openStart = nil
                }
            } else {
                openStart = line.location
                openMarker = marker
            }
        }
        if let start = openStart { ranges.append(NSRange(location: start, length: text.length - start)) }
        return ranges
    }

    public struct TagMatch: Hashable {
        public var range: NSRange
        public var name: String
    }

    /// All tags in the text, skipping code. Ranges include the `#` markers.
    public static func tags(in text: NSString, codeRanges: [NSRange]? = nil) -> [TagMatch] {
        let code = codeRanges ?? self.codeRanges(in: text)
        let full = NSRange(location: 0, length: text.length)
        var result: [TagMatch] = []
        func inCode(_ r: NSRange) -> Bool { code.contains { NSIntersectionRange($0, r).length > 0 || NSLocationInRange(r.location, $0) } }
        multiWordTag.enumerateMatches(in: text as String, range: full) { m, _, _ in
            guard let m, !inCode(m.range) else { return }
            let name = text.substring(with: m.range(at: 1))
            guard name.contains(" ") else { return }
            result.append(TagMatch(range: m.range, name: normalizeTag(name)))
        }
        tag.enumerateMatches(in: text as String, range: full) { m, _, _ in
            guard let m, !inCode(m.range) else { return }
            if result.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) { return }
            // A heading marker is `#` followed by whitespace, which the pattern already excludes.
            var name = text.substring(with: m.range(at: 1))
            var length = m.range.length
            while let last = name.last, "/.-".contains(last) {
                name.removeLast()
                length -= 1
            }
            guard !name.isEmpty else { return }
            result.append(TagMatch(range: NSRange(location: m.range.location, length: length), name: normalizeTag(name)))
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    public static func normalizeTag(_ name: String) -> String {
        name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
    }
}

public enum NoteParser {
    public static func parse(_ body: String) -> NoteMeta {
        var meta = NoteMeta()
        let text = body as NSString
        let full = NSRange(location: 0, length: text.length)
        let code = MarkdownSyntax.codeRanges(in: text)

        // Title: first non-empty line.
        var titleLineEnd = 0
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let raw = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            location = NSMaxRange(line)
            if !raw.isEmpty {
                meta.title = String(cleanInline(stripHeadingMarker(raw)).prefix(200))
                titleLineEnd = NSMaxRange(line)
                break
            }
        }

        if titleLineEnd < text.length {
            let rest = text.substring(from: titleLineEnd)
            var preview = ""
            for line in rest.split(separator: "\n", omittingEmptySubsequences: true) {
                let cleaned = cleanInline(stripHeadingMarker(String(line).trimmingCharacters(in: .whitespaces)))
                if cleaned.isEmpty || cleaned.hasPrefix("```") { continue }
                preview += (preview.isEmpty ? "" : " ") + cleaned
                if preview.count > 240 { break }
            }
            meta.preview = String(preview.prefix(240))
        }

        var seenTags = Set<String>()
        for t in MarkdownSyntax.tags(in: text, codeRanges: code) where seenTags.insert(t.name.lowercased()).inserted {
            meta.tags.append(t.name)
        }

        var seenLinks = Set<String>()
        MarkdownSyntax.wikiLink.enumerateMatches(in: body, range: full) { m, _, _ in
            guard let m, !code.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return }
            let target = wikiTarget(text.substring(with: m.range(at: 1)))
            if seenLinks.insert(target.lowercased()).inserted { meta.wikiLinks.append(target) }
        }

        MarkdownSyntax.todo.enumerateMatches(in: body, range: full) { m, _, _ in
            guard let m, !code.contains(where: { NSLocationInRange(m.range.location, $0) }) else { return }
            if text.substring(with: m.range(at: 3)) == " " { meta.openTodos += 1 } else { meta.doneTodos += 1 }
        }

        meta.hasCode = !code.isEmpty

        MarkdownSyntax.attachmentRef.enumerateMatches(in: body, range: full) { m, _, _ in
            guard let m else { return }
            let id = text.substring(with: m.range(at: 3))
            if m.range(at: 1).length > 0 { meta.imageIds.append(id) } else { meta.fileIds.append(id) }
        }

        MarkdownSyntax.heading.enumerateMatches(in: body, range: full) { m, _, _ in
            guard let m, !code.contains(where: { NSLocationInRange(m.range.location, $0) }) else { return }
            let level = m.range(at: 1).length
            let title = cleanInline(text.substring(with: m.range(at: 2)))
            meta.headings.append(Heading(level: level, text: title, location: m.range.location))
        }
        return meta
    }

    /// `[[Title|Alias]]` and `[[Title/Heading]]` link to `Title`.
    public static func wikiTarget(_ inner: String) -> String {
        var target = inner
        if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
        return target.trimmingCharacters(in: .whitespaces)
    }

    static func stripHeadingMarker(_ line: String) -> String {
        var s = Substring(line)
        if s.hasPrefix("#") {
            let hashes = s.prefix { $0 == "#" }
            if hashes.count <= 6, s.dropFirst(hashes.count).first?.isWhitespace == true {
                s = s.dropFirst(hashes.count)
            }
        }
        if s.hasPrefix(">") { s = s.drop { $0 == ">" || $0 == " " } }
        if let m = s.range(of: #"^[-*+] \[[ xX]\] "#, options: .regularExpression) { s = s[m.upperBound...] }
        else if let m = s.range(of: #"^([-*+]|\d+[.)]) "#, options: .regularExpression) { s = s[m.upperBound...] }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Strips inline Markdown markup for display in lists and titles.
    public static func cleanInline(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"!?\[([^\]]*)\]\(attachment:[^)]+\)"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[\[([^\]|]+)(\|([^\]]+))?\]\]"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "~~", "==", "`"] { out = out.replacingOccurrences(of: marker, with: "") }
        out = out.replacingOccurrences(of: #"(?<!\w)[*_](\S[^*_]*)[*_](?!\w)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<![~\w])~(\S[^~]*)~(?![~\w])"#, with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }
}

public struct TextStats: Hashable, Sendable {
    public var words = 0
    public var characters = 0
    public var charactersNoSpaces = 0
    public var paragraphs = 0
    public var lines = 0
    public var readingMinutes: Int { max(1, Int((Double(words) / 230).rounded(.up))) }

    public init(_ text: String) {
        characters = text.count
        charactersNoSpaces = text.filter { !$0.isWhitespace }.count
        var lineCount = 0
        var paragraphCount = 0
        text.enumerateLines { line, _ in
            lineCount += 1
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { paragraphCount += 1 }
        }
        lines = lineCount
        paragraphs = paragraphCount
        var w = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in w += 1 }
        words = w
    }
}
