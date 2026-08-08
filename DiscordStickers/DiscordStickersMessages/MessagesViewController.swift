import UIKit
import Messages
import StickerKit

/// Compact mode shows whichever of the three tabs (Favorites, Recent, All) is
/// selected, defaulting to Favorites. Expanded mode adds search, the paste
/// control, and the Edit button.
///
/// The extension owns storage outright: App Groups is unavailable on a free
/// Personal Team, so there is no shared container to read from.
final class MessagesViewController: MSMessagesAppViewController {

    private var store: StickerStore!
    private var downloader: EmojiDownloader!
    private var grid: StickerGridViewController!
    private var paste: PasteViewController!

    private let searchBar = UISearchBar()
    private let tabs = UISegmentedControl(items: ["Favorites", "Recent", "All"])
    private let editButton = UIButton(type: .system)
    private let editScope = UISegmentedControl(items: StickerEditMode.scopeTitles)
    private let scopeRow = UIStackView()
    private let searchRow = UIStackView()
    private let pasteContainer = UIView()
    private let topControls = UIStackView()
    private var fatalLabel: UILabel?

    /// False until the UI has been built, so a retry can tell "never
    /// succeeded" from "already running" and never builds twice.
    private var isReady = false

    override func viewDidLoad() {
        super.viewDidLoad()
        prepareIfNeeded()
    }

    /// Builds the UI, retrying storage setup on every attempt until it works.
    ///
    /// This used to run once, in `viewDidLoad`, and give up permanently on a
    /// failed `StickerStore` init. That is a worse failure than it looks: the
    /// view controller instance outlives any single appearance of the drawer,
    /// so one transient failure left a dead drawer that **stayed** dead for
    /// the life of the extension process — no amount of closing and reopening
    /// the drawer would fix it, only force-quitting Messages.
    ///
    /// Called again from `willBecomeActive`, so the drawer repairs itself the
    /// next time it is opened.
    private func prepareIfNeeded() {
        guard !isReady else { return }

        let root = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]

        do {
            store = try StickerStore(root: root)
        } catch {
            showFatal("Couldn't open sticker storage. Close and reopen this drawer.")
            return
        }

        clearFatal()
        downloader = EmojiDownloader(store: store)
        buildUI()
        isReady = true
        applyPresentationStyle(presentationStyle)
    }

    private func buildUI() {
        // Favorites when there is something in it, otherwise All — so a
        // first-run user sees exactly what they saw before this feature.
        tabs.selectedSegmentIndex = store.favorites().isEmpty ? 2 : 0
        tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        searchBar.placeholder = "Search emoji"
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false

        editButton.setTitle("Edit", for: .normal)
        editButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        editButton.setContentHuggingPriority(.required, for: .horizontal)
        editButton.addTarget(self, action: #selector(editTapped),
                             for: .touchUpInside)

        editScope.selectedSegmentIndex = 0
        editScope.addTarget(self, action: #selector(editScopeChanged),
                            for: .valueChanged)
        // Destructive tint only on the segment that deletes, so the armed
        // state is visible without reading the label.
        editScope.selectedSegmentTintColor = nil

        scopeRow.axis = .horizontal
        scopeRow.isLayoutMarginsRelativeArrangement = true
        scopeRow.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
        scopeRow.addArrangedSubview(editScope)

        searchRow.axis = .horizontal
        searchRow.alignment = .center
        searchRow.spacing = 8
        // The search bar expands to fill, so without a trailing margin Edit is
        // pinned hard against the screen edge — awkward to hit and visually
        // cramped. Matches the 12pt inset the tab bar and the grid already use.
        searchRow.isLayoutMarginsRelativeArrangement = true
        searchRow.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 12)
        searchRow.addArrangedSubview(searchBar)
        searchRow.addArrangedSubview(editButton)

        pasteContainer.translatesAutoresizingMaskIntoConstraints = false

        topControls.axis = .vertical
        topControls.translatesAutoresizingMaskIntoConstraints = false

        grid = StickerGridViewController(store: store)
        addChild(grid)
        grid.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid.view)
        grid.didMove(toParent: self)

        paste = PasteViewController(store: store, downloader: downloader)
        paste.onFinished = { [weak self] _ in self?.grid.reload() }
        addChild(paste)
        paste.view.translatesAutoresizingMaskIntoConstraints = false
        pasteContainer.addSubview(paste.view)

        topControls.addArrangedSubview(pasteContainer)
        topControls.addArrangedSubview(searchRow)
        // Last, so it sits directly above the grid it acts on rather than up
        // in the toolbar with the controls that act on the whole drawer.
        topControls.addArrangedSubview(scopeRow)

        view.addSubview(topControls)
        view.addSubview(tabs)

        paste.didMove(toParent: self)

        // No fixed height here on purpose. This was 76pt, sized when the paste
        // view held a button, a spinner and a label; Paste Link and Add Photos
        // were appended by two later features and the container never grew, so
        // both were clipped out of sight and the features looked unbuilt. The
        // container now takes its height from the paste view's own content,
        // which cannot fall out of date.
        NSLayoutConstraint.activate([
            paste.view.topAnchor.constraint(equalTo: pasteContainer.topAnchor),
            paste.view.bottomAnchor.constraint(equalTo: pasteContainer.bottomAnchor),
            paste.view.leadingAnchor.constraint(equalTo: pasteContainer.leadingAnchor),
            paste.view.trailingAnchor.constraint(equalTo: pasteContainer.trailingAnchor),

            topControls.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor),
            topControls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topControls.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            grid.view.topAnchor.constraint(equalTo: topControls.bottomAnchor),
            grid.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.view.bottomAnchor.constraint(equalTo: tabs.topAnchor, constant: -8),

            tabs.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Presentation style

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        applyPresentationStyle(presentationStyle)
    }

    private func applyPresentationStyle(_ style: MSMessagesAppPresentationStyle) {
        // viewDidLoad may have bailed out after a failed StickerStore init, in
        // which case buildUI() never ran and grid/paste are still nil. This
        // callback fires independently of that, so guard against it.
        guard grid != nil else { return }

        let expanded = (style == .expanded)
        searchRow.isHidden = !expanded
        pasteContainer.isHidden = !expanded
        if !expanded {
            // Never leave the drawer in a state where taps do not send.
            setEditMode(.off)
            searchBar.text = nil
            searchBar.resignFirstResponder()
        }
        grid.filter = filterForSelectedTab()
        view.setNeedsLayout()
    }

    // MARK: - Lifecycle

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        // The extension can be killed without further warning; make sure no
        // manifest change is sitting in the debounce window.
        store?.flush()
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        // Second chance for a drawer that failed to set up. Fires every time
        // the extension becomes active, including after Messages has kept this
        // view controller alive across a trip to another app.
        prepareIfNeeded()
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        // `recordUse` never triggers a reload on its own (reordering cells
        // under the user's finger mid-tap would be worse than a stale
        // order), so pick up any use-count changes here instead: this fires
        // on every return to the extension, including re-expanding after the
        // conversation view collapsed it.
        grid?.reload()
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        grid?.reload()
    }

    // MARK: - Actions

    /// One place that maps segment index to filter. Three call sites used to
    /// each carry their own copy of this ternary; a fourth tab would have
    /// meant finding all of them.
    private func filterForSelectedTab() -> StickerFilter {
        switch tabs.selectedSegmentIndex {
        case 0:  return .favorites
        case 1:  return .recents
        default: return .all
        }
    }

    /// Single writer for edit state. Both buttons retitle on every change, so
    /// entering one mode visibly leaves the other — the two can never both
    /// read as active, and there is always exactly one Done to tap.
    private func setEditMode(_ mode: StickerEditMode) {
        grid?.editMode = mode
        editButton.setTitle(mode.editButtonTitle, for: .normal)
        scopeRow.isHidden = !mode.showsScopeBar
        if let index = mode.scopeIndex { editScope.selectedSegmentIndex = index }
        // Destructive tint while delete is armed, so the state is legible
        // without reading the segment label.
        editScope.selectedSegmentTintColor = (mode == .delete) ? .systemRed : nil
    }

    @objc private func tabChanged() {
        guard grid != nil else { return }
        searchBar.text = nil
        grid.filter = filterForSelectedTab()
    }

    /// Always enters at `entryMode`, never the mode last used — editing must
    /// not begin armed to delete.
    @objc private func editTapped() {
        guard grid != nil else { return }
        setEditMode(grid.editMode == .off ? StickerEditMode.entryMode : .off)
    }

    @objc private func editScopeChanged() {
        guard grid != nil, grid.editMode != .off else { return }
        setEditMode(StickerEditMode.mode(forScopeIndex: editScope.selectedSegmentIndex))
    }

    /// Retried on every activation, so it must not stack labels.
    private func showFatal(_ message: String) {
        if let existing = fatalLabel { existing.text = message; return }
        let label = UILabel()
        fatalLabel = label
        label.text = message
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
        ])
    }

    private func clearFatal() {
        fatalLabel?.removeFromSuperview()
        fatalLabel = nil
    }
}

extension MessagesViewController: UISearchBarDelegate {

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        grid.filter = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? filterForSelectedTab()
            : .search(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
