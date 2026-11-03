#!/usr/bin/env python3
"""End-to-end check of Axolotl's MCP server over stdio, the way an agent client talks to it.

    python3 scripts/test-mcp.py /path/to/Axolotl.app/Contents/Helpers/axolotl

Run against a disposable library (AXOLOTL_DATA_DIR) with the app running. Exercises both protocol
eras: the legacy `initialize` handshake (2025-11-25) and `server/discover` with per-request
`_meta` versioning (2026-07-28).
"""
import json
import subprocess
import sys
import uuid

CLI = sys.argv[1]
VERSION_KEY = "io.modelcontextprotocol/protocolVersion"
TAG = "mcp/run" + uuid.uuid4().hex[:8]
failures = 0


def check(cond, label):
    global failures
    print(("  ok    " if cond else "  FAIL  ") + label)
    if not cond:
        failures += 1


class Client:
    def __init__(self):
        self.proc = subprocess.Popen([CLI, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.next_id = 1

    def send(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            msg["id"] = self.next_id
            self.next_id += 1
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        if notify:
            return None
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed the connection")
            reply = json.loads(line)
            if reply.get("id") == msg["id"]:
                return reply

    def call(self, name, args, meta=None):
        params = {"name": name, "arguments": args}
        if meta:
            params["_meta"] = meta
        return self.send("tools/call", params)["result"]

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


print("legacy (initialize) client")
c = Client()
init = c.send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test-mcp", "version": "1"}})["result"]
check(init["protocolVersion"] == "2025-06-18", "negotiates the requested legacy version")
check("tools" in init["capabilities"] and init["serverInfo"]["name"] == "axolotl", "reports capabilities and server info")
check("[[Note Title]]" in init.get("instructions", ""), "includes usage instructions")
c.send("notifications/initialized", notify=True)
check(c.send("ping", {})["result"] == {}, "answers ping")
tools = c.send("tools/list", {})["result"]["tools"]
names = {t["name"] for t in tools}
check(len(tools) >= 30, f"lists {len(tools)} tools")
for required in ["create_note", "search_notes", "get_note", "edit_note", "append_to_note", "set_todo", "tag_note",
                 "rename_tag", "restore_revision", "add_attachment", "export_note", "open_in_app", "sync_now"]:
    check(required in names, f"has {required}")
delete = next(t for t in tools if t["name"] == "delete_note_permanently")
check(delete["annotations"]["destructiveHint"] is True and delete["annotations"]["readOnlyHint"] is False, "destructive tools are annotated")
search = next(t for t in tools if t["name"] == "search_notes")
check(search["annotations"]["readOnlyHint"] is True and search["inputSchema"]["required"] == ["query"], "read-only tools are annotated with schemas")

created = c.call("create_note", {"title": "MCP test", "text": "Hello from MCP.\n\n#" + TAG, "tags": ["agents"]})
note_id = created["structuredContent"]["id"]
check(not created.get("isError") and created["structuredContent"]["title"] == "MCP test", "create_note")
c.call("append_to_note", {"note": note_id, "text": "Appended paragraph."})
c.call("add_todo", {"note": note_id, "text": "First task"})
c.call("add_todo", {"note": note_id, "text": "Second task"})
c.call("set_todo", {"note": note_id, "match": "first"})
text = c.call("get_note", {"note": "MCP test"})["structuredContent"]["text"]
check(text.rstrip().endswith("#" + TAG + " #agents"), "tags stay on the last line after appends")
check("- [x] First task\n- [ ] Second task" in text, "todos are added together and checked off")
check(text.index("Appended paragraph.") < text.index("#" + TAG), "appended text goes above the tags")
edit = c.call("edit_note", {"note": note_id, "find": "Hello", "replace": "Hi"})
check(edit["structuredContent"]["replacements"] == 1, "edit_note replaces exact text")
missing = c.call("edit_note", {"note": note_id, "find": "not in the note", "replace": "x"})
check(missing.get("isError") is True, "edit_note reports a missing match as a tool error")
revisions = c.call("list_revisions", {"note": note_id})["structuredContent"]["revisions"]
check(len(revisions) >= 4, f"each agent edit is its own history entry ({len(revisions)} revisions)")
first = revisions[-1]["revision"]
c.call("restore_revision", {"note": note_id, "revision": first})
restored = c.call("get_note", {"note": note_id})["structuredContent"]["text"]
check("Appended paragraph." not in restored and "Hello from MCP." in restored, "restore_revision undoes agent edits")
found = c.call("search_notes", {"query": "#" + TAG})["structuredContent"]
check(found["total"] == 1, "search_notes finds the note by tag")
todos = c.call("list_todos", {})["structuredContent"]
check(isinstance(todos["todos"], list), "list_todos")
c.call("tag_note", {"note": note_id, "add": ["renamed-me"]})
c.call("rename_tag", {"tag": "renamed-me", "new_name": "renamed/done"})
check("renamed/done" in c.call("get_note", {"note": note_id})["structuredContent"]["tags"], "rename_tag rewrites notes")
resources = c.send("resources/list", {})["result"]["resources"]
uri = f"axolotl://note/{note_id}"
check(any(r["uri"] == uri for r in resources), "notes are listed as resources")
check(c.send("resources/read", {"uri": uri})["result"]["contents"][0]["text"].startswith("# MCP test"), "resources/read returns Markdown")
unknown = c.send("does/not/exist", {})
check(unknown.get("error", {}).get("code") == -32601, "unknown methods return -32601")
c.close()

print("modern (server/discover) client")
c = Client()
meta = {VERSION_KEY: "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}
discover = c.send("server/discover", {"_meta": meta})["result"]
check("2026-07-28" in discover["supportedVersions"] and "2025-11-25" in discover["supportedVersions"], "server/discover lists supported versions")
check(discover["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "axolotl", "server info travels in _meta")
listed = c.send("tools/list", {"_meta": meta})["result"]
check(listed.get("resultType") == "complete" and "ttlMs" in listed and listed.get("cacheScope") == "private", "modern results carry resultType and cache fields")
called = c.call("get_note", {"note": note_id}, meta=meta)
check(called.get("resultType") == "complete" and called["structuredContent"]["id"] == note_id, "modern tools/call")
bad = c.send("tools/list", {"_meta": {VERSION_KEY: "1999-01-01"}})
check(bad.get("error", {}).get("code") == -32022 and "2026-07-28" in bad["error"]["data"]["supported"], "unsupported versions are rejected with -32022")
c.call("delete_note_permanently", {"note": note_id}, meta=meta)
gone = c.call("get_note", {"note": note_id}, meta=meta)
check(gone.get("isError") is True, "delete_note_permanently")
c.close()

print(f"\n{'all checks passed' if failures == 0 else f'{failures} check(s) failed'}")
sys.exit(1 if failures else 0)
