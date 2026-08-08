import UIKit
import Messages
import StickerKit

/// Compact mode shows Recents plus the full grid. Expanded mode adds search
/// and the paste control.
///
/// The extension owns storage outright: App Groups is unavailable on a free
/// Personal Team, so there is no shared container to read from.
final class MessagesViewController: MSMessagesAppViewController {

    private var store: StickerStore!
    private var downloader: EmojiDownloader!
    private var grid: StickerGridViewController!
    private var paste: PasteViewController!

    private let searchBar = UISearchBar()
    private let tabs = UISegmentedControl(items: ["Recent", "All"])
    private let pasteContainer = UIView()
    private let topControls = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()

        let root = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]

        do {
            store = try StickerStore(root: root)
        } catch {
            showFatal("Couldn't open sticker storage.")
            return
        }
        downloader = EmojiDownloader(store: store)

        buildUI()
        applyPresentationStyle(presentationStyle)
    }

    private func buildUI() {
        tabs.selectedSegmentIndex = 1
        tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        searchBar.placeholder = "Search emoji"
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false

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
        topControls.addArrangedSubview(searchBar)

        view.addSubview(topControls)
        view.addSubview(tabs)

        paste.didMove(toParent: self)

        // Required priority would conflict with the stack view's own
        // required-priority zero-size constraint when pasteContainer is
        // hidden (UISV-hiding); .defaultHigh lets that one win without any
        // console warnings, and the layout still collapses correctly.
        let pasteContainerHeight = pasteContainer.heightAnchor.constraint(equalToConstant: 76)
        pasteContainerHeight.priority = .defaultHigh
        pasteContainerHeight.isActive = true

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
        searchBar.isHidden = !expanded
        pasteContainer.isHidden = !expanded
        if !expanded {
            searchBar.text = nil
            searchBar.resignFirstResponder()
        }
        grid.filter = tabs.selectedSegmentIndex == 0 ? .recents : .all
        view.setNeedsLayout()
    }

    // MARK: - Lifecycle

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        // The extension can be killed without further warning; make sure no
        // manifest change is sitting in the debounce window.
        store?.flush()
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

    @objc private func tabChanged() {
        guard grid != nil else { return }
        searchBar.text = nil
        grid.filter = tabs.selectedSegmentIndex == 0 ? .recents : .all
    }

    private func showFatal(_ message: String) {
        let label = UILabel()
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
}

extension MessagesViewController: UISearchBarDelegate {

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        grid.filter = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? (tabs.selectedSegmentIndex == 0 ? .recents : .all)
            : .search(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
