import UIKit
import ImageIO

/// Reads image dimensions from metadata and decodes images directly at a
/// reduced size.
///
/// This is what makes a byte cap actually bound memory. A byte cap does not
/// bound a bitmap: flat artwork at 8000x6000 compresses to under 10 MB and
/// decodes to roughly 192 MB, and an ordinary 12-megapixel iPhone photo
/// decodes to about 49 MB — against an extension that is killed somewhere
/// between 40 and 120 MB.
///
/// Extracted from `DraftFetcher` so link import and photo import share one
/// implementation rather than growing two that drift.
public enum ImageDownsampler {

    /// Dimensions from the file header. Parses metadata only — no pixels are
    /// decoded, so this is safe to call on bytes of unknown size.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Decodes straight to the target size via ImageIO's thumbnail path, so
    /// the full-resolution bitmap is never materialized.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` combined with a max
    /// pixel size never enlarges an image that is already smaller than the
    /// limit, so a small source comes back at its own size.
    public static func downsampled(_ data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }

        return UIImage(cgImage: thumbnail).pngData()
    }
}
