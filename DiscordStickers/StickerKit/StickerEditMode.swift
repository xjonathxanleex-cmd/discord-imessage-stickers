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
/// its density and every target is a comfortable size.
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

    /// The title the toggle should show, given which mode it controls.
    /// Entering either mode turns that button into Done, so there is always an
    /// obvious way out and never two active modes at once.
    public func buttonTitle(for controlled: StickerEditMode) -> String {
        self == controlled ? "Done" : controlled.defaultTitle
    }

    private var defaultTitle: String {
        switch self {
        case .off:       return ""
        case .favorites: return "Edit"
        case .delete:    return "Delete"
        }
    }
}
