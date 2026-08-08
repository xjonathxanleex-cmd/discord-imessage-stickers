import Foundation

/// Moves the manifest in and out as clipboard text.
///
/// A backup restores stickers with a real remote origin — Discord and 7TV
/// alike, dispatched by `source` — by re-fetching each from its own CDN
/// using its id. Link and photo imports have no such origin: their id is a
/// content hash of bytes that existed only on this device, so they cannot
/// be recovered by this feature at all — `restore` reports them as missing
/// without attempting a request.
///
/// For a re-fetchable sticker, a re-paste (or a re-scan of a 7TV payload)
/// already restores names and images from the origin CDN, so what this
/// genuinely rescues is everything about it that isn't part of a
/// `ParsedEmoji`: `useCount`, `favoritedAt`, `addedAt`, `isAnimated`, and
/// `source` — the pieces of data in the app that cannot be re-derived from
/// the origin. `isAnimated` in particular must survive intact for a
/// Discord-sourced entry: the CDN returns 415 for an emoji requested with
/// the wrong extension, so losing the flag doesn't merely degrade a
/// restored sticker, it can break the request for it. `source` must
/// survive too: the downloader picks a CDN from it, so losing it sends 7TV
/// ids to Discord's CDN and reports the user's own 7TV emotes as missing.
///
/// `favoritedAt`, then `isAnimated`, then `source`, then `addedAt` — four
/// fields have now been lost on this path one at a time, each only caught
/// by a dedicated test. `StickerStore.restoreMetadata(from:)` copies the
/// whole backup record onto the freshly re-downloaded entry instead, which
/// is what stops a fifth field being lost the same way.
///
/// Text rather than a file, because text survives being pasted into a note
/// and retrieved a week later, and because file-sharing UI inside a
/// Messages extension is more friction than this feature earns.
public enum ManifestTransfer {

    /// Ids assigned by `ContentHash`, rather than Discord, to stickers with
    /// no Discord identity of their own — link and photo imports.
    private static let contentHashPrefix = "sha256-"

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func export(from store: StickerStore) -> String {
        guard let data = try? encoder.encode(store.all()),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    public static func parseImport(_ text: String) -> [StickerEntry] {
        guard let data = text.data(using: .utf8),
              let entries = try? decoder.decode([StickerEntry].self, from: data)
        else { return [] }
        return entries
    }

    /// Re-downloads every listed entry with a real remote origin, then
    /// writes each one's saved metadata back via
    /// `StickerStore.restoreMetadata(from:)` so Recents, Favorites, and
    /// "added" order all come back as they were rather than reset. Entries
    /// whose id is content-addressed (`sha256-…`, from link and photo
    /// imports) are never sent to `downloader` — there is nothing to ask
    /// any origin for — and are routed straight into the returned outcome's
    /// `missing` bucket instead.
    ///
    /// Because `restoreMetadata` copies the backup's `useCount` and
    /// `favoritedAt` directly rather than replaying them onto whatever the
    /// store already has, restoring into a store that already has activity
    /// for an id overwrites that activity with the backup's values, rather
    /// than the additive behaviour an earlier implementation had.
    public static func restore(
        _ entries: [StickerEntry],
        store: StickerStore,
        downloader: EmojiDownloader
    ) async -> DownloadOutcome {
        // Content-addressed entries cannot be re-fetched from anywhere —
        // their bytes existed only on this device — so they're partitioned
        // out before any request is made. Sending one to the downloader
        // would build a request for an object that never existed at any
        // origin, and report the sticker back as "no longer exists" —
        // implying its origin deleted it, when in fact it was never there.
        let redownloadable = entries.filter { !$0.id.hasPrefix(contentHashPrefix) }
        let unrecoverable = entries.filter { $0.id.hasPrefix(contentHashPrefix) }

        let downloaded = await downloader.download(
            redownloadable.map {
                ParsedEmoji(id: $0.id, name: $0.name,
                            isAnimated: $0.isAnimated, source: $0.source)
            }
        )

        let outcome = DownloadOutcome(
            added: downloaded.added,
            alreadyPresent: downloaded.alreadyPresent,
            missing: downloaded.missing + unrecoverable.map(\.id),
            unusable: downloaded.unusable
        )

        for entry in entries where store.contains(id: entry.id) {
            store.restoreMetadata(from: entry)
        }

        store.flush()

        return outcome
    }
}
