import XCTest
@testable import StickerKit

final class EmojiMarkupParserTests: XCTestCase {

    func testParsesSingleStaticEmoji() {
        let result = EmojiMarkupParser.parse("<:blobcatcozy:823847191234>")
        XCTAssertEqual(result, [
            ParsedEmoji(id: "823847191234", name: "blobcatcozy", isAnimated: false)
        ])
    }

    func testParsesAnimatedEmoji() {
        let result = EmojiMarkupParser.parse("<a:blobdance:111222333444>")
        XCTAssertEqual(result, [
            ParsedEmoji(id: "111222333444", name: "blobdance", isAnimated: true)
        ])
    }

    func testParsesAdjacentEmojiWithNoSeparator() {
        let result = EmojiMarkupParser.parse("<:one:111><:two:222><:three:333>")
        XCTAssertEqual(result.map(\.name), ["one", "two", "three"])
    }

    func testExtractsEmojiEmbeddedInChatText() {
        let result = EmojiMarkupParser.parse("hey <:wave:555> how are you <:smile:666> ok")
        XCTAssertEqual(result.map(\.name), ["wave", "smile"])
    }

    func testDedupesByIDKeepingFirstOccurrenceAndOrder() {
        let result = EmojiMarkupParser.parse("<:a:111><:b:222><:a:111>")
        XCTAssertEqual(result.map(\.name), ["a", "b"])
    }

    func testAcceptsUnderscoresAndDigitsInNames() {
        let result = EmojiMarkupParser.parse("<:blob_cat_2:999>")
        XCTAssertEqual(result.first?.name, "blob_cat_2")
    }

    func testIgnoresMalformedMarkup() {
        XCTAssertTrue(EmojiMarkupParser.parse("<::>").isEmpty)
        XCTAssertTrue(EmojiMarkupParser.parse("<:noid:>").isEmpty)
        XCTAssertTrue(EmojiMarkupParser.parse("<:123>").isEmpty)
    }

    func testReturnsEmptyForEmptyString() {
        XCTAssertTrue(EmojiMarkupParser.parse("").isEmpty)
    }

    func testDoesNotMatchUnicodeEmoji() {
        XCTAssertTrue(EmojiMarkupParser.parse("hello 🙂 there 🎉").isEmpty)
    }

    func testMixedUnicodeAndCustomEmoji() {
        let result = EmojiMarkupParser.parse("🙂 <:custom:777> 🎉")
        XCTAssertEqual(result.map(\.name), ["custom"])
    }
}
