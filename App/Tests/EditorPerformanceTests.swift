import XCTest
import AxolotlKit
@testable import Axolotl

/// Editor and model timings. Printed with a `PERF` prefix; assertions are loose upper bounds.
@MainActor
final class EditorPerformanceTests: XCTestCase {
    static let style = EditorStyle(theme: Theme.named("axolotl"), font: EditorFont.all[0], fontSize: 17, lineHeight: 1.35,
                                   paragraphSpacing: 6, dimMarkdown: true, hideMarkdown: true)

    static func markdown(sections: Int) -> String {
        (0..<sections).map { i in
            """
            ## Section \(i)

            A paragraph with **bold**, *italic*, ==highlight==, `code`, a [link](https://example.com/\(i)) and #tag\(i % 9).

            - [ ] todo item \(i)
            - [x] done item
            - bullet with [[Section \(i)]]

            > [!TIP]
            > Quoted text that
            > continues here.

            ```swift
            func f\(i)() { return \(i) }
            ```
            """
        }.joined(separator: "\n\n")
    }

    @discardableResult
    func time(_ label: String, _ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "PERF %@: %.1f ms", label, ms))
        return ms
    }

    func makeEditor(_ md: String) -> (NSTextStorage, MarkdownStorageDelegate, MarkdownLayoutManager, NSTextContainer, MarkupHider) {
        let storage = NSTextStorage()
        let delegate = MarkdownStorageDelegate(style: Self.style)
        storage.delegate = delegate
        let layout = MarkdownLayoutManager(style: Self.style)
        let container = NSTextContainer(size: CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 6
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let hider = MarkupHider()
        layout.delegate = hider
        delegate.suspended = true
        storage.setAttributedString(NSAttributedString(string: md))
        delegate.suspended = false
        return (storage, delegate, layout, container, hider)
    }

    func testInitialHighlightOfLargeNote() {
        let md = Self.markdown(sections: 800)
        print("PERF note size: \(md.utf8.count / 1024) KB, \(md.split(separator: "\n").count) lines")
        let (storage, delegate, _, _, _) = makeEditor(md)
        let ms = time("rehighlightAll 800 sections") { delegate.rehighlight(storage) }
        XCTAssertLessThan(ms, 5000)
    }

    func testKeystrokesInLargeNote() {
        let md = Self.markdown(sections: 800)
        let (storage, delegate, _, _, _) = makeEditor(md)
        delegate.rehighlight(storage)
        let middle = storage.length / 2
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: middle, length: 0))
        var loc = NSMaxRange(paragraph) - 1
        let ms = time("60 keystrokes mid-note") {
            for ch in "the quick brown fox jumps over the lazy dog and keeps on going..." {
                storage.replaceCharacters(in: NSRange(location: loc, length: 0), with: String(ch))
                loc += 1
            }
        }
        print(String(format: "PERF per keystroke: %.2f ms", ms / 60))
        XCTAssertLessThan(ms / 60, 50)
    }

    func testLayoutWithHiddenSyntax() {
        let md = Self.markdown(sections: 300)
        let (storage, delegate, layout, container, hider) = makeEditor(md)
        delegate.rehighlight(storage)
        let ms = time("ensureLayout 300 sections with hider") { layout.ensureLayout(for: container) }
        XCTAssertLessThan(ms, 8000)
        // Moving the caret reveals one paragraph and re-hides the previous one.
        let text = storage.string as NSString
        var cost = 0.0
        for i in 0..<20 {
            let loc = text.length * i / 20
            let para = text.paragraphRange(for: NSRange(location: loc, length: 0))
            let old = hider.revealed
            hider.revealed = para
            cost += time("reveal paragraph \(i)") {
                for r in [old, para] where r.location != NSNotFound {
                    layout.invalidateGlyphs(forCharacterRange: r, changeInLength: 0, actualCharacterRange: nil)
                    layout.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
                }
                layout.ensureLayout(for: container)
            }
        }
        print(String(format: "PERF average reveal: %.2f ms", cost / 20))
    }

    func testModelListOperations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-model-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let r = try Replica(directory: dir)
            for i in 0..<4000 {
                r.createNote(body: "# Note \(i)\n\nBody text number \(i) with #tag\(i % 50) and more words.\n\n- [\(i % 4 == 0 ? " " : "x")] task\n")
            }
        }
        var model: AppModel!
        let launch = time("AppModel init with 4000 notes") { model = AppModel(dataDirectory: dir) }
        XCTAssertLessThan(launch, 6000)
        time("notes(for: .notes) sorted by modified ×10") { for _ in 0..<10 { _ = model.notes(for: .notes, search: "", sort: .modified) } }
        time("notes(for: .notes) sorted by title ×10") { for _ in 0..<10 { _ = model.notes(for: .notes, search: "", sort: .title) } }
        time("count(for: .todo) ×10") { for _ in 0..<10 { _ = model.count(for: .todo) } }
        time("search '#tag3 @todo' ×10") { for _ in 0..<10 { _ = model.notes(for: .notes, search: "#tag3 @todo", sort: .modified) } }
        time("single note edit → model update") { model.updateText(model.liveNotes[0].id, "# Edited\n\nnew body #tag1\n") }
    }

    func testImageDecoding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-img-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(dataDirectory: dir)
        let noteId = model.createNote(body: "# Photos\n")
        // A 16-megapixel JPEG, roughly what a phone camera produces.
        let size = CGSize(width: 4600, height: 3450)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.systemPink.setFill()
        NSBezierPath(ovalIn: NSRect(x: 400, y: 300, width: 3000, height: 2400)).fill()
        image.unlockFocus()
        let jpeg = try XCTUnwrap(image.jpegData(quality: 0.9))
        print("PERF jpeg size: \(jpeg.count / 1024) KB")
        var ids: [String] = []
        time("addFiles (store + re-encode) ×3") {
            for _ in 0..<3 { _ = model.addFiles([(jpeg, "photo.jpg", "image/jpeg")], to: noteId) }
            ids = model.attachments.keys.sorted()
        }
        let url = model.replica.blobURL(model.attachments[ids[0]]!.hash)
        var full: PlatformImage?
        let naive = time("full decode via NSImage(contentsOf:) + draw") {
            full = NSImage(contentsOf: url)?.thumbnail(maxDimension: 2000)
        }
        XCTAssertNotNil(full)
        let editor = time("ImageIO downsample to 2000px (editor)") { XCTAssertNotNil(ImageLoader.downsampled(url: url, maxPixels: 2000)) }
        let thumb = time("ImageIO downsample to 240px (list thumbnail)") { XCTAssertNotNil(ImageLoader.downsampled(url: url, maxPixels: 240)) }
        let reencode = time("ImageIO re-encode 16MP JPEG to 2400px") { XCTAssertNotNil(ImageLoader.reencodedJPEG(jpeg, maxPixels: 2400, quality: 0.85)) }
        print(String(format: "PERF naive %.1f / editor %.1f / thumb %.1f / reencode %.1f ms", naive, editor, thumb, reencode))
        XCTAssertLessThan(thumb, naive)
    }
}
