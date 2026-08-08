import UIKit

/// The paste control, plus the one-line summary of what a batch did.
///
/// Deliberately knows nothing about its parent. `UIPasteControl` is used
/// rather than reading `UIPasteboard.general.string` directly, because
/// programmatic pasteboard reads trigger a system "Allow Paste?" alert on
/// every invocation — intolerable for this app's core action. A tap on the
/// control *is* the consent.
public final class PasteViewController: UIViewController {

    private let store: StickerStore
    private let downloader: EmojiDownloader

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    public var onFinished: ((DownloadOutcome) -> Void)?

    public init(store: StickerStore, downloader: EmojiDownloader) {
        self.store = store
        self.downloader = downloader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)

        var configuration = UIPasteControl.Configuration()
        configuration.displayMode = .labelOnly
        configuration.cornerStyle = .capsule
        let pasteControl = UIPasteControl(configuration: configuration)
        pasteControl.target = self

        statusLabel.text = "Copy Discord emoji, then paste them here."
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        spinner.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [pasteControl, spinner, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                       constant: 12),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor,
                                           constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor,
                                            constant: -16),
        ])
    }

    public override func paste(itemProviders: [NSItemProvider]) {
        for provider in itemProviders where provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String else { return }
                Task { @MainActor in self?.handle(text) }
            }
            return
        }
    }

    @MainActor
    private func handle(_ text: String) {
        let parsed = EmojiMarkupParser.parse(text)
        guard !parsed.isEmpty else {
            statusLabel.text = "No Discord emoji found in what you pasted."
            return
        }

        // Checked before any network work so the paste isn't consumed for
        // nothing — the user can simply paste again once they're back online.
        guard NetworkReachability.isLikelyOnline else {
            statusLabel.text = "You're offline — paste again when you're back."
            return
        }

        spinner.startAnimating()
        statusLabel.text = "Adding \(parsed.count) emoji…"

        Task {
            let outcome = await downloader.download(parsed)
            await MainActor.run {
                spinner.stopAnimating()
                statusLabel.text = Self.summary(for: outcome)
                onFinished?(outcome)
            }
        }
    }

    /// One honest sentence. Clauses are omitted when their count is zero, so
    /// the common case reads "Added 12 stickers." and nothing more.
    public static func summary(for outcome: DownloadOutcome) -> String {
        var parts: [String] = []

        if !outcome.added.isEmpty {
            parts.append("Added \(outcome.added.count) "
                         + (outcome.added.count == 1 ? "sticker" : "stickers"))
        }
        if !outcome.alreadyPresent.isEmpty {
            parts.append("\(outcome.alreadyPresent.count) already saved")
        }
        if !outcome.missing.isEmpty {
            parts.append("\(outcome.missing.count) no longer "
                         + (outcome.missing.count == 1 ? "exists" : "exist"))
        }
        if !outcome.unusable.isEmpty {
            parts.append("\(outcome.unusable.count) couldn't be used")
        }

        guard !parts.isEmpty else { return "Nothing to add." }
        return parts.joined(separator: ", ") + "."
    }
}
