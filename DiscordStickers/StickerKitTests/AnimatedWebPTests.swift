import XCTest
@testable import StickerKit

/// Pins that animated WebP works end to end, using a **real Discord emoji**
/// rather than a synthesised fixture.
///
/// Discord has moved animated emoji off GIF. Measured 2026-08-09 on three
/// emoji whose own markup says `<a:`:
///
/// | URL | Result |
/// |---|---|
/// | `.gif` | 415 `Invalid resource` |
/// | `.png` | 200, a flat still |
/// | `.webp?animated=true` | 200, genuine animated WebP |
///
/// Every one of them imported permanently frozen until this was found. A
/// synthesised fixture would not have caught it and would not catch a
/// regression: the whole point is what Discord actually serves.
final class AnimatedWebPTests: XCTestCase {

    /// Located from `#filePath` for the same reason `CorpusParityTests` is —
    /// this is captured evidence, not a generated input.
    private func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/discord-animated.webp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "fixture missing at \(url.path)")
        return try Data(contentsOf: url)
    }

    func testImageIODecodesEveryFrameOfAnimatedWebP() throws {
        // The assumption the whole Discord path now rests on. The 7TV notes
        // listed animated-WebP frame support as unverified; it is not
        // optional any more.
        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: try fixture()), 8)
    }

    /// Without the WebP branch in `delay(of:at:)` every frame silently takes
    /// the 0.1s fallback, so the loop plays at a uniform 10fps whatever the
    /// source intended — an error that looks like a tuning problem rather
    /// than a missing code path.
    func testFrameDelaysComeFromTheWebPMetadataNotTheFallback() throws {
        let total = AnimatedStickerProcessor.totalDuration(of: try fixture())
        XCTAssertGreaterThan(total, 0)
        XCTAssertNotEqual(total, 0.1 * 8, accuracy: 0.0001,
                          "every frame fell back to the default delay")
    }

    func testAnimatedWebPNormalizesToAnAnimatedSticker() throws {
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(
                try fixture(),
                canvas: StickerLimits.animatedCanvasSize,
                maxFrames: StickerLimits.maxAnimatedFrames,
                asGIF: true
            ),
            "a real animated Discord emoji must survive normalization"
        )
        XCTAssertGreaterThanOrEqual(AnimatedStickerProcessor.frameCount(of: output), 2)
        XCTAssertLessThanOrEqual(output.count, StickerLimits.maxBytes)
    }

    /// Total loop duration must survive the canvas/frame normalization, or
    /// the sticker plays at the wrong speed.
    func testLoopDurationIsPreservedThroughNormalization() throws {
        let source = try fixture()
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(
                source, canvas: StickerLimits.animatedCanvasSize,
                maxFrames: StickerLimits.maxAnimatedFrames, asGIF: true))

        XCTAssertEqual(AnimatedStickerProcessor.totalDuration(of: output),
                       AnimatedStickerProcessor.totalDuration(of: source),
                       accuracy: 0.05)
    }
}
