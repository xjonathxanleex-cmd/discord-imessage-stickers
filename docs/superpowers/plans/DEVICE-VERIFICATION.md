# Device verification — consolidated session

**Date:** 2026-08-08
**Covers:** Favorites, animated stickers, link import, photo import, 7TV — plus the memory
test deferred from Task 11.

Five plans each wrote their own checklist independently. Run separately they would have you
install, import, and re-import five times. This merges them into one session and — more
importantly — **runs the gates first**.

## Why gates come first

Four checks can invalidate work that is already merged. Everything else is confirmation.
Answer these four before spending time on detail:

| # | Gate | If it fails |
|---|---|---|
| G1 | In Edit mode, tapping a sticker must **not** send it | Favorites is unsafe to ship |
| G2 | Does an APNG **animate**? | The animated format choice is wrong — 4 changes, not 1 |
| G3 | Does the review screen **present** at all? | Link *and* photo import both blocked |
| G4 | Does `PHPickerViewController` **appear**? | Photo import moves to the paid tier |

G3 comes before G4 deliberately: both present the same `StickerReviewViewController`
modally, and link import is the cheaper way to ask the question. If G3 fails, G4's result
tells you nothing new.

Record the answer to each gate before continuing past it. A failed gate is a **stop and
report**, not a "try the next thing".

---

## Phase 0 — Install

1. Plug the iPhone into the Mac.
2. Open the project in Xcode.
3. Scheme selector (top bar) → **DiscordStickersMessages**. Destination → your iPhone.
4. Press ▶.
5. Xcode asks which app to run it in → choose **Messages**.

**"Could not attach to pid" is expected — dismiss it.** An extension only launches when you
tap it, so there is no process to attach to yet. The install still succeeded.

Open Messages → any conversation → the app row under the text field → the sticker icon.

> This also resets the 7-day signing clock. The app expires ~August 14th otherwise.

---

## Phase 1 — The gates

### G1 · Editing must not send

Expand the drawer (drag it up). Tap **Edit** — the title becomes **Done**.
Now tap a sticker's **image** — not its star, not its ×.

- ✅ Nothing is inserted into the conversation.
- ❌ A sticker sends → `stickerView.isUserInteractionEnabled = false` is not taking effect.

Also try to **drag** a sticker while editing. It must not peel off.

### G2 · Does it move?

In Discord, send yourself a message with at least one **animated** emoji (its markup starts
`<a:`) plus two static ones. Long-press the sent message → **Copy Text**.

In the drawer: expand → **Paste Emoji** → **Allow**. Expect a summary saying all three added.

Look at the animated one in the grid. **It must be animating.**

**If it is still, do NOT conclude the format is wrong yet.** `StickerCell.configure` assigns
`stickerView.sticker` but never calls `startAnimating()`, and Apple's header does not say
that assignment starts playback. So a frozen sticker may just mean nobody pressed play.

Tell me if it's frozen — the fix is a two-line change I'll make before we touch the format.
Switching to GIF first would find GIF equally frozen and wrongly rule out animation entirely.

### G3 · Does a modal present?

In Discord, long-press any custom emoji → **Copy Link**. In the expanded drawer, tap
**Paste Link** → **Allow**.

- ✅ A review screen slides up with the emoji's numeric id pre-filled as the name.
- ❌ Nothing appears → check the console. If the status label says "Fetching…" and stops,
  that looks identical to a network hang but is actually modal presentation failing. A
  Messages extension is itself presented inside Messages, and this is the first time the app
  presents on top of that.

### G4 · Does the photo picker appear?

Expanded drawer → **Add Photos**.

- ✅ The system photo picker appears (grant access if prompted).
- ❌ Nothing happens → `PHPickerViewController` cannot present from inside a Messages
  extension, and photo import moves to the paid-account tier. **Stop there** — the rest of
  the photo checks are moot.

`UIPasteControl` rendered permanently disabled in exactly this context, and `NWPathMonitor`
reported asynchronously in exactly this context. This is not a paranoid check.

---

## Phase 2 — Detail checks

Only for features whose gate passed.

### Favorites

| # | Check | Expected |
|---|---|---|
| F1 | Fresh install, open drawer | **All** tab selected, grid unchanged |
| F2 | Tap **Favorites** with none saved | *"Expand this drawer, tap Edit, then tap the star on any sticker."* — not a blank grid |
| F3 | Edit → star two stickers → Done → Favorites | Both appear, in the order you starred them |
| F4 | Edit on **All**, scroll a favorited sticker off screen and back several times | Star still filled; no unfavorited sticker shows a filled star |
| F5 | In Favorites: Edit → unstar then re-star the **first** sticker → Done | It moves to **last** |
| F6 | Re-star an already-starred sticker | Nothing moves |
| F7 | Edit → tap × on a sticker | Gone immediately; gone from **All** too; still gone after collapse + reopen |
| F8 | Delete favorites until none remain | Tab stays selected, shows the empty-state line |
| F9 | Enter Edit, drag drawer closed, reopen | Back in normal mode; tapping sends again |

F4 is the one that catches a `prepareForReuse` gap — cell reuse is invisible until you scroll.

### Animated stickers

| # | Check | Expected |
|---|---|---|
| A1 | Tap the animated sticker to send it | It animates **in the message bubble too** |
| A2 | Compare its speed to the same emoji in Discord | Roughly the same |
| A3 | Import until ~20 animated stickers are in the grid, scroll hard | No crash, no blank drawer |
| A4 | Send a static sticker, drag one onto a bubble | Behaves exactly as before |

A2 matters: **noticeably slower means the frame-delay redistribution is dropping delays**
rather than absorbing them. That's a code bug, not tuning — report it.

A3: if the extension dies, the first lever is `maxAnimatedFrames` 48 → 24. Frames cost more
than canvas size here.

Also worth watching: animated stickers are the first to ship at a **128px** canvas.
`MSSticker.h` claims a 300px floor that this project has always violated successfully at 256,
but 128 is new. If animated stickers are missing entirely while static ones import fine,
that's the cause.

### Link import

| # | Check | Expected |
|---|---|---|
| L1 | Rename the pre-filled name, tap **Add** | Appears in grid, sends on tap, findable by search |
| L2 | Copy any image link from a browser, paste | Name pre-fills from the filename |
| L3 | Paste the **same** link again | Reports already-saved; grid count unchanged |
| L4 | Same image at a **different URL** | Also already-saved — that's content-addressing, not URL matching |
| L5 | Paste plain text | *"That doesn't look like a link."* |
| L6 | Paste a link to a web page | *"That link isn't an image."* |
| L7 | Paste a link to a deleted image | *"Couldn't fetch that link."* |
| L8 | Paste valid link → **Cancel** | Nothing added, grid unchanged |
| L9 | Tap the name field on the review screen | **Keyboard must not cover it** |

L9 is the one layout risk unique to editing text inside a Messages extension.

### Photo import

| # | Check | Expected |
|---|---|---|
| P1 | Pick one photo | Review screen, name pre-filled `photo 1` |
| P2 | Pick four or five | Rows named `photo 1`…`photo 5`, **in selection order** |
| P3 | Pick the **largest** photo in your library | Extension must not die |
| P4 | Import a GIF from Photos | Arrives **animated**, not a still frame |
| P5 | Open picker, dismiss without choosing | Nothing added; status text not stuck mid-sentence |
| P6 | Reach review screen, **Cancel** | Nothing added |
| P7 | Import the **same photo twice** | Second reports already-saved |

P3 is the real memory test on this path. A 12-megapixel photo decodes to ~49 MB against a
40–120 MB kill window. If the drawer goes blank here, `ImageDownsampler` isn't being applied
to the photo path.

### 7TV

The web page isn't built yet, so here is a hand-made payload using **real, verified** 7TV
global emotes — three animated, three static. Every URL was confirmed to return HTTP 200.

Email or message this to yourself, copy it, then use **Paste Emoji** (not Paste Link — the
app recognizes the `DSTK1` header and routes it automatically):

```
DSTK1
7a 01FCY771D800007PQ2DF3GDTN6 RainTime
7a 01FE3XY508000AA32JP519W2EW PETPET
7a 01GB2TN09G000AZXHZ8HNEZX6G Clap2
7 01GAZ199Z8000FEWHS6AT5QZV0 peepoHappy
7 01GAZ4SBX80007YCE2RXBT44B2 peepoSad
7 01GGD5PJA8000FH13S498E9D8X ppL
```

| # | Check | Expected |
|---|---|---|
| S1 | Paste the payload | Summary reports **6 added** |
| S2 | The three `7a` emotes | **Animated** |
| S3 | The three `7` emotes | Static, sharp |
| S4 | Paste the same payload again | All six already-saved |
| S5 | Search `peepo` | Finds two |

**Expect `ppL` to look blurry.** Its `4x` variant is genuinely only 36×28 pixels — 7TV's
"4x" is a naming convention, not a size guarantee. Upscaling onto the 256px canvas is
`StickerImageProcessor` working as designed, not a bug.

If S2 shows stills while G2's Discord emoji animated, the problem is 7TV-specific: the
downloader is requesting `.webp` instead of `.gif` for animated emotes. That fails *silently*
— 7TV returns HTTP 200 with a valid still image rather than an error.

---

## Phase 3 — The memory test

This is check 11 from the original build, deferred because it needs volume.

Get the grid to **300+ stickers**, then scroll rapidly through the whole thing several times.

Expect no crash and no blank drawer. If the drawer goes blank or snaps shut, that's the
40–120 MB ceiling, and the lever is `StickerLimits.canvasSize` 256 → 128.

This is the check that validates choosing 256 over 512 in the first place.

---

## Recording results

Note pass/fail per row plus anything surprising. For the gates, note the answer explicitly
even if it passed — a recorded "APNG animates: yes" is what stops someone re-litigating the
format choice later.
