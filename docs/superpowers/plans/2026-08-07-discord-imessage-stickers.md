# Discord → iMessage Stickers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an iMessage sticker extension that turns Discord custom emoji, pasted as raw markup, into sendable iMessage stickers.

**Architecture:** All logic and reusable UI live in a `StickerKit` framework linked by both an iOS app shell and an iMessage extension. In v1 the extension hosts everything, because App Groups is unavailable on a free Personal Team. `StickerStore` owns all disk I/O behind an injected root URL, and `PasteViewController` is parent-agnostic, so a later paid-tier migration is a re-hosting rather than a rewrite.

**Tech Stack:** Swift 5.9+, UIKit, Messages.framework (`MSSticker`, `MSStickerView`, `MSMessagesAppViewController`), ImageIO, XCTest. No third-party dependencies.

**Source spec:** `docs/superpowers/specs/2026-08-07-discord-imessage-stickers-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Toolchain: Xcode 26.6, Swift 6.3.3, iOS 26.5 SDK.** Verified on this machine.
- **Swift Language Version must be set to 5 on all three targets.** Xcode 26 defaults new projects to Swift 6 language mode, whose strict concurrency checking would reject this code without several `Sendable` annotations. The app's concurrency is trivial — one download batch at a time, all UI on the main actor — so Swift 6 mode buys close to nothing here while generating diagnostics that obscure real errors. Task 1 Step 4 sets this. It is a build setting, reversible at any time.
- **Deployment target: iOS 17.0** on all three targets. `UIPasteControl` requires iOS 16+; 17.0 gives headroom and is well within what Xcode 26 supports.
- **No App Groups entitlement may appear in any target.** It fails to provision on a free Personal Team and the build will not compile. Do not add it, even speculatively.
- **No third-party dependencies.** No SPM packages, no CocoaPods.
- **`MSSticker` limits:** file ≤ 500,000 bytes; both dimensions between 100 and 618 inclusive.
- **CDN URL format:** `https://cdn.discordapp.com/emojis/<id>.png` — **no `size` parameter.** Task 0 measured that `size` only downscales; requesting 256/512/1024 returns the native image unchanged. See `task-0-findings.md`.
- **Every downloaded image is normalized to a 256×256 transparent canvas** before validation. Discord emoji are frequently non-square and sometimes below `MSSticker`'s 100px floor (a measured case is 76×61), so raw bytes must never reach `MSSticker` directly.
- **Download concurrency cap: 5.**
- **Recents cap: 16**, sorted by `useCount` descending, `addedAt` descending as tiebreak.
- **Manifest invariant:** no entry may enter `manifest.json` without an `MSSticker` having been successfully constructed from its file first.
- **Memory:** never hold decoded `UIImage`s in a collection or array. Read image dimensions with ImageIO (`CGImageSourceCopyPropertiesAtIndex`), never by decoding into a `UIImage`.
- **The Xcode project is created from Apple's templates via the GUI.** Never hand-author or hand-edit `project.pbxproj`.
- **Never bundle third-party emoji artwork** in the repository or the app bundle.

---

### Task 0: Verify CDN behavior — ✅ DONE 2026-08-07

**Do not re-run this task.** It is recorded here because its results reshaped
Tasks 3, 4b and 5. Full data: `docs/superpowers/plans/task-0-findings.md`.

Measured against `<:67:1481800758532903104>` and `<a:cuh:1229610158183678072>`:

- [x] **`?size=` only downscales.** Requests at 256, 512 and 1024 all returned
  the native 128×128 image byte-for-byte identical to the bare URL (17,651
  bytes each). Only `size=64` produced something smaller. **The spec's
  server-side-upscale premise was false**, so the downloader now requests the
  bare URL and `StickerLimits.preferredSize`/`fallbackSize` no longer exist.

- [x] **Emoji are often non-square and can fall below `MSSticker`'s floor.**
  The animated test emoji is **76×61** at every requested size — under the
  100×100 minimum. Discord does not pad emoji to a square, so this is ordinary
  rather than exotic. Left unhandled it would have silently dropped a real
  fraction of every paste, reported only as "couldn't be used". **This is why
  Task 4b exists.**

- [x] **Animated emoji do return a static PNG first frame.** `file` reports
  `PNG image data, 76 x 61, 8-bit/color RGBA` for the animated ID. This
  assumption held.

### Task 1: Create the Xcode project and three targets

This is GUI work. Xcode's templates generate `project.pbxproj` correctly; hand-authoring it produces subtly broken projects that fail to sign.

**Files:**
- Create: `DiscordStickers/DiscordStickers.xcodeproj` (via Xcode template)
- Create: `DiscordStickers/DiscordStickers/` (app target sources, template-generated)
- Create: `DiscordStickers/DiscordStickersMessages/` (extension target sources, template-generated)
- Create: `DiscordStickers/StickerKit/` (framework target)
- Create: `DiscordStickers/StickerKitTests/` (unit test bundle)

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable workspace where `import StickerKit` resolves from both `DiscordStickersMessages` and `StickerKitTests`.

- [ ] **Step 1: Create the app project**

In Xcode: `File → New → Project… → iOS → App`.

- Product Name: `DiscordStickers`
- Language: **Swift**
- Interface: choose **Storyboard** if offered. Xcode 26 may offer only **SwiftUI** — that is fine, and Task 10 provides both variants of the host-app screen. Record which one you got; Task 10 needs to know.
- Uncheck "Use Core Data", uncheck "Include Tests"
- Save into `/Users/jonathan/Projects/discord stickers for iphone/`
- When prompted about source control, **uncheck** "Create Git repository" — the repo already exists.

- [ ] **Step 2: Set the deployment target**

Select the project in the navigator → `DiscordStickers` target → General → Minimum Deployments → iOS **17.0**.

- [ ] **Step 3: Add the iMessage extension target**

`File → New → Target… → iOS → iMessage Extension`. In Xcode 26 this sits under the **Application Extension** heading; use the template chooser's search field if it isn't visible.

Do **not** pick "Sticker Pack Extension" — that template ships a fixed folder of images with no code, which is the opposite of what this app does.

- Product Name: `DiscordStickersMessages`
- Embed in Application: `DiscordStickers`
- Click "Activate" if prompted about the new scheme.

Set its Minimum Deployments to iOS 17.0 as well.

- [ ] **Step 4: Set Swift Language Version to 5 on every target**

Select the **project** (not a target) in the navigator → Build Settings → search for `Swift Language Version` → set it to **Swift 5**. Then check each of the three targets and clear any target-level override so all inherit the project setting.

Xcode 26 defaults to Swift 6 language mode. Under it, `StickerStore` being handed to a task group and `EmojiDownloader` capturing `self` across an `await` are both hard errors until the types carry `Sendable` conformances. The app's threading is genuinely simple, so the checking earns little here and its diagnostics would bury the errors that matter. Flipping back to Swift 6 later is this same setting.

Verify: Build (⌘B) and confirm no `Sendable`-related errors appear.

- [ ] **Step 5: Add the StickerKit framework target**

`File → New → Target… → iOS → Framework`.

- Product Name: `StickerKit`
- Embed in Application: `DiscordStickers`
- Minimum Deployments: iOS 17.0

- [ ] **Step 6: Link StickerKit into the extension**

Select the `DiscordStickersMessages` target → General → **Frameworks and Libraries** → `+` → `StickerKit.framework` → set to **Do Not Embed**.

The framework is embedded once by the app (Xcode did this in Step 5) and merely linked by the extension. Embedding it twice produces a duplicate-bundle error at launch.

- [ ] **Step 7: Add the unit test target**

`File → New → Target… → iOS → Unit Testing Bundle`.

- Product Name: `StickerKitTests`
- Target to be Tested: `StickerKit`
- Testing System: **XCTest** (not Swift Testing — every test in this plan is written as `XCTestCase`).

- [ ] **Step 8: Confirm no App Groups entitlement exists anywhere**

For each of the three targets, open Signing & Capabilities. Confirm **App Groups is not listed**. If Xcode added an entitlements file, open it and confirm it contains no `com.apple.security.application-groups` key.

- [ ] **Step 9: Set signing to the Personal Team**

For each of the three targets: Signing & Capabilities → check "Automatically manage signing" → Team → your personal Apple ID.

- [ ] **Step 10: Verify the whole thing builds**

Product → Build (⌘B).

Expected: build succeeds with no errors.

- [ ] **Step 11: Find your simulator name for later tasks**

```bash
xcrun simctl list devices available | grep -i iphone
```

Record one name exactly as printed (for example `iPhone 17 Pro`). Every `xcodebuild` command below writes `NAME` — substitute this value. If nothing lists, the iOS 26.5 simulator runtime is still downloading; wait for it to finish.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "chore: scaffold app, iMessage extension, StickerKit framework, and test target"
```

---

### Task 2: EmojiMarkupParser

A pure function with no I/O — the easiest thing in the project to test exhaustively, and the one place a bug produces silently wrong output rather than a crash.

**Files:**
- Create: `DiscordStickers/StickerKit/ParsedEmoji.swift`
- Create: `DiscordStickers/StickerKit/EmojiMarkupParser.swift`
- Test: `DiscordStickers/StickerKitTests/EmojiMarkupParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct ParsedEmoji: Equatable, Hashable { public let id: String; public let name: String; public let isAnimated: Bool }`
  - `public enum EmojiMarkupParser { public static func parse(_ input: String) -> [ParsedEmoji] }`
  - Dedupe policy: **first occurrence wins, original order preserved.**

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/EmojiMarkupParserTests.swift`:

```swift
import XCTest
@testable import StickerKit

final class EmojiMarkupParserTests: XCTestCase {

    func testParsesSingleStaticEmoji() {
        let result = EmojiMarkupParser.parse("<:blobcatcozy:823847191234>")
        XCTAssertEqual(result, [
            ParsedEmoji(id: "823847191234", name: "blobcatcozy", isAnimated: false)
        ])
    }

    func testParsesAnimatedEmoji() {
        let result = EmojiMarkupParser.parse("<a:blobdance:111222333444>")
        XCTAssertEqual(result, [
            ParsedEmoji(id: "111222333444", name: "blobdance", isAnimated: true)
        ])
    }

    func testParsesAdjacentEmojiWithNoSeparator() {
        let result = EmojiMarkupParser.parse("<:one:111><:two:222><:three:333>")
        XCTAssertEqual(result.map(\.name), ["one", "two", "three"])
    }

    func testExtractsEmojiEmbeddedInChatText() {
        let result = EmojiMarkupParser.parse("hey <:wave:555> how are you <:smile:666> ok")
        XCTAssertEqual(result.map(\.name), ["wave", "smile"])
    }

    func testDedupesByIDKeepingFirstOccurrenceAndOrder() {
        let result = EmojiMarkupParser.parse("<:a:111><:b:222><:a:111>")
        XCTAssertEqual(result.map(\.name), ["a", "b"])
    }

    func testAcceptsUnderscoresAndDigitsInNames() {
        let result = EmojiMarkupParser.parse("<:blob_cat_2:999>")
        XCTAssertEqual(result.first?.name, "blob_cat_2")
    }

    func testIgnoresMalformedMarkup() {
        XCTAssertTrue(EmojiMarkupParser.parse("<::>").isEmpty)
        XCTAssertTrue(EmojiMarkupParser.parse("<:noid:>").isEmpty)
        XCTAssertTrue(EmojiMarkupParser.parse("<:123>").isEmpty)
    }

    func testReturnsEmptyForEmptyString() {
        XCTAssertTrue(EmojiMarkupParser.parse("").isEmpty)
    }

    func testDoesNotMatchUnicodeEmoji() {
        XCTAssertTrue(EmojiMarkupParser.parse("hello 🙂 there 🎉").isEmpty)
    }

    func testMixedUnicodeAndCustomEmoji() {
        let result = EmojiMarkupParser.parse("🙂 <:custom:777> 🎉")
        XCTAssertEqual(result.map(\.name), ["custom"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'EmojiMarkupParser' in scope`.

- [ ] **Step 3: Write ParsedEmoji**

Create `DiscordStickers/StickerKit/ParsedEmoji.swift`:

```swift
import Foundation

/// One Discord custom emoji recovered from pasted markup.
public struct ParsedEmoji: Equatable, Hashable {
    public let id: String
    public let name: String
    public let isAnimated: Bool

    public init(id: String, name: String, isAnimated: Bool) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
    }
}
```

- [ ] **Step 4: Write the parser**

Create `DiscordStickers/StickerKit/EmojiMarkupParser.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: PASS, 10 tests.

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/ParsedEmoji.swift DiscordStickers/StickerKit/EmojiMarkupParser.swift \
        DiscordStickers/StickerKitTests/EmojiMarkupParserTests.swift
git commit -m "feat: parse Discord emoji markup into deduped ParsedEmoji values"
```

---

### Task 3: StickerEntry and StickerLimits

Small value types both later tasks depend on. No behavior worth testing beyond Codable round-tripping the exact JSON shape the spec specifies.

**Files:**
- Create: `DiscordStickers/StickerKit/StickerEntry.swift`
- Create: `DiscordStickers/StickerKit/StickerLimits.swift`
- Test: `DiscordStickers/StickerKitTests/StickerEntryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum StickerSource: String, Codable { case pasted, server }`
  - `public struct StickerEntry: Codable, Equatable { public let id: String; public let name: String; public let source: StickerSource; public let addedAt: Date; public var useCount: Int }`
  - `public enum StickerLimits` with `maxBytes: Int`, `minDimension: Int`, `maxDimension: Int`, `canvasSize: Int`, `fallbackCanvasSize: Int`, `recentsLimit: Int`, `downloadConcurrency: Int`

- [ ] **Step 1: Write the failing test**

Create `DiscordStickers/StickerKitTests/StickerEntryTests.swift`:

```swift
import XCTest
@testable import StickerKit

final class StickerEntryTests: XCTestCase {

    func testRoundTripsThroughJSONWithISO8601Dates() throws {
        let entry = StickerEntry(
            id: "823847191234",
            name: "blobcatcozy",
            source: .pasted,
            addedAt: Date(timeIntervalSince1970: 1_754_604_840),
            useCount: 12
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(StickerEntry.self, from: data), entry)
    }

    func testEncodesTheFieldNamesTheSpecRequires() throws {
        let entry = StickerEntry(
            id: "1", name: "a", source: .pasted,
            addedAt: Date(timeIntervalSince1970: 0), useCount: 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(entry))
                as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["id", "name", "source", "addedAt", "useCount"])
        XCTAssertEqual(json["source"] as? String, "pasted")
    }

    func testLimitsMatchMSStickerRequirements() {
        XCTAssertEqual(StickerLimits.maxBytes, 500_000)
        XCTAssertEqual(StickerLimits.minDimension, 100)
        XCTAssertEqual(StickerLimits.maxDimension, 618)
    }

    func testBothCanvasSizesAreThemselvesValidStickerDimensions() {
        for size in [StickerLimits.canvasSize, StickerLimits.fallbackCanvasSize] {
            XCTAssertGreaterThanOrEqual(size, StickerLimits.minDimension)
            XCTAssertLessThanOrEqual(size, StickerLimits.maxDimension)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'StickerEntry' in scope`.

- [ ] **Step 3: Write StickerEntry**

Create `DiscordStickers/StickerKit/StickerEntry.swift`:

```swift
import Foundation

public enum StickerSource: String, Codable {
    case pasted
    case server
}

/// One row of `manifest.json`. Every entry that reaches the manifest has had
/// an `MSSticker` successfully constructed from its file at least once.
public struct StickerEntry: Codable, Equatable {
    public let id: String
    public let name: String
    public let source: StickerSource
    public let addedAt: Date
    public var useCount: Int

    public init(id: String, name: String, source: StickerSource,
                addedAt: Date, useCount: Int) {
        self.id = id
        self.name = name
        self.source = source
        self.addedAt = addedAt
        self.useCount = useCount
    }
}
```

- [ ] **Step 4: Write StickerLimits**

Create `DiscordStickers/StickerKit/StickerLimits.swift`:

```swift
import Foundation

/// Hard limits imposed by `MSSticker`, plus the tuning constants derived
/// from them. Values confirmed against the CDN in Task 0.
public enum StickerLimits {
    /// `MSSticker` rejects files above 500 KB. 500,000 is the conservative
    /// decimal reading of that limit.
    public static let maxBytes = 500_000
    public static let minDimension = 100
    public static let maxDimension = 618

    /// Side length of the square canvas every sticker is rendered onto.
    ///
    /// Task 0 measured that Discord's `?size=` only downscales, and that emoji
    /// are frequently non-square and sometimes below `minDimension` (76x61 was
    /// observed). So normalization is mandatory, not cosmetic.
    ///
    /// 256 trades sharpness for headroom against the extension's 40-120 MB
    /// ceiling: ~20 visible cells cost ~5 MB decoded here versus ~20 MB at 512.
    /// Validated by Task 11's scroll test — if the extension is still killed,
    /// drop this to 128.
    public static let canvasSize = 256
    /// Used when the `canvasSize` render still exceeds `maxBytes`.
    public static let fallbackCanvasSize = 128

    public static let recentsLimit = 16
    public static let downloadConcurrency = 5
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: PASS, 14 tests total.

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/StickerEntry.swift DiscordStickers/StickerKit/StickerLimits.swift \
        DiscordStickers/StickerKitTests/StickerEntryTests.swift
git commit -m "feat: add StickerEntry model and MSSticker limit constants"
```

---

### Task 4: StickerStore

Sole owner of disk. The injected `root` is what makes this testable against a temp directory and what makes a later App Group migration a one-argument change.

**Files:**
- Create: `DiscordStickers/StickerKit/StickerStore.swift`
- Test: `DiscordStickers/StickerKitTests/StickerStoreTests.swift`
- Test: `DiscordStickers/StickerKitTests/TempDirectory.swift`

**Interfaces:**
- Consumes: `StickerEntry`, `StickerSource`, `StickerLimits` (Task 3).
- Produces:
  - `public final class StickerStore`
  - `public init(root: URL, writeDebounce: TimeInterval = 0.3) throws`
  - `public func all() -> [StickerEntry]`
  - `public func contains(id: String) -> Bool`
  - `public func search(_ query: String) -> [StickerEntry]`
  - `public func recents(limit: Int = StickerLimits.recentsLimit) -> [StickerEntry]`
  - `public func add(_ entry: StickerEntry, movingFileFrom tempURL: URL) throws`
  - `public func delete(id: String) throws`
  - `public func recordUse(id: String)`
  - `public func fileURL(for id: String) -> URL`
  - `public func flush()`

- [ ] **Step 1: Write the temp directory helper**

Create `DiscordStickers/StickerKitTests/TempDirectory.swift`:

```swift
import Foundation
import UIKit

/// A throwaway directory that deletes itself when the test's reference drops.
final class TempDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a valid PNG of the given square size and returns its URL.
    /// Used as the "downloaded temp file" a store `add` moves into place.
    func makePNG(named name: String, size: Int = 128) throws -> URL {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size)
        )
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        let fileURL = url.appendingPathComponent(name)
        try image.pngData()!.write(to: fileURL)
        return fileURL
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `DiscordStickers/StickerKitTests/StickerStoreTests.swift`:

```swift
import XCTest
@testable import StickerKit

final class StickerStoreTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
    }

    private func makeStore() throws -> StickerStore {
        try StickerStore(root: temp.url, writeDebounce: 0)
    }

    private func entry(_ id: String, name: String, useCount: Int = 0,
                       addedAt: Date = Date()) -> StickerEntry {
        StickerEntry(id: id, name: name, source: .pasted,
                     addedAt: addedAt, useCount: useCount)
    }

    func testAddThenReadBack() throws {
        let store = try makeStore()
        let png = try temp.makePNG(named: "a.png")
        try store.add(entry("111", name: "wave"), movingFileFrom: png)

        XCTAssertEqual(store.all().map(\.id), ["111"])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.fileURL(for: "111").path)
        )
    }

    func testAddingSameIDTwiceDoesNotDuplicate() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "b.png"))

        XCTAssertEqual(store.all().count, 1)
    }

    func testDeleteRemovesEntryAndFile() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        let path = store.fileURL(for: "111").path

        try store.delete(id: "111")

        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRecordUseIncrementsAndSurvivesReload() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        store.recordUse(id: "111")
        store.recordUse(id: "111")
        store.flush()

        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.all().first?.useCount, 2)
    }

    func testSearchIsCaseInsensitiveSubstringOnName() throws {
        let store = try makeStore()
        try store.add(entry("1", name: "blobcatcozy"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        try store.add(entry("2", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "b.png"))

        XCTAssertEqual(store.search("CATCO").map(\.id), ["1"])
        XCTAssertEqual(store.search("").count, 2)
    }

    func testRecentsSortsByUseCountThenAddedAtAndRespectsLimit() throws {
        let store = try makeStore()
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)

        try store.add(entry("low", name: "low", useCount: 1, addedAt: new),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        try store.add(entry("highOld", name: "ho", useCount: 9, addedAt: old),
                      movingFileFrom: try temp.makePNG(named: "b.png"))
        try store.add(entry("highNew", name: "hn", useCount: 9, addedAt: new),
                      movingFileFrom: try temp.makePNG(named: "c.png"))

        XCTAssertEqual(store.recents().map(\.id), ["highNew", "highOld", "low"])
        XCTAssertEqual(store.recents(limit: 2).count, 2)
    }

    func testContainsReportsMembership() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))

        XCTAssertTrue(store.contains(id: "111"))
        XCTAssertFalse(store.contains(id: "222"))
    }

    func testCorruptManifestIsQuarantinedAndImagesAreSalvaged() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        store.flush()

        try Data("{ not json".utf8)
            .write(to: temp.url.appendingPathComponent("manifest.json"))

        let recovered = try makeStore()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: temp.url.appendingPathComponent("manifest.json.broken").path
        ))
        // The image survives; the name does not.
        XCTAssertEqual(recovered.all().map(\.id), ["111"])
        XCTAssertEqual(recovered.all().first?.name, "111")
    }

    func testEmptyRootStartsEmptyWithoutThrowing() throws {
        XCTAssertTrue(try makeStore().all().isEmpty)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'StickerStore' in scope`.

- [ ] **Step 4: Write StickerStore**

Create `DiscordStickers/StickerKit/StickerStore.swift`:

```swift
import Foundation

/// Sole owner of `<root>/stickers/*.png` and `<root>/manifest.json`.
/// All mutation is confined to a serial queue; nothing else in the app
/// touches these paths.
///
/// `root` is injected rather than derived internally so that tests can point
/// it at a temp directory, and so that moving to a shared App Group container
/// on a paid account is a change to one argument.
///
/// `@unchecked Sendable` is honest here rather than a shortcut: every access
/// to `entries` and `pendingWrite` goes through `queue`, which is serial. The
/// compiler cannot see that invariant, but it is the class's central design
/// fact. If you ever add a property touched outside `queue`, this conformance
/// becomes a lie — so don't.
public final class StickerStore: @unchecked Sendable {

    private let root: URL
    private let imagesDirectory: URL
    private let manifestURL: URL
    private let writeDebounce: TimeInterval
    private let queue = DispatchQueue(label: "StickerStore")

    private var entries: [StickerEntry] = []
    private var pendingWrite: DispatchWorkItem?

    public init(root: URL, writeDebounce: TimeInterval = 0.3) throws {
        self.root = root
        self.imagesDirectory = root.appendingPathComponent("stickers", isDirectory: true)
        self.manifestURL = root.appendingPathComponent("manifest.json")
        self.writeDebounce = writeDebounce

        try FileManager.default.createDirectory(
            at: imagesDirectory, withIntermediateDirectories: true
        )
        entries = Self.loadManifest(at: manifestURL, imagesDirectory: imagesDirectory)
    }

    // MARK: - Reads

    public func all() -> [StickerEntry] {
        queue.sync { entries }
    }

    public func contains(id: String) -> Bool {
        queue.sync { entries.contains { $0.id == id } }
    }

    public func search(_ query: String) -> [StickerEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all() }
        return queue.sync {
            entries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    public func recents(limit: Int = StickerLimits.recentsLimit) -> [StickerEntry] {
        queue.sync {
            entries
                .sorted {
                    $0.useCount != $1.useCount
                        ? $0.useCount > $1.useCount
                        : $0.addedAt > $1.addedAt
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    public func fileURL(for id: String) -> URL {
        imagesDirectory.appendingPathComponent("\(id).png")
    }

    // MARK: - Writes

    /// Moves an already-validated temp file into the store and records it.
    /// Adding an ID that is already present is a no-op, which is what makes
    /// re-pasting an overlapping batch free.
    public func add(_ entry: StickerEntry, movingFileFrom tempURL: URL) throws {
        try queue.sync {
            guard !entries.contains(where: { $0.id == entry.id }) else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            let destination = fileURL(for: entry.id)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            entries.append(entry)
            scheduleWriteLocked()
        }
    }

    public func delete(id: String) throws {
        try queue.sync {
            entries.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: fileURL(for: id))
            scheduleWriteLocked()
        }
    }

    public func recordUse(id: String) {
        queue.sync {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].useCount += 1
            scheduleWriteLocked()
        }
    }

    /// Writes any pending manifest change immediately. Call before the
    /// extension is likely to be suspended or killed.
    public func flush() {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            writeManifestLocked()
        }
    }

    // MARK: - Persistence

    private func scheduleWriteLocked() {
        pendingWrite?.cancel()
        guard writeDebounce > 0 else {
            writeManifestLocked()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.writeManifestLocked()
        }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + writeDebounce, execute: work)
    }

    private func writeManifestLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private static func loadManifest(at url: URL, imagesDirectory: URL) -> [StickerEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let entries = try? decoder.decode([StickerEntry].self, from: data) {
            return entries
        }

        // Corrupt manifest: quarantine rather than delete, then rebuild what
        // the images alone can tell us. Names are unrecoverable, so search is
        // degraded until the user re-pastes.
        let quarantine = url.deletingLastPathComponent()
            .appendingPathComponent("manifest.json.broken")
        try? FileManager.default.removeItem(at: quarantine)
        try? FileManager.default.moveItem(at: url, to: quarantine)

        let files = (try? FileManager.default.contentsOfDirectory(
            at: imagesDirectory, includingPropertiesForKeys: nil
        )) ?? []

        return files
            .filter { $0.pathExtension == "png" }
            .map { file in
                let id = file.deletingPathExtension().lastPathComponent
                return StickerEntry(id: id, name: id, source: .pasted,
                                    addedAt: Date(), useCount: 0)
            }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: PASS, 23 tests total.

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/StickerStore.swift DiscordStickers/StickerKitTests/StickerStoreTests.swift \
        DiscordStickers/StickerKitTests/TempDirectory.swift
git commit -m "feat: add StickerStore owning manifest and image files behind an injected root"
```

---

### Task 4b: StickerImageProcessor

Added after Task 0 measured live emoji. Discord returns non-square images, some below `MSSticker`'s 100px floor (76×61 observed), so raw bytes can never reach `MSSticker` directly. Numbered `4b` to avoid renumbering the tasks that follow.

**Files:**
- Create: `DiscordStickers/StickerKit/StickerImageProcessor.swift`
- Test: `DiscordStickers/StickerKitTests/StickerImageProcessorTests.swift`

**Interfaces:**
- Consumes: `StickerLimits` (Task 3).
- Produces:
  - `public enum StickerImageProcessor`
  - `public static func normalize(_ data: Data, canvas: Int = StickerLimits.canvasSize) -> Data?` — returns PNG data of exactly `canvas`×`canvas`, or `nil` if the input isn't a decodable image.

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/StickerImageProcessorTests.swift`:

```swift
import XCTest
import UIKit
import ImageIO
@testable import StickerKit

final class StickerImageProcessorTests: XCTestCase {

    /// Builds a PNG of arbitrary (possibly non-square) dimensions, with a
    /// filled inner rect so aspect-ratio preservation is observable.
    private func png(width: Int, height: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height)
        )
        return renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData()!
    }

    private func size(of data: Data) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    func testUpscalesAnUndersizedNonSquareEmojiToTheCanvas() throws {
        // The real measured case from Task 0: <a:cuh:...> is 76x61.
        let output = try XCTUnwrap(StickerImageProcessor.normalize(png(width: 76, height: 61)))
        let dimensions = try XCTUnwrap(size(of: output))

        XCTAssertEqual(dimensions.width, StickerLimits.canvasSize)
        XCTAssertEqual(dimensions.height, StickerLimits.canvasSize)
    }

    func testNormalizesATypical128SquareEmoji() throws {
        let output = try XCTUnwrap(StickerImageProcessor.normalize(png(width: 128, height: 128)))
        let dimensions = try XCTUnwrap(size(of: output))

        XCTAssertEqual(dimensions.width, StickerLimits.canvasSize)
        XCTAssertEqual(dimensions.height, StickerLimits.canvasSize)
    }

    func testExtremeAspectRatioIsPaddedNotStretched() throws {
        let output = try XCTUnwrap(StickerImageProcessor.normalize(png(width: 400, height: 20)))
        let dimensions = try XCTUnwrap(size(of: output))

        // A scale-only approach cannot satisfy both the 100 floor and the 618
        // ceiling for a 20:1 strip. Padding onto a square canvas always can.
        XCTAssertEqual(dimensions.width, StickerLimits.canvasSize)
        XCTAssertEqual(dimensions.height, StickerLimits.canvasSize)
    }

    func testEveryOutputSatisfiesMSStickerBoundsByConstruction() throws {
        for (width, height) in [(76, 61), (128, 128), (400, 20), (1, 1), (618, 618)] {
            let output = try XCTUnwrap(
                StickerImageProcessor.normalize(png(width: width, height: height)),
                "failed for \(width)x\(height)"
            )
            let dimensions = try XCTUnwrap(size(of: output))
            XCTAssertGreaterThanOrEqual(dimensions.width, StickerLimits.minDimension)
            XCTAssertGreaterThanOrEqual(dimensions.height, StickerLimits.minDimension)
            XCTAssertLessThanOrEqual(dimensions.width, StickerLimits.maxDimension)
            XCTAssertLessThanOrEqual(dimensions.height, StickerLimits.maxDimension)
        }
    }

    func testHonoursAnExplicitSmallerCanvas() throws {
        let output = try XCTUnwrap(
            StickerImageProcessor.normalize(png(width: 128, height: 128),
                                            canvas: StickerLimits.fallbackCanvasSize)
        )
        let dimensions = try XCTUnwrap(size(of: output))

        XCTAssertEqual(dimensions.width, StickerLimits.fallbackCanvasSize)
    }

    func testReturnsNilForUndecodableBytes() {
        XCTAssertNil(StickerImageProcessor.normalize(Data("not an image".utf8)))
        XCTAssertNil(StickerImageProcessor.normalize(Data()))
    }

    func testOutputPreservesTransparency() throws {
        let output = try XCTUnwrap(StickerImageProcessor.normalize(png(width: 400, height: 20)))
        let image = try XCTUnwrap(UIImage(data: output))
        let cgImage = try XCTUnwrap(image.cgImage)

        XCTAssertNotEqual(cgImage.alphaInfo, .none)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'StickerImageProcessor' in scope`.

- [ ] **Step 3: Write the processor**

Create `DiscordStickers/StickerKit/StickerImageProcessor.swift`:

```swift
import UIKit

/// Renders arbitrary downloaded bytes onto a fixed square transparent canvas,
/// aspect-fit and centred.
///
/// This exists because Task 0 measured live emoji and found two things: the
/// CDN's `?size=` only downscales, and Discord does not pad emoji to a square
/// — a real animated emoji came back 76x61, under `MSSticker`'s 100px floor.
/// Feeding raw bytes to `MSSticker` would therefore drop a genuine fraction of
/// every paste.
///
/// A square canvas is used rather than a scale calculation because scaling
/// alone cannot satisfy both the 100 floor and the 618 ceiling for an extreme
/// aspect ratio — a 20:1 strip has no valid scale factor. Padding always does,
/// and it gives the grid uniform cells for free.
public enum StickerImageProcessor {

    /// Returns PNG data of exactly `canvas` x `canvas`, or `nil` if `data`
    /// is not a decodable image.
    public static func normalize(
        _ data: Data,
        canvas: Int = StickerLimits.canvasSize
    ) -> Data? {
        guard let source = UIImage(data: data), source.size.width > 0,
              source.size.height > 0
        else { return nil }

        let side = CGFloat(canvas)
        let scale = min(side / source.size.width, side / source.size.height)
        let drawnSize = CGSize(width: source.size.width * scale,
                               height: source.size.height * scale)
        let origin = CGPoint(x: (side - drawnSize.width) / 2,
                             y: (side - drawnSize.height) / 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1          // canvas is in pixels, not points
        format.opaque = false     // keep the alpha channel

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        )
        let output = renderer.image { context in
            context.cgContext.interpolationQuality = .high
            source.draw(in: CGRect(origin: origin, size: drawnSize))
        }
        return output.pngData()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: PASS, 30 tests total.

- [ ] **Step 5: Commit**

```bash
git add DiscordStickers/StickerKit/StickerImageProcessor.swift \
        DiscordStickers/StickerKitTests/StickerImageProcessorTests.swift
git commit -m "feat: normalize downloaded emoji onto a square canvas before validation"
```

---

### Task 5: EmojiDownloader

Fetch, normalize, validate, commit. Failures are returned as data, never thrown, so a batch never fails as a unit.

**Files:**
- Create: `DiscordStickers/StickerKit/DownloadOutcome.swift`
- Create: `DiscordStickers/StickerKit/EmojiDownloader.swift`
- Test: `DiscordStickers/StickerKitTests/EmojiDownloaderTests.swift`
- Test: `DiscordStickers/StickerKitTests/StubURLProtocol.swift`

**Interfaces:**
- Consumes: `ParsedEmoji` (Task 2), `StickerEntry`/`StickerLimits` (Task 3), `StickerStore` (Task 4).
- Produces:
  - `public struct DownloadOutcome: Equatable { public let added: [String]; public let alreadyPresent: [String]; public let missing: [String]; public let unusable: [String] }` — all arrays hold emoji IDs.
  - `public final class EmojiDownloader { public init(store: StickerStore, session: URLSession = .shared); public func download(_ emoji: [ParsedEmoji]) async -> DownloadOutcome }`

- [ ] **Step 1: Write the network stub**

Create `DiscordStickers/StickerKitTests/StubURLProtocol.swift`:

```swift
import Foundation

/// Intercepts every request so downloader tests never touch the network.
/// Set `handler` to decide what each URL returns.
final class StubURLProtocol: URLProtocol {

    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        handler = nil
        requestedURLs = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.requestedURLs.append(url) }

        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Write the failing tests**

Create `DiscordStickers/StickerKitTests/EmojiDownloaderTests.swift`:

```swift
import XCTest
import UIKit
@testable import StickerKit

final class EmojiDownloaderTests: XCTestCase {

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

    private func makeDownloader() -> EmojiDownloader {
        EmojiDownloader(store: store, session: StubURLProtocol.makeSession())
    }

    private func pngData(width: Int, height: Int? = nil) -> Data {
        let size = CGSize(width: width, height: height ?? width)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    /// Noise compresses badly, so a large random image is the reliable way to
    /// push a *rendered* PNG past the byte gate. Padding trailing bytes would
    /// not work here: the downloader re-encodes, discarding anything appended.
    private func bulkyPNGData(side: Int) -> Data {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for index in pixels.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return UIImage(cgImage: context.makeImage()!).pngData()!
    }

    private func emoji(_ id: String, _ name: String) -> ParsedEmoji {
        ParsedEmoji(id: id, name: name, isAnimated: false)
    }

    func testDownloadsAndCommitsAValidEmoji() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertEqual(store.all().map(\.name), ["wave"])
    }

    func testRequestsTheBareURLWithNoSizeParameter() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([emoji("111", "wave")])

        // Task 0 measured that ?size= only downscales, so sending one either
        // changes nothing or actively degrades the source.
        XCTAssertNil(StubURLProtocol.requestedURLs.first?.query)
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
    }

    func testAcceptsAnUndersizedNonSquareEmoji() async throws {
        // The real measured shape of <a:cuh:...>, which raw would fail
        // MSSticker's 100px floor and be silently dropped.
        StubURLProtocol.handler = { _ in
            (200, self.pngData(width: 76, height: 61))
        }

        let outcome = await makeDownloader().download([emoji("111", "cuh")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertTrue(outcome.unusable.isEmpty)
    }

    func testSkipsEmojiAlreadyInTheStore() async throws {
        try store.add(
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(), useCount: 0),
            movingFileFrom: try temp.makePNG(named: "seed.png")
        )
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.alreadyPresent, ["111"])
        XCTAssertTrue(outcome.added.isEmpty)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty)
    }

    func testTreatsA404AsMissingRatherThanThrowing() async throws {
        StubURLProtocol.handler = { _ in (404, Data()) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.missing, ["111"])
        XCTAssertTrue(store.all().isEmpty)
    }

    func testFallsBackToASmallerCanvasWhenTheRenderIsTooLarge() async throws {
        // Noise at 618 renders past 500 KB on a 256 canvas but fits on a 128.
        StubURLProtocol.handler = { _ in (200, self.bulkyPNGData(side: 618)) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.added, ["111"])
        // Only one network request either way — the retry is a local
        // re-render, not a refetch.
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
    }

    func testRejectsNonImagePayloads() async throws {
        StubURLProtocol.handler = { _ in (200, Data("not an image".utf8)) }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.unusable, ["111"])
    }

    func testPartialBatchReportsBothSidesAndLeavesNoOrphanFiles() async throws {
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            return path.contains("dead") ? (404, Data())
                                         : (200, self.pngData(width: 128))
        }

        let outcome = await makeDownloader().download([
            emoji("ok1", "one"), emoji("dead", "gone"), emoji("ok2", "two"),
        ])

        XCTAssertEqual(Set(outcome.added), ["ok1", "ok2"])
        XCTAssertEqual(outcome.missing, ["dead"])
        XCTAssertEqual(store.all().count, 2)
    }

    func testEmptyInputProducesEmptyOutcome() async throws {
        let outcome = await makeDownloader().download([])
        XCTAssertEqual(outcome, DownloadOutcome(added: [], alreadyPresent: [],
                                                missing: [], unusable: []))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'EmojiDownloader' in scope`.

- [ ] **Step 4: Write DownloadOutcome**

Create `DiscordStickers/StickerKit/DownloadOutcome.swift`:

```swift
import Foundation

/// The result of one paste batch. Every emoji lands in exactly one bucket,
/// so a batch never fails as a unit and the UI can always report honestly.
/// All arrays hold Discord emoji IDs.
public struct DownloadOutcome: Equatable {
    public let added: [String]
    public let alreadyPresent: [String]
    /// Fetched but gone from Discord (404). Not retried — permanent.
    public let missing: [String]
    /// Fetched but failed validation even at the fallback size.
    public let unusable: [String]

    public init(added: [String], alreadyPresent: [String],
                missing: [String], unusable: [String]) {
        self.added = added
        self.alreadyPresent = alreadyPresent
        self.missing = missing
        self.unusable = unusable
    }

    public var isEmpty: Bool {
        added.isEmpty && alreadyPresent.isEmpty
            && missing.isEmpty && unusable.isEmpty
    }
}
```

- [ ] **Step 5: Write EmojiDownloader**

Create `DiscordStickers/StickerKit/EmojiDownloader.swift`:

```swift
import Foundation
import Messages

/// Fetches emoji from Discord's public CDN, validates them against
/// `MSSticker`'s limits, and hands survivors to `StickerStore`.
///
/// Nothing here throws to the caller: every failure is recorded in the
/// returned `DownloadOutcome`, because a partial batch is the expected case
/// rather than an exceptional one.
///
/// `Sendable` holds without qualification: both stored properties are
/// immutable, `URLSession` is `Sendable`, and `StickerStore` vouches for
/// itself through queue confinement.
public final class EmojiDownloader: Sendable {

    private let store: StickerStore
    private let session: URLSession

    public init(store: StickerStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    private enum ItemResult {
        case added(String)
        case alreadyPresent(String)
        case missing(String)
        case unusable(String)
    }

    /// Duplicate ids in the input are collapsed to the first occurrence.
    public func download(_ emoji: [ParsedEmoji]) async -> DownloadOutcome {
        // Dedupe up front. Two entries with the same id would both clear the
        // `store.contains` check below, both get fetched, and both be counted
        // in `added` — while `StickerStore.add` silently no-ops the second.
        // It would also trap the `Dictionary(uniqueKeysWithValues:)` further
        // down, crashing the extension from a public entry point.
        var seenIDs: Set<String> = []
        let emoji = emoji.filter { seenIDs.insert($0.id).inserted }

        // The diff. Doing it up front is what makes re-pasting an
        // overlapping batch free rather than redundant network work.
        var results: [ItemResult] = []
        var toFetch: [ParsedEmoji] = []
        for item in emoji {
            if store.contains(id: item.id) {
                results.append(.alreadyPresent(item.id))
            } else {
                toFetch.append(item)
            }
        }

        let fetched = await withTaskGroup(
            of: ItemResult.self, returning: [ItemResult].self
        ) { group in
            var index = 0
            var collected: [ItemResult] = []

            // Cap concurrency: prime the group, then add one task per
            // completion. The extension's memory ceiling makes an unbounded
            // fan-out genuinely dangerous.
            while index < min(StickerLimits.downloadConcurrency, toFetch.count) {
                let item = toFetch[index]
                group.addTask { await self.fetchOne(item) }
                index += 1
            }
            while let result = await group.next() {
                collected.append(result)
                if index < toFetch.count {
                    let item = toFetch[index]
                    group.addTask { await self.fetchOne(item) }
                    index += 1
                }
            }
            return collected
        }

        results.append(contentsOf: fetched)
        store.flush()

        // Preserve the caller's ordering so the summary reads predictably.
        let order = Dictionary(uniqueKeysWithValues: emoji.enumerated().map { ($1.id, $0) })
        func ids(_ predicate: (ItemResult) -> String?) -> [String] {
            results.compactMap(predicate).sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
        }

        return DownloadOutcome(
            added: ids { if case .added(let id) = $0 { return id } else { return nil } },
            alreadyPresent: ids { if case .alreadyPresent(let id) = $0 { return id } else { return nil } },
            missing: ids { if case .missing(let id) = $0 { return id } else { return nil } },
            unusable: ids { if case .unusable(let id) = $0 { return id } else { return nil } }
        )
    }

    private func fetchOne(_ emoji: ParsedEmoji) async -> ItemResult {
        switch await fetch(id: emoji.id) {
        case .notFound:
            return .missing(emoji.id)
        case .failed:
            return .unusable(emoji.id)
        case .success(let raw):
            // Raw bytes are never trusted: Discord emoji are often non-square
            // and sometimes below MSSticker's floor (76x61 measured in Task 0).
            guard let normalized = StickerImageProcessor.normalize(raw) else {
                return .unusable(emoji.id)
            }
            if normalized.count <= StickerLimits.maxBytes {
                return commit(emoji, data: normalized)
            }
            // Re-render smaller rather than discard. A guard, not a routine
            // path — 128px source art at a 256 canvas lands far under 500 KB.
            guard let smaller = StickerImageProcessor.normalize(
                raw, canvas: StickerLimits.fallbackCanvasSize
            ), smaller.count <= StickerLimits.maxBytes else {
                return .unusable(emoji.id)
            }
            return commit(emoji, data: smaller)
        }
    }

    private enum FetchResult {
        case success(Data)
        case notFound
        case failed
    }

    /// No `size` parameter: Task 0 measured that it only downscales, so
    /// requesting one either changes nothing or makes the source worse.
    private func fetch(id: String) async -> FetchResult {
        guard let url = URL(
            string: "https://cdn.discordapp.com/emojis/\(id).png"
        ) else { return .failed }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200: return .success(data)
            case 404: return .notFound
            default: return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Writes to a temp file, proves the bytes are a usable `MSSticker`, then
    /// hands the file to the store. Constructing the sticker here rather than
    /// in `cellForItemAt` is what turns a scroll-time crash into a
    /// download-time skip, and is what upholds the manifest invariant.
    private func commit(_ emoji: ParsedEmoji, data: Data) -> ItemResult {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(emoji.id)-\(UUID().uuidString).png")

        do {
            try data.write(to: tempURL)

            // Dimensions are guaranteed by the square canvas, so this is a
            // cheap assertion rather than a real gate. Constructing the
            // MSSticker below is the decisive check.
            _ = try MSSticker(contentsOfFileURL: tempURL,
                              localizedDescription: emoji.name)

            try store.add(
                StickerEntry(id: emoji.id, name: emoji.name, source: .pasted,
                             addedAt: Date(), useCount: 0),
                movingFileFrom: tempURL
            )
            return .added(emoji.id)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return .unusable(emoji.id)
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: PASS, 41 tests total.

- [ ] **Step 7: Commit**

```bash
git add DiscordStickers/StickerKit/DownloadOutcome.swift DiscordStickers/StickerKit/EmojiDownloader.swift \
        DiscordStickers/StickerKitTests/EmojiDownloaderTests.swift \
        DiscordStickers/StickerKitTests/StubURLProtocol.swift
git commit -m "feat: download, validate, and commit emoji with 256 fallback and per-item results"
```

---

### Task 6: StickerCell

The cell is where the memory discipline lives or dies. Isolated into its own task so it can be reviewed on that basis alone.

**Files:**
- Create: `DiscordStickers/StickerKit/StickerCell.swift`

**Interfaces:**
- Consumes: nothing beyond Messages.framework.
- Produces:
  - `public final class StickerCell: UICollectionViewCell`
  - `public static let reuseIdentifier = "StickerCell"`
  - `public func configure(with sticker: MSSticker, onTap: @escaping () -> Void)`

- [ ] **Step 1: Write the cell**

Create `DiscordStickers/StickerKit/StickerCell.swift`:

```swift
import UIKit
import Messages

/// Hosts one `MSStickerView`, which supplies tap-to-send and
/// drag-onto-bubble for free.
///
/// `prepareForReuse` clearing the sticker is load-bearing: a Messages
/// extension is killed somewhere between 40 and 120 MB, and holding decoded
/// images in recycled cells is the fastest way to get there.
public final class StickerCell: UICollectionViewCell {

    public static let reuseIdentifier = "StickerCell"

    private let stickerView = MSStickerView()
    private var onTap: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)

        stickerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stickerView)
        NSLayoutConstraint.activate([
            stickerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stickerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stickerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stickerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        // MSStickerView handles the tap internally and offers no delegate
        // callback on insertion, so this observes the tap alongside it rather
        // than instead of it. It counts taps, not confirmed sends — a
        // deliberate approximation, sufficient for ordering Recents.
        let recognizer = UITapGestureRecognizer(
            target: self, action: #selector(handleTap)
        )
        recognizer.delegate = self
        stickerView.addGestureRecognizer(recognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func configure(with sticker: MSSticker, onTap: @escaping () -> Void) {
        stickerView.sticker = sticker
        self.onTap = onTap
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        stickerView.sticker = nil
        onTap = nil
    }

    @objc private func handleTap() {
        onTap?()
    }
}

extension StickerCell: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add DiscordStickers/StickerKit/StickerCell.swift
git commit -m "feat: add StickerCell with reuse-safe sticker clearing and tap observation"
```

---

### Task 7: StickerGridViewController

**Files:**
- Create: `DiscordStickers/StickerKit/StickerGridViewController.swift`

**Interfaces:**
- Consumes: `StickerStore` (Task 4), `StickerCell` (Task 6), `StickerLimits` (Task 3).
- Produces:
  - `public enum StickerFilter: Equatable { case recents, all, search(String) }`
  - `public final class StickerGridViewController: UIViewController`
  - `public init(store: StickerStore)`
  - `public var filter: StickerFilter { get set }` — setting it reloads
  - `public func reload()`

- [ ] **Step 1: Write the grid**

Create `DiscordStickers/StickerKit/StickerGridViewController.swift`:

```swift
import UIKit
import Messages

public enum StickerFilter: Equatable {
    case recents
    case all
    case search(String)
}

/// A collection view of stickers backed entirely by `StickerStore`.
/// It never touches disk itself and never holds a decoded image: `MSSticker`
/// is file-URL-backed and constructed lazily per visible cell.
public final class StickerGridViewController: UIViewController {

    private let store: StickerStore
    private var entries: [StickerEntry] = []
    private var collectionView: UICollectionView!

    public var filter: StickerFilter = .all {
        didSet { if filter != oldValue { reload() } }
    }

    public init(store: StickerStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            StickerCell.self, forCellWithReuseIdentifier: StickerCell.reuseIdentifier
        )

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        reload()
    }

    public func reload() {
        switch filter {
        case .recents: entries = store.recents()
        case .all:     entries = store.all()
        case .search(let query): entries = store.search(query)
        }
        collectionView?.reloadData()
    }
}

extension StickerGridViewController: UICollectionViewDataSource {

    public func collectionView(_ collectionView: UICollectionView,
                               numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: StickerCell.reuseIdentifier, for: indexPath
        ) as! StickerCell

        let entry = entries[indexPath.item]

        // Every manifest entry was proven constructible at download time, so
        // this should never fail. `try?` is belt-and-braces: an empty cell is
        // survivable, a throw mid-scroll is not.
        if let sticker = try? MSSticker(
            contentsOfFileURL: store.fileURL(for: entry.id),
            localizedDescription: entry.name
        ) {
            cell.configure(with: sticker) { [weak self] in
                self?.store.recordUse(id: entry.id)
            }
        }
        return cell
    }
}

extension StickerGridViewController: UICollectionViewDelegateFlowLayout {

    public func collectionView(
        _ collectionView: UICollectionView,
        layout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        // ~6 per row in the compact drawer, wider cells as the view grows.
        let columns = max(4, Int(collectionView.bounds.width / 70))
        let spacing: CGFloat = 8 * CGFloat(columns - 1) + 24
        let side = (collectionView.bounds.width - spacing) / CGFloat(columns)
        return CGSize(width: side, height: side)
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add DiscordStickers/StickerKit/StickerGridViewController.swift
git commit -m "feat: add sticker grid with recents, all, and search filters"
```

---

### Task 8: PasteViewController

Parent-agnostic by design: the extension presents it in expanded mode today, and a paid-tier host app could present it full-screen tomorrow with no change.

**Files:**
- Create: `DiscordStickers/StickerKit/PasteViewController.swift`
- Create: `DiscordStickers/StickerKit/NetworkReachability.swift`
- Test: `DiscordStickers/StickerKitTests/PasteSummaryTests.swift`

**Interfaces:**
- Consumes: `EmojiMarkupParser` (Task 2), `StickerStore` (Task 4), `EmojiDownloader`/`DownloadOutcome` (Task 5).
- Produces:
  - `public final class PasteViewController: UIViewController`
  - `public init(store: StickerStore, downloader: EmojiDownloader)`
  - `public var onFinished: ((DownloadOutcome) -> Void)?`
  - `public static func summary(for outcome: DownloadOutcome) -> String`

- [ ] **Step 1: Write the paste screen**

Create `DiscordStickers/StickerKit/PasteViewController.swift`:

```swift
import UIKit

/// The paste control, plus the one-line summary of what a batch did.
///
/// Deliberately knows nothing about its parent. `UIPasteControl` was tried
/// first, specifically to avoid the system "Allow Paste?" alert that a direct
/// `UIPasteboard.general.string` read triggers. On a real device, inside a
/// Messages extension, it renders permanently disabled — even with valid
/// text on the clipboard — so a plain button is used instead. See
/// `pasteTapped()` for the trade-off this accepts.
public final class PasteViewController: UIViewController {

    private let store: StickerStore
    private let downloader: EmojiDownloader

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    public var onFinished: ((DownloadOutcome) -> Void)?

    public init(store: StickerStore, downloader: EmojiDownloader) {
        self.store = store
        self.downloader = downloader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        var pasteConfiguration = UIButton.Configuration.borderedProminent()
        pasteConfiguration.cornerStyle = .capsule
        pasteConfiguration.title = "Paste Emoji"
        let pasteButton = UIButton(configuration: pasteConfiguration)
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)

        statusLabel.text = "Copy Discord emoji, then paste them here."
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        spinner.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [pasteButton, spinner, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                       constant: 12),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor,
                                           constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor,
                                            constant: -16),
        ])
    }

    /// Reads the pasteboard directly, which deliberately triggers the system
    /// "Allow Paste?" alert. `UIPasteControl` was tried first to avoid that
    /// alert entirely, but real-device testing showed it renders permanently
    /// disabled inside a Messages extension — it cannot determine the
    /// pasteboard's contents in that sandbox, even when the clipboard
    /// demonstrably holds valid Discord markup. A button that never enables
    /// is a worse failure than one system prompt, and a batch paste is a
    /// rare action (roughly weekly, or after the 7-day reinstall), so one
    /// prompt per batch is an acceptable trade.
    @objc private func pasteTapped() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            statusLabel.text = "Nothing on the clipboard to paste."
            return
        }
        handle(text)
    }

    @MainActor
    private func handle(_ text: String) {
        let parsed = EmojiMarkupParser.parse(text)
        guard !parsed.isEmpty else {
            statusLabel.text = "No Discord emoji found in what you pasted."
            return
        }

        // Checked before any network work so the paste isn't consumed for
        // nothing — the user can simply paste again once they're back online.
        guard NetworkReachability.isLikelyOnline else {
            statusLabel.text = "You're offline — paste again when you're back."
            return
        }

        spinner.startAnimating()
        statusLabel.text = "Adding \(parsed.count) emoji…"

        Task {
            let outcome = await downloader.download(parsed)
            await MainActor.run {
                spinner.stopAnimating()
                statusLabel.text = Self.summary(for: outcome)
                onFinished?(outcome)
            }
        }
    }

    /// One honest sentence. Clauses are omitted when their count is zero, so
    /// the common case reads "Added 12 stickers." and nothing more.
    public static func summary(for outcome: DownloadOutcome) -> String {
        var parts: [String] = []

        if !outcome.added.isEmpty {
            parts.append("Added \(outcome.added.count) "
                         + (outcome.added.count == 1 ? "sticker" : "stickers"))
        }
        if !outcome.alreadyPresent.isEmpty {
            parts.append("\(outcome.alreadyPresent.count) already saved")
        }
        if !outcome.missing.isEmpty {
            parts.append("\(outcome.missing.count) no longer "
                         + (outcome.missing.count == 1 ? "exists" : "exist"))
        }
        if !outcome.unusable.isEmpty {
            parts.append("\(outcome.unusable.count) couldn't be used")
        }

        guard !parts.isEmpty else { return "Nothing to add." }
        return parts.joined(separator: ", ") + "."
    }
}

```

- [ ] **Step 2: Write the reachability check**

Create `DiscordStickers/StickerKit/NetworkReachability.swift`:

```swift
import Network

/// A cheap pre-flight check so an offline paste isn't consumed for nothing.
///
/// Deliberately lenient: anything other than a definite `.unsatisfied` counts
/// as online. A false "you're offline" would block a paste that would have
/// worked, whereas a false "online" costs nothing — `EmojiDownloader` already
/// records every transport failure as a per-item result, so the truth still
/// reaches the user in the summary.
enum NetworkReachability {

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "NetworkReachability"))
        return monitor
    }()

    static var isLikelyOnline: Bool {
        monitor.currentPath.status != .unsatisfied
    }
}
```

- [ ] **Step 3: Verify it builds**

```bash
xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Add summary tests**

Create `DiscordStickers/StickerKitTests/PasteSummaryTests.swift`:

```swift
import XCTest
@testable import StickerKit

final class PasteSummaryTests: XCTestCase {

    private func outcome(added: Int = 0, present: Int = 0,
                         missing: Int = 0, unusable: Int = 0) -> DownloadOutcome {
        func ids(_ n: Int, _ prefix: String) -> [String] {
            (0..<n).map { "\(prefix)\($0)" }
        }
        return DownloadOutcome(
            added: ids(added, "a"), alreadyPresent: ids(present, "p"),
            missing: ids(missing, "m"), unusable: ids(unusable, "u")
        )
    }

    func testCleanBatchMentionsOnlyAdditions() {
        XCTAssertEqual(
            PasteViewController.summary(for: outcome(added: 12)),
            "Added 12 stickers."
        )
    }

    func testSingularGrammar() {
        XCTAssertEqual(
            PasteViewController.summary(for: outcome(added: 1, missing: 1)),
            "Added 1 sticker, 1 no longer exists."
        )
    }

    func testPartialBatchReportsEveryNonZeroBucket() {
        XCTAssertEqual(
            PasteViewController.summary(
                for: outcome(added: 9, present: 35, missing: 2, unusable: 1)
            ),
            "Added 9 stickers, 35 already saved, 2 no longer exist, 1 couldn't be used."
        )
    }

    func testEmptyOutcomeStillReadsAsASentence() {
        XCTAssertEqual(PasteViewController.summary(for: outcome()), "Nothing to add.")
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: PASS, 45 tests total.

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/PasteViewController.swift DiscordStickers/StickerKit/NetworkReachability.swift \
        DiscordStickers/StickerKitTests/PasteSummaryTests.swift
git commit -m "feat: add parent-agnostic paste screen with UIPasteControl and batch summary"
```

---

### Task 9: Wire the extension together

**Files:**
- Modify: `DiscordStickers/DiscordStickersMessages/MessagesViewController.swift` (replace template contents)

**Interfaces:**
- Consumes: everything in `StickerKit`.
- Produces: a running extension.

- [ ] **Step 1: Replace the template view controller**

Replace the entire contents of `DiscordStickers/DiscordStickersMessages/MessagesViewController.swift`:

```swift
import UIKit
import Messages
import StickerKit

/// Compact mode shows Recents plus the full grid. Expanded mode adds search
/// and the paste control.
///
/// The extension owns storage outright: App Groups is unavailable on a free
/// Personal Team, so there is no shared container to read from.
final class MessagesViewController: MSMessagesAppViewController {

    private var store: StickerStore!
    private var downloader: EmojiDownloader!
    private var grid: StickerGridViewController!
    private var paste: PasteViewController!

    private let searchBar = UISearchBar()
    private let tabs = UISegmentedControl(items: ["Recent", "All"])
    private let pasteContainer = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()

        let root = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]

        do {
            store = try StickerStore(root: root)
        } catch {
            showFatal("Couldn't open sticker storage.")
            return
        }
        downloader = EmojiDownloader(store: store)

        buildUI()
        applyPresentationStyle(presentationStyle)
    }

    private func buildUI() {
        tabs.selectedSegmentIndex = 1
        tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        searchBar.placeholder = "Search emoji"
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.delegate = self
        searchBar.translatesAutoresizingMaskIntoConstraints = false

        pasteContainer.translatesAutoresizingMaskIntoConstraints = false

        grid = StickerGridViewController(store: store)
        addChild(grid)
        grid.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid.view)
        grid.didMove(toParent: self)

        paste = PasteViewController(store: store, downloader: downloader)
        paste.onFinished = { [weak self] _ in self?.grid.reload() }
        addChild(paste)
        paste.view.translatesAutoresizingMaskIntoConstraints = false
        pasteContainer.addSubview(paste.view)
        paste.didMove(toParent: self)

        view.addSubview(searchBar)
        view.addSubview(tabs)
        view.addSubview(pasteContainer)

        NSLayoutConstraint.activate([
            paste.view.topAnchor.constraint(equalTo: pasteContainer.topAnchor),
            paste.view.bottomAnchor.constraint(equalTo: pasteContainer.bottomAnchor),
            paste.view.leadingAnchor.constraint(equalTo: pasteContainer.leadingAnchor),
            paste.view.trailingAnchor.constraint(equalTo: pasteContainer.trailingAnchor),

            pasteContainer.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor),
            pasteContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pasteContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pasteContainer.heightAnchor.constraint(equalToConstant: 76),

            searchBar.topAnchor.constraint(equalTo: pasteContainer.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            grid.view.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            grid.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.view.bottomAnchor.constraint(equalTo: tabs.topAnchor, constant: -8),

            tabs.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Presentation style

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        applyPresentationStyle(presentationStyle)
    }

    private func applyPresentationStyle(_ style: MSMessagesAppPresentationStyle) {
        let expanded = (style == .expanded)
        searchBar.isHidden = !expanded
        pasteContainer.isHidden = !expanded
        if !expanded {
            searchBar.text = nil
            searchBar.resignFirstResponder()
            grid.filter = tabs.selectedSegmentIndex == 0 ? .recents : .all
        }
        view.setNeedsLayout()
    }

    // MARK: - Lifecycle

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
        // The extension can be killed without further warning; make sure no
        // manifest change is sitting in the debounce window.
        store?.flush()
    }

    // MARK: - Actions

    @objc private func tabChanged() {
        searchBar.text = nil
        grid.filter = tabs.selectedSegmentIndex == 0 ? .recents : .all
    }

    private func showFatal(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
        ])
    }
}

extension MessagesViewController: UISearchBarDelegate {

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        grid.filter = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? (tabs.selectedSegmentIndex == 0 ? .recents : .all)
            : .search(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
```

- [ ] **Step 2: Build and run on the simulator**

```bash
xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme DiscordStickersMessages \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

Then in Xcode: select the `DiscordStickersMessages` scheme, Run, and choose **Messages** as the app to run in. The extension appears in the Messages app drawer.

- [ ] **Step 3: Smoke test in the simulator**

Open the extension. Expand the drawer. Confirm the paste control and search bar appear on expand and disappear on collapse. The grid will be empty — that is expected.

- [ ] **Step 4: Commit**

```bash
git add DiscordStickers/DiscordStickersMessages/MessagesViewController.swift
git commit -m "feat: wire grid, search, tabs, and paste into the Messages extension"
```

---

### Task 10: Host app shell

**Files:**
- Modify: `DiscordStickers/DiscordStickers/ViewController.swift` **or** `DiscordStickers/DiscordStickers/ContentView.swift`, depending on which interface the Task 1 Step 1 template produced.

**Interfaces:**
- Consumes: nothing from `StickerKit`. Intentionally inert in v1.
- Produces: a screen explaining how to reach the extension.

Do Step 1a **or** Step 1b, not both. Check which file exists in the `DiscordStickers` group.

- [ ] **Step 1a: Storyboard variant — replace `DiscordStickers/DiscordStickers/ViewController.swift`**

Skip to Step 1b if your project has `ContentView.swift` instead.

```swift
import UIKit

/// Deliberately inert. An iMessage extension cannot ship on its own, so this
/// app exists to carry one. Everything real happens inside the extension,
/// because App Groups — which would let this app write storage the extension
/// could read — is unavailable on a free Personal Team.
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

        let stack = UIStackView(arrangedSubviews: [title, body])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }
}
```

- [ ] **Step 1b: SwiftUI variant — replace `DiscordStickers/DiscordStickers/ContentView.swift`**

Skip this if you already did Step 1a.

```swift
import SwiftUI

/// Deliberately inert. An iMessage extension cannot ship on its own, so this
/// app exists to carry one. Everything real happens inside the extension,
/// because App Groups — which would let this app write storage the extension
/// could read — is unavailable on a free Personal Team.
struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Discord Stickers")
                .font(.largeTitle)

            Text("""
            Everything happens inside Messages.

            1. Open any conversation in Messages.
            2. Tap the apps row beside the text field, then pick \
            Discord Stickers.
            3. Drag the drawer up to reveal search and the paste button.

            To add emoji: in Discord, tap emoji into a message box, select \
            all, and copy. Then paste them into the drawer.

            Tap a sticker to send it, or drag it onto a message to stick \
            it there.
            """)
            .font(.body)
        }
        .padding(24)
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme DiscordStickers \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add DiscordStickers/DiscordStickers/
git commit -m "feat: add host app shell explaining how to reach the extension"
```

---

### Task 11: Device verification

Everything here is a property of the iOS runtime rather than of the code, which is exactly why none of it can be unit tested. Run on a real iPhone, not the simulator — the memory ceiling in particular does not reproduce in a simulator.

**Files:**
- Create: `docs/superpowers/plans/task-11-device-checklist.md`

**Interfaces:**
- Consumes: the built app.
- Produces: a recorded pass/fail per item.

- [ ] **Step 1: Install on the device**

Connect the iPhone. In Xcode select it as the run destination, select the `DiscordStickersMessages` scheme, Run, and pick Messages as the host app.

On first run: on the iPhone, go to Settings → General → VPN & Device Management → trust the developer certificate.

- [ ] **Step 2: Paste a real batch**

In Discord, tap 30–50 emoji into a compose box, select all, copy. In the extension's expanded drawer, tap the paste button.

Record: does a "Allow Paste?" alert appear? It **should**, once per batch — the button reads `UIPasteboard.general.string` directly (see Task 8). This replaced an earlier `UIPasteControl`-based design specifically because `UIPasteControl` rendered permanently disabled inside a Messages extension on device, alert or no alert. If the alert never appears at all, or the paste silently fails, that indicates a real bug (e.g. `pasteTapped()` not wired up), not a working alert-free path.

Record the summary line shown.

- [ ] **Step 3: The memory test**

Paste enough batches to exceed **300 stickers**, then scroll the grid rapidly top to bottom several times.

Expected: no crash, no blank drawer, no relaunch. If the extension dies here, the cause is almost certainly decoded images being retained — verify `StickerCell.prepareForReuse` sets `stickerView.sticker = nil`.

Record: pass or fail, and the sticker count reached.

- [ ] **Step 4: Sending**

- Tap a sticker. Confirm it inserts into the conversation.
- Drag a sticker onto an existing message bubble. Confirm it sticks.

- [ ] **Step 5: Recents and search**

- Tap the same sticker 3 times, switch to the Recent tab, confirm it appears near the front.
- Type part of an emoji name in search, confirm the grid filters live.
- Clear the search, confirm the full grid returns.

- [ ] **Step 6: Drawer transitions**

Collapse and expand the drawer several times. Confirm search and paste appear only when expanded, and that the grid does not reset to the top on every transition.

- [ ] **Step 7: Cold launch**

Force-quit Messages, reopen, and open the extension. Confirm it appears without a visible stall and that stickers persisted.

- [ ] **Step 8: Record results and commit**

Write `docs/superpowers/plans/task-11-device-checklist.md` with one line per step: pass/fail plus any observation.

```bash
git add docs/superpowers/plans/task-11-device-checklist.md
git commit -m "docs: record device verification results"
```

---

### Task 12: Export and import (cuttable)

Build this last. Re-pasting already recovers everything except `useCount`, so this exists solely to preserve Recents ordering across the 7-day reinstall. Cut it without regret if it fights.

**Files:**
- Create: `DiscordStickers/StickerKit/ManifestTransfer.swift`
- Modify: `DiscordStickers/StickerKit/PasteViewController.swift`
- Test: `DiscordStickers/StickerKitTests/ManifestTransferTests.swift`

**Interfaces:**
- Consumes: `StickerEntry` (Task 3), `StickerStore` (Task 4), `EmojiDownloader` (Task 5).
- Produces:
  - `public enum ManifestTransfer`
  - `public static func export(from store: StickerStore) -> String`
  - `public static func parseImport(_ text: String) -> [StickerEntry]`
  - `public static func restore(_ entries: [StickerEntry], store: StickerStore, downloader: EmojiDownloader) async -> DownloadOutcome`

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/ManifestTransferTests.swift`:

```swift
import XCTest
@testable import StickerKit

final class ManifestTransferTests: XCTestCase {

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

    func testExportProducesTextThatImportsBack() throws {
        try store.add(
            StickerEntry(id: "111", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 1000), useCount: 7),
            movingFileFrom: try temp.makePNG(named: "a.png")
        )

        let text = ManifestTransfer.export(from: store)
        let imported = ManifestTransfer.parseImport(text)

        XCTAssertEqual(imported.map(\.id), ["111"])
        XCTAssertEqual(imported.first?.useCount, 7)
        XCTAssertEqual(imported.first?.name, "wave")
    }

    func testImportRejectsGarbageWithoutThrowing() {
        XCTAssertTrue(ManifestTransfer.parseImport("not json at all").isEmpty)
        XCTAssertTrue(ManifestTransfer.parseImport("").isEmpty)
    }

    func testExportOfAnEmptyStoreIsAnEmptyArray() {
        XCTAssertEqual(ManifestTransfer.parseImport(
            ManifestTransfer.export(from: store)
        ).count, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: FAIL — `cannot find 'ManifestTransfer' in scope`.

- [ ] **Step 3: Write ManifestTransfer**

Create `DiscordStickers/StickerKit/ManifestTransfer.swift`:

```swift
import Foundation

/// Moves the manifest in and out as clipboard text.
///
/// A re-paste already restores names and images from the CDN, so the only
/// thing this genuinely rescues is `useCount` — which is the one piece of
/// data in the app that cannot be re-derived from Discord. Text rather than a
/// file, because text survives being pasted into a note and retrieved a week
/// later, and because file-sharing UI inside a Messages extension is more
/// friction than this feature earns.
public enum ManifestTransfer {

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func export(from store: StickerStore) -> String {
        guard let data = try? encoder.encode(store.all()),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    public static func parseImport(_ text: String) -> [StickerEntry] {
        guard let data = text.data(using: .utf8),
              let entries = try? decoder.decode([StickerEntry].self, from: data)
        else { return [] }
        return entries
    }

    /// Re-downloads every listed emoji, then replays the saved use counts so
    /// Recents comes back correctly ordered rather than empty.
    public static func restore(
        _ entries: [StickerEntry],
        store: StickerStore,
        downloader: EmojiDownloader
    ) async -> DownloadOutcome {
        let outcome = await downloader.download(
            entries.map {
                ParsedEmoji(id: $0.id, name: $0.name, isAnimated: false)
            }
        )

        for entry in entries where store.contains(id: entry.id) {
            for _ in 0..<entry.useCount { store.recordUse(id: entry.id) }
        }
        store.flush()

        return outcome
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -30
```

Expected: PASS, 48 tests total.

- [ ] **Step 5: Add export and import buttons to the paste screen**

In `DiscordStickers/StickerKit/PasteViewController.swift`, add these two properties after `public var onFinished`:

```swift
    private let exportButton = UIButton(type: .system)
    private let importButton = UIButton(type: .system)
```

In `viewDidLoad`, replace the line creating the stack with:

```swift
        exportButton.setTitle("Back Up", for: .normal)
        exportButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)

        importButton.setTitle("Restore", for: .normal)
        importButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [exportButton, importButton])
        buttons.axis = .horizontal
        buttons.spacing = 16

        let stack = UIStackView(
            arrangedSubviews: [pasteControl, spinner, statusLabel, buttons]
        )
```

Then add these methods before the closing brace of the class:

```swift
    @objc private func exportTapped() {
        UIPasteboard.general.string = ManifestTransfer.export(from: store)
        statusLabel.text = "Backup copied. Paste it somewhere safe."
    }

    /// Restore reads the pasteboard directly and so will trigger the system
    /// paste alert. That is acceptable here: this runs roughly once a week at
    /// most, unlike the main paste flow.
    @objc private func importTapped() {
        guard let text = UIPasteboard.general.string else {
            statusLabel.text = "Nothing on the clipboard to restore."
            return
        }
        let entries = ManifestTransfer.parseImport(text)
        guard !entries.isEmpty else {
            statusLabel.text = "That doesn't look like a backup."
            return
        }

        spinner.startAnimating()
        statusLabel.text = "Restoring \(entries.count) stickers…"

        Task {
            let outcome = await ManifestTransfer.restore(
                entries, store: store, downloader: downloader
            )
            await MainActor.run {
                spinner.stopAnimating()
                statusLabel.text = Self.summary(for: outcome)
                onFinished?(outcome)
            }
        }
    }
```

- [ ] **Step 6: Build and verify**

```bash
xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme DiscordStickersMessages \
  -destination 'platform=iOS Simulator,name=NAME' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add DiscordStickers/StickerKit/ManifestTransfer.swift DiscordStickers/StickerKit/PasteViewController.swift \
        DiscordStickers/StickerKitTests/ManifestTransferTests.swift
git commit -m "feat: add clipboard backup and restore to preserve use counts across reinstalls"
```

---

## Deferred to phase 2

Not in this plan, listed so nothing is lost:

- **Bot token browser** for the one server with Manage Server permission — `GET /users/@me/guilds`, `GET /guilds/{id}/emojis`, token in the Keychain. This is what populates the `<Server>` source tab and `StickerSource.server`, both of which already exist in the data model.
- **Paid-tier migration** — App Groups capability on both targets, `StickerStore(root:)` pointed at the shared container, and `PasteViewController` re-hosted full-screen in the app. Task 12 becomes unnecessary at that point.
