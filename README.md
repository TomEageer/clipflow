<div align="center">

<img src="assets/icon_1024.png" width="120" alt="Clipflow icon">

# Clipflow

**A clipboard manager that gives you back exactly what you copied**

Most clipboard managers keep the text and quietly drop everything else.<br>
Clipflow stores **every representation** the pasteboard offered — rich text keeps its<br>
formatting, a three-file copy stays three files, and what you paste is byte-identical.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/TomEageer/clipflow?color=brightgreen&label=release)](https://github.com/TomEageer/clipflow/releases/latest)
[![Download](https://img.shields.io/badge/download-3%20MB-brightgreen)](https://github.com/TomEageer/clipflow/releases/latest/download/Clipflow.zip)
[![Search](https://img.shields.io/badge/search%20P95-0.27%20ms%20%40%201M-brightgreen)](#measured-performance)
[![Downloads](https://img.shields.io/github/downloads/TomEageer/clipflow/total?color=brightgreen&label=downloads)](https://github.com/TomEageer/clipflow/releases)
[![Telemetry](https://img.shields.io/badge/telemetry-none-success)](#privacy)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](#requirements)

[**⬇ Download**](https://github.com/TomEageer/clipflow/releases/latest/download/Clipflow.zip) · [Quick start](#quick-start) · [How it works](#how-it-works) · [FAQ](#faq) · [**中文文档**](README.zh-CN.md)

</div>

---

## Why Clipflow

Clipboard managers are a solved problem — until you paste. Then the formatting is
gone, the second file vanished, and searching Chinese returns nothing. Clipflow is
built around the paste, not the list:

- 🧬 **Fidelity, not just text** — one copy is one `NSPasteboardItem` carrying several
  UTIs (`public.rtf`, `public.html`, `public.utf8-plain-text`, app-private types…).
  All of them are stored, all of them written back. Formatting survives the round trip
- 📎 **Multi-file copies stay intact** — copy three files, get three files. The
  pasteboard's multi-item structure is preserved, not flattened into one
- 🔍 **Chinese search that actually works** — FTS5's default tokeniser treats a run of
  Han characters as one token, so searching 订单 never matches 订单支付回调. Clipflow
  tokenises to bigrams in the app layer and uses phrase queries, so precision holds
- ⚡ **Flat at scale** — 1,000,000 items measured at 518 MB with a P95 search of
  **0.27 ms**. Latency does not grow with history size
- 👁 **Searchable screenshots** — text inside images is recognised locally with Apple
  Vision and folded into the search index, so `KUMQUAT7788` in a screenshot is findable
- 🔒 **Private by construction** — no telemetry, no account, nothing leaves your Mac.
  The only network request in the whole app is the update check, and it only fires
  when you ask for it (or leave auto-check on). Password-manager content is never recorded

|  | Clipflow | Paste | Maccy |
|---|---|---|---|
| Price | **Free (MIT)** | $9.99/year | Free |
| Source | **Open** | Closed | Open |
| Search index | **FTS5, separate DB** | FTS5 + spellfix1 | **None** — linear scan over memory |
| Chinese phrase search | **Bigram + FTS5 phrase** | not verified | no index; fuzzy match, truncates at 5,000 chars |
| Screenshot storage | transcode planned; compressed | **raw TIFF kept** | blobs inline in SQLite |
| Database file mode | **`600`** | `644` | — |
| Telemetry | **None** | PostHog | None |
| Image OCR | **yes** | **yes** | no |

<sub>
Every cell here was checked against the shipped software — Maccy from its source,
Paste from its own on-disk database and binary — not from marketing pages.
Blank cells are things not verified rather than things assumed. Paste does dedupe by
checksum and does OCR screenshots, both of which Clipflow does not do today.
</sub>

## Quick start

```bash
git clone https://github.com/TomEageer/clipflow.git
cd clipflow
./scripts/build-app.sh
open build/Clipflow.app
```

Requires macOS 14+ and Xcode Command Line Tools. A menu bar icon appears; that's it.

| Action | Key |
|---|---|
| Open the panel at the cursor | **⌘⇧V** (customisable) |
| Search | just type |
| Move / paste | **↑↓** / **⏎** |
| Jump to item N | **⌘1** … **⌘9** |
| Pin / delete | **⌘P** / **⌘⌫** |
| Close | **esc** or click outside |

Auto-paste needs Accessibility permission (System Settings → Privacy & Security →
Accessibility). **Without it Clipflow still works** — the item lands on your
clipboard and you press ⌘V yourself; it tells you so instead of silently failing.

## The panel

Opens next to the pointer, because the point of following the mouse is to keep
mouse travel short. At the right edge of the screen the panel opens to the left —
and its two columns **swap**, so the clickable list is always the side nearest
your pointer.

The preview pane shows the full text, a scaled image, and which formats this entry
actually holds with their sizes — fidelity is the selling point, so it should be
visible.

## How it works

macOS has **no clipboard change notification** — no `NSNotification`, no KVO, no
callback. The only way is polling `NSPasteboard.general.changeCount` (200 ms while
active, 1 s once the system has been idle for a minute).

Reading the contents is where it gets interesting, and the implementation is shaped
by things only visible under measurement:

- **Reads must be synchronous with detection.** Clipboard content is transient —
  the system keeps only "current". Deferring the read means that if the clipboard
  has moved on, you record the *new* content against the *old* event. Measured:
  7 copies in a row, deferred reads attributed the last item to five of them.
  Losing an event is acceptable; recording the wrong thing is not.
- **Some types can block for tens of seconds.** A promised type whose owner never
  fulfils it hangs the read until a system timeout. Clipflow keeps a watchdog and a
  self-learning negative cache for that case — but the common path reads
  everything, because skipping a type costs fidelity.
- **Never `ORDER BY rank`.** Ranking scores every hit: 46 ms for 20,000 matches
  versus 0.30 ms ordering by recency — and recency is what a clipboard user
  actually wants. Both faster and more correct.

Storage is SQLite via GRDB: a content database, a **separate** index database (so
the index can be rebuilt without touching content), and content-addressed blob
storage where identical images collapse to a single file on disk.

## Architecture

```
ClipflowCore      engine — zero UI imports, enforced by a test
ClipflowCapture   the only non-UI target allowed to import AppKit
ClipflowApp       menu bar app
clipflow          CLI — also the proof that Core is really decoupled
```

The CLI is not a bonus feature. If `clipflow search 订单` works, Core cannot have
sneaked in a UI dependency.

```bash
.build/release/clipflow list -n 10
.build/release/clipflow search 分布式锁
.build/release/clipflow stats
.build/release/clipflow bench 50     # asserts against the perf budget
```

## Measured performance

48,000 items on an M4 Pro:

| Operation | Median | P95 | Budget |
|---|---|---|---|
| List recent 20 | 0.09 ms | 0.11 ms | — |
| Chinese phrase search | 0.16 ms | 0.19 ms | 16 ms |
| Identifier search | 0.45 ms | 0.55 ms | 16 ms |

Scaling to 1,000,000 items: 518 MB total, P95 search 0.27 ms — flat, not linear.
Every number here is reproducible with the scripts in `bench/`.

## FAQ

**Does it work without Accessibility permission?**
Yes. The item is placed on your clipboard and Clipflow tells you to press ⌘V — it
never fails silently. The permission is only needed to synthesise the keystroke.

**Why does it ask again after I rebuild?**
It shouldn't. Builds are signed with a stable Apple Development certificate, so the
designated requirement is tied to the certificate and bundle ID rather than the
binary hash. Ad-hoc signing does invalidate the grant on every rebuild — that's why
`build-app.sh` prefers a real identity.

**Where is my data?**
`~/Library/Application Support/Clipflow/` — a content database, a separate index
database, and a `blobs/` directory. Directories are `700`, files `600`. Delete the
folder and nothing is left behind.

**Does it store the file when I copy a file?**
No — and neither does any other clipboard manager. macOS puts only a `public.file-url`
on the pasteboard when you copy a file (a 200 MB video is 76 bytes on the clipboard).
Clipflow stores that reference and writes it back on paste.

**Why is my screenshot 235 MB on the clipboard?**
Because macOS puts screenshots on the pasteboard as **uncompressed TIFF**. The same
image is 12 MB as PNG. Transcoding is on the roadmap; today it is stored compressed.

## Privacy

Your clipboard never leaves your Mac. No telemetry, no accounts, no analytics.

The app makes exactly **one** kind of network request: fetching the latest release
tag from GitHub to tell you a new version exists. It sends no identifiers, no device
info and no usage data, and you can switch it off in Settings → General → Behaviour.
Everything else — capture, storage, search, paste — is entirely local.

- `org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType` are
  honoured, plus a bundle-ID blocklist for 1Password / Bitwarden / LastPass /
  Dashlane / KeePassXC and friends
- Content matching JWT / AWS key / private key / `password=` patterns is marked
  sensitive, kept **out of the search index**, and expires on a short TTL
- Database files are `600`, directories `700`

## Requirements

- macOS 14+, Apple Silicon or Intel
- Developed and tested on M4 Pro / macOS 27

## Support

If Clipflow helps, see [DONATE.md](DONATE.md) — Alipay / WeChat. Everything stays
free regardless.

## Contact

[GitHub Issues](https://github.com/TomEageer/clipflow/issues) ·
[tomeageer@gmail.com](mailto:tomeageer@gmail.com) ·
[tomeageer.com](https://tomeageer.com)

## License

MIT — see [LICENSE](LICENSE). Uses [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT).

<sub>macOS clipboard manager · clipboard history Mac · Paste app alternative · Maccy alternative · 剪贴板管理器 · Mac 剪切板历史 · clipboard manager with Chinese search · open source clipboard Mac</sub>
