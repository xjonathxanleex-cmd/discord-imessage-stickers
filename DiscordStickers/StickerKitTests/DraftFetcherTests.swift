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
        let size = CGSize(width: width, height: width)
        return UIGraphicsImageRenderer(size: size).image { context in
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
}

private extension Result where Failure == DraftFetchError {
    var failure: DraftFetchError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
