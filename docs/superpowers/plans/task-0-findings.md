# Task 0 findings — Discord CDN behavior

**Date:** 2026-08-07
**Emoji tested:** `<:67:1481800758532903104>` (static), `<a:cuh:1229610158183678072>` (animated)

## Result: two spec assumptions were wrong

### 1. `?size=` only downscales. It never upscales.

| Request | Returned | Bytes |
|---|---|---|
| `.png?size=64` | 64×64 | 6,197 |
| `.png?size=128` | 128×128 | 17,651 |
| `.png?size=256` | **128×128** | 17,651 |
| `.png?size=512` | **128×128** | 17,651 |
| `.png?size=1024` | **128×128** | 17,651 |
| `.png` (no param) | 128×128 | 17,651 |
| `.webp?size=512` | **128×128** | 3,938 |

Every request at or above native resolution returns the native image byte-for-byte identical. The `size` parameter is a downscale-only cap.

**Consequence:** spec §7's premise — "request 512 and Discord resamples server-side" — is false. There is no server-side upscale to obtain. `?size=320` returning 200 (contradicting the earlier guess that it would 400) is irrelevant for the same reason: the parameter has no upward effect.

### 2. Emoji are not all 128×128, and some fall below `MSSticker`'s minimum.

The animated test emoji returns **76×61** at every requested size. `MSSticker` requires both dimensions ≥ 100.

**Consequence:** that emoji — and every emoji stored below 100px on either axis — would fail validation and be reported "couldn't be used". Discord does not pad emoji to a square, so non-square and undersized emoji are ordinary, not exotic. Left unfixed, this would silently drop a real fraction of every paste.

### 3. Animated emoji do return a static PNG first frame.

`file` reports `PNG image data, 76 x 61, 8-bit/color RGBA` for the animated ID. This assumption **held** — requesting `.png` on an animated emoji is a valid way to get a static frame.

## Required design change

Downloaded bytes can no longer go straight to `MSSticker`. A local normalization step must sit between download and validation: render every image onto a fixed square transparent canvas, aspect-fit and centered.

This solves both problems with one code path — undersized emoji clear the 100px floor, non-square emoji get consistent framing in the grid, and extreme aspect ratios are handled by padding rather than by a scale calculation that cannot satisfy both bounds at once.

**Canvas size chosen: 256×256.** The tradeoff is memory against sharpness, and memory wins because the extension's 40–120 MB ceiling is this project's documented top crash risk. With roughly 20 cells visible, decoded RGBA costs about 5 MB at 256 versus about 20 MB at 512 — and 20 MB against a 40 MB floor is not a margin worth spending on interpolated detail that was never in the source. Task 11's scroll test is what validates this number; if the extension still dies, drop it to 128.
