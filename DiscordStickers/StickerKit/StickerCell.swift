import UIKit
import Messages

/// Hosts one `MSStickerView`, which supplies tap-to-send and
/// drag-onto-bubble for free.
///
/// `prepareForReuse` clearing the sticker is load-bearing: a Messages
/// extension is killed somewhere between 40 and 120 MB, and holding decoded
/// images in recycled cells is the fastest way to get there.
///
/// In edit mode the sticker view's interaction is disabled outright rather
/// than competing with it for gestures. `MSStickerView` owns tap and
/// long-press-drag and exposes no callbacks — the tap counter below only
/// works because it recognizes *simultaneously* rather than instead.
/// Contesting those gestures a second time would be fragile in a way only a
/// device could reveal, so edit mode takes `MSStickerView` out of the
/// conversation entirely.
public final class StickerCell: UICollectionViewCell {

    public static let reuseIdentifier = "StickerCell"

    private let stickerView = MSStickerView()
    private let starButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    // 32x32 frames need this to keep the glyph itself visually small; see
    // the frame-size comment in `init`.
    private static let glyphConfiguration = UIImage.SymbolConfiguration(pointSize: 17)

    private var onTap: (() -> Void)?
    private var onToggleFavorite: (() -> Void)?
    private var onDelete: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)

        stickerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stickerView)

        for button in [starButton, deleteButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isHidden = true
            contentView.addSubview(button)
        }

        // 44x44 — the full HIG minimum, affordable because only ever one of
        // these is visible. Two 32pt buttons previously shared a ~63pt cell
        // and physically overlapped; see StickerEditMode for the arithmetic.
        starButton.tintColor = .systemYellow
        starButton.addTarget(self, action: #selector(handleStar),
                             for: .touchUpInside)

        deleteButton.setImage(
            UIImage(systemName: "xmark.circle.fill",
                   withConfiguration: Self.glyphConfiguration),
            for: .normal
        )
        deleteButton.tintColor = .systemRed
        deleteButton.addTarget(self, action: #selector(handleDelete),
                               for: .touchUpInside)

        NSLayoutConstraint.activate([
            stickerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stickerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stickerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stickerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            // Both occupy the same corner. Only one is ever visible, so there
            // is no collision, and a single fixed position means the target
            // does not move as you switch between favoriting and deleting.
            starButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            starButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            starButton.widthAnchor.constraint(equalToConstant: 44),
            starButton.heightAnchor.constraint(equalToConstant: 44),

            deleteButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 44),
            deleteButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Recognizes alongside MSStickerView's own handling rather than
        // instead of it, so the tap still sends. Counts taps, not confirmed
        // sends — a deliberate approximation, sufficient for ordering Recents.
        let recognizer = UITapGestureRecognizer(
            target: self, action: #selector(handleTap)
        )
        recognizer.delegate = self
        stickerView.addGestureRecognizer(recognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func configure(with sticker: MSSticker,
                          isFavorite: Bool,
                          mode: StickerEditMode,
                          onTap: @escaping () -> Void,
                          onToggleFavorite: @escaping () -> Void,
                          onDelete: @escaping () -> Void) {
        stickerView.sticker = sticker
        // Playback is NOT started here. Assigning `.sticker` does not begin it
        // — `MSStickerView.h` documents startAnimating/stopAnimating but never
        // says assignment starts anything — but calling it here does not work
        // either.
        //
        // `configure` runs from `cellForItemAt`, which happens *before* the
        // cell is in the window. A sticker told to animate off-screen does not
        // begin, and nothing asks it again, so it stays frozen for as long as
        // that cell lives. Starting playback belongs in `willDisplay`, which
        // fires once the cell is actually about to appear — see
        // `beginAnimating()`.
        self.onTap = onTap
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete

        stickerView.isUserInteractionEnabled = !mode.disablesSending
        starButton.isHidden = mode != .favorites
        deleteButton.isHidden = mode != .delete
        starButton.setImage(
            UIImage(systemName: isFavorite ? "star.fill" : "star",
                   withConfiguration: Self.glyphConfiguration),
            for: .normal
        )
    }

    /// Starts playback. Called from `willDisplay`, when the cell is genuinely
    /// on its way on screen — not from `configure`, which runs while the cell
    /// is still detached and where the call is simply ignored.
    public func beginAnimating() {
        stickerView.startAnimating()
    }

    /// Stops playback when the cell scrolls away. Paired with `beginAnimating`
    /// so off-screen cells are not decoding frames nobody can see, against a
    /// 40-120 MB ceiling.
    public func endAnimating() {
        stickerView.stopAnimating()
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        // Stop before clearing: a recycled cell that keeps ticking is the same
        // class of leak as one that keeps its decoded image, and the extension
        // is killed somewhere between 40 and 120 MB.
        stickerView.stopAnimating()
        stickerView.sticker = nil
        stickerView.isUserInteractionEnabled = true
        starButton.isHidden = true
        deleteButton.isHidden = true
        onTap = nil
        onToggleFavorite = nil
        onDelete = nil
    }

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func handleStar() {
        onToggleFavorite?()
    }

    @objc private func handleDelete() {
        onDelete?()
    }
}

extension StickerCell: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
