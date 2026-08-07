# Discord → iMessage Stickers — Design Handoff

**Date:** 2026-08-07
**Status:** Brainstorming ~80% complete. UX and architecture approved. Remaining sections: sync/data flow details, error handling, testing, then write the formal spec and implementation plan.
**Next step on the Mac:** resume the `superpowers:brainstorming` skill from Section 3 (data flow / error handling), finish the design, get spec approval, then `superpowers:writing-plans`.

---

## Goal

Use Discord custom emojis (static only) as iMessage stickers, without manually downloading each emoji and converting it in Photos.

---

## Decisions made

### Toolchain
- **Mac with a free Apple ID** (Personal Team), no paid Apple Developer membership.
- Consequence: **App Groups capability is unavailable.** The host app and the Messages extension cannot share a container.
- Consequence: app expires every **7 days** and must be re-run from Xcode with the iPhone connected (or on the same Wi-Fi).
- Xcode project should be created with Apple's templates on the Mac — do NOT hand-author `project.pbxproj`:
  - `File → New → Project → iOS → App`
  - `File → New → Target → iMessage Extension`

### Emoji source
- **Primary: paste emoji markup in bulk.** No Discord token, no bot, no ToS gray area.
  - Discord's "Copy Text" on a message returns raw markup: `<:blobcatcozy:823847191234>`.
  - Workflow: open Discord emoji picker → tap 30–50 emojis into the compose box → select all → copy → paste into the app. One paste = one batch.
  - Parse with regex, dedupe by ID, download from `https://cdn.discordapp.com/emojis/<id>.png?size=512`.
  - The public CDN needs no auth.
  - **Resolution ceiling:** Discord stores custom emoji at **128×128** natively. `?size=512` returns a server-side upscale, not extra detail — the detail does not exist. Still worth doing: one good server-side resample beats the display layer stretching 128px across ~400 physical pixels on every frame. 512 is the largest power of two under `MSSticker`'s 618×618 max.
  - **Verify before coding:** Discord's CDN restricts `size` to an allowed list. Powers of two are accepted; the earlier `?size=320` value is unverified. `curl` one emoji URL on the Mac before writing `EmojiDownloader`.
  - **Adaptive fallback:** if the 512 render exceeds `MSSticker`'s 500 KB limit, refetch at 256 rather than discarding the emoji.
  - **Not building:** on-device ML upscaling. A CoreML super-resolution pass inside a Messages extension trades the project's biggest reliability risk (the 40–120 MB memory ceiling) for a marginal sharpness gain.
  - Requesting `.png` on an **animated** emoji returns a **static first frame** — free win, matches the static-only requirement.
- **Secondary (phase 2): bot token browser** for the ONE server where Jonathan has Manage Server permission.
  - `GET /users/@me/guilds` then `GET /guilds/{id}/emojis`.
  - Store the bot token in the **Keychain**, not UserDefaults. No sharing needed since the extension owns it.

### Browse UX (APPROVED)
Modeled on Twitch emote sticker apps (7TV, Emote Keyboard):
- **Compact mode** (default short drawer): dense grid, ~5–6 emoji per row, with a **Recents** row pinned at top, auto-filled by tap count.
- **Expanded mode** (drawer dragged up): taller grid plus a **search field** filtering on the emoji's Discord name.
- **Source tabs** along the bottom: `Recent` · `All` · `<Server>` · `Pasted`.
- No manual folders/packs to maintain.
- **Not** using Apple's stock `MSStickerBrowserViewController` (no search, no tabs, no recents). Instead subclass `MSMessagesAppViewController` with a `UICollectionView` whose cells host `MSStickerView` — which still gives tap-to-send and drag-onto-bubble for free.

### Architecture (APPROVED, pending the one open question below)

Two targets, deliberately lopsided:

| Target | Role |
|---|---|
| `DiscordStickers` (iOS app) | Thin shell. One screen of setup instructions. Exists only because an iMessage extension can't ship alone. |
| `DiscordStickersMessages` (iMessage extension) | **Everything** — browsing, search, pasting, downloading, storage. |

Forced by the App Groups restriction: the extension can't read what the host app wrote, so the extension owns its world end to end. **The paste UI therefore lives inside the extension's expanded mode**, not in the host app.

Four units inside the extension:

- **`EmojiMarkupParser`** — pure function, no I/O. String in, `[ParsedEmoji]` out. Regex `<(a)?:([A-Za-z0-9_]+):(\d+)>`, deduped by ID. Unit-testable without a simulator.
- **`StickerStore`** — sole owner of `Documents/stickers/*.png` and `Documents/manifest.json`. API: `all()`, `search(_:)`, `add(_:)`, `delete(_:)`, `recordUse(_:)`.
- **`EmojiDownloader`** — `[ParsedEmoji]` → concurrent fetch (cap ~4–6) → validate → hand files to `StickerStore`. No UI knowledge.
- **`StickerGridViewController`** — `UICollectionView` of `MSStickerView` cells. Reads from `StickerStore`, never from disk directly.

Data model — `manifest.json` is one flat array:
```json
{ "id": "823847191234", "name": "blobcatcozy", "source": "pasted",
  "addedAt": "2026-08-07T22:14:00Z", "useCount": 12 }
```
Recents = sort by `useCount`. Source tabs = filter on `source`. Search = substring on `name`. One array feeds all three views, so there is no second index to keep in sync and no dangling-recents bug class.

---

## Critical technical constraints (do not lose these)

1. **Messages extension memory ceiling is tight** (~40–120 MB before the system kills it) — far tighter than a normal app. With hundreds of stickers, never hold decoded images in memory. `MSSticker` is file-URL-backed and loads lazily; rely on collection view cell recycling. This is the #1 thing separating a working emote app from one that crashes on scroll.
2. **`MSSticker` enforces limits:** ≤500 KB, dimensions between 100×100 and 618×618. Discord at `?size=320` fits comfortably, but the downloader must still **validate every file** — a rejected sticker throws at `MSSticker.init` and would crash the grid mid-scroll.
3. **App Groups is unavailable on a free Personal Team.** Any design that shares a container between app and extension will fail to build.
4. Search on emoji *name* only works because pasted markup carries the name. CDN URLs alone would give IDs with no searchable text.
5. A full reinstall (every 7 days) wipes the extension's Documents dir — so **re-syncing must be cheap and idempotent**. Consider an export/import of `manifest.json` so a re-paste isn't needed from scratch.

---

## Open question — ANSWERED 2026-08-07

> Does the two-target split look right, or would you rather the host app do more (e.g. be where you paste), accepting that this would require a **paid** Apple Developer account for App Groups?

**Answer: free tier now, structured for paid later.** Keep the extension self-contained and stay on the Personal Team. But `StickerStore` takes its storage root as an injected dependency rather than hardcoding `Documents/`, so migrating to a shared App Group container later is a change to one initializer call plus new host-app UI — not a rewrite.

---

## Remaining design sections to cover

3. Sync / data flow — what happens step by step on paste → download → appear in grid.
4. Error handling — dead emoji IDs (404), no network, oversized/invalid images, duplicate pastes, malformed input, partial batch failure.
5. Testing — parser unit tests, `StickerStore` round-trip, manual device checklist.
6. Persistence across the 7-day reinstall (export/import).

Then: write the spec to `docs/superpowers/specs/2026-08-07-discord-imessage-stickers-design.md`, commit, self-review, get approval, and invoke `superpowers:writing-plans`.
