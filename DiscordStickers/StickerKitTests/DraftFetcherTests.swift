import XCTest
import UIKit
@testable import StickerKit

final class DraftFetcherTests: XCTestCase {

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    private func makeFetcher() -> DraftFetcher {
        DraftFetcher(session: StubURLProtocol.makeSession())
    }

    private func link(_ string: String) -> ParsedLink {
        LinkParser.parse(string)!
    }

    private func pngData(width: Int = 128) -> Data {
        // Explicit scale of 1: `width` is meant as a pixel count, and
        // `UIGraphicsImageRendererFormat.default()` otherwise renders at the
        // simulator's screen scale (e.g. 3x on iPhone 17 Pro), silently
        // tripling the actual pixel dimensions this test asks for.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: width)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testFetchesAnImageIntoADraft() async {
        StubURLProtocol.handler = { _ in (200, self.pngData()) }

        let result = await makeFetcher().fetch(link("https://e.com/cat.png"))

        guard case .success(let draft) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(draft.name, "cat")
        XCTAssertEqual(draft.origin, .link)
        XCTAssertFalse(draft.imageData.isEmpty)
    }

    func testReportsUnreachableOnA404() async {
        StubURLProtocol.handler = { _ in (404, Data()) }

        let result = await makeFetcher().fetch(link("https://e.com/cat.png"))

        XCTAssertEqual(result.failure, .unreachable)
    }

    func testReportsUnreachableOnAServerError() async {
        StubURLProtocol.handler = { _ in (500, Data()) }

        let result = await makeFetcher().fetch(link("https://e.com/cat.png"))
        XCTAssertEqual(result.failure, .unreachable)
    }

    func testRejectsABodyOverTheSizeCap() async {
        // Bounding this protects the extension's 40-120 MB ceiling from a
        // careless or hostile URL.
        let huge = Data(repeating: 0x41,
                        count: DraftFetcher.maxDownloadBytes + 1)
        StubURLProtocol.handler = { _ in (200, huge) }

        let result = await makeFetcher().fetch(link("https://e.com/big.png"))
        XCTAssertEqual(result.failure, .tooLarge)
    }

    func testAcceptsABodyExactlyAtTheCap() async {
        // Off-by-one guard: the cap is inclusive.
        var data = pngData()
        data.append(Data(repeating: 0,
                         count: DraftFetcher.maxDownloadBytes - data.count))
        StubURLProtocol.handler = { _ in (200, data) }

        let result = await makeFetcher().fetch(link("https://e.com/edge.png"))
        XCTAssertNil(result.failure)
    }

    func testRejectsANonImageBody() async {
        // The bytes decide, not the Content-Type header.
        StubURLProtocol.handler = { _ in (200, Data("<html>nope</html>".utf8)) }

        let result = await makeFetcher().fetch(link("https://e.com/page.png"))
        XCTAssertEqual(result.failure, .notAnImage)
    }

    func testCarriesTheAnimatedFlagFromTheLink() async {
        StubURLProtocol.handler = { _ in (200, self.pngData()) }

        let result = await makeFetcher().fetch(link("https://e.com/loop.gif"))

        guard case .success(let draft) = result else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(draft.isAnimated)
    }

    /// Flat, solid-fill artwork compresses tiny regardless of pixel count,
    /// so a byte cap alone would let an enormous bitmap through. Non-square
    /// so rendering stays cheap even past the pixel cap.
    private func solidPNGData(width: Int, height: Int) -> Data {
        // Explicit scale of 1 for the same reason as `pngData` above: these
        // callers need the exact pixel dimensions they ask for.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testRejectsImageDimensionsOverTheCap() async {
        // Only a metadata-based dimension check catches this — the byte
        // cap alone would not, since flat artwork compresses far under it.
        StubURLProtocol.handler = { _ in
            (200, self.solidPNGData(
                width: StickerLimits.maxSourcePixelDimension + 4, height: 8
            ))
        }

        let result = await makeFetcher().fetch(link("https://e.com/huge.png"))
        XCTAssertEqual(result.failure, .tooLarge)
    }

    func testAcceptsDimensionsExactlyAtTheCap() async {
        // Off-by-one guard: the pixel cap is inclusive, matching the byte
        // cap's own inclusive boundary.
        StubURLProtocol.handler = { _ in
            (200, self.solidPNGData(
                width: StickerLimits.maxSourcePixelDimension, height: 8
            ))
        }

        let result = await makeFetcher().fetch(link("https://e.com/edge.png"))
        XCTAssertNil(result.failure)
    }

    func testDownsamplesLargeStaticImagesAtFetchTime() async {
        // A byte cap does not bound a bitmap: without decode-time
        // downsampling, this 1000x1000 source would pass through untouched
        // and get decoded at full resolution three separate times
        // downstream.
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 1000)) }

        let result = await makeFetcher().fetch(link("https://e.com/big.png"))

        guard case .success(let draft) = result,
              let image = UIImage(data: draft.imageData)
        else { return XCTFail("expected a decodable success draft") }

        XCTAssertLessThanOrEqual(Int(image.size.width), StickerLimits.maxDimension)
        XCTAssertLessThanOrEqual(Int(image.size.height), StickerLimits.maxDimension)
    }

    func testDoesNotDownsampleAnimatedDraftsRegardlessOfSize() async {
        // AnimatedStickerProcessor already streams one frame at a time, and
        // the dimension cap bounds a single frame — downsampling an
        // animated draft here would be redundant work on the
        // memory-critical path.
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 1000)) }

        let result = await makeFetcher().fetch(link("https://e.com/loop.gif"))

        guard case .success(let draft) = result,
              let image = UIImage(data: draft.imageData)
        else { return XCTFail("expected a decodable success draft") }

        XCTAssertEqual(Int(image.size.width), 1000)
        XCTAssertEqual(Int(image.size.height), 1000)
    }
}

private extension Result where Failure == DraftFetchError {
    var failure: DraftFetchError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
