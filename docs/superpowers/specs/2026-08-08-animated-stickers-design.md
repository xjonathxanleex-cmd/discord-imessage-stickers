# Animated Stickers — Design Spec

**Date:** 2026-08-08
**Status:** Design approved. Ready for implementation planning.
**Builds on:** `2026-08-07-discord-imessage-stickers-design.md`

---

## 1. Goal

Let Discord's animated custom emoji become animated iMessage stickers, instead of the static first frames the app stores today.

**This overturns a base-spec decision.** Base spec §1 lists "animated stickers" as a non-goal and §1's opening states animated emoji "are stored and sent as their static first frame." Both are superseded here. The original choice was made for simplicity, not because of a platform limit — `MSSticker` supports animated GIF and APNG.

### Non-goals

- Animated stickers from user photos or Live Photos. This spec covers Discord's animated emoji only.
- Editing animation — trimming, speed changes, reversing.
- Animated output for sources that arrive static. A static source stays static.
- A per-sticker "play/pause" control. Animated stickers animate.

---

## 2. Measured facts

Verified against live emoji on 2026-08-08 (`<a:cuh:1229610158183678072>`). Do not re-derive these from assumption; they drove every decision below.

| Request | Result |
|---|---|
| `…/1229610158183678072.gif` | **200**, GIF89a, **76×61, 94 frames, 157,069 bytes** |
| Same with `?size=128` and `?size=512` | **Byte-identical.** `size` is ignored for GIF, as it is for PNG. |
| A **static** emoji requested as `.gif` | **415 Unsupported Media Type** |

Three consequences shape the design:

1. **The URL extension must be chosen from `isAnimated`**, since guessing wrong returns 415. See §3.
2. **The raw file already fits** `MSSticker`'s 500 KB limit — but at 76×61 it is below the 100 px floor, so it still needs canvas normalization, exactly like static emoji.
3. **Canvas size now trades against file size, not just memory.** Scaling 76×61 to the static 256×256 canvas multiplies pixel area ~14×, across 94 frames. That is megabytes. The static `canvasSize = 256` constant is wrong for animated stickers, so they get their own budget (§5).

---

## 3. Data model

Add one property to `StickerEntry`:

```swift
public var isAnimated: Bool   // default false
```

**This is load-bearing, not metadata.** `ManifestTransfer.restore` rebuilds `ParsedEmoji` values from a decoded backup and re-downloads them. Without persisting this flag, every animated sticker would come back **static after a restore**, silently — and requesting the wrong extension returns 415, so it would come back as a failure rather than a static image.

That is the identical failure shape the Favorites final review caught: a value present in the model, dropped on the restore path, invisible until someone traced the whole flow. It is designed out here rather than discovered later. §8 pins it with a test.

Migration remains free: a `Bool` with a default value decodes from manifests lacking the key via the same synthesized-`Codable` mechanism that made `favoritedAt` free.

**Cross-spec note.** `2026-08-08-import-sources-design.md` §6 independently adds `.photo` and `.link` cases to `StickerSource`, and adds a content-hash identity scheme. The two are additive and do not conflict — this spec touches `StickerEntry`'s properties, that one touches `StickerSource`'s cases. Whichever is built second must extend rather than replace the first's work, and its "a manifest written before this change still loads" test must cover every field and case then present.

`ParsedEmoji.isAnimated` already exists and is parsed from `<a:name:id>` markup. It has been dead code since the base implementation — the base spec's final review flagged it as set-but-never-read. It now becomes essential.

---

## 4. Architecture

Animated emoji get a **parallel pipeline**, not a flag on the existing one. Their constraints differ in kind, not degree: file size scales with frame count, memory scales with frame count, and the encoder is different.

```
                    ┌─ isAnimated == false ─► StickerImageProcessor ──► 256² PNG ─┐
  downloaded bytes ─┤                                                              ├─► validate ─► StickerStore
                    └─ isAnimated == true  ─► AnimatedStickerProcessor ─► 128² APNG┘
```

### New unit: `AnimatedStickerProcessor`

Pure transform, no network and no store, mirroring `StickerImageProcessor`'s shape.

```swift
public enum AnimatedStickerProcessor {
    public static func normalize(
        _ data: Data,
        canvas: Int = StickerLimits.animatedCanvasSize,
        maxFrames: Int = StickerLimits.maxAnimatedFrames
    ) -> Data?
}
```

Steps:

1. Read frames and their **per-frame delays** via `CGImageSource`.
2. If the frame count exceeds `maxFrames`, drop frames evenly — **and redistribute each dropped frame's delay into the surviving frame that precedes it**, so total loop duration is unchanged.
3. Render every surviving frame onto a `canvas` × `canvas` transparent square, aspect-fit and centred, at high interpolation quality — the same geometry `StickerImageProcessor` uses.
4. Encode as **APNG** via `CGImageDestination`. Return `nil` for undecodable input.

**Step 2's second half is the part most easily got wrong.** Frames carry individual delays, so dropping every other frame while keeping the remainder's delays plays the loop at **half speed** — still smooth, silently wrong, and invisible to any assertion about frame count or file size. §8 tests total duration explicitly.

---

## 5. Constants

```swift
animatedCanvasSize = 128    // static stickers use 256
maxAnimatedFrames  = 48     // the measured cuh emoji has 94
```

Separate constants because they answer a different question. For static images, canvas size trades only against decoded memory. For animated, it trades against **file size as well**, and both scale with frame count — so a single shared number cannot be right for both.

**128 and 48 are a starting point validated on device (§8), not a derivation.** If animated stickers prove too large or the extension is killed while scrolling them, reduce `maxAnimatedFrames` first (§6).

---

## 6. Downloader changes

**URL selection** comes from `isAnimated`:

```
animated → https://cdn.discordapp.com/emojis/<id>.gif
static   → https://cdn.discordapp.com/emojis/<id>.png
```

No `size` parameter in either case — measured as ignored for both formats (§2).

**On HTTP 415, retry once with the other extension.** A 415 means the flag disagreed with reality; retrying self-heals it rather than reporting a puzzling failure. On success via retry, the stored entry records the corrected `isAnimated`.

**Size fallback tightens in a fixed order**, and the order matters:

1. Halve `maxFrames` and re-encode
2. Drop the canvas to 100 (the `MSSticker` floor) and re-encode
3. Reject as `unusable`

Frames are sacrificed before resolution because a slightly choppier animation reads as intentional, while a blurry sticker reads as broken.

**Format fallback:** if `MSSticker` refuses the APNG, re-encode the same frames as GIF and retry once. This catches outright rejection. It **cannot** catch an APNG that constructs successfully but renders only its first frame — construction success is the only signal available at that layer. That gap is closed by the device check in §8, not by code.

---

## 7. Error handling

| Condition | Behaviour |
|---|---|
| 415 on the first attempt | Retry once with the other extension; record the corrected flag on success |
| 415 on both extensions | Counted `unusable` |
| Source decodes to fewer than 2 frames | Treat as static — route to `StickerImageProcessor`, store as PNG, **and record `isAnimated == false`** on the entry, so a later restore does not request `.gif` for something that has no animation |
| Undecodable bytes | `normalize` returns nil → counted `unusable`, as today |
| Still over 500 KB after both reductions | Counted `unusable` |
| `MSSticker` rejects the APNG | Re-encode as GIF, retry once; if that also fails, `unusable` |
| Frame delays missing or zero in the source | Substitute 100 ms, the de-facto browser default for a zero-delay GIF frame |

Consistent with the base spec: failures are data, never exceptions, and a partial batch is the expected case.

---

## 8. Testing

### Automated

- **Total duration is preserved when frames are dropped.** A 94-frame source capped at 48 must produce a file whose summed frame delays match the original within a small tolerance. This is the test that catches the half-speed bug; frame-count and file-size assertions cannot.
- Frame reduction drops evenly rather than truncating — a 94-frame source must not become "the first 48 frames."
- Output dimensions are exactly `canvas` × `canvas`, within `MSSticker`'s 100–618 bounds, for square, non-square, and extreme-aspect sources.
- Transparency survives the re-encode.
- A single-frame GIF routes to the static path and stores as PNG.
- Undecodable bytes return nil rather than throwing.
- The 415 retry: a stub returning 415 for `.gif` and 200 for `.png` must produce a stored sticker, with `isAnimated` corrected to false.
- `isAnimated` round-trips through `manifest.json`, **and survives backup → restore** — the §3 failure mode.
- A manifest written before this change still loads, with every entry `isAnimated == false`.

### Device — the gate

**Run these before building anything on top of the format choice:**

1. A pasted animated emoji **actually moves** in the drawer.
2. It **still moves** after being sent into a conversation.
3. Scrolling a grid containing many animated stickers does not kill the extension.

If (1) or (2) fails, APNG constructs but does not animate. Switch the encoder to GIF and repeat. If (3) fails, reduce `maxAnimatedFrames` before touching the canvas size.

---

## 9. Deferred

- **A global "disable animation" setting.** The natural escape hatch if animated stickers prove too heavy in practice, but adding it before there is evidence of a problem is speculative.
- **Animated stickers from user photos or Live Photos.**
- **Per-sticker frame-rate tuning.**
- **7TV animated emotes**, which arrive as animated WEBP. The transform is the same shape; only the decode differs. Belongs with `2026-08-08-desktop-companion-design.md`.
- **An animated badge in the grid**, marking which stickers move.
