import XCTest
import AxolotlKit
@testable import Axolotl

@MainActor
final class ImportSecurityTests: XCTestCase {
    func testTextBundleImportCannotReadOutsideItsAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("evil.textbundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "top secret".write(to: root.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: bundle.appendingPathComponent("assets/ok.png"))
        let markdown = """
        # Evil
        ![escape](assets/../../secret.txt)
        ![encoded](assets/%2e%2e/%2e%2e/secret.txt)
        ![fine](assets/ok.png)
        """
        try markdown.write(to: bundle.appendingPathComponent("text.markdown"), atomically: true, encoding: .utf8)

        let model = AppModel(dataDirectory: root.appendingPathComponent("data"))
        XCTAssertEqual(ImportService.importFiles([bundle], into: model), 1)
        let attachments = Array(model.attachments.values)
        XCTAssertEqual(attachments.count, 1, "only the in-bundle asset may be attached")
        XCTAssertEqual(attachments.first?.name, "ok.png")
        for a in attachments {
            XCTAssertNotEqual(model.attachmentData(a.id), Data("top secret".utf8))
        }
    }
}
