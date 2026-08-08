import Foundation

/// Which editing affordance the grid is currently offering, if any.
///
/// This replaced a plain `isEditingStickers: Bool` after device testing found
/// the two-button edit mode physically unusable. The grid sizes cells at
/// `max(4, width / 70)` columns, which on a real iPhone is **six columns of
/// roughly 63pt**. A star and an × of 32pt each is 64pt of controls in a 63pt
/// cell: they overlapped, and both sat under the 44pt minimum besides.
///
/// Showing one affordance at a time is what makes the arithmetic work. A
/// single 44pt button fits a 63pt cell with room to spare, so the grid keeps
/// its density and every target is a comfortable size. Which affordance is
/// showing is chosen by a scope bar directly above the grid.
///
/// The safety property that mattered on device — tapping a sticker must not
/// send it while editing — holds for `.favorites` and `.delete` alike, so it
/// is expressed once here as `disablesSending` rather than re-derived at each
/// call site.
public enum StickerEditMode: Equatable, CaseIterable {

    /// Normal browsing. Tapping sends, dragging peels.
    case off

    /// Cells show a star. Tapping it favorites or unfavorites.
    case favorites

    /// Cells show an ×. Tapping it deletes.
    case delete

    /// True in every editing mode. `MSStickerView` owns tap and
    /// long-press-drag and exposes no callbacks, so edit mode disables its
    /// interaction outright rather than competing for those gestures.
    public var disablesSending: Bool { self != .off }

    /// One button turns editing on and off; a scope bar above the grid picks
    /// which kind. An earlier build put Edit and Delete side by side in the
    /// search row, which worked but asked the toolbar to carry a distinction
    /// that belongs next to the thing being edited.
    public var editButtonTitle: String { self == .off ? "Edit" : "Done" }

    /// Whether the scope bar should be on screen at all. It is meaningless
    /// outside editing, and showing a disabled one would just be clutter.
    public var showsScopeBar: Bool { self != .off }

    // MARK: - Scope bar

    /// Segment titles, in order. The single source for both the control's
    /// construction and the index mapping below, so they cannot disagree.
    public static let scopeTitles = ["Favorite", "Delete"]

    /// Which segment is selected, or nil when not editing.
    public var scopeIndex: Int? {
        switch self {
        case .off:       return nil
        case .favorites: return 0
        case .delete:    return 1
        }
    }

    /// The mode a scope selection means. An out-of-range index falls back to
    /// `.favorites` rather than `.delete`: if this is ever reached with an
    /// unexpected value, the harmless mode is the right place to land.
    public static func mode(forScopeIndex index: Int) -> StickerEditMode {
        index == 1 ? .delete : .favorites
    }

    /// The mode the Edit button enters from `.off`.
    ///
    /// Always `.favorites`, never the last one used. Editing must not begin
    /// armed to delete — a tap landing on a sticker the moment the grid enters
    /// edit mode should cost a star, not the sticker.
    public static let entryMode = StickerEditMode.favorites
}
