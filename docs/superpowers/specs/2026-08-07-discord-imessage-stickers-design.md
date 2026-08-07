# Discord → iMessage Stickers — Design Spec

**Date:** 2026-08-07
**Status:** Design complete and approved. Ready for implementation planning.

---

## 1. Goal

Use Discord custom emoji as iMessage stickers, without manually downloading each emoji and converting it in Photos.

Static images only. Animated Discord emoji are supported as sources, but are stored and sent as their static first frame.

### Non-goals

- Animated stickers.
- Any Discord account integration in v1 (no OAuth, no user token, no scraping the client).
- Manually curated packs or folders. Organization is automatic.
- On-device image upscaling or ML super-resolution. See §7.
- App Store distribution in v1. See §10 for what that would require.

---

## 2. Constraints

These shape every decision below. Losing track of one invalidates the design.

1. **Free Apple ID (Personal Team), no paid Developer membership.** Consequently **App Groups is unavailable** — the host app and the Messages extension cannot share a container. This fails at *provisioning time*, not runtime: a target declaring the capability under a Personal Team will not build at all (*"Personal development teams do not support the App Groups capability"*). There is therefore no way to trial a shared-container design before paying.

2. **The app expires every 7 days** and must be re-run from Xcode with the iPhone connected or on the same Wi-Fi. A reinstall wipes the extension's `Documents/` directory, so re-syncing must be cheap and idempotent.

3. **Messages extensions have a hard memory ceiling** — roughly 40–120 MB before the system kills the process, far tighter than a normal app. With hundreds of stickers, decoded images must never be held in memory. This is the single biggest reliability risk in the project.

4. **`MSSticker` enforces limits:** file ≤ 500 KB, dimensions between 100×100 and 618×618. `MSSticker.init(contentsOfFileURL:localizedDescription:)` throws when a file violates them.

5. **Discord stores custom emoji at 128×128.** No higher-resolution original exists anywhere. See §7.

6. **The Xcode project must be created from Apple's templates** on the Mac — do not hand-author `project.pbxproj`:
   - `File → New → Project → iOS → App`
   - `File → New → Target → iMessage Extension`

---

## 3. Architecture

### Targets

| Target | Role |
|---|---|
| `StickerKit` (framework) | All logic and reusable UI — parser, store, downloader, grid, paste view controller. Linked by both targets below. |
| `DiscordStickers` (iOS app) | Thin shell in v1. One screen of setup instructions. Exists only because an iMessage extension cannot ship alone. |
| `DiscordStickersMessages` (iMessage extension) | Hosts the `StickerKit` UI. In v1 it owns everything — browsing, search, pasting, downloading, storage. |

The lopsided split is forced by §2 constraint 1: the extension cannot read what the host app wrote, so in v1 the extension owns its world end to end. **The paste UI therefore lives inside the extension's expanded mode**, not in the host app.

### Designed so the paid-tier flip is cheap

The governing distinction: **App Groups shares *data* between targets at runtime and is unavailable on a free Personal Team. A shared framework shares *code* between targets at compile time and is not restricted.** A build that declares the App Groups capability under a Personal Team fails to provision entirely — there is no 7-day trial of that architecture — so v1 must be genuinely free-tier-native, not a paid design running in degraded mode.

Three seams make the later upgrade an evening rather than a rewrite:

1. **`StickerKit` is a real framework target**, not source files pasted into the extension. Both targets link it. Free-tier legal, and it also makes the logic testable outside an app extension (§8).
2. **`StickerStore` takes its storage root as an initializer parameter**, never reaching for `FileManager.default.urls(for: .documentDirectory, …)` internally. The free build passes the extension's own `Documents/`; a paid build passes the shared container URL. This same injection is what allows testing against a temp directory.
3. **The paste flow is a self-contained view controller** in `StickerKit`, not logic welded into the extension's drawer controller. The free build presents it inside expanded mode; a paid build presents the same class full-screen from the host app.

The upgrade path is then: obtain the membership, enable App Groups on both targets, change one URL, and add a host-app screen presenting a view controller that already exists. §9 (reinstall persistence) becomes unnecessary at that point, since the 7-day expiry extends to a year.

None of these three costs anything today — the view controller must live somewhere regardless, and the store needs a path regardless. The design simply declines to hardcode the two facts known to be changeable.

### Units

Five units inside `StickerKit`, each independently understandable and — except the last two — independently testable without a device.

- **`EmojiMarkupParser`** — pure function, no I/O. String in, `[ParsedEmoji]` out. Regex `<(a)?:([A-Za-z0-9_]+):(\d+)>`, deduped by ID within the batch.

- **`StickerStore`** — sole owner of `<root>/stickers/*.png` and `<root>/manifest.json`. Confined to a serial queue; nothing else touches disk. API: `all()`, `search(_:)`, `add(_:)`, `delete(_:)`, `recordUse(_:)`.

- **`EmojiDownloader`** — `[ParsedEmoji]` → concurrent fetch (cap ~5) → validate → hand files to `StickerStore`. No UI knowledge. Returns per-item results; does not throw.

- **`StickerGridViewController`** — `UICollectionView` whose cells host `MSStickerView`. Reads from `StickerStore`, never from disk directly.

- **`PasteViewController`** — the paste control, the diff report, and the batch summary. Self-contained and parent-agnostic, so it can be presented from the extension's expanded mode (v1) or full-screen from the host app (paid tier) with no changes.

### Data model

`manifest.json` is one flat array:

```json
{ "id": "823847191234", "name": "blobcatcozy", "source": "pasted",
  "addedAt": "2026-08-07T22:14:00Z", "useCount": 12 }
```

Recents = sort by `useCount` (full ordering rule in §5). Source tabs = filter on `source`. Search = substring on `name`. One array feeds all three views, so there is no second index to keep in sync and no dangling-recents bug class.

**Manifest invariant:** every entry in `manifest.json` is known-constructible as an `MSSticker`, because nothing enters the manifest without having been constructed as one at least once (§5, step 5).

---

## 4. Emoji source & browse UX

### Source: bulk markup paste

No Discord token, no bot, no ToS gray area.

Discord's "Copy Text" on a message returns raw markup: `<:blobcatcozy:823847191234>`. The workflow is: open the Discord emoji picker → tap 30–50 emoji into the compose box → select all → copy → paste into the app. One paste is one batch.

Emoji are fetched from the public CDN at `https://cdn.discordapp.com/emojis/<id>.png?size=512`, which needs no auth. Requesting `.png` on an animated emoji returns a static first frame — which matches the static-only requirement for free.

Search on emoji *name* works only because pasted markup carries the name. CDN URLs alone would give IDs with no searchable text.

### Browse UX

Modeled on Twitch emote sticker apps (7TV, Emote Keyboard):

- **Compact mode** (default short drawer): dense grid, ~5–6 emoji per row, with a **Recents** row pinned at top, auto-filled by tap count.
- **Expanded mode** (drawer dragged up): taller grid, a **search field** filtering on emoji name, and the paste control.
- **Source tabs** along the bottom: `Recent` · `All` · `Pasted`. A `<Server>` tab appears only if the phase-2 bot token browser (§10) is ever built; in v1, `All` and `Pasted` contain the same set, so `Pasted` is hidden until a second source exists.
- No manual folders or packs to maintain.

**Not** using Apple's stock `MSStickerBrowserViewController` — it offers no search, no tabs, and no recents. Instead subclass `MSMessagesAppViewController` with a `UICollectionView` whose cells host `MSStickerView`, which still gives tap-to-send and drag-onto-bubble for free.

**Paste uses `UIPasteControl`** (iOS 16+), not a plain button calling `UIPasteboard.general.string`. Reading the pasteboard in code triggers a system *"Allow Paste?"* alert on every invocation, which would be intolerable for this app's core action. A tap on `UIPasteControl` *is* the consent, so access is granted silently.

---

## 5. Data flow

The path a pasted string takes. All of it runs inside the extension, triggered from expanded mode.

1. **Capture.** User taps the paste control; the system hands over the pasteboard string. Nothing polls or observes the clipboard.

2. **Parse.** `EmojiMarkupParser` extracts `<(a)?:name:id>` triples and dedupes by ID within the batch. A paste with zero matches is a normal reportable outcome, not an error.

3. **Diff.** Subtract IDs already in `StickerStore.all()`. Download work is done only for new IDs. Re-pasting an overlapping batch — the natural user habit — is therefore free and non-destructive.

4. **Download.** `EmojiDownloader` fetches new IDs via `URLSession`, concurrency capped at ~5. Each item proceeds independently.

5. **Validate before commit.** Two gates:
   - Cheap: byte count ≤ 500 KB, and PNG-header dimensions within 100–618. If the 512 render exceeds 500 KB, refetch at 256 before rejecting (§7).
   - Decisive: construct an `MSSticker` from the file URL immediately. If the initializer throws, delete the file and drop the entry.

   The second gate exists because the natural place to call the throwing initializer is `cellForItemAt` during scroll, where a throw is a crash mid-gesture on a device with no debugger attached. Constructing it once at download time converts a scroll-time crash into a download-time skip, and establishes the manifest invariant from §3.

6. **Commit per item, not per batch.** On success, `StickerStore.add(entry)` appends to the in-memory array and schedules a manifest write; the sticker appears in the grid immediately. Per-item commit also means a memory-killed batch loses only the in-flight item rather than all of them.

7. **Persist.** `manifest.json` is written atomically (temp file plus rename), debounced ~300 ms so a fast batch performs a handful of writes rather than one per sticker.

**Reads flow one direction.** The grid asks `StickerStore` for a filtered, sorted array and builds `MSSticker` objects lazily in `cellForItemAt`, relying on cell recycling to keep decoded images out of memory. Recents sorts by `useCount` descending, `addedAt` descending as tiebreak, capped at 16.

**Use counting is approximate.** `MSStickerView` handles tap-to-send internally and exposes no delegate callback on insertion. A `UITapGestureRecognizer` on the cell, configured to recognize simultaneously with the sticker view's own handling, observes the tap without stealing it. This counts *taps*, not confirmed sends, so `useCount` is a popularity heuristic. That is sufficient for ordering a Recents row, and the approximation is deliberate.

---

## 6. Error handling

Organizing principle: **a batch never fails as a unit.** Every emoji succeeds or fails on its own, failures are collected as data rather than thrown, and the user gets one honest summary at the end.

| Condition | Behavior |
|---|---|
| Emoji deleted from server (404) | Skip and count. Reported as *"3 emoji no longer exist."* Not retried — a 404 here is permanent. |
| No network | Detected before any work begins. *"You're offline — paste again when you're back."* The pasted text is not consumed. |
| Fails validation (oversized after 256 fallback, wrong dimensions, or `MSSticker` won't construct) | File deleted, entry never enters the manifest. Counted as *"1 couldn't be used."* |
| Duplicate paste | Not an error. The step-3 diff makes it a no-op. |
| Malformed or non-emoji text | Zero matches is a normal outcome: *"No Discord emoji found in what you pasted."* |
| Partial batch failure | The expected case, not the exceptional one. 9 of 12 landing is a success with a footnote. |
| Extension memory-killed mid-batch | Per-item commit means everything already downloaded is on disk and in the manifest. Re-pasting resumes exactly where it stopped, because the diff skips what is already there. |
| Corrupt `manifest.json` | Do not crash, do not wipe. Rename to `manifest.json.broken`, start fresh, and rebuild what is recoverable by scanning `stickers/` for files. Names are lost; images survive. Search is degraded until the user re-pastes. |

**Idempotent re-paste is the universal recovery mechanism.** The same gesture resolves a dead network, a killed extension, a partial batch, and the 7-day reinstall. One recovery path is a much smaller thing to get right than four — and it is why §9's export/import is a convenience rather than a necessity.

---

## 7. Image quality

**The ceiling is fixed and low.** Discord downsizes every custom emoji to 128×128 on upload and discards the original. There is no high-resolution version to fetch, and no conversion can create one — any upscale invents plausible pixels between real ones.

**What we do anyway, because it is free.** Request `?size=512` rather than accepting the default 128px render. Discord resamples server-side with good quality; we then hand iOS an image close to the size it will actually display. Without this, a 128px image gets stretched across roughly 400 physical pixels by the display compositor on every frame, using whatever cheap filter it picked — which is the visible blur users notice when they download Discord emoji by hand.

To be precise about the benefit: this is not more detail. It is the same 128px of information, resampled well once, instead of resampled badly at display time. The result is clean and soft rather than blurry and smeared. It will look clearly better than a manual download and will never look as crisp as a native Apple sticker.

512 is the largest power of two below `MSSticker`'s 618×618 maximum.

**Adaptive fallback.** A 512×512 PNG of flat art is small, but a busy or photographic emoji upscaled to 512 can exceed the 500 KB limit. The downloader then refetches at 256 rather than discarding the emoji. Falling back one step is strictly better than reporting a failure when a usable smaller version was one request away.

**To verify on the Mac before writing `EmojiDownloader`:** Discord's CDN restricts `size` to an allowed list of values. Powers of two are accepted. Confirm with a single `curl` against a known emoji ID that `?size=512` returns 200 and a 512×512 PNG.

**Explicitly not built:** on-device ML super-resolution. Running a CoreML model inside a Messages extension would trade the project's largest reliability risk (§2 constraint 3) for a marginal sharpness gain.

---

## 8. Testing

The dividing line is whether a behavior depends on something we control. Logic we own is automated; everything the iOS runtime does *to* us is a manual device check.

### Automated — no simulator, runs in a second

**`EmojiMarkupParser`.** A pure function, and the one place a subtle bug produces silently wrong results rather than a crash. Cases: a lone emoji; several adjacent with no separator; animated `<a:name:id>`; the same emoji twice in one paste; emoji embedded in ordinary chat text; names with underscores and digits; malformed fragments like `<::>`; empty string; and Unicode emoji such as 🙂, which must **not** match.

**`StickerStore`.** Round-trips against a temp directory, enabled by the injected storage root. Cases: add then read back; adding the same ID twice does not duplicate; delete removes both the manifest entry and the file; `recordUse` increments and survives a reload; search is case-insensitive substring; a deliberately corrupted `manifest.json` triggers the §6 salvage path rather than crashing.

**`EmojiDownloader`.** Against a stubbed `URLProtocol`, so no real request goes out and the miserable-to-reproduce failures become ordinary tests: a 404; a response over 500 KB that must fall back to 256; a response still over the limit at 256, which must be rejected; a batch where 9 succeed and 3 fail, returning both lists. §6's error table is only trustworthy if these are pinned here.

### Manual device checklist

- **Scroll fast through 300+ stickers.** The single most important check in the project. If cell recycling is not keeping decoded images out of memory, the system kills the extension, and this is the only place that surfaces.
- Tap a sticker — does it insert into the conversation?
- Drag a sticker onto an existing bubble (peel-and-stick).
- Compact → expanded → compact without losing scroll position.
- Paste via `UIPasteControl` with no *"Allow Paste?"* alert appearing.
- Recents reorder after repeated taps on the same sticker.
- Search filters as you type.
- Extension cold-launch time is within Messages' window for extensions to appear.
- On day 8: reinstall and confirm the recovery story works end to end.

---

## 9. Surviving the 7-day reinstall

§6 already supplies a working answer: **re-paste is the recovery path**, idempotent by construction. Nothing else strictly needs to exist.

Export/import is therefore a convenience and stays small. A control in expanded mode copies `manifest.json` to the clipboard as text; the matching import reads it back and re-downloads every listed emoji. Text on the clipboard rather than a file, because it survives being pasted into a note and retrieved a week later, and because file-sharing UI from inside a Messages extension is more friction than this feature warrants.

**What it preserves that a re-paste does not:** `useCount` history, so Recents returns correctly ordered rather than empty. That is the actual justification. Names and images come back from the CDN; the accumulated sense of which emoji the user actually reaches for is the only irreplaceable data in the app.

Build this **last**, after everything else works. Cut it without regret if it fights.

---

## 10. Deferred

### Phase 2 — bot token browser

For the one server where the user holds Manage Server permission: `GET /users/@me/guilds`, then `GET /guilds/{id}/emojis`. The bot token goes in the **Keychain**, not `UserDefaults`. No sharing is needed, since the extension owns it. This populates the `<Server>` source tab without any pasting.

### App Store distribution

Viable, but the obstacles are legal rather than technical.

- **Intellectual property (App Review Guideline 5.2) is the real gate.** Most Discord custom emoji are cropped frames from copyrighted work. The app's saving grace is structural and already present: it ships empty and the user supplies content, making it a tool rather than a distributor. **Never bundle a starter set of third-party characters.** If demo content is needed for review, use Google's openly licensed blob emoji (Apache 2.0 / CC-BY), which are also the on-brand aesthetic.
- **Discord's terms.** Pointing a distributed app at `cdn.discordapp.com` is invisible at one-user scale and noticeable at thousands. Discord may rate-limit or block it. This is a business risk, not a review blocker.
- **Mechanics.** Paid Developer Program, privacy policy URL, support URL, screenshots.
- **Code impact is small.** A paid account unlocks App Groups, so paste and management move into a full-screen host app and the extension becomes a thin browser. The three seams in §3 — the `StickerKit` framework, the injected storage root, and the parent-agnostic `PasteViewController` — are what keep that an evening's work rather than a restructure.

---

## 11. Verify on the Mac before coding

1. `curl` a known emoji ID at `?size=512` — confirm 200 and 512×512 output, and confirm which `size` values the CDN accepts.
2. Confirm `UIPasteControl` is usable inside a Messages extension on the target iOS version.
3. Confirm the free Personal Team provisions both targets together without an App Groups entitlement anywhere in either target's capabilities.
