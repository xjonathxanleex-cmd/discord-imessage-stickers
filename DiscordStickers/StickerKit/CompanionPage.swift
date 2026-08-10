import Foundation

/// The desktop companion page, which builds a sticker set on a computer and
/// hands it over as a `DSTK1` payload.
///
/// Defined once so the drawer's first-run text and the host app cannot drift
/// apart, and so moving the page is a one-line change rather than a search.
public enum CompanionPage {

    public static let url = URL(string:
        "https://xjonathxanleex-cmd.github.io/discord-imessage-stickers/")!

    /// Without the scheme. Shown rather than linked in the extension, where a
    /// tap cannot open Safari reliably — and where the reader is on the wrong
    /// device anyway: the page exists because picking through hundreds of
    /// emoji is miserable on a phone.
    public static var displayText: String {
        url.absoluteString
            .replacingOccurrences(of: "https://", with: "")
    }
}
