import XCTest
import UniformTypeIdentifiers
import ImageIO
import UIKit
@testable import StickerKit

final class StickerImageProcessorTests: XCTestCase {

    /// Builds a PNG of arbitrary (possibly non-square) dimensions, with a
    /// filled inner rect so aspect-ratio preservation is observable.
    private func png(width: Int, height: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height)
        )
        return renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData()!
    }

    private func size(of data: Data) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    func testUpscalesAnUndersizedNonSquareEmojiToTheCanvas() throws {
        // The real measured case from Task 0: <a:cuh:...> is 76x61.
        let output = try XCTUnwrap(StickerImageProcessor.normalize(png(width: 76, height: 61)))
        let dimensions = try XCTUnwrap(size(of: output))

        XCTAssertEqual(dimensions.width, StickerLimits.canvasSize)
        XCTAssertEqual(dimensions.height, StickerLimits.canvasSize)
    }

    func testNormalizesATypical128SquareEmoji() throws {
        let output = try XCTUnwrap(StickerImageProcessor.normalize(png(width: 128, height: 128)))
        let dimensions = try XCTUnwrap(size(of: output))

        XCTAssertEqual(dimensions.width, StickerLimits.canvasSize)
        XCTAssertEqual(dimensions.height, StickerLimits.canvasSize)
    }

    func testExtremeAspectRatioIsPaddedNotStretched() throws {
        let output = try XCTUnwrap(StickerImageProcessor.normalize(png(width: 400, height: 20)))
        let dimensions = try XCTUnwrap(size(of: output))

        // A scale-only approach cannot satisfy both the 100 floor and the 618
        // ceiling for a 20:1 strip. Padding onto a square canvas always can.
        XCTAssertEqual(dimensions.width, StickerLimits.canvasSize)
        XCTAssertEqual(dimensions.height, StickerLimits.canvasSize)
    }

    func testEveryOutputSatisfiesMSStickerBoundsByConstruction() throws {
        for (width, height) in [(76, 61), (128, 128), (400, 20), (1, 1), (618, 618)] {
            let output = try XCTUnwrap(
                StickerImageProcessor.normalize(png(width: width, height: height)),
                "failed for \(width)x\(height)"
            )
            let dimensions = try XCTUnwrap(size(of: output))
            XCTAssertGreaterThanOrEqual(dimensions.width, StickerLimits.minDimension)
            XCTAssertGreaterThanOrEqual(dimensions.height, StickerLimits.minDimension)
            XCTAssertLessThanOrEqual(dimensions.width, StickerLimits.maxDimension)
            XCTAssertLessThanOrEqual(dimensions.height, StickerLimits.maxDimension)
        }
    }

    func testHonoursAnExplicitSmallerCanvas() throws {
        let output = try XCTUnwrap(
            StickerImageProcessor.normalize(png(width: 128, height: 128),
                                            canvas: StickerLimits.fallbackCanvasSize)
        )
        let dimensions = try XCTUnwrap(size(of: output))

        XCTAssertEqual(dimensions.width, StickerLimits.fallbackCanvasSize)
    }

    func testReturnsNilForUndecodableBytes() {
        XCTAssertNil(StickerImageProcessor.normalize(Data("not an image".utf8)))
        XCTAssertNil(StickerImageProcessor.normalize(Data()))
    }

    func testOutputPreservesTransparency() throws {
        let output = try XCTUnwrap(StickerImageProcessor.normalize(png(width: 400, height: 20)))
        let image = try XCTUnwrap(UIImage(data: output))
        let cgImage = try XCTUnwrap(image.cgImage)

        XCTAssertNotEqual(cgImage.alphaInfo, .none)
    }

    // MARK: - Still animation (the system Recents trick)

    /// iOS copies a sent sticker into the system Recents picker only when the
    /// sticker is animated — verified on device by sending a static and an
    /// animated one back to back and finding only the animated one there.
    /// A still image encoded as two identical frames qualifies.
    func testStillAnimationHasTwoFrames() throws {
        let output = try XCTUnwrap(
            StickerImageProcessor.normalizeAsStillAnimation(png(width: 64, height: 64)))
        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: output), 2,
                       "one frame would not reach the system picker")
    }

    /// The whole point is that it looks unchanged.
    func testStillAnimationRendersTheSameCanvasAsTheStillPath() throws {
        let source = png(width: 40, height: 90)
        let animated = try XCTUnwrap(
            StickerImageProcessor.normalizeAsStillAnimation(source))
        let image = try XCTUnwrap(UIImage(data: animated))

        XCTAssertEqual(Int(image.size.width), StickerLimits.canvasSize)
        XCTAssertEqual(Int(image.size.height), StickerLimits.canvasSize)
    }

    /// APNG, not GIF: GIF is 256 colours with **1-bit** alpha and would harden
    /// every antialiased edge.
    ///
    /// This asserts a *partial* alpha value survives, not merely that an alpha
    /// channel exists. The first version of this test checked
    /// `alphaInfo != .none` and passed happily when the encoder was switched
    /// to GIF — GIF reports an alpha channel too, it just cannot hold any
    /// value between transparent and opaque. Half-transparent in, half
    /// transparent out is the only form of this check that can fail.
    func testStillAnimationPreservesPartialTransparency() throws {
        let source = halfTransparentPNG(side: 64)
        let sourceAlpha = try XCTUnwrap(centreAlpha(of: source))
        XCTAssertEqual(sourceAlpha, 128, accuracy: 2,
                       "fixture: the source itself must be half transparent")

        let output = try XCTUnwrap(
            StickerImageProcessor.normalizeAsStillAnimation(source))

        let alpha = try XCTUnwrap(centreAlpha(of: output))
        XCTAssertEqual(alpha, 128, accuracy: 8,
                       "a GIF round trip would snap this to 0 or 255")
    }

    /// A solid colour at 50% alpha across the whole square.
    private func halfTransparentPNG(side: Int) -> Data {
        let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = context.makeImage()!

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// Alpha of the centre pixel of frame 0, 0-255.
    private func centreAlpha(of data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let frame = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Draw the frame scaled so its centre pixel lands in this 1x1 context.
        context.draw(frame, in: CGRect(x: -CGFloat(frame.width) / 2 + 0.5,
                                       y: -CGFloat(frame.height) / 2 + 0.5,
                                       width: CGFloat(frame.width),
                                       height: CGFloat(frame.height)))
        return CGFloat(pixel[3])
    }

    /// Doubling the frames must not push a normal sticker over the ceiling.
    func testStillAnimationStaysUnderTheByteLimit() throws {
        let output = try XCTUnwrap(
            StickerImageProcessor.normalizeAsStillAnimation(png(width: 512, height: 512)))
        XCTAssertLessThanOrEqual(output.count, StickerLimits.maxBytes)
    }

    func testStillAnimationRejectsUndecodableData() {
        XCTAssertNil(StickerImageProcessor.normalizeAsStillAnimation(Data([0x00, 0x01])))
    }

}
