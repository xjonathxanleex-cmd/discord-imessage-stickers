# Favorites & Delete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user curate a stable, hand-picked list of stickers and delete ones they no longer want.

**Architecture:** A single optional `favoritedAt: Date?` on `StickerEntry` carries both membership and ordering. `StickerStore` gains two methods following its existing serial-queue and debounced-write behaviour. The grid gains a `.favorites` filter and an edit mode that disables `MSStickerView` interaction entirely rather than competing for its gestures.

**Tech Stack:** Swift 5 language mode, UIKit, Messages.framework, XCTest. No new dependencies.

**Source spec:** `docs/superpowers/specs/2026-08-07-favorites-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Toolchain:** Xcode 26.6, Swift 6.3.3, iOS 26.5 SDK. **Swift Language Version is 5** on all targets — do not change it.
- **Deployment target iOS 17.0** on all targets.
- **Never** hand-author or hand-edit `project.pbxproj`. The project uses synchronized folder groups, so a `.swift` file created inside `DiscordStickers/StickerKit/` or `DiscordStickers/StickerKitTests/` is added to the right target automatically.
- **Never** create, modify, or delete any `.xcscheme` file. The shared scheme at `DiscordStickers/DiscordStickers.xcodeproj/xcshareddata/xcschemes/StickerKit.xcscheme` is required for the test action.
- **No App Groups entitlement** may appear in any target — it fails to provision on a free Personal Team.
- **No third-party dependencies.**
- **Simulator name is `iPhone 17 Pro`.**
- **Memory:** never hold decoded `UIImage`s or `MSSticker`s in a collection or array. The extension is killed between 40 and 120 MB.
- **`StickerSource` is a `String`-raw-valued `Codable` enum.** Cases may be added but never renamed or removed — an unknown case fails to decode the entire entry.
- **Baseline: 52 tests passing.** This plan takes it to **62**.

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

### Task 1: Add `favoritedAt` to `StickerEntry`

The model change, and the test that protects the stickers already on the user's phone.

**Files:**
- Modify: `DiscordStickers/StickerKit/StickerEntry.swift`
- Test: `DiscordStickers/StickerKitTests/StickerEntryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `StickerEntry` gains `public var favoritedAt: Date?`, and its memberwise init gains a trailing `favoritedAt: Date? = nil` parameter. **The default is required** — without it every existing call site (`EmojiDownloader.commit`, `ManifestTransfer`, and four test files) stops compiling.

- [ ] **Step 1: Write the failing tests**

Append to `DiscordStickers/StickerKitTests/StickerEntryTests.swift`, inside the existing `StickerEntryTests` class:

```swift
    func testFavoritedAtRoundTripsThroughJSON() throws {
        let entry = StickerEntry(
            id: "823847191234",
            name: "blobcatcozy",
            source: .pasted,
            addedAt: Date(timeIntervalSince1970: 1_754_604_840),
            useCount: 12,
            favoritedAt: Date(timeIntervalSince1970: 1_754_608_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(StickerEntry.self, from: data), entry)
    }

    func testDefaultsToNotFavorited() {
        let entry = StickerEntry(id: "1", name: "a", source: .pasted,
                                 addedAt: Date(), useCount: 0)
        XCTAssertNil(entry.favoritedAt)
    }

    func testManifestWrittenBeforeFavoritesStillDecodes() throws {
        // Exactly the shape manifest.json had before this change. This is the
        // test that protects stickers already on the user's device: Swift's
        // synthesized Codable uses decodeIfPresent for optionals, so a missing
        // key must decode as nil rather than throwing.
        let legacyJSON = """
        [{"addedAt":"2026-08-07T22:14:00Z","id":"823847191234",\
        "name":"blobcatcozy","source":"pasted","useCount":12}]
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([StickerEntry].self,
                                         from: Data(legacyJSON.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "823847191234")
        XCTAssertEqual(entries[0].useCount, 12)
        XCTAssertNil(entries[0].favoritedAt)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: FAIL — `extra argument 'favoritedAt' in call` and `value of type 'StickerEntry' has no member 'favoritedAt'`.

- [ ] **Step 3: Add the property**

Replace the body of `DiscordStickers/StickerKit/StickerEntry.swift`'s `StickerEntry` struct:

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
    /// ordering, so the two cannot contradict each other — a separate
    /// `isFavorite: Bool` alongside a date would permit "favorited with no
    /// date" and "dated but not favorited", and every read would have to
    /// decide which wins.
    ///
    /// Being optional also makes this a free migration: synthesized `Codable`
    /// uses `decodeIfPresent` for optionals, so manifests written before this
    /// property existed decode with it nil.
    public var favoritedAt: Date?

    public init(id: String, name: String, source: StickerSource,
                addedAt: Date, useCount: Int, favoritedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.addedAt = addedAt
        self.useCount = useCount
        self.favoritedAt = favoritedAt
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: PASS, **55 tests total** (52 existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add DiscordStickers/StickerKit/StickerEntry.swift \
        DiscordStickers/StickerKitTests/StickerEntryTests.swift
git commit -m "feat: add favoritedAt to StickerEntry with a free Codable migration"
```

---

### Task 2: `StickerStore` favorites API

**Files:**
- Modify: `DiscordStickers/StickerKit/StickerStore.swift`
- Test: `DiscordStickers/StickerKitTests/StickerStoreTests.swift`

**Interfaces:**
- Consumes: `StickerEntry.favoritedAt` (Task 1).
- Produces:
  - `public func favorites() -> [StickerEntry]` — entries with `favoritedAt != nil`, sorted ascending by `favoritedAt`.
  - `public func setFavorite(_ favorite: Bool, id: String)` — favoriting an already-favorited sticker is a no-op that preserves the original timestamp.

- [ ] **Step 1: Extend the test helper**

In `DiscordStickers/StickerKitTests/StickerStoreTests.swift`, replace the existing private `entry` helper with one that can set `favoritedAt`:

```swift
    private func entry(_ id: String, name: String, useCount: Int = 0,
                       addedAt: Date = Date(),
                       favoritedAt: Date? = nil) -> StickerEntry {
        StickerEntry(id: id, name: name, source: .pasted,
                     addedAt: addedAt, useCount: useCount,
                     favoritedAt: favoritedAt)
    }
```

- [ ] **Step 2: Write the failing tests**

Append to the existing `StickerStoreTests` class:

```swift
    func testSetFavoriteMarksAndSurvivesReload() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))

        store.setFavorite(true, id: "111")
        store.flush()

        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.favorites().map(\.id), ["111"])
        XCTAssertNotNil(reloaded.all().first?.favoritedAt)
    }

    func testUnfavoriteClearsAndSurvivesReload() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        store.setFavorite(true, id: "111")
        store.setFavorite(false, id: "111")
        store.flush()

        let reloaded = try makeStore()
        XCTAssertTrue(reloaded.favorites().isEmpty)
        XCTAssertNil(reloaded.all().first?.favoritedAt)
        XCTAssertEqual(reloaded.all().count, 1, "unfavoriting must not delete")
    }

    func testFavoritesAreOrderedOldestFirst() throws {
        let store = try makeStore()
        // Explicit timestamps rather than two setFavorite calls: Date() twice
        // in quick succession can produce equal values, which would make this
        // assertion pass or fail by luck.
        try store.add(entry("second", name: "b",
                            favoritedAt: Date(timeIntervalSince1970: 2000)),
                      movingFileFrom: try temp.makePNG(named: "b.png"))
        try store.add(entry("first", name: "a",
                            favoritedAt: Date(timeIntervalSince1970: 1000)),
                      movingFileFrom: try temp.makePNG(named: "a.png"))

        XCTAssertEqual(store.favorites().map(\.id), ["first", "second"])
    }

    func testRefavoritingDoesNotMoveTheStickerOrChangeItsTimestamp() throws {
        let store = try makeStore()
        let original = Date(timeIntervalSince1970: 1000)
        try store.add(entry("first", name: "a", favoritedAt: original),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        try store.add(entry("second", name: "b",
                            favoritedAt: Date(timeIntervalSince1970: 2000)),
                      movingFileFrom: try temp.makePNG(named: "b.png"))

        store.setFavorite(true, id: "first")

        XCTAssertEqual(store.favorites().map(\.id), ["first", "second"])
        XCTAssertEqual(store.favorites().first?.favoritedAt, original)
    }

    func testFavoritesIsEmptyWhenNothingIsFavorited() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))

        XCTAssertTrue(store.favorites().isEmpty)
    }

    func testDeletingAFavoriteRemovesItEverywhere() throws {
        let store = try makeStore()
        try store.add(entry("111", name: "wave"),
                      movingFileFrom: try temp.makePNG(named: "a.png"))
        store.setFavorite(true, id: "111")
        let path = store.fileURL(for: "111").path

        try store.delete(id: "111")

        XCTAssertTrue(store.favorites().isEmpty)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFavoritingAnUnknownIDIsIgnored() throws {
        let store = try makeStore()
        store.setFavorite(true, id: "does-not-exist")

        XCTAssertTrue(store.favorites().isEmpty)
        XCTAssertTrue(store.all().isEmpty)
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run the test command. Expected: FAIL — `value of type 'StickerStore' has no member 'setFavorite'`.

- [ ] **Step 4: Implement the two methods**

In `DiscordStickers/StickerKit/StickerStore.swift`, add `favorites()` immediately after the existing `recents(limit:)` method:

```swift
    /// Favorites in the order they were favorited, oldest first, and they
    /// never move. That stability is the feature's justification: `recents()`
    /// reorders continuously by use, so nothing there holds a position.
    public func favorites() -> [StickerEntry] {
        queue.sync {
            entries
                .filter { $0.favoritedAt != nil }
                .sorted {
                    ($0.favoritedAt ?? .distantPast)
                        < ($1.favoritedAt ?? .distantPast)
                }
        }
    }
```

And add `setFavorite` immediately after the existing `recordUse(id:)` method:

```swift
    /// Favoriting something already favorited is a no-op rather than a
    /// re-stamp — overwriting the timestamp would send the sticker to the end
    /// of the list, which is exactly the instability this feature exists to
    /// avoid. Unknown ids are ignored.
    public func setFavorite(_ favorite: Bool, id: String) {
        queue.sync {
            guard let index = entries.firstIndex(where: { $0.id == id })
            else { return }

            if favorite {
                guard entries[index].favoritedAt == nil else { return }
                entries[index].favoritedAt = Date()
            } else {
                guard entries[index].favoritedAt != nil else { return }
                entries[index].favoritedAt = nil
            }
            scheduleWriteLocked()
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run the test command. Expected: PASS, **62 tests total** (55 + 7 new).

- [ ] **Step 6: Commit**

```bash
git add DiscordStickers/StickerKit/StickerStore.swift \
        DiscordStickers/StickerKitTests/StickerStoreTests.swift
git commit -m "feat: add favorites() and setFavorite() to StickerStore"
```

---

### Task 3: `.favorites` filter and empty state

**Files:**
- Modify: `DiscordStickers/StickerKit/StickerGridViewController.swift`

**Interfaces:**
- Consumes: `StickerStore.favorites()` (Task 2).
- Produces: `StickerFilter` gains a `.favorites` case. The grid shows an empty-state label when the favorites filter is active and empty.

This task has no unit tests — it is view code with no logic that can be exercised outside a running view hierarchy. Its verification is a build plus the existing suite staying green.

- [ ] **Step 1: Add the filter case**

In `DiscordStickers/StickerKit/StickerGridViewController.swift`, replace the `StickerFilter` enum:

```swift
public enum StickerFilter: Equatable {
    case favorites
    case recents
    case all
    case search(String)
}
```

- [ ] **Step 2: Add the empty-state label**

Add this stored property immediately after the existing `private var collectionView: UICollectionView!`:

```swift
    private let emptyLabel = UILabel()
```

Then, inside `viewDidLoad`, immediately before the existing `reload()` call at the end, insert:

```swift
        // Wording must not assume the drawer is expanded: Edit is unreachable
        // from compact mode, so "tap Edit" alone would refer to a button the
        // reader cannot see.
        emptyLabel.text = "Expand this drawer, tap Edit, "
            + "then tap the star on any sticker."
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                                constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                 constant: -24),
        ])
```

- [ ] **Step 3: Handle the new case in `reload()`**

Replace the body of the existing `reload()` method:

```swift
    public func reload() {
        switch filter {
        case .favorites: entries = store.favorites()
        case .recents:   entries = store.recents()
        case .all:       entries = store.all()
        case .search(let query): entries = store.search(query)
        }
        emptyLabel.isHidden = !(entries.isEmpty && filter == .favorites)
        collectionView?.reloadData()
    }
```

- [ ] **Step 4: Verify it builds and nothing regressed**

Run the extension build command. Expected: `** BUILD SUCCEEDED **`.
Run the test command. Expected: **62 tests, 0 failures** (this task adds none).

- [ ] **Step 5: Commit**

```bash
git add DiscordStickers/StickerKit/StickerGridViewController.swift
git commit -m "feat: add favorites filter and its empty state to the grid"
```

---

### Task 4: `StickerCell` edit mode

**Files:**
- Modify: `DiscordStickers/StickerKit/StickerCell.swift`

**Interfaces:**
- Consumes: nothing beyond UIKit and Messages.
- Produces: a new `configure` signature. **This replaces the existing two-argument one**, so Task 5 must update the only call site.

```swift
public func configure(with sticker: MSSticker,
                      isFavorite: Bool,
                      isEditing: Bool,
                      onTap: @escaping () -> Void,
                      onToggleFavorite: @escaping () -> Void,
                      onDelete: @escaping () -> Void)
```

- [ ] **Step 1: Replace the file**

Replace the entire contents of `DiscordStickers/StickerKit/StickerCell.swift`:

```swift
import UIKit
import Messages

/// Hosts one `MSStickerView`, which supplies tap-to-send and
/// drag-onto-bubble for free.
///
/// `prepareForReuse` clearing the sticker is load-bearing: a Messages
/// extension is killed somewhere between 40 and 120 MB, and holding decoded
/// images in recycled cells is the fastest way to get there.
///
/// In edit mode the sticker view's interaction is disabled outright rather
/// than competing with it for gestures. `MSStickerView` owns tap and
/// long-press-drag and exposes no callbacks — the tap counter below only
/// works because it recognizes *simultaneously* rather than instead.
/// Contesting those gestures a second time would be fragile in a way only a
/// device could reveal, so edit mode takes `MSStickerView` out of the
/// conversation entirely.
public final class StickerCell: UICollectionViewCell {

    public static let reuseIdentifier = "StickerCell"

    private let stickerView = MSStickerView()
    private let starButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    private var onTap: (() -> Void)?
    private var onToggleFavorite: (() -> Void)?
    private var onDelete: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)

        stickerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stickerView)

        for button in [starButton, deleteButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isHidden = true
            contentView.addSubview(button)
        }

        starButton.tintColor = .systemYellow
        starButton.addTarget(self, action: #selector(handleStar),
                             for: .touchUpInside)

        deleteButton.setImage(
            UIImage(systemName: "xmark.circle.fill"), for: .normal
        )
        deleteButton.tintColor = .systemRed
        deleteButton.addTarget(self, action: #selector(handleDelete),
                               for: .touchUpInside)

        NSLayoutConstraint.activate([
            stickerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stickerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stickerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stickerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            starButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            starButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            starButton.widthAnchor.constraint(equalToConstant: 24),
            starButton.heightAnchor.constraint(equalToConstant: 24),

            deleteButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            deleteButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Recognizes alongside MSStickerView's own handling rather than
        // instead of it, so the tap still sends. Counts taps, not confirmed
        // sends — a deliberate approximation, sufficient for ordering Recents.
        let recognizer = UITapGestureRecognizer(
            target: self, action: #selector(handleTap)
        )
        recognizer.delegate = self
        stickerView.addGestureRecognizer(recognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func configure(with sticker: MSSticker,
                          isFavorite: Bool,
                          isEditing: Bool,
                          onTap: @escaping () -> Void,
                          onToggleFavorite: @escaping () -> Void,
                          onDelete: @escaping () -> Void) {
        stickerView.sticker = sticker
        self.onTap = onTap
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete

        stickerView.isUserInteractionEnabled = !isEditing
        starButton.isHidden = !isEditing
        deleteButton.isHidden = !isEditing
        starButton.setImage(
            UIImage(systemName: isFavorite ? "star.fill" : "star"),
            for: .normal
        )
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        stickerView.sticker = nil
        stickerView.isUserInteractionEnabled = true
        starButton.isHidden = true
        deleteButton.isHidden = true
        onTap = nil
        onToggleFavorite = nil
        onDelete = nil
    }

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func handleStar() {
        onToggleFavorite?()
    }

    @objc private func handleDelete() {
        onDelete?()
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

- [ ] **Step 2: Confirm it fails to build, for the right reason**

Run the extension build command. Expected: **FAIL** — `missing arguments for parameters 'isFavorite', 'isEditing'...` at the call site in `StickerGridViewController.swift`. Task 5 fixes that. A failure naming any *other* file means something above is wrong.

- [ ] **Step 3: Commit**

```bash
git add DiscordStickers/StickerKit/StickerCell.swift
git commit -m "feat: add star and delete controls to StickerCell for edit mode"
```

---

### Task 5: Grid edit-mode plumbing

**Files:**
- Modify: `DiscordStickers/StickerKit/StickerGridViewController.swift`

**Interfaces:**
- Consumes: `StickerCell.configure(with:isFavorite:isEditing:onTap:onToggleFavorite:onDelete:)` (Task 4), `StickerStore.setFavorite(_:id:)` and `delete(id:)` (Task 2).
- Produces: `public var isEditingStickers: Bool` on `StickerGridViewController`, defaulting to `false`. Setting it reloads. **Not** named `isEditing` — that collides with `UIViewController`'s own property and does not compile.

- [ ] **Step 1: Add the editing property**

In `DiscordStickers/StickerKit/StickerGridViewController.swift`, add immediately after the existing `filter` property:

```swift
    /// While editing, cells show a star and an ×, and `MSStickerView`
    /// interaction is off — sending and dragging are disabled for the
    /// duration rather than competing with the edit controls for gestures.
    ///
    /// Named `isEditingStickers`, not `isEditing`: `UIViewController` already
    /// declares a settable `isEditing` tied to its `editButtonItem` and
    /// `setEditing(_:animated:)` machinery, none of which this app uses. A
    /// plain `var isEditing` therefore fails to compile, and overriding it
    /// would let UIKit flip this app's edit mode through a path nobody here
    /// is watching.
    public var isEditingStickers: Bool = false {
        didSet {
            if isEditingStickers != oldValue { collectionView?.reloadData() }
        }
    }
```

- [ ] **Step 2: Update the cell call site**

Replace the body of the existing `collectionView(_:cellForItemAt:)` method:

```swift
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
            cell.configure(
                with: sticker,
                isFavorite: entry.favoritedAt != nil,
                isEditing: isEditingStickers,
                onTap: { [weak self] in
                    self?.store.recordUse(id: entry.id)
                },
                onToggleFavorite: { [weak self] in
                    guard let self else { return }
                    self.store.setFavorite(entry.favoritedAt == nil, id: entry.id)
                    self.reload()
                },
                onDelete: { [weak self] in
                    guard let self else { return }
                    try? self.store.delete(id: entry.id)
                    self.reload()
                }
            )
        }
        return cell
    }
```

- [ ] **Step 3: Verify it builds and nothing regressed**

Run the extension build command. Expected: `** BUILD SUCCEEDED **`.
Run the test command. Expected: **62 tests, 0 failures**.

- [ ] **Step 4: Commit**

```bash
git add DiscordStickers/StickerKit/StickerGridViewController.swift
git commit -m "feat: wire favorite and delete actions through the grid"
```

---

### Task 6: Three tabs and the Edit button

**Files:**
- Modify: `DiscordStickers/DiscordStickersMessages/MessagesViewController.swift`

**Interfaces:**
- Consumes: `StickerFilter.favorites` (Task 3), `StickerGridViewController.isEditing` (Task 5), `StickerStore.favorites()` (Task 2).
- Produces: the finished feature. Nothing consumes this.

- [ ] **Step 1: Replace the tabs control and add the Edit button**

In `DiscordStickers/DiscordStickersMessages/MessagesViewController.swift`, replace the existing `tabs` declaration:

```swift
    private let tabs = UISegmentedControl(items: ["Favorites", "Recent", "All"])
    private let editButton = UIButton(type: .system)
    private let searchRow = UIStackView()
```

- [ ] **Step 2: Add a single source of truth for tab → filter**

Add these two methods immediately before the existing `@objc private func tabChanged()`:

```swift
    /// One place that maps segment index to filter. Three call sites used to
    /// each carry their own copy of this ternary; a fourth tab would have
    /// meant finding all of them.
    private func filterForSelectedTab() -> StickerFilter {
        switch tabs.selectedSegmentIndex {
        case 0:  return .favorites
        case 1:  return .recents
        default: return .all
        }
    }

    private func setEditing(_ editing: Bool) {
        grid?.isEditingStickers = editing
        editButton.setTitle(editing ? "Done" : "Edit", for: .normal)
    }
```

- [ ] **Step 3: Build the search row and wire the Edit button**

In `buildUI()`, replace the block that configures `searchBar` and adds it to `topControls`. The existing code configures `searchBar` then calls `topControls.addArrangedSubview(searchBar)`; the search bar must now sit in a horizontal row beside the Edit button.

Immediately after the existing `searchBar` configuration lines, and **replacing** the line `topControls.addArrangedSubview(searchBar)`, insert:

```swift
        editButton.setTitle("Edit", for: .normal)
        editButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        editButton.setContentHuggingPriority(.required, for: .horizontal)
        editButton.addTarget(self, action: #selector(editTapped),
                             for: .touchUpInside)

        searchRow.axis = .horizontal
        searchRow.alignment = .center
        searchRow.spacing = 8
        searchRow.addArrangedSubview(searchBar)
        searchRow.addArrangedSubview(editButton)

        topControls.addArrangedSubview(searchRow)
```

Then change the single line in `applyPresentationStyle` that reads `searchBar.isHidden = !expanded` to hide the row instead:

```swift
        searchRow.isHidden = !expanded
```

- [ ] **Step 4: Add the Edit action and exit editing on collapse**

Add this method immediately after `tabChanged()`:

```swift
    @objc private func editTapped() {
        guard grid != nil else { return }
        setEditing(!grid.isEditingStickers)
    }
```

Then in `applyPresentationStyle`, inside the existing `if !expanded { ... }` block, add as its first line:

```swift
            // Never leave the drawer in a state where taps do not send.
            setEditing(false)
```

- [ ] **Step 5: Use the shared filter mapping everywhere**

Replace all three existing occurrences of the ternary `tabs.selectedSegmentIndex == 0 ? .recents : .all` with `filterForSelectedTab()`. They appear in `applyPresentationStyle`, `tabChanged()`, and `searchBar(_:textDidChange:)`.

In `searchBar(_:textDidChange:)` the replacement reads:

```swift
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        grid.filter = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? filterForSelectedTab()
            : .search(searchText)
    }
```

- [ ] **Step 6: Default to Favorites when it has contents**

In `buildUI()`, replace the existing line `tabs.selectedSegmentIndex = 1` with:

```swift
        // Favorites when there is something in it, otherwise All — so a
        // first-run user sees exactly what they saw before this feature.
        tabs.selectedSegmentIndex = store.favorites().isEmpty ? 2 : 0
```

- [ ] **Step 7: Verify it builds and nothing regressed**

Run the extension build command. Expected: `** BUILD SUCCEEDED **`.
Run the test command. Expected: **62 tests, 0 failures**.

- [ ] **Step 8: Commit**

```bash
git add DiscordStickers/DiscordStickersMessages/MessagesViewController.swift
git commit -m "feat: add Favorites tab and Edit button to the Messages extension"
```

---

### Task 7: Device verification

Everything here is behaviour the simulator cannot settle — gesture ownership, cell reuse under real scrolling, and whether disabling `MSStickerView` interaction genuinely stops sending. This project has already had two bugs that only a device revealed.

**Files:**
- Create: `docs/superpowers/plans/task-7-favorites-device-checklist.md`

**Interfaces:**
- Consumes: the built app.
- Produces: a recorded pass/fail per item.

- [ ] **Step 1: Install on the device**

Connect the iPhone, select the `DiscordStickersMessages` scheme and the device as destination, Run, and pick Messages as the host app. If Xcode reports "Could not attach to pid", dismiss it — an extension only launches when tapped, so the install still succeeded.

- [ ] **Step 2: Verify the default tab on a fresh install**

With no favorites yet, open the drawer. The selected tab must be **All**, and the grid must show stickers exactly as before this feature.

- [ ] **Step 3: Verify the empty state**

Tap the **Favorites** tab. Expect the line *"Expand this drawer, tap Edit, then tap the star on any sticker."* — not a blank grid.

- [ ] **Step 4: Favorite something**

Expand the drawer, tap **Edit** (title changes to **Done**), tap the star on two stickers. Both stars fill. Tap **Done**.

Switch to **Favorites**. Both stickers appear, in the order you starred them.

- [ ] **Step 5: The critical check — editing must not send**

Expand, tap **Edit**, then tap a sticker's *image* (not its star or ×).

**Nothing must be inserted into the conversation.** If a sticker sends, `stickerView.isUserInteractionEnabled = false` is not taking effect and the feature is unsafe to ship — report it rather than continuing.

Also try dragging a sticker while editing: it must not peel.

- [ ] **Step 6: Verify reuse does not corrupt star state**

With several favorites and many non-favorites, enter Edit on the **All** tab and scroll a favorited sticker off screen and back several times. Its star must still be filled, and no unfavorited sticker may show a filled star. This is the check that catches a `prepareForReuse` gap.

- [ ] **Step 7: Verify ordering stability**

In **Favorites**, note the order. Tap **Edit**, unstar then re-star the *first* sticker, tap **Done**. It should now be **last** — unfavoriting genuinely cleared it, so re-favoriting appends. Then re-star an *already-starred* sticker without unstarring: nothing should move.

- [ ] **Step 8: Delete**

Tap **Edit**, tap the × on a sticker. It disappears immediately from the grid. Switch to **All** and confirm it is gone there too. Collapse and reopen the drawer to confirm it stays gone.

Then, on the **Favorites** tab, delete favorites until none remain. The tab must stay selected and show the empty-state line rather than switching away or going blank.

- [ ] **Step 9: Verify edit mode exits on collapse**

Enter Edit, then drag the drawer closed and reopen it. The drawer must be back in normal mode, and tapping a sticker must send.

- [ ] **Step 10: Record results and commit**

Write `docs/superpowers/plans/task-7-favorites-device-checklist.md` with one line per step: pass/fail plus any observation.

```bash
git add docs/superpowers/plans/task-7-favorites-device-checklist.md
git commit -m "docs: record Favorites device verification results"
```

---

## Deferred

Listed so nothing is lost. All are from the spec's §10.

- **Manual drag-to-reorder** within Favorites. Append-order is a strict subset, so this is additive later rather than a rewrite.
- **A favorites cap.** None is imposed; a user who favorites hundreds gets a second `All` tab, which is their choice.
- **Bulk edit** — select several, act once.
- **Undo.** Deletion removes one sticker that a re-paste restores in seconds.
- **Renaming from edit mode.** Natural home once the import-sources work lands, since that introduces user-supplied names.
