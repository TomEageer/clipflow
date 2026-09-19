# Changelog

All notable changes to Clipflow are documented here.
Per-release notes live on the [Releases page](https://github.com/TomEageer/clipflow/releases).

## 0.2.0 — 2026-09-19

### Added

- **Custom groups** replace pinning — rename them, drag to reorder, and grouped
  items are never auto-cleaned
- **Name your clips** and find them by that name
- Source app icon on every row
- **SQL, shell/curl and JSON detection**, each with its own category tab
- Category tabs are configurable in Settings (add/remove, drag to reorder; "All"
  is always present) and live on their own row with paging arrows
- **Localisation** — English and Simplified Chinese, following the system region
  by default, switchable in Settings
- Launch at login (`SMAppService`)
- Settings button inside the panel
- Editing the original text now saves (600 ms after you stop typing). Transform
  results still never touch the stored original

### Changed

- Panel is fully elastic: drag the divider between list and preview, and the one
  between original and processed text
- Panel shrinks near screen edges instead of mirroring to the other side
- Preview is split into "original" above and "processed" below, each copyable
- Settings rebuilt with the native grouped form style
- Drag-to-reorder now squeezes neighbours aside and snaps into place on release

### Fixed

- **Copies made right after pasting from the panel were silently dropped.**
  The pasteboard-suppression window covered the two following change counts,
  i.e. the user's next two copies. Now it suppresses exactly the one write it made
- **Images copied from WeChat were stored as a file path**, not an image — the
  classifier checked `public.file-url` before image data, and that path lives in a
  temp directory that gets cleaned up
- **The panel could not be dragged.** The drag handle sat in a `.background()`,
  where hit-testing never reached it
- Adding a settings field wiped every existing setting (synthesised `Decodable`
  throws on a missing key; the loader swallowed it and fell back to defaults)
- Clicking a category had a 370 ms delay (double-tap gesture waiting out the
  system double-click interval)

### Search

Rebuilt after the results turned out to be mostly noise.

- **Latin text is no longer indexed character-by-character.** FTS5 drops
  punctuation *without consuming a position*, so phrase queries could hop across
  word boundaries — searching `test` matched ``update `StaffInfo12` SET …``
  because `update` + `Staff` spells `t e s t`. Latin is now indexed as whole words
  plus camelCase/digit sub-words; Chinese keeps bigram phrase queries
- **Results are tiered**: exact name → exact title → name prefix → title prefix →
  token match → substring fallback, most recently used first within each tier
- Exact and prefix matches get their own indexed query, so an old exact match is
  no longer pushed out of the candidate set by newer fuzzy hits
- `LIKE` fallback for what the token index cannot express (a fragment in the
  middle of a word, a single Han character), bounded to the 20,000 most recent items
- Category and group filtering moved into SQL

### Performance

- **Indexes now match the query patterns.** The only index containing `usedSeq`
  led with the retired `pinned` column, so `recent()` — the query behind every
  panel open — was a full table scan plus a temp B-tree sort.
  At 50k items: list 59.2 → 5.3 ms, prefix search 20.2 → 5.1 ms,
  mid-word fragment 81.5 → 4.8 ms, worst case (no match) 80.6 → 11.5 ms
- `preview` holds a 2,000-character excerpt again instead of the whole content
  (the longest single item was 1.26 MB). Full text lives in the representations;
  the search index is built from it. On a 5.9k-item library the content database
  went 20.9 → 8.6 MB
- `optimize()` actually reclaims space now — it used `PRAGMA incremental_vacuum`
  on databases created with `auto_vacuum = 0`, where it is a no-op

### Known limitations

- Substring fallback only scans the 2,000-character excerpt, not the full text
- A single Han character falls back to `LIKE`; the index stores bigrams only
- First-frame panel render is ~269 ms — the data layer is 5.4 ms of that

## 0.1.0 — 2026-08-10

First public release.

### Core

- Clipboard capture with full multi-representation fidelity — every UTI on the
  pasteboard is stored and restored byte-identically, so pasting back gives you
  exactly what you copied (rich text keeps its formatting, multi-file copies keep
  every file)
- Full-text search with Chinese support (application-level bigram tokenisation +
  FTS5 phrase queries)
- Content-addressed blob storage with SHA-256 dedup; LZFSE compression above 512 B
- Separate content and index databases

### App

- Menu bar app, global hotkey (customisable, default ⌘⇧V)
- Panel opens next to the cursor; mirrors its layout at screen edges so the list
  always stays on the side nearest the mouse
- Live preview pane, image thumbnails, type categories, keyboard-first navigation
- Pastes back into whatever app you came from, with focus restored
- **Image OCR** — text inside screenshots is recognised locally (Apple Vision) and
  becomes searchable; runs on a persistent queue, pauses in Low Power Mode, and
  results matching password/key patterns are stored but kept out of the index

### Privacy

- Everything stays on your Mac. No network, no telemetry, no accounts
- Honours `org.nspasteboard.ConcealedType` and friends — password managers are
  never recorded
- Content matching token / key / password patterns is flagged, kept out of the
  search index, and expires on a short TTL
- Database files are `600`, directories `700`

### Known limitations

- Ingest throughput is ~2700 items/s (one transaction per item). Fine for real
  clipboard use; a bulk-import feature would need batching
- Encryption at rest is not implemented yet
