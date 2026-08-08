import XCTest
@testable import StickerKit

final class ManifestTransferTests: XCTestCase {

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
}
