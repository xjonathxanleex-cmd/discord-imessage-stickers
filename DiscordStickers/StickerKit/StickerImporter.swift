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

        for (index, draft) in drafts.enumerated() {
            // Every other array in `DownloadOutcome` holds sticker ids, and
            // `unusable` must too. When normalization fails outright there
            // are no normalized bytes to hash, so a placeholder that still
            // reads as an id — rather than the user-chosen name — stands in.
            guard let normalized = normalize(draft) else {
                unusable.append("sha256-unknown-\(index)")
                continue
            }

            // Hash the normalized bytes, not the source: two files that
            // render identically onto the canvas are one sticker.
            let id = ContentHash.id(for: normalized.data)

            if store.contains(id: id) {
                alreadyPresent.append(id)
                continue
            }

            let stored = StickerCommitter.commit(
                id: id, name: draft.name, source: draft.origin,
                isAnimated: normalized.isAnimated, data: normalized.data, to: store
            )
            stored ? added.append(id) : unusable.append(id)
        }

        store.flush()

        return DownloadOutcome(added: added, alreadyPresent: alreadyPresent,
                               missing: [], unusable: unusable)
    }

    /// Normalizes a draft and reports what the stored file actually turned
    /// out to be, rather than trusting `draft.isAnimated` — for link drafts
    /// that flag comes from the source URL's file extension, a guess about
    /// content, not a fact about it. (Photo drafts detect it from the bytes
    /// instead, via `PhotoDraftLoader`, but the re-check below is cheap and
    /// applies uniformly regardless of origin.) The animated path can fall
    /// through to a static result
    /// two ways: fewer than two frames (a single-frame GIF is not
    /// animation), or `AnimatedStickerProcessor.normalize` failing outright.
    /// Either way, what gets stored is static, so `isAnimated` reported here
    /// must be too — otherwise the manifest claims animation for a file that
    /// isn't, and a later restore requests the wrong extension for it.
    ///
    /// Applies the same size-fallback ladder `EmojiDownloader` applies: a
    /// render over `StickerLimits.maxBytes` is re-rendered once at a smaller
    /// canvas (and, for animated, fewer frames) before being treated as
    /// unusable — `StickerImporter` has no other route to that guard, and
    /// without it a too-large render reaches `StickerCommitter` only to be
    /// silently lost when `MSSticker.init` throws.
    private static func normalize(
        _ draft: StickerDraft
    ) -> (data: Data, isAnimated: Bool)? {
        if draft.isAnimated,
           AnimatedStickerProcessor.frameCount(of: draft.imageData) >= 2 {
            guard let animated = AnimatedStickerProcessor.normalize(draft.imageData)
            else { return nil }

            if animated.count <= StickerLimits.maxBytes {
                return (animated, true)
            }
            guard let smaller = AnimatedStickerProcessor.normalize(
                draft.imageData,
                canvas: StickerLimits.animatedCanvasSize,
                maxFrames: StickerLimits.maxAnimatedFrames / 2
            ), smaller.count <= StickerLimits.maxBytes else {
                return nil
            }
            return (smaller, true)
        }

        guard let normalized = StickerImageProcessor.normalize(draft.imageData)
        else { return nil }

        if normalized.count <= StickerLimits.maxBytes {
            return (normalized, false)
        }
        guard let smaller = StickerImageProcessor.normalize(
            draft.imageData, canvas: StickerLimits.fallbackCanvasSize
        ), smaller.count <= StickerLimits.maxBytes else {
            return nil
        }
        return (smaller, false)
    }
}
