# Changelog

All notable changes to Clipflow are documented here.
Per-release notes live on the [Releases page](https://github.com/TomEageer/clipflow/releases).

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
