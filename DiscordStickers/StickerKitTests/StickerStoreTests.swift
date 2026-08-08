import XCTest
@testable import StickerKit

final class StickerStoreTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
    }

    private func makeStore() throws -> StickerStore {
        try StickerStore(root: temp.url, writeDebounce: 0)
    }

    private func entry(_ id: String, name: String, useCount: Int = 0,
                       addedAt: Date = Date()) -> StickerEntry {
        StickerEntry(id: id, name: name, source: .pasted,
                     addedAt: addedAt, useCount: useCount)
    }

    func testAddThenReadBack() throws {
        let store = try makeStore()
        let png = try temp.makePNG(named: "a.png")
        try store.add(entry("111", name: "wave"), movingFileFrom: png)

        XCTAssertEqual(store.all().map(\.id), ["111"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.fileURL(for: "111").path)
        )
    }

    func testAddingSameIDTwiceDoesNotDuplicate() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "b.png"))

        XCTAssertEqual(store.all().count, 1)
    }

    func testDeleteRemovesEntryAndFile() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        let path = store.fileURL(for: "111").path

        try store.delete(id: "111")

        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRecordUseIncrementsAndSurvivesReload() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        store.recordUse(id: "111")
        store.recordUse(id: "111")
        store.flush()

        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.all().first?.useCount, 2)
    }

    func testSearchIsCaseInsensitiveSubstringOnName() throws {
        let store = try makeStore()
        try store.add(entry("1", name: "blobcatcozy"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        try store.add(entry("2", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "b.png"))

        XCTAssertEqual(store.search("CATCO").map(\.id), ["1"])
        XCTAssertEqual(store.search("").count, 2)
    }

    func testRecentsSortsByUseCountThenAddedAtAndRespectsLimit() throws {
        let store = try makeStore()
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)

        try store.add(entry("low", name: "low", useCount: 1, addedAt: new),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        try store.add(entry("highOld", name: "ho", useCount: 9, addedAt: old),
                      movingFileFrom: try temp.makePNG(named: "b.png"))
        try store.add(entry("highNew", name: "hn", useCount: 9, addedAt: new),
                      movingFileFrom: try temp.makePNG(named: "c.png"))

        XCTAssertEqual(store.recents().map(\.id), ["highNew", "highOld", "low"])
        XCTAssertEqual(store.recents(limit: 2).count, 2)
    }

    func testContainsReportsMembership() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))

        XCTAssertTrue(store.contains(id: "111"))
        XCTAssertFalse(store.contains(id: "222"))
    }

    func testCorruptManifestIsQuarantinedAndImagesAreSalvaged() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        store.flush()

        try Data("{ not json".utf8)
            .write(to: temp.url.appendingPathComponent("manifest.json"))

        let recovered = try makeStore()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: temp.url.appendingPathComponent("manifest.json.broken").path
        ))
        // The image survives; the name does not.
        XCTAssertEqual(recovered.all().map(\.id), ["111"])
        XCTAssertEqual(recovered.all().first?.name, "111")
    }

    func testEmptyRootStartsEmptyWithoutThrowing() throws {
        XCTAssertTrue(try makeStore().all().isEmpty)
    }
}
