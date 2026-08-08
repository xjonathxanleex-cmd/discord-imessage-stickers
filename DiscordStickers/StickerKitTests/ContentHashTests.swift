import XCTest
@testable import StickerKit

final class ContentHashTests: XCTestCase {

    func testSameBytesProduceTheSameID() {
        let data = Data("hello".utf8)
        XCTAssertEqual(ContentHash.id(for: data), ContentHash.id(for: data))
    }

    func testDifferentBytesProduceDifferentIDs() {
        XCTAssertNotEqual(ContentHash.id(for: Data("hello".utf8)),
                          ContentHash.id(for: Data("hello!".utf8)))
    }

    func testIDIsPrefixedAndFixedLength() {
        let id = ContentHash.id(for: Data("hello".utf8))
        XCTAssertTrue(id.hasPrefix("sha256-"))
        // "sha256-" plus 64 hex characters.
        XCTAssertEqual(id.count, 71)
        XCTAssertTrue(id.dropFirst(7).allSatisfy {
            $0.isHexDigit && !$0.isUppercase
        })
    }

    func testKnownVectorSoTheHashIsActuallySHA256() {
        // The SHA-256 of "abc" is a published constant. Without this the
        // tests above would pass for any deterministic function, including
        // a broken one.
        XCTAssertEqual(
            ContentHash.id(for: Data("abc".utf8)),
            "sha256-ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testEmptyDataStillProducesAnID() {
        XCTAssertTrue(ContentHash.id(for: Data()).hasPrefix("sha256-"))
    }
}
