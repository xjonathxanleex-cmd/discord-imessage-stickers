import XCTest
import UIKit
@testable import StickerKit

final class ImageDownsamplerTests: XCTestCase {

    /// `format.scale = 1` is required. `UIGraphicsImageRenderer` defaults to
    /// the screen's scale, which is 3x on this simulator — a fixture asking
    /// for 128x128 would silently produce 384x384, and every dimension
    /// assertion below would be measuring the wrong thing.
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testReadsPixelSizeWithoutDecoding() {
        let size = ImageDownsampler.pixelSize(of: png(width: 300, height: 200))
        XCTAssertEqual(size?.width, 300)
        XCTAssertEqual(size?.height, 200)
    }

    func testPixelSizeIsNilForNonImages() {
        XCTAssertNil(ImageDownsampler.pixelSize(of: Data("nope".utf8)))
        XCTAssertNil(ImageDownsampler.pixelSize(of: Data()))
    }

    func testDownsamplesTheLongEdgeToTheLimit() throws {
        let output = try XCTUnwrap(
            ImageDownsampler.downsampled(png(width: 2000, height: 1000),
                                         maxPixel: 618)
        )
        let size = try XCTUnwrap(ImageDownsampler.pixelSize(of: output))

        XCTAssertEqual(size.width, 618)
        XCTAssertEqual(size.height, 309, "aspect ratio must be preserved")
    }

    func testDownsamplingIsNotUpscaling() throws {
        // A small image must come back at its own size, not blown up to the
        // limit — upscaling here would waste bytes and add no detail.
        let output = try XCTUnwrap(
            ImageDownsampler.downsampled(png(width: 100, height: 80),
                                         maxPixel: 618)
        )
        let size = try XCTUnwrap(ImageDownsampler.pixelSize(of: output))

        XCTAssertLessThanOrEqual(size.width, 100)
        XCTAssertLessThanOrEqual(size.height, 80)
    }

    func testDownsampledIsNilForNonImages() {
        XCTAssertNil(ImageDownsampler.downsampled(Data("nope".utf8),
                                                  maxPixel: 618))
    }
}
