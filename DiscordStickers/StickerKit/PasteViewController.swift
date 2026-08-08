import UIKit
import PhotosUI
import UniformTypeIdentifiers

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
    private let linkButton = UIButton(type: .system)
    private let photoButton = UIButton(type: .system)

    /// Guards against a second import starting while one is already in
    /// flight, on either the link or the photo path. Without this, UIKit
    /// silently drops the second `present(_:)` call and that draft is lost
    /// with no error shown. Covers both paths with one flag because they
    /// share the same failure mode and the same modal presentation: a photo
    /// pick landing mid-link-fetch (or vice versa) would lose one of them
    /// exactly as silently as two taps on the same button. Set on entry to
    /// `linkTapped` / `photosTapped`, cleared on every exit — cancel,
    /// failure, and after the review screen finishes or is dismissed.
    private var isImporting = false

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

        linkButton.setTitle("Paste Link", for: .normal)
        linkButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        linkButton.addTarget(self, action: #selector(linkTapped),
                             for: .touchUpInside)

        photoButton.setTitle("Add Photos", for: .normal)
        photoButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        photoButton.addTarget(self, action: #selector(photosTapped),
                              for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [linkButton, photoButton, exportButton, importButton])
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

    /// Reads the clipboard directly, which triggers the system "Allow Paste?"
    /// alert. Acceptable here for the same reason Restore accepts it: this is
    /// an occasional action, not the app's core loop.
    @objc private func linkTapped() {
        guard !isImporting else { return }

        guard let text = UIPasteboard.general.string,
              let link = LinkParser.parse(text) else {
            statusLabel.text = "That doesn't look like a link."
            return
        }

        // Checked before any network work so the paste isn't consumed for
        // nothing — the user can simply paste again once they're back
        // online. Same guard and message as the emoji paste flow.
        guard NetworkReachability.isLikelyOnline else {
            statusLabel.text = "You're offline — paste again when you're back."
            return
        }

        isImporting = true
        spinner.startAnimating()
        statusLabel.text = "Fetching…"

        Task { [weak self] in
            guard let self else { return }
            let result = await DraftFetcher().fetch(link)

            await MainActor.run {
                self.spinner.stopAnimating()
                switch result {
                case .failure(let error):
                    self.isImporting = false
                    self.statusLabel.text = self.message(for: error)
                case .success(let draft):
                    // isImporting stays true — presentReview's onFinished
                    // clears it once the review screen actually finishes.
                    self.presentReview(for: [draft])
                }
            }
        }
    }

    @objc private func photosTapped() {
        guard !isImporting else { return }
        isImporting = true

        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = StickerLimits.maxPhotoSelection
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Loads and normalizes every picked item, preserving the order the user
    /// chose, with concurrency capped at `StickerLimits.photoLoadConcurrency`
    /// — the same shape as `EmojiDownloader.download`: prime the group, then
    /// add one task per completion, rather than one task per picked item.
    ///
    /// `PhotoDraftLoader.draft(from:)` runs *inside* each task, so the
    /// multi-megabyte `Data` `loadDataRepresentation` hands back is released
    /// when that task ends and only the ~400 KB downsampled payload survives
    /// into the array below. The old shape — one task per item, every raw
    /// `Data` collected into an array, downsampling only afterwards — kept
    /// every picked item's full-size bytes resident at once; 20 photos at
    /// ~3 MB alone crosses the extension's 40 MB floor before anything
    /// decodes.
    private func loadDrafts(from results: [PHPickerResult]) async -> [StickerDraft] {
        await withTaskGroup(
            of: (Int, StickerDraft?).self, returning: [StickerDraft].self
        ) { group in
            var nextIndex = 0

            func addTask(_ index: Int) {
                let provider = results[index].itemProvider
                group.addTask {
                    (index, await Self.loadDraft(from: provider))
                }
            }

            while nextIndex < min(StickerLimits.photoLoadConcurrency, results.count) {
                addTask(nextIndex)
                nextIndex += 1
            }

            var collected: [(Int, StickerDraft?)] = []
            while let result = await group.next() {
                collected.append(result)
                if nextIndex < results.count {
                    addTask(nextIndex)
                    nextIndex += 1
                }
            }

            // Tagged with the picker index above and sorted back into order
            // here, since task completion order does not match selection
            // order under a concurrency cap.
            return collected.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }

    /// Loads one picked item's raw bytes and turns them into a draft.
    private static func loadDraft(from provider: NSItemProvider) async -> StickerDraft? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        else { return nil }

        guard let data = await loadDataRepresentation(from: provider) else { return nil }
        return PhotoDraftLoader.draft(from: data)
    }

    /// This SDK does not expose the async overload of
    /// `loadDataRepresentation(for:)`, only the completion-handler form, so
    /// it's wrapped in `withCheckedContinuation` rather than switching to
    /// `loadObject(ofClass: UIImage.self)`, which would decode the image at
    /// full resolution and defeat the downsampling this whole feature
    /// depends on.
    ///
    /// Raced against a 15 second timeout — matching `DraftFetcher`'s
    /// deadline for a fetched link — because a provider that never invokes
    /// its completion handler would otherwise suspend forever, leaving the
    /// spinner spinning with no recovery. Whichever finishes first resumes
    /// the continuation; a `SingleResume` box makes the loser's resume a
    /// harmless no-op instead of the trap-worthy double-resume it would
    /// otherwise be. The timeout runs as its own unstructured `Task` rather
    /// than a second `TaskGroup` child, specifically so it is *not*
    /// structurally awaited — a `TaskGroup` implicitly waits for every child
    /// before returning, which would defeat the timeout for exactly the
    /// never-calls-back case it exists to handle.
    private static func loadDataRepresentation(
        from provider: NSItemProvider
    ) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let box = SingleResume(continuation)

            provider.loadDataRepresentation(for: .image) { data, _ in
                box.resume(with: data)
            }

            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                box.resume(with: nil)
            }
        }
    }

    private func message(for error: DraftFetchError) -> String {
        switch error {
        case .unreachable: return "Couldn't fetch that link."
        case .tooLarge:    return "That image is too large."
        case .notAnImage:  return "That link isn't an image."
        }
    }

    /// `droppedCount` is folded into the eventual status text rather than
    /// shown immediately: the review screen covers the status label the
    /// instant it's presented, so anything written to `statusLabel.text`
    /// beforehand would never be seen — only the text set in `onFinished`,
    /// once the modal is dismissed, is.
    @MainActor
    private func presentReview(for drafts: [StickerDraft], droppedCount: Int = 0) {
        let review = StickerReviewViewController(drafts: drafts, store: store)
        let navigation = UINavigationController(rootViewController: review)
        // A swipe-down must not be able to bypass `onFinished` entirely —
        // that would skip both the cancelled-status update and any eventual
        // outcome reporting.
        navigation.isModalInPresentation = true

        review.onFinished = { [weak self, weak navigation] outcome in
            navigation?.dismiss(animated: true)
            guard let self else { return }
            self.isImporting = false
            guard let outcome else {
                self.statusLabel.text = "Cancelled."
                return
            }
            var text = Self.summary(for: outcome)
            if droppedCount > 0 {
                text += " \(droppedCount) "
                    + (droppedCount == 1 ? "photo" : "photos")
                    + " couldn't be read."
            }
            self.statusLabel.text = text
            self.onFinished?(outcome)
        }

        present(navigation, animated: true)
    }
}

extension PasteViewController: PHPickerViewControllerDelegate {

    public func picker(_ picker: PHPickerViewController,
                       didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard !results.isEmpty else {   // cancelled
            isImporting = false
            return
        }

        spinner.startAnimating()
        statusLabel.text = "Loading \(results.count) "
            + (results.count == 1 ? "photo…" : "photos…")

        Task { [weak self] in
            guard let self else { return }
            // Downsampling now happens inside `loadDrafts`, one item at a
            // time, so the spinner stops only once that work is actually
            // done — not before it, which would read as finished while the
            // task group is still decoding.
            let drafts = await self.loadDrafts(from: results)

            await MainActor.run {
                self.spinner.stopAnimating()

                guard !drafts.isEmpty else {
                    self.isImporting = false
                    self.statusLabel.text = "Couldn't read those photos."
                    return
                }

                let droppedCount = results.count - drafts.count
                self.presentReview(for: drafts, droppedCount: droppedCount)
            }
        }
    }
}

/// Ensures a `CheckedContinuation` is resumed exactly once, no matter which
/// of two racing callers — a completion handler and a timeout — gets there
/// first. Both may run on arbitrary queues, so the flag is lock-protected
/// rather than merely `@MainActor`.
private final class SingleResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
