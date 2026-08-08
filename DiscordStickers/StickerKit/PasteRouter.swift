import Foundation

/// What a pasted string turned out to be.
public enum PasteRoute: Equatable {
    /// A `DSTK1` transfer payload from the desktop companion.
    case payload([ParsedEmoji])
    /// Discord custom-emoji markup copied from a message.
    case markup([ParsedEmoji])
    /// A single image URL.
    case link(ParsedLink)
    /// A backup blob from Back Up, restorable but not importable here.
    case none
}

/// Decides what the clipboard holds, so one button can serve every format.
/// Pure: no I/O, no state, no UIKit.
///
/// There used to be a separate Paste Link button. Device testing found people
/// reasonably tapping Paste Emoji with a copied image link and being told
/// "No emoji found" — true, and useless. Making the user classify their own
/// clipboard is asking them to explain something the software can see for
/// itself, which is the same argument that already justified detecting
/// `DSTK1` payloads without asking.
///
/// This lives apart from `PasteViewController` so the decision can be tested
/// without a view controller, a pasteboard, or a running extension.
public enum PasteRouter {

    public static func route(_ text: String) -> PasteRoute {
        // A payload announces itself on line one, so it is unambiguous and
        // costs one line to check.
        if TransferPayloadParser.looksLikePayload(text) {
            let parsed = TransferPayloadParser.parse(text)
            return parsed.isEmpty ? .none : .payload(parsed)
        }

        // Markup before links, so that a message containing emoji *and* a URL
        // imports the emoji rather than the one image.
        //
        // This ordering is defensive, not currently load-bearing: today
        // `LinkParser` requires the entire trimmed string to be one http(s)
        // URL, so mixed text cannot route to `.link` whichever order these two
        // appear in. Swapping them changes nothing — verified by swapping
        // them and watching every test stay green.
        //
        // It is written this way regardless because the day `LinkParser` is
        // loosened to find a URL *inside* surrounding text, this order becomes
        // the only thing standing between "imports your 40 emoji" and
        // "imports one image and silently drops 40 emoji".
        let markup = EmojiMarkupParser.parse(text)
        if !markup.isEmpty { return .markup(markup) }

        if let link = LinkParser.parse(text) { return .link(link) }

        return .none
    }
}
