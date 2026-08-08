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
/// 7a 01F6MZGCNG000255K4X1K7EMS7 catJAM
/// ```
public enum TransferPayloadParser {

    public static let header = "DSTK1"

    /// Source tag to `(source, isAnimated)`. An optional trailing `a` means
    /// animated — `d`/`da` for Discord, `7`/`7a` for 7TV — still one
    /// whitespace-delimited token, so QR capacity is unchanged and the
    /// three-way split below still works unmodified.
    private static let sources: [String: (StickerSource, Bool)] = [
        "d": (.pasted, false),
        "da": (.pasted, true),
        "7": (.sevenTV, false),
        "7a": (.sevenTV, true),
    ]

    /// True when the first non-blank line is exactly the header. Lets the
    /// paste flow tell a payload from Discord markup without asking the user
    /// which they copied.
    ///
    /// Scans line by line via `enumerateLines`, stopping at the first
    /// non-blank one, rather than splitting the whole string the way
    /// `parse` must. For the common case — the header on line one — that's
    /// one line inspected instead of materializing every line of a payload
    /// that may run to hundreds.
    public static func looksLikePayload(_ text: String) -> Bool {
        var firstMeaningfulLine: String?
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            firstMeaningfulLine = trimmed
            stop = true
        }
        return firstMeaningfulLine == header
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
            // Machine-generated, unlike pasted Discord markup, so it isn't
            // bounded by what a human is willing to select and copy. Stops
            // rather than merely skipping the rest, since a payload at or
            // past the cap has nothing more worth scanning for.
            if result.count >= StickerLimits.maxPayloadEmoji { break }

            // Split into tag, id, and the rest. The id never contains a
            // space, so three components with the remainder kept whole is
            // unambiguous and lets names contain spaces.
            let parts = line.split(separator: " ", maxSplits: 2,
                                   omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let (source, isAnimated) = sources[String(parts[0])]
            else { continue }

            let id = String(parts[1])
            let name = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !name.isEmpty, seen.insert(id).inserted
            else { continue }

            let truncatedName = name.count > StickerLimits.maxStickerNameLength
                ? String(name.prefix(StickerLimits.maxStickerNameLength))
                : name

            // The producing side (the web page) knows whether an emote is
            // animated — 7TV's own API returns an `animated` boolean per
            // emote — so the tag carries that fact rather than making the
            // phone guess. 7TV does *not* self-heal a wrong guess the way
            // Discord's 415 does: requesting `4x.webp` for an animated
            // emote returns HTTP 200 with a valid (but wrong-format) image,
            // so a guess that misses here fails silently, not loudly.
            result.append(ParsedEmoji(id: id, name: truncatedName,
                                      isAnimated: isAnimated, source: source))
        }

        return result
    }
}
