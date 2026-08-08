# Task 11 — Device verification results

**Date:** 2026-08-07
**Device:** iPhone 17 Pro Max (iPhone18,2), iOS 26.x
**Build:** `feature/sticker-kit`, free Personal Team signing

## Results

| # | Check | Result |
|---|---|---|
| 1 | App installs and launches on device | ✅ pass (after trusting the developer certificate) |
| 2 | Extension appears in the Messages app row | ✅ pass |
| 3 | Paste imports a batch of emoji | ✅ pass — **after two fixes**, see below |
| 4 | Tap a sticker to send | ✅ pass |
| 5 | Drag a sticker onto a bubble | ✅ pass |
| 6 | Recents reorder after repeated taps | ✅ pass |
| 7 | Search filters the grid live | ✅ pass |
| 8 | Compact ↔ expanded transitions | ✅ pass |
| 9 | Transparency preserved on transparent emoji | ✅ pass — visually confirmed, no white boxes |
| 10 | Aspect ratio preserved on non-square emoji | ✅ pass — visually confirmed, no stretching |
| 11 | **Memory: scroll 300+ stickers without a kill** | ⏳ **deferred** — needs volume that accumulates through real use |

## Two bugs the device found that nothing else could

Both were assumptions about how Apple's frameworks behave at runtime — not defects in our own logic, and therefore invisible to 52 unit tests and every code review.

### 1. `UIPasteControl` renders permanently disabled inside a Messages extension

The paste button was greyed out and untappable even with correct markup on the clipboard (verified by pasting into the ordinary iMessage field on the same device). `UIPasteControl` decides its own enabled state by inspecting the pasteboard, and inside the extension's sandbox it evidently cannot.

**Fix (commit `13e2cb8`):** replaced with a plain `UIButton` reading `UIPasteboard.general.string`. This restores the system "Allow Paste?" prompt that `UIPasteControl` was chosen to avoid — an acceptable trade, since the original rationale overweighted it. The alert appears once per *batch paste*, a roughly weekly operation, not per sticker sent.

### 2. `NWPathMonitor` reports asynchronously, so the first read always said "offline"

Every paste failed with *"You're offline — paste again when you're back."* on a device with a working connection. `NWPathMonitor` delivers its first path via `pathUpdateHandler` asynchronously; before that arrives, `currentPath.status` is `.unsatisfied`. Because the monitor was started lazily and read microseconds later on the same call, the first read always preceded the first update.

The Task 8 reviewer had flagged this exact line as `⚠️ Cannot verify from diff — that's a framework timing question`. It was right, and the device answered it.

**Fix (commits `e1342b3`, `d03da0c`):** treat an undelivered status as online, so an unknown state can never block a paste. Also hoisted the monitor into a static — as a local inside the once-only start closure it was eligible for deallocation, which would have stopped updates entirely and silently reduced the check to a constant `true`.

## Note on the remaining check

Check 11 is the one that validates `StickerLimits.canvasSize = 256`. That constant was chosen over 512 to protect the extension's 40–120 MB ceiling — roughly 5 MB of decoded RGBA across ~20 visible cells rather than ~20 MB. If the drawer ever goes blank or snaps shut while scrolling a large grid, that is the signal, and the remedy is a one-line change to `StickerLimits.fallbackCanvasSize`'s sibling constant.
