import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Normalizes animated images onto a fixed square transparent canvas,
/// capping frame count, and re-encodes them as APNG (or GIF on request).
///
/// A sibling of `StickerImageProcessor` rather than a mode of it, because
/// animated stickers are constrained differently in kind: file size scales
/// with frame count, not just canvas area, so the static 256 canvas is
/// simply wrong for them.
public enum AnimatedStickerProcessor {

    /// The de-facto default a browser applies to a zero-delay GIF frame.
    private static let fallbackDelay = 0.1

    /// One surviving frame: its index in the source, and the delay it carries
    /// after absorbing any frames dropped after it.
    private struct KeptFrame {
        let index: Int
        let delay: Double
    }

    /// Returns animated image data of exactly `canvas` x `canvas`, or `nil`
    /// if `data` is undecodable **or contains fewer than two frames** — a
    /// single-frame image is not animated and belongs to
    /// `StickerImageProcessor`.
    public static func normalize(
        _ data: Data,
        canvas: Int = StickerLimits.animatedCanvasSize,
        maxFrames: Int = StickerLimits.maxAnimatedFrames,
        asGIF: Bool = false
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count >= 2 else { return nil }

        // Delays come from metadata, so this costs no decoded pixels. Doing
        // the whole frame plan up front is what lets the encode loop below
        // hold exactly one decoded frame at a time.
        let delays = (0..<count).map { delay(of: source, at: $0) }
        let plan = framePlan(count: count, delays: delays, maxFrames: maxFrames)
        guard plan.count >= 2 else { return nil }

        return encode(source: source, plan: plan, canvas: canvas, asGIF: asGIF)
    }

    public static func frameCount(of data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return 0 }
        return CGImageSourceGetCount(source)
    }

    public static func totalDuration(of data: Data) -> Double {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return 0 }
        return (0..<CGImageSourceGetCount(source))
            .reduce(0.0) { $0 + delay(of: source, at: $1) }
    }

    // MARK: - Frames

    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any]
        else { return fallbackDelay }

        func read(_ dictionary: CFString,
                  _ unclamped: CFString,
                  _ clamped: CFString) -> Double? {
            guard let container = properties[dictionary] as? [CFString: Any]
            else { return nil }
            let value = (container[unclamped] as? Double)
                ?? (container[clamped] as? Double)
                ?? 0
            return value > 0 ? value : nil
        }

        return read(kCGImagePropertyGIFDictionary,
                    kCGImagePropertyGIFUnclampedDelayTime,
                    kCGImagePropertyGIFDelayTime)
            ?? read(kCGImagePropertyPNGDictionary,
                    kCGImagePropertyAPNGUnclampedDelayTime,
                    kCGImagePropertyAPNGDelayTime)
            // WebP is the format Discord now serves animated emoji in, so
            // omitting it here would not merely lose timing — every frame
            // would silently take `fallbackDelay`, playing the loop at a
            // uniform 10fps regardless of what the source intended. Verified
            // present on real Discord emoji: the WebP dictionary carries both
            // `DelayTime` and `UnclampedDelayTime`.
            ?? read(kCGImagePropertyWebPDictionary,
                    kCGImagePropertyWebPUnclampedDelayTime,
                    kCGImagePropertyWebPDelayTime)
            ?? fallbackDelay
    }

    /// Samples `maxFrames` indices evenly and folds each dropped frame's delay
    /// into the surviving frame that precedes it.
    ///
    /// The delay accumulation is the part that matters. Dropping every other
    /// frame while keeping the survivors' own delays plays the loop at half
    /// speed — still smooth, silently wrong, and invisible to any assertion
    /// about frame count or file size.
    private static func framePlan(
        count: Int, delays: [Double], maxFrames: Int
    ) -> [KeptFrame] {
        guard maxFrames > 0, count > maxFrames else {
            return (0..<count).map { KeptFrame(index: $0, delay: delays[$0]) }
        }

        let kept = (0..<maxFrames).map { step in
            Int(Double(step) * Double(count) / Double(maxFrames))
        }

        return kept.enumerated().map { position, start in
            let end = position + 1 < kept.count ? kept[position + 1] : count
            return KeptFrame(index: start,
                             delay: delays[start..<end].reduce(0, +))
        }
    }

    // MARK: - Rendering

    /// Aspect-fit and centre one frame onto the square canvas. Uses
    /// `CGContext` directly rather than `UIGraphicsImageRenderer` so no
    /// `UIImage` round-trip is needed and the alpha channel is explicit.
    private static func render(_ image: CGImage, canvas: Int) -> CGImage? {
        let side = CGFloat(canvas)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }

        let scale = min(side / width, side / height)
        let drawn = CGSize(width: width * scale, height: height * scale)
        let origin = CGPoint(x: (side - drawn.width) / 2,
                             y: (side - drawn.height) / 2)

        guard let context = CGContext(
            data: nil, width: canvas, height: canvas,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: origin, size: drawn))
        return context.makeImage()
    }

    /// Decodes, renders, appends and releases one frame per iteration, so
    /// peak decoded pixels is a single frame rather than the whole animation.
    private static func encode(
        source: CGImageSource,
        plan: [KeptFrame],
        canvas: Int,
        asGIF: Bool
    ) -> Data? {
        let output = NSMutableData()
        let type = (asGIF ? UTType.gif : UTType.png).identifier as CFString

        guard let destination = CGImageDestinationCreateWithData(
            output, type, plan.count, nil
        ) else { return nil }

        CGImageDestinationSetProperties(destination, (asGIF
            ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
        ) as CFDictionary)

        for frame in plan {
            // Decoded through the thumbnail path, sized to the canvas it is
            // about to be rendered onto, rather than
            // `CGImageSourceCreateImageAtIndex`'s plain full-resolution
            // decode — a 4K animated source would otherwise cost 33 MB per
            // frame. Decoding at the canvas size rather than the source's
            // native size is what bounds per-frame memory; `render` still
            // runs afterwards because the thumbnail preserves aspect ratio
            // rather than squaring the frame to `canvas` x `canvas`.
            let decodeOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: canvas,
            ]
            guard
                let decoded = CGImageSourceCreateThumbnailAtIndex(
                    source, frame.index, decodeOptions as CFDictionary
                ),
                let rendered = render(decoded, canvas: canvas)
            else { return nil }

            CGImageDestinationAddImage(destination, rendered, (asGIF
                ? [kCGImagePropertyGIFDictionary:
                    [kCGImagePropertyGIFDelayTime: frame.delay]]
                : [kCGImagePropertyPNGDictionary:
                    [kCGImagePropertyAPNGDelayTime: frame.delay]]
            ) as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
