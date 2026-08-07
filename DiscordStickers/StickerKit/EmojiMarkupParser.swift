import Foundation

/// Extracts Discord custom-emoji markup (`<:name:id>` / `<a:name:id>`) from
/// arbitrary text. Pure: no I/O, no state.
public enum EmojiMarkupParser {

    private static let pattern = try! NSRegularExpression(
        pattern: "<(a)?:([A-Za-z0-9_]+):(\\d+)>"
    )

    /// Duplicate IDs are collapsed to their first occurrence, and the
    /// original left-to-right order is preserved.
    public static func parse(_ input: String) -> [ParsedEmoji] {
        let range = NSRange(input.startIndex..., in: input)
        var seen = Set<String>()
        var result: [ParsedEmoji] = []

        for match in pattern.matches(in: input, range: range) {
            guard
                let nameRange = Range(match.range(at: 2), in: input),
                let idRange = Range(match.range(at: 3), in: input)
            else { continue }

            let id = String(input[idRange])
            guard seen.insert(id).inserted else { continue }

            result.append(ParsedEmoji(
                id: id,
                name: String(input[nameRange]),
                isAnimated: match.range(at: 1).location != NSNotFound
            ))
        }
        return result
    }
}
