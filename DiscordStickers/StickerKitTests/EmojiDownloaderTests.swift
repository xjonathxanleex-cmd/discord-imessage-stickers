import XCTest
import UIKit
@testable import StickerKit

final class EmojiDownloaderTests: XCTestCase {

    private var temp: TempDirectory!
    private var store: StickerStore!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        store = try StickerStore(root: temp.url, writeDebounce: 0)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        store = nil
        temp = nil
    }

    private func makeDownloader() -> EmojiDownloader {
        EmojiDownloader(store: store, session: StubURLProtocol.makeSession())
    }

    private func pngData(width: Int, height: Int? = nil) -> Data {
        let size = CGSize(width: width, height: height ?? width)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    /// Noise compresses badly, so a large random image is the reliable way to
    /// push a *rendered* PNG past the byte gate. Padding trailing bytes would
    /// not work here: the downloader re-encodes, discarding anything appended.
    private func bulkyPNGData(side: Int) -> Data {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for index in pixels.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return UIImage(cgImage: context.makeImage()!).pngData()!
    }

    private func emoji(_ id: String, _ name: String) -> ParsedEmoji {
        ParsedEmoji(id: id, name: name, isAnimated: false)
    }

    func testDownloadsAndCommitsAValidEmoji() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertEqual(store.all().map(\.name), ["wave"])
    }

    func testRequestsTheBareURLWithNoSizeParameter() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([emoji("111", "wave")])

        // Task 0 measured that ?size= only downscales, so sending one either
        // changes nothing or actively degrades the source.
        XCTAssertNil(StubURLProtocol.requestedURLs.first?.query)
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
    }

    func testAcceptsAnUndersizedNonSquareEmoji() async throws {
        // The real measured shape of <a:cuh:...>, which raw would fail
        // MSSticker's 100px floor and be silently dropped.
        StubURLProtocol.handler = { _ in
            (200, self.pngData(width: 76, height: 61))
        }

        let outcome = await makeDownloader().download([emoji("111", "cuh")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertTrue(outcome.unusable.isEmpty)
    }

    func testSkipsEmojiAlreadyInTheStore() async throws {
        try store.add(
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(), useCount: 0),
            movingFileFrom: try temp.makePNG(named: "seed.png")
        )
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.alreadyPresent, ["111"])
        XCTAssertTrue(outcome.added.isEmpty)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty)
    }

    func testTreatsA404AsMissingRatherThanThrowing() async throws {
        StubURLProtocol.handler = { _ in (404, Data()) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.missing, ["111"])
        XCTAssertTrue(store.all().isEmpty)
    }

    func testFallsBackToASmallerCanvasWhenTheRenderIsTooLarge() async throws {
        // Noise at 618 renders past 500 KB on a 256 canvas but fits on a 128.
        StubURLProtocol.handler = { _ in (200, self.bulkyPNGData(side: 618)) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.added, ["111"])
        // Only one network request either way — the retry is a local
        // re-render, not a refetch.
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
    }

    func testRejectsNonImagePayloads() async throws {
        StubURLProtocol.handler = { _ in (200, Data("not an image".utf8)) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.unusable, ["111"])
    }

    func testPartialBatchReportsBothSidesAndLeavesNoOrphanFiles() async throws {
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            return path.contains("dead") ? (404, Data())
                                         : (200, self.pngData(width: 128))
        }

        let outcome = await makeDownloader().download([
            emoji("ok1", "one"), emoji("dead", "gone"), emoji("ok2", "two"),
        ])

        XCTAssertEqual(Set(outcome.added), ["ok1", "ok2"])
        XCTAssertEqual(outcome.missing, ["dead"])
        XCTAssertEqual(store.all().count, 2)
    }

    func testEmptyInputProducesEmptyOutcome() async throws {
        let outcome = await makeDownloader().download([])
        XCTAssertEqual(outcome, DownloadOutcome(added: [], alreadyPresent: [],
                                                missing: [], unusable: []))
    }
}
