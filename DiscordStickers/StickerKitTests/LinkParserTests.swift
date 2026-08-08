import XCTest
@testable import StickerKit

final class LinkParserTests: XCTestCase {

    func testParsesADiscordEmojiURLAndNamesItByID() {
        let link = LinkParser.parse(
            "https://cdn.discordapp.com/emojis/1481800758532903104.png"
        )
        XCTAssertEqual(link?.suggestedName, "1481800758532903104")
        XCTAssertFalse(link?.isAnimated ?? true)
    }

    func testMarksADiscordGIFEmojiAsAnimated() {
        let link = LinkParser.parse(
            "https://cdn.discordapp.com/emojis/1229610158183678072.gif"
        )
        XCTAssertEqual(link?.suggestedName, "1229610158183678072")
        XCTAssertTrue(link?.isAnimated ?? false)
    }

    func testNamesAnArbitraryURLByItsFilename() {
        let link = LinkParser.parse("https://example.com/img/party-parrot.png")
        XCTAssertEqual(link?.suggestedName, "party-parrot")
    }

    func testIgnoresQueryAndFragmentWhenNaming() {
        let link = LinkParser.parse(
            "https://example.com/a/cat.png?width=200&v=3#top"
        )
        XCTAssertEqual(link?.suggestedName, "cat")
    }

    func testPercentDecodesTheFilename() {
        let link = LinkParser.parse("https://example.com/happy%20cat.png")
        XCTAssertEqual(link?.suggestedName, "happy cat")
    }

    func testFallsBackToStickerWhenThereIsNoFilename() {
        XCTAssertEqual(LinkParser.parse("https://example.com/")?.suggestedName,
                       "sticker")
        XCTAssertEqual(LinkParser.parse("https://example.com")?.suggestedName,
                       "sticker")
    }

    func testTrimsSurroundingWhitespace() {
        let link = LinkParser.parse("  https://example.com/cat.png\n")
        XCTAssertEqual(link?.url.absoluteString,
                       "https://example.com/cat.png")
    }

    func testAcceptsAnyImageURLNotJustKnownHosts() {
        // Restricting to an allowlist would be a rule users must learn and
        // will get wrong. With a naming step in place there is no reason to.
        XCTAssertNotNil(LinkParser.parse("https://some-random-site.example/x.webp"))
    }

    func testRejectsNonHTTPSchemes() {
        XCTAssertNil(LinkParser.parse("ftp://example.com/cat.png"))
        XCTAssertNil(LinkParser.parse("file:///etc/passwd"))
        XCTAssertNil(LinkParser.parse("javascript:alert(1)"))
    }

    func testRejectsTextThatIsNotAURL() {
        XCTAssertNil(LinkParser.parse("just some words"))
        XCTAssertNil(LinkParser.parse(""))
        XCTAssertNil(LinkParser.parse("   "))
    }

    func testAcceptsPlainHTTP() {
        XCTAssertNotNil(LinkParser.parse("http://example.com/cat.png"))
    }

    func testDoesNotRequireAnImageExtension() {
        // Plenty of image URLs end in an id or a route rather than .png.
        // The bytes decide whether it is an image, not the path.
        XCTAssertNotNil(LinkParser.parse("https://example.com/i/abc123"))
    }
}
