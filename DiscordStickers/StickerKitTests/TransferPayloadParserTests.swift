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

    func testParsesAnimatedTags() {
        let emoji = TransferPayloadParser.parse("""
        DSTK1
        7a 111 animatedSevenTV
        da 222 animatedDiscord
        7 333 staticSevenTV
        d 444 staticDiscord
        """)

        let byID = Dictionary(uniqueKeysWithValues: emoji.map { ($0.id, $0) })
        XCTAssertEqual(byID["111"]?.isAnimated, true)
        XCTAssertEqual(byID["222"]?.isAnimated, true)
        XCTAssertEqual(byID["333"]?.isAnimated, false)
        XCTAssertEqual(byID["444"]?.isAnimated, false)
    }

    func testAnimatedTagsMapToTheRightSource() {
        let emoji = TransferPayloadParser.parse("""
        DSTK1
        7a 111 animatedSevenTV
        da 222 animatedDiscord
        """)

        let byID = Dictionary(uniqueKeysWithValues: emoji.map { ($0.id, $0) })
        XCTAssertEqual(byID["111"]?.source, .sevenTV)
        XCTAssertEqual(byID["222"]?.source, .pasted)
    }

    func testUnknownTagVariantsAreSkipped() {
        // Only "d", "da", "7", "7a" are recognised. A malformed variant must
        // be dropped without affecting neighbouring good lines.
        let emoji = TransferPayloadParser.parse("""
        DSTK1
        db 111 bad
        7x 222 bad
        a 333 bad
        aa 444 bad
        d 555 good
        """)

        XCTAssertEqual(emoji.map(\.name), ["good"])
    }

    func testStopsAfterTheEmojiCap() {
        // Machine-generated, unlike pasted Discord markup, so it is not
        // bounded by what a human would ever paste by hand.
        var lines = ["DSTK1"]
        for index in 0..<(StickerLimits.maxPayloadEmoji + 50) {
            lines.append("d \(index) emoji\(index)")
        }

        let emoji = TransferPayloadParser.parse(lines.joined(separator: "\n"))

        XCTAssertEqual(emoji.count, StickerLimits.maxPayloadEmoji)
    }

    func testTruncatesOverlongNames() {
        let longName = String(repeating: "x",
                              count: StickerLimits.maxStickerNameLength + 20)

        let emoji = TransferPayloadParser.parse("DSTK1\nd 111 \(longName)")

        XCTAssertEqual(emoji.first?.name.count, StickerLimits.maxStickerNameLength)
    }

    func testLooksLikePayloadRecognisesTheHeader() {
        XCTAssertTrue(TransferPayloadParser.looksLikePayload(valid))
        XCTAssertTrue(TransferPayloadParser.looksLikePayload("  DSTK1\nd 1 a"))
        XCTAssertFalse(TransferPayloadParser.looksLikePayload("<:wave:111>"))
        XCTAssertFalse(TransferPayloadParser.looksLikePayload(""))
    }
}
