import Foundation

/// Context a query needs beyond the note itself.
public struct SearchContext {
    public var now: Date
    public var calendar: Calendar
    public var backlinked: Set<String>
    public var attachments: [String: Attachment]

    public init(now: Date = Date(), calendar: Calendar = .current, backlinked: Set<String> = [], attachments: [String: Attachment] = [:]) {
        self.now = now
        self.calendar = calendar
        self.backlinked = backlinked
        self.attachments = attachments
    }
}

/// Parses Bear-style search strings: words, `"phrases"`, `-exclusions`, `#tags`, `!#exact`,
/// `-#tag`, `OR`, and `@special` filters such as `@todo`, `@today`, `@last7days`, `@date(>2024-01-01)`.
public struct SearchQuery {
    indirect enum Term {
        case text(String, titleOnly: Bool)
        case tag(String, exact: Bool)
        case tagSuffix(String)
        case special(String)
        case date(created: Bool, op: Character, day: Date)
        case lastDays(created: Bool, Int)
        case not(Term)
    }

    /// Conjunction of disjunctions.
    var groups: [[Term]] = []
    public var isEmpty: Bool { groups.isEmpty }

    /// Plain words, for highlighting matches.
    public private(set) var highlightTerms: [String] = []

    public init(_ string: String) {
        let tokens = Self.tokenize(string)
        var titleOnly = false
        var pendingOr = false
        for token in tokens {
            if token == "OR" { pendingOr = true; continue }
            guard let term = parse(token, titleOnly: &titleOnly) else { continue }
            if pendingOr, !groups.isEmpty {
                groups[groups.count - 1].append(term)
            } else {
                groups.append([term])
            }
            pendingOr = false
        }
    }

    private mutating func parse(_ raw: String, titleOnly: inout Bool) -> Term? {
        var token = raw
        var negate = false
        if token.hasPrefix("-") && token.count > 1 { negate = true; token.removeFirst() }
        func wrap(_ t: Term) -> Term { negate ? .not(t) : t }

        if token.hasPrefix("\"") {
            let phrase = token.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !phrase.isEmpty else { return nil }
            if !negate { highlightTerms.append(phrase) }
            return wrap(.text(phrase.lowercased(), titleOnly: titleOnly))
        }
        if token.hasPrefix("!#") {
            return wrap(.tag(MarkdownSyntax.normalizeTag(String(token.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "#"))).lowercased(), exact: true))
        }
        if token.hasPrefix("#*/") {
            return wrap(.tagSuffix(String(token.dropFirst(3)).lowercased()))
        }
        if token.hasPrefix("#") && token.count > 1 {
            return wrap(.tag(MarkdownSyntax.normalizeTag(String(token.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "#"))).lowercased(), exact: false))
        }
        if token.hasPrefix("@") {
            let lower = token.lowercased()
            if lower == "@title" { titleOnly = true; return nil }
            if let m = lower.wholeMatch(of: #/@(c?)date\(([<>]?)(\d{4}-\d{2}-\d{2})\)/#) {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.locale = Locale(identifier: "en_US_POSIX")
                guard let day = f.date(from: String(m.3)) else { return nil }
                return wrap(.date(created: !m.1.isEmpty, op: m.2.first ?? "=", day: day))
            }
            if let m = lower.wholeMatch(of: #/@last(\d+)days/#) { return wrap(.lastDays(created: false, Int(m.1) ?? 0)) }
            if let m = lower.wholeMatch(of: #/@created(\d+)days/#) { return wrap(.lastDays(created: true, Int(m.1) ?? 0)) }
            return wrap(.special(String(lower.dropFirst())))
        }
        if !negate { highlightTerms.append(token) }
        return wrap(.text(token.lowercased(), titleOnly: titleOnly))
    }

    static func tokenize(_ input: String) -> [String] {
        // Protect spaces inside `#multi word tags#` so they survive splitting.
        var s = input
        let ns = input as NSString
        for m in MarkdownSyntax.multiWordTag.matches(in: input, range: NSRange(location: 0, length: ns.length)).reversed() {
            s = (s as NSString).replacingCharacters(in: m.range, with: ns.substring(with: m.range).replacingOccurrences(of: " ", with: "\u{1}"))
        }
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var depth = 0
        for c in s {
            if c == "\"" {
                current.append(c)
                if inQuote { tokens.append(current); current = "" }
                inQuote.toggle()
            } else if c == "(" && !inQuote {
                depth += 1; current.append(c)
            } else if c == ")" && !inQuote {
                depth = max(0, depth - 1); current.append(c)
            } else if c.isWhitespace && !inQuote && depth == 0 {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.map { $0.replacingOccurrences(of: "\u{1}", with: " ") }
    }

    public func matches(_ note: Note, context: SearchContext) -> Bool {
        groups.allSatisfy { group in group.contains { evaluate($0, note, context) } }
    }

    private func evaluate(_ term: Term, _ note: Note, _ ctx: SearchContext) -> Bool {
        let meta = note.meta
        switch term {
        case .not(let inner):
            return !evaluate(inner, note, ctx)
        case .text(let needle, let titleOnly):
            if titleOnly { return note.title.lowercased().contains(needle) }
            if note.isEncrypted { return note.title.lowercased().contains(needle) }
            if note.body.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            return (meta.imageIds + meta.fileIds).contains { id in
                ctx.attachments[id].map { $0.ocr.range(of: needle, options: .caseInsensitive) != nil || $0.name.lowercased().contains(needle) } ?? false
            }
        case .tag(let tag, let exact):
            return meta.tags.contains { t in
                let l = t.lowercased()
                return l == tag || (!exact && l.hasPrefix(tag + "/"))
            }
        case .tagSuffix(let suffix):
            return meta.tags.contains { t in let l = t.lowercased(); return l == suffix || l.hasSuffix("/" + suffix) }
        case .lastDays(let created, let days):
            let start = ctx.calendar.date(byAdding: .day, value: -max(0, days - 1), to: ctx.calendar.startOfDay(for: ctx.now))!
            return (created ? note.created : note.modified) >= start
        case .date(let created, let op, let day):
            let d = ctx.calendar.startOfDay(for: created ? note.created : note.modified)
            let target = ctx.calendar.startOfDay(for: day)
            switch op {
            case "<": return d < target
            case ">": return d > target
            default: return d == target
            }
        case .special(let name):
            let cal = ctx.calendar
            switch name {
            case "tagged": return !meta.tags.isEmpty
            case "untagged": return meta.tags.isEmpty
            case "today": return cal.isDate(note.modified, inSameDayAs: ctx.now)
            case "ctoday": return cal.isDate(note.created, inSameDayAs: ctx.now)
            case "yesterday": return cal.isDate(note.modified, inSameDayAs: cal.date(byAdding: .day, value: -1, to: ctx.now)!)
            case "cyesterday": return cal.isDate(note.created, inSameDayAs: cal.date(byAdding: .day, value: -1, to: ctx.now)!)
            case "images": return !meta.imageIds.isEmpty
            case "files": return !meta.fileIds.isEmpty
            case "attachments": return !meta.imageIds.isEmpty || !meta.fileIds.isEmpty
            case "task", "tasks": return meta.openTodos + meta.doneTodos > 0
            case "todo": return meta.openTodos > 0
            case "done": return meta.doneTodos > 0 && meta.openTodos == 0
            case "code": return meta.hasCode
            case "locked": return note.isEncrypted
            case "pinned": return note.pinned
            case "untitled": return note.isUntitled
            case "empty": return !note.isEncrypted && note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "wikilinks": return !meta.wikiLinks.isEmpty
            case "backlinks": return ctx.backlinked.contains(note.id)
            case "archived": return note.archived
            case "conflict", "conflicted": return note.conflictOf != nil
            case "ocr": return (meta.imageIds + meta.fileIds).contains { !(ctx.attachments[$0]?.ocr.isEmpty ?? true) }
            default: return true
            }
        }
    }
}
