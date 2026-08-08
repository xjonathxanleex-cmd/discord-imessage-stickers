import XCTest
import UIKit
@testable import StickerKit

final class PhotoDraftLoaderTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
    }

    /// `format.scale = 1` matters: the renderer otherwise uses the screen's
    /// scale, so a fixture asking for 4000x3000 would produce 12000x9000 and
    /// the assertions below would be measuring something else entirely.
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testNamesDraftsSequentially() {
        let drafts = PhotoDraftLoader.drafts(from: [
            png(width: 100, height: 100),
            png(width: 120, height: 90),
        ])

        XCTAssertEqual(drafts.map(\.name), ["photo 1", "photo 2"])
    }

    func testMarksDraftsAsComingFromPhotos() {
        let drafts = PhotoDraftLoader.drafts(from: [png(width: 100, height: 100)])
        XCTAssertEqual(drafts.first?.origin, .photo)
    }

    func testDownsamplesALargePhoto() throws {
        // A 12-megapixel iPhone photo decodes to roughly 49 MB. Against an
        // extension killed between 40 and 120 MB, downsampling is survival,
        // not optimization.
        let drafts = PhotoDraftLoader.drafts(from: [png(width: 4032, height: 3024)])
        let draft = try XCTUnwrap(drafts.first)
        let size = try XCTUnwrap(ImageDownsampler.pixelSize(of: draft.imageData))

        XCTAssertLessThanOrEqual(size.width, StickerLimits.maxDimension)
        XCTAssertLessThanOrEqual(size.height, StickerLimits.maxDimension)
    }

    func testDetectsAnimationFromTheBytes() {
        // Unlike link import, which must guess from a URL's extension, the
        // picked bytes are in hand — so animation is detected, not assumed.
        let drafts = PhotoDraftLoader.drafts(
            from: [temp.makeAnimatedGIFData(frameCount: 6)]
        )

        XCTAssertEqual(drafts.first?.isAnimated, true)
    }

    func testASingleFrameImageIsNotAnimated() {
        let drafts = PhotoDraftLoader.drafts(
            from: [temp.makeAnimatedGIFData(frameCount: 1)]
        )

        XCTAssertEqual(drafts.first?.isAnimated, false)
    }

    func testAnimatedImagesAreNotDownsampled() throws {
        // Downsampling reads frame 0 only, which would silently flatten an
        // animation into a still image.
        let animated = temp.makeAnimatedGIFData(frameCount: 6)
        let drafts = PhotoDraftLoader.drafts(from: [animated])

        XCTAssertEqual(drafts.first?.imageData, animated)
    }

    func testDropsUndecodableInputsAndKeepsNumberingContiguous() {
        let drafts = PhotoDraftLoader.drafts(from: [
            png(width: 100, height: 100),
            Data("not an image".utf8),
            png(width: 100, height: 100),
        ])

        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts.map(\.name), ["photo 1", "photo 2"],
                       "numbering must not leave a gap where a bad input was")
    }

    func testAnEmptyInputProducesNoDrafts() {
        XCTAssertTrue(PhotoDraftLoader.drafts(from: []).isEmpty)
    }
}
