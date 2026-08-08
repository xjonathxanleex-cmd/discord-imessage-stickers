import XCTest
@testable import StickerKit

/// The safety property here was verified on a real device — tapping a sticker
/// while editing must not send it — so it is pinned by tests rather than left
/// to be re-derived at each call site.
final class StickerEditModeTests: XCTestCase {

    /// Iterates `allCases` rather than listing modes, so a fourth mode added
    /// later cannot ship without deciding this question for it.
    func testEveryEditingModeDisablesSending() {
        for mode in StickerEditMode.allCases {
            XCTAssertEqual(mode.disablesSending, mode != .off,
                           "mode \(mode) must disable sending unless it is .off")
        }
    }

    func testOffAlonePermitsSending() {
        XCTAssertFalse(StickerEditMode.off.disablesSending)
    }

    func testTheActiveModesButtonReadsDone() {
        XCTAssertEqual(StickerEditMode.favorites.buttonTitle(for: .favorites), "Done")
        XCTAssertEqual(StickerEditMode.delete.buttonTitle(for: .delete), "Done")
    }

    /// The reason two separate modes are safe: entering one visibly leaves the
    /// other, so the two can never both read as active and there is always
    /// exactly one Done to tap.
    func testTheInactiveModesButtonKeepsItsOwnName() {
        XCTAssertEqual(StickerEditMode.favorites.buttonTitle(for: .delete), "Delete")
        XCTAssertEqual(StickerEditMode.delete.buttonTitle(for: .favorites), "Edit")
    }

    func testNeitherButtonReadsDoneWhenEditingIsOff() {
        XCTAssertEqual(StickerEditMode.off.buttonTitle(for: .favorites), "Edit")
        XCTAssertEqual(StickerEditMode.off.buttonTitle(for: .delete), "Delete")
    }

    /// Exactly one Done at a time, checked over every combination rather than
    /// the three spelled out above.
    func testAtMostOneButtonEverReadsDone() {
        for mode in StickerEditMode.allCases {
            let dones = [StickerEditMode.favorites, .delete]
                .filter { mode.buttonTitle(for: $0) == "Done" }
            XCTAssertLessThanOrEqual(dones.count, 1, "mode \(mode)")
        }
    }
}
