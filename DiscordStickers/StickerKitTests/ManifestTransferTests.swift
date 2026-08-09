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

    func testRestoreRequestsTheRightExtensionFirstTime() async throws {
        // EmojiDownloader already self-heals a wrong flag: a 415 triggers a
        // retry with the opposite extension, so the flags would come back
        // correct even with restore hardcoding isAnimated: false. What that
        // hardcoding actually costs is a second CDN round-trip per
        // misclassified entry — 415 then retry — instead of one correct
        // request. On a large restore that is exactly the request pattern
        // most likely to get an unofficial CDN consumer rate-limited, so
        // this test pins request count and the exact extension requested,
        // not just the flag on the stored entry.
        let entries = [
            StickerEntry(id: "111", name: "cuh", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 1000),
                         useCount: 0, favoritedAt: nil, isAnimated: true),
            StickerEntry(id: "222", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 2000),
                         useCount: 0, favoritedAt: nil, isAnimated: false),
        ]

        StubURLProtocol.handler = { request in
            switch request.url?.lastPathComponent {
            case "111.gif": return (200, self.temp.makeAnimatedGIFData(frameCount: 6))
            case "222.png": return (200, self.pngData(width: 128))
            default:        return (415, Data())
            }
        }

        _ = await ManifestTransfer.restore(entries, store: store,
                                           downloader: makeDownloader())

        let byID = Dictionary(uniqueKeysWithValues: store.all().map { ($0.id, $0) })
        XCTAssertEqual(byID["111"]?.isAnimated, true)
        XCTAssertEqual(byID["222"]?.isAnimated, false)
        XCTAssertEqual(store.all().count, 2)

        // What this really guards is that `isAnimated` survives a backup and
        // is *used*: the animated sticker must be fetched as `.gif` and must
        // never be fetched as `.png`, because a `.png` response for an
        // animated emoji is a silently flattened image.
        //
        // It previously also asserted "one request per sticker, no retries".
        // That efficiency no longer holds and should not: the animated format
        // is now tried first for everything, so a genuinely static sticker
        // costs a 415 and one retry. A duplicate round trip on a restore is
        // worth far less than a permanently frozen sticker.
        let requestedPaths = StubURLProtocol.requestedURLs.map(\.lastPathComponent)
        XCTAssertTrue(requestedPaths.contains("111.gif"))
        XCTAssertFalse(requestedPaths.contains("111.png"),
                       "an animated sticker must never be fetched as .png")
        XCTAssertEqual(requestedPaths.filter { $0.hasPrefix("111") }.count, 1,
                       "a correct animated flag still saves the retry")
    }

    func testRestoreDoesNotRequestContentHashedStickersFromDiscord() async throws {
        // A `sha256-…` id names a link or photo import: bytes that only
        // ever existed on this device. Requesting it from Discord's CDN
        // would hit an object that never existed there, and the 404 would
        // misleadingly read as "Discord deleted this" rather than "this
        // was never recoverable."
        StubURLProtocol.handler = { _ in (200, self.pngData()) }

        let entries = [
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 1000), useCount: 0),
            StickerEntry(id: "sha256-abcdef0123456789", name: "link import",
                         source: .link,
                         addedAt: Date(timeIntervalSince1970: 2000), useCount: 0),
        ]

        let outcome = await ManifestTransfer.restore(
            entries, store: store, downloader: makeDownloader()
        )

        // The point is *which* ids are requested, not how many times. The
        // content-hashed entry must produce no request at all; the Discord one
        // is tried as `.gif` first, as everything now is.
        let requested = StubURLProtocol.requestedURLs.map(\.lastPathComponent)
        XCTAssertTrue(requested.allSatisfy { $0.hasPrefix("111.") },
                      "a sha256- id has no remote origin and must not be fetched")
        XCTAssertEqual(requested.first, "111.gif")
        XCTAssertTrue(outcome.missing.contains("sha256-abcdef0123456789"))
    }

    func testRestorePreservesEveryFieldOfAFullyPopulatedEntry() async throws {
        // favoritedAt, then isAnimated, then source, then addedAt — four
        // fields have been lost on this path one at a time, each caught
        // only after the fact by its own dedicated test. This test builds
        // an entry with every field set to a distinctive non-default value
        // and asserts each one survives restore individually, so a failure
        // names exactly which field was lost. A new StickerEntry field must
        // either be carried through StickerStore.restoreMetadata(from:) or
        // be explicitly excluded here with a stated reason.
        let original = StickerEntry(
            id: "01G3WEGZN0000ET2J0MQP5YJ0G",
            name: "GAMBA",
            source: .sevenTV,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            useCount: 42,
            favoritedAt: Date(timeIntervalSince1970: 1_700_000_500),
            isAnimated: true
        )

        let sourceStore = try StickerStore(root: try TempDirectory().url, writeDebounce: 0)
        try sourceStore.add(original, movingFileFrom: try temp.makePNG(named: "seed.png"))
        let entries = ManifestTransfer.parseImport(ManifestTransfer.export(from: sourceStore))

        StubURLProtocol.handler = { _ in
            (200, self.temp.makeAnimatedGIFData(frameCount: 6))
        }

        _ = await ManifestTransfer.restore(entries, store: store, downloader: makeDownloader())

        let restored = try XCTUnwrap(store.all().first { $0.id == original.id })

        XCTAssertEqual(restored.id, original.id, "id was lost")
        XCTAssertEqual(restored.name, original.name, "name was lost")
        XCTAssertEqual(restored.source, original.source, "source was lost")
        XCTAssertEqual(restored.isAnimated, original.isAnimated, "isAnimated was lost")
        XCTAssertEqual(restored.useCount, original.useCount, "useCount was lost")
        XCTAssertEqual(restored.favoritedAt, original.favoritedAt, "favoritedAt was lost")
        XCTAssertEqual(restored.addedAt, original.addedAt, "addedAt was lost")
    }

    func testRestoreRequestsSevenTVEmotesFromSevenTV() async throws {
        let entries = [
            StickerEntry(id: "01G3WEGZN0000ET2J0MQP5YJ0G", name: "GAMBA",
                         source: .sevenTV,
                         addedAt: Date(timeIntervalSince1970: 1000),
                         useCount: 0),
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 2000),
                         useCount: 0),
        ]

        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await ManifestTransfer.restore(entries, store: store,
                                           downloader: makeDownloader())

        let hosts = Set(StubURLProtocol.requestedURLs.compactMap(\.host))
        XCTAssertEqual(hosts, ["cdn.7tv.app", "cdn.discordapp.com"],
                       "each sticker must be fetched from its own service")
        XCTAssertEqual(store.all().count, 2)
    }
}
