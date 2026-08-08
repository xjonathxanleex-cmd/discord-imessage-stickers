# Animated Stickers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Discord's animated custom emoji into animated iMessage stickers instead of static first frames.

**Architecture:** A parallel pipeline. `AnimatedStickerProcessor` reads frames and per-frame delays with `CGImageSource`, drops frames evenly while redistributing their delays so total duration is preserved, renders each surviving frame onto a 128×128 transparent canvas, and re-encodes as APNG. `EmojiDownloader` picks the URL extension from a newly persisted `isAnimated` flag and routes to the animated or static processor accordingly.

**Tech Stack:** Swift 5 language mode, ImageIO (`CGImageSource` / `CGImageDestination`), Core Graphics, UniformTypeIdentifiers, Messages.framework, XCTest. No new dependencies.

**Source spec:** `docs/superpowers/specs/2026-08-08-animated-stickers-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Toolchain:** Xcode 26.6, Swift 6.3.3, iOS 26.5 SDK. **Swift Language Version is 5** — do not change it.
- **Deployment target iOS 17.0.**
- **Never** hand-author or hand-edit `project.pbxproj`. The project uses synchronized folder groups, so a `.swift` file created in `DiscordStickers/StickerKit/` or `DiscordStickers/StickerKitTests/` joins its target automatically.
- **Never** create, modify, or delete any `.xcscheme`.
- **No App Groups entitlement** in any target.
- **No third-party dependencies.**
- **Simulator is `iPhone 17 Pro`.**
- **`MSSticker` limits:** file ≤ 500,000 bytes; both dimensions 100–618 inclusive.
- **Memory:** the extension is killed between 40 and 120 MB. Never hold decoded images in a collection beyond the frames of the one sticker being processed.
- **CDN URLs carry no `size` parameter** — measured as ignored for both PNG and GIF.
- **A static emoji requested as `.gif` returns HTTP 415.** The extension must be chosen from `isAnimated`, never guessed.
- **Baseline: 64 tests passing.** This plan takes it to **87**.

**Commands used throughout:**

```bash
# tests
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# extension build
xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme DiscordStickersMessages \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

---

### Task 1: `isAnimated` on the model, and the animated constants

**Files:**
- Modify: `DiscordStickers/StickerKit/StickerEntry.swift`
- Modify: `DiscordStickers/StickerKit/StickerLimits.swift`
- Test: `DiscordStickers/StickerKitTests/StickerEntryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `StickerEntry` gains `public var isAnimated: Bool`, and its memberwise init gains a trailing `isAnimated: Bool = false`. **The default is required** — without it every existing call site stops compiling.
  - `StickerLimits.animatedCanvasSize = 128` and `StickerLimits.maxAnimatedFrames = 48`.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `StickerEntryTests` class in `DiscordStickers/StickerKitTests/StickerEntryTests.swift`:

```swift
    func testIsAnimatedRoundTripsThroughJSON() throws {
        let entry = StickerEntry(
            id: "1229610158183678072",
            name: "cuh",
            source: .pasted,
            addedAt: Date(timeIntervalSince1970: 1_754_604_840),
            useCount: 3,
            favoritedAt: nil,
            isAnimated: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(StickerEntry.self, from: data), entry)
    }

    func testDefaultsToNotAnimated() {
        let entry = StickerEntry(id: "1", name: "a", source: .pasted,
                                 addedAt: Date(), useCount: 0)
        XCTAssertFalse(entry.isAnimated)
    }

    func testManifestWrittenBeforeAnimationStillDecodes() throws {
        // The shape manifest.json had before this change — favoritedAt was
        // already optional, but isAnimated did not exist at all. This is the
        // test that protects stickers already on the user's device.
        let legacyJSON = """
        [{"addedAt":"2026-08-07T22:14:00Z","id":"823847191234",\
        "name":"blobcatcozy","source":"pasted","useCount":12}]
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([StickerEntry].self,
                                         from: Data(legacyJSON.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].useCount, 12)
        XCTAssertNil(entries[0].favoritedAt)
        XCTAssertFalse(entries[0].isAnimated)
    }

    func testAnimatedConstantsAreValidStickerDimensions() {
        XCTAssertGreaterThanOrEqual(StickerLimits.animatedCanvasSize,
                                    StickerLimits.minDimension)
        XCTAssertLessThanOrEqual(StickerLimits.animatedCanvasSize,
                                 StickerLimits.maxDimension)
        // Animated stickers pay for canvas size in file bytes as well as
        // memory, once per frame — so their canvas must be smaller than the
        // static one, not merely valid.
        XCTAssertLessThan(StickerLimits.animatedCanvasSize,
                          StickerLimits.canvasSize)
        XCTAssertGreaterThan(StickerLimits.maxAnimatedFrames, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `extra argument 'isAnimated' in call` and `type 'StickerLimits' has no member 'animatedCanvasSize'`.

- [ ] **Step 3: Add the property**

Replace the `StickerEntry` struct in `DiscordStickers/StickerKit/StickerEntry.swift`, keeping the existing `StickerSource` enum above it untouched:

```swift
/// One row of `manifest.json`. Every entry that reaches the manifest has had
/// an `MSSticker` successfully constructed from its file at least once.
public struct StickerEntry: Codable, Equatable {
    public let id: String
    public let name: String
    public let source: StickerSource
    public let addedAt: Date
    public var useCount: Int

    /// `nil` means not a favorite. One optional carries both membership and
    /// ordering, so the two cannot contradict each other.
    public var favoritedAt: Date?

    /// Whether this sticker's stored file is animated.
    ///
    /// Load-bearing, not metadata. `ManifestTransfer.restore` rebuilds
    /// `ParsedEmoji` values from a decoded backup and re-downloads them, and
    /// the CDN returns **HTTP 415** for a static emoji requested as `.gif`.
    /// Without persisting this, every animated sticker would come back
    /// static — or fail outright — after a restore.
    public var isAnimated: Bool

    public init(id: String, name: String, source: StickerSource,
                addedAt: Date, useCount: Int, favoritedAt: Date? = nil,
                isAnimated: Bool = false) {
        self.id = id
        self.name = name
        self.source = source
        self.addedAt = addedAt
        self.useCount = useCount
        self.favoritedAt = favoritedAt
        self.isAnimated = isAnimated
    }
}
```

- [ ] **Step 4: Add the constants**

In `DiscordStickers/StickerKit/StickerLimits.swift`, add immediately after the existing `fallbackCanvasSize` declaration:

```swift
    /// Side length of the square canvas animated stickers are rendered onto.
    ///
    /// Smaller than `canvasSize` because animated stickers pay for canvas
    /// area in **file bytes as well as memory**, once per frame. A measured
    /// Discord emoji is 76x61 with 94 frames at 157 KB; scaling that to the
    /// static 256 canvas multiplies pixel area ~14x across every frame,
    /// which is megabytes against a 500 KB ceiling.
    public static let animatedCanvasSize = 128

    /// Frames beyond this are dropped evenly, with their delays redistributed
    /// so total loop duration is unchanged. 48 keeps motion smooth to the eye
    /// while roughly halving the measured 94-frame case.
    public static let maxAnimatedFrames = 48
```

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: PASS, **68 tests total** (64 existing + 4 new).

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/StickerEntry.swift \
        DiscordStickers/StickerKit/StickerLimits.swift \
        DiscordStickers/StickerKitTests/StickerEntryTests.swift
git commit -m "feat: persist isAnimated and add the animated canvas budget"
```

---

### Task 2: `AnimatedStickerProcessor`

The heart of the feature. A pure transform: animated bytes in, animated bytes out, normalized onto the canvas with total duration preserved.

**Files:**
- Create: `DiscordStickers/StickerKit/AnimatedStickerProcessor.swift`
- Modify: `DiscordStickers/StickerKitTests/TempDirectory.swift`
- Test: `DiscordStickers/StickerKitTests/AnimatedStickerProcessorTests.swift`

**Interfaces:**
- Consumes: `StickerLimits.animatedCanvasSize`, `StickerLimits.maxAnimatedFrames` (Task 1).
- Produces:
  - `public enum AnimatedStickerProcessor`
  - `public static func normalize(_ data: Data, canvas: Int = StickerLimits.animatedCanvasSize, maxFrames: Int = StickerLimits.maxAnimatedFrames, asGIF: Bool = false) -> Data?` — APNG data of exactly `canvas`×`canvas`, or GIF when `asGIF` is true, or `nil` for input that is undecodable **or has fewer than 2 frames**.
  - `public static func frameCount(of data: Data) -> Int` — 0 when undecodable. Used by the downloader to decide routing and by tests.
  - `public static func totalDuration(of data: Data) -> Double` — summed frame delays in seconds, 0 when undecodable. Exists so tests can assert duration preservation.
- Also produces a test helper: `TempDirectory.makeAnimatedGIFData(frameCount:width:height:delay:) -> Data`.

- [ ] **Step 1: Add the animated-GIF test helper**

In `DiscordStickers/StickerKitTests/TempDirectory.swift`, add these imports at the top if not already present, alongside the existing ones:

```swift
import ImageIO
import UniformTypeIdentifiers
```

Then add this method inside the `TempDirectory` class:

```swift
    /// Builds an animated GIF in memory. Each frame is a different solid
    /// colour so frame-dropping can be observed, not just counted.
    func makeAnimatedGIFData(frameCount: Int = 10,
                             width: Int = 76,
                             height: Int = 61,
                             delay: Double = 0.05) -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            out, UTType.gif.identifier as CFString, frameCount, nil
        )!

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        for index in 0..<frameCount {
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: width, height: height)
            )
            let image = renderer.image { context in
                UIColor(hue: CGFloat(index) / CGFloat(max(frameCount, 1)),
                        saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CGImageDestinationAddImage(destination, image.cgImage!, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay
                ]
            ] as CFDictionary)
        }

        CGImageDestinationFinalize(destination)
        return out as Data
    }
```

- [ ] **Step 2: Write the failing tests**

Create `DiscordStickers/StickerKitTests/AnimatedStickerProcessorTests.swift`:

```swift
import XCTest
import UIKit
import ImageIO
@testable import StickerKit

final class AnimatedStickerProcessorTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
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

    func testNormalizesToTheAnimatedCanvas() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 10)
        let output = try XCTUnwrap(AnimatedStickerProcessor.normalize(input))
        let dimensions = try XCTUnwrap(size(of: output))

        XCTAssertEqual(dimensions.width, StickerLimits.animatedCanvasSize)
        XCTAssertEqual(dimensions.height, StickerLimits.animatedCanvasSize)
    }

    func testKeepsEveryFrameWhenUnderTheCap() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 10)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, maxFrames: 48)
        )

        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: output), 10)
    }

    func testDropsFramesDownToTheCap() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 94)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, maxFrames: 48)
        )

        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: output), 48)
    }

    func testDroppingFramesPreservesTotalDuration() throws {
        // The test that catches the half-speed bug. Dropping every other
        // frame while keeping the survivors' delays plays the loop at half
        // speed — still smooth, silently wrong, and invisible to any
        // frame-count or file-size assertion.
        let input = temp.makeAnimatedGIFData(frameCount: 94, delay: 0.05)
        let expected = AnimatedStickerProcessor.totalDuration(of: input)
        XCTAssertEqual(expected, 94 * 0.05, accuracy: 0.05,
                       "fixture itself is wrong if this fails")

        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, maxFrames: 48)
        )

        XCTAssertEqual(AnimatedStickerProcessor.totalDuration(of: output),
                       expected, accuracy: 0.05)
    }

    func testDropsFramesEvenlyRatherThanTruncating() throws {
        // A truncating implementation would keep frames 0..<48 of 94, so the
        // last surviving frame would be the input's 47th. Sampling evenly
        // means the last surviving frame is near the input's end. The frames
        // differ in hue, so comparing the final frame's pixels distinguishes
        // the two.
        let input = temp.makeAnimatedGIFData(frameCount: 94)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, maxFrames: 48)
        )

        let inputSource = try XCTUnwrap(
            CGImageSourceCreateWithData(input as CFData, nil)
        )
        let outputSource = try XCTUnwrap(
            CGImageSourceCreateWithData(output as CFData, nil)
        )

        // Each fixture frame is a single solid colour, so squashing a whole
        // frame into one pixel yields that colour.
        func colour(_ source: CGImageSource, at index: Int) throws -> [UInt8] {
            let image = try XCTUnwrap(
                CGImageSourceCreateImageAtIndex(source, index, nil)
            )
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return pixel
        }

        let lastOutput = try colour(outputSource, at: 47)
        let inputAt47 = try colour(inputSource, at: 47)
        let inputAt93 = try colour(inputSource, at: 93)

        // Sanity: the fixture's frames really do differ.
        XCTAssertNotEqual(inputAt47, inputAt93)
        // The kept last frame must come from near the end, not the middle.
        XCTAssertNotEqual(lastOutput, inputAt47,
                          "frames were truncated, not sampled evenly")
    }

    func testReturnsNilForASingleFrameImage() {
        let input = temp.makeAnimatedGIFData(frameCount: 1)
        XCTAssertNil(AnimatedStickerProcessor.normalize(input))
    }

    func testReturnsNilForUndecodableBytes() {
        XCTAssertNil(AnimatedStickerProcessor.normalize(Data("nope".utf8)))
        XCTAssertNil(AnimatedStickerProcessor.normalize(Data()))
    }

    func testEveryOutputSatisfiesMSStickerBounds() throws {
        for (width, height) in [(76, 61), (128, 128), (400, 20), (16, 16)] {
            let input = temp.makeAnimatedGIFData(
                frameCount: 6, width: width, height: height
            )
            let output = try XCTUnwrap(
                AnimatedStickerProcessor.normalize(input),
                "failed for \(width)x\(height)"
            )
            let dimensions = try XCTUnwrap(size(of: output))
            XCTAssertGreaterThanOrEqual(dimensions.width, StickerLimits.minDimension)
            XCTAssertLessThanOrEqual(dimensions.width, StickerLimits.maxDimension)
            XCTAssertGreaterThanOrEqual(dimensions.height, StickerLimits.minDimension)
            XCTAssertLessThanOrEqual(dimensions.height, StickerLimits.maxDimension)
        }
    }

    func testHonoursAnExplicitSmallerCanvas() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 6)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, canvas: 100)
        )

        XCTAssertEqual(try XCTUnwrap(size(of: output)).width, 100)
    }

    func testCanEncodeAsGIFWhenAsked() throws {
        let input = temp.makeAnimatedGIFData(frameCount: 6)
        let output = try XCTUnwrap(
            AnimatedStickerProcessor.normalize(input, asGIF: true)
        )

        // GIF87a / GIF89a both begin "GIF".
        XCTAssertEqual(Array(output.prefix(3)), Array("GIF".utf8))
        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: output), 6)
    }

    func testFrameCountAndDurationHandleGarbage() {
        XCTAssertEqual(AnimatedStickerProcessor.frameCount(of: Data()), 0)
        XCTAssertEqual(AnimatedStickerProcessor.totalDuration(of: Data()), 0)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run the test command. Expected: FAIL — `cannot find 'AnimatedStickerProcessor' in scope`.

- [ ] **Step 4: Write the processor**

Create `DiscordStickers/StickerKit/AnimatedStickerProcessor.swift`:

```swift
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Normalizes animated images onto a fixed square transparent canvas,
/// capping frame count, and re-encodes them as APNG (or GIF on request).
///
/// A sibling of `StickerImageProcessor` rather than a mode of it, because
/// animated stickers are constrained differently in kind: file size scales
/// with frame count, not just canvas area, so the static 256 canvas is
/// simply wrong for them.
public enum AnimatedStickerProcessor {

    /// The de-facto default a browser applies to a zero-delay GIF frame.
    private static let fallbackDelay = 0.1

    /// Returns animated image data of exactly `canvas` x `canvas`, or `nil`
    /// if `data` is undecodable **or contains fewer than two frames** — a
    /// single-frame image is not animated and belongs to
    /// `StickerImageProcessor`.
    public static func normalize(
        _ data: Data,
        canvas: Int = StickerLimits.animatedCanvasSize,
        maxFrames: Int = StickerLimits.maxAnimatedFrames,
        asGIF: Bool = false
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count >= 2 else { return nil }

        var frames: [(image: CGImage, delay: Double)] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil)
            else { continue }
            frames.append((image, delay(of: source, at: index)))
        }
        guard frames.count >= 2 else { return nil }

        return encode(reduce(frames, to: maxFrames), canvas: canvas, asGIF: asGIF)
    }

    public static func frameCount(of data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return 0 }
        return CGImageSourceGetCount(source)
    }

    public static func totalDuration(of data: Data) -> Double {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return 0 }
        return (0..<CGImageSourceGetCount(source))
            .reduce(0.0) { $0 + delay(of: source, at: $1) }
    }

    // MARK: - Frames

    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any]
        else { return fallbackDelay }

        func read(_ dictionary: CFString,
                  _ unclamped: CFString,
                  _ clamped: CFString) -> Double? {
            guard let container = properties[dictionary] as? [CFString: Any]
            else { return nil }
            let value = (container[unclamped] as? Double)
                ?? (container[clamped] as? Double)
                ?? 0
            return value > 0 ? value : nil
        }

        return read(kCGImagePropertyGIFDictionary,
                    kCGImagePropertyGIFUnclampedDelayTime,
                    kCGImagePropertyGIFDelayTime)
            ?? read(kCGImagePropertyPNGDictionary,
                    kCGImagePropertyAPNGUnclampedDelayTime,
                    kCGImagePropertyAPNGDelayTime)
            ?? fallbackDelay
    }

    /// Samples `maxFrames` evenly across the input and folds each dropped
    /// frame's delay into the surviving frame that precedes it.
    ///
    /// The delay accumulation is the part that matters. Dropping every other
    /// frame while keeping the survivors' own delays plays the loop at half
    /// speed — still smooth, silently wrong, and invisible to any assertion
    /// about frame count or file size.
    private static func reduce(
        _ frames: [(image: CGImage, delay: Double)],
        to maxFrames: Int
    ) -> [(image: CGImage, delay: Double)] {
        guard maxFrames > 0, frames.count > maxFrames else { return frames }

        let kept = (0..<maxFrames).map { step in
            Int(Double(step) * Double(frames.count) / Double(maxFrames))
        }

        return kept.enumerated().map { position, start in
            let end = position + 1 < kept.count ? kept[position + 1] : frames.count
            let absorbed = frames[start..<end].reduce(0.0) { $0 + $1.delay }
            return (frames[start].image, absorbed)
        }
    }

    // MARK: - Rendering

    /// Aspect-fit and centre one frame onto the square canvas. Uses
    /// `CGContext` directly rather than `UIGraphicsImageRenderer` so no
    /// `UIImage` round-trip is needed and the alpha channel is explicit.
    private static func render(_ image: CGImage, canvas: Int) -> CGImage? {
        let side = CGFloat(canvas)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }

        let scale = min(side / width, side / height)
        let drawn = CGSize(width: width * scale, height: height * scale)
        let origin = CGPoint(x: (side - drawn.width) / 2,
                             y: (side - drawn.height) / 2)

        guard let context = CGContext(
            data: nil, width: canvas, height: canvas,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: origin, size: drawn))
        return context.makeImage()
    }

    private static func encode(
        _ frames: [(image: CGImage, delay: Double)],
        canvas: Int,
        asGIF: Bool
    ) -> Data? {
        let output = NSMutableData()
        let type = (asGIF ? UTType.gif : UTType.png).identifier as CFString

        guard let destination = CGImageDestinationCreateWithData(
            output, type, frames.count, nil
        ) else { return nil }

        CGImageDestinationSetProperties(destination, (asGIF
            ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
        ) as CFDictionary)

        for frame in frames {
            guard let rendered = render(frame.image, canvas: canvas)
            else { return nil }

            CGImageDestinationAddImage(destination, rendered, (asGIF
                ? [kCGImagePropertyGIFDictionary:
                    [kCGImagePropertyGIFDelayTime: frame.delay]]
                : [kCGImagePropertyPNGDictionary:
                    [kCGImagePropertyAPNGDelayTime: frame.delay]]
            ) as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: PASS, **79 tests total** (68 + 11 new).

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/AnimatedStickerProcessor.swift \
        DiscordStickers/StickerKitTests/AnimatedStickerProcessorTests.swift \
        DiscordStickers/StickerKitTests/TempDirectory.swift
git commit -m "feat: add AnimatedStickerProcessor preserving loop duration"
```

---

### Task 3: Downloader routing, 415 retry, and the fallback ladder

**Files:**
- Modify: `DiscordStickers/StickerKit/EmojiDownloader.swift`
- Test: `DiscordStickers/StickerKitTests/EmojiDownloaderTests.swift`

**Interfaces:**
- Consumes: `AnimatedStickerProcessor.normalize(_:canvas:maxFrames:asGIF:)` (Task 2), `StickerEntry.isAnimated` and the animated constants (Task 1).
- Produces: no new public API. `EmojiDownloader.download(_:)` keeps its signature; behaviour changes.

- [ ] **Step 1: Write the failing tests**

Append to the existing `EmojiDownloaderTests` class in `DiscordStickers/StickerKitTests/EmojiDownloaderTests.swift`. Note the class already has a private `temp` property of type `TempDirectory`:

```swift
    private func animatedEmoji(_ id: String, _ name: String) -> ParsedEmoji {
        ParsedEmoji(id: id, name: name, isAnimated: true)
    }

    func testRequestsGIFForAnimatedEmoji() async throws {
        StubURLProtocol.handler = { _ in
            (200, self.temp.makeAnimatedGIFData(frameCount: 6))
        }

        _ = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(StubURLProtocol.requestedURLs.first?.lastPathComponent,
                       "111.gif")
        XCTAssertNil(StubURLProtocol.requestedURLs.first?.query)
    }

    func testRequestsPNGForStaticEmoji() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(StubURLProtocol.requestedURLs.first?.lastPathComponent,
                       "111.png")
    }

    func testStoresAnimatedFlagOnTheEntry() async throws {
        StubURLProtocol.handler = { _ in
            (200, self.temp.makeAnimatedGIFData(frameCount: 6))
        }

        _ = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(store.all().first?.isAnimated, true)
    }

    func testRetriesWithPNGWhenGIFReturns415() async throws {
        // A wrong isAnimated flag: the CDN answers 415 for a static emoji
        // requested as .gif. Retrying self-heals it instead of reporting a
        // puzzling failure.
        StubURLProtocol.handler = { request in
            request.url?.lastPathComponent == "111.gif"
                ? (415, Data())
                : (200, self.pngData(width: 128))
        }

        let outcome = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertEqual(StubURLProtocol.requestedURLs.map(\.lastPathComponent),
                       ["111.gif", "111.png"])
        XCTAssertEqual(store.all().first?.isAnimated, false,
                       "the corrected flag must be what gets stored")
    }

    func testRetriesWithGIFWhenPNGReturns415() async throws {
        StubURLProtocol.handler = { request in
            request.url?.lastPathComponent == "111.png"
                ? (415, Data())
                : (200, self.temp.makeAnimatedGIFData(frameCount: 6))
        }

        let outcome = await makeDownloader().download([emoji("111", "wave")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertEqual(store.all().first?.isAnimated, true)
    }

    func testRejectsWhenBothExtensions415() async throws {
        StubURLProtocol.handler = { _ in (415, Data()) }

        let outcome = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(outcome.unusable, ["111"])
        XCTAssertTrue(store.all().isEmpty)
    }

    func testAnimatedSourceWithOneFrameIsStoredAsStatic() async throws {
        // Fewer than two frames is not animation. It must route to the static
        // processor rather than being rejected.
        StubURLProtocol.handler = { _ in
            (200, self.temp.makeAnimatedGIFData(frameCount: 1))
        }

        let outcome = await makeDownloader().download([animatedEmoji("111", "cuh")])

        XCTAssertEqual(outcome.added, ["111"])
        XCTAssertEqual(store.all().first?.isAnimated, false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `testRequestsGIFForAnimatedEmoji` fails on `"111.png"` not equalling `"111.gif"`, and the 415 tests fail because no retry exists.

- [ ] **Step 3: Rewrite the fetch and commit path**

In `DiscordStickers/StickerKit/EmojiDownloader.swift`, replace the existing `fetchOne(_:)`, the `FetchResult` enum, and `fetch(id:)` with the following. Leave `download(_:)`, the task-group concurrency loop, and `DownloadOutcome` untouched.

```swift
    private enum FetchResult {
        case success(Data)
        case notFound
        case unsupportedType
        case failed
    }

    private func fetchOne(_ emoji: ParsedEmoji) async -> ItemResult {
        switch await fetch(id: emoji.id, animated: emoji.isAnimated) {
        case .notFound:
            return .missing(emoji.id)
        case .failed:
            return .unusable(emoji.id)
        case .success(let raw):
            return process(emoji, raw: raw, animated: emoji.isAnimated)
        case .unsupportedType:
            // The flag disagreed with reality. The CDN returns 415 for a
            // static emoji requested as .gif, so retry with the other
            // extension and store whichever answer actually worked.
            switch await fetch(id: emoji.id, animated: !emoji.isAnimated) {
            case .success(let raw):
                return process(emoji, raw: raw, animated: !emoji.isAnimated)
            case .notFound:
                return .missing(emoji.id)
            case .failed, .unsupportedType:
                return .unusable(emoji.id)
            }
        }
    }

    /// No `size` parameter in either case — measured as ignored for both
    /// formats, so sending one either changes nothing or degrades the source.
    private func fetch(id: String, animated: Bool) async -> FetchResult {
        let ext = animated ? "gif" : "png"
        guard let url = URL(
            string: "https://cdn.discordapp.com/emojis/\(id).\(ext)"
        ) else { return .failed }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200: return .success(data)
            case 404: return .notFound
            case 415: return .unsupportedType
            default:  return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Routes to the animated or static processor and applies the size
    /// fallback ladder. Frames are sacrificed before resolution: a slightly
    /// choppier animation reads as intentional, a blurry sticker reads as
    /// broken.
    private func process(_ emoji: ParsedEmoji, raw: Data, animated: Bool) -> ItemResult {
        guard animated else {
            guard let normalized = StickerImageProcessor.normalize(raw) else {
                return .unusable(emoji.id)
            }
            if normalized.count <= StickerLimits.maxBytes {
                return commit(emoji, data: normalized, animated: false)
            }
            guard let smaller = StickerImageProcessor.normalize(
                raw, canvas: StickerLimits.fallbackCanvasSize
            ), smaller.count <= StickerLimits.maxBytes else {
                return .unusable(emoji.id)
            }
            return commit(emoji, data: smaller, animated: false)
        }

        // Fewer than two frames is not animation; normalize returns nil and
        // the source is stored as an ordinary static sticker.
        guard AnimatedStickerProcessor.frameCount(of: raw) >= 2 else {
            return process(emoji, raw: raw, animated: false)
        }

        let attempts: [(canvas: Int, frames: Int)] = [
            (StickerLimits.animatedCanvasSize, StickerLimits.maxAnimatedFrames),
            (StickerLimits.animatedCanvasSize, StickerLimits.maxAnimatedFrames / 2),
            (StickerLimits.minDimension, StickerLimits.maxAnimatedFrames / 2),
        ]

        for attempt in attempts {
            guard let encoded = AnimatedStickerProcessor.normalize(
                raw, canvas: attempt.canvas, maxFrames: attempt.frames
            ) else { return .unusable(emoji.id) }

            if encoded.count <= StickerLimits.maxBytes {
                return commit(emoji, data: encoded, animated: true)
            }
        }
        return .unusable(emoji.id)
    }
```

- [ ] **Step 4: Teach `commit` about animation**

Still in `DiscordStickers/StickerKit/EmojiDownloader.swift`, change `commit`'s signature and the entry it builds. Replace its declaration line and the `store.add` call:

```swift
    private func commit(_ emoji: ParsedEmoji, data: Data, animated: Bool) -> ItemResult {
```

and, inside it, the entry construction:

```swift
            try store.add(
                StickerEntry(id: emoji.id, name: emoji.name, source: .pasted,
                             addedAt: Date(), useCount: 0, favoritedAt: nil,
                             isAnimated: animated),
                movingFileFrom: tempURL
            )
```

The temp file's extension does not need to change — `MSSticker` reads the file's contents, not its name, and `StickerStore` already keys everything on id.

**If `MSSticker` construction throws for an APNG**, the existing `catch` already returns `.unusable`. That is the outright-rejection case; the format fallback to GIF is deliberately **not** implemented here, because it cannot be verified in the simulator. Task 5 step 4 covers it on device and tells you exactly what to change if it is needed.

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: PASS, **86 tests total** (79 + 7 new).

- [ ] **Step 6: Verify the extension still builds**

Run the extension build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add DiscordStickers/StickerKit/EmojiDownloader.swift \
        DiscordStickers/StickerKitTests/EmojiDownloaderTests.swift
git commit -m "feat: fetch animated emoji as GIF with a 415 self-heal and size ladder"
```

---

### Task 4: Preserve `isAnimated` through backup and restore

The failure this exists to prevent is the one the Favorites review caught in its own form: a field present in the model, dropped on the restore path, invisible until someone traces the whole flow.

**Files:**
- Modify: `DiscordStickers/StickerKit/ManifestTransfer.swift`
- Test: `DiscordStickers/StickerKitTests/ManifestTransferTests.swift`

**Interfaces:**
- Consumes: `StickerEntry.isAnimated` (Task 1).
- Produces: no API change.

- [ ] **Step 1: Write the failing test**

Append to the existing `ManifestTransferTests` class:

```swift
    func testRestorePreservesTheAnimatedFlag() async throws {
        // Without this, restore rebuilds ParsedEmoji with isAnimated false,
        // requests .png for an animated emoji, and the CDN answers 415 — so
        // an animated sticker comes back broken rather than merely static.
        let entries = [
            StickerEntry(id: "111", name: "cuh", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 1000),
                         useCount: 0, favoritedAt: nil, isAnimated: true),
            StickerEntry(id: "222", name: "wave", source: .pasted,
                         addedAt: Date(timeIntervalSince1970: 2000),
                         useCount: 0, favoritedAt: nil, isAnimated: false),
        ]

        StubURLProtocol.handler = { request in
            switch request.url?.lastPathComponent {
            case "111.gif": return (200, self.temp.makeAnimatedGIFData(frameCount: 6))
            case "222.png": return (200, self.pngData(width: 128))
            default:        return (415, Data())
            }
        }

        _ = await ManifestTransfer.restore(entries, store: store,
                                           downloader: makeDownloader())

        let byID = Dictionary(uniqueKeysWithValues: store.all().map { ($0.id, $0) })
        XCTAssertEqual(byID["111"]?.isAnimated, true)
        XCTAssertEqual(byID["222"]?.isAnimated, false)
        XCTAssertEqual(store.all().count, 2)
    }
```

This test needs a `pngData(width:)` helper and a `makeDownloader()` in `ManifestTransferTests`. If the class does not already have them, add these two private methods to it:

```swift
    private func pngData(width: Int) -> Data {
        let size = CGSize(width: width, height: width)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private func makeDownloader() -> EmojiDownloader {
        EmojiDownloader(store: store, session: StubURLProtocol.makeSession())
    }
```

and ensure the file imports `UIKit` at the top alongside its existing imports.

- [ ] **Step 2: Run the test to verify it fails**

Run the test command. Expected: FAIL — `byID["111"]?.isAnimated` is `false`, or the entry is missing entirely because `.png` was requested and the stub answered 415.

- [ ] **Step 3: Carry the flag into the rebuilt `ParsedEmoji`**

In `DiscordStickers/StickerKit/ManifestTransfer.swift`, inside `restore(_:store:downloader:)`, the call that builds `ParsedEmoji` values currently hardcodes `isAnimated: false`. Change it to read the entry's own flag:

```swift
        let outcome = await downloader.download(
            entries.map {
                ParsedEmoji(id: $0.id, name: $0.name, isAnimated: $0.isAnimated)
            }
        )
```

- [ ] **Step 4: Update the type's doc comment**

The comment at the top of `ManifestTransfer` names `useCount` and `favoritedAt` as the values a backup rescues. Add `isAnimated` to that list, noting it must survive because the CDN returns 415 for the wrong extension, so losing it breaks a restore rather than merely degrading it.

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: PASS, **87 tests total** (86 + 1 new).

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/ManifestTransfer.swift \
        DiscordStickers/StickerKitTests/ManifestTransferTests.swift
git commit -m "fix: carry isAnimated through backup and restore"
```

---

### Task 5: Device verification — the format gate

**Everything in this feature rests on one unverified assumption: that `MSSticker` actually animates an APNG.** Apple documents APNG as a supported sticker format, but this project has twice had a documented behaviour disagree with a real device. Run this before treating the feature as done.

**Files:**
- Create: `docs/superpowers/plans/task-5-animated-device-checklist.md`

**Interfaces:**
- Consumes: the built app.
- Produces: a recorded pass/fail per item, and a go/no-go on APNG.

- [ ] **Step 1: Install on the device**

Connect the iPhone, select the `DiscordStickersMessages` scheme and the device as destination, Run, and choose Messages as the host app. Dismiss "Could not attach to pid" if it appears — an extension only launches when tapped, so the install still succeeded.

- [ ] **Step 2: Import an animated emoji**

In Discord, send a message containing at least one **animated** emoji (its markup starts `<a:`) alongside two static ones. Long-press the sent message → Copy Text. In the sticker drawer, expand and tap Paste Emoji, then Allow.

Expect a summary reporting all three added.

- [ ] **Step 3: THE GATE — does it move?**

Look at the animated sticker in the grid.

**It must be animating.** If it is a still image, `MSSticker` accepted the APNG and is rendering only its first frame — the exact failure the format fallback cannot detect, because construction succeeded.

If it is still: go to Step 4. If it moves: skip Step 4 and continue at Step 5.

- [ ] **Step 4: Only if APNG did not animate — switch to GIF**

`AnimatedStickerProcessor.normalize` already takes an `asGIF` parameter, so this is a one-word change at the call site. In `DiscordStickers/StickerKit/EmojiDownloader.swift`, inside `process(_:raw:animated:)`, add `asGIF: true` to both `AnimatedStickerProcessor.normalize` calls in the attempt loop.

Then delete the app from the phone (so old APNG files are gone), rebuild, re-import, and repeat Step 3.

Record which format worked. Commit the change if GIF was needed:

```bash
git add DiscordStickers/StickerKit/EmojiDownloader.swift
git commit -m "fix: encode animated stickers as GIF, APNG does not animate in MSStickerView"
```

- [ ] **Step 5: Does it still move after sending?**

Tap the animated sticker to send it into the conversation. It must animate in the message bubble too — a sticker that animates in the drawer but freezes when sent is still a failure.

- [ ] **Step 6: Check the loop speed**

Compare the sticker's animation against the same emoji in Discord. They should run at roughly the same speed.

**If ours is noticeably slower, the frame-delay redistribution is wrong** — dropped frames' delays are being discarded rather than absorbed. That is a code bug, not a tuning issue; report it.

- [ ] **Step 7: The memory check**

Import enough emoji that the grid contains **at least 20 animated stickers**, then scroll rapidly for several passes.

Expect no crash and no blank drawer. If the extension dies, reduce `StickerLimits.maxAnimatedFrames` from 48 to 24 first — frames cost more than canvas here — rebuild, and repeat.

- [ ] **Step 8: Confirm static stickers are unchanged**

Send a static sticker and drag one onto a message bubble. Both must behave exactly as before this feature. Animated support must not have regressed the path that already worked.

- [ ] **Step 9: Record results and commit**

Write `docs/superpowers/plans/task-5-animated-device-checklist.md` with one line per step: pass/fail, the format that ended up working, and the final `maxAnimatedFrames` value.

```bash
git add docs/superpowers/plans/task-5-animated-device-checklist.md
git commit -m "docs: record animated sticker device verification"
```

---

## Deferred

From the spec's §9, listed so nothing is lost:

- **A global "disable animation" setting** — the escape hatch if animated stickers prove too heavy in practice. Speculative until there is evidence.
- **Animated stickers from user photos or Live Photos.**
- **Per-sticker frame-rate tuning.**
- **7TV animated emotes**, which arrive as animated WEBP. Same transform shape, different decode. Belongs with the desktop-companion work.
- **An animated badge in the grid**, marking which stickers move.
