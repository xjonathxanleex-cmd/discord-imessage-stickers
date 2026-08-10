import XCTest
@testable import StickerKit

/// The page's address is defined once, so the drawer's first-run text and the
/// host app's link cannot drift apart.
final class CompanionPageTests: XCTestCase {

    func testTheURLIsHTTPSSoItIsReachableFromAPhone() {
        XCTAssertEqual(CompanionPage.url.scheme, "https")
        XCTAssertFalse(CompanionPage.url.host?.isEmpty ?? true)
    }

    /// Shown without a scheme in the extension, where it is read off a screen
    /// and typed on a computer rather than tapped.
    func testDisplayTextDropsTheSchemeButKeepsThePath() {
        XCTAssertFalse(CompanionPage.displayText.contains("https://"))
        XCTAssertTrue(CompanionPage.displayText.contains(
            CompanionPage.url.host ?? "impossible"))
    }

    /// The first-run text is the only place most people will ever see the
    /// address, so it has to actually contain it.
    func testFirstRunTextNamesThePageAndThePasteButton() {
        XCTAssertTrue(
            StickerGridViewController.firstRunText.contains(CompanionPage.displayText),
            "the first-run message must carry the address")
        XCTAssertTrue(StickerGridViewController.firstRunText.contains("Paste Emoji"),
                      "and the button it is telling people to tap")
    }

    /// Wording must not assume the drawer is expanded or a tab is selected,
    /// the way the favorites message has to.
    func testTheTwoEmptyMessagesAreDifferent() {
        XCTAssertNotEqual(StickerGridViewController.firstRunText,
                          StickerGridViewController.favoritesEmptyText)
        XCTAssertTrue(StickerGridViewController.favoritesEmptyText.contains("star"))
    }
}
