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

    func testCollapsesDuplicateIDsInTheInput() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let outcome = await makeDownloader().download([
            emoji("111", "wave"), emoji("111", "wave"),
        ])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
    }

    func testDuplicateIDsDoNotDoubleCountAcrossBuckets() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let outcome = await makeDownloader().download([
            emoji("111", "wave"), emoji("111", "wave"), emoji("222", "smile"),
        ])

        let total = outcome.added.count + outcome.alreadyPresent.count
            + outcome.missing.count + outcome.unusable.count
        XCTAssertEqual(total, 2)
    }

    private func animatedEmoji(_ id: String, _ name: String) -> ParsedEmoji {
        ParsedEmoji(id: id, name: name, isAnimated: true)
    }

    func testRequestsGIFForAnimatedEmoji() async throws {
        StubURLProtocol.handler = { _ in
            (200, self.temp.makeAnimatedGIFData(frameCount: 6))
        }

        _ = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(StubURLProtocol.requestedURLs.first?.lastPathComponent,
                       "111.gif")
        XCTAssertNil(StubURLProtocol.requestedURLs.first?.query)
    }

    func testRequestsPNGForStaticEmoji() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(StubURLProtocol.requestedURLs.first?.lastPathComponent,
                       "111.png")
    }

    func testStoresAnimatedFlagOnTheEntry() async throws {
        StubURLProtocol.handler = { _ in
            (200, self.temp.makeAnimatedGIFData(frameCount: 6))
        }

        _ = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(store.all().first?.isAnimated, true)
    }

    func testRetriesWithPNGWhenGIFReturns415() async throws {
        // A wrong isAnimated flag: the CDN answers 415 for a static emoji
        // requested as .gif. Retrying self-heals it instead of reporting a
        // puzzling failure.
        StubURLProtocol.handler = { request in
            request.url?.lastPathComponent == "111.gif"
                ? (415, Data())
                : (200, self.pngData(width: 128))
        }

        let outcome = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertEqual(StubURLProtocol.requestedURLs.map(\.lastPathComponent),
                       ["111.gif", "111.png"])
        XCTAssertEqual(store.all().first?.isAnimated, false,
                       "the corrected flag must be what gets stored")
    }

    func testRetriesWithGIFWhenPNGReturns415() async throws {
        StubURLProtocol.handler = { request in
            request.url?.lastPathComponent == "111.png"
                ? (415, Data())
                : (200, self.temp.makeAnimatedGIFData(frameCount: 6))
        }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertEqual(store.all().first?.isAnimated, true)
    }

    func testRejectsWhenBothExtensions415() async throws {
        StubURLProtocol.handler = { _ in (415, Data()) }

        let outcome = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(outcome.unusable, ["111"])
        XCTAssertTrue(store.all().isEmpty)
    }

    func testAnimatedSourceWithOneFrameIsStoredAsStatic() async throws {
        // Fewer than two frames is not animation. It must route to the static
        // processor rather than being rejected.
        StubURLProtocol.handler = { _ in
            (200, self.temp.makeAnimatedGIFData(frameCount: 1))
        }

        let outcome = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertEqual(store.all().first?.isAnimated, false)
    }

    private func sevenTVEmoji(_ id: String, _ name: String,
                              animated: Bool) -> ParsedEmoji {
        ParsedEmoji(id: id, name: name, isAnimated: animated, source: .sevenTV)
    }

    func testRequestsTheSevenTVCDNForSevenTVEmotes() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([
            sevenTVEmoji("01G3WEGZN0000ET2J0MQP5YJ0G", "GAMBA", animated: false)
        ])

        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.first)
        XCTAssertEqual(url.host, "cdn.7tv.app")
        XCTAssertEqual(url.path,
                       "/emote/01G3WEGZN0000ET2J0MQP5YJ0G/4x.webp")
    }

    func testRequestsGIFForAnimatedSevenTVEmotes() async throws {
        // .gif is not advertised in 7TV's own host.files list but is served,
        // and is chosen over animated WebP because ImageIO's animated-WebP
        // frame support is unverified on this platform.
        StubURLProtocol.handler = { _ in
            (200, self.temp.makeAnimatedGIFData(frameCount: 6))
        }

        _ = await makeDownloader().download([
            sevenTVEmoji("01G3WEGZN0000ET2J0MQP5YJ0G", "GAMBA", animated: true)
        ])

        XCTAssertEqual(StubURLProtocol.requestedURLs.first?.lastPathComponent,
                       "4x.gif")
    }

    func testStoresTheSevenTVSourceOnTheEntry() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([
            sevenTVEmoji("01G3WEGZN0000ET2J0MQP5YJ0G", "GAMBA", animated: false)
        ])

        XCTAssertEqual(store.all().first?.source, .sevenTV)
    }

    func testContentAddressedEntriesAreNeverRequestedFromACDN() async throws {
        // .photo and .link entries are content-addressed (sha256-…) with no
        // remote origin at all. Nothing sends this today only because
        // ManifestTransfer partitions on the "sha256-" prefix in a different
        // file — a future caller that skips that check must still fail
        // closed here rather than firing a bogus request.
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let outcome = await makeDownloader().download([
            ParsedEmoji(id: "sha256-abcdef0123456789", name: "my photo",
                       isAnimated: false, source: .photo)
        ])

        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty)
        XCTAssertEqual(outcome.unusable, ["sha256-abcdef0123456789"])
    }

    func testDiscordEmojiStillUseTheDiscordCDN() async throws {
        // The regression guard for this task: adding a second source must not
        // change where Discord emoji come from.
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([emoji("111", "wave")])

        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.first)
        XCTAssertEqual(url.host, "cdn.discordapp.com")
        XCTAssertEqual(url.path, "/emojis/111.png")
    }
}
