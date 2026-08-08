# Transfer Payload & 7TV — Implementation Plan (iOS side)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the app to accept a `DSTK1` transfer payload — a compact list of emoji from any supported source — and to fetch 7TV emotes as well as Discord ones.

**Architecture:** A new `TransferPayloadParser` turns pasted `DSTK1` text into emoji descriptors, mirroring `EmojiMarkupParser`'s pure-function shape. `StickerSource` gains `.sevenTV`, and `EmojiDownloader` builds its URL from the entry's source rather than hardcoding Discord's CDN. The existing paste button recognizes both formats from the first line, so the user never has to say which they copied.

**Tech Stack:** Swift 5 language mode, UIKit, Messages.framework, XCTest. No new dependencies.

**Source spec:** `docs/superpowers/specs/2026-08-08-desktop-companion-design.md`
**Verified API facts:** `docs/superpowers/plans/7tv-api-findings.md` — read this; it overrides assumptions in the spec.

**Scope note:** the spec also covers the static web page that *produces* these payloads. That is a separate product in a different language with no Swift, no Xcode, and its own testing story. It gets its own plan. This one is the consuming half, and it is independently valuable: a payload can be hand-written or produced by any script.

## Global Constraints

Every task's requirements implicitly include this section.

- **Toolchain:** Xcode 26.6, Swift 6.3.3, iOS 26.5 SDK. **Swift Language Version is 5** — do not change it.
- **Deployment target iOS 17.0.**
- **Never** hand-author or hand-edit `project.pbxproj`. Synchronized folder groups add new files automatically.
- **Never** create, modify, or delete any `.xcscheme`.
- **No App Groups entitlement** in any target.
- **No third-party dependencies.**
- **Simulator is `iPhone 17 Pro`.**
- **`MSSticker` limits:** file ≤ 500,000 bytes; both dimensions 100–618 inclusive.
- **`StickerSource` is String-raw-valued and persisted** — cases may be **added**, never renamed or removed.
- **Memory:** the extension is killed between 40 and 120 MB.
- **7TV CDN, verified:** `https://cdn.7tv.app/emote/<id>/4x.gif` for animated, `https://cdn.7tv.app/emote/<id>/4x.webp` for static. **`.gif` is not advertised in the API's own `host.files` list but is served and returns valid GIF89a.** It is chosen over animated WebP because ImageIO's animated-WebP frame support is unverified on this platform, whereas GIF is already handled by `AnimatedStickerProcessor`.
- **`4x.webp` can exceed 500,000 bytes on the wire** (572 KB measured). That is fine — everything is re-encoded — but the fetch must respect the existing byte bound rather than assuming emotes are small.
- **Baseline: 146 tests passing.** This plan takes it to **169**.

**Commands used throughout:**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme DiscordStickersMessages \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

---

### Task 1: `.sevenTV` source and source-driven URLs

`EmojiDownloader` currently hardcodes Discord's CDN. Teaching it to build a URL from the entry's source is what makes a second emote service possible at all.

**Files:**
- Modify: `DiscordStickers/StickerKit/StickerEntry.swift`
- Modify: `DiscordStickers/StickerKit/ParsedEmoji.swift`
- Modify: `DiscordStickers/StickerKit/EmojiDownloader.swift`
- Test: `DiscordStickers/StickerKitTests/StickerEntryTests.swift`
- Test: `DiscordStickers/StickerKitTests/EmojiDownloaderTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `StickerSource` gains `case sevenTV = "sevenTV"`, **added alongside** the existing cases.
  - `ParsedEmoji` gains `public let source: StickerSource`, defaulting to `.pasted` in its initializer so every existing call site keeps compiling.
  - `EmojiDownloader` builds its URL from `ParsedEmoji.source` and `isAnimated`.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `StickerEntryTests` class:

```swift
    func testSevenTVSourceRoundTrips() throws {
        let entry = StickerEntry(id: "01G3WEGZN0000ET2J0MQP5YJ0G", name: "GAMBA",
                                 source: .sevenTV,
                                 addedAt: Date(timeIntervalSince1970: 0),
                                 useCount: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            StickerEntry.self, from: try encoder.encode(entry)
        )
        XCTAssertEqual(decoded.source, .sevenTV)
    }

    func testSevenTVRawValueIsStable() {
        // Persisted in manifest.json on the user's device. Renaming it would
        // orphan every 7TV sticker already stored.
        XCTAssertEqual(StickerSource.sevenTV.rawValue, "sevenTV")
    }
```

Append inside the existing `EmojiDownloaderTests` class:

```swift
    private func sevenTVEmoji(_ id: String, _ name: String,
                              animated: Bool) -> ParsedEmoji {
        ParsedEmoji(id: id, name: name, isAnimated: animated, source: .sevenTV)
    }

    func testRequestsTheSevenTVCDNForSevenTVEmotes() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([
            sevenTVEmoji("01G3WEGZN0000ET2J0MQP5YJ0G", "GAMBA", animated: false)
        ])

        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.first)
        XCTAssertEqual(url.host, "cdn.7tv.app")
        XCTAssertEqual(url.path,
                       "/emote/01G3WEGZN0000ET2J0MQP5YJ0G/4x.webp")
    }

    func testRequestsGIFForAnimatedSevenTVEmotes() async throws {
        // .gif is not advertised in 7TV's own host.files list but is served,
        // and is chosen over animated WebP because ImageIO's animated-WebP
        // frame support is unverified on this platform.
        StubURLProtocol.handler = { _ in
            (200, self.temp.makeAnimatedGIFData(frameCount: 6))
        }

        _ = await makeDownloader().download([
            sevenTVEmoji("01G3WEGZN0000ET2J0MQP5YJ0G", "GAMBA", animated: true)
        ])

        XCTAssertEqual(StubURLProtocol.requestedURLs.first?.lastPathComponent,
                       "4x.gif")
    }

    func testStoresTheSevenTVSourceOnTheEntry() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([
            sevenTVEmoji("01G3WEGZN0000ET2J0MQP5YJ0G", "GAMBA", animated: false)
        ])

        XCTAssertEqual(store.all().first?.source, .sevenTV)
    }

    func testDiscordEmojiStillUseTheDiscordCDN() async throws {
        // The regression guard for this task: adding a second source must not
        // change where Discord emoji come from.
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([emoji("111", "wave")])

        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.first)
        XCTAssertEqual(url.host, "cdn.discordapp.com")
        XCTAssertEqual(url.path, "/emojis/111.png")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `type 'StickerSource' has no member 'sevenTV'` and `extra argument 'source' in call`.

- [ ] **Step 3: Add the source case**

In `DiscordStickers/StickerKit/StickerEntry.swift`, add `case sevenTV` to the `StickerSource` enum, after the existing cases. Do not reorder or rename anything already there.

- [ ] **Step 4: Give `ParsedEmoji` a source**

In `DiscordStickers/StickerKit/ParsedEmoji.swift`, add the property and a defaulted initializer parameter:

```swift
/// One custom emoji recovered from pasted markup or a transfer payload.
public struct ParsedEmoji: Equatable, Hashable {
    public let id: String
    public let name: String
    public let isAnimated: Bool

    /// Which service hosts this emoji. Defaults to `.pasted` — Discord — so
    /// every existing call site keeps compiling, and so `EmojiMarkupParser`,
    /// which only ever produces Discord emoji, needs no change.
    public let source: StickerSource

    public init(id: String, name: String, isAnimated: Bool,
                source: StickerSource = .pasted) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
        self.source = source
    }
}
```

- [ ] **Step 5: Build the URL from the source**

In `DiscordStickers/StickerKit/EmojiDownloader.swift`, replace the private `fetch(id:animated:)` method's URL construction so it takes the source into account. Change its signature to `fetch(_ emoji: ParsedEmoji, animated: Bool) -> FetchResult` and derive the URL:

```swift
    /// Discord carries no `size` parameter — measured as ignored for both its
    /// formats. 7TV's `.gif` is not advertised in its own `host.files` list
    /// but is served, and is preferred over animated WebP because ImageIO's
    /// animated-WebP frame support is unverified here.
    private static func url(for emoji: ParsedEmoji, animated: Bool) -> URL? {
        switch emoji.source {
        case .pasted, .server, .photo, .link:
            let ext = animated ? "gif" : "png"
            return URL(string:
                "https://cdn.discordapp.com/emojis/\(emoji.id).\(ext)")
        case .sevenTV:
            let file = animated ? "4x.gif" : "4x.webp"
            return URL(string:
                "https://cdn.7tv.app/emote/\(emoji.id)/\(file)")
        }
    }
```

Update `fetchOne` to pass the whole `ParsedEmoji` through, and `commit` to record `emoji.source` instead of the hardcoded `.pasted`.

**The 415 self-heal stays exactly as it is.** It is a Discord behaviour — 7TV returns 404, not 415, for a wrong variant — and retrying with the other extension is harmless either way.

- [ ] **Step 6: Run tests to verify they pass**

Run the test command. Expected: PASS, **152 tests total** (146 + 6 new).

All 146 pre-existing tests must pass unchanged. `testDiscordEmojiStillUseTheDiscordCDN` is the explicit guard, but the whole existing downloader suite is the real proof.

- [ ] **Step 7: Commit**

```bash
git add DiscordStickers/StickerKit/StickerEntry.swift \
        DiscordStickers/StickerKit/ParsedEmoji.swift \
        DiscordStickers/StickerKit/EmojiDownloader.swift \
        DiscordStickers/StickerKitTests/StickerEntryTests.swift \
        DiscordStickers/StickerKitTests/EmojiDownloaderTests.swift
git commit -m "feat: build emoji URLs from their source, adding 7TV"
```

---

### Task 2: `TransferPayloadParser`

A pure function, so it gets the same exhaustive treatment as `EmojiMarkupParser` and `LinkParser`.

**Files:**
- Create: `DiscordStickers/StickerKit/TransferPayloadParser.swift`
- Test: `DiscordStickers/StickerKitTests/TransferPayloadParserTests.swift`

**Interfaces:**
- Consumes: `ParsedEmoji` and `StickerSource` (Task 1).
- Produces:
  - `public enum TransferPayloadParser`
  - `public static let header = "DSTK1"`
  - `public static func looksLikePayload(_ text: String) -> Bool` — true when the first non-blank line is exactly the header.
  - `public static func parse(_ text: String) -> [ParsedEmoji]` — empty when the header is absent.

**Format**, from the spec: line 1 is the literal `DSTK1`; every later line is `<sourceTag> <id> <name>`, where the tag is one character (`d` = Discord, `7` = 7TV), the id contains no spaces, and the name runs to end of line. Blank and unparseable lines are skipped, never fatal.

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/TransferPayloadParserTests.swift`:

```swift
import XCTest
@testable import StickerKit

final class TransferPayloadParserTests: XCTestCase {

    private let valid = """
    DSTK1
    d 1481800758532903104 67
    d 1095953169969860649 NOWAY
    7 01G3WEGZN0000ET2J0MQP5YJ0G GAMBA
    """

    func testParsesEveryLine() {
        let emoji = TransferPayloadParser.parse(valid)

        XCTAssertEqual(emoji.map(\.id), [
            "1481800758532903104",
            "1095953169969860649",
            "01G3WEGZN0000ET2J0MQP5YJ0G",
        ])
        XCTAssertEqual(emoji.map(\.name), ["67", "NOWAY", "GAMBA"])
    }

    func testMapsSourceTags() {
        let emoji = TransferPayloadParser.parse(valid)
        XCTAssertEqual(emoji.map(\.source), [.pasted, .pasted, .sevenTV])
    }

    func testRejectsTextWithoutTheHeader() {
        XCTAssertTrue(TransferPayloadParser.parse(
            "d 111 wave\n7 222 GAMBA"
        ).isEmpty)
        XCTAssertTrue(TransferPayloadParser.parse("").isEmpty)
        XCTAssertTrue(TransferPayloadParser.parse("hello").isEmpty)
    }

    func testRejectsAWrongHeaderVersion() {
        // A future DSTK2 must not be half-parsed as DSTK1.
        XCTAssertTrue(TransferPayloadParser.parse(
            "DSTK2\nd 111 wave"
        ).isEmpty)
    }

    func testHeaderOnlyPayloadYieldsNothing() {
        XCTAssertTrue(TransferPayloadParser.parse("DSTK1").isEmpty)
        XCTAssertTrue(TransferPayloadParser.parse("DSTK1\n").isEmpty)
    }

    func testNamesMayContainSpaces() {
        // The id never contains a space, so a two-way split is unambiguous
        // and the remainder is the name.
        let emoji = TransferPayloadParser.parse("DSTK1\nd 111 happy cat face")
        XCTAssertEqual(emoji.first?.name, "happy cat face")
    }

    func testSkipsMalformedLinesWithoutLosingGoodOnes() {
        // One bad line must not cost the other two hundred.
        let emoji = TransferPayloadParser.parse("""
        DSTK1
        d 111 good
        garbage
        d
        x 333 unknown-tag
        7 444 alsogood
        """)

        XCTAssertEqual(emoji.map(\.name), ["good", "alsogood"])
    }

    func testSkipsBlankLines() {
        let emoji = TransferPayloadParser.parse("DSTK1\n\nd 111 wave\n\n")
        XCTAssertEqual(emoji.count, 1)
    }

    func testToleratesCarriageReturns() {
        // Text copied from a browser on Windows arrives CRLF-terminated.
        let emoji = TransferPayloadParser.parse("DSTK1\r\nd 111 wave\r\n")
        XCTAssertEqual(emoji.first?.name, "wave")
    }

    func testToleratesLeadingAndTrailingWhitespace() {
        let emoji = TransferPayloadParser.parse("  \n DSTK1 \n d 111 wave \n")
        XCTAssertEqual(emoji.first?.name, "wave")
    }

    func testDedupesByIDKeepingFirstOccurrence() {
        // Chunked payloads overlap by design, and the same emoji may appear
        // in two scans. Matches EmojiMarkupParser's policy exactly.
        let emoji = TransferPayloadParser.parse("""
        DSTK1
        d 111 first
        d 222 other
        d 111 second
        """)

        XCTAssertEqual(emoji.map(\.name), ["first", "other"])
    }

    func testAnimationIsNotEncodedInThePayload() {
        // The payload carries no animation flag; the downloader's 415 retry
        // and 7TV's own metadata settle it. Every parsed emoji starts static.
        XCTAssertFalse(TransferPayloadParser.parse(valid).contains { $0.isAnimated })
    }

    func testLooksLikePayloadRecognisesTheHeader() {
        XCTAssertTrue(TransferPayloadParser.looksLikePayload(valid))
        XCTAssertTrue(TransferPayloadParser.looksLikePayload("  DSTK1\nd 1 a"))
        XCTAssertFalse(TransferPayloadParser.looksLikePayload("<:wave:111>"))
        XCTAssertFalse(TransferPayloadParser.looksLikePayload(""))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `cannot find 'TransferPayloadParser' in scope`.

- [ ] **Step 3: Write it**

Create `DiscordStickers/StickerKit/TransferPayloadParser.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS, **165 tests total** (152 + 13 new).

- [ ] **Step 5: Commit**

```bash
git add DiscordStickers/StickerKit/TransferPayloadParser.swift \
        DiscordStickers/StickerKitTests/TransferPayloadParserTests.swift
git commit -m "feat: parse DSTK1 transfer payloads"
```

---

### Task 3: Recognize payloads in the existing paste flow

**No new button.** A user who copies from the web page and taps the paste button they already know should simply see it work — the app can tell the two formats apart from the first line, and making the user choose would be asking them to explain something the software already knows.

**Files:**
- Modify: `DiscordStickers/StickerKit/PasteViewController.swift`
- Test: `DiscordStickers/StickerKitTests/PasteSummaryTests.swift`

**Interfaces:**
- Consumes: `TransferPayloadParser` (Task 2).
- Produces: no new public API.

- [ ] **Step 1: Write the failing test**

Append to `DiscordStickers/StickerKitTests/PasteSummaryTests.swift`:

```swift
    func testPayloadAndMarkupAreDistinguishedByTheirFirstLine() {
        // The paste flow must route on content, never on a user choice.
        let payload = "DSTK1\nd 111 wave"
        let markup = "<:wave:111> <:smile:222>"

        XCTAssertTrue(TransferPayloadParser.looksLikePayload(payload))
        XCTAssertFalse(TransferPayloadParser.looksLikePayload(markup))

        XCTAssertEqual(TransferPayloadParser.parse(payload).count, 1)
        XCTAssertEqual(EmojiMarkupParser.parse(markup).count, 2)

        // Each parser must ignore the other's format outright, so a
        // misrouted paste yields nothing rather than something wrong.
        XCTAssertTrue(TransferPayloadParser.parse(markup).isEmpty)
        XCTAssertTrue(EmojiMarkupParser.parse(payload).isEmpty)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run the test command. Expected: FAIL — `cannot find 'TransferPayloadParser' in scope` if Task 2 was skipped; otherwise it passes trivially and you should still proceed, since the routing change below is what the task delivers.

- [ ] **Step 3: Route on content in `handle(_:)`**

In `DiscordStickers/StickerKit/PasteViewController.swift`, find the private `handle(_ text: String)` method. Its first statement currently parses Discord markup. Replace that single parse with a content-routed one, leaving everything after it — the empty check, the reachability check, the download, the summary — exactly as it is:

```swift
        // Route on the payload's own first line rather than asking the user
        // which format they copied. Both parsers reject the other's format
        // outright, so a misroute yields nothing rather than something wrong.
        let parsed = TransferPayloadParser.looksLikePayload(text)
            ? TransferPayloadParser.parse(text)
            : EmojiMarkupParser.parse(text)
```

Then widen the empty-input message, which currently names Discord only:

```swift
        guard !parsed.isEmpty else {
            statusLabel.text = "No emoji found in what you pasted."
            return
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS, **166 tests total** (165 + 1 new).

- [ ] **Step 5: Verify the extension builds**

Run the extension build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/PasteViewController.swift \
        DiscordStickers/StickerKitTests/PasteSummaryTests.swift
git commit -m "feat: recognise DSTK1 payloads in the existing paste flow"
```

---

### Task 4: Preserve source through backup and restore

`ManifestTransfer.restore` rebuilds `ParsedEmoji` values from a backup. It now has to carry `source`, or every 7TV sticker comes back requested from Discord's CDN.

This is the third time this exact failure has appeared in this file — `favoritedAt`, then `isAnimated`, now `source`. Each was a field present in the model and dropped on the restore path.

**Files:**
- Modify: `DiscordStickers/StickerKit/ManifestTransfer.swift`
- Test: `DiscordStickers/StickerKitTests/ManifestTransferTests.swift`

**Interfaces:**
- Consumes: `ParsedEmoji.source` (Task 1).
- Produces: no API change.

- [ ] **Step 1: Write the failing test**

Append to the existing `ManifestTransferTests` class:

```swift
    func testRestoreRequestsSevenTVEmotesFromSevenTV() async throws {
        let entries = [
            StickerEntry(id: "01G3WEGZN0000ET2J0MQP5YJ0G", name: "GAMBA",
                         source: .sevenTV,
                         addedAt: Date(timeIntervalSince1970: 1000),
                         useCount: 0),
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 2000),
                         useCount: 0),
        ]

        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await ManifestTransfer.restore(entries, store: store,
                                           downloader: makeDownloader())

        let hosts = Set(StubURLProtocol.requestedURLs.compactMap(\.host))
        XCTAssertEqual(hosts, ["cdn.7tv.app", "cdn.discordapp.com"],
                       "each sticker must be fetched from its own service")
        XCTAssertEqual(store.all().count, 2)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run the test command. Expected: FAIL — both requests go to `cdn.discordapp.com`, so the host set has one element.

- [ ] **Step 3: Carry the source through**

In `DiscordStickers/StickerKit/ManifestTransfer.swift`, find where `restore` maps entries to `ParsedEmoji` values and add the source alongside the id, name and animated flag it already carries:

```swift
                ParsedEmoji(id: $0.id, name: $0.name,
                            isAnimated: $0.isAnimated, source: $0.source)
```

- [ ] **Step 4: Update the type's doc comment**

It lists the values a backup rescues. Add `source` to that list, noting it must survive because the downloader now chooses a CDN from it — so losing it would send 7TV ids to Discord and report the user's own emotes as missing.

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: PASS, **167 tests total** (166 + 1 new).

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/ManifestTransfer.swift \
        DiscordStickers/StickerKitTests/ManifestTransferTests.swift
git commit -m "fix: carry source through backup and restore"
```

---

### Task 5: A worked payload, end to end

A single integration test proving the whole chain — payload text in, stickers in the store, each fetched from the right service. Every unit below it is already covered; this is the one that proves they are wired together.

**Files:**
- Test: `DiscordStickers/StickerKitTests/TransferPayloadIntegrationTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: nothing.

- [ ] **Step 1: Write the test**

Create `DiscordStickers/StickerKitTests/TransferPayloadIntegrationTests.swift`:

```swift
import XCTest
import UIKit
@testable import StickerKit

final class TransferPayloadIntegrationTests: XCTestCase {

    private var temp: TempDirectory!
    private var store: StickerStore!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        store = try StickerStore(root: temp.url, writeDebounce: 0)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        store = nil
        temp = nil
    }

    private func pngData(width: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: width)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testAPayloadBecomesStickersFromTheRightServices() async throws {
        let payload = """
        DSTK1
        d 1481800758532903104 67
        7 01G3WEGZN0000ET2J0MQP5YJ0G GAMBA
        """

        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let parsed = TransferPayloadParser.parse(payload)
        XCTAssertEqual(parsed.count, 2)

        let downloader = EmojiDownloader(
            store: store, session: StubURLProtocol.makeSession()
        )
        let outcome = await downloader.download(parsed)

        XCTAssertEqual(outcome.added.count, 2)

        let bySource = Dictionary(
            uniqueKeysWithValues: store.all().map { ($0.source, $0) }
        )
        XCTAssertEqual(bySource[.pasted]?.name, "67")
        XCTAssertEqual(bySource[.sevenTV]?.name, "GAMBA")

        let hosts = Set(StubURLProtocol.requestedURLs.compactMap(\.host))
        XCTAssertEqual(hosts, ["cdn.discordapp.com", "cdn.7tv.app"])
    }

    func testAPayloadSurvivesBackupAndRestore() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let downloader = EmojiDownloader(
            store: store, session: StubURLProtocol.makeSession()
        )
        _ = await downloader.download(TransferPayloadParser.parse("""
        DSTK1
        d 1481800758532903104 67
        7 01G3WEGZN0000ET2J0MQP5YJ0G GAMBA
        """))

        let backup = ManifestTransfer.export(from: store)

        // A fresh device: new store, same backup text.
        let secondTemp = try TempDirectory()
        let secondStore = try StickerStore(root: secondTemp.url, writeDebounce: 0)
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await ManifestTransfer.restore(
            ManifestTransfer.parseImport(backup),
            store: secondStore,
            downloader: EmojiDownloader(store: secondStore,
                                        session: StubURLProtocol.makeSession())
        )

        XCTAssertEqual(secondStore.all().count, 2)
        XCTAssertEqual(
            Set(secondStore.all().map(\.source)), [.pasted, .sevenTV]
        )
        XCTAssertEqual(
            Set(StubURLProtocol.requestedURLs.compactMap(\.host)),
            ["cdn.discordapp.com", "cdn.7tv.app"]
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run the test command. Expected: PASS, **169 tests total** (167 + 2 new).

If either fails, it is a real integration gap — the units all pass individually, so a failure here means they are wired together wrongly. Report it rather than adjusting the test.

- [ ] **Step 3: Commit**

```bash
git add DiscordStickers/StickerKitTests/TransferPayloadIntegrationTests.swift
git commit -m "test: prove a DSTK1 payload survives download and restore"
```

---

## Deferred

- **The static web page** that produces these payloads. Its own plan — different language, no Xcode, browser-based tests.
- **BetterTTV and FrankerFaceZ.** The payload's source tag makes them additive; 7TV alone establishes the pattern.
- **Native 7TV browsing on the phone.** The page covers the bulk case and this would duplicate discovery logic on the constrained side.
- **Resolving a Twitch username to a numeric id.** The REST API takes an id; a username lookup needs 7TV's GraphQL endpoint. The page can ask for an emote-set id or URL instead, which has no undocumented dependency.
- **A short-link service** so QR codes carry a URL rather than data. Removes the capacity limit and requires a server — the one thing the spec rules out.
