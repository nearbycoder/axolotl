// axolotl — command line access to Axolotl, and its MCP server for AI agents.
//
//   axolotl mcp                     run as an MCP server on stdio (for Claude Code, Claude Desktop, Cursor, …)
//   axolotl search "#work @todo"    search notes
//   axolotl call get_note '{"note":"Shopping"}'
//
// The CLI talks to the running app over a local socket (launching it in the background if
// needed), so every change goes through the app, appears immediately and syncs normally.

import Foundation
import Darwin

let version = "1.3.0"
let bundleID = "com.nearbycoder.axolotl"

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("axolotl: \(message)\n".utf8))
    exit(code)
}

func socketPath() -> String {
    let env = ProcessInfo.processInfo.environment
    if let explicit = env["AXOLOTL_SOCKET"], !explicit.isEmpty { return explicit }
    let dataDir: String
    if let override = env["AXOLOTL_DATA_DIR"], !override.isEmpty {
        dataDir = override
    } else {
        dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Axolotl").path
    }
    let path = (dataDir as NSString).appendingPathComponent("agent.sock")
    if path.utf8.count < 100 { return path }
    return (NSTemporaryDirectory() as NSString).appendingPathComponent("axolotl-\(getuid()).sock")
}

func connectOnce(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes.prefix(raw.count - 1))
        raw[min(bytes.count, raw.count - 1)] = 0
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if ok != 0 { close(fd); return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// Connects to the app, launching it hidden in the background when it isn't running.
func connectToApp() -> Int32 {
    let path = socketPath()
    if let fd = connectOnce(path) { return fd }
    if ProcessInfo.processInfo.environment["AXOLOTL_NO_LAUNCH"] == nil {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j", "-b", bundleID]
        open.standardError = FileHandle.nullDevice
        try? open.run()
        open.waitUntilExit()
    }
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if let fd = connectOnce(path) { return fd }
        usleep(150_000)
    }
    fail("""
    can't reach Axolotl. Make sure the app is installed and that Settings → Agents → "Allow agents and the command line" is on.
    (looked for \(path))
    """, code: 3)
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }
}

// MARK: MCP bridge

/// Pipes stdin to the app and the app's replies to stdout until either side closes.
func runMCPBridge() -> Never {
    let fd = connectToApp()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            FileHandle.standardOutput.write(Data(buf[0..<n]))
        }
        done.signal()
    }
    Thread.detachNewThread {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 { break }
            if !writeAll(fd, Data(buf[0..<n])) { break }
        }
        // Client went away: let in-flight replies drain, then finish.
        shutdown(fd, SHUT_WR)
    }
    done.wait()
    exit(0)
}

// MARK: Request/response client

final class Client {
    let fd: Int32
    private var buffer = Data()
    private var nextID = 1

    init() {
        fd = connectToApp()
        _ = request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:] as [String: Any],
                                   "clientInfo": ["name": "axolotl CLI", "version": version]])
    }

    func request(_ method: String, _ params: [String: Any]) -> [String: Any] {
        let id = nextID
        nextID += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        var data = try! JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        guard writeAll(fd, data) else { fail("lost connection to Axolotl") }
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if (obj["id"] as? Int) == id { return obj }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { fail("lost connection to Axolotl") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Calls a tool and returns (structured result, text, isError).
    func call(_ tool: String, _ args: [String: Any]) -> (Any?, String, Bool) {
        let response = request("tools/call", ["name": tool, "arguments": args])
        if let error = response["error"] as? [String: Any] { fail(error["message"] as? String ?? "request failed") }
        let result = response["result"] as? [String: Any] ?? [:]
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (result["structuredContent"], text, result["isError"] as? Bool ?? false)
    }
}

// MARK: Output

let jsonOutput = CommandLine.arguments.contains("--json")
/// ANSI dimming only when writing to a terminal.
let dim = isatty(STDOUT_FILENO) != 0 ? "\u{1B}[2m" : ""
let reset = isatty(STDOUT_FILENO) != 0 ? "\u{1B}[0m" : ""
var args = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--json" }

func printJSON(_ value: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        print(String(decoding: data, as: UTF8.self))
    }
}

func printNotes(_ result: Any?) {
    guard let obj = result as? [String: Any], let notes = obj["notes"] as? [[String: Any]] else { return printJSON(result ?? [:]) }
    if jsonOutput { return printJSON(obj) }
    for n in notes {
        var flags = ""
        if n["pinned"] as? Bool == true { flags += "📌 " }
        if n["locked"] as? Bool == true { flags += "🔒 " }
        let tags = (n["tags"] as? [String] ?? []).map { "#\($0)" }.joined(separator: " ")
        print("\(flags)\(n["title"] as? String ?? "")  \(dim)\(n["id"] as? String ?? "")\(reset)")
        if let preview = n["preview"] as? String, !preview.isEmpty { print("  \(preview.prefix(110))") }
        if !tags.isEmpty { print("  \(tags)") }
    }
    if let total = obj["total"] as? Int, total > notes.count { print("\(dim)… \(total - notes.count) more\(reset)") }
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func readStdinIfPiped() -> String? {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
}

func finish(_ outcome: (Any?, String, Bool), notes: Bool = false, field: String? = nil) -> Never {
    let (structured, text, isError) = outcome
    if isError { fail(text) }
    if notes { printNotes(structured) }
    else if let field, !jsonOutput, let obj = structured as? [String: Any], let value = obj[field] { print(value) }
    else if jsonOutput, let s = structured { printJSON(s) }
    else { print(text) }
    exit(0)
}

let usage = """
axolotl \(version) — Axolotl notes from the command line and for AI agents

USAGE
  axolotl mcp                               Run the MCP server on stdio (add this command to your agent)
  axolotl list [--section todo] [--tag work] [--limit 20]
  axolotl search <query>                     e.g. axolotl search '#work @todo'
  axolotl show <note>                        Print a note's Markdown (note = id or exact title)
  axolotl new [--title T] [--tag t]... [text] Create a note (text may also be piped on stdin)
  axolotl append <note> [text] [--heading H] Add text to a note (or pipe it on stdin)
  axolotl todo <note> <text>                 Add a todo
  axolotl done <note> <text or index>        Check off a todo
  axolotl todos [--tag work]                 List open todos across notes
  axolotl tags                               List tags
  axolotl open <note>                        Show a note in the app
  axolotl export <note> --format pdf [--to path]
  axolotl tools                              List every tool agents can use
  axolotl call <tool> [json-args]            Call any tool directly
  axolotl setup                              Show how to connect Claude Code, Claude Desktop and others

Add --json to any command for machine-readable output.
"""

guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "mcp":
    runMCPBridge()
case "help", "-h", "--help":
    print(usage)
case "version", "--version", "-v":
    print("axolotl \(version)")
case "setup":
    let exe = (Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) ?? "/Applications/Axolotl.app/Contents/Helpers/axolotl"
    print("""
    Connect an agent to Axolotl with this MCP server command:

      \(exe) mcp

    Claude Code:
      claude mcp add --scope user axolotl -- "\(exe)" mcp

    Claude Code plugin (adds the server plus an Axolotl skill), inside Claude Code:
      /plugin install axolotl --marketplace nearbycoder/axolotl

    Claude Desktop — add to ~/Library/Application Support/Claude/claude_desktop_config.json:
      { "mcpServers": { "axolotl": { "command": "\(exe)", "args": ["mcp"] } } }

    Cursor, Windsurf, Zed, VS Code and other MCP clients use the same command and args.
    """)
case "tools":
    let client = Client()
    let tools = client.request("tools/list", [:])["result"] as? [String: Any]
    let list = tools?["tools"] as? [[String: Any]] ?? []
    if jsonOutput { printJSON(list) } else {
        for t in list { print("\(t["name"] as? String ?? "")\n  \(t["description"] as? String ?? "")") }
    }
case "call":
    guard let tool = args.first else { fail("usage: axolotl call <tool> [json-args]") }
    var arguments: [String: Any] = [:]
    let raw = args.count > 1 ? args[1] : (readStdinIfPiped() ?? "{}")
    guard let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { fail("arguments must be a JSON object") }
    arguments = parsed
    let (structured, text, isError) = Client().call(tool, arguments)
    if isError { fail(text) }
    if let s = structured { printJSON(s) } else { print(text) }
case "list", "ls":
    var a: [String: Any] = ["limit": Int(option("--limit") ?? "") ?? 30]
    if let s = option("--section") { a["section"] = s }
    if let t = option("--tag") { a["tag"] = t }
    if let s = option("--sort") { a["sort"] = s }
    finish(Client().call("list_notes", a), notes: true)
case "search", "find":
    guard !args.isEmpty else { fail("usage: axolotl search <query>") }
    finish(Client().call("search_notes", ["query": args.joined(separator: " "), "limit": Int(option("--limit") ?? "") ?? 30]), notes: true)
case "show", "cat":
    guard let note = args.first else { fail("usage: axolotl show <note>") }
    finish(Client().call("get_note", ["note": note]), field: "text")
case "new", "create":
    var a: [String: Any] = [:]
    if let t = option("--title") { a["title"] = t }
    var tags: [String] = []
    while let t = option("--tag") { tags.append(t) }
    if !tags.isEmpty { a["tags"] = tags }
    if flag("--pin") { a["pinned"] = true }
    if flag("--open") { a["open"] = true }
    a["text"] = args.isEmpty ? (readStdinIfPiped() ?? "") : args.joined(separator: " ")
    finish(Client().call("create_note", a), field: "id")
case "append", "add":
    guard let note = args.first else { fail("usage: axolotl append <note> [text]") }
    var a: [String: Any] = ["note": note]
    if let h = option("--heading") { a["heading"] = h }
    let text = args.dropFirst().joined(separator: " ")
    a["text"] = text.isEmpty ? (readStdinIfPiped() ?? "") : text
    finish(Client().call("append_to_note", a))
case "todo":
    let heading = option("--heading")
    guard args.count >= 2 else { fail("usage: axolotl todo <note> <text> [--heading H]") }
    var a: [String: Any] = ["note": args[0], "text": args.dropFirst().joined(separator: " ")]
    if let heading { a["heading"] = heading }
    finish(Client().call("add_todo", a))
case "done", "undone":
    guard args.count >= 2 else { fail("usage: axolotl \(command) <note> <todo text or index>") }
    var a: [String: Any] = ["note": args[0], "done": command == "done"]
    let target = args.dropFirst().joined(separator: " ")
    if let i = Int(target) { a["index"] = i } else { a["match"] = target }
    finish(Client().call("set_todo", a))
case "todos":
    var a: [String: Any] = [:]
    if let t = option("--tag") { a["tag"] = t }
    let (structured, text, isError) = Client().call("list_todos", a)
    if isError { fail(text) }
    if jsonOutput { printJSON(structured ?? [:]); exit(0) }
    for t in (structured as? [String: Any])?["todos"] as? [[String: Any]] ?? [] {
        print("☐ \(t["text"] as? String ?? "")  \(dim)— \(t["note_title"] as? String ?? "") #\(t["index"] as? Int ?? 0)\(reset)")
    }
case "tags":
    let (structured, text, isError) = Client().call("list_tags", [:])
    if isError { fail(text) }
    if jsonOutput { printJSON(structured ?? [:]); exit(0) }
    func show(_ nodes: [[String: Any]], _ depth: Int) {
        for n in nodes {
            print(String(repeating: "  ", count: depth) + "#\(n["name"] as? String ?? "")  \(dim)\(n["count"] as? Int ?? 0)\(reset)")
            show(n["children"] as? [[String: Any]] ?? [], depth + 1)
        }
    }
    show((structured as? [String: Any])?["tags"] as? [[String: Any]] ?? [], 0)
case "open":
    guard let note = args.first else { fail("usage: axolotl open <note>") }
    finish(Client().call("open_in_app", ["note": note]))
case "export":
    guard let note = args.first, let format = option("--format") else { fail("usage: axolotl export <note> --format md|txt|html|pdf|rtf|docx|textbundle [--to path]") }
    let formats = ["md": "markdown", "txt": "text"]
    var a: [String: Any] = ["note": note, "format": formats[format] ?? format]
    if let to = option("--to") { a["path"] = to }
    let (structured, text, isError) = Client().call("export_note", a)
    if isError { fail(text) }
    let obj = structured as? [String: Any] ?? [:]
    if jsonOutput { printJSON(obj) } else { print(obj["content"] as? String ?? obj["path"] as? String ?? text) }
default:
    fail("unknown command '\(command)'. Run 'axolotl help'.")
}
