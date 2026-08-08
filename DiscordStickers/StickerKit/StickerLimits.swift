import Foundation

/// Hard limits imposed by `MSSticker`, plus the tuning constants derived
/// from them. Values confirmed against the CDN in Task 0.
public enum StickerLimits {
    /// `MSSticker` rejects files above 500 KB. 500,000 is the conservative
    /// decimal reading of that limit.
    public static let maxBytes = 500_000
    public static let minDimension = 100
    public static let maxDimension = 618

    /// Side length of the square canvas every sticker is rendered onto.
    ///
    /// Task 0 measured that Discord's `?size=` only downscales, and that emoji
    /// are frequently non-square and sometimes below `minDimension` (76x61 was
    /// observed). So normalization is mandatory, not cosmetic.
    ///
    /// 256 trades sharpness for headroom against the extension's 40-120 MB
    /// ceiling: ~20 visible cells cost ~5 MB decoded here versus ~20 MB at 512.
    /// Validated by Task 11's scroll test — if the extension is still killed,
    /// drop this to 128.
    public static let canvasSize = 256
    /// Used when the `canvasSize` render still exceeds `maxBytes`.
    public static let fallbackCanvasSize = 128

    public static let recentsLimit = 16
    public static let downloadConcurrency = 5
}
