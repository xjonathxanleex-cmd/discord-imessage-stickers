import XCTest
import Messages
import ImageIO
import UniformTypeIdentifiers
@testable import StickerKit

/// Pins how `MSSticker` decides an image's format, because the animated
/// encoder's design depends on the answer.
///
/// The animated-sticker plan asserted that conformance is resolved from the
/// **path extension**, and concluded that switching from APNG to GIF would
/// require renaming every stored file plus the two other sites that hardcode
/// `.png` — a migration for stickers already on disk, whose bytes are still
/// APNG and would fail under a `.gif` name.
///
/// That assertion is false. `MSSticker` sniffs the content. The move to GIF
/// therefore cost one argument and no migration at all.
///
/// This test exists so that stops being folklore in either direction. If a
/// future iOS resolves format by extension after all, the GIF-bytes-in-a-
/// `.png`-file case below fails here rather than silently producing stickers
/// that will not construct on a user's phone.
final class StickerFormatTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMSStickerAcceptsGIFBytesInAFileNamedPNG() throws {
        let gif = try XCTUnwrap(Self.animatedGIF(), "fixture")

        // Control: the same bytes under the matching name must work, or a
        // failure below would say nothing about extensions.
        let matching = directory.appendingPathComponent("a.gif")
        try gif.write(to: matching)
        XCTAssertNotNil(
            try? MSSticker(contentsOfFileURL: matching, localizedDescription: "x"),
            "control: GIF bytes in a .gif file"
        )

        let mismatched = directory.appendingPathComponent("a.png")
        try gif.write(to: mismatched)
        XCTAssertNotNil(
            try? MSSticker(contentsOfFileURL: mismatched, localizedDescription: "x"),
            "GIF bytes must be accepted in a .png file — the animated encoder "
            + "writes exactly this, and a migration was skipped on the strength of it"
        )
    }

    /// The real encoder's output, not a hand-built fixture, so this exercises
    /// what actually reaches disk.
    func testProcessorOutputConstructsAnMSSticker() throws {
        let source = try XCTUnwrap(Self.animatedGIF(), "fixture")
        let encoded = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(
                source, canvas: StickerLimits.animatedCanvasSize,
                maxFrames: StickerLimits.maxAnimatedFrames, asGIF: true
            ),
            "the processor must produce animated output for a 2-frame source"
        )

        let url = directory.appendingPathComponent("real.png")
        try encoded.write(to: url)
        XCTAssertNotNil(try? MSSticker(contentsOfFileURL: url,
                                       localizedDescription: "x"))
        XCTAssertLessThanOrEqual(encoded.count, StickerLimits.maxBytes)
        XCTAssertGreaterThanOrEqual(AnimatedStickerProcessor.frameCount(of: encoded), 2,
                                    "still animated after the round trip")
    }

    // MARK: - Fixture

    private static func animatedGIF(side: Int = 128, frames: Int = 4) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, frames, nil
        ) else { return nil }

        for frame in 0..<frames {
            guard let context = CGContext(
                data: nil, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: Double(frame) / Double(frames),
                                         green: 0.2, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            guard let image = context.makeImage() else { return nil }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
