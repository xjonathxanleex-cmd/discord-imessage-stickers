import Foundation

/// Turns image data picked from the photo library into drafts.
///
/// The counterpart to `DraftFetcher` for local images: no network, and one
/// genuine advantage over the link path — the bytes are in hand, so whether
/// an image is animated is **detected** rather than guessed from a URL's
/// file extension.
public enum PhotoDraftLoader {

    /// One draft per decodable input, in order. Undecodable inputs are
    /// dropped and the numbering stays contiguous, so a user who picked five
    /// photos and had one fail sees `photo 1`…`photo 4` rather than a gap.
    public static func drafts(from images: [Data]) -> [StickerDraft] {
        var drafts: [StickerDraft] = []

        for data in images {
            guard ImageDownsampler.pixelSize(of: data) != nil else { continue }

            let isAnimated = AnimatedStickerProcessor.frameCount(of: data) >= 2

            // Downsampling reads frame 0 only, so applying it to an animated
            // image would silently flatten it. Animated sources pass through
            // untouched; AnimatedStickerProcessor streams one frame at a time
            // and bounds its own memory.
            let payload = isAnimated
                ? data
                : (ImageDownsampler.downsampled(
                    data, maxPixel: StickerLimits.maxDimension
                ) ?? data)

            drafts.append(StickerDraft(
                name: "photo \(drafts.count + 1)",
                imageData: payload,
                origin: .photo,
                isAnimated: isAnimated
            ))
        }

        return drafts
    }
}
