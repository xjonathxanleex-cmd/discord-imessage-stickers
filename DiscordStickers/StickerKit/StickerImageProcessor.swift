import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Renders arbitrary downloaded bytes onto a fixed square transparent canvas,
/// aspect-fit and centred.
///
/// This exists because Task 0 measured live emoji and found two things: the
/// CDN's `?size=` only downscales, and Discord does not pad emoji to a square
/// — a real animated emoji came back 76x61, under `MSSticker`'s 100px floor.
/// Feeding raw bytes to `MSSticker` would therefore drop a genuine fraction of
/// every paste.
///
/// A square canvas is used rather than a scale calculation because scaling
/// alone cannot satisfy both the 100 floor and the 618 ceiling for an extreme
/// aspect ratio — a 20:1 strip has no valid scale factor. Padding always does,
/// and it gives the grid uniform cells for free.
public enum StickerImageProcessor {

    /// Returns PNG data of exactly `canvas` x `canvas`, or `nil` if `data`
    /// is not a decodable image.
    public static func normalize(
        _ data: Data,
        canvas: Int = StickerLimits.canvasSize
    ) -> Data? {
        guard let source = UIImage(data: data), source.size.width > 0,
              source.size.height > 0
        else { return nil }

        let side = CGFloat(canvas)
        let scale = min(side / source.size.width, side / source.size.height)
        let drawnSize = CGSize(width: source.size.width * scale,
                               height: source.size.height * scale)
        let origin = CGPoint(x: (side - drawnSize.width) / 2,
                             y: (side - drawnSize.height) / 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1          // canvas is in pixels, not points
        format.opaque = false     // keep the alpha channel

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        )
        let output = renderer.image { context in
            context.cgContext.interpolationQuality = .high
            source.draw(in: CGRect(origin: origin, size: drawnSize))
        }
        return output.pngData()
    }

    /// The same canvas, encoded as a **two-frame APNG whose frames are
    /// identical** — visually a still image, structurally an animation.
    ///
    /// Device finding, 2026-08-08: iOS copies a sent sticker into the system
    /// Recents picker, but **only if the sticker is animated**. Verified by
    /// sending a static and an animated sticker back to back with the same
    /// gesture: only the animated one appeared. Verified as a copy, not a
    /// reference, by deleting it from this app afterwards and finding it still
    /// worked.
    ///
    /// So a still sticker encoded as two identical frames reaches the system
    /// picker while looking exactly as it did. That is worth more than it
    /// sounds: after one use, a sticker becomes reachable from the ordinary
    /// iMessage sticker UI without opening this extension at all — which the
    /// base spec had recorded as impossible.
    ///
    /// **APNG rather than GIF**, unlike the animated path. GIF is 256 colours
    /// with 1-bit alpha, which would band gradients and harden every
    /// antialiased edge — a real quality loss on artwork that arrives as full
    /// RGBA PNG. The animated path pays no such price because its sources are
    /// already GIF. Here the cost is roughly double the bytes, against a
    /// ceiling with about tenfold headroom for static art.
    ///
    /// Returns `nil` on the same terms as `normalize`.
    public static func normalizeAsStillAnimation(
        _ data: Data,
        canvas: Int = StickerLimits.canvasSize
    ) -> Data? {
        guard let still = normalize(data, canvas: canvas),
              let source = CGImageSourceCreateWithData(still as CFData, nil),
              let frame = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 2, nil
        ) else { return nil }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]
        ] as CFDictionary)

        // A long delay on both frames. They are identical, so the value has no
        // visual effect at all — but it decides how often MSStickerView is
        // asked to redraw a picture that never changes, across every visible
        // cell in the grid at once.
        for _ in 0..<2 {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyPNGDictionary:
                    [kCGImagePropertyAPNGDelayTime: stillFrameDelay]
            ] as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static let stillFrameDelay = 5.0
}
