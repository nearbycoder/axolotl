import Foundation
import AxolotlKit

/// One Model Context Protocol conversation, independent of transport.
///
/// Speaks both protocol eras: clients that open with `initialize` (2025-11-25 and earlier) and
/// clients that use `server/discover` with a protocol version in each request's `_meta`
/// (2026-07-28). Messages are newline-delimited JSON-RPC 2.0.
@MainActor
final class MCPSession {
    static let modernVersions = ["2026-07-28"]
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static var supportedVersions: [String] { modernVersions + legacyVersions }
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    let toolbox: AgentToolbox
    /// Who is connected, for the activity log ("Claude Code", "axolotl CLI", …).
    private(set) var clientName = "Agent"
    /// Version agreed through `initialize`, when the client uses the legacy handshake.
    private(set) var legacyVersion: String?

    init(toolbox: AgentToolbox) { self.toolbox = toolbox }

    var serverInfo: JSONObject {
        ["name": "axolotl", "title": "Axolotl Notes",
         "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"]
    }

    var capabilities: JSONObject {
        ["tools": ["listChanged": false] as JSONObject, "resources": ["listChanged": false, "subscribe": false] as JSONObject]
    }

    /// Handles one incoming message. Returns the encoded response, or nil for notifications.
    func handle(_ data: Data) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let message = object as? JSONObject else {
            return encode(error: nil, code: -32700, message: "Parse error")
        }
        guard let method = message["method"] as? String else { return nil } // a response or junk: ignore
        let id = message["id"]
        let params = message["params"] as? JSONObject ?? [:]
        guard id != nil else { return nil } // notifications (initialized, cancelled, …) need no reply

        // Modern requests carry their protocol version in _meta.
        let meta = params["_meta"] as? JSONObject
        let requestVersion = meta?[Self.versionKey] as? String
        if let requestVersion, !Self.supportedVersions.contains(requestVersion) {
            return encode(error: id, code: -32022, message: "Unsupported protocol version \(requestVersion)",
                          data: ["supported": Self.supportedVersions])
        }
        let modern = requestVersion.map(Self.modernVersions.contains) ?? false

        do {
            let result: JSONObject
            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String ?? Self.legacyVersions[0]
                let version = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
                legacyVersion = version
                if let info = params["clientInfo"] as? JSONObject, let name = info["name"] as? String { clientName = name }
                result = ["protocolVersion": version, "capabilities": capabilities, "serverInfo": serverInfo,
                          "instructions": AgentToolbox.instructions]
            case "server/discover":
                if let info = (meta?["io.modelcontextprotocol/clientInfo"] as? JSONObject)?["name"] as? String { clientName = info }
                result = ["supportedVersions": Self.supportedVersions, "capabilities": capabilities,
                          "instructions": AgentToolbox.instructions, "ttlMs": 0, "cacheScope": "private",
                          "_meta": [Self.serverInfoKey: serverInfo] as JSONObject]
            case "ping":
                result = [:]
            case "logging/setLevel":
                result = [:]
            case "tools/list":
                result = ["tools": toolbox.tools.map(\.definition)]
            case "tools/call":
                result = await callTool(params)
            case "resources/list":
                result = ["resources": resources()]
            case "resources/templates/list":
                result = ["resourceTemplates": [["uriTemplate": "axolotl://note/{id}", "name": "note", "title": "Axolotl note",
                                                 "description": "A note's Markdown, by id.", "mimeType": "text/markdown"] as JSONObject]]
            case "resources/read":
                result = try readResource(params)
            case "prompts/list":
                result = ["prompts": [] as [Any]]
            default:
                return encode(error: id, code: -32601, message: "Method not found: \(method)")
            }
            return encode(result: decorate(result, method: method, modern: modern), id: id)
        } catch let error as ProtocolError {
            return encode(error: id, code: error.code, message: error.message)
        } catch {
            return encode(error: id, code: -32603, message: error.localizedDescription)
        }
    }

    struct ProtocolError: Error { var code: Int; var message: String }

    /// Adds the fields the 2026-07-28 revision requires on results.
    private func decorate(_ result: JSONObject, method: String, modern: Bool) -> JSONObject {
        guard modern else { return result }
        var r = result
        r["resultType"] = r["resultType"] ?? "complete"
        if ["tools/list", "resources/list", "resources/read", "resources/templates/list", "prompts/list"].contains(method) {
            r["ttlMs"] = r["ttlMs"] ?? 0
            r["cacheScope"] = r["cacheScope"] ?? "private"
        }
        return r
    }

    private func callTool(_ params: JSONObject) async -> JSONObject {
        guard let name = params["name"] as? String, let tool = toolbox.tool(named: name) else {
            let name = params["name"] as? String ?? "?"
            return ["content": [["type": "text", "text": "Unknown tool '\(name)'."]], "isError": true]
        }
        let args = ToolArgs(raw: params["arguments"] as? JSONObject ?? [:])
        do {
            let output = try await tool.handler(args)
            toolbox.model.recordAgentActivity(name, client: clientName, summary: Self.describe(args), failed: false)
            if let content = output as? ToolContent {
                var r: JSONObject = ["content": content.blocks]
                if let s = content.structured { r["structuredContent"] = s }
                return r
            }
            let json = Self.jsonText(output)
            var r: JSONObject = ["content": [["type": "text", "text": json]]]
            if output is JSONObject { r["structuredContent"] = output }
            return r
        } catch {
            toolbox.model.recordAgentActivity(name, client: clientName, summary: error.localizedDescription, failed: true)
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    private func resources() -> [JSONObject] {
        toolbox.model.notes(for: .notes, search: "", sort: .modified).prefix(100).filter { !$0.isEncrypted }.map { n in
            ["uri": "axolotl://note/\(n.id)", "name": n.id, "title": n.isUntitled ? "Untitled" : n.title,
             "description": n.meta.preview, "mimeType": "text/markdown"]
        }
    }

    private func readResource(_ params: JSONObject) throws -> JSONObject {
        guard let uri = params["uri"] as? String, uri.hasPrefix("axolotl://note/") else {
            throw ProtocolError(code: -32602, message: "Unknown resource")
        }
        let id = String(uri.dropFirst("axolotl://note/".count))
        guard let note = toolbox.model.notes[id], !note.deleted else { throw ProtocolError(code: -32602, message: "Resource not found: \(uri)") }
        let text: String
        do { text = try toolbox.readableText(note) } catch { throw ProtocolError(code: -32602, message: error.localizedDescription) }
        return ["contents": [["uri": uri, "mimeType": "text/markdown", "text": text] as JSONObject]]
    }

    // MARK: Encoding

    static func jsonText(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func describe(_ args: ToolArgs) -> String {
        for key in ["note", "query", "title", "tag", "attachment", "paths"] {
            if let v = args.raw[key] as? String { return v.count > 60 ? String(v.prefix(60)) + "…" : v }
            if let v = args.raw[key] as? [String] { return v.joined(separator: ", ") }
        }
        return ""
    }

    private func encode(result: JSONObject, id: Any?) -> Data {
        line(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func encode(error id: Any?, code: Int, message: String, data: Any? = nil) -> Data {
        var err: JSONObject = ["code": code, "message": message]
        if let data { err["data"] = data }
        return line(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": err])
    }

    private func line(_ object: JSONObject) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encoding failed"}}"#.utf8)
        data.append(0x0A)
        return data
    }
}
