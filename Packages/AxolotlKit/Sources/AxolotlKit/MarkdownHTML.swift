import Foundation

/// Renders Axolotl Markdown to HTML for export, printing and PDF.
public struct MarkdownHTML {
    public var attachmentURL: (String) -> String? = { _ in nil }
    public var wikiLinkURL: (String) -> String? = { _ in nil }
    public var keepTags = true

    public init() {}

    public func document(title: String, body markdown: String, css: String = MarkdownHTML.defaultCSS) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escape(title))</title><style>\(css)</style></head>
        <body><article>\(render(markdown))</article></body></html>
        """
    }

    public func render(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return renderBlocks(lines[...])
    }

    // MARK: Blocks

    private func renderBlocks(_ lines: ArraySlice<String>) -> String {
        var out = ""
        var i = lines.startIndex
        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out += "<p>" + paragraph.map(inline).joined(separator: "<br>\n") + "</p>\n"
            paragraph.removeAll()
        }
        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.endIndex && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                let cls = lang.isEmpty ? "" : " class=\"language-\(Self.escape(lang))\""
                out += "<pre><code\(cls)>\(Self.escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            if let m = trimmed.wholeMatch(of: #/(#{1,6})\s+(.*?)\s*#*/#) {
                flushParagraph()
                let level = m.1.count
                let text = String(m.2)
                out += "<h\(level) id=\"\(Self.slug(text))\">\(inline(text))</h\(level)>\n"
                i += 1; continue
            }
            if trimmed.wholeMatch(of: #/([-*_])(\s*\1){2,}/#) != nil {
                flushParagraph()
                out += "<hr>\n"
                i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var l = Substring(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                    if l.hasPrefix(" ") { l = l.dropFirst() }
                    quoted.append(String(l)); i += 1
                }
                if let first = quoted.first, let m = first.wholeMatch(of: #/\[!(\w+)\]\s*(.*)/#) {
                    let kind = m.1.lowercased()
                    let heading = m.2.isEmpty ? kind.capitalized : String(m.2)
                    out += "<div class=\"callout callout-\(Self.escape(kind))\"><div class=\"callout-title\">\(inline(heading))</div>\(renderBlocks(quoted.dropFirst()[...]))</div>\n"
                } else {
                    out += "<blockquote>\(renderBlocks(quoted[...]))</blockquote>\n"
                }
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.endIndex,
               lines[i + 1].trimmingCharacters(in: .whitespaces).wholeMatch(of: #/\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?/#) != nil {
                flushParagraph()
                func cells(_ l: String) -> [String] {
                    var t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("|") { t.removeFirst() }
                    if t.hasSuffix("|") { t.removeLast() }
                    return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                out += "<table><thead><tr>" + cells(line).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>\n"
                i += 2
                while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    out += "<tr>" + cells(lines[i]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
                    i += 1
                }
                out += "</tbody></table>\n"
                continue
            }
            if Self.listMarker(line) != nil {
                flushParagraph()
                var items: [String] = []
                while i < lines.endIndex, Self.listMarker(lines[i]) != nil || (!lines[i].trimmingCharacters(in: .whitespaces).isEmpty && lines[i].first?.isWhitespace == true && !items.isEmpty) {
                    items.append(lines[i]); i += 1
                }
                out += renderList(items[...])
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return out
    }

    struct ListMarker { var indent: Int; var ordered: Bool; var todo: Bool?; var content: String }

    static func listMarker(_ line: String) -> ListMarker? {
        guard let m = line.wholeMatch(of: #/([ \t]*)([-*+]|\d+[.)])[ \t]+(.*)/#) else { return nil }
        let indent = m.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let ordered = m.2.first?.isNumber == true
        var content = String(m.3)
        var todo: Bool?
        if !ordered, let t = content.wholeMatch(of: #/\[([ xX])\](?:\s+(.*))?/#) {
            todo = t.1 != " "
            content = String(t.2 ?? "")
        }
        return ListMarker(indent: indent, ordered: ordered, todo: todo, content: content)
    }

    private func renderList(_ lines: ArraySlice<String>) -> String {
        guard let first = lines.first.flatMap(Self.listMarker) else { return "" }
        let base = first.indent
        let tag = first.ordered ? "ol" : "ul"
        let isTodo = first.todo != nil
        var out = "<\(tag)\(isTodo ? " class=\"todo\"" : "")>\n"
        var i = lines.startIndex
        while i < lines.endIndex {
            guard let item = Self.listMarker(lines[i]), item.indent <= base + 1 else { i += 1; continue }
            i += 1
            var children: [String] = []
            while i < lines.endIndex {
                if let m = Self.listMarker(lines[i]), m.indent <= base + 1 { break }
                children.append(lines[i]); i += 1
            }
            var li = ""
            if let done = item.todo {
                li = "<li class=\"task\(done ? " done" : "")\"><input type=\"checkbox\" disabled\(done ? " checked" : "")> \(inline(item.content))"
            } else {
                li = "<li>\(inline(item.content))"
            }
            if !children.isEmpty {
                if children.contains(where: { Self.listMarker($0) != nil }) {
                    li += "\n" + renderList(children[...])
                } else {
                    li += "<br>" + children.map { inline($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "<br>")
                }
            }
            out += li + "</li>\n"
        }
        return out + "</\(tag)>\n"
    }

    // MARK: Inline

    func inline(_ text: String) -> String {
        var placeholders: [String] = []
        func hold(_ html: String) -> String {
            placeholders.append(html)
            return "\u{2}\(placeholders.count - 1)\u{3}"
        }
        var s = text
        // Code spans first so their contents are left alone.
        s = replace(s, #"`([^`\n]+)`"#) { g in hold("<code>\(Self.escape(g[1]))</code>") }
        s = replace(s, #"!\[([^\]\n]*)\]\(attachment:([A-Za-z0-9\-]+)\)"#) { g in
            hold("<img alt=\"\(Self.escape(g[1]))\" src=\"\(Self.escape(attachmentURL(g[2]) ?? ""))\">")
        }
        s = replace(s, #"\[([^\]\n]*)\]\(attachment:([A-Za-z0-9\-]+)\)"#) { g in
            hold("<a class=\"file\" href=\"\(Self.escape(attachmentURL(g[2]) ?? "#"))\">📎 \(Self.escape(g[1]))</a>")
        }
        s = replace(s, #"!\[([^\]\n]*)\]\(([^)\s]+)\)"#) { g in hold("<img alt=\"\(Self.escape(g[1]))\" src=\"\(Self.escape(g[2]))\">") }
        s = replace(s, #"\[\[([^\[\]\n]+?)\]\]"#) { g in
            let inner = g[1]
            let target = NoteParser.wikiTarget(inner)
            let label = inner.contains("|") ? String(inner.split(separator: "|", maxSplits: 1)[1]) : inner
            if let url = wikiLinkURL(target) {
                return hold("<a class=\"wikilink\" href=\"\(Self.escape(url))\">\(Self.escape(label))</a>")
            }
            return hold("<span class=\"wikilink\">\(Self.escape(label))</span>")
        }
        s = replace(s, #"\[([^\]\n]+)\]\(([^)\s]+)\)"#) { g in hold("<a href=\"\(Self.escape(g[2]))\">\(Self.escape(g[1]))</a>") }
        s = replace(s, #"\bhttps?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#) { g in hold("<a href=\"\(Self.escape(g[0]))\">\(Self.escape(g[0]))</a>") }
        let ns = s as NSString
        for t in MarkdownSyntax.tags(in: ns, codeRanges: []).reversed() {
            let html = keepTags ? "<span class=\"tag\">#\(Self.escape(t.name))</span>" : ""
            s = (s as NSString).replacingCharacters(in: t.range, with: hold(html))
        }
        s = Self.escape(s)
        s = replace(s, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#) { g in "<strong>\(g[2])</strong>" }
        s = replace(s, #"(?<![\*\w])(\*|_)(?=[^\s\*_])(.+?)(?<=[^\s\*_])\1(?![\*\w])"#) { g in "<em>\(g[2])</em>" }
        s = replace(s, #"~~(?=\S)(.+?)(?<=\S)~~"#) { g in "<del>\(g[1])</del>" }
        s = replace(s, #"==(?=\S)(.+?)(?<=\S)=="#) { g in "<mark>\(g[1])</mark>" }
        s = replace(s, #"(?<!~)~(?=[^\s~])([^~\n]+?)(?<=[^\s~])~(?!~)"#) { g in "<u>\(g[1])</u>" }
        s = replace(s, #"(?<![\\$])\$(?=\S)([^$\n]+?)(?<=\S)\$(?!\$)"#) { g in "<span class=\"math\">\(g[1])</span>" }
        s = replace(s, #"\[\^([^\]\s]+)\]"#) { g in "<sup class=\"footnote\">\(g[1])</sup>" }
        // Restore placeholders (may be nested).
        while let r = s.range(of: #"\u{2}(\d+)\u{3}"#, options: .regularExpression) {
            let idx = Int(s[r].dropFirst().dropLast()) ?? 0
            s.replaceSubrange(r, with: idx < placeholders.count ? placeholders[idx] : "")
        }
        return s
    }

    private func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(groups)
            last = NSMaxRange(m.range)
        }
        out += ns.substring(from: last)
        return out
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func slug(_ s: String) -> String {
        let lowered = NoteParser.cleanInline(s).lowercased()
        let allowed = lowered.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return allowed.split(separator: "-").joined(separator: "-")
    }

    public static let defaultCSS = """
    :root { color-scheme: light dark; --fg:#2b2b2b; --muted:#8a8a8a; --accent:#d9534f; --bg:#ffffff; --code:#f4f4f4; --mark:#fff3a3; }
    @media (prefers-color-scheme: dark) { :root { --fg:#e6e6e6; --muted:#9a9a9a; --bg:#1e1e1e; --code:#2b2b2b; --mark:#6b5d00; } }
    body { margin:0; background:var(--bg); color:var(--fg); font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Avenir Next", "Helvetica Neue", sans-serif; }
    article { max-width: 720px; margin: 0 auto; padding: 48px 24px; }
    h1,h2,h3,h4,h5,h6 { line-height:1.25; margin:1.4em 0 .5em; }
    a { color: var(--accent); }
    code { font: 0.9em ui-monospace, Menlo, monospace; background: var(--code); padding: .1em .3em; border-radius: 4px; }
    pre { background: var(--code); padding: 14px 16px; border-radius: 8px; overflow:auto; }
    pre code { background: none; padding: 0; }
    blockquote { margin: 1em 0; padding: 0 1em; border-left: 3px solid var(--accent); color: var(--muted); }
    mark { background: var(--mark); color: inherit; padding: 0 .15em; border-radius: 3px; }
    img { max-width: 100%; border-radius: 6px; }
    table { border-collapse: collapse; margin: 1em 0; } th, td { border: 1px solid #8884; padding: 6px 10px; text-align:left; }
    ul.todo { list-style: none; padding-left: 1.2em; } li.task.done { color: var(--muted); text-decoration: line-through; }
    .tag { color: var(--accent); background: color-mix(in srgb, var(--accent) 12%, transparent); padding: 0 .35em; border-radius: 4px; }
    .wikilink { color: var(--accent); text-decoration: underline dotted; }
    .callout { border-left: 4px solid var(--accent); background: color-mix(in srgb, var(--accent) 8%, transparent); padding: .6em 1em; border-radius: 6px; margin: 1em 0; }
    .callout-title { font-weight: 600; }
    .callout-note,.callout-info { --accent:#3b82f6; } .callout-tip,.callout-success { --accent:#16a34a; } .callout-warning { --accent:#d97706; } .callout-danger,.callout-error { --accent:#dc2626; }
    hr { border: none; border-top: 1px solid #8885; margin: 2em 0; }
    """
}
