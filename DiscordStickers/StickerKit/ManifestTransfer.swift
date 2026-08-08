import Foundation

/// Moves the manifest in and out as clipboard text.
///
/// A backup restores Discord-sourced stickers only. The manifest carries
/// names and ids, never image bytes, so this can only bring a sticker back
/// by re-fetching it from Discord's CDN using that id. Link and photo
/// imports have no such source: their id is a content hash of bytes that
/// existed only on this device, so they cannot be recovered by this feature
/// at all — `restore` reports them as missing without attempting a request.
///
/// For a Discord-sourced sticker, a re-paste already restores names and
/// images from the CDN, so what this genuinely rescues is `useCount`,
/// `favoritedAt`, `isAnimated`, and `source` — the pieces of data in the
/// app that cannot be re-derived from Discord. `isAnimated` in particular
/// must survive intact: the CDN returns 415 for an emoji requested with the
/// wrong extension, so losing the flag doesn't merely degrade a restored
/// sticker, it can break the request for it. `source` must survive too:
/// the downloader picks a CDN from it, so losing it sends 7TV ids to
/// Discord's CDN and reports the user's own 7TV emotes as missing.
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

    /// Re-downloads every listed entry whose id names an actual Discord
    /// emoji, then replays the saved use counts and favorites so Recents and
    /// Favorites come back correctly rather than empty. Entries whose id is
    /// content-addressed (`sha256-…`, from link and photo imports) are never
    /// sent to `downloader` — there is nothing at Discord to ask for — and
    /// are routed straight into the returned outcome's `missing` bucket
    /// instead.
    ///
    /// The use-count replay *adds* recordings on top of whatever the store
    /// already has for that id rather than reconciling to the saved value —
    /// fine for the intended case of restoring into a fresh store after a
    /// reinstall, but calling this against a store that already has activity
    /// for an id will inflate its count rather than overwrite it.
    ///
    /// The favorites replay calls `setFavorite` in ascending `favoritedAt`
    /// order. `StickerStore.setFavorite` stamps `Date()` at call time rather
    /// than preserving the original timestamp, so the *order of these calls*
    /// — not the original timestamps — is what determines the restored
    /// `favorites()` order. Sorting ascending first is what makes that order
    /// match the order the user originally built.
    public static func restore(
        _ entries: [StickerEntry],
        store: StickerStore,
        downloader: EmojiDownloader
    ) async -> DownloadOutcome {
        // Content-addressed entries cannot be re-fetched from anywhere —
        // their bytes existed only on this device — so they're partitioned
        // out before any request is made. Sending one to the downloader
        // would build `https://cdn.discordapp.com/emojis/sha256-….<ext>`,
        // a request for an object that never existed there, and report the
        // sticker back as "no longer exists" — implying Discord deleted it,
        // when in fact Discord never had it.
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
            for _ in 0..<entry.useCount { store.recordUse(id: entry.id) }
        }

        let favorited = entries
            .filter { $0.favoritedAt != nil }
            .sorted { $0.favoritedAt! < $1.favoritedAt! }
        for entry in favorited where store.contains(id: entry.id) {
            store.setFavorite(true, id: entry.id)
        }

        store.flush()

        return outcome
    }
}
