import XCTest
@testable import StickerKit

final class StickerEntryTests: XCTestCase {

    func testRoundTripsThroughJSONWithISO8601Dates() throws {
        let entry = StickerEntry(
            id: "823847191234",
            name: "blobcatcozy",
            source: .pasted,
            addedAt: Date(timeIntervalSince1970: 1_754_604_840),
            useCount: 12
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(StickerEntry.self, from: data), entry)
    }

    func testEncodesTheFieldNamesTheSpecRequires() throws {
        let entry = StickerEntry(
            id: "1", name: "a", source: .pasted,
            addedAt: Date(timeIntervalSince1970: 0), useCount: 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(entry))
                as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["id", "name", "source", "addedAt", "useCount"])
        XCTAssertEqual(json["source"] as? String, "pasted")
        // isAnimated defaults to false and is omitted from the JSON encoding
        XCTAssertNil(json["isAnimated"])
    }

    func testLimitsMatchMSStickerRequirements() {
        XCTAssertEqual(StickerLimits.maxBytes, 500_000)
        XCTAssertEqual(StickerLimits.minDimension, 100)
        XCTAssertEqual(StickerLimits.maxDimension, 618)
    }

    func testBothCanvasSizesAreThemselvesValidStickerDimensions() {
        for size in [StickerLimits.canvasSize, StickerLimits.fallbackCanvasSize] {
            XCTAssertGreaterThanOrEqual(size, StickerLimits.minDimension)
            XCTAssertLessThanOrEqual(size, StickerLimits.maxDimension)
        }
    }

    func testFavoritedAtRoundTripsThroughJSON() throws {
        let entry = StickerEntry(
            id: "823847191234",
            name: "blobcatcozy",
            source: .pasted,
            addedAt: Date(timeIntervalSince1970: 1_754_604_840),
            useCount: 12,
            favoritedAt: Date(timeIntervalSince1970: 1_754_608_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(StickerEntry.self, from: data), entry)
    }

    func testDefaultsToNotFavorited() {
        let entry = StickerEntry(id: "1", name: "a", source: .pasted,
                                 addedAt: Date(), useCount: 0)
        XCTAssertNil(entry.favoritedAt)
    }

    func testManifestWrittenBeforeFavoritesStillDecodes() throws {
        // Exactly the shape manifest.json had before this change. This is the
        // test that protects stickers already on the user's device: Swift's
        // synthesized Codable uses decodeIfPresent for optionals, so a missing
        // key must decode as nil rather than throwing.
        let legacyJSON = """
        [{"addedAt":"2026-08-07T22:14:00Z","id":"823847191234",\
        "name":"blobcatcozy","source":"pasted","useCount":12}]
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([StickerEntry].self,
                                         from: Data(legacyJSON.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "823847191234")
        XCTAssertEqual(entries[0].useCount, 12)
        XCTAssertNil(entries[0].favoritedAt)
    }

    func testIsAnimatedRoundTripsThroughJSON() throws {
        let entry = StickerEntry(
            id: "1229610158183678072",
            name: "cuh",
            source: .pasted,
            addedAt: Date(timeIntervalSince1970: 1_754_604_840),
            useCount: 3,
            favoritedAt: nil,
            isAnimated: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(StickerEntry.self, from: data), entry)
    }

    func testDefaultsToNotAnimated() {
        let entry = StickerEntry(id: "1", name: "a", source: .pasted,
                                 addedAt: Date(), useCount: 0)
        XCTAssertFalse(entry.isAnimated)
    }

    func testManifestWrittenBeforeAnimationStillDecodes() throws {
        // The shape manifest.json had before this change — favoritedAt was
        // already optional, but isAnimated did not exist at all. This is the
        // test that protects stickers already on the user's device.
        let legacyJSON = """
        [{"addedAt":"2026-08-07T22:14:00Z","id":"823847191234",\
        "name":"blobcatcozy","source":"pasted","useCount":12}]
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([StickerEntry].self,
                                         from: Data(legacyJSON.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].useCount, 12)
        XCTAssertNil(entries[0].favoritedAt)
        XCTAssertFalse(entries[0].isAnimated)
    }

    func testAnimatedConstantsAreValidStickerDimensions() {
        XCTAssertGreaterThanOrEqual(StickerLimits.animatedCanvasSize,
                                    StickerLimits.minDimension)
        XCTAssertLessThanOrEqual(StickerLimits.animatedCanvasSize,
                                 StickerLimits.maxDimension)
        // Animated stickers pay for canvas size in file bytes as well as
        // memory, once per frame — so their canvas must be smaller than the
        // static one, not merely valid.
        XCTAssertLessThan(StickerLimits.animatedCanvasSize,
                          StickerLimits.canvasSize)
        XCTAssertGreaterThan(StickerLimits.maxAnimatedFrames, 1)
    }

    func testAllStickerSourcesRoundTripThroughJSON() throws {
        // Cases may be added but never renamed or removed: StickerSource is
        // String-raw-valued, so an unknown case fails to decode the entire
        // entry, silently losing a sticker the user already had.
        for source in [StickerSource.pasted, .server, .photo, .link] {
            let entry = StickerEntry(id: "1", name: "a", source: source,
                                     addedAt: Date(timeIntervalSince1970: 0),
                                     useCount: 0)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let decoded = try decoder.decode(
                StickerEntry.self, from: try encoder.encode(entry)
            )
            XCTAssertEqual(decoded.source, source)
        }
    }

    func testStickerSourceRawValuesAreStable() {
        // These strings are written into manifest.json on the user's device.
        // Changing one orphans every sticker already stored with it.
        XCTAssertEqual(StickerSource.pasted.rawValue, "pasted")
        XCTAssertEqual(StickerSource.server.rawValue, "server")
        XCTAssertEqual(StickerSource.photo.rawValue, "photo")
        XCTAssertEqual(StickerSource.link.rawValue, "link")
    }
}
