import XCTest
import UIKit
@testable import StickerKit

final class StickerImporterTests: XCTestCase {

    private var temp: TempDirectory!
    private var store: StickerStore!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        store = try StickerStore(root: temp.url, writeDebounce: 0)
    }

    override func tearDown() {
        store = nil
        temp = nil
    }

    private func pngData(width: Int = 128) -> Data {
        let size = CGSize(width: width, height: width)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private func draft(_ name: String, data: Data, isAnimated: Bool = false) -> StickerDraft {
        StickerDraft(name: name, imageData: data,
                     origin: .link, isAnimated: isAnimated)
    }

    func testImportsADraftAndKeepsItsName() {
        let outcome = StickerImporter.importDrafts(
            [draft("party parrot", data: pngData())], into: store
        )

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(store.all().first?.name, "party parrot")
        XCTAssertEqual(store.all().first?.source, .link)
    }

    func testIDIsContentAddressedAndStable() {
        let data = pngData()
        _ = StickerImporter.importDrafts([draft("a", data: data)], into: store)
        let firstID = store.all().first?.id

        XCTAssertTrue(firstID?.hasPrefix("sha256-") ?? false)
    }

    func testTheSameImageTwiceIsReportedAlreadyPresent() {
        // Re-importing the same picture is a no-op, exactly like re-pasting
        // the same Discord emoji.
        let data = pngData()
        _ = StickerImporter.importDrafts([draft("first", data: data)], into: store)

        let second = StickerImporter.importDrafts(
            [draft("second", data: data)], into: store
        )

        XCTAssertEqual(second.added.count, 0)
        XCTAssertEqual(second.alreadyPresent.count, 1)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.name, "first",
                       "the first import's name must win")
    }

    func testTheSameImageFromTwoURLsCollapsesToOneSticker() {
        let data = pngData()
        let outcome = StickerImporter.importDrafts([
            StickerDraft(name: "x", imageData: data, origin: .link,
                         isAnimated: false),
            StickerDraft(name: "y", imageData: data, origin: .link,
                         isAnimated: false),
        ], into: store)

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(outcome.alreadyPresent.count, 1)
        XCTAssertEqual(store.all().count, 1)
    }

    func testUndecodableBytesAreReportedUnusable() {
        let outcome = StickerImporter.importDrafts(
            [draft("broken", data: Data("nope".utf8))], into: store
        )

        XCTAssertEqual(outcome.unusable.count, 1)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testAPartialBatchStoresTheGoodOnes() {
        let outcome = StickerImporter.importDrafts([
            draft("good", data: pngData()),
            draft("bad", data: Data("nope".utf8)),
        ], into: store)

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(outcome.unusable.count, 1)
        XCTAssertEqual(store.all().count, 1)
    }

    func testAnimatedDraftsAreStoredAsAnimated() throws {
        let animated = temp.makeAnimatedGIFData(frameCount: 6)
        let outcome = StickerImporter.importDrafts(
            [draft("loop", data: animated, isAnimated: true)], into: store
        )

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(store.all().first?.isAnimated, true)
    }

    func testAnEmptyBatchIsAnEmptyOutcome() {
        XCTAssertTrue(StickerImporter.importDrafts([], into: store).isEmpty)
    }

    func testAGifURLWithASingleFrameIsRecordedAsStatic() throws {
        // `isAnimated: true` here is only a guess from the source URL's
        // extension. A single-frame GIF is not animation, so what actually
        // gets stored is static — the manifest entry must say so, or a
        // later restore will request the wrong extension for it.
        let singleFrame = temp.makeAnimatedGIFData(frameCount: 1)
        let outcome = StickerImporter.importDrafts(
            [draft("loop", data: singleFrame, isAnimated: true)], into: store
        )

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(store.all().first?.isAnimated, false)
    }

    /// Noise compresses badly, so a large random image is the reliable way
    /// to push a *rendered* PNG past the byte gate. Mirrors
    /// `EmojiDownloaderTests.bulkyPNGData`.
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

    func testFallsBackToASmallerCanvasWhenTheRenderIsTooLarge() {
        // Noise at 618 renders past 500 KB on a 256 canvas but fits on a
        // 128 — the same fallback ladder `EmojiDownloader` applies. Without
        // it, this draft would reach `StickerCommitter` only to be silently
        // dropped when `MSSticker.init` throws.
        let outcome = StickerImporter.importDrafts(
            [draft("noisy", data: bulkyPNGData(side: 618))], into: store
        )

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertTrue(outcome.unusable.isEmpty)
    }

    func testUnusableDraftsAreRecordedByContentHashNotName() {
        // Every other array in `DownloadOutcome` holds ids, not
        // user-chosen names — `unusable` must match, or a caller reading
        // it as an id list gets a name leaked into it instead.
        let outcome = StickerImporter.importDrafts(
            [draft("do not leak this name", data: Data("nope".utf8))], into: store
        )

        XCTAssertEqual(outcome.unusable, ["sha256-unknown-0"])
    }
}
