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

    /// Side length of the square canvas animated stickers are rendered onto.
    ///
    /// Smaller than `canvasSize` because animated stickers pay for canvas
    /// area in **file bytes as well as memory**, once per frame. A measured
    /// Discord emoji is 76x61 with 94 frames at 157 KB; scaling that to the
    /// static 256 canvas multiplies pixel area ~14x across every frame,
    /// which is megabytes against a 500 KB ceiling.
    public static let animatedCanvasSize = 128

    /// Frames beyond this are dropped evenly, with their delays redistributed
    /// so total loop duration is unchanged. 48 keeps motion smooth to the eye
    /// while roughly halving the measured 94-frame case.
    public static let maxAnimatedFrames = 48

    public static let recentsLimit = 16
    public static let downloadConcurrency = 5

    /// Hard ceiling on either dimension of a fetched image, checked from
    /// metadata before anything is decoded. A byte cap does not bound a
    /// bitmap: flat artwork at 8000x6000 compresses under 10 MB and decodes
    /// to ~192 MB, past the window where the extension is killed.
    public static let maxSourcePixelDimension = 4096
}
