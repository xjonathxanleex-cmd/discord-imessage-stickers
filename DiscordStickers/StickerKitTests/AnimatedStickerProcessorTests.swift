import XCTest
import UIKit
import ImageIO
@testable import StickerKit

final class AnimatedStickerProcessorTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
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

    func testNormalizesToTheAnimatedCanvas() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 10)
        let output = try XCTUnwrap(AnimatedStickerProcessor.normalize(input))
        let dimensions = try XCTUnwrap(size(of: output))

        XCTAssertEqual(dimensions.width, StickerLimits.animatedCanvasSize)
        XCTAssertEqual(dimensions.height, StickerLimits.animatedCanvasSize)
    }

    func testKeepsEveryFrameWhenUnderTheCap() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 10)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, maxFrames: 48)
        )

        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: output), 10)
    }

    func testDropsFramesDownToTheCap() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 94)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, maxFrames: 48)
        )

        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: output), 48)
    }

    func testDroppingFramesPreservesTotalDuration() throws {
        // The test that catches the half-speed bug. Dropping every other
        // frame while keeping the survivors' delays plays the loop at half
        // speed — still smooth, silently wrong, and invisible to any
        // frame-count or file-size assertion.
        let input = temp.makeAnimatedGIFData(frameCount: 94, delay: 0.05)
        let expected = AnimatedStickerProcessor.totalDuration(of: input)
        XCTAssertEqual(expected, 94 * 0.05, accuracy: 0.05,
                       "fixture itself is wrong if this fails")

        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, maxFrames: 48)
        )

        XCTAssertEqual(AnimatedStickerProcessor.totalDuration(of: output),
                       expected, accuracy: 0.05)
    }

    func testDropsFramesEvenlyRatherThanTruncating() throws {
        // A truncating implementation would keep frames 0..<48 of 94, so the
        // last surviving frame would be the input's 47th. Sampling evenly
        // means the last surviving frame is near the input's end. The frames
        // differ in hue, so comparing the final frame's pixels distinguishes
        // the two.
        let input = temp.makeAnimatedGIFData(frameCount: 94)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, maxFrames: 48)
        )

        let inputSource = try XCTUnwrap(
            CGImageSourceCreateWithData(input as CFData, nil)
        )
        let outputSource = try XCTUnwrap(
            CGImageSourceCreateWithData(output as CFData, nil)
        )

        // Each fixture frame is a single solid colour, so squashing a whole
        // frame into one pixel yields that colour.
        func colour(_ source: CGImageSource, at index: Int) throws -> [UInt8] {
            let image = try XCTUnwrap(
                CGImageSourceCreateImageAtIndex(source, index, nil)
            )
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return pixel
        }

        let lastOutput = try colour(outputSource, at: 47)
        let inputAt47 = try colour(inputSource, at: 47)
        let inputAt93 = try colour(inputSource, at: 93)

        // Sanity: the fixture's frames really do differ.
        XCTAssertNotEqual(inputAt47, inputAt93)
        // The kept last frame must come from near the end, not the middle.
        XCTAssertNotEqual(lastOutput, inputAt47,
                          "frames were truncated, not sampled evenly")
    }

    func testReturnsNilForASingleFrameImage() {
        let input = temp.makeAnimatedGIFData(frameCount: 1)
        XCTAssertNil(AnimatedStickerProcessor.normalize(input))
    }

    func testReturnsNilForUndecodableBytes() {
        XCTAssertNil(AnimatedStickerProcessor.normalize(Data("nope".utf8)))
        XCTAssertNil(AnimatedStickerProcessor.normalize(Data()))
    }

    func testEveryOutputSatisfiesMSStickerBounds() throws {
        for (width, height) in [(76, 61), (128, 128), (400, 20), (16, 16)] {
            let input = temp.makeAnimatedGIFData(
                frameCount: 6, width: width, height: height
            )
            let output = try XCTUnwrap(
                AnimatedStickerProcessor.normalize(input),
                "failed for \(width)x\(height)"
            )
            let dimensions = try XCTUnwrap(size(of: output))
            XCTAssertGreaterThanOrEqual(dimensions.width, StickerLimits.minDimension)
            XCTAssertLessThanOrEqual(dimensions.width, StickerLimits.maxDimension)
            XCTAssertGreaterThanOrEqual(dimensions.height, StickerLimits.minDimension)
            XCTAssertLessThanOrEqual(dimensions.height, StickerLimits.maxDimension)
        }
    }

    func testHonoursAnExplicitSmallerCanvas() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 6)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, canvas: 100)
        )

        XCTAssertEqual(try XCTUnwrap(size(of: output)).width, 100)
    }

    func testCanEncodeAsGIFWhenAsked() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 6)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, asGIF: true)
        )

        // GIF87a / GIF89a both begin "GIF".
        XCTAssertEqual(Array(output.prefix(3)), Array("GIF".utf8))
        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: output), 6)
    }

    func testFrameCountAndDurationHandleGarbage() {
        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: Data()), 0)
        XCTAssertEqual(AnimatedStickerProcessor.totalDuration(of: Data()), 0)
    }

    func testAnimatedOutputPreservesTransparency() throws {
        func alphaInfoOfFirstFrame(_ data: Data) throws -> CGImageAlphaInfo {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return frame.alphaInfo
        }

        let input = temp.makeAnimatedGIFData(frameCount: 6, opaque: false)
        let output = try XCTUnwrap(AnimatedStickerProcessor.normalize(input))
        XCTAssertNotEqual(try alphaInfoOfFirstFrame(output), .none)

        // Extreme aspect ratio: the letterbox padding added around the
        // drawn image must be transparent, not opaque.
        let wideInput = temp.makeAnimatedGIFData(
            frameCount: 6, width: 400, height: 20, opaque: false
        )
        let wideOutput = try XCTUnwrap(AnimatedStickerProcessor.normalize(wideInput))
        XCTAssertNotEqual(try alphaInfoOfFirstFrame(wideOutput), .none)
    }
}
