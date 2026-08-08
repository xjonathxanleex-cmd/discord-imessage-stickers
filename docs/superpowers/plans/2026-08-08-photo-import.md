# Photo Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user pick images from their photo library and turn them into named stickers.

**Architecture:** Reuses link import wholesale — `StickerReviewViewController`, `StickerImporter`, and `ContentHash` are untouched. Only two things are new: an `ImageDownsampler` extracted from `DraftFetcher` so both entry points share it, and a `PhotoDraftLoader` that turns picked image data into drafts. A modern iPhone photo is 12 megapixels and decodes to ~49 MB, so downsampling is not an optimization here — it is what keeps the extension alive.

**Tech Stack:** Swift 5 language mode, UIKit, PhotosUI, ImageIO, XCTest. No new dependencies.

**Source spec:** `docs/superpowers/specs/2026-08-08-import-sources-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Toolchain:** Xcode 26.6, Swift 6.3.3, iOS 26.5 SDK. **Swift Language Version is 5** — do not change it.
- **Deployment target iOS 17.0.**
- **Never** hand-author or hand-edit `project.pbxproj`. Synchronized folder groups add new files to their target automatically.
- **Never** create, modify, or delete any `.xcscheme`.
- **No App Groups entitlement** in any target.
- **No third-party dependencies.** PhotosUI is a system framework.
- **Simulator is `iPhone 17 Pro`.**
- **`MSSticker` limits:** file ≤ 500,000 bytes; both dimensions 100–618 inclusive.
- **Memory:** the extension is killed between 40 and 120 MB. A 12 MP photo decodes to ~49 MB on its own; **never** decode a picked image at full resolution.
- **`StickerSource` is String-raw-valued and persisted** — `.photo` already exists; do not rename or remove any case.
- **Baseline: 130 tests passing.** This plan takes it to **143**.

**Commands used throughout:**

```bash
xcodebuild test -project DiscordStickers/DiscordStickers.xcodeproj -scheme StickerKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild build -project DiscordStickers/DiscordStickers.xcodeproj -scheme DiscordStickersMessages \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

---

### Task 1: Extract `ImageDownsampler`

`DraftFetcher` already reads dimensions from metadata and downsamples through ImageIO's thumbnail path. Photo import needs exactly that, and a second copy is how the two drift — the same reasoning that produced `StickerCommitter`.

**Files:**
- Create: `DiscordStickers/StickerKit/ImageDownsampler.swift`
- Modify: `DiscordStickers/StickerKit/DraftFetcher.swift`
- Test: `DiscordStickers/StickerKitTests/ImageDownsamplerTests.swift`

**Interfaces:**
- Consumes: `StickerLimits` (existing).
- Produces:
  - `public enum ImageDownsampler`
  - `public static func pixelSize(of data: Data) -> (width: Int, height: Int)?` — from metadata only, no decode. `nil` when the bytes are not a decodable image.
  - `public static func downsampled(_ data: Data, maxPixel: Int) -> Data?` — PNG data whose largest dimension is at most `maxPixel`, decoded directly at that size. `nil` when the bytes are not a decodable image.

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/ImageDownsamplerTests.swift`:

```swift
import XCTest
import UIKit
@testable import StickerKit

final class ImageDownsamplerTests: XCTestCase {

    /// `format.scale = 1` is required. `UIGraphicsImageRenderer` defaults to
    /// the screen's scale, which is 3x on this simulator — a fixture asking
    /// for 128x128 would silently produce 384x384, and every dimension
    /// assertion below would be measuring the wrong thing.
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testReadsPixelSizeWithoutDecoding() {
        let size = ImageDownsampler.pixelSize(of: png(width: 300, height: 200))
        XCTAssertEqual(size?.width, 300)
        XCTAssertEqual(size?.height, 200)
    }

    func testPixelSizeIsNilForNonImages() {
        XCTAssertNil(ImageDownsampler.pixelSize(of: Data("nope".utf8)))
        XCTAssertNil(ImageDownsampler.pixelSize(of: Data()))
    }

    func testDownsamplesTheLongEdgeToTheLimit() throws {
        let output = try XCTUnwrap(
            ImageDownsampler.downsampled(png(width: 2000, height: 1000),
                                         maxPixel: 618)
        )
        let size = try XCTUnwrap(ImageDownsampler.pixelSize(of: output))

        XCTAssertEqual(size.width, 618)
        XCTAssertEqual(size.height, 309, "aspect ratio must be preserved")
    }

    func testDownsamplingIsNotUpscaling() throws {
        // A small image must come back at its own size, not blown up to the
        // limit — upscaling here would waste bytes and add no detail.
        let output = try XCTUnwrap(
            ImageDownsampler.downsampled(png(width: 100, height: 80),
                                         maxPixel: 618)
        )
        let size = try XCTUnwrap(ImageDownsampler.pixelSize(of: output))

        XCTAssertLessThanOrEqual(size.width, 100)
        XCTAssertLessThanOrEqual(size.height, 80)
    }

    func testDownsampledIsNilForNonImages() {
        XCTAssertNil(ImageDownsampler.downsampled(Data("nope".utf8),
                                                  maxPixel: 618))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `cannot find 'ImageDownsampler' in scope`.

- [ ] **Step 3: Create the shared unit**

Create `DiscordStickers/StickerKit/ImageDownsampler.swift`:

```swift
import UIKit
import ImageIO

/// Reads image dimensions from metadata and decodes images directly at a
/// reduced size.
///
/// This is what makes a byte cap actually bound memory. A byte cap does not
/// bound a bitmap: flat artwork at 8000x6000 compresses to under 10 MB and
/// decodes to roughly 192 MB, and an ordinary 12-megapixel iPhone photo
/// decodes to about 49 MB — against an extension that is killed somewhere
/// between 40 and 120 MB.
///
/// Extracted from `DraftFetcher` so link import and photo import share one
/// implementation rather than growing two that drift.
public enum ImageDownsampler {

    /// Dimensions from the file header. Parses metadata only — no pixels are
    /// decoded, so this is safe to call on bytes of unknown size.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Decodes straight to the target size via ImageIO's thumbnail path, so
    /// the full-resolution bitmap is never materialized.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` combined with a max
    /// pixel size never enlarges an image that is already smaller than the
    /// limit, so a small source comes back at its own size.
    public static func downsampled(_ data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }

        return UIImage(cgImage: thumbnail).pngData()
    }
}
```

- [ ] **Step 4: Route `DraftFetcher` through it**

In `DiscordStickers/StickerKit/DraftFetcher.swift`, delete its private dimension-reading and downsampling helpers and call `ImageDownsampler.pixelSize(of:)` and `ImageDownsampler.downsampled(_:maxPixel:)` instead. **Change nothing about when or why they are called** — the size cap, the dimension rejection, and the static-only downsampling rule all stay exactly as they are.

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: PASS, **135 tests total** (130 + 5 new).

**All 130 pre-existing tests must pass unchanged.** They are the proof the extraction changed no behaviour — `DraftFetcherTests` already covers the dimension cap and the downsampling path. If any needs editing, the extraction is wrong; report it rather than adjusting the test.

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/ImageDownsampler.swift \
        DiscordStickers/StickerKit/DraftFetcher.swift \
        DiscordStickers/StickerKitTests/ImageDownsamplerTests.swift
git commit -m "refactor: extract ImageDownsampler for reuse by photo import"
```

---

### Task 2: `PhotoDraftLoader`

Turns picked image data into drafts. Pure — the picker itself is Task 3.

**Files:**
- Create: `DiscordStickers/StickerKit/PhotoDraftLoader.swift`
- Test: `DiscordStickers/StickerKitTests/PhotoDraftLoaderTests.swift`

**Interfaces:**
- Consumes: `ImageDownsampler` (Task 1), `AnimatedStickerProcessor.frameCount(of:)` (existing), `StickerDraft` and `StickerLimits` (existing).
- Produces: `public enum PhotoDraftLoader { public static func drafts(from images: [Data]) -> [StickerDraft] }` — one draft per decodable input, in order, named `photo 1`, `photo 2`, …; undecodable inputs are dropped.

- [ ] **Step 1: Write the failing tests**

Create `DiscordStickers/StickerKitTests/PhotoDraftLoaderTests.swift`:

```swift
import XCTest
import UIKit
@testable import StickerKit

final class PhotoDraftLoaderTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
    }

    /// `format.scale = 1` matters: the renderer otherwise uses the screen's
    /// scale, so a fixture asking for 4000x3000 would produce 12000x9000 and
    /// the assertions below would be measuring something else entirely.
    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testNamesDraftsSequentially() {
        let drafts = PhotoDraftLoader.drafts(from: [
            png(width: 100, height: 100),
            png(width: 120, height: 90),
        ])

        XCTAssertEqual(drafts.map(\.name), ["photo 1", "photo 2"])
    }

    func testMarksDraftsAsComingFromPhotos() {
        let drafts = PhotoDraftLoader.drafts(from: [png(width: 100, height: 100)])
        XCTAssertEqual(drafts.first?.origin, .photo)
    }

    func testDownsamplesALargePhoto() throws {
        // A 12-megapixel iPhone photo decodes to roughly 49 MB. Against an
        // extension killed between 40 and 120 MB, downsampling is survival,
        // not optimization.
        let drafts = PhotoDraftLoader.drafts(from: [png(width: 4032, height: 3024)])
        let draft = try XCTUnwrap(drafts.first)
        let size = try XCTUnwrap(ImageDownsampler.pixelSize(of: draft.imageData))

        XCTAssertLessThanOrEqual(size.width, StickerLimits.maxDimension)
        XCTAssertLessThanOrEqual(size.height, StickerLimits.maxDimension)
    }

    func testDetectsAnimationFromTheBytes() {
        // Unlike link import, which must guess from a URL's extension, the
        // picked bytes are in hand — so animation is detected, not assumed.
        let drafts = PhotoDraftLoader.drafts(
            from: [temp.makeAnimatedGIFData(frameCount: 6)]
        )

        XCTAssertEqual(drafts.first?.isAnimated, true)
    }

    func testASingleFrameImageIsNotAnimated() {
        let drafts = PhotoDraftLoader.drafts(
            from: [temp.makeAnimatedGIFData(frameCount: 1)]
        )

        XCTAssertEqual(drafts.first?.isAnimated, false)
    }

    func testAnimatedImagesAreNotDownsampled() throws {
        // Downsampling reads frame 0 only, which would silently flatten an
        // animation into a still image.
        let animated = temp.makeAnimatedGIFData(frameCount: 6)
        let drafts = PhotoDraftLoader.drafts(from: [animated])

        XCTAssertEqual(drafts.first?.imageData, animated)
    }

    func testDropsUndecodableInputsAndKeepsNumberingContiguous() {
        let drafts = PhotoDraftLoader.drafts(from: [
            png(width: 100, height: 100),
            Data("not an image".utf8),
            png(width: 100, height: 100),
        ])

        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts.map(\.name), ["photo 1", "photo 2"],
                       "numbering must not leave a gap where a bad input was")
    }

    func testAnEmptyInputProducesNoDrafts() {
        XCTAssertTrue(PhotoDraftLoader.drafts(from: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `cannot find 'PhotoDraftLoader' in scope`.

- [ ] **Step 3: Write it**

Create `DiscordStickers/StickerKit/PhotoDraftLoader.swift`:

```swift
import Foundation

/// Turns image data picked from the photo library into drafts.
///
/// The counterpart to `DraftFetcher` for local images: no network, and one
/// genuine advantage over the link path — the bytes are in hand, so whether
/// an image is animated is **detected** rather than guessed from a URL's
/// file extension.
public enum PhotoDraftLoader {

    /// One draft per decodable input, in order. Undecodable inputs are
    /// dropped and the numbering stays contiguous, so a user who picked five
    /// photos and had one fail sees `photo 1`…`photo 4` rather than a gap.
    public static func drafts(from images: [Data]) -> [StickerDraft] {
        var drafts: [StickerDraft] = []

        for data in images {
            guard ImageDownsampler.pixelSize(of: data) != nil else { continue }

            let isAnimated = AnimatedStickerProcessor.frameCount(of: data) >= 2

            // Downsampling reads frame 0 only, so applying it to an animated
            // image would silently flatten it. Animated sources pass through
            // untouched; AnimatedStickerProcessor streams one frame at a time
            // and bounds its own memory.
            let payload = isAnimated
                ? data
                : (ImageDownsampler.downsampled(
                    data, maxPixel: StickerLimits.maxDimension
                ) ?? data)

            drafts.append(StickerDraft(
                name: "photo \(drafts.count + 1)",
                imageData: payload,
                origin: .photo,
                isAnimated: isAnimated
            ))
        }

        return drafts
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS, **143 tests total** (135 + 8 new).

- [ ] **Step 5: Commit**

```bash
git add DiscordStickers/StickerKit/PhotoDraftLoader.swift \
        DiscordStickers/StickerKitTests/PhotoDraftLoaderTests.swift
git commit -m "feat: turn picked photos into drafts, detecting animation from bytes"
```

---

### Task 3: Wire the picker into the extension

**Files:**
- Modify: `DiscordStickers/StickerKit/PasteViewController.swift`

**Interfaces:**
- Consumes: `PhotoDraftLoader` (Task 2), and the existing private `presentReview(for:)`.
- Produces: an **Add Photos** button beside the existing Paste Link / Back Up / Restore buttons.

No unit tests — `PHPickerViewController` cannot be exercised without a running UI. Task 4 verifies it.

- [ ] **Step 1: Add the button**

In `DiscordStickers/StickerKit/PasteViewController.swift`, add `import PhotosUI` and `import UniformTypeIdentifiers` at the top alongside the existing imports, and a stored property beside the other buttons:

```swift
    private let photoButton = UIButton(type: .system)
```

In `viewDidLoad`, configure it exactly as the neighbouring buttons are configured and add it to the same horizontal `buttons` stack, immediately after `linkButton`:

```swift
        photoButton.setTitle("Add Photos", for: .normal)
        photoButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        photoButton.addTarget(self, action: #selector(photosTapped),
                              for: .touchUpInside)
```

- [ ] **Step 2: Present the picker**

Add these methods beside the existing `linkTapped`:

```swift
    @objc private func photosTapped() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0        // unlimited
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Loads every picked item's raw data, preserving the order the user
    /// chose. `loadDataRepresentation` gives the original bytes rather than a
    /// decoded `UIImage`, which is what lets `PhotoDraftLoader` downsample
    /// before anything is decoded at full resolution.
    private func loadImageData(
        from results: [PHPickerResult]
    ) async -> [Data] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, result) in results.enumerated() {
                group.addTask {
                    let provider = result.itemProvider
                    guard provider.hasItemConformingToTypeIdentifier(
                        UTType.image.identifier
                    ) else { return (index, nil) }

                    let data = try? await provider.loadDataRepresentation(
                        for: .image
                    )
                    return (index, data)
                    // If `loadDataRepresentation(for:)`'s async overload is
                    // unavailable on this SDK, wrap the completion-handler
                    // form in `withCheckedContinuation` instead — do NOT
                    // switch to `loadObject(ofClass: UIImage.self)`, which
                    // decodes the image at full resolution and defeats the
                    // downsampling this whole feature depends on.
                }
            }

            var loaded: [(Int, Data)] = []
            for await (index, data) in group {
                if let data { loaded.append((index, data)) }
            }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
```

- [ ] **Step 3: Handle the picker's result**

Add this extension at the end of the file, after the existing type's closing brace:

```swift
extension PasteViewController: PHPickerViewControllerDelegate {

    public func picker(_ picker: PHPickerViewController,
                       didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard !results.isEmpty else { return }   // cancelled

        spinner.startAnimating()
        statusLabel.text = "Loading \(results.count) "
            + (results.count == 1 ? "photo…" : "photos…")

        Task { [weak self] in
            guard let self else { return }
            let data = await self.loadImageData(from: results)

            await MainActor.run {
                self.spinner.stopAnimating()

                let drafts = PhotoDraftLoader.drafts(from: data)
                guard !drafts.isEmpty else {
                    self.statusLabel.text = "Couldn't read those photos."
                    return
                }
                self.presentReview(for: drafts)
            }
        }
    }
}
```

- [ ] **Step 4: Verify it builds and nothing regressed**

Run the extension build command. Expected: `** BUILD SUCCEEDED **`.
Run the test command. Expected: **143 tests, 0 failures** (this task adds none).

- [ ] **Step 5: Commit**

```bash
git add DiscordStickers/StickerKit/PasteViewController.swift
git commit -m "feat: add photo library import to the extension"
```

---

### Task 4: Device verification — the picker gate

**The whole feature rests on one unverified assumption: that `PHPickerViewController` presents and returns results from inside a Messages extension.** It is out-of-process and generally available to extensions, but this project has already had `UIPasteControl` render permanently disabled and `NWPathMonitor` report asynchronously in exactly this context. Run this before treating the feature as done.

**Files:**
- Create: `docs/superpowers/plans/task-4-photo-import-device-checklist.md`

- [ ] **Step 1: Install and open the picker**

Run the `DiscordStickersMessages` scheme on the device with Messages as host. Open the drawer, expand it, tap **Add Photos**.

**THE GATE: the photo picker must appear.** If nothing happens, `PHPickerViewController` cannot present from inside a Messages extension, and photo import moves to the paid-account tier alongside the share extension. Record that outcome and stop — the rest of this checklist is moot.

Note that the picker may show a limited-library prompt on first use; grant access to at least a few photos.

- [ ] **Step 2: Import one photo**

Pick a single photo. Expect the review screen with the name pre-filled as `photo 1`. Rename it and tap **Add**.

Confirm it appears in the grid, sends by tapping, and is findable by the name you typed.

- [ ] **Step 3: Import several at once**

Pick four or five photos. Expect four or five review rows, named `photo 1` through `photo 5`, **in the order you selected them**. Rename at least two differently and add.

- [ ] **Step 4: The memory check — a large photo**

Pick the largest photo in your library — ideally a full-resolution camera shot, or a screenshot from a Pro Max.

**The extension must not die.** A 12-megapixel photo decodes to roughly 49 MB at full size, against a 40–120 MB kill window; this is the check that proves `ImageDownsampler` is actually preventing that. If the drawer goes blank here, downsampling is not being applied on the photo path.

- [ ] **Step 5: An animated image from Photos**

If you have a GIF saved in Photos, import it. It must arrive **animated**, not as a still frame — `PhotoDraftLoader` detects animation from the bytes, so this is the check that the detection works on real Photos data rather than only on test fixtures.

- [ ] **Step 6: Cancel does nothing**

Tap **Add Photos**, then dismiss the picker without choosing anything. Nothing is added and the status text does not get stuck mid-sentence.

Then pick a photo, reach the review screen, and tap **Cancel** there. Again nothing is added.

- [ ] **Step 7: Dedupe**

Import the **same photo twice**. The second must report already-saved, not add a duplicate — that is content-addressing working on real photo bytes.

- [ ] **Step 8: Record results and commit**

Write `docs/superpowers/plans/task-4-photo-import-device-checklist.md` with one line per step, and note explicitly whether the picker presented at all.

```bash
git add docs/superpowers/plans/task-4-photo-import-device-checklist.md
git commit -m "docs: record photo import device verification"
```

---

## Deferred

- **Background removal** on imported photos, using `VNGenerateForegroundInstanceMaskRequest`. It wants the host app rather than the extension — Vision loads an ML model, and the extension's memory ceiling is this project's top documented risk — so it is blocked on the paid account.
- **Cropping or rotation.** iOS's own editor is one tap away in Photos.
- **Live Photos** as animated stickers. `PHPickerConfiguration.filter` is `.images`, which excludes them.
- **A `Photos` source tab.** The `source` field is recorded from day one, so adding one needs no migration.
