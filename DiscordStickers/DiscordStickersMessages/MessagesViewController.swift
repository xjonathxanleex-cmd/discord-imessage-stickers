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
        paste.didMove(toParent: self)

        view.addSubview(searchBar)
        view.addSubview(tabs)
        view.addSubview(pasteContainer)

        NSLayoutConstraint.activate([
            paste.view.topAnchor.constraint(equalTo: pasteContainer.topAnchor),
            paste.view.bottomAnchor.constraint(equalTo: pasteContainer.bottomAnchor),
            paste.view.leadingAnchor.constraint(equalTo: pasteContainer.leadingAnchor),
            paste.view.trailingAnchor.constraint(equalTo: pasteContainer.trailingAnchor),

            pasteContainer.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor),
            pasteContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pasteContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pasteContainer.heightAnchor.constraint(equalToConstant: 76),

            searchBar.topAnchor.constraint(equalTo: pasteContainer.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            grid.view.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
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
        let expanded = (style == .expanded)
        searchBar.isHidden = !expanded
        pasteContainer.isHidden = !expanded
        if !expanded {
            searchBar.text = nil
            searchBar.resignFirstResponder()
            grid.filter = tabs.selectedSegmentIndex == 0 ? .recents : .all
        }
        view.setNeedsLayout()
    }

    // MARK: - Lifecycle

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        // The extension can be killed without further warning; make sure no
        // manifest change is sitting in the debounce window.
        store?.flush()
    }

    // MARK: - Actions

    @objc private func tabChanged() {
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
