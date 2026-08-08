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
        StickerDraft(sourceURL: URL(string: "https://e.com/\(name).png"),
                     name: name, imageData: data,
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
            StickerDraft(sourceURL: URL(string: "https://a.com/x.png"),
                         name: "x", imageData: data, origin: .link,
                         isAnimated: false),
            StickerDraft(sourceURL: URL(string: "https://b.com/y.png"),
                         name: "y", imageData: data, origin: .link,
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
}
