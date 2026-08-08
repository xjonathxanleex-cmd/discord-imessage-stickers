import UIKit

/// The paste button, plus the one-line summary of what a batch did.
///
/// Deliberately knows nothing about its parent. `UIPasteControl` was tried
/// first, specifically to avoid the system "Allow Paste?" alert that a direct
/// `UIPasteboard.general.string` read triggers. On a real device, inside a
/// Messages extension, it renders permanently disabled — even with valid
/// text on the clipboard — so a plain button is used instead. See
/// `pasteTapped()` for the trade-off this accepts.
public final class PasteViewController: UIViewController {

    private let store: StickerStore
    private let downloader: EmojiDownloader

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    public var onFinished: ((DownloadOutcome) -> Void)?

    private let exportButton = UIButton(type: .system)
    private let importButton = UIButton(type: .system)

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

        var pasteConfiguration = UIButton.Configuration.borderedProminent()
        pasteConfiguration.cornerStyle = .capsule
        pasteConfiguration.title = "Paste Emoji"
        let pasteButton = UIButton(configuration: pasteConfiguration)
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)

        statusLabel.text = "Copy Discord emoji, then paste them here."
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        spinner.hidesWhenStopped = true

        exportButton.setTitle("Back Up", for: .normal)
        exportButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)

        importButton.setTitle("Restore", for: .normal)
        importButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [exportButton, importButton])
        buttons.axis = .horizontal
        buttons.spacing = 16

        let stack = UIStackView(
            arrangedSubviews: [pasteButton, spinner, statusLabel, buttons]
        )
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

    /// Reads the pasteboard directly, which deliberately triggers the system
    /// "Allow Paste?" alert. `UIPasteControl` was tried first to avoid that
    /// alert entirely, but real-device testing showed it renders permanently
    /// disabled inside a Messages extension — it cannot determine the
    /// pasteboard's contents in that sandbox, even when the clipboard
    /// demonstrably holds valid Discord markup. A button that never enables
    /// is a worse failure than one system prompt, and a batch paste is a
    /// rare action (roughly weekly, or after the 7-day reinstall), so one
    /// prompt per batch is an acceptable trade.
    @objc private func pasteTapped() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            statusLabel.text = "Nothing on the clipboard to paste."
            return
        }
        handle(text)
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

    @objc private func exportTapped() {
        UIPasteboard.general.string = ManifestTransfer.export(from: store)
        statusLabel.text = "Backup copied. Paste it somewhere safe."
    }

    /// Restore reads the pasteboard directly and so will trigger the system
    /// paste alert, same as `pasteTapped()`. That is acceptable here too:
    /// this runs roughly once a week at most.
    @objc private func importTapped() {
        guard let text = UIPasteboard.general.string else {
            statusLabel.text = "Nothing on the clipboard to restore."
            return
        }
        let entries = ManifestTransfer.parseImport(text)
        guard !entries.isEmpty else {
            statusLabel.text = "That doesn't look like a backup."
            return
        }

        spinner.startAnimating()
        statusLabel.text = "Restoring \(entries.count) stickers…"

        Task {
            let outcome = await ManifestTransfer.restore(
                entries, store: store, downloader: downloader
            )
            await MainActor.run {
                spinner.stopAnimating()
                statusLabel.text = Self.summary(for: outcome)
                onFinished?(outcome)
            }
        }
    }
}
