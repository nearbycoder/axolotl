import XCTest
@testable import AxolotlKit

/// Timing checks for the paths that scale with library size. Numbers are printed with a
/// `PERF` prefix; the assertions are deliberately loose so CI noise does not fail them.
@MainActor
final class PerformanceTests: XCTestCase {
    var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-perf-\(UUID().uuidString)")
        dirs.append(d)
        return d
    }

    @discardableResult
    func time(_ label: String, _ block: () throws -> Void) rethrows -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        try block()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "PERF %@: %.1f ms", label, ms))
        return ms
    }

    static func sampleBody(_ i: Int) -> String {
        """
        # Note \(i) about something

        Some **bold** text, *italic* words and a [[Note \(max(0, i - 1)) about something]] link. #tag\(i % 40)/sub\(i % 7)

        - [ ] open task \(i)
        - [x] done task
        - a plain bullet with `inline code`

        > [!NOTE]
        > A callout that spans
        > two lines.

        ```swift
        let x = \(i)
        ```
        """
    }

    func seededReplica(notes: Int) throws -> (Replica, URL) {
        let dir = tempDir()
        let r = try Replica(directory: dir, deviceId: "seed")
        for i in 0..<notes { r.createNote(body: Self.sampleBody(i)) }
        return (r, dir)
    }

    func testLaunchWithLargeLibrary() throws {
        let (_, dir) = try seededReplica(notes: 4000)
        var reopened: Replica?
        let ms = time("Replica.init with 4000 notes") { reopened = try? Replica(directory: dir) }
        XCTAssertEqual(reopened?.liveNotes.count, 4000)
        XCTAssertLessThan(ms, 4000)
    }

    func testRowsAfterVector() throws {
        let (r, _) = try seededReplica(notes: 4000)
        var everything = 0
        time("rows(after: empty) over 12k records") { everything = r.rows(after: [:]).count }
        XCTAssertEqual(everything, 4000 * 3)
        // A peer that is fully caught up should cost almost nothing.
        var nothing = 0
        let ms = time("rows(after: caught-up vector) ×20") { for _ in 0..<20 { nothing += r.rows(after: r.vector).count } }
        XCTAssertEqual(nothing, 0)
        XCTAssertLessThan(ms, 2000)
    }

    func testParseLargeNote() {
        let body = (0..<1500).map(Self.sampleBody).joined(separator: "\n\n")
        print("PERF note size: \(body.utf8.count / 1024) KB")
        var meta = NoteMeta()
        let ms = time("NoteParser.parse 1500-section note") { meta = NoteParser.parse(body) }
        XCTAssertEqual(meta.headings.count, 1500)
        XCTAssertLessThan(ms, 3000)
    }

    func testMergeOfHeavilyDivergentTexts() {
        let base = (0..<8000).map { "word\($0)" }.joined(separator: " ")
        let ours = (0..<8000).map { $0 % 3 == 0 ? "ours\($0)" : "word\($0)" }.joined(separator: " ")
        let theirs = (0..<8000).map { $0 % 5 == 0 ? "theirs\($0)" : "word\($0)" }.joined(separator: " ")
        var merged = ""
        let ms = time("TextMerge.merge 8000 words, ~4000 edits") { merged = TextMerge.merge(base: base, ours: ours, theirs: theirs, oursIsPrimary: true) }
        XCTAssertTrue(merged.contains("ours3") && merged.contains("theirs5"))
        XCTAssertLessThan(ms, 5000)
    }

    func testSearchOverLibrary() throws {
        let (r, _) = try seededReplica(notes: 4000)
        let notes = r.liveNotes
        let ctx = SearchContext()
        var hits = 0
        let ms = time("SearchQuery over 4000 notes ×5 queries") {
            for q in ["@todo #tag3", "\"bold\" -done", "note OR task", "@code", "@untagged"] {
                let query = SearchQuery(q)
                hits += notes.filter { query.matches($0, context: ctx) }.count
            }
        }
        XCTAssertGreaterThan(hits, 0)
        XCTAssertLessThan(ms, 3000)
    }
}
