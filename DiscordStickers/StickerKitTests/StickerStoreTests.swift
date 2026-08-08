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
                       addedAt: Date = Date(),
                       favoritedAt: Date? = nil) -> StickerEntry {
        StickerEntry(id: id, name: name, source: .pasted,
                     addedAt: addedAt, useCount: useCount,
                     favoritedAt: favoritedAt)
    }

    /// Adds a real file plus its entry, since undo has to restore both.
    @discardableResult
    private func addSticker(to store: StickerStore, id: String,
                            name: String) throws -> StickerEntry {
        let record = entry(id, name: name)
        try store.add(record, movingFileFrom: try temp.makePNG(named: "\(id)-src.png"))
        return record
    }

    private func temporaryRoot() throws -> URL { temp.url }

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

    /// `testCorruptManifestIsQuarantinedAndImagesAreSalvaged` only checks the
    /// salvage that happens in memory on the *second* store. If that store is
    /// killed before it ever flushes (the documented top risk for the
    /// extension: memory-killed before `didResignActive` fires), the salvage
    /// must still be reachable by a *third* store reading whatever is on disk
    /// — which at that point is still just the images, with no manifest at
    /// all, since the second store never wrote one.
    func testSalvagedStickersSurviveASecondLaunchWithoutFlush() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        store.flush()

        try Data("{ not json".utf8)
            .write(to: temp.url.appendingPathComponent("manifest.json"))

        // Second store: performs the salvage (quarantines the broken
        // manifest, rebuilds from images) but is never flushed, so nothing
        // it does reaches disk beyond the quarantine rename.
        _ = try makeStore()

        // Third store: simulates a memory kill between salvage and flush.
        // It reads the manifest-less on-disk state left behind — which must
        // still resolve to the salvaged entry, not an empty store.
        let thirdStore = try makeStore()

        XCTAssertEqual(thirdStore.all().map(\.id), ["111"])
    }

    func testSetFavoriteMarksAndSurvivesReload() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))

        store.setFavorite(true, id: "111")
        store.flush()

        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.favorites().map(\.id), ["111"])
        XCTAssertNotNil(reloaded.all().first?.favoritedAt)
    }

    func testUnfavoriteClearsAndSurvivesReload() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        store.setFavorite(true, id: "111")
        store.setFavorite(false, id: "111")
        store.flush()

        let reloaded = try makeStore()
        XCTAssertTrue(reloaded.favorites().isEmpty)
        XCTAssertNil(reloaded.all().first?.favoritedAt)
        XCTAssertEqual(reloaded.all().count, 1, "unfavoriting must not delete")
    }

    func testFavoritesAreOrderedOldestFirst() throws {
        let store = try makeStore()
        // Explicit timestamps rather than two setFavorite calls: Date() twice
        // in quick succession can produce equal values, which would make this
        // assertion pass or fail by luck.
        try store.add(entry("second", name: "b",
                            favoritedAt: Date(timeIntervalSince1970: 2000)),
                      movingFileFrom: try temp.makePNG(named: "b.png"))
        try store.add(entry("first", name: "a",
                            favoritedAt: Date(timeIntervalSince1970: 1000)),
                      movingFileFrom: try temp.makePNG(named: "a.png"))

        XCTAssertEqual(store.favorites().map(\.id), ["first", "second"])
    }

    func testRefavoritingDoesNotMoveTheStickerOrChangeItsTimestamp() throws {
        let store = try makeStore()
        let original = Date(timeIntervalSince1970: 1000)
        try store.add(entry("first", name: "a", favoritedAt: original),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        try store.add(entry("second", name: "b",
                            favoritedAt: Date(timeIntervalSince1970: 2000)),
                      movingFileFrom: try temp.makePNG(named: "b.png"))

        store.setFavorite(true, id: "first")

        XCTAssertEqual(store.favorites().map(\.id), ["first", "second"])
        XCTAssertEqual(store.favorites().first?.favoritedAt, original)
    }

    func testFavoritesIsEmptyWhenNothingIsFavorited() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))

        XCTAssertTrue(store.favorites().isEmpty)
    }

    func testDeletingAFavoriteRemovesItEverywhere() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        store.setFavorite(true, id: "111")
        let path = store.fileURL(for: "111").path

        try store.delete(id: "111")

        XCTAssertTrue(store.favorites().isEmpty)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFavoritingAnUnknownIDIsIgnored() throws {
        let store = try makeStore()
        store.setFavorite(true, id: "does-not-exist")

        XCTAssertTrue(store.favorites().isEmpty)
        XCTAssertTrue(store.all().isEmpty)
    }

    // MARK: - Undo delete

    /// Delete mode offers no confirmation, deliberately — confirming every tap
    /// while clearing out a dozen stickers is worse than the mistake it
    /// prevents. That trade only holds if the mistake is reversible.
    func testUndoRestoresADeletedSticker() throws {
        let store = try makeStore()
        try addSticker(to: store, id: "a", name: "alpha")

        try store.delete(id: "a")
        XCTAssertFalse(store.contains(id: "a"))
        XCTAssertTrue(store.canUndoDelete)

        let restored = store.undoLastDelete()
        XCTAssertEqual(restored?.id, "a")
        XCTAssertTrue(store.contains(id: "a"))
    }

    /// The image has to come back too. Restoring the entry alone would leave
    /// the manifest naming a file that is gone — the one state this store must
    /// never be in.
    func testUndoRestoresTheImageFileNotJustTheEntry() throws {
        let store = try makeStore()
        try addSticker(to: store, id: "a", name: "alpha")

        try store.delete(id: "a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: "a").path))

        store.undoLastDelete()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: "a").path),
                      "an entry without its image breaks the manifest invariant")
    }

    /// The grid is ordered, so an undo that quietly moved a sticker to the end
    /// would look like a different bug to whoever hit it.
    func testUndoRestoresToTheOriginalPosition() throws {
        let store = try makeStore()
        for id in ["a", "b", "c"] { try addSticker(to: store, id: id, name: id) }

        try store.delete(id: "b")
        store.undoLastDelete()

        XCTAssertEqual(store.all().map(\.id), ["a", "b", "c"])
    }

    func testUndoUnwindsSeveralDeletesInReverseOrder() throws {
        let store = try makeStore()
        for id in ["a", "b", "c"] { try addSticker(to: store, id: id, name: id) }

        try store.delete(id: "a")
        try store.delete(id: "c")

        XCTAssertEqual(store.undoLastDelete()?.id, "c", "most recent first")
        XCTAssertEqual(store.undoLastDelete()?.id, "a")
        XCTAssertEqual(store.all().map(\.id), ["a", "b", "c"])
    }

    func testUndoIsUnavailableWithNothingDeleted() throws {
        let store = try makeStore()
        XCTAssertFalse(store.canUndoDelete)
        XCTAssertNil(store.undoLastDelete())
    }

    func testUndoIsExhaustedAfterUnwindingEverything() throws {
        let store = try makeStore()
        try addSticker(to: store, id: "a", name: "alpha")

        try store.delete(id: "a")
        store.undoLastDelete()

        XCTAssertFalse(store.canUndoDelete)
        XCTAssertNil(store.undoLastDelete())
    }

    /// Each pending undo holds a sticker's image on disk. Unbounded, clearing
    /// out a collection would hold every image twice against a 40-120 MB
    /// ceiling.
    func testUndoDepthIsBounded() throws {
        let store = try makeStore()
        let count = StickerLimits.undoDepth + 5
        for index in 0..<count { try addSticker(to: store, id: "s\(index)", name: "s\(index)") }
        for index in 0..<count { try store.delete(id: "s\(index)") }

        var undone = 0
        while store.undoLastDelete() != nil { undone += 1 }
        XCTAssertEqual(undone, StickerLimits.undoDepth,
                       "the oldest deletes past the cap are gone for real")
    }

    /// The undo stack is in-memory by design, so a new process must not
    /// inherit a trash directory it can never act on.
    func testTrashIsPurgedOnLaunchSoNothingAccumulates() throws {
        let root = try temporaryRoot()
        let first = try StickerStore(root: root, writeDebounce: 0)
        try addSticker(to: first, id: "a", name: "alpha")
        try first.delete(id: "a")
        first.flush()

        let second = try StickerStore(root: root, writeDebounce: 0)
        XCTAssertFalse(second.canUndoDelete, "a fresh process has nothing to undo")

        let trash = root.appendingPathComponent("trash")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        XCTAssertTrue(leftovers.isEmpty, "orphaned trash would grow forever")
    }

}
