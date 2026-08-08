# Favorites & Delete — Design Spec

**Date:** 2026-08-07
**Status:** Design approved. Ready for implementation planning.
**Builds on:** `2026-08-07-discord-imessage-stickers-design.md`

---

## 1. Goal

Let the user curate a short, stable list of stickers they reach for often, and remove stickers they no longer want.

These ship together because they share one mechanism: an edit mode that suspends sending so taps can mean something else.

### Why this is needed now

Device testing established that **stickers created at runtime never reach iOS's own sticker drawer** (base spec §2 constraint 7). The extension's drawer is the only surface these stickers will ever have — the system will never provide a recents list, a search, or a favorites shelf over them. Every affordance for finding a sticker has to exist inside this app.

Delete has a second driver: with no way to remove anything, a grid accumulates permanently. `StickerStore.delete(id:)` already exists and is tested; nothing calls it.

### Non-goals

- Manual drag-to-reorder within Favorites. See §5.
- Folders, groups, or nested organization. Automatic organization remains the design (base spec §4).
- Bulk selection or multi-delete.
- Undo. See §8.
- Any change to how stickers are imported.

---

## 2. Relationship to Recents

Favorites and Recents overlap — a sticker used constantly already sits at the front of Recents. Favorites earns its place by doing two things Recents cannot:

1. **Staying still.** Recents reorders continuously by `useCount`, so nothing there holds a position. Favorites never moves (§5).
2. **Holding the unused.** A sticker can be a favorite before it has ever been sent.

Both remain. Recents keeps curating itself; Favorites is curated deliberately.

---

## 3. Data model

Add exactly one property to `StickerEntry`:

```swift
public var favoritedAt: Date?    // nil = not a favorite
```

**One optional, not a `Bool` plus a `Date`.** A separate `isFavorite: Bool` alongside a timestamp permits two states that contradict each other — favorited with no date, dated but not favorited — and every read would have to decide which wins. A single optional makes membership and ordering the same fact.

**Migration is free.** Swift's synthesized `Codable` uses `decodeIfPresent` for optional properties, so every `manifest.json` written before this change decodes with `favoritedAt == nil`. No migration code, no schema version, no risk to existing stickers. §9 pins this with a test.

---

## 4. `StickerStore` API

Two additions. Both follow the existing serial-queue confinement and debounced-write behaviour exactly — `setFavorite` schedules a manifest write the same way `recordUse` does.

```swift
public func favorites() -> [StickerEntry]
public func setFavorite(_ favorite: Bool, id: String)
```

- `favorites()` returns entries where `favoritedAt != nil`, sorted ascending by `favoritedAt` (§5). Unknown ids are ignored.
- `setFavorite(true, id:)` on an already-favorited sticker is a **no-op** — it must not overwrite the original timestamp, or the entry would jump to the end of the list. `setFavorite(false, id:)` sets `favoritedAt` to nil.
- `delete(id:)` is unchanged and needs no favorite-specific handling: removing the entry removes it from every view, including Favorites.

---

## 5. Ordering: oldest favorite first, forever

Favorites append to the end and never move.

This is the feature's whole justification. Recents reorders constantly, so nothing in it has a stable position and finding a sticker there always requires looking. A fixed order means the third sticker is always the third sticker — muscle memory instead of search. Two lists that both shuffle would be one list too many.

**Manual reorder is deliberately deferred.** It needs drag-and-drop in a collection view plus a persisted order index, which is more machinery than the feature currently justifies. Append-order is a strict subset of it, so adding reorder later is additive rather than a rewrite.

---

## 6. Tabs

The segmented control becomes three: **`Favorites` · `Recent` · `All`**.

This supersedes the base spec §4 tab list (`Recent` · `All`, with `Pasted` hidden until a second source exists). The `Pasted` and `<Server>` tabs remain deferred on the same terms.

`StickerFilter` gains a `.favorites` case alongside `.recents`, `.all`, and `.search(String)`.

**Default tab** is `Favorites` when it is non-empty, and `All` otherwise. A first-run user sees exactly what they see today.

**Empty state:** when Favorites is selected and empty, the grid shows a single line rather than a blank area. The wording must not assume the drawer is expanded, since Edit is unreachable from compact mode, and it must not instruct an action that is impossible from this screen: with Favorites empty, there is no sticker on this tab to star, so the missing step — switch to another tab first — has to be named. (An earlier version of this wording, *"Expand this drawer, tap Edit, then tap the star on any sticker,"* omitted that step and described an action impossible from the screen showing it.) Current wording: *"No favorites yet. Open the All tab, tap Edit, then tap the star on any sticker."*

This is the only empty state in the app; `All` being empty on first run is already covered by the paste flow's own messaging.

---

## 7. Edit mode

An **Edit** button, shown in expanded mode only. Editing is not something done mid-conversation, and the compact drawer has no room for it.

While editing, on every cell:

- a **star** (top-right) toggling favorite — filled when favorited, outline when not
- an **×** (top-left) deleting the sticker
- `MSStickerView.isUserInteractionEnabled = false`, and a transparent overlay receives the taps

**Sending and dragging are fully off while editing.** This is the design's load-bearing decision. `MSStickerView` owns tap and long-press-drag and exposes no callbacks — the existing Recents tap counter only works because it recognizes *simultaneously* rather than instead. Competing for those gestures a second time would be fragile in a way only a device could reveal. Edit mode sidesteps the contest: for its duration, `MSStickerView` is not in the gesture conversation at all.

Edit mode applies to **all three tabs**, so a sticker can be deleted from `Recent` or `All` without hunting for it elsewhere.

Leaving expanded mode exits edit mode, so the drawer can never be left in a state where taps do not send.

---

## 8. Error handling

Consistent with the base spec's principle that failures are data, not exceptions.

| Condition | Behaviour |
|---|---|
| Favoriting an already-favorited sticker | No-op. The original timestamp is preserved so position does not change. |
| Unfavoriting something not favorited | No-op. |
| Favoriting or deleting an id no longer in the store | Ignored silently. Cannot occur through the UI, which only offers actions on visible cells. |
| Deleting the last favorite | Favorites empties and shows its empty state. If the user is on the Favorites tab, they stay there. |
| Extension killed between an edit and the debounced write | Same exposure as `recordUse` today, bounded by the same ~300 ms window. `didResignActive` still flushes. |

**No undo.** Deletion removes one sticker that a re-paste restores in seconds, and the base spec already treats idempotent re-paste as the universal recovery path (base spec §6). An undo stack would be more machinery than the loss justifies. Deletion is not confirmed either, for the same reason — a confirmation dialog on a cheap, reversible action is friction without protection.

---

## 9. Testing

Automated, against a temp directory, following the existing `StickerStoreTests` pattern:

- Favoriting round-trips and survives a store reload.
- Unfavoriting clears the flag and survives a reload.
- `favorites()` returns oldest-favorited first, not insertion or `useCount` order.
- Re-favoriting an already-favorited sticker does **not** move it — the ordering-stability guarantee of §5.
- `favorites()` on a store with no favorites returns empty, not nil or a crash.
- Deleting a favorited sticker removes it from `favorites()`, `all()`, and disk.
- **A manifest written without the `favoritedAt` key still loads**, with every entry unfavorited. This is the test that protects existing data on the user's phone.

Manual device checks, appended to the existing checklist:

- Edit mode disables sending — tapping a sticker while editing must not insert it into the conversation.
- Leaving expanded mode exits edit mode.
- The star reflects state correctly after scrolling a favorited sticker off screen and back, which exercises cell reuse.

---

## 10. Deferred

- **Manual reorder** within Favorites (§5).
- **A favorites cap.** No limit is imposed. If a user favorites hundreds, the tab degrades into a second `All` — their choice, and no code is needed to permit it.
- **Bulk edit** — select several, act once.
- **Undo** (§8).
