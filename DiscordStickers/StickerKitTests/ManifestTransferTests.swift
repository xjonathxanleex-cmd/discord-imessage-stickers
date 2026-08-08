import XCTest
import UIKit
@testable import StickerKit

final class ManifestTransferTests: XCTestCase {

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

    private func pngData(width: Int = 128, height: Int? = nil) -> Data {
        let size = CGSize(width: width, height: height ?? width)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testExportProducesTextThatImportsBack() throws {
        try store.add(
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 1000), useCount: 7),
            movingFileFrom: try temp.makePNG(named: "a.png")
        )

        let text = ManifestTransfer.export(from: store)
        let imported = ManifestTransfer.parseImport(text)

        XCTAssertEqual(imported.map(\.id), ["111"])
        XCTAssertEqual(imported.first?.useCount, 7)
        XCTAssertEqual(imported.first?.name, "wave")
    }

    func testImportRejectsGarbageWithoutThrowing() {
        XCTAssertTrue(ManifestTransfer.parseImport("not json at all").isEmpty)
        XCTAssertTrue(ManifestTransfer.parseImport("").isEmpty)
    }

    func testExportOfAnEmptyStoreIsAnEmptyArray() {
        XCTAssertEqual(ManifestTransfer.parseImport(
            ManifestTransfer.export(from: store)
        ).count, 0)
    }

    func testRestoreReplaysUseCountsOntoAFreshStore() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData()) }

        let entries = [
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 1000), useCount: 7),
            StickerEntry(id: "222", name: "smile", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 2000), useCount: 3),
        ]

        _ = await ManifestTransfer.restore(entries, store: store, downloader: makeDownloader())

        let byID = Dictionary(uniqueKeysWithValues: store.all().map { ($0.id, $0) })
        XCTAssertEqual(byID["111"]?.useCount, 7)
        XCTAssertEqual(byID["222"]?.useCount, 3)
    }

    func testRestoreSkipsEntriesThatFailedToDownload() async throws {
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            return path.contains("222") ? (404, Data()) : (200, self.pngData())
        }

        let entries = [
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 1000), useCount: 7),
            StickerEntry(id: "222", name: "smile", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 2000), useCount: 3),
        ]

        _ = await ManifestTransfer.restore(entries, store: store, downloader: makeDownloader())

        let byID = Dictionary(uniqueKeysWithValues: store.all().map { ($0.id, $0) })
        XCTAssertEqual(byID["111"]?.useCount, 7)
        XCTAssertNil(byID["222"])
    }

    func testRestoreOfAnEmptyListIsANoOp() async throws {
        let outcome = await ManifestTransfer.restore([], store: store, downloader: makeDownloader())

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty)
    }

    func testRestoreReplaysFavorites() async throws {
        let source = try StickerStore(root: try TempDirectory().url, writeDebounce: 0)
        try source.add(
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 1000), useCount: 1),
            movingFileFrom: try temp.makePNG(named: "a.png")
        )
        try source.add(
            StickerEntry(id: "222", name: "smile", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 2000), useCount: 1),
            movingFileFrom: try temp.makePNG(named: "b.png")
        )
        source.setFavorite(true, id: "111")

        let text = ManifestTransfer.export(from: source)
        let entries = ManifestTransfer.parseImport(text)

        StubURLProtocol.handler = { _ in (200, self.pngData()) }
        _ = await ManifestTransfer.restore(entries, store: store, downloader: makeDownloader())

        let favoriteIDs = store.favorites().map(\.id)
        XCTAssertEqual(favoriteIDs, ["111"])
        XCTAssertFalse(favoriteIDs.contains("222"))
    }

    func testRestorePreservesFavoriteOrder() async throws {
        // Array order deliberately disagrees with favoritedAt order (333,
        // 111, 222 vs. timestamps 111 < 222 < 333), so a replay that
        // forgets to sort by favoritedAt before calling setFavorite would
        // stamp fresh Date()s in array order and produce ["333", "111",
        // "222"] here — a different, and wrong, result. That's what makes
        // this test discriminate rather than pass on either implementation.
        let entries = [
            StickerEntry(id: "333", name: "cry", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 3000), useCount: 0,
                         favoritedAt: Date(timeIntervalSince1970: 5002)),
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 1000), useCount: 0,
                         favoritedAt: Date(timeIntervalSince1970: 5000)),
            StickerEntry(id: "222", name: "smile", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 2000), useCount: 0,
                         favoritedAt: Date(timeIntervalSince1970: 5001)),
        ]

        StubURLProtocol.handler = { _ in (200, self.pngData()) }
        _ = await ManifestTransfer.restore(entries, store: store, downloader: makeDownloader())

        XCTAssertEqual(store.favorites().map(\.id), ["111", "222", "333"])
    }
}
