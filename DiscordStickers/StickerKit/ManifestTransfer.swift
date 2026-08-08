import Foundation

/// Moves the manifest in and out as clipboard text.
///
/// A re-paste already restores names and images from the CDN, so what this
/// genuinely rescues is `useCount` and `favoritedAt` — the two pieces of
/// data in the app that cannot be re-derived from Discord. Text rather than a
/// file, because text survives being pasted into a note and retrieved a week
/// later, and because file-sharing UI inside a Messages extension is more
/// friction than this feature earns.
public enum ManifestTransfer {

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

    /// Re-downloads every listed emoji, then replays the saved use counts and
    /// favorites so Recents and Favorites come back correctly rather than
    /// empty.
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
        let outcome = await downloader.download(
            entries.map {
                ParsedEmoji(id: $0.id, name: $0.name, isAnimated: false)
            }
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
