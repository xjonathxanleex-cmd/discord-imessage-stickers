import XCTest
@testable import StickerKit

/// Parses a payload captured verbatim from the desktop companion page, driven
/// in a real browser.
///
/// `TransferPayloadParserTests` proves the parser handles payloads *this
/// project wrote by hand*. That is a weaker claim than it looks: a hand-written
/// fixture encodes what the author believed the producer emits, so producer and
/// consumer can agree perfectly with each other and both be wrong about the
/// format. This fixture came out of the page itself.
///
/// It is the check that would have caught the defect this feature nearly
/// shipped with — a `DSTK1` format carrying no animation flag, which imported
/// every animated 7TV emote as a permanent still frame while reporting success
/// at every layer.
///
/// If the page's output ever changes shape, re-capture this string rather than
/// editing it to fit. Its value lies entirely in not being written by hand.
final class ProducedPayloadTests: XCTestCase {

    /// Captured 2026-08-08 from `web/index.html`: two Discord emoji pasted as
    /// markup, two 7TV emotes pasted as CDN links, two renamed inline —
    /// exercising all four tags plus a name containing a space.
    private let captured = """
    DSTK1
    d 1481800758532903104 67
    da 1095953169969860649 catJAM
    7 01GAZ199Z8000FEWHS6AT5QZV0 peepo Happy
    7a 01FCY771D800007PQ2DF3GDTN6 RainTime
    """

    func testPageOutputParsesToAllFourTagCombinations() {
        let parsed = TransferPayloadParser.parse(captured)

        XCTAssertEqual(parsed.count, 4)

        XCTAssertEqual(parsed[0].id, "1481800758532903104")
        XCTAssertEqual(parsed[0].name, "67")
        XCTAssertEqual(parsed[0].source, .pasted)
        XCTAssertFalse(parsed[0].isAnimated)

        XCTAssertEqual(parsed[1].id, "1095953169969860649")
        XCTAssertEqual(parsed[1].name, "catJAM")
        XCTAssertEqual(parsed[1].source, .pasted)
        XCTAssertTrue(parsed[1].isAnimated)

        XCTAssertEqual(parsed[2].id, "01GAZ199Z8000FEWHS6AT5QZV0")
        XCTAssertEqual(parsed[2].source, .sevenTV)
        XCTAssertFalse(parsed[2].isAnimated)

        XCTAssertEqual(parsed[3].id, "01FCY771D800007PQ2DF3GDTN6")
        XCTAssertEqual(parsed[3].name, "RainTime")
        XCTAssertEqual(parsed[3].source, .sevenTV)
        XCTAssertTrue(parsed[3].isAnimated)
    }

    /// The name column runs to end of line precisely so a user can rename an
    /// emote to something with a space in it. A parser that split on every
    /// space would truncate this to "peepo" and still look plausible.
    func testInlineRenameWithASpaceSurvivesTheRoundTrip() {
        let parsed = TransferPayloadParser.parse(captured)
        XCTAssertEqual(parsed[2].name, "peepo Happy")
    }

    /// The page recognises its own output without the user choosing a format.
    func testPageOutputIsRecognisedAsAPayload() {
        XCTAssertTrue(TransferPayloadParser.looksLikePayload(captured))
    }
}
