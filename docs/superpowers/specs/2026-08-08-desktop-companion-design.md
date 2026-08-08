# Desktop Companion & 7TV — Design Spec

**Date:** 2026-08-08
**Status:** Design approved. Ready for implementation planning.
**Builds on:** `2026-08-07-discord-imessage-stickers-design.md`

---

## 1. Goal

Let people assemble a sticker set on a computer — where browsing hundreds of emoji is pleasant — and move it to the phone in one action.

Two deliverables:

- **A static web page**, usable from any OS, that gathers emoji and emits a transfer payload.
- **A small iOS addition** that accepts that payload and understands 7TV as a source.

### Why a web page instead of a Mac app

A desktop app cannot write into the iPhone's Messages-extension sandbox. Only three bridges exist, and the choice is forced:

| Bridge | Works on | Needs | Verdict |
|---|---|---|---|
| iCloud sync | Mac only | Paid account | Excludes Windows and Linux entirely |
| A hosted backend | Everything | A server you run and pay for | Storing users' emoji makes you a redistributor — the one line this project will not cross |
| **Text transfer** | **Everything** | **Nothing** | **Chosen** |

A static page on GitHub Pages costs nothing to host, stores nothing, and works on Windows, Linux, macOS and ChromeOS from one codebase. The painful part of phone-based import is *browsing*, and a browser solves that as well as a native app would.

### Non-goals

- Any server, database, account, or login.
- Storing or proxying image data. The page handles **names and URLs only**; the phone fetches every image itself, directly from its origin. This is what keeps the project a tool rather than a host.
- A native Mac app. Deferred to the paid tier, where iCloud makes it worthwhile.
- Editing images.

---

## 2. Architecture

Discovery and fetching are split across the two halves, deliberately.

```
  ┌──────────── Browser (any OS) ─────────────┐      ┌──── iPhone ─────┐
  │  Discord markup  ──┐                       │      │                 │
  │                    ├──►  picker  ──► payload──────►  parse  ──► fetch│
  │  7TV username    ──┘        UI        text/QR│      │        images  │
  └───────────────────────────────────────────┘      └─────────────────┘
        knows about sources                          knows about downloading
```

**The page does discovery. The phone does fetching.** The phone never learns the 7TV API; it receives a list of ids, names, and source tags. Adding a fifth emote service later means updating a web page, not shipping an App Store release.

---

## 3. Transfer payload

A line-based text format, chosen over JSON because QR capacity is the binding constraint (§5) and JSON's punctuation is pure overhead.

```
DSTK1
d 1481800758532903104 67
d 1095953169969860649 NOWAY
7 01F6MZGCNG000255K4X1K7EMS7 catJAM
```

- **Line 1** is the literal magic `DSTK1` — format name and version. A payload without it is rejected outright, so pasting unrelated text produces a clear message rather than a confusing partial import.
- **Each subsequent line:** a one-character source tag, a space, the id, a space, the name. The name runs to end of line and may contain spaces; ids never do, so a two-way split is unambiguous.
- **Source tags:** `d` = Discord, `7` = 7TV. One character because every byte costs QR capacity.
- Blank lines and unparseable lines are skipped, not fatal — one malformed line must not lose the other 200.

Roughly 35 bytes per emoji.

**Why not reuse `manifest.json`?** That format carries `addedAt` and `useCount`, which the page cannot know and would have to fabricate, and its JSON overhead would cut QR capacity by more than half. `ManifestTransfer` stays a separate feature for backup and restore; this is a distinct concern that happens to move similar data.

---

## 4. The web page

A single static HTML file with no build step, no framework, and no dependencies beyond one QR library. Hosted on GitHub Pages from the existing repo.

**Inputs, both optional and combinable:**

1. **Paste Discord markup** — a textarea. Parses `<(a)?:name:id>` with the same rules as the iOS parser: dedupe by id, first occurrence wins, original order preserved.
2. **7TV** — a text field taking a Twitch username or a 7TV profile/set URL, resolved against the 7TV API (§6).

**Picker:** everything found renders as a grid of thumbnails with checkboxes, all selected by default, with *Select all* / *Select none*. Names are shown and editable inline — a user who wants `catJAM` called `cat` should not have to wait until the phone to say so.

**Output**, updating live as selections change:

- The payload in a read-only box with a **Copy** button
- A **QR code** of the same payload
- A count and byte size, so a user who exceeds QR capacity understands why they are seeing several codes

**No persistence.** Reloading the page clears everything. Nothing is stored in `localStorage`, cookies, or anywhere else — there is no state worth keeping and no state worth being responsible for.

---

## 5. Transfer: text and QR

**Both**, because they serve different machines.

**Text** is primary and unbounded. On a Mac, Universal Clipboard makes it invisible: copy in the browser, paste on the phone. Elsewhere, users message or email it to themselves.

**QR** is the escape hatch for Windows and Linux, where no clipboard bridge exists. A QR code in byte mode at low error correction holds roughly 2,900 bytes — about **80 emoji** at 35 bytes each.

Above that, the page **splits into multiple codes**, each a self-contained `DSTK1` payload, labelled *1 of 3*, *2 of 3*. The phone imports each independently and its existing dedupe makes order and repetition harmless. Chunking is presented plainly rather than silently truncating — a payload that quietly dropped half the selection would be the worst possible failure here.

---

## 6. 7TV integration

7TV publishes a documented public API intended for third-party clients. This matters beyond convenience: the app currently depends on `cdn.discordapp.com`, which is **not** an interface Discord offers third parties and could be rate-limited or blocked at any time. 7TV is a supported source in a way Discord is not.

**⚠️ Verify every endpoint with `curl` before writing code that depends on it.** The exact v3 paths below are from memory, and this project has already been bitten once by an unverified API assumption — Discord's `?size=` parameter turned out to only downscale, invalidating an entire section of the base spec. One command settles each of these.

Expected shape:

```
GET https://7tv.io/v3/emote-sets/{setId}     → emotes[] with id + name
CDN: https://cdn.7tv.app/emote/{emoteId}/4x.webp
```

**Format note:** 7TV serves **WEBP and AVIF**, not PNG. iOS decodes WEBP natively and `StickerImageProcessor` normalizes to PNG regardless, so no new decoding is needed. Animated emotes arrive as animated WEBP; the downloader must take **frame 0 explicitly** via `CGImageSource` rather than trusting `UIImage(data:)` to choose, since the project is static-only by design.

---

## 7. iOS changes

Small, and the seams already exist.

**`StickerSource`** gains `.sevenTV`. The enum was built with `.pasted` and `.server` from the start precisely so additional origins would not require a data migration.

**Cross-spec note.** `2026-08-08-import-sources-design.md` §6 independently adds `.photo` and `.link` to the same enum. The two are additive and do not conflict, but whichever project is built second must add its cases *alongside* the first's rather than replacing them — and its "manifest written before this change still loads" test must cover every case then present. Both specs rely on the same mechanism for that: `StickerSource` is `String`-raw-valued, so an unknown case in an old manifest fails to decode the whole entry — meaning cases may be **added** freely but must never be **renamed or removed**.

**`EmojiDownloader`** builds its URL from the entry's source rather than hardcoding Discord:

```swift
case .pasted, .server: "https://cdn.discordapp.com/emojis/\(id).png"
case .sevenTV:         "https://cdn.7tv.app/emote/\(id)/4x.webp"
```

**New unit `TransferPayloadParser`** — pure, no I/O, mirroring `EmojiMarkupParser`. Text in, `[ParsedEmoji]`-equivalents out, with source. Rejects payloads lacking the `DSTK1` header.

**UI:** the existing paste flow gains recognition of a `DSTK1` payload. **No new button.** A user who copies from the web page and taps the paste button they already know should simply see it work — the app can tell the two formats apart from the first line, and making the user pick would be asking them to explain something the software already knows.

---

## 8. Error handling

### Web page

| Condition | Behaviour |
|---|---|
| 7TV username not found | *"No 7TV emotes found for that user."* Discord markup already entered is untouched. |
| 7TV API unreachable | *"Couldn't reach 7TV — try again."* No partial state. |
| Discord markup with zero matches | *"No Discord emoji found in that text."* Same wording as the app, deliberately. |
| Nothing selected | Output area shows a prompt instead of an empty payload; Copy is disabled. |
| A thumbnail fails to load | Broken image placeholder; the emote is still selectable. Its thumbnail failing does not mean the phone's fetch will. |

### iOS

| Condition | Behaviour |
|---|---|
| Pasted text lacks the `DSTK1` header | Falls through to the existing Discord-markup parser, then to *"No Discord emoji found."* |
| A payload line is malformed | Skipped. Remaining lines import normally. |
| A 7TV emote 404s | Counted `missing`, exactly like a deleted Discord emoji. |
| A chunk is imported twice | Existing dedupe makes it a no-op, reported as `alreadyPresent`. |

---

## 9. Testing

**Web page** — a small unit test file run in the browser, no framework:

- Discord markup parsing matches the iOS parser on the same inputs, including the dedupe rule. **These two implementations must agree**; a shared corpus of test strings lives in the repo and both are checked against it.
- Payload generation: correct header, one line per selection, names containing spaces survive, an empty selection yields header-only.
- Chunking: a set below capacity yields one code; above it splits, every chunk carries the header, and the chunks reassemble to exactly the original selection with nothing dropped or duplicated.

**iOS:**

- `TransferPayloadParser`: valid payload; missing header; malformed lines mixed with good ones; unknown source tag; empty body; names with spaces; a payload with only a header.
- URL construction per source, asserted against `StubURLProtocol` — a `.sevenTV` entry must request the 7TV CDN and a `.pasted` entry the Discord CDN.
- A WEBP response normalizes correctly through the existing processor.
- An animated WEBP yields a single static frame, not an animation.
- `StickerSource.sevenTV` round-trips through `manifest.json`, and manifests written before this change still load.

**Manual:**

- Generate a payload on a real computer, transfer by clipboard and by QR, confirm both produce identical stickers.
- A multi-chunk set imports completely across several scans.

---

## 10. Deferred

- **BetterTTV and FrankerFaceZ.** The payload format's source tag makes them additive; 7TV alone establishes the pattern.
- **Native 7TV browsing on the phone.** The page covers the bulk case, and this would duplicate discovery logic on the constrained side.
- **A short-link service** so QR codes carry a URL instead of data. It would remove the capacity limit and require a server — the one thing §1 rules out.
- **A native Mac app with iCloud sync.** Paid tier.
