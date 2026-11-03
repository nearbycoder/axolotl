<p align="center"><img src="assets/icon.png" width="128" height="128" alt="Axolotl icon"></p>

<h1 align="center">Axolotl</h1>

<p align="center">A beautiful, private, Markdown-first notes app for Mac, iPhone and iPad,<br>with end-to-end encrypted sync between your devices.</p>

<p align="center"><a href="https://nearbycoder.github.io/axolotl/"><b>Download</b></a> · <a href="#sync">Sync</a> · <a href="#building">Build from source</a></p>

---

## Features

**Writing**
- Live Markdown editor that styles as you type and hides the syntax except on the line you're editing: headings, **bold**, *italic*, ~~strikethrough~~, ==highlight==, ~underline~, `code`, quotes, callouts (`> [!NOTE]`), tables, footnotes, inline math, horizontal rules
- Real checkboxes for `- [ ]` todos, bullets for lists, automatic list continuation, Tab / Shift-Tab to indent
- Fenced code blocks with syntax highlighting
- Inline images, file attachments, drag and drop, paste images, photo picker
- iPhone/iPad: formatting bar above the keyboard, Apple Pencil sketches, document scanning
- Typewriter mode, adjustable font, size, line height, paragraph spacing and line width
- Find and replace in a note, version history with restore

**Organizing**
- `#tags`, `#nested/tags` and `#multi word tags#`, with icons, pinning, rename and delete
- `[[Wiki links]]` between notes with autocomplete, backlinks and outgoing links
- Tag and note-link autocomplete while typing
- Pin, archive and trash notes; Notes, Todo, Today, Locked, Untagged, Archive and Trash sections
- Info panel with word count, read time, dates and a table of contents
- Quick Open (⌘O) to jump to any note

**Search**
- Words, `"phrases"`, `-exclusions`, `#tag`, `!#exact-tag`, `-#tag`, `#*/child`, `OR`
- Special filters: `@todo` `@done` `@task` `@today` `@yesterday` `@ctoday` `@last7days` `@created7days` `@date(>2025-01-01)` `@cdate(…)` `@tagged` `@untagged` `@pinned` `@locked` `@images` `@files` `@attachments` `@code` `@wikilinks` `@backlinks` `@untitled` `@empty` `@ocr` `@title` `@conflict`
- Text inside images is recognized on-device and searchable

**Privacy & security**
- Lock individual notes with AES-256-GCM encryption (password + Face ID / Touch ID)
- Lock the whole app with Face ID / Touch ID
- No account, no tracking; notes live on your devices

**Export & import**
- Markdown, plain text, TextBundle, HTML (with embedded images), PDF, RTF, and Word (Mac)
- Export everything as a zip of Markdown files; import Markdown, text, TextBundle and Bear notes
- `axolotl://` URL scheme with Bear-style x-callback-url actions (`create`, `open-note`, `add-text`, `search`, `open-tag`)

**Themes**
Axolotl and Axolotl Night, plus Red Graphite, Dark Graphite, High Contrast, Charcoal, Solarized Light/Dark, Dracula, Nord, Tokyo Night, Gruvbox, Catppuccin Latte/Mocha, Everforest, Rosé Pine and Rosé Pine Dawn, with separate light and dark choices.

## Sync

Axolotl ships its own sync engine (in [`Packages/AxolotlKit`](Packages/AxolotlKit)):

- **Local-first.** Every device has a full SQLite replica and works offline.
- **Conflict-free fields.** Each field of each note is stamped with a hybrid logical clock; metadata merges last-writer-wins.
- **Merged text.** Note bodies carry their revision lineage. Concurrent edits are three-way merged word by word, so edits to different parts of a note both survive. When there is no shared history to merge from, the other version is kept as a "conflicted copy", so nothing is lost.
- **End-to-end encrypted.** Everything is derived from a sync code (`AXO-…`): the vault id, the server auth token, and the AES-256-GCM key. Servers and the network only ever see ciphertext.
- **Two transports:**
  - **Nearby devices:** devices with the same sync code find each other over Bonjour and sync directly over the local network, with no server.
  - **Sync server (optional):** a tiny relay you host yourself, for syncing when your devices are apart. It stores only encrypted rows and keeps the latest row per field. It uses long polling, so changes arrive in about a second.

To set it up, open **Settings → Sync → Start Syncing on This Device**, then enter or scan the code on your other devices.

### Running the sync server

```sh
cd server
node server.mjs                 # Node 22.13+; listens on :8787, stores data in ./data
# or
docker compose up -d
```

Put it behind HTTPS (Caddy, Cloudflare Tunnel, Tailscale, Fly.io…) and enter its URL in **Settings → Sync → Sync server**. Set `REGISTRATION=closed` once your vault exists to stop new vaults being created.

| Variable | Default | Meaning |
| --- | --- | --- |
| `REGISTRATION` | `open` | `closed` refuses unknown vaults |
| `MAX_VAULTS` | `100` | vaults this relay will register |
| `MAX_VAULT_BYTES` | 5 GiB | storage per vault, rows plus attachments |
| `MAX_BLOB_BYTES` | 200 MiB | largest single attachment |
| `TRUST_PROXY` | unset | `1` to rate-limit by `X-Forwarded-For` behind your own proxy |

New vaults are also limited to 10 per address per hour. Attachments stream to disk, so the relay's memory use does not grow with attachment size.

### What the sync protocol protects

- **Confidentiality.** Rows and attachments are sealed with AES-256-GCM under keys derived (HKDF) from the sync code. The relay stores only ciphertext, an opaque per-field key (an HMAC of the field's identity) and the row's logical timestamp.
- **Integrity and rollback.** Clients check that the key and timestamp the relay returns match the sealed row, so a relay (or anyone holding the auth token) cannot re-file an old version of a field as the newest. Attachments are addressed by their SHA-256 and verified on receipt.
- **Local network.** Peers must present a frame sealed with the vault key before they are allowed to send anything large. Discovery only advertises a short HKDF-derived hint, not the key.
- **Locked notes.** Note bodies are encrypted with a key derived from your password (PBKDF2-HMAC-SHA256, 600,000 rounds for vaults created from 1.2 on). Locking a note also removes its earlier plaintext history from every device. The title of a locked note stays visible, as in Bear.
- **What it does not do.** There is no forward secrecy: anyone who learns the sync code can read everything synced with it, past and future. Rotate by creating a new vault. The relay can still see when and how much you sync, and it can withhold data.

## Agents and automation

Everything you can do in Axolotl, an AI agent can do too: search, read, write, edit, tag, manage todos,
restore versions, attach files, export, change themes and sync. There are four ways in.

**MCP (Mac).** Axolotl includes a [Model Context Protocol](https://modelcontextprotocol.io) server with
35 tools. It works with Claude Code, Claude Desktop, Cursor, Windsurf, Zed, VS Code and any other MCP
client. The server command is the `axolotl` tool inside the app:

```sh
# Claude Code
claude mcp add --scope user axolotl -- /Applications/Axolotl.app/Contents/Helpers/axolotl mcp
```

```json
// Claude Desktop, Cursor and others
{ "mcpServers": { "axolotl": { "command": "/Applications/Axolotl.app/Contents/Helpers/axolotl", "args": ["mcp"] } } }
```

**Claude Code plugin.** Installs the MCP server plus an `axolotl-notes` skill that teaches Claude
Axolotl's Markdown, tags, todos and search syntax. Inside Claude Code:

```
/plugin install axolotl --marketplace nearbycoder/axolotl
```

**Command line (Mac).** `axolotl` works on its own for scripts and shell agents. Install it on your PATH
from **Settings → Agents**, then:

```sh
axolotl search '#work @todo'
axolotl new --title "Idea" --tag ideas "Write it down."
echo "- [ ] call back" | axolotl append "Meeting notes" --heading Actions
axolotl todos
axolotl call <tool> '{"note": "Shopping"}'    # any MCP tool, with --json output
```

**Siri, Shortcuts and Apple Intelligence (iPhone, iPad, Mac).** App Intents for creating notes, adding
to notes and todo lists, searching, opening, reading, tagging, and pinning, archiving or trashing notes,
with ready-made App Shortcuts such as “Create a note in Axolotl”.

**How agents are kept in check**

- Agent access goes through the running app over a Unix socket in your user folder (mode 0600, peer
  uid checked), so only apps running as you on that Mac can connect. You can turn it off in **Settings → Agents**.
- Every agent edit is saved as its own version, so you can undo it from Version History or with
  `restore_revision`.
- Locked notes stay hidden unless you allow agent access to them *and* have unlocked them in the app.
  They are never matched by search and stay encrypted when an agent edits them.
- Destructive tools (`delete_note_permanently`, `empty_trash`, `delete_tag`, `replace_note_text`) are
  annotated as such, so clients can ask before running them. Security settings can't be changed by agents.
- **Settings → Agents** shows every connected client and a log of what agents did.

## Install

Grab the latest build from the [download page](https://nearbycoder.github.io/axolotl/) or [Releases](https://github.com/nearbycoder/axolotl/releases):

- **macOS 14+:** `Axolotl-macOS.zip` (universal). The build is not notarized, so the first time, right-click the app and choose **Open** (or run `xattr -dr com.apple.quarantine /Applications/Axolotl.app`).
- **iPhone & iPad (iOS 17+):** `Axolotl-iOS.ipa`, an unsigned IPA for sideloading with AltStore, SideStore or Sideloadly. AltStore users can add the source `https://nearbycoder.github.io/axolotl/altstore.json`. Or build it onto your device from source.

## Building

Requirements: Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (only needed if you change `project.yml`).

```sh
xcodegen generate              # regenerates Axolotl.xcodeproj
open Axolotl.xcodeproj         # run the Axolotl-macOS or Axolotl-iOS scheme

# tests
swift test --package-path Packages/AxolotlKit
(cd server && npm test)
xcodebuild test -project Axolotl.xcodeproj -scheme Axolotl-macOS -destination platform=macOS
python3 scripts/test-mcp.py Axolotl.app/Contents/Helpers/axolotl   # MCP end to end, app running

# release artifacts into dist/
./scripts/build-release.sh
```

## Layout

```
App/Shared        SwiftUI app shared by macOS and iOS (editor, views, model)
App/Shared/Agent  MCP server, agent tools, App Intents
App/CLI           the `axolotl` command line tool and MCP stdio bridge
plugins/axolotl   Claude Code plugin (MCP server + skill)
App/iOS           iPhone/iPad-only pieces (sketching, scanning, QR)
Packages/AxolotlKit  storage, sync engine, merge, crypto, search, Markdown → HTML
server/           zero-dependency Node sync relay + Dockerfile
docs/             GitHub Pages download site
```

## License

MIT
