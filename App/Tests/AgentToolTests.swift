import XCTest
import AxolotlKit
@testable import Axolotl

/// The agent surface (MCP tools) driven in-process, with emphasis on the safety rules.
@MainActor
final class AgentToolTests: XCTestCase {
    var dir: URL!
    var model: AppModel!
    var session: MCPSession!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-agent-\(UUID().uuidString)")
        model = AppModel(dataDirectory: dir)
        model.settings.agentsReadLockedNotes = false
        session = MCPSession(toolbox: AgentToolbox(model: model))
    }

    override func tearDown() async throws {
        model.settings.agentsReadLockedNotes = false
        try? FileManager.default.removeItem(at: dir)
    }

    func rpc(_ method: String, _ params: JSONObject = [:]) async throws -> JSONObject {
        let message: JSONObject = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message)
        let handled = await session.handle(data)
        let reply = try XCTUnwrap(handled)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? JSONObject)
    }

    func call(_ tool: String, _ args: JSONObject) async throws -> (JSONObject, Bool) {
        let reply = try await rpc("tools/call", ["name": tool, "arguments": args])
        let result = try XCTUnwrap(reply["result"] as? JSONObject)
        return (result["structuredContent"] as? JSONObject ?? [:], result["isError"] as? Bool ?? false)
    }

    func text(of result: JSONObject) -> String { result["text"] as? String ?? "" }

    func testToolDefinitionsAreWellFormed() async throws {
        let reply = try await rpc("tools/list")
        let list = try XCTUnwrap((reply["result"] as? JSONObject)?["tools"] as? [JSONObject])
        XCTAssertGreaterThanOrEqual(list.count, 35)
        XCTAssertEqual(Set(list.map { $0["name"] as! String }).count, list.count, "tool names are unique")
        for tool in list {
            let schema = try XCTUnwrap(tool["inputSchema"] as? JSONObject)
            XCTAssertEqual(schema["type"] as? String, "object")
            let annotations = try XCTUnwrap(tool["annotations"] as? JSONObject)
            let readOnly = annotations["readOnlyHint"] as? Bool ?? false
            let destructive = annotations["destructiveHint"] as? Bool ?? true
            XCTAssertFalse(readOnly && destructive, "\(tool["name"]!) can't be both read-only and destructive")
            for name in schema["required"] as? [String] ?? [] {
                XCTAssertNotNil((schema["properties"] as? JSONObject)?[name], "\(tool["name"]!) requires undeclared \(name)")
            }
        }
        let destructive = list.filter { ($0["annotations"] as? JSONObject)?["destructiveHint"] as? Bool == true }.map { $0["name"] as! String }
        XCTAssertTrue(Set(["delete_note_permanently", "empty_trash", "delete_tag", "replace_note_text"]).isSubset(of: destructive))
    }

    func testLockedNotesAreHiddenUnlessAllowedAndUnlocked() async throws {
        let id = model.createNote(body: "# Diary\n\nsecret words")
        await model.setEncryptionPassword("correct horse")
        model.encrypt(id)
        XCTAssertTrue(model.notes[id]!.isEncrypted)

        // Not allowed: unreadable even though the app has it unlocked.
        var (_, isError) = try await call("get_note", ["note": id])
        XCTAssertTrue(isError)
        let (listed, _) = try await call("list_notes", ["section": "locked"])
        let summary = try XCTUnwrap((listed["notes"] as? [JSONObject])?.first)
        XCTAssertNil(summary["preview"], "locked previews are not exposed")
        (_, isError) = try await call("edit_note", ["note": id, "find": "secret", "replace": "public"])
        XCTAssertTrue(isError)
        (_, isError) = try await call("unlock_note", ["note": id])
        XCTAssertTrue(isError)
        let found = try await call("search_notes", ["query": "secret"]).0
        XCTAssertEqual(found["total"] as? Int, 0, "search does not match encrypted text")

        // Allowed and unlocked: readable and editable, and stays encrypted.
        model.settings.agentsReadLockedNotes = true
        let (detail, err) = try await call("get_note", ["note": id])
        XCTAssertFalse(err)
        XCTAssertTrue(text(of: detail).contains("secret words"))
        (_, isError) = try await call("append_to_note", ["note": id, "text": "more"])
        XCTAssertFalse(isError)
        XCTAssertTrue(model.notes[id]!.isEncrypted, "edits keep the note encrypted")

        // Allowed but locked again in the app: refused.
        model.relockNotes()
        (_, isError) = try await call("get_note", ["note": id])
        XCTAssertTrue(isError)
        let resource = try await rpc("resources/read", ["uri": "axolotl://note/\(id)"])
        XCTAssertNotNil(resource["error"], "resources/read respects locking too")
    }

    func testAgentEditsAreUndoable() async throws {
        let id = model.createNote(body: "# Plan\n\nOriginal line")
        model.updateText(id, "# Plan\n\nOriginal line, edited by hand")
        _ = try await call("edit_note", ["note": id, "find": "edited by hand", "replace": "rewritten by an agent"])
        let listed = try await call("list_revisions", ["note": id]).0
        let revisions = try XCTUnwrap(listed["revisions"] as? [JSONObject])
        var texts: [String] = []
        for r in revisions {
            let revision = try await call("get_revision", ["note": id, "revision": r["revision"] as! String]).0
            texts.append(text(of: revision))
        }
        XCTAssertTrue(texts.contains("# Plan\n\nOriginal line, edited by hand"), "the pre-agent text is a restorable version")
        XCTAssertTrue(texts.contains { $0.contains("rewritten by an agent") })
    }

    func testTodosTagsAndErrors() async throws {
        let id = model.createNote(body: "# Groceries\n\n## List\n- [ ] milk\n\n## Notes\nbuy early\n\n#home")
        _ = try await call("add_todo", ["note": "Groceries", "text": "eggs", "heading": "List"])
        _ = try await call("set_todo", ["note": id, "match": "milk"])
        _ = try await call("tag_note", ["note": id, "add": ["errands/weekly"], "remove": ["home"]])
        let body = model.notes[id]!.body
        XCTAssertTrue(body.contains("## List\n- [x] milk\n- [ ] eggs\n\n## Notes"), body)
        XCTAssertTrue(body.hasSuffix("#errands/weekly\n"), body)
        XCTAssertFalse(body.contains("#home"))

        let plan = model.createNote(body: "# Plan\n\n## Priorities\n- [ ] one\n\n> [!NOTE]\n> context\n\n## Later\n")
        _ = try await call("add_todo", ["note": plan, "text": "two", "heading": "Priorities"])
        XCTAssertTrue(model.notes[plan]!.body.contains("- [ ] one\n- [ ] two\n\n> [!NOTE]"), "todos join the section's checklist")

        var (_, isError) = try await call("set_todo", ["note": id, "match": "caviar"])
        XCTAssertTrue(isError)
        (_, isError) = try await call("get_note", [:])
        XCTAssertTrue(isError, "missing required arguments are tool errors, not crashes")
        (_, isError) = try await call("no_such_tool", [:])
        XCTAssertTrue(isError)
        let handled = await session.handle(Data("{not json".utf8))
        let parse = try XCTUnwrap(handled)
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: parse) as? JSONObject)?["error"] as? JSONObject)?["code"] as? Int, -32700)
    }

    func testSettingsToolsCannotTouchSecurity() async throws {
        let (_, isError) = try await call("update_settings", ["light_theme": "dracula"])
        XCTAssertTrue(isError, "a dark theme can't be set as the light theme")
        _ = try await call("update_settings", ["dark_theme": "nord", "font_size": 99])
        XCTAssertEqual(model.settings.darkThemeId, "nord")
        XCTAssertEqual(model.settings.fontSize, 28, "values are clamped")
        let (_, rejected) = try await call("update_settings", ["agentsReadLockedNotes": true])
        XCTAssertFalse(rejected)
        XCTAssertFalse(model.settings.agentsReadLockedNotes, "security settings are not reachable by agents")
    }
}
