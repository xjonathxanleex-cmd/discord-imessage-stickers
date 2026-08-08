import Foundation

/// Turns image data picked from the photo library into drafts.
///
/// The counterpart to `DraftFetcher` for local images: no network, and one
/// genuine advantage over the link path — the bytes are in hand, so whether
/// an image is animated is **detected** rather than guessed from a URL's
/// file extension.
public enum PhotoDraftLoader {

    /// Turns one picked image into a draft, or `nil` if it is unusable.
    ///
    /// The name is a placeholder; `drafts(from:)` renumbers afterwards so a
    /// failed item leaves no gap in the sequence.
    ///
    /// Bounds are enforced in the same order `DraftFetcher` applies them to
    /// a fetched link, because a picked photo is exactly as untrusted as a
    /// downloaded one: a byte cap first (cheap, and rules out anything
    /// absurd before touching ImageIO), then dimensions from metadata alone
    /// (a byte cap does not bound a bitmap — flat artwork compresses tiny
    /// regardless of pixel count), and only then is anything decoded.
    public static func draft(from data: Data) -> StickerDraft? {
        guard data.count <= StickerLimits.maxSourceBytes else { return nil }

        guard let dimensions = ImageDownsampler.pixelSize(of: data) else { return nil }
        guard dimensions.width <= StickerLimits.maxSourcePixelDimension,
              dimensions.height <= StickerLimits.maxSourcePixelDimension
        else { return nil }

        let isAnimated = AnimatedStickerProcessor.frameCount(of: data) >= 2

        let payload: Data
        if isAnimated {
            // Downsampling reads frame 0 only, so applying it to an animated
            // image would silently flatten it. Animated sources pass
            // through untouched; AnimatedStickerProcessor streams one frame
            // at a time and bounds its own memory, and is now safely
            // bounded by the byte and dimension checks above too.
            payload = data
        } else {
            // Unconditional, unlike `DraftFetcher`, which only downsamples
            // above `maxDimension` — deliberately: doing it unconditionally
            // buys EXIF-orientation correction via
            // `kCGImageSourceCreateThumbnailWithTransform`, which matters
            // for camera photos and not for CDN emoji.
            //
            // No fallback to the full-resolution original on failure: that
            // full-resolution decode is exactly the 192 MB memory spike this
            // feature exists to prevent, so a failed downsample must reject
            // the photo rather than smuggle the original through.
            guard let downsampled = ImageDownsampler.downsampled(
                data, maxPixel: StickerLimits.maxDimension
            ) else { return nil }
            payload = downsampled
        }

        return StickerDraft(
            name: "photo",
            imageData: payload,
            origin: .photo,
            isAnimated: isAnimated
        )
    }

    /// One draft per decodable input, in order. Undecodable inputs are
    /// dropped and the numbering stays contiguous, so a user who picked five
    /// photos and had one fail sees `photo 1`…`photo 4` rather than a gap.
    public static func drafts(from images: [Data]) -> [StickerDraft] {
        images.compactMap(draft(from:)).enumerated().map { index, draft in
            var renamed = draft
            renamed.name = "photo \(index + 1)"
            return renamed
        }
    }
}
