import XCTest
@testable import AxolotlKit

/// Runs two replicas against the real Node sync server (skipped when Node is unavailable).
@MainActor
final class ServerIntegrationTests: XCTestCase {
    var server: Process?
    var dirs: [URL] = []

    override func tearDown() {
        server?.terminate()
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    func startServer(port: Int) throws -> URL {
        let serverScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("server/server.mjs")
        guard FileManager.default.fileExists(atPath: serverScript.path),
              let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("node or server not available") }
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-server-\(UUID().uuidString)")
        dirs.append(data)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [serverScript.path]
        p.environment = ["PORT": "\(port)", "HOST": "127.0.0.1", "DATA_DIR": data.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        server = p
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func replica(_ name: String) throws -> Replica {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-int-\(UUID().uuidString)")
        dirs.append(dir)
        return try Replica(directory: dir, deviceId: name)
    }

    func push(_ r: Replica, _ client: ServerClient) async throws {
        while true {
            let batch = r.takeDirtyRows()
            if batch.isEmpty { break }
            _ = try await client.push(batch.map(\.row))
            r.markClean(batch)
        }
    }

    /// Mirrors SyncManager: push, pull, then push any merge results.
    func sync(_ r: Replica, _ client: ServerClient, cursor: inout Int) async throws {
        try await push(r, client)
        while true {
            let page = try await client.pull(since: cursor)
            r.apply(page.rows, markDirty: false)
            cursor = page.cursor
            if !page.more { break }
        }
        try await push(r, client)
        for hash in r.blobsToUpload {
            if let data = r.blob(hash) { try await client.uploadBlob(hash, data: data) }
            r.markBlobUploaded(hash)
        }
        for hash in r.missingBlobs {
            if let data = try await client.downloadBlob(hash) { try r.putBlob(data, expectedHash: hash) }
        }
    }

    func testTwoDevicesSyncThroughServer() async throws {
        let base = try startServer(port: 18787)
        let keys = try XCTUnwrap(VaultKeys(syncCode: VaultKeys.generateCode()))
        let client = ServerClient(baseURL: base, keys: keys)
        for _ in 0..<50 {
            if (try? await client.health()) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let a = try replica("mac1"), b = try replica("ipad1")
        var ca = 0, cb = 0

        let id = a.createNote(body: "# Trip\n- passport\n- tickets\n")
        _ = try a.addAttachment(data: Data(repeating: 7, count: 5000), name: "map.png", mime: "image/png", noteId: id)
        try await sync(a, client, cursor: &ca)
        try await sync(b, client, cursor: &cb)
        XCTAssertEqual(b.notes[id]?.body, "# Trip\n- passport\n- tickets\n")
        XCTAssertEqual(b.attachments.values.first?.name, "map.png")
        XCTAssertTrue(b.missingBlobs.isEmpty, "blob should have downloaded")

        a.updateBody(id, "# Trip\n- passport\n- tickets\n- charger\n")
        b.updateBody(id, "# Paris Trip\n- passport\n- tickets\n")
        try await sync(a, client, cursor: &ca)
        try await sync(b, client, cursor: &cb)
        try await sync(a, client, cursor: &ca)
        try await sync(b, client, cursor: &cb)
        XCTAssertEqual(a.notes[id]?.body, "# Paris Trip\n- passport\n- tickets\n- charger\n")
        XCTAssertEqual(b.notes[id]?.body, a.notes[id]?.body)

        // A device with the wrong key cannot read anything.
        let intruder = ServerClient(baseURL: base, keys: try XCTUnwrap(VaultKeys(syncCode: VaultKeys.generateCode())))
        let other = try await intruder.pull(since: 0)
        XCTAssertTrue(other.rows.isEmpty)
    }
}
