import UIKit

/// Lets the user name imports before anything is stored.
///
/// Parent-agnostic, like `PasteViewController`, so the extension can present
/// it today and a paid-tier host app could present it unchanged later.
public final class StickerReviewViewController: UITableViewController {

    private var drafts: [StickerDraft]
    private let store: StickerStore

    public var onFinished: ((DownloadOutcome?) -> Void)?

    public init(drafts: [StickerDraft], store: StickerStore) {
        self.drafts = drafts
        self.store = store
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = drafts.count == 1 ? "Name this sticker" : "Name these stickers"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Add", style: .done, target: self, action: #selector(add)
        )

        tableView.register(DraftCell.self,
                           forCellReuseIdentifier: DraftCell.reuseIdentifier)
        tableView.keyboardDismissMode = .interactive
        updateAddButton()
    }

    public override func tableView(_ tableView: UITableView,
                                   numberOfRowsInSection section: Int) -> Int {
        drafts.count
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: DraftCell.reuseIdentifier, for: indexPath
        ) as! DraftCell

        cell.configure(with: drafts[indexPath.row]) { [weak self] newName in
            guard let self, indexPath.row < self.drafts.count else { return }
            self.drafts[indexPath.row].name = newName
            self.updateAddButton()
        }
        return cell
    }

    /// Add stays disabled while any name is blank, rather than silently
    /// substituting a default the user did not choose.
    private func updateAddButton() {
        navigationItem.rightBarButtonItem?.isEnabled = drafts.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    @objc private func cancel() {
        onFinished?(nil)
    }

    @objc private func add() {
        let trimmed = drafts.map { draft -> StickerDraft in
            var copy = draft
            copy.name = draft.name.trimmingCharacters(in: .whitespaces)
            return copy
        }
        onFinished?(StickerImporter.importDrafts(trimmed, into: store))
    }
}

/// One row: a thumbnail and an editable name.
private final class DraftCell: UITableViewCell, UITextFieldDelegate {

    static let reuseIdentifier = "DraftCell"

    private let thumbnail = UIImageView()
    private let nameField = UITextField()
    private var onNameChanged: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        thumbnail.contentMode = .scaleAspectFit
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        nameField.placeholder = "Name"
        nameField.autocapitalizationType = .none
        nameField.autocorrectionType = .no
        nameField.clearButtonMode = .whileEditing
        nameField.delegate = self
        nameField.addTarget(self, action: #selector(nameChanged),
                            for: .editingChanged)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(thumbnail)
        contentView.addSubview(nameField)

        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 44),
            thumbnail.heightAnchor.constraint(equalToConstant: 44),
            thumbnail.topAnchor.constraint(
                greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
            thumbnail.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

            nameField.leadingAnchor.constraint(
                equalTo: thumbnail.trailingAnchor, constant: 12),
            nameField.trailingAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            nameField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with draft: StickerDraft,
                   onNameChanged: @escaping (String) -> Void) {
        // A thumbnail of one pending import, not a collection — the memory
        // discipline that governs the sticker grid does not apply to a
        // short review list.
        thumbnail.image = UIImage(data: draft.imageData)
        nameField.text = draft.name
        self.onNameChanged = onNameChanged
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.image = nil
        nameField.text = nil
        onNameChanged = nil
    }

    @objc private func nameChanged() {
        onNameChanged?(nameField.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
