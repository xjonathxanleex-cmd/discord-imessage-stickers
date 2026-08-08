# Link Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user paste a link to any image on the internet and turn it into a named, searchable sticker.

**Architecture:** A parsed link becomes one or more `StickerDraft`s, which the user names on a review screen before anything is stored. Drafts go through the existing normalization pipeline, get a content-addressed id, and are committed by a `StickerCommitter` extracted from `EmojiDownloader` so both paths share one implementation of the manifest invariant.

**Tech Stack:** Swift 5 language mode, UIKit, CryptoKit, Messages.framework, XCTest. No new dependencies.

**Source spec:** `docs/superpowers/specs/2026-08-08-import-sources-design.md`

**Scope note:** the spec also covers a photo-library picker. That is deliberately **not** in this plan. It shares the review screen built here, and its viability inside a Messages extension is unverified (`PHPickerViewController` is out-of-process, and this project has twice had a documented API misbehave in an extension). Splitting it out means a picker failure cannot strand link import. It becomes a short follow-on plan once this lands.

## Global Constraints

Every task's requirements implicitly include this section.

- **Toolchain:** Xcode 26.6, Swift 6.3.3, iOS 26.5 SDK. **Swift Language Version is 5** — do not change it.
- **Deployment target iOS 17.0.**
- **Never** hand-author or hand-edit `project.pbxproj`. Synchronized folder groups add new files to their target automatically.
- **Never** create, modify, or delete any `.xcscheme`.
- **No App Groups entitlement** in any target.
- **No third-party dependencies.** CryptoKit is a system framework and is allowed.
- **Simulator is `iPhone 17 Pro`.**
- **`MSSticker` limits:** file ≤ 500,000 bytes; both dimensions 100–618 inclusive.
- **Manifest invariant:** nothing enters `manifest.json` without an `MSSticker` having been constructed from its file first.
- **`StickerSource` is a String-raw-valued Codable enum** — cases may be **added** but never renamed or removed, since an unknown case fails to decode the entire entry.
- **Memory:** the extension is killed between 40 and 120 MB. Never hold decoded images in a collection.
- **Accept any format iOS can decode; always store PNG (or APNG for animated).** No format allowlist.
- **Baseline: 88 tests passing.** This plan takes it to **122**.

**Commands used throughout:**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme DiscordStickersMessages \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

---

### Task 1: New sources, and extract the shared commit path

`EmojiDownloader.commit` currently owns the only implementation of the manifest invariant — write a temp file, prove `MSSticker` constructs from it, hand it to the store. Link import needs exactly that, and duplicating it is how the two drift apart. Extract it first, with existing tests proving the extraction changed nothing.

**Files:**
- Modify: `DiscordStickers/StickerKit/StickerEntry.swift`
- Create: `DiscordStickers/StickerKit/StickerCommitter.swift`
- Modify: `DiscordStickers/StickerKit/EmojiDownloader.swift`
- Test: `DiscordStickers/StickerKitTests/StickerEntryTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `StickerSource` gains `case photo` and `case link`, **added alongside** `pasted` and `server`, never replacing them.
  - `public enum StickerCommitter` with
    `public static func commit(id: String, name: String, source: StickerSource, isAnimated: Bool, data: Data, to store: StickerStore) -> Bool` — true on success, false if the bytes fail `MSSticker` construction or the store rejects them. Always cleans up its temp file.

- [ ] **Step 1: Write the failing test**

Append inside the existing `StickerEntryTests` class:

```swift
    func testAllStickerSourcesRoundTripThroughJSON() throws {
        // Cases may be added but never renamed or removed: StickerSource is
        // String-raw-valued, so an unknown case fails to decode the entire
        // entry, silently losing a sticker the user already had.
        for source in [StickerSource.pasted, .server, .photo, .link] {
            let entry = StickerEntry(id: "1", name: "a", source: source,
                                     addedAt: Date(timeIntervalSince1970: 0),
                                     useCount: 0)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let decoded = try decoder.decode(
                StickerEntry.self, from: try encoder.encode(entry)
            )
            XCTAssertEqual(decoded.source, source)
        }
    }

    func testStickerSourceRawValuesAreStable() {
        // These strings are written into manifest.json on the user's device.
        // Changing one orphans every sticker already stored with it.
        XCTAssertEqual(StickerSource.pasted.rawValue, "pasted")
        XCTAssertEqual(StickerSource.server.rawValue, "server")
        XCTAssertEqual(StickerSource.photo.rawValue, "photo")
        XCTAssertEqual(StickerSource.link.rawValue, "link")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `type 'StickerSource' has no member 'photo'`.

- [ ] **Step 3: Add the cases**

In `DiscordStickers/StickerKit/StickerEntry.swift`, replace the `StickerSource` enum:

```swift
/// Where a sticker came from.
///
/// String-raw-valued and persisted in `manifest.json`, so cases may be
/// **added** freely but never renamed or removed — an unknown raw value
/// fails to decode the whole entry, silently losing a sticker the user
/// already had.
public enum StickerSource: String, Codable {
    case pasted
    case server
    case photo
    case link
}
```

- [ ] **Step 4: Extract the committer**

Create `DiscordStickers/StickerKit/StickerCommitter.swift`:

```swift
import Foundation
import Messages

/// Writes sticker bytes to disk through the one path that upholds the
/// manifest invariant: nothing reaches `manifest.json` without an
/// `MSSticker` having been constructed from its file first.
///
/// Extracted from `EmojiDownloader` so downloads and local imports share a
/// single implementation. Two copies of this logic would drift, and the
/// thing that drifts is the invariant that keeps the grid from throwing
/// mid-scroll on a device with no debugger attached.
public enum StickerCommitter {

    /// Returns `true` when the sticker was stored, `false` when the bytes
    /// could not become an `MSSticker` or the store refused them. Never
    /// leaves a temp file behind on either path.
    public static func commit(
        id: String,
        name: String,
        source: StickerSource,
        isAnimated: Bool,
        data: Data,
        to store: StickerStore
    ) -> Bool {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id)-\(UUID().uuidString).png")

        do {
            try data.write(to: tempURL)

            // The decisive check. Constructing here rather than in
            // cellForItemAt turns a scroll-time crash into an import-time
            // skip, and is what upholds the manifest invariant.
            _ = try MSSticker(contentsOfFileURL: tempURL,
                              localizedDescription: name)

            try store.add(
                StickerEntry(id: id, name: name, source: source,
                             addedAt: Date(), useCount: 0, favoritedAt: nil,
                             isAnimated: isAnimated),
                movingFileFrom: tempURL
            )
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}
```

- [ ] **Step 5: Route the downloader through it**

In `DiscordStickers/StickerKit/EmojiDownloader.swift`, replace the entire body of the private `commit(_:data:animated:)` method with a call to the shared committer, keeping its signature and return type exactly as they are:

```swift
    private func commit(_ emoji: ParsedEmoji, data: Data, animated: Bool) -> ItemResult {
        StickerCommitter.commit(
            id: emoji.id, name: emoji.name, source: .pasted,
            isAnimated: animated, data: data, to: store
        ) ? .added(emoji.id) : .unusable(emoji.id)
    }
```

Delete any now-unused imports only if the compiler flags them; leave the rest of the file untouched.

- [ ] **Step 6: Run tests to verify they pass**

Run the test command. Expected: PASS, **90 tests total** (88 + 2 new).

**This is the important part of this task:** all 88 pre-existing tests must pass unchanged. They are the proof the extraction changed no behaviour. If any existing test needs editing, the extraction is wrong — report it rather than adjusting the test.

- [ ] **Step 7: Commit**

```bash
git add DiscordStickers/StickerKit/StickerEntry.swift \
        DiscordStickers/StickerKit/StickerCommitter.swift \
        DiscordStickers/StickerKit/EmojiDownloader.swift \
        DiscordStickers/StickerKitTests/StickerEntryTests.swift
git commit -m "refactor: extract StickerCommitter and add photo/link sources"
```

---

### Task 2: Content-addressed identity

A Discord emoji has a snowflake id. An arbitrary image has nothing, and `StickerStore` needs an id that is unique and stable across re-adds.

**Files:**
- Create: `DiscordStickers/StickerKit/ContentHash.swift`
- Test: `DiscordStickers/StickerKitTests/ContentHashTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum ContentHash { public static func id(for data: Data) -> String }` — returns `"sha256-"` followed by 64 lowercase hex characters.

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/ContentHashTests.swift`:

```swift
import XCTest
@testable import StickerKit

final class ContentHashTests: XCTestCase {

    func testSameBytesProduceTheSameID() {
        let data = Data("hello".utf8)
        XCTAssertEqual(ContentHash.id(for: data), ContentHash.id(for: data))
    }

    func testDifferentBytesProduceDifferentIDs() {
        XCTAssertNotEqual(ContentHash.id(for: Data("hello".utf8)),
                          ContentHash.id(for: Data("hello!".utf8)))
    }

    func testIDIsPrefixedAndFixedLength() {
        let id = ContentHash.id(for: Data("hello".utf8))
        XCTAssertTrue(id.hasPrefix("sha256-"))
        // "sha256-" plus 64 hex characters.
        XCTAssertEqual(id.count, 71)
        XCTAssertTrue(id.dropFirst(7).allSatisfy {
            $0.isHexDigit && !$0.isUppercase
        })
    }

    func testKnownVectorSoTheHashIsActuallySHA256() {
        // The SHA-256 of "abc" is a published constant. Without this the
        // tests above would pass for any deterministic function, including
        // a broken one.
        XCTAssertEqual(
            ContentHash.id(for: Data("abc".utf8)),
            "sha256-ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testEmptyDataStillProducesAnID() {
        XCTAssertTrue(ContentHash.id(for: Data()).hasPrefix("sha256-"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `cannot find 'ContentHash' in scope`.

- [ ] **Step 3: Write it**

Create `DiscordStickers/StickerKit/ContentHash.swift`:

```swift
import Foundation
import CryptoKit

/// Content-addressed identity for stickers that arrive without one.
///
/// A Discord emoji carries a snowflake id. A photo or an arbitrary URL does
/// not, and `StickerStore` needs an id that is both unique and stable across
/// re-adds. Hashing the **normalized** bytes gives both, plus two properties
/// worth having on purpose:
///
/// - Re-importing the same image is a no-op, exactly like re-pasting the
///   same Discord emoji. The dedupe users already rely on extends for free.
/// - The same image fetched from two different URLs collapses to one
///   sticker, which is almost always what someone wants.
public enum ContentHash {

    public static func id(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256-\(hex)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS, **95 tests total** (90 + 5 new).

- [ ] **Step 5: Commit**

```bash
git add DiscordStickers/StickerKit/ContentHash.swift \
        DiscordStickers/StickerKitTests/ContentHashTests.swift
git commit -m "feat: add content-addressed identity for non-Discord stickers"
```

---

### Task 3: `LinkParser`

A pure function, so it gets the same exhaustive treatment `EmojiMarkupParser` did.

**Files:**
- Create: `DiscordStickers/StickerKit/LinkParser.swift`
- Test: `DiscordStickers/StickerKitTests/LinkParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct ParsedLink: Equatable { public let url: URL; public let suggestedName: String; public let isAnimated: Bool }`
  - `public enum LinkParser { public static func parse(_ text: String) -> ParsedLink? }`

Name derivation, in order: a Discord CDN emoji URL yields the emoji id; any other URL yields its filename without extension, percent-decoded; a URL with no usable filename yields `"sticker"`. `isAnimated` is true only for a `.gif` path extension.

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/LinkParserTests.swift`:

```swift
import XCTest
@testable import StickerKit

final class LinkParserTests: XCTestCase {

    func testParsesADiscordEmojiURLAndNamesItByID() {
        let link = LinkParser.parse(
            "https://cdn.discordapp.com/emojis/1481800758532903104.png"
        )
        XCTAssertEqual(link?.suggestedName, "1481800758532903104")
        XCTAssertFalse(link?.isAnimated ?? true)
    }

    func testMarksADiscordGIFEmojiAsAnimated() {
        let link = LinkParser.parse(
            "https://cdn.discordapp.com/emojis/1229610158183678072.gif"
        )
        XCTAssertEqual(link?.suggestedName, "1229610158183678072")
        XCTAssertTrue(link?.isAnimated ?? false)
    }

    func testNamesAnArbitraryURLByItsFilename() {
        let link = LinkParser.parse("https://example.com/img/party-parrot.png")
        XCTAssertEqual(link?.suggestedName, "party-parrot")
    }

    func testIgnoresQueryAndFragmentWhenNaming() {
        let link = LinkParser.parse(
            "https://example.com/a/cat.png?width=200&v=3#top"
        )
        XCTAssertEqual(link?.suggestedName, "cat")
    }

    func testPercentDecodesTheFilename() {
        let link = LinkParser.parse("https://example.com/happy%20cat.png")
        XCTAssertEqual(link?.suggestedName, "happy cat")
    }

    func testFallsBackToStickerWhenThereIsNoFilename() {
        XCTAssertEqual(LinkParser.parse("https://example.com/")?.suggestedName,
                       "sticker")
        XCTAssertEqual(LinkParser.parse("https://example.com")?.suggestedName,
                       "sticker")
    }

    func testTrimsSurroundingWhitespace() {
        let link = LinkParser.parse("  https://example.com/cat.png\n")
        XCTAssertEqual(link?.url.absoluteString,
                       "https://example.com/cat.png")
    }

    func testAcceptsAnyImageURLNotJustKnownHosts() {
        // Restricting to an allowlist would be a rule users must learn and
        // will get wrong. With a naming step in place there is no reason to.
        XCTAssertNotNil(LinkParser.parse("https://some-random-site.example/x.webp"))
    }

    func testRejectsNonHTTPSchemes() {
        XCTAssertNil(LinkParser.parse("ftp://example.com/cat.png"))
        XCTAssertNil(LinkParser.parse("file:///etc/passwd"))
        XCTAssertNil(LinkParser.parse("javascript:alert(1)"))
    }

    func testRejectsTextThatIsNotAURL() {
        XCTAssertNil(LinkParser.parse("just some words"))
        XCTAssertNil(LinkParser.parse(""))
        XCTAssertNil(LinkParser.parse("   "))
    }

    func testAcceptsPlainHTTP() {
        XCTAssertNotNil(LinkParser.parse("http://example.com/cat.png"))
    }

    func testDoesNotRequireAnImageExtension() {
        // Plenty of image URLs end in an id or a route rather than .png.
        // The bytes decide whether it is an image, not the path.
        XCTAssertNotNil(LinkParser.parse("https://example.com/i/abc123"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `cannot find 'LinkParser' in scope`.

- [ ] **Step 3: Write it**

Create `DiscordStickers/StickerKit/LinkParser.swift`:

```swift
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
        return cleaned.isEmpty ? fallbackName : cleaned
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS, **107 tests total** (95 + 12 new).

- [ ] **Step 5: Commit**

```bash
git add DiscordStickers/StickerKit/LinkParser.swift \
        DiscordStickers/StickerKitTests/LinkParserTests.swift
git commit -m "feat: parse any http(s) image link with a suggested name"
```

---

### Task 4: `StickerDraft` and the bounded fetcher

Arbitrary URLs mean arbitrary responses, so the fetch is bounded before anything else.

**Files:**
- Create: `DiscordStickers/StickerKit/StickerDraft.swift`
- Create: `DiscordStickers/StickerKit/DraftFetcher.swift`
- Test: `DiscordStickers/StickerKitTests/DraftFetcherTests.swift`

**Interfaces:**
- Consumes: `ParsedLink` (Task 3), `StickerLimits` (existing).
- Produces:
  - `public struct StickerDraft: Equatable { public let sourceURL: URL?; public var name: String; public let imageData: Data; public let origin: StickerSource; public let isAnimated: Bool }`
  - `public enum DraftFetchError: Equatable { case unreachable, tooLarge, notAnImage }`
  - `public final class DraftFetcher: Sendable` with `public init(session: URLSession = .shared)` and `public func fetch(_ link: ParsedLink) async -> Result<StickerDraft, DraftFetchError>`
  - `public static let maxDownloadBytes = 10_000_000` on `DraftFetcher`

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/DraftFetcherTests.swift`:

```swift
import XCTest
import UIKit
@testable import StickerKit

final class DraftFetcherTests: XCTestCase {

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    private func makeFetcher() -> DraftFetcher {
        DraftFetcher(session: StubURLProtocol.makeSession())
    }

    private func link(_ string: String) -> ParsedLink {
        LinkParser.parse(string)!
    }

    private func pngData(width: Int = 128) -> Data {
        let size = CGSize(width: width, height: width)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testFetchesAnImageIntoADraft() async {
        StubURLProtocol.handler = { _ in (200, self.pngData()) }

        let result = await makeFetcher().fetch(link("https://e.com/cat.png"))

        guard case .success(let draft) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(draft.name, "cat")
        XCTAssertEqual(draft.origin, .link)
        XCTAssertFalse(draft.imageData.isEmpty)
    }

    func testReportsUnreachableOnA404() async {
        StubURLProtocol.handler = { _ in (404, Data()) }

        let result = await makeFetcher().fetch(link("https://e.com/cat.png"))

        XCTAssertEqual(result.failure, .unreachable)
    }

    func testReportsUnreachableOnAServerError() async {
        StubURLProtocol.handler = { _ in (500, Data()) }

        XCTAssertEqual(
            await makeFetcher().fetch(link("https://e.com/cat.png")).failure,
            .unreachable
        )
    }

    func testRejectsABodyOverTheSizeCap() async {
        // Bounding this protects the extension's 40-120 MB ceiling from a
        // careless or hostile URL.
        let huge = Data(repeating: 0x41,
                        count: DraftFetcher.maxDownloadBytes + 1)
        StubURLProtocol.handler = { _ in (200, huge) }

        XCTAssertEqual(
            await makeFetcher().fetch(link("https://e.com/big.png")).failure,
            .tooLarge
        )
    }

    func testAcceptsABodyExactlyAtTheCap() async {
        // Off-by-one guard: the cap is inclusive.
        var data = pngData()
        data.append(Data(repeating: 0,
                         count: DraftFetcher.maxDownloadBytes - data.count))
        StubURLProtocol.handler = { _ in (200, data) }

        let result = await makeFetcher().fetch(link("https://e.com/edge.png"))
        XCTAssertNil(result.failure)
    }

    func testRejectsANonImageBody() async {
        // The bytes decide, not the Content-Type header.
        StubURLProtocol.handler = { _ in (200, Data("<html>nope</html>".utf8)) }

        XCTAssertEqual(
            await makeFetcher().fetch(link("https://e.com/page.png")).failure,
            .notAnImage
        )
    }

    func testCarriesTheAnimatedFlagFromTheLink() async {
        StubURLProtocol.handler = { _ in (200, self.pngData()) }

        let result = await makeFetcher().fetch(link("https://e.com/loop.gif"))

        guard case .success(let draft) = result else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(draft.isAnimated)
    }
}

private extension Result where Failure == DraftFetchError {
    var failure: DraftFetchError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `cannot find 'DraftFetcher' in scope`.

- [ ] **Step 3: Write `StickerDraft`**

Create `DiscordStickers/StickerKit/StickerDraft.swift`:

```swift
import Foundation

/// A sticker that has been fetched but not yet accepted.
///
/// Drafts exist so the user can name an import before it is stored. Search
/// matches on name, and this app's own drawer is the only surface these
/// stickers will ever have, so an unnamed sticker is one you can find only
/// by scrolling.
public struct StickerDraft: Equatable {
    public let sourceURL: URL?
    public var name: String
    public let imageData: Data
    public let origin: StickerSource
    public let isAnimated: Bool

    public init(sourceURL: URL?, name: String, imageData: Data,
                origin: StickerSource, isAnimated: Bool) {
        self.sourceURL = sourceURL
        self.name = name
        self.imageData = imageData
        self.origin = origin
        self.isAnimated = isAnimated
    }
}
```

- [ ] **Step 4: Write `DraftFetcher`**

Create `DiscordStickers/StickerKit/DraftFetcher.swift`:

```swift
import UIKit

public enum DraftFetchError: Equatable {
    case unreachable
    case tooLarge
    case notAnImage
}

/// Fetches one image URL into a draft, with hard bounds.
///
/// Arbitrary URLs mean arbitrary responses, so both the size and the
/// deadline are capped before anything reaches the image decoder. The
/// extension is killed between 40 and 120 MB, which a single careless URL
/// could reach on its own.
public final class DraftFetcher: Sendable {

    /// Ten megabytes, inclusive. Far above any real sticker and far below
    /// anything that threatens the extension.
    public static let maxDownloadBytes = 10_000_000

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ link: ParsedLink) async -> Result<StickerDraft, DraftFetchError> {
        var request = URLRequest(url: link.url)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failure(.unreachable)
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return .failure(.unreachable) }

        guard data.count <= Self.maxDownloadBytes else {
            return .failure(.tooLarge)
        }

        // The bytes decide, not the Content-Type header — plenty of servers
        // label images wrongly, and a wrong label should not lose a sticker.
        guard UIImage(data: data) != nil else {
            return .failure(.notAnImage)
        }

        return .success(StickerDraft(
            sourceURL: link.url,
            name: link.suggestedName,
            imageData: data,
            origin: .link,
            isAnimated: link.isAnimated
        ))
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: PASS, **114 tests total** (107 + 7 new).

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/StickerDraft.swift \
        DiscordStickers/StickerKit/DraftFetcher.swift \
        DiscordStickers/StickerKitTests/DraftFetcherTests.swift
git commit -m "feat: add StickerDraft and a size-bounded link fetcher"
```

---

### Task 5: `StickerImporter`

Turns accepted drafts into stored stickers, reusing the normalization and commit paths already in place.

**Files:**
- Create: `DiscordStickers/StickerKit/StickerImporter.swift`
- Test: `DiscordStickers/StickerKitTests/StickerImporterTests.swift`

**Interfaces:**
- Consumes: `StickerDraft` (Task 4), `ContentHash` (Task 2), `StickerCommitter` (Task 1), `StickerImageProcessor` and `AnimatedStickerProcessor` (existing), `DownloadOutcome` (existing).
- Produces: `public enum StickerImporter { public static func importDrafts(_ drafts: [StickerDraft], into store: StickerStore) -> DownloadOutcome }`

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/StickerImporterTests.swift`:

```swift
import XCTest
import UIKit
@testable import StickerKit

final class StickerImporterTests: XCTestCase {

    private var temp: TempDirectory!
    private var store: StickerStore!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        store = try StickerStore(root: temp.url, writeDebounce: 0)
    }

    override func tearDown() {
        store = nil
        temp = nil
    }

    private func pngData(width: Int = 128) -> Data {
        let size = CGSize(width: width, height: width)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private func draft(_ name: String, data: Data, isAnimated: Bool = false) -> StickerDraft {
        StickerDraft(sourceURL: URL(string: "https://e.com/\(name).png"),
                     name: name, imageData: data,
                     origin: .link, isAnimated: isAnimated)
    }

    func testImportsADraftAndKeepsItsName() {
        let outcome = StickerImporter.importDrafts(
            [draft("party parrot", data: pngData())], into: store
        )

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(store.all().first?.name, "party parrot")
        XCTAssertEqual(store.all().first?.source, .link)
    }

    func testIDIsContentAddressedAndStable() {
        let data = pngData()
        _ = StickerImporter.importDrafts([draft("a", data: data)], into: store)
        let firstID = store.all().first?.id

        XCTAssertTrue(firstID?.hasPrefix("sha256-") ?? false)
    }

    func testTheSameImageTwiceIsReportedAlreadyPresent() {
        // Re-importing the same picture is a no-op, exactly like re-pasting
        // the same Discord emoji.
        let data = pngData()
        _ = StickerImporter.importDrafts([draft("first", data: data)], into: store)

        let second = StickerImporter.importDrafts(
            [draft("second", data: data)], into: store
        )

        XCTAssertEqual(second.added.count, 0)
        XCTAssertEqual(second.alreadyPresent.count, 1)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.name, "first",
                       "the first import's name must win")
    }

    func testTheSameImageFromTwoURLsCollapsesToOneSticker() {
        let data = pngData()
        let outcome = StickerImporter.importDrafts([
            StickerDraft(sourceURL: URL(string: "https://a.com/x.png"),
                         name: "x", imageData: data, origin: .link,
                         isAnimated: false),
            StickerDraft(sourceURL: URL(string: "https://b.com/y.png"),
                         name: "y", imageData: data, origin: .link,
                         isAnimated: false),
        ], into: store)

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(outcome.alreadyPresent.count, 1)
        XCTAssertEqual(store.all().count, 1)
    }

    func testUndecodableBytesAreReportedUnusable() {
        let outcome = StickerImporter.importDrafts(
            [draft("broken", data: Data("nope".utf8))], into: store
        )

        XCTAssertEqual(outcome.unusable.count, 1)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testAPartialBatchStoresTheGoodOnes() {
        let outcome = StickerImporter.importDrafts([
            draft("good", data: pngData()),
            draft("bad", data: Data("nope".utf8)),
        ], into: store)

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(outcome.unusable.count, 1)
        XCTAssertEqual(store.all().count, 1)
    }

    func testAnimatedDraftsAreStoredAsAnimated() throws {
        let animated = temp.makeAnimatedGIFData(frameCount: 6)
        let outcome = StickerImporter.importDrafts(
            [draft("loop", data: animated, isAnimated: true)], into: store
        )

        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(store.all().first?.isAnimated, true)
    }

    func testAnEmptyBatchIsAnEmptyOutcome() {
        XCTAssertTrue(StickerImporter.importDrafts([], into: store).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `cannot find 'StickerImporter' in scope`.

- [ ] **Step 3: Write it**

Create `DiscordStickers/StickerKit/StickerImporter.swift`:

```swift
import Foundation

/// Turns accepted drafts into stored stickers.
///
/// The local counterpart to `EmojiDownloader`: no network, but the same
/// normalize → validate → commit path, and the same contract that failures
/// are data rather than exceptions so a partial batch is never lost.
public enum StickerImporter {

    public static func importDrafts(
        _ drafts: [StickerDraft],
        into store: StickerStore
    ) -> DownloadOutcome {
        var added: [String] = []
        var alreadyPresent: [String] = []
        var unusable: [String] = []

        for draft in drafts {
            guard let normalized = normalize(draft) else {
                unusable.append(draft.name)
                continue
            }

            // Hash the normalized bytes, not the source: two files that
            // render identically onto the canvas are one sticker.
            let id = ContentHash.id(for: normalized)

            if store.contains(id: id) {
                alreadyPresent.append(id)
                continue
            }

            let stored = StickerCommitter.commit(
                id: id, name: draft.name, source: draft.origin,
                isAnimated: draft.isAnimated, data: normalized, to: store
            )
            stored ? added.append(id) : unusable.append(draft.name)
        }

        store.flush()

        return DownloadOutcome(added: added, alreadyPresent: alreadyPresent,
                               missing: [], unusable: unusable)
    }

    /// Animated drafts whose bytes turn out to hold fewer than two frames
    /// fall back to the static path — a single-frame GIF is not animation
    /// and must not become an unexplained failure.
    private static func normalize(_ draft: StickerDraft) -> Data? {
        if draft.isAnimated,
           AnimatedStickerProcessor.frameCount(of: draft.imageData) >= 2,
           let animated = AnimatedStickerProcessor.normalize(draft.imageData) {
            return animated
        }
        return StickerImageProcessor.normalize(draft.imageData)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS, **122 tests total** (114 + 8 new).

- [ ] **Step 5: Commit**

```bash
git add DiscordStickers/StickerKit/StickerImporter.swift \
        DiscordStickers/StickerKitTests/StickerImporterTests.swift
git commit -m "feat: import drafts with content-addressed dedupe"
```

---

### Task 6: `StickerReviewViewController`

The naming screen. Shared by link import now and photo import later.

**Files:**
- Create: `DiscordStickers/StickerKit/StickerReviewViewController.swift`

**Interfaces:**
- Consumes: `StickerDraft` (Task 4), `StickerImporter` (Task 5), `DownloadOutcome` (existing).
- Produces:
  - `public final class StickerReviewViewController: UITableViewController`
  - `public init(drafts: [StickerDraft], store: StickerStore)`
  - `public var onFinished: ((DownloadOutcome?) -> Void)?` — `nil` when the user cancelled.

No unit tests: it is view code whose logic lives in `StickerImporter`, already covered. Verification is a build plus the suite staying green.

- [ ] **Step 1: Write it**

Create `DiscordStickers/StickerKit/StickerReviewViewController.swift`:

```swift
import UIKit

/// Lets the user name imports before anything is stored.
///
/// Parent-agnostic, like `PasteViewController`, so the extension can present
/// it today and a paid-tier host app could present it unchanged later.
public final class StickerReviewViewController: UITableViewController {

    private var drafts: [StickerDraft]
    private let store: StickerStore

    public var onFinished: ((DownloadOutcome?) -> Void)?

    public init(drafts: [StickerDraft], store: StickerStore) {
        self.drafts = drafts
        self.store = store
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = drafts.count == 1 ? "Name this sticker" : "Name these stickers"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Add", style: .done, target: self, action: #selector(add)
        )

        tableView.register(DraftCell.self,
                           forCellReuseIdentifier: DraftCell.reuseIdentifier)
        tableView.keyboardDismissMode = .interactive
        updateAddButton()
    }

    public override func tableView(_ tableView: UITableView,
                                   numberOfRowsInSection section: Int) -> Int {
        drafts.count
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: DraftCell.reuseIdentifier, for: indexPath
        ) as! DraftCell

        cell.configure(with: drafts[indexPath.row]) { [weak self] newName in
            guard let self, indexPath.row < self.drafts.count else { return }
            self.drafts[indexPath.row].name = newName
            self.updateAddButton()
        }
        return cell
    }

    /// Add stays disabled while any name is blank, rather than silently
    /// substituting a default the user did not choose.
    private func updateAddButton() {
        navigationItem.rightBarButtonItem?.isEnabled = drafts.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    @objc private func cancel() {
        onFinished?(nil)
    }

    @objc private func add() {
        let trimmed = drafts.map { draft -> StickerDraft in
            var copy = draft
            copy.name = draft.name.trimmingCharacters(in: .whitespaces)
            return copy
        }
        onFinished?(StickerImporter.importDrafts(trimmed, into: store))
    }
}

/// One row: a thumbnail and an editable name.
private final class DraftCell: UITableViewCell, UITextFieldDelegate {

    static let reuseIdentifier = "DraftCell"

    private let thumbnail = UIImageView()
    private let nameField = UITextField()
    private var onNameChanged: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        thumbnail.contentMode = .scaleAspectFit
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        nameField.placeholder = "Name"
        nameField.autocapitalizationType = .none
        nameField.autocorrectionType = .no
        nameField.clearButtonMode = .whileEditing
        nameField.delegate = self
        nameField.addTarget(self, action: #selector(nameChanged),
                            for: .editingChanged)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(thumbnail)
        contentView.addSubview(nameField)

        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 44),
            thumbnail.heightAnchor.constraint(equalToConstant: 44),
            thumbnail.topAnchor.constraint(
                greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
            thumbnail.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

            nameField.leadingAnchor.constraint(
                equalTo: thumbnail.trailingAnchor, constant: 12),
            nameField.trailingAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            nameField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with draft: StickerDraft,
                   onNameChanged: @escaping (String) -> Void) {
        // A thumbnail of one pending import, not a collection — the memory
        // discipline that governs the sticker grid does not apply to a
        // short review list.
        thumbnail.image = UIImage(data: draft.imageData)
        nameField.text = draft.name
        self.onNameChanged = onNameChanged
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.image = nil
        nameField.text = nil
        onNameChanged = nil
    }

    @objc private func nameChanged() {
        onNameChanged?(nameField.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
```

- [ ] **Step 2: Verify it builds and nothing regressed**

Run the extension build command. Expected: `** BUILD SUCCEEDED **`.
Run the test command. Expected: **122 tests, 0 failures**.

- [ ] **Step 3: Commit**

```bash
git add DiscordStickers/StickerKit/StickerReviewViewController.swift
git commit -m "feat: add the draft review screen for naming imports"
```

---

### Task 7: Wire link import into the extension

**Files:**
- Modify: `DiscordStickers/StickerKit/PasteViewController.swift`

**Interfaces:**
- Consumes: `LinkParser` (Task 3), `DraftFetcher` (Task 4), `StickerReviewViewController` (Task 6).
- Produces: a **Paste Link** button beside the existing Paste Emoji button.

- [ ] **Step 1: Add the button and its handler**

In `DiscordStickers/StickerKit/PasteViewController.swift`, add a stored property beside the existing button properties:

```swift
    private let linkButton = UIButton(type: .system)
```

In `viewDidLoad`, configure it alongside the existing Back Up / Restore buttons and add it to the same horizontal `buttons` stack, so the layout gains a control rather than a row:

```swift
        linkButton.setTitle("Paste Link", for: .normal)
        linkButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        linkButton.addTarget(self, action: #selector(linkTapped),
                             for: .touchUpInside)
```

and include `linkButton` in the `buttons` stack's arranged subviews, first.

Then add this method beside the existing `exportTapped` / `importTapped`:

```swift
    /// Reads the clipboard directly, which triggers the system "Allow Paste?"
    /// alert. Acceptable here for the same reason Restore accepts it: this is
    /// an occasional action, not the app's core loop.
    @objc private func linkTapped() {
        guard let text = UIPasteboard.general.string,
              let link = LinkParser.parse(text) else {
            statusLabel.text = "That doesn't look like a link."
            return
        }

        spinner.startAnimating()
        statusLabel.text = "Fetching…"

        Task { [weak self] in
            guard let self else { return }
            let result = await DraftFetcher().fetch(link)

            await MainActor.run {
                self.spinner.stopAnimating()
                switch result {
                case .failure(let error):
                    self.statusLabel.text = self.message(for: error)
                case .success(let draft):
                    self.presentReview(for: [draft])
                }
            }
        }
    }

    private func message(for error: DraftFetchError) -> String {
        switch error {
        case .unreachable: return "Couldn't fetch that link."
        case .tooLarge:    return "That image is too large."
        case .notAnImage:  return "That link isn't an image."
        }
    }

    @MainActor
    private func presentReview(for drafts: [StickerDraft]) {
        let review = StickerReviewViewController(drafts: drafts, store: store)
        let navigation = UINavigationController(rootViewController: review)

        review.onFinished = { [weak self] outcome in
            guard let self else { return }
            navigation.dismiss(animated: true)
            guard let outcome else { return }   // cancelled
            self.statusLabel.text = Self.summary(for: outcome)
            self.onFinished?(outcome)
        }

        present(navigation, animated: true)
    }
```

- [ ] **Step 2: Verify it builds and nothing regressed**

Run the extension build command. Expected: `** BUILD SUCCEEDED **`.
Run the test command. Expected: **122 tests, 0 failures**.

- [ ] **Step 3: Commit**

```bash
git add DiscordStickers/StickerKit/PasteViewController.swift
git commit -m "feat: add Paste Link to the extension's expanded mode"
```

---

### Task 8: Device verification

**Files:**
- Create: `docs/superpowers/plans/task-8-link-import-device-checklist.md`

- [ ] **Step 1: Install and import a Discord CDN link**

Run the `DiscordStickersMessages` scheme on the device with Messages as host. In Discord, long-press any custom emoji → **Copy Link**. In the drawer's expanded mode, tap **Paste Link** → Allow.

Expect the review screen, with the emoji's numeric id pre-filled as the name. Rename it to something memorable and tap **Add**.

**If no review screen appears at all**, the problem is modal presentation, not link parsing. A Messages extension is itself presented inside Messages, and presenting a `UINavigationController` on top of it is the first time this app has done so. Check the console for a presentation warning before assuming the fetch failed — the status label will have said "Fetching…" and stopped, which looks identical to a network hang. If modals are unavailable, push the review screen into the drawer's own hierarchy instead of presenting it.

- [ ] **Step 2: Confirm it became a real sticker**

The new sticker appears in the grid, sends by tapping, and is findable by the name you typed via search. If search cannot find it, the name did not reach the store.

- [ ] **Step 3: Import an arbitrary image URL**

Copy any image link from a web browser. Paste it. The name should pre-fill from the filename. Add it and confirm it works as a sticker.

- [ ] **Step 4: The dedupe check**

Paste the **same** link again. Expect the summary to say it was already saved, and the grid count not to change.

Then find the **same image at a different URL** if you can, and confirm it also reports already-saved — that is content-addressing working rather than URL matching.

- [ ] **Step 5: The failure paths**

- Paste plain text that is not a link → *"That doesn't look like a link."*
- Paste a link to a web page rather than an image → *"That link isn't an image."*
- Paste a link to a deleted image (404) → *"Couldn't fetch that link."*

Each must leave the app usable, with nothing added.

- [ ] **Step 6: Cancel does nothing**

Paste a valid link, then tap **Cancel** on the review screen. Nothing is added and the grid is unchanged.

- [ ] **Step 7: The keyboard check**

With the review screen open in the expanded drawer, tap the name field. The keyboard must not cover the field being edited. This is the one layout risk unique to editing text inside a Messages extension.

- [ ] **Step 8: Record results and commit**

Write `docs/superpowers/plans/task-8-link-import-device-checklist.md` with one line per step.

```bash
git add docs/superpowers/plans/task-8-link-import-device-checklist.md
git commit -m "docs: record link import device verification"
```

---

## Deferred

- **The photo-library picker.** Its own short plan, reusing `StickerReviewViewController`, `StickerImporter`, and `ContentHash` unchanged. Split out because `PHPickerViewController`'s viability inside a Messages extension is unverified.
- **7TV emote-set URLs**, which expand one link into many drafts. Belongs with the desktop-companion work, which builds the 7TV client.
- **Source tabs** for `Photos` and `Links`. The `source` field is recorded from day one, so adding them needs no migration.
- **Renaming after import.** Edit mode already exists from the Favorites work and is the natural home.
