import UIKit

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
}
