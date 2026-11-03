# Axolotl reference

## Search syntax (`search_notes`, `axolotl search`)

| Query | Matches |
| --- | --- |
| `word` | notes containing the word (title, body, text recognized in images) |
| `"exact phrase"` | the exact phrase |
| `-word`, `-"phrase"` | excludes |
| `#tag` | the tag or any subtag (`#work` matches `#work/atlas`) |
| `!#tag` | only that tag, not subtags |
| `-#tag` | excludes a tag |
| `#*/child` | any tag ending in `/child` |
| `a OR b` | either term |
| `@todo` / `@done` / `@task` | has open todos / all todos done / has any todos |
| `@today` `@yesterday` `@last7days` | modified recently (any number of days) |
| `@ctoday` `@cyesterday` `@created7days` | created recently |
| `@date(2025-01-31)` `@date(>2025-01-01)` `@cdate(<2024-06-01)` | modified / created on, after, before a day |
| `@tagged` `@untagged` `@pinned` `@locked` | state |
| `@images` `@files` `@attachments` `@code` `@ocr` | content types |
| `@wikilinks` `@backlinks` | links to / linked from other notes |
| `@untitled` `@empty` `@conflict` | housekeeping |
| `@title word` | following words match titles only |

Terms combine with AND; `OR` binds the terms on either side.

## Tools

Reading: `list_notes`, `search_notes`, `get_note`, `list_todos`, `list_tags`, `get_library_stats`,
`list_revisions`, `get_revision`, `get_attachment`, `get_settings`, `get_sync_status`.

Writing: `create_note`, `edit_note`, `append_to_note`, `replace_note_text`, `update_note`
(pinned / archived / trashed), `duplicate_note`, `add_todo`, `set_todo`, `tag_note`, `rename_tag`,
`set_tag_appearance`, `restore_revision`, `add_attachment`, `import_files`, `lock_note`, `unlock_note`,
`update_settings`, `sync_now`, `open_in_app`.

Export: `export_note` (markdown, text, html, pdf, rtf, docx, textbundle), `export_library` (zip).

Destructive (cannot be undone): `delete_note_permanently`, `empty_trash`, `delete_tag`.

Notes are identified by `id` or exact title. Sections: `notes`, `todo`, `today`, `locked`, `untagged`,
`archive`, `trash`.

## Command line

```
axolotl search '#work @todo'
axolotl show "Meeting notes"
axolotl new --title "Idea" --tag ideas "Body text"
echo "- [ ] follow up" | axolotl append "Meeting notes" --heading Actions
axolotl todos
axolotl call <tool> '<json arguments>'     # any tool above
```

Add `--json` for machine-readable output.
