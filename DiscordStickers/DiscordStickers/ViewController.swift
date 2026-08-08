import UIKit

/// Deliberately inert. An iMessage extension cannot ship on its own, so this
/// app exists to carry one. Everything real happens inside the extension,
/// because App Groups — which would let this app write storage the extension
/// could read — is unavailable on a free Personal Team.
final class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "Discord Stickers"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.adjustsFontForContentSizeCategory = true

        let body = UILabel()
        body.numberOfLines = 0
        body.font = .preferredFont(forTextStyle: .body)
        body.adjustsFontForContentSizeCategory = true
        body.text = """
        Everything happens inside Messages.

        1. Open any conversation in Messages.
        2. Tap the apps row beside the text field, then pick Discord Stickers.
        3. Drag the drawer up to reveal search and the paste button.

        To add emoji: in Discord, tap emoji into a message box, select all, \
        and copy. Then paste them into the drawer.

        Tap a sticker to send it, or drag it onto a message to stick it there.
        """

        let stack = UIStackView(arrangedSubviews: [title, body])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }
}

