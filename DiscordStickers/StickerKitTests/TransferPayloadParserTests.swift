import XCTest
@testable import StickerKit

final class TransferPayloadParserTests: XCTestCase {

    private let valid = """
    DSTK1
    d 1481800758532903104 67
    d 1095953169969860649 NOWAY
    7 01G3WEGZN0000ET2J0MQP5YJ0G GAMBA
    """

    func testParsesEveryLine() {
        let emoji = TransferPayloadParser.parse(valid)

        XCTAssertEqual(emoji.map(\.id), [
            "1481800758532903104",
            "1095953169969860649",
            "01G3WEGZN0000ET2J0MQP5YJ0G",
        ])
        XCTAssertEqual(emoji.map(\.name), ["67", "NOWAY", "GAMBA"])
    }

    func testMapsSourceTags() {
        let emoji = TransferPayloadParser.parse(valid)
        XCTAssertEqual(emoji.map(\.source), [.pasted, .pasted, .sevenTV])
    }

    func testRejectsTextWithoutTheHeader() {
        XCTAssertTrue(TransferPayloadParser.parse(
            "d 111 wave\n7 222 GAMBA"
        ).isEmpty)
        XCTAssertTrue(TransferPayloadParser.parse("").isEmpty)
        XCTAssertTrue(TransferPayloadParser.parse("hello").isEmpty)
    }

    func testRejectsAWrongHeaderVersion() {
        // A future DSTK2 must not be half-parsed as DSTK1.
        XCTAssertTrue(TransferPayloadParser.parse(
            "DSTK2\nd 111 wave"
        ).isEmpty)
    }

    func testHeaderOnlyPayloadYieldsNothing() {
        XCTAssertTrue(TransferPayloadParser.parse("DSTK1").isEmpty)
        XCTAssertTrue(TransferPayloadParser.parse("DSTK1\n").isEmpty)
    }

    func testNamesMayContainSpaces() {
        // The id never contains a space, so a two-way split is unambiguous
        // and the remainder is the name.
        let emoji = TransferPayloadParser.parse("DSTK1\nd 111 happy cat face")
        XCTAssertEqual(emoji.first?.name, "happy cat face")
    }

    func testSkipsMalformedLinesWithoutLosingGoodOnes() {
        // One bad line must not cost the other two hundred.
        let emoji = TransferPayloadParser.parse("""
        DSTK1
        d 111 good
        garbage
        d
        x 333 unknown-tag
        7 444 alsogood
        """)

        XCTAssertEqual(emoji.map(\.name), ["good", "alsogood"])
    }

    func testSkipsBlankLines() {
        let emoji = TransferPayloadParser.parse("DSTK1\n\nd 111 wave\n\n")
        XCTAssertEqual(emoji.count, 1)
    }

    func testToleratesCarriageReturns() {
        // Text copied from a browser on Windows arrives CRLF-terminated.
        let emoji = TransferPayloadParser.parse("DSTK1\r\nd 111 wave\r\n")
        XCTAssertEqual(emoji.first?.name, "wave")
    }

    func testToleratesLeadingAndTrailingWhitespace() {
        let emoji = TransferPayloadParser.parse("  \n DSTK1 \n d 111 wave \n")
        XCTAssertEqual(emoji.first?.name, "wave")
    }

    func testDedupesByIDKeepingFirstOccurrence() {
        // Chunked payloads overlap by design, and the same emoji may appear
        // in two scans. Matches EmojiMarkupParser's policy exactly.
        let emoji = TransferPayloadParser.parse("""
        DSTK1
        d 111 first
        d 222 other
        d 111 second
        """)

        XCTAssertEqual(emoji.map(\.name), ["first", "other"])
    }

    func testAnimationIsNotEncodedInThePayload() {
        // The payload carries no animation flag; the downloader's 415 retry
        // and 7TV's own metadata settle it. Every parsed emoji starts static.
        XCTAssertFalse(TransferPayloadParser.parse(valid).contains { $0.isAnimated })
    }

    func testLooksLikePayloadRecognisesTheHeader() {
        XCTAssertTrue(TransferPayloadParser.looksLikePayload(valid))
        XCTAssertTrue(TransferPayloadParser.looksLikePayload("  DSTK1\nd 1 a"))
        XCTAssertFalse(TransferPayloadParser.looksLikePayload("<:wave:111>"))
        XCTAssertFalse(TransferPayloadParser.looksLikePayload(""))
    }
}
