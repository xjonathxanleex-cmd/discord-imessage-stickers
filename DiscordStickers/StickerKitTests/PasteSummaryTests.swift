import XCTest
@testable import StickerKit

final class PasteSummaryTests: XCTestCase {

    func testPayloadAndMarkupAreDistinguishedByTheirFirstLine() {
        // The paste flow must route on content, never on a user choice.
        let payload = "DSTK1\nd 111 wave"
        let markup = "<:wave:111> <:smile:222>"

        XCTAssertTrue(TransferPayloadParser.looksLikePayload(payload))
        XCTAssertFalse(TransferPayloadParser.looksLikePayload(markup))

        XCTAssertEqual(TransferPayloadParser.parse(payload).count, 1)
        XCTAssertEqual(EmojiMarkupParser.parse(markup).count, 2)

        // Each parser must ignore the other's format outright, so a
        // misrouted paste yields nothing rather than something wrong.
        XCTAssertTrue(TransferPayloadParser.parse(markup).isEmpty)
        XCTAssertTrue(EmojiMarkupParser.parse(payload).isEmpty)
    }

    private func outcome(added: Int = 0, present: Int = 0,
                         missing: Int = 0, unusable: Int = 0) -> DownloadOutcome {
        func ids(_ n: Int, _ prefix: String) -> [String] {
            (0..<n).map { "\(prefix)\($0)" }
        }
        return DownloadOutcome(
            added: ids(added, "a"), alreadyPresent: ids(present, "p"),
            missing: ids(missing, "m"), unusable: ids(unusable, "u")
        )
    }

    func testCleanBatchMentionsOnlyAdditions() {
        XCTAssertEqual(
            PasteViewController.summary(for: outcome(added: 12)),
            "Added 12 stickers."
        )
    }

    func testSingularGrammar() {
        XCTAssertEqual(
            PasteViewController.summary(for: outcome(added: 1, missing: 1)),
            "Added 1 sticker, 1 no longer exists."
        )
    }

    func testPartialBatchReportsEveryNonZeroBucket() {
        XCTAssertEqual(
            PasteViewController.summary(
                for: outcome(added: 9, present: 35, missing: 2, unusable: 1)
            ),
            "Added 9 stickers, 35 already saved, 2 no longer exist, 1 couldn't be used."
        )
    }

    func testEmptyOutcomeStillReadsAsASentence() {
        XCTAssertEqual(PasteViewController.summary(for: outcome()), "Nothing to add.")
    }
}
