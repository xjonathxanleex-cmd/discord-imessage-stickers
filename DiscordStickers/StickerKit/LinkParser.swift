import Foundation

/// One image URL recovered from pasted text, with a name to pre-fill.
public struct ParsedLink: Equatable {
    public let url: URL
    public let suggestedName: String
    public let isAnimated: Bool

    public init(url: URL, suggestedName: String, isAnimated: Bool) {
        self.url = url
        self.suggestedName = suggestedName
        self.isAnimated = isAnimated
    }
}

/// Turns pasted text into a fetchable link. Pure: no I/O, no state.
///
/// Any `http(s)` URL is accepted rather than an allowlist of known hosts.
/// An allowlist is a rule users must learn and will get wrong, and since
/// every import is named on the review screen anyway, the usual argument
/// for restricting sources — that an unnamed sticker is unsearchable —
/// does not apply.
public enum LinkParser {

    private static let fallbackName = "sticker"

    public static func parse(_ text: String) -> ParsedLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }

        let ext = url.pathExtension.lowercased()

        return ParsedLink(
            url: url,
            suggestedName: name(for: url),
            isAnimated: ext == "gif"
        )
    }

    private static func name(for url: URL) -> String {
        // A Discord CDN emoji URL carries only an id — no name exists in it,
        // unlike the `<:name:id>` markup the paste flow reads.
        let filename = url.deletingPathExtension().lastPathComponent
        let decoded = filename.removingPercentEncoding ?? filename
        let cleaned = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty or root path (e.g. "https://example.com" or
        // "https://example.com/") makes `lastPathComponent` report "/"
        // rather than "", so both must map to the fallback.
        return (cleaned.isEmpty || cleaned == "/") ? fallbackName : cleaned
    }
}
