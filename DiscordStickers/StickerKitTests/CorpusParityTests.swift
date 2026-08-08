import XCTest
@testable import StickerKit

/// Runs `web/corpus.json` through `EmojiMarkupParser`, the same corpus the
/// desktop page's `test.js` runs through its own parser.
///
/// Two implementations of one grammar drift silently otherwise: the page would
/// show emoji the phone then refuses to import, with nothing anywhere reporting
/// a problem. Changing the regex in `parse.js` without changing
/// `EmojiMarkupParser.swift` — or the reverse — turns this red.
final class CorpusParityTests: XCTestCase {

    private struct Case: Decodable {
        let why: String
        let input: String
        let expect: [Expected]
    }

    private struct Expected: Decodable {
        let id: String
        let name: String
        let animated: Bool
    }

    /// Located from `#filePath` rather than a bundle resource: the corpus is
    /// shared with the web page and lives outside any target, so copying it
    /// into the test bundle would create a second copy free to drift from the
    /// one the page actually reads — reintroducing exactly the problem this
    /// test exists to prevent.
    private func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StickerKitTests
            .deletingLastPathComponent()   // DiscordStickers
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("web/corpus.json")
    }

    func testParserMatchesSharedCorpus() throws {
        let url = corpusURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "corpus not found at \(url.path) — has web/ moved?")

        let cases = try JSONDecoder().decode([Case].self,
                                             from: Data(contentsOf: url))

        // Load-bearing. If the path ever breaks and `decode` yields an empty
        // array, the loop below iterates nothing and passes with flying
        // colours — the same vacuous-pass hazard as an empty test.
        XCTAssertGreaterThan(cases.count, 5,
                             "corpus looks truncated — parity would pass vacuously")

        for c in cases {
            let got = EmojiMarkupParser.parse(c.input)
            XCTAssertEqual(got.count, c.expect.count, "case: \(c.why)")
            guard got.count == c.expect.count else { continue }
            for (actual, expected) in zip(got, c.expect) {
                XCTAssertEqual(actual.id, expected.id, "case: \(c.why)")
                XCTAssertEqual(actual.name, expected.name, "case: \(c.why)")
                XCTAssertEqual(actual.isAnimated, expected.animated, "case: \(c.why)")
            }
        }
    }
}
