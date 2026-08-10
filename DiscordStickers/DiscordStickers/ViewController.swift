import UIKit
import StickerKit

/// Mostly inert. An iMessage extension cannot ship on its own, so this app
/// exists to carry one, and everything real happens inside the extension —
/// App Groups, which would let this app write storage the extension could
/// read, is unavailable on a free Personal Team.
///
/// It is still the only screen in the project that can open a URL. A Messages
/// extension has no reliable route to Safari, so the companion page is *shown*
/// there and *linked* here.
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

        let companionHeading = UILabel()
        companionHeading.text = "Build a set on a computer"
        companionHeading.font = .preferredFont(forTextStyle: .headline)
        companionHeading.adjustsFontForContentSizeCategory = true

        let companionBody = UILabel()
        companionBody.numberOfLines = 0
        companionBody.font = .preferredFont(forTextStyle: .body)
        companionBody.adjustsFontForContentSizeCategory = true
        companionBody.text = """
        Picking through hundreds of emoji is easier on a big screen. \
        The page gathers Discord and 7TV emoji, then hands the set over as \
        text you paste here — or as QR codes you scan.
        """

        // Copy first, deliberately. The page is meant to be *used* on a
        // computer, so the useful action from a phone is getting the address
        // onto one — via Universal Clipboard, or by messaging it to yourself.
        // Opening it here just loads the hard-to-use version on the small
        // screen the page exists to avoid.
        var copyConfiguration = UIButton.Configuration.borderedProminent()
        copyConfiguration.title = "Copy page link"
        copyConfiguration.cornerStyle = .capsule
        let copyButton = UIButton(configuration: copyConfiguration)
        copyButton.addTarget(self, action: #selector(copyLink), for: .touchUpInside)

        var openConfiguration = UIButton.Configuration.plain()
        openConfiguration.title = CompanionPage.displayText
        let openButton = UIButton(configuration: openConfiguration)
        openButton.contentHorizontalAlignment = .leading
        openButton.titleLabel?.adjustsFontSizeToFitWidth = true
        openButton.addTarget(self, action: #selector(openPage), for: .touchUpInside)

        confirmation.font = .preferredFont(forTextStyle: .footnote)
        confirmation.textColor = .secondaryLabel
        confirmation.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [
            title, body, companionHeading, companionBody,
            copyButton, openButton, confirmation,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        stack.setCustomSpacing(28, after: body)
        stack.setCustomSpacing(8, after: companionHeading)
        stack.setCustomSpacing(4, after: copyButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable: the text is long enough to clip on a small phone at the
        // larger accessibility text sizes, and a screen whose only job is
        // instructions must not hide half of them.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor,
                                       constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor,
                                          constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor,
                                           constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor,
                                            constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor,
                                         constant: -48),
        ])
    }

    private let confirmation = UILabel()

    @objc private func copyLink() {
        UIPasteboard.general.string = CompanionPage.url.absoluteString
        confirmation.text = "Copied. On a Mac it's already on your clipboard — "
            + "otherwise message it to yourself."
    }

    @objc private func openPage() {
        UIApplication.shared.open(CompanionPage.url)
    }
}
