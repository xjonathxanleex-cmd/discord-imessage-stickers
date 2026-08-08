# Additional Import Sources — Design Spec

**Date:** 2026-08-08
**Status:** Design approved. Ready for implementation planning.
**Builds on:** `2026-08-07-discord-imessage-stickers-design.md`

---

## 1. Goal

Let stickers come from two sources beyond pasted Discord markup:

- **Photos** on the device
- **Any image URL**, pasted as a link

Both feed the existing pipeline unchanged. `StickerImageProcessor` already accepts arbitrary image bytes and normalizes them onto the 256×256 canvas; `StickerStore` and the grid neither know nor care where a sticker came from.

### Why now

Runtime stickers can never reach iOS's own sticker drawer (base spec §2 constraint 7), so this app's drawer is the only surface they will ever have. That makes it worth filling by more than one route — and it means an unnamed, unsearchable sticker is effectively lost, which shapes §4.

### Non-goals

- Background removal. Blocked on the paid account; it wants the host app, not the extension.
- A Share Extension. Also blocked — a third extension target gets its own sandbox container and cannot write where the Messages extension reads, so it requires App Groups.
- Bulk renaming after the fact.
- Editing, cropping, or rotating images. iOS's own editor is one tap away in Photos.

---

## 2. Image formats

**Accept anything iOS can decode** — PNG, JPEG, HEIC, WEBP, GIF, TIFF, BMP. `UIImage(data:)` handles all of them and `StickerImageProcessor` already goes through it, so no format checking is needed or wanted. A user picking a photo should never think about formats.

**Always store PNG**, which is already what `normalize` emits. Two reasons, both load-bearing:

- **Alpha.** The canvas approach depends on transparency — padding around non-square images is transparent. JPEG has no alpha channel, so a JPEG-stored sticker would carry a white or black box.
- **Lossless.** A 128×128 Discord emoji has little detail to spare; re-compressing it lossily would visibly hurt.

Photographs compress poorly as PNG, but at 256×256 they land around 100–200 KB — well under `MSSticker`'s 500 KB — and the existing fallback re-renders at 128 if one ever doesn't.

---

## 3. Architecture

Both sources converge on one new screen before anything is committed.

```
Photos  ──┐
          ├──►  [ StickerDraft ]  ──►  ReviewViewController  ──►  StickerStore
Link    ──┘        (name + data)         (name, confirm)
```

### New unit: `StickerDraft`

A value type representing a sticker that has been fetched but not yet accepted:

```swift
public struct StickerDraft: Identifiable, Equatable {
    public let id: String            // stable identity; see §6
    public var name: String          // pre-filled, user-editable
    public let imageData: Data       // raw, un-normalized
    public let origin: StickerSource
}
```

### New unit: `StickerReviewViewController`

One screen shared by both sources, in `StickerKit`, parent-agnostic like `PasteViewController`. Shows a list of drafts — thumbnail, editable name field — plus **Add** and **Cancel**.

- Presented modally from expanded mode.
- On **Add**, each draft is normalized, validated, and committed through the existing path.
- On **Cancel**, nothing is written and no files are left behind.
- `onFinished: ((DownloadOutcome) -> Void)?` — same contract `PasteViewController` already uses, so the caller's reload logic is unchanged.

Existing markup paste does **not** route through this screen. It already carries real names from Discord, and forcing a review step onto a 50-emoji batch would be a regression.

---

## 4. Naming

**Every sticker gets a name before it is stored.** Search matches on name and this drawer is the only place these stickers exist, so an unnamed sticker is one you can only find by scrolling.

Defaults are pre-filled so the common case is one tap:

| Source | Default name |
|---|---|
| Photo | `photo 1`, `photo 2`, … numbered within the batch |
| 7TV URL | the real emote name, from the 7TV API (§5) |
| Discord CDN URL | the emoji id (the URL carries no name) |
| Any other URL | the filename without extension, e.g. `party-parrot` from `…/party-parrot.png` |

Names need not be unique — `StickerStore` keys on id, and two stickers called `photo 1` are a cosmetic annoyance, not a correctness problem.

An empty name is rejected inline: **Add** stays disabled while any field is blank, rather than silently substituting a default the user didn't choose.

---

## 5. Source: link paste

A **Paste Link** button in expanded mode reads `UIPasteboard.general.string` — the same plain-button approach the main paste flow now uses, for the same reason (`UIPasteControl` renders permanently disabled inside a Messages extension).

**Any image URL is accepted.** Restricting to known hosts would be a rule users must learn and will get wrong; with a naming step in place, the only argument for restriction disappears.

Recognition happens in a new pure unit, `LinkParser`:

| Pattern | Handling |
|---|---|
| `cdn.discordapp.com/emojis/<id>.<ext>` | Extract id. Default name is the id. |
| A 7TV emote or emote-set URL | Resolve via the 7TV API to get real names. A set yields many drafts from one link. **Depends on `2026-08-08-desktop-companion-design.md`** — see the cross-spec note below. |
| Any other `http(s)` URL | Fetch directly. Default name from the filename. |
| Not a URL at all | *"That doesn't look like a link."* No draft screen is shown. |

**Cross-spec dependency.** 7TV handling — the `StickerSource.sevenTV` case, the 7TV CDN URL construction, and the animated-WEBP first-frame rule — is specified in `2026-08-08-desktop-companion-design.md` §6–§7, not here. If that project is built first, this row works as written. If this one is built first, **drop the 7TV row**: a 7TV URL then falls through to the generic branch, which fetches it as an ordinary image with a filename-derived name. That degrades gracefully and needs no coordination between the two plans.

### Fetch safety

Arbitrary URLs mean arbitrary responses, so the fetch is bounded:

- **10 MB ceiling**, enforced by inspecting `Content-Length` and by aborting a streamed body that exceeds it. Protects the extension's 40–120 MB memory ceiling from a hostile or careless URL.
- **15 second timeout.**
- **Redirects followed, capped at 5.**
- **No content-type trust.** Whatever comes back goes to `StickerImageProcessor.normalize`, which returns nil for anything undecodable. The bytes decide, not the header.

---

## 6. Identity for non-Discord stickers

Discord stickers use the emoji's snowflake id, which is globally unique and stable. Photos and arbitrary URLs have no such thing, and `StickerStore` requires an id that is unique and stable across re-adds.

**Rule:** the id is the lowercase hex **SHA-256 of the normalized PNG bytes**, prefixed `sha256-`.

This gives content-addressed identity with two useful consequences:

- **Re-adding the same photo is a no-op**, exactly like re-pasting the same Discord emoji. The dedupe behaviour users already rely on extends to every source for free.
- **The same image from two different URLs collapses to one sticker**, which is almost always what someone wants.

Hashing happens *after* normalization, so two source files that render identically onto the canvas are correctly treated as one sticker.

`StickerSource` gains `.photo` and `.link` alongside `.pasted` and `.server`. This is also the field that lets a later `Photos` or `Links` tab exist without a data migration.

---

## 7. Source: photo picker

A **Add Photo** button in expanded mode presents `PHPickerViewController` with `selectionLimit = 0` (unlimited multi-select).

**⚠️ Verify before building.** `PHPickerViewController` is out-of-process and generally available to extensions, but Messages extensions have surprised this project twice already — `UIPasteControl` renders disabled, and `NWPathMonitor` reports asynchronously. Confirm the picker actually presents and returns items from inside the extension *before* writing the rest of this feature. If it does not, this source moves to the paid-account tier alongside the Share Extension.

Selected items load as `Data` via `NSItemProvider`, become drafts, and go to the review screen. HEIC from the camera is handled transparently by §2.

---

## 8. Error handling

Consistent with the base spec: failures are data, never exceptions, and a batch never fails as a unit.

| Condition | Behaviour |
|---|---|
| URL fetch fails (offline, DNS, 404, timeout) | Reported on the review screen before anything is stored: *"Couldn't fetch that link."* |
| Response is not a decodable image | Same message. `normalize` returning nil is the test, not the content-type header. |
| Response exceeds 10 MB | *"That image is too large."* |
| Photo fails to load from the picker | That item is skipped; the rest still reach the review screen, with a count of what was dropped. |
| A draft's normalized PNG exceeds 500 KB | Existing fallback re-renders at 128; only then is it counted unusable. |
| Sticker already in the store (same content hash) | Counted as `alreadyPresent`, exactly like a duplicate paste. Not an error. |
| User cancels the review screen | Nothing written, no orphaned temp files. |

---

## 9. Testing

**Automated**, following existing patterns:

- `LinkParser`: a pure function, so it gets the same exhaustive treatment as `EmojiMarkupParser` — Discord CDN URLs with each extension; 7TV emote and emote-set URLs; a bare image URL; a URL with query parameters; a non-URL; an empty string; an `ftp://` URL (rejected); a URL with no filename to derive a name from.
- Content-hash identity: the same image normalized twice yields the same id; two visibly different images do not; the id is stable across process restarts.
- Fetch bounds, against `StubURLProtocol`: a 404; a body over 10 MB; a non-image body; a redirect chain within the cap; one exceeding it.
- Draft → store commit: names carry through; cancel writes nothing; a duplicate hash is reported `alreadyPresent`.
- `StickerSource` round-trips `.photo` and `.link` through `manifest.json`, and a manifest written before this change still loads.

**Manual device checks:**

- `PHPickerViewController` presents from inside the extension at all (§7).
- Multi-select returns every chosen photo.
- A HEIC photo from the camera imports correctly.
- The review screen's keyboard does not obscure the name field in expanded mode.

---

## 10. Deferred

- **Source tabs** for `Photos` and `Links`. The `source` field is recorded from day one, so adding them later needs no data migration.
- **Renaming after import.** Edit mode already exists from the Favorites spec and would be the natural home.
- **Cropping or rotation.**
- **A per-source download budget** or history.
