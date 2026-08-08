import Foundation
import Messages

/// Fetches emoji from their source CDN — Discord's or 7TV's, depending on
/// each `ParsedEmoji`'s `source` — validates them against `MSSticker`'s
/// limits, and hands survivors to `StickerStore`.
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

    /// Duplicate ids in the input are collapsed to the first occurrence,
    /// matching `EmojiMarkupParser`'s own dedupe policy.
    public func download(_ emoji: [ParsedEmoji]) async -> DownloadOutcome {
        // Dedupe up front: a second entry with the same id would otherwise
        // pass `store.contains` alongside the first, get fetched twice, and
        // be double-counted in the outcome even though `StickerStore.add`
        // silently no-ops the second write. Keeping the first occurrence
        // also keeps the `order` map below well-defined.
        var seenIDs: Set<String> = []
        let emoji = emoji.filter { seenIDs.insert($0.id).inserted }

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

    private enum FetchResult {
        case success(Data)
        case notFound
        case unsupportedType
        case failed
    }

    private func fetchOne(_ emoji: ParsedEmoji) async -> ItemResult {
        switch await fetch(emoji, animated: emoji.isAnimated) {
        case .notFound:
            return .missing(emoji.id)
        case .failed:
            return .unusable(emoji.id)
        case .success(let raw):
            return process(emoji, raw: raw, animated: emoji.isAnimated)
        case .unsupportedType:
            // The flag disagreed with reality. This self-heal is Discord-
            // specific: Discord's CDN returns 415 for a static emoji
            // requested as .gif, so retrying with the other extension and
            // storing whichever answer actually worked corrects a wrong
            // guess there. 7TV does not behave this way — see
            // `TransferPayloadParser`'s doc comment — so this branch is
            // simply never reached for a `.sevenTV` emoji; the tag itself
            // must already be right.
            switch await fetch(emoji, animated: !emoji.isAnimated) {
            case .success(let raw):
                return process(emoji, raw: raw, animated: !emoji.isAnimated)
            case .notFound:
                return .missing(emoji.id)
            case .failed, .unsupportedType:
                return .unusable(emoji.id)
            }
        }
    }

    /// Discord carries no `size` parameter — measured as ignored for both
    /// its formats. 7TV's `.gif` is not advertised in its own `host.files`
    /// list but is served, and is preferred over animated WebP because
    /// ImageIO's animated-WebP frame support is unverified here.
    private static func url(for emoji: ParsedEmoji, animated: Bool) -> URL? {
        switch emoji.source {
        case .pasted, .server:
            let ext = animated ? "gif" : "png"
            return URL(string:
                "https://cdn.discordapp.com/emojis/\(emoji.id).\(ext)")
        case .sevenTV:
            let file = animated ? "4x.gif" : "4x.webp"
            return URL(string:
                "https://cdn.7tv.app/emote/\(emoji.id)/\(file)")
        case .photo, .link:
            // Content-addressed: the id is a `sha256-…` hash of bytes that
            // existed only on this device, with no remote origin at all.
            // Returning nil here (rather than folding these into the
            // Discord case) makes "no such thing as a request for this
            // source" an invariant of the switch itself, so any future
            // caller — a retry button, a repair pass, a sync path — fails
            // closed instead of having to separately know to check the
            // `sha256-` prefix the way `ManifestTransfer` does today.
            return nil
        }
    }

    private func fetch(_ emoji: ParsedEmoji, animated: Bool) async -> FetchResult {
        guard let url = Self.url(for: emoji, animated: animated) else { return .failed }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200: return .success(data)
            case 404: return .notFound
            case 415: return .unsupportedType
            default:  return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Routes to the animated or static processor and applies the size
    /// fallback ladder. Frames are sacrificed before resolution: a slightly
    /// choppier animation reads as intentional, a blurry sticker reads as
    /// broken.
    private func process(_ emoji: ParsedEmoji, raw: Data, animated: Bool) -> ItemResult {
        // The flag says which URL to *request*; the bytes say what arrived.
        // Where they disagree, the bytes win — a multi-frame response routed
        // down the static path would be silently flattened to frame one, and
        // recorded as static so no later self-heal could recover it.
        //
        // Discord's CDN makes the flag mostly reliable by answering 415 for a
        // wrong-format request, which the caller retries. 7TV does not: it
        // returns 200 with a valid still image. This check is what makes the
        // rule uniform across every import path rather than per-CDN folklore.
        let animated = animated || AnimatedStickerProcessor.frameCount(of: raw) >= 2

        guard animated else {
            // Raw bytes are never trusted: Discord emoji are often non-square
            // and sometimes below MSSticker's floor (76x61 measured in Task 0).
            //
            // Encoded as a two-frame APNG so the sticker reaches the system
            // Recents picker after it is sent — iOS only copies animated
            // stickers there. See StickerImageProcessor.normalizeAsStillAnimation.
            // Falls back to a plain single-frame PNG if that ever fails or
            // does not fit, since a sticker that works is worth more than one
            // that might have shown up in a picker.
            guard let normalized = StickerImageProcessor.normalizeAsStillAnimation(raw)
                    ?? StickerImageProcessor.normalize(raw) else {
                return .unusable(emoji.id)
            }
            if normalized.count <= StickerLimits.maxBytes {
                return commit(emoji, data: normalized, animated: false)
            }
            // Re-render smaller rather than discard. A guard, not a routine
            // path — 128px source art at a 256 canvas lands far under 500 KB.
            guard let smaller = StickerImageProcessor.normalize(
                raw, canvas: StickerLimits.fallbackCanvasSize
            ), smaller.count <= StickerLimits.maxBytes else {
                return .unusable(emoji.id)
            }
            return commit(emoji, data: smaller, animated: false)
        }

        // Fewer than two frames is not animation; normalize returns nil and
        // the source is stored as an ordinary static sticker.
        let actualFrameCount = AnimatedStickerProcessor.frameCount(of: raw)
        guard actualFrameCount >= 2 else {
            return process(emoji, raw: raw, animated: false)
        }

        // Canvas is surrendered before frames: a step down in size is a
        // smaller loss than halving the frame rate, and motion is most of what
        // makes an animated emoji worth having at all.
        //
        // Measured on real 7TV emotes. Surrendering frames first (the shipped
        // order for one build) put a 75-frame emote at 256px with 32 of its
        // frames; this order puts it at 192px with all 64 — visibly smoother
        // for a size step most people will not notice. No emote measured does
        // worse under this order than the other.
        let attempts: [(canvas: Int, frames: Int)] = [
            (StickerLimits.animatedCanvasSize,      StickerLimits.maxAnimatedFrames),
            (StickerLimits.midAnimatedCanvasSize,   StickerLimits.maxAnimatedFrames),
            (StickerLimits.midAnimatedCanvasSize,   StickerLimits.reducedAnimatedFrames),
            (StickerLimits.smallAnimatedCanvasSize, StickerLimits.reducedAnimatedFrames),
            (StickerLimits.smallAnimatedCanvasSize, StickerLimits.minAnimatedFrames),
        ]

        // Skips any rung that would re-encode byte-for-byte what the previous
        // one already produced. `normalize` caps rather than resamples, so for
        // a source with fewer frames than the cap two rungs differing only in
        // frame budget are identical — and each wasted rung is a full
        // decode/render/re-encode on the memory-critical path.
        var lastAttempted: (canvas: Int, frames: Int)?

        for attempt in attempts {
            let effective = (canvas: attempt.canvas,
                             frames: min(attempt.frames, actualFrameCount))
            if let last = lastAttempted, last == effective { continue }
            lastAttempted = effective

            guard let encoded = AnimatedStickerProcessor.normalize(
                raw, canvas: attempt.canvas, maxFrames: attempt.frames,
                // GIF, not APNG. See StickerLimits.animatedCanvasSize: every
                // animated source here is already a GIF, so APNG cost 3-4x the
                // bytes to store nothing extra. MSSticker resolves format by
                // sniffing content, not by path extension — verified in
                // StickerFormatTests — so the stored filename stays `.png`
                // and no migration is needed for stickers already on disk.
                asGIF: true
            ) else { return .unusable(emoji.id) }

            if encoded.count <= StickerLimits.maxBytes {
                return commit(emoji, data: encoded, animated: true)
            }
        }
        return .unusable(emoji.id)
    }

    /// Writes to a temp file, proves the bytes are a usable `MSSticker`, then
    /// hands the file to the store. Constructing the sticker here rather than
    /// in `cellForItemAt` is what turns a scroll-time crash into a
    /// download-time skip, and is what upholds the manifest invariant.
    ///
    /// Delegates to `StickerCommitter`, the shared implementation of that
    /// invariant, so this and any other import path can't drift apart.
    private func commit(_ emoji: ParsedEmoji, data: Data, animated: Bool) -> ItemResult {
        StickerCommitter.commit(
            id: emoji.id, name: emoji.name, source: emoji.source,
            isAnimated: animated, data: data, to: store
        ) ? .added(emoji.id) : .unusable(emoji.id)
    }
}
