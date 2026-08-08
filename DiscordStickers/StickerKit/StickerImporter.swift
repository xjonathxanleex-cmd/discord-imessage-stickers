import Foundation

/// Turns accepted drafts into stored stickers.
///
/// The local counterpart to `EmojiDownloader`: no network, but the same
/// normalize → validate → commit path, and the same contract that failures
/// are data rather than exceptions so a partial batch is never lost.
public enum StickerImporter {

    public static func importDrafts(
        _ drafts: [StickerDraft],
        into store: StickerStore
    ) -> DownloadOutcome {
        var added: [String] = []
        var alreadyPresent: [String] = []
        var unusable: [String] = []

        for draft in drafts {
            guard let normalized = normalize(draft) else {
                unusable.append(draft.name)
                continue
            }

            // Hash the normalized bytes, not the source: two files that
            // render identically onto the canvas are one sticker.
            let id = ContentHash.id(for: normalized)

            if store.contains(id: id) {
                alreadyPresent.append(id)
                continue
            }

            let stored = StickerCommitter.commit(
                id: id, name: draft.name, source: draft.origin,
                isAnimated: draft.isAnimated, data: normalized, to: store
            )
            stored ? added.append(id) : unusable.append(draft.name)
        }

        store.flush()

        return DownloadOutcome(added: added, alreadyPresent: alreadyPresent,
                               missing: [], unusable: unusable)
    }

    /// Animated drafts whose bytes turn out to hold fewer than two frames
    /// fall back to the static path — a single-frame GIF is not animation
    /// and must not become an unexplained failure.
    private static func normalize(_ draft: StickerDraft) -> Data? {
        if draft.isAnimated,
           AnimatedStickerProcessor.frameCount(of: draft.imageData) >= 2,
           let animated = AnimatedStickerProcessor.normalize(draft.imageData) {
            return animated
        }
        return StickerImageProcessor.normalize(draft.imageData)
    }
}
