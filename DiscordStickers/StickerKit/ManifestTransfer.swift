import Foundation

/// Moves the manifest in and out as clipboard text.
///
/// A re-paste already restores names and images from the CDN, so the only
/// thing this genuinely rescues is `useCount` — which is the one piece of
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

    /// Re-downloads every listed emoji, then replays the saved use counts so
    /// Recents comes back correctly ordered rather than empty.
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
        store.flush()

        return outcome
    }
}
