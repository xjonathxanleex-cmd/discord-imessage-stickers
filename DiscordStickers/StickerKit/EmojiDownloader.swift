import Foundation
import Messages

/// Fetches emoji from Discord's public CDN, validates them against
/// `MSSticker`'s limits, and hands survivors to `StickerStore`.
///
/// Nothing here throws to the caller: every failure is recorded in the
/// returned `DownloadOutcome`, because a partial batch is the expected case
/// rather than an exceptional one.
///
/// `Sendable` holds without qualification: both stored properties are
/// immutable, `URLSession` is `Sendable`, and `StickerStore` vouches for
/// itself through queue confinement.
public final class EmojiDownloader: Sendable {

    private let store: StickerStore
    private let session: URLSession

    public init(store: StickerStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    private enum ItemResult {
        case added(String)
        case alreadyPresent(String)
        case missing(String)
        case unusable(String)
    }

    public func download(_ emoji: [ParsedEmoji]) async -> DownloadOutcome {
        // The diff. Doing it up front is what makes re-pasting an
        // overlapping batch free rather than redundant network work.
        var results: [ItemResult] = []
        var toFetch: [ParsedEmoji] = []
        for item in emoji {
            if store.contains(id: item.id) {
                results.append(.alreadyPresent(item.id))
            } else {
                toFetch.append(item)
            }
        }

        let fetched = await withTaskGroup(
            of: ItemResult.self, returning: [ItemResult].self
        ) { group in
            var index = 0
            var collected: [ItemResult] = []

            // Cap concurrency: prime the group, then add one task per
            // completion. The extension's memory ceiling makes an unbounded
            // fan-out genuinely dangerous.
            while index < min(StickerLimits.downloadConcurrency, toFetch.count) {
                let item = toFetch[index]
                group.addTask { await self.fetchOne(item) }
                index += 1
            }
            while let result = await group.next() {
                collected.append(result)
                if index < toFetch.count {
                    let item = toFetch[index]
                    group.addTask { await self.fetchOne(item) }
                    index += 1
                }
            }
            return collected
        }

        results.append(contentsOf: fetched)
        store.flush()

        // Preserve the caller's ordering so the summary reads predictably.
        let order = Dictionary(uniqueKeysWithValues: emoji.enumerated().map { ($1.id, $0) })
        func ids(_ predicate: (ItemResult) -> String?) -> [String] {
            results.compactMap(predicate).sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
        }

        return DownloadOutcome(
            added: ids { if case .added(let id) = $0 { return id } else { return nil } },
            alreadyPresent: ids { if case .alreadyPresent(let id) = $0 { return id } else { return nil } },
            missing: ids { if case .missing(let id) = $0 { return id } else { return nil } },
            unusable: ids { if case .unusable(let id) = $0 { return id } else { return nil } }
        )
    }

    private func fetchOne(_ emoji: ParsedEmoji) async -> ItemResult {
        switch await fetch(id: emoji.id) {
        case .notFound:
            return .missing(emoji.id)
        case .failed:
            return .unusable(emoji.id)
        case .success(let raw):
            // Raw bytes are never trusted: Discord emoji are often non-square
            // and sometimes below MSSticker's floor (76x61 measured in Task 0).
            guard let normalized = StickerImageProcessor.normalize(raw) else {
                return .unusable(emoji.id)
            }
            if normalized.count <= StickerLimits.maxBytes {
                return commit(emoji, data: normalized)
            }
            // Re-render smaller rather than discard. A guard, not a routine
            // path — 128px source art at a 256 canvas lands far under 500 KB.
            guard let smaller = StickerImageProcessor.normalize(
                raw, canvas: StickerLimits.fallbackCanvasSize
            ), smaller.count <= StickerLimits.maxBytes else {
                return .unusable(emoji.id)
            }
            return commit(emoji, data: smaller)
        }
    }

    private enum FetchResult {
        case success(Data)
        case notFound
        case failed
    }

    /// No `size` parameter: Task 0 measured that it only downscales, so
    /// requesting one either changes nothing or makes the source worse.
    private func fetch(id: String) async -> FetchResult {
        guard let url = URL(
            string: "https://cdn.discordapp.com/emojis/\(id).png"
        ) else { return .failed }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200: return .success(data)
            case 404: return .notFound
            default: return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Writes to a temp file, proves the bytes are a usable `MSSticker`, then
    /// hands the file to the store. Constructing the sticker here rather than
    /// in `cellForItemAt` is what turns a scroll-time crash into a
    /// download-time skip, and is what upholds the manifest invariant.
    private func commit(_ emoji: ParsedEmoji, data: Data) -> ItemResult {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(emoji.id)-\(UUID().uuidString).png")

        do {
            try data.write(to: tempURL)

            // Dimensions are guaranteed by the square canvas, so this is a
            // cheap assertion rather than a real gate. Constructing the
            // MSSticker below is the decisive check.
            _ = try MSSticker(contentsOfFileURL: tempURL,
                              localizedDescription: emoji.name)

            try store.add(
                StickerEntry(id: emoji.id, name: emoji.name, source: .pasted,
                             addedAt: Date(), useCount: 0),
                movingFileFrom: tempURL
            )
            return .added(emoji.id)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return .unusable(emoji.id)
        }
    }
}
