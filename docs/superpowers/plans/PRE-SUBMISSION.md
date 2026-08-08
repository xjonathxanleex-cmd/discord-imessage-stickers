# Pre-submission checklist

Things that are fine on a free Personal Team but must be settled before this
goes to the App Store. Written 2026-08-08; nothing here is urgent while the
7-day provisioning cycle is still the reality.

---

## 1. Backup exclusion — likely rejection risk

**Now:** every sticker image lives in `Documents` with nothing marked
`isExcludedFromBackupKey`. At 300 stickers of up to 500 KB, that is ~150 MB of
each user's iCloud quota.

Apple's [iOS Data Storage Guidelines][1] say re-downloadable content does not
belong in `Documents` unmarked, and apps have been rejected for it.

**Why it is not a one-line fix.** The images are not uniformly re-downloadable:

| Source | Re-fetchable? | Should be backed up? |
|---|---|---|
| `.pasted`, `.server` (Discord CDN) | yes, by id | no — exclude |
| `.sevenTV` | yes, by id | no — exclude |
| `.photo` | **no** | **yes** |
| `.link` | no — the URL is not retained | **yes** |

A photo import's id is a content hash of bytes that existed only on that
device. Excluding the whole directory would silently destroy exactly the
stickers a user cannot recover.

**The fix:** set the exclusion flag per file at commit time, keyed on
`StickerEntry.source` — the same distinction `ManifestTransfer` already reasons
about. `manifest.json` itself stays backed up regardless; it is small and
carries `favoritedAt` / `useCount` / `addedAt`, none of which is re-derivable.

**Test it with:** a `StickerSource`-driven test over `allCases`, so a sixth
source cannot ship without answering the question. `StickerCommitter` is the
single place that writes sticker files, so there is one site to change.

## 2. iCloud sync, and what happens to Back Up / Restore

**Now:** Back Up / Restore exists because free provisioning expires every 7
days. That reason disappears on the App Store.

What iOS covers without it:

| Scenario | Survives? |
|---|---|
| New iPhone, restored from backup | yes |
| App Store update | yes |
| Offload App | yes |
| **Delete the app and reinstall** | **no** |

So one real gap remains. `NSUbiquitousKeyValueStore` (1 MB limit — enough for a
manifest, not for images) or CloudKit closes it properly and syncs iPhone↔iPad
for free.

**Recommendation:** keep the Back Up code either way — it is small and tested.
Demote the two buttons out of the main drawer row once iCloud sync exists; the
drawer is cramped and they stop being something anyone needs to find.

**Note the interaction with §1:** if images are excluded from backup, then after
a device restore a Discord-sourced sticker needs re-downloading. Whatever
performs that re-download is the same machinery `ManifestTransfer.restore`
already implements.

## 3. Free-tier features to reinstate

Blocked only by the $99 account, already designed:

- **Share Extension** — import an image from any app's share sheet
- **Background removal** (`VNGenerateForegroundInstanceMaskRequest`)
- **Mac app + iCloud** — see §2

## 4. Things to re-verify on a paid provisioning profile

The free tier's 7-day cycle has masked anything that only breaks over longer
periods:

- A manifest that has accumulated for months, not days
- The memory ceiling with a genuinely large collection, built up through real
  use rather than a test import
- Whether `MSSticker` construction stays fast with 500+ files in one directory

## 5. Review-facing questions worth having an answer to

- **What the app does with copyrighted emoji.** It stores nothing on a server,
  hosts nothing, and redistributes nothing: every image is fetched by the user's
  own device, from the origin CDN, using an id the user supplied. The app is a
  client, not a host. Worth stating plainly in review notes rather than leaving
  a reviewer to guess.
- **Why it reads the clipboard.** Only on an explicit button tap, never
  automatically.

[1]: https://developer.apple.com/icloud/documentation/data-storage/
