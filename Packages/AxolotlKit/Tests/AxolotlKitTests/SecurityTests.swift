import XCTest
@testable import AxolotlKit

@MainActor
final class SecurityTests: XCTestCase {
    var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    func makeReplica(_ name: String) throws -> Replica {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-sec-\(UUID().uuidString)")
        dirs.append(dir)
        return try Replica(directory: dir, deviceId: name)
    }

    func exchange(_ a: Replica, _ b: Replica) {
        let toB = a.rows(after: b.vector)
        a.markSent(toB)
        b.apply(toB, markDirty: true)
        let toA = b.rows(after: a.vector)
        b.markSent(toA)
        a.apply(toA, markDirty: true)
    }

    func testLockingANotePurgesItsPlaintextHistoryEverywhere() throws {
        let a = try makeReplica("aaaa"), b = try makeReplica("bbbb")
        let id = a.createNote(body: "# Diary\nfirst secret")
        exchange(a, b)
        a.updateBody(id, "# Diary\nfirst secret\nsecond secret")
        exchange(a, b)
        XCTAssertTrue(a.revisions(for: id).contains { $0.text.contains("first secret") })
        XCTAssertTrue(b.revisions(for: id).contains { $0.text.contains("second secret") })

        let key = NoteCrypto.deriveKey(password: "pw", salt: NoteCrypto.makeSalt(), iterations: 1000)
        a.updateBody(id, try NoteCrypto.encrypt("# Diary\nfirst secret\nsecond secret", key: key))
        exchange(a, b)

        for r in [a, b] {
            let history = r.revisions(for: id)
            XCTAssertFalse(history.isEmpty)
            XCTAssertTrue(history.allSatisfy { NoteCrypto.isEncrypted($0.text) }, "plaintext revision survived on \(r.deviceId)")
            XCTAssertTrue(r.notes[id]!.isEncrypted)
        }
    }

    func testGarbageCollectionRemovesOrphanedBlobs() throws {
        let r = try makeReplica("aaaa")
        let id = r.createNote(body: "with file")
        let kept = try r.addAttachment(data: Data("keep".utf8), name: "k.txt", mime: "text/plain", noteId: r.createNote(body: "other"))
        let gone = try r.addAttachment(data: Data("gone".utf8), name: "g.txt", mime: "text/plain", noteId: id)
        XCTAssertTrue(r.hasBlob(gone.hash))
        r.deleteForever(id)
        XCTAssertEqual(r.collectGarbageBlobs(), 1)
        XCTAssertFalse(r.hasBlob(gone.hash))
        XCTAssertTrue(r.hasBlob(kept.hash))
    }

    func testBlobLookupsOnlyAcceptContentHashes() throws {
        let r = try makeReplica("aaaa")
        XCTAssertNil(r.blob("../../etc/passwd"))
        XCTAssertFalse(r.hasBlob("../axolotl.sqlite"))
        XCTAssertFalse(Replica.isValidBlobHash("Z".padding(toLength: 64, withPad: "Z", startingAt: 0)))
        XCTAssertTrue(Replica.isValidBlobHash(Data("x".utf8).sha256))
        XCTAssertEqual(r.blobURL("../escape").lastPathComponent, "invalid")
    }

    func testExportedLinksRefuseScriptSchemes() {
        XCTAssertNil(MarkdownHTML.safeHref("javascript:alert(1)"))
        XCTAssertNil(MarkdownHTML.safeHref(" JavaScript:alert(1)"))
        XCTAssertNil(MarkdownHTML.safeHref("data:text/html;base64,AAAA"))
        XCTAssertEqual(MarkdownHTML.safeHref("https://example.com/a?b=c:d"), "https://example.com/a?b=c:d")
        XCTAssertEqual(MarkdownHTML.safeHref("mailto:hi@example.com"), "mailto:hi@example.com")
        XCTAssertEqual(MarkdownHTML.safeHref("notes/relative.html"), "notes/relative.html")
        XCTAssertNotNil(MarkdownHTML.safeHref("data:image/png;base64,AAAA", allowImageData: true))
        let html = MarkdownHTML().render("[click](javascript:alert(1)) and ![x](javascript:alert(2)) and [ok](https://example.com)")
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
    }

    func testFastForwardPathStillWorksWithEncryptedBodies() throws {
        // An encrypted note edited many times on one device must still land on another without conflicts.
        let a = try makeReplica("aaaa"), b = try makeReplica("bbbb")
        let key = NoteCrypto.deriveKey(password: "pw", salt: NoteCrypto.makeSalt(), iterations: 1000)
        let id = a.createNote(body: try NoteCrypto.encrypt("v0", key: key))
        exchange(a, b)
        for i in 1...5 {
            a.updateBody(id, try NoteCrypto.encrypt("v\(i)", key: key))
            a.markSent(a.rows(after: [:]))
        }
        exchange(a, b)
        XCTAssertEqual(try NoteCrypto.decrypt(b.notes[id]!.body, key: key), "v5")
        XCTAssertEqual(b.liveNotes.count, 1)
    }
}
