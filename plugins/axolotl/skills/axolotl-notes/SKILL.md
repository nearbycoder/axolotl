---
name: axolotl-notes
description: Work with the user's Axolotl notes (a Markdown notes app for Mac, iPhone and iPad) — search, read, write, organize with #tags, manage todos, link notes, and export. Use whenever the user mentions their notes, Axolotl, a note by title, their todo list, tags, journal, meeting notes, or asks to save, capture, summarize, or file something for later.
---

# Axolotl notes

Axolotl stores notes as plain Markdown and exposes every app action to agents through the
`axolotl` MCP server (tools such as `search_notes`, `get_note`, `create_note`, `edit_note`).
If the MCP tools are not available, the same actions work from the shell with the `axolotl`
command (`axolotl help`, or `/Applications/Axolotl.app/Contents/Helpers/axolotl help`).

## How notes are written

- The first line is the title, normally `# Title`. Keep it when editing.
- Tags are inline: `#work`, nested `#work/atlas`, multi-word `#reading list#`. By convention they sit
  on the last line of the note. Use `tag_note` rather than typing tags yourself.
- Links between notes: `[[Note Title]]` (or `[[Note Title|label]]`). `get_note` returns backlinks.
- Todos: `- [ ] open`, `- [x] done`. Use `add_todo` / `set_todo`; `list_todos` gathers open items from every note.
- Callouts: `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]`, `> [!DANGER]`. Highlight: `==text==`. Underline: `~text~`.
- Attachments appear as `![name](attachment:ID)` (images) or `[name](attachment:ID)` (files). Never invent
  attachment ids; use `add_attachment` with a file path.

## Working well

1. **Find before you write.** Use `search_notes` (or `list_notes` with a `tag`/`section`) to find an existing
   note rather than creating duplicates. Refer to notes by the `id` you get back.
2. **Make small edits.** Prefer `edit_note` (exact find/replace), `append_to_note` (end, start, or under a
   heading), `add_todo` and `tag_note` over `replace_note_text`. Read the note first with `get_note`.
3. **Every agent edit is its own version.** If something goes wrong, `list_revisions` then
   `restore_revision` puts the note back.
4. **Ask before destroying.** `delete_note_permanently`, `empty_trash` and `delete_tag` cannot be undone;
   prefer `update_note` with `trashed: true`, which the user can restore.
5. **Respect locked notes.** Locked (encrypted) notes are only readable if the user allows it in
   Axolotl → Settings → Agents *and* has unlocked them. If a tool says a note is locked, tell the user
   rather than working around it.
6. **Show the user.** `open_in_app` brings Axolotl forward on a note, tag, section or search.

See [reference.md](reference.md) for the search syntax and the full tool list.

## Recipes

- **Capture**: `create_note` with a clear title, the content, and 1–3 tags that already exist (`list_tags`).
- **Daily note**: search `@ctoday #journal`; if none, create `# <weekday, date>` tagged `#journal`, then append.
- **Meeting notes**: create `# <Meeting> — <date>` with `## Attendees`, `## Notes`, `## Actions`; put actions as todos.
- **Todo triage**: `list_todos`, group by note, then `set_todo` items the user confirms are done.
- **Reorganize tags**: `list_tags`, then `rename_tag` (it rewrites every note and keeps subtags).
- **Summarize a topic**: `search_notes "#topic"`, `get_note` each result, then write a summary note that
  links back with `[[Title]]`.
