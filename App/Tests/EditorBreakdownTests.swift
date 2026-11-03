import XCTest
import AxolotlKit
@testable import Axolotl

/// Isolates the cost of each editor layer so a regression points at a cause, not a symptom.
/// These numbers found two problems in 1.1: a Swift `NSTextStorage` subclass made layout ~45×
/// slower, and highlighting outside the storage's processing pass invalidated layout twice.
@MainActor
final class EditorBreakdownTests: XCTestCase {
    @discardableResult
    func time(_ label: String, _ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "PERF %@: %.1f ms", label, ms))
        return ms
    }

    func container() -> NSTextContainer {
        let c = NSTextContainer(size: CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        c.lineFragmentPadding = 6
        return c
    }

    func drivenStorage(_ md: String, style: EditorStyle) -> (NSTextStorage, MarkdownStorageDelegate) {
        let storage = NSTextStorage()
        let delegate = MarkdownStorageDelegate(style: style)
        storage.delegate = delegate
        delegate.suspended = true
        storage.setAttributedString(NSAttributedString(string: md))
        delegate.suspended = false
        delegate.rehighlight(storage)
        return (storage, delegate)
    }

    func testLayoutCostByLayer() {
        let md = EditorPerformanceTests.markdown(sections: 300)
        let style = EditorPerformanceTests.style

        let plain = NSTextStorage(string: md, attributes: [.font: style.bodyFont])
        let lmA = NSLayoutManager(), tcA = container()
        plain.addLayoutManager(lmA); lmA.addTextContainer(tcA)
        let a = time("A plain storage, plain attributes") { lmA.ensureLayout(for: tcA) }

        let (driven, _) = drivenStorage(md, style: style)
        let lmB = NSLayoutManager(), tcB = container()
        driven.addLayoutManager(lmB); lmB.addTextContainer(tcB)
        let b = time("B highlighted storage, no hider") { lmB.ensureLayout(for: tcB) }

        let lmC = MarkdownLayoutManager(style: style), tcC = container()
        let hider = MarkupHider()
        lmC.delegate = hider
        driven.addLayoutManager(lmC); lmC.addTextContainer(tcC)
        let c = time("C highlighted storage, editor layout manager + hider") { lmC.ensureLayout(for: tcC) }
        // Highlighting and hiding together may cost a few times plain layout, never an order of magnitude.
        XCTAssertLessThan(c, max(50, a * 6))
        XCTAssertLessThan(b, max(50, a * 6))

        let text = driven.string as NSString
        let para = text.paragraphRange(for: NSRange(location: text.length / 2, length: 0))
        hider.revealed = para
        let reveal = time("D reveal one paragraph mid-document") {
            lmC.invalidateGlyphs(forCharacterRange: para, changeInLength: 0, actualCharacterRange: nil)
            lmC.invalidateLayout(forCharacterRange: para, actualCharacterRange: nil)
            lmC.ensureLayout(for: tcC)
        }
        XCTAssertLessThan(reveal, max(100, c))
    }

    func testKeystrokeCostByLayer() {
        let md = EditorPerformanceTests.markdown(sections: 800)
        let style = EditorPerformanceTests.style
        let (driven, delegate) = drivenStorage(md, style: style)
        let snapshot = MarkdownStorageDelegate.snapshot(driven)
        time("fenced-block scan of 215 KB") { _ = MarkdownSyntax.fencedBlocks(in: snapshot) }
        time("snapshot ×20") { for _ in 0..<20 { _ = MarkdownStorageDelegate.snapshot(driven) } }
        let fences = MarkdownSyntax.fencedBlocks(in: snapshot)
        let para = snapshot.paragraphRange(for: NSRange(location: snapshot.length / 2, length: 0))
        time("highlight one paragraph ×20, batched") {
            for _ in 0..<20 {
                driven.beginEditing()
                MarkdownHighlighter.highlight(driven, range: para, style: style, fencedBlocks: fences, text: snapshot)
                driven.endEditing()
            }
        }
        var loc = NSMaxRange(para) - 1
        let noLayout = time("20 keystrokes, no layout manager") {
            for ch in "abcdefghijklmnopqrst" { driven.replaceCharacters(in: NSRange(location: loc, length: 0), with: String(ch)); loc += 1 }
        }
        let lm = NSLayoutManager(), tc = container()
        driven.addLayoutManager(lm); lm.addTextContainer(tc)
        let withLayout = time("20 keystrokes, layout manager attached") {
            for ch in "abcdefghijklmnopqrst" { driven.replaceCharacters(in: NSRange(location: loc, length: 0), with: String(ch)); loc += 1 }
        }
        print(String(format: "PERF per keystroke: %.2f ms without / %.2f ms with layout manager", noLayout / 20, withLayout / 20))
        _ = delegate
        let (small, _) = drivenStorage(EditorPerformanceTests.markdown(sections: 20), style: style)
        var sloc = small.length / 2
        let smallCost = time("20 keystrokes in a 20-section note") {
            for ch in "abcdefghijklmnopqrst" { small.replaceCharacters(in: NSRange(location: sloc, length: 0), with: String(ch)); sloc += 1 }
        }
        XCTAssertLessThan(smallCost / 20, 2)
    }
}
