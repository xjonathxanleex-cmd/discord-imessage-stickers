import UIKit
import Messages

public enum StickerFilter: Equatable {
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

    public var filter: StickerFilter = .all {
        didSet { if filter != oldValue { reload() } }
    }

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

        reload()
    }

    public func reload() {
        switch filter {
        case .recents: entries = store.recents()
        case .all:     entries = store.all()
        case .search(let query): entries = store.search(query)
        }
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
            cell.configure(with: sticker) { [weak self] in
                self?.store.recordUse(id: entry.id)
            }
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
