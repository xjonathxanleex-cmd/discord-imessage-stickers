import Foundation

/// Parses the `DSTK1` transfer payload produced by the desktop companion.
///
/// Line-based rather than JSON because QR capacity is the binding constraint
/// on the producing side, and JSON's punctuation is pure overhead there.
/// Pure: no I/O, no state.
///
/// ```
/// DSTK1
/// d 1481800758532903104 67
/// 7 01G3WEGZN0000ET2J0MQP5YJ0G GAMBA
/// ```
public enum TransferPayloadParser {

    public static let header = "DSTK1"

    private static let sources: [String: StickerSource] = [
        "d": .pasted,
        "7": .sevenTV,
    ]

    /// True when the first non-blank line is exactly the header. Lets the
    /// paste flow tell a payload from Discord markup without asking the user
    /// which they copied.
    public static func looksLikePayload(_ text: String) -> Bool {
        firstMeaningfulLine(of: text) == header
    }

    /// Duplicate ids collapse to their first occurrence, matching
    /// `EmojiMarkupParser`. Chunked payloads overlap by design, so the same
    /// emoji arriving twice is expected rather than exceptional.
    public static func parse(_ text: String) -> [ParsedEmoji] {
        var lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.first == header else { return [] }
        lines.removeFirst()

        var seen = Set<String>()
        var result: [ParsedEmoji] = []

        for line in lines {
            // Split into tag, id, and the rest. The id never contains a
            // space, so three components with the remainder kept whole is
            // unambiguous and lets names contain spaces.
            let parts = line.split(separator: " ", maxSplits: 2,
                                   omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let source = sources[String(parts[0])]
            else { continue }

            let id = String(parts[1])
            let name = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !name.isEmpty, seen.insert(id).inserted
            else { continue }

            // No animation flag travels in the payload. Discord's 415 retry
            // corrects a wrong guess, and 7TV emotes carry the fact in their
            // own metadata on the producing side.
            result.append(ParsedEmoji(id: id, name: name,
                                      isAnimated: false, source: source))
        }

        return result
    }

    private static func firstMeaningfulLine(of text: String) -> String? {
        text.components(separatedBy: .newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
