import UIKit
import Messages

public enum StickerFilter: Equatable {
    case favorites
    case recents
    case all
    case search(String)
}

/// A collection view of stickers backed entirely by `StickerStore`.
/// It never touches disk itself and never holds a decoded image: `MSSticker`
/// is file-URL-backed and constructed lazily per visible cell.
public final class StickerGridViewController: UIViewController {

    private let store: StickerStore
    private var entries: [StickerEntry] = []
    private var collectionView: UICollectionView!
    private let emptyLabel = UILabel()

    public var filter: StickerFilter = .all {
        didSet { if filter != oldValue { reload() } }
    }

    /// Which editing affordance cells offer. In any editing mode
    /// `MSStickerView` interaction is off — sending and dragging are disabled
    /// for the duration rather than competing with the edit controls for
    /// gestures.
    ///
    /// Named `editMode`, not `isEditing`: `UIViewController` already declares
    /// a settable `isEditing` tied to its `editButtonItem` and
    /// `setEditing(_:animated:)` machinery, none of which this app uses.
    /// Overriding it would let UIKit flip this app's edit mode through a path
    /// nobody here is watching.
    public var editMode: StickerEditMode = .off {
        didSet {
            if editMode != oldValue { collectionView?.reloadData() }
        }
    }

    /// Called after a delete, with the removed sticker's name, so the host
    /// can offer an undo. The grid does not own that affordance itself: it
    /// belongs beside the other editing controls, not floating over the cells
    /// it would obscure.
    public var onDeleted: ((String) -> Void)?

    public init(store: StickerStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            StickerCell.self, forCellWithReuseIdentifier: StickerCell.reuseIdentifier
        )

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Wording must not assume the drawer is expanded: Edit is unreachable
        // from compact mode, so "tap Edit" alone would refer to a button the
        // reader cannot see. It also must not describe an action that is
        // impossible from this tab: the Favorites grid is empty precisely
        // when this label is showing, so "star any sticker" needs an
        // explicit "switch tabs first" step or there is nothing to star.
        emptyLabel.text = "No favorites yet. Open the All tab, "
            + "tap Edit, then tap the star on any sticker."
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                                constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                 constant: -24),
        ])

        reload()
    }

    public func reload() {
        switch filter {
        case .favorites: entries = store.favorites()
        case .recents:   entries = store.recents()
        case .all:       entries = store.all()
        case .search(let query): entries = store.search(query)
        }
        emptyLabel.isHidden = !(entries.isEmpty && filter == .favorites)
        collectionView?.reloadData()
    }
}

extension StickerGridViewController: UICollectionViewDataSource {

    public func collectionView(_ collectionView: UICollectionView,
                               numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: StickerCell.reuseIdentifier, for: indexPath
        ) as! StickerCell

        let entry = entries[indexPath.item]

        // Every manifest entry was proven constructible at download time, so
        // this should never fail. `try?` is belt-and-braces: an empty cell is
        // survivable, a throw mid-scroll is not.
        if let sticker = try? MSSticker(
            contentsOfFileURL: store.fileURL(for: entry.id),
            localizedDescription: entry.name
        ) {
            cell.configure(
                with: sticker,
                isFavorite: entry.favoritedAt != nil,
                mode: editMode,
                onTap: { [weak self] in
                    self?.store.recordUse(id: entry.id)
                },
                onToggleFavorite: { [weak self] in
                    guard let self else { return }
                    self.store.setFavorite(entry.favoritedAt == nil, id: entry.id)
                    self.reload()
                },
                onDelete: { [weak self] in
                    guard let self else { return }
                    try? self.store.delete(id: entry.id)
                    self.reload()
                    self.onDeleted?(entry.name)
                }
            )
        }
        return cell
    }
}

extension StickerGridViewController: UICollectionViewDelegateFlowLayout {

    public func collectionView(
        _ collectionView: UICollectionView,
        layout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        // ~6 per row in the compact drawer, wider cells as the view grows.
        let columns = max(4, Int(collectionView.bounds.width / 70))
        let spacing: CGFloat = 8 * CGFloat(columns - 1) + 24
        let side = (collectionView.bounds.width - spacing) / CGFloat(columns)
        return CGSize(width: side, height: side)
    }
}
