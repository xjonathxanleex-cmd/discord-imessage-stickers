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

    // MARK: - The one button

    func testTheEditButtonReadsDoneWhileEditing() {
        XCTAssertEqual(StickerEditMode.favorites.editButtonTitle, "Done")
        XCTAssertEqual(StickerEditMode.delete.editButtonTitle, "Done")
    }

    func testTheEditButtonReadsEditWhenOff() {
        XCTAssertEqual(StickerEditMode.off.editButtonTitle, "Edit")
    }

    /// There is always exactly one way out, from any editing mode.
    func testThereIsAlwaysADoneWhileEditing() {
        for mode in StickerEditMode.allCases where mode != .off {
            XCTAssertEqual(mode.editButtonTitle, "Done", "mode \(mode)")
        }
    }

    // MARK: - The scope bar

    func testTheScopeBarShowsOnlyWhileEditing() {
        for mode in StickerEditMode.allCases {
            XCTAssertEqual(mode.showsScopeBar, mode != .off, "mode \(mode)")
        }
    }

    func testScopeIndexIsNilOffAndSetWhileEditing() {
        XCTAssertNil(StickerEditMode.off.scopeIndex)
        XCTAssertEqual(StickerEditMode.favorites.scopeIndex, 0)
        XCTAssertEqual(StickerEditMode.delete.scopeIndex, 1)
    }

    /// Index and mode must agree in both directions, or selecting a segment
    /// would arm a different mode than the one it highlights — the worst
    /// possible disagreement given one of them deletes.
    func testScopeIndexRoundTripsForEveryEditingMode() {
        for mode in StickerEditMode.allCases where mode != .off {
            let index = try? XCTUnwrap(mode.scopeIndex)
            XCTAssertEqual(StickerEditMode.mode(forScopeIndex: index ?? -1), mode)
        }
    }

    /// Every segment the control actually renders maps to a mode. Derived from
    /// `scopeTitles` rather than hard-coded, so adding a third segment without
    /// extending the mapping fails here instead of silently landing on
    /// Favorite.
    func testEveryRenderedSegmentMapsToADistinctMode() {
        let modes = StickerEditMode.scopeTitles.indices
            .map(StickerEditMode.mode(forScopeIndex:))
        XCTAssertEqual(Set(modes).count, StickerEditMode.scopeTitles.count,
                       "each segment must mean something different")
    }

    /// An unexpected index must land somewhere harmless.
    func testAnOutOfRangeScopeIndexFallsBackToFavourites() {
        XCTAssertEqual(StickerEditMode.mode(forScopeIndex: 99), .favorites)
        XCTAssertEqual(StickerEditMode.mode(forScopeIndex: -1), .favorites)
    }

    /// The property the whole design rests on: a tap landing the instant the
    /// grid enters edit mode costs a star, never a sticker.
    func testEditingNeverBeginsArmedToDelete() {
        XCTAssertNotEqual(StickerEditMode.entryMode, .delete)
        XCTAssertEqual(StickerEditMode.entryMode, .favorites)
        XCTAssertTrue(StickerEditMode.entryMode.disablesSending)
    }
}
