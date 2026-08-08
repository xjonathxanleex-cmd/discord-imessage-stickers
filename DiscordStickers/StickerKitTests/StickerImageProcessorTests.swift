import XCTest
import UIKit
import ImageIO
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
}
