import XCTest
@testable import StickerKit

/// One paste button serves every format, so the routing decision is the thing
/// that must not regress. These run without a pasteboard, a view controller,
/// or a running extension — which is the whole reason `PasteRouter` was
/// extracted out of `PasteViewController`.
final class PasteRouterTests: XCTestCase {

    func testDiscordMarkupRoutesToMarkup() {
        guard case .markup(let emoji) = PasteRouter.route("<:67:1481800758532903104>") else {
            return XCTFail("expected .markup")
        }
        XCTAssertEqual(emoji.count, 1)
        XCTAssertEqual(emoji[0].id, "1481800758532903104")
    }

    func testTransferPayloadRoutesToPayload() {
        let text = "DSTK1\n7a 01FCY771D800007PQ2DF3GDTN6 RainTime"
        guard case .payload(let emoji) = PasteRouter.route(text) else {
            return XCTFail("expected .payload")
        }
        XCTAssertEqual(emoji.count, 1)
        XCTAssertEqual(emoji[0].source, .sevenTV)
        XCTAssertTrue(emoji[0].isAnimated)
    }

    /// The case that sent us here. Copying an emoji's *link* rather than the
    /// message containing it used to land on "No emoji found."
    func testAnImageLinkRoutesToLink() {
        let text = "https://cdn.discordapp.com/emojis/1481800758532903104.png"
        guard case .link(let link) = PasteRouter.route(text) else {
            return XCTFail("expected .link")
        }
        XCTAssertEqual(link.url.absoluteString, text)
    }

    func testDiscordCopyLinkFormatWithQueryParametersRoutesToLink() {
        let text = "https://cdn.discordapp.com/emojis/1481800758532903104.webp?size=44"
        guard case .link = PasteRouter.route(text) else {
            return XCTFail("expected .link")
        }
    }

    /// A message with emoji *and* a URL imports the emoji, all of them.
    ///
    /// Honest note on what this does and does not prove: reversing the markup
    /// and link branches in `PasteRouter` leaves this green, because
    /// `LinkParser` requires the entire trimmed string to be one http(s) URL
    /// and so cannot claim mixed text at all. The second assertion is what
    /// keeps the test from being decorative — it pins that exact mechanism, so
    /// if `LinkParser` is ever loosened to find URLs inside surrounding text,
    /// this fails and forces the ordering question to be answered again.
    func testMarkupWinsWhenTextContainsBothMarkupAndALink() {
        let text = "look <:67:111> https://example.com/x.png <:yo:222>"
        guard case .markup(let emoji) = PasteRouter.route(text) else {
            return XCTFail("markup must win over a link in the same text")
        }
        XCTAssertEqual(emoji.count, 2, "every emoji in the paste, not just the first")

        // The mechanism, pinned: the same URL alone does route to .link, so
        // the case above is decided by LinkParser's whole-string requirement
        // rather than by nothing at all.
        guard case .link = PasteRouter.route("https://example.com/x.png") else {
            return XCTFail("a bare URL must still route to .link")
        }
    }

    /// A payload also announces itself on line one; markup inside it must not
    /// steal the route, or the source tags would be lost and every 7TV emote
    /// would import as a Discord one.
    ///
    /// Unlike the markup-versus-link case above, this ordering **is**
    /// load-bearing: moving the payload check below the markup check turns
    /// this red.
    func testPayloadWinsOverMarkupInTheSameText() {
        let text = "DSTK1\n7 01GAZ199Z8000FEWHS6AT5QZV0 peepo\n<:67:111>"
        guard case .payload(let emoji) = PasteRouter.route(text) else {
            return XCTFail("payload header must win")
        }
        XCTAssertEqual(emoji[0].source, .sevenTV)
    }

    func testPlainTextRoutesToNone() {
        XCTAssertEqual(PasteRouter.route("just some words"), .none)
    }

    func testEmptyStringRoutesToNone() {
        XCTAssertEqual(PasteRouter.route(""), .none)
    }

    /// A header with no usable lines is not an import, and must not report
    /// success by returning an empty payload.
    func testHeaderOnlyPayloadRoutesToNone() {
        XCTAssertEqual(PasteRouter.route("DSTK1"), .none)
    }

    /// Non-http schemes are not fetchable; routing them to .link would produce
    /// a spinner that never resolves.
    func testANonHttpURLDoesNotRouteToLink() {
        XCTAssertEqual(PasteRouter.route("ftp://example.com/x.png"), .none)
    }
}
