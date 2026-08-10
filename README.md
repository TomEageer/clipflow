<div align="center">

<img src="assets/icon_1024.png" width="120" alt="Clipflow icon">

# Clipflow

**A clipboard manager for macOS that gives you back exactly what you copied**

Most clipboard managers keep the text and quietly drop everything else.<br>
Clipflow stores **every representation** the pasteboard offered — so rich text
keeps its formatting, a multi-file copy stays multi-file, and pasting back is
byte-identical to the original.

[中文说明](README.zh-CN.md) · [Changelog](CHANGELOG.md) · [Donate](DONATE.md)

</div>

---

## Why Clipflow

- **Fidelity, not just text** — one copy is one `NSPasteboardItem` carrying several
  UTIs (`public.rtf`, `public.html`, `public.utf8-plain-text`, app-private types…).
  Clipflow keeps all of them and writes all of them back. Copy formatted text from
  a doc, paste it into another doc, and the formatting survives.
- **Multi-file copies stay intact** — copy three files, get three files. The
  pasteboard's multi-item structure is preserved, not flattened.
- **Chinese search that actually works** — FTS5's default tokeniser treats a run of
  Han characters as a single token, so searching 订单 never matches 订单支付回调.
  Clipflow tokenises to bigrams in the app layer and uses phrase queries, so
  precision holds.
- **Fast at scale** — 1,000,000 items benchmarked at 518 MB with a P95 search of
  0.27 ms. Latency does not degrade with size.
- **Private by construction** — no network code, no telemetry, no account.
  Password-manager content is never recorded.

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

## Privacy

Everything stays on your Mac. There is no network code in this project.

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
