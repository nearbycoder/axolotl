import Foundation

/// Token-level diff and three-way merge used to reconcile concurrent edits of a note body.
public enum TextMerge {
    /// A replaced region: `base[baseStart..<baseEnd]` became `side[sideStart..<sideEnd]`.
    struct Hunk {
        var baseStart: Int
        var baseEnd: Int
        var sideStart: Int
        var sideEnd: Int
    }

    /// Splits text into words, runs of horizontal whitespace, newlines and single punctuation marks.
    static func tokenize(_ text: String) -> [Substring] {
        var tokens: [Substring] = []
        var start = text.startIndex
        var kind = -1
        func classify(_ c: Character) -> Int {
            if c == "\n" || c == "\r\n" { return 2 }
            if c.isWhitespace { return 1 }
            if c.isLetter || c.isNumber || c == "_" { return 0 }
            return 3
        }
        var i = text.startIndex
        while i < text.endIndex {
            let k = classify(text[i])
            if i == start {
                kind = k
            } else if k != kind || k >= 2 {
                tokens.append(text[start..<i])
                start = i
                kind = k
            }
            i = text.index(after: i)
        }
        if start < text.endIndex { tokens.append(text[start...]) }
        return tokens
    }

    /// Myers O(ND) diff over integer token ids. Falls back to a single hunk when the edit distance is huge.
    /// The trace is O(D²) in memory (about 32 MB at the default bound), so the bound matters on iPhone.
    static func diff(_ a: [Int], _ b: [Int], maxEdits: Int = 2000) -> [Hunk] {
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let a2 = Array(a[prefix..<(a.count - suffix)])
        let b2 = Array(b[prefix..<(b.count - suffix)])
        let n = a2.count, m = b2.count
        if n == 0 && m == 0 { return [] }
        if n == 0 || m == 0 { return [Hunk(baseStart: prefix, baseEnd: prefix + n, sideStart: prefix, sideEnd: prefix + m)] }

        let maxD = min(n + m, maxEdits)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        var finalD = 0
        outer: for d in 0...maxD {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n && y < m && a2[x] == b2[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m {
                    found = true
                    finalD = d
                    break outer
                }
                k += 2
            }
        }
        if !found {
            return [Hunk(baseStart: prefix, baseEnd: prefix + n, sideStart: prefix, sideEnd: prefix + m)]
        }

        // Backtrack to collect matching (x, y) diagonal points.
        var matches: [(Int, Int)] = []
        var x = n, y = m
        var d = finalD
        while d > 0 {
            let vd = trace[d]
            func vAt(_ k: Int) -> Int { vd[k + d] }
            let k = x - y
            let prevK = (k == -d || (k != d && vAt(k - 1) < vAt(k + 1))) ? k + 1 : k - 1
            let prevX = vAt(prevK)
            let prevY = prevX - prevK
            while x > prevX && y > prevY {
                x -= 1; y -= 1
                matches.append((x, y))
            }
            x = prevX
            y = prevY
            d -= 1
        }
        while x > 0 && y > 0 {
            x -= 1; y -= 1
            matches.append((x, y))
        }
        matches.reverse()

        var hunks: [Hunk] = []
        var ai = 0, bi = 0
        for (mx, my) in matches {
            if mx > ai || my > bi {
                hunks.append(Hunk(baseStart: prefix + ai, baseEnd: prefix + mx, sideStart: prefix + bi, sideEnd: prefix + my))
            }
            ai = mx + 1
            bi = my + 1
        }
        if ai < n || bi < m {
            hunks.append(Hunk(baseStart: prefix + ai, baseEnd: prefix + n, sideStart: prefix + bi, sideEnd: prefix + m))
        }
        return hunks
    }

    /// Three-way merge. Non-overlapping edits from both sides are combined; where both sides changed the
    /// same region differently, the `primary` side's text comes first followed by the other's, so no
    /// content is lost and the result does not depend on which replica performs the merge.
    public static func merge(base: String, ours: String, theirs: String, oursIsPrimary: Bool) -> String {
        if ours == theirs { return ours }
        if base == ours { return theirs }
        if base == theirs { return ours }

        var ids: [Substring: Int] = [:]
        func encode(_ tokens: [Substring]) -> [Int] {
            tokens.map { t in
                if let id = ids[t] { return id }
                let id = ids.count
                ids[t] = id
                return id
            }
        }
        let bT = tokenize(base), oT = tokenize(ours), tT = tokenize(theirs)
        let b = encode(bT), o = encode(oT), t = encode(tT)
        let oh = diff(b, o), th = diff(b, t)

        struct Tagged { var hunk: Hunk; var side: Int } // 0 = ours, 1 = theirs
        var all = oh.map { Tagged(hunk: $0, side: 0) } + th.map { Tagged(hunk: $0, side: 1) }
        all.sort { ($0.hunk.baseStart, $0.hunk.baseEnd, $0.side) < ($1.hunk.baseStart, $1.hunk.baseEnd, $1.side) }

        var out = ""
        var basePos = 0
        var i = 0
        while i < all.count {
            var group = [all[i]]
            var gStart = all[i].hunk.baseStart
            var gEnd = all[i].hunk.baseEnd
            var j = i + 1
            while j < all.count {
                let h = all[j].hunk
                let overlaps = h.baseStart < gEnd || (h.baseStart == gEnd && (h.baseStart == h.baseEnd || gStart == gEnd))
                guard overlaps else { break }
                group.append(all[j])
                gStart = min(gStart, h.baseStart)
                gEnd = max(gEnd, h.baseEnd)
                j += 1
            }
            for k in basePos..<gStart { out += bT[k] }

            func render(side: Int, tokens: [Substring]) -> String {
                var s = ""
                var pos = gStart
                for g in group where g.side == side {
                    for k in pos..<g.hunk.baseStart { s += bT[k] }
                    for k in g.hunk.sideStart..<g.hunk.sideEnd { s += tokens[k] }
                    pos = g.hunk.baseEnd
                }
                for k in pos..<gEnd { s += bT[k] }
                return s
            }
            let sides = Set(group.map(\.side))
            if sides.count == 1 {
                out += render(side: group[0].side, tokens: group[0].side == 0 ? oT : tT)
            } else {
                let mine = render(side: 0, tokens: oT)
                let other = render(side: 1, tokens: tT)
                if mine == other {
                    out += mine
                } else {
                    let first = oursIsPrimary ? mine : other
                    let second = oursIsPrimary ? other : mine
                    out += first
                    if let l = first.last, let f = second.first, !l.isWhitespace, !f.isWhitespace { out += " " }
                    out += second
                }
            }
            basePos = gEnd
            i = j
        }
        for k in basePos..<bT.count { out += bT[k] }
        return out
    }

    /// Minimal single-region edit turning `old` into `new`, in UTF-16 units.
    /// Used by editors to apply remote changes without resetting the caret.
    public static func singleEdit(from old: String, to new: String) -> (range: NSRange, replacement: String)? {
        if old == new { return nil }
        let a = Array(old.utf16), b = Array(new.utf16)
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        // Avoid splitting surrogate pairs.
        while p > 0 && p < a.count && UTF16.isTrailSurrogate(a[p]) { p -= 1 }
        while s > 0 && UTF16.isTrailSurrogate(a[a.count - s]) { s -= 1 }
        let replacement = String(decoding: b[p..<(b.count - s)], as: UTF16.self)
        return (NSRange(location: p, length: a.count - s - p), replacement)
    }
}
