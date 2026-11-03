import XCTest
@testable import AxolotlKit

/// Two replicas discover each other over Bonjour and sync over TCP in-process.
@MainActor
final class LANTests: XCTestCase {
    func testPeersSyncOverLocalNetwork() async throws {
        guard ProcessInfo.processInfo.environment["AXOLOTL_LAN_TEST"] == "1" else {
            throw XCTSkip("Set AXOLOTL_LAN_TEST=1 to run (needs local network access)")
        }
        let tmp = FileManager.default.temporaryDirectory
        let a = try Replica(directory: tmp.appendingPathComponent("lan-a-\(UUID())"), deviceId: "aaaa\(Int.random(in: 1000...9999))")
        let b = try Replica(directory: tmp.appendingPathComponent("lan-b-\(UUID())"), deviceId: "bbbb\(Int.random(in: 1000...9999))")
        let keys = try XCTUnwrap(VaultKeys(syncCode: VaultKeys.generateCode()))
        let id = a.createNote(body: "Hello from A")
        _ = try a.addAttachment(data: Data("pixels".utf8), name: "p.png", mime: "image/png", noteId: id)
        let la = LANSync(replica: a, keys: keys, deviceName: "A")
        let lb = LANSync(replica: b, keys: keys, deviceName: "B")
        la.start(); lb.start()
        defer { la.stop(); lb.stop() }

        for _ in 0..<150 where b.notes[id]?.body != "Hello from A" || !b.missingBlobs.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(b.notes[id]?.body, "Hello from A")
        XCTAssertTrue(b.missingBlobs.isEmpty, "blob should transfer over LAN")

        b.updateBody(id, "Hello from A and B")
        lb.broadcast()
        for _ in 0..<100 where a.notes[id]?.body != "Hello from A and B" {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(a.notes[id]?.body, "Hello from A and B")
    }
}
