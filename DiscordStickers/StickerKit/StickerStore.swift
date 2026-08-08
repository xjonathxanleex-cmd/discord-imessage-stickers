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
/// to `entries` and `pendingWrite` *after initialization* goes through
/// `queue`, which is serial. (`init` assigns `entries` directly, bypassing
/// `queue` — that is safe only because `self` has not yet escaped the
/// initializer, so no concurrent access is possible at that point.) The
/// compiler cannot see this invariant, but it is the class's central design
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

    // Hardcodes ".png" as the storage name for every sticker, animated or
    // not. This is NOT a format claim: `MSSticker` resolves conformance by
    // sniffing content, not from the path extension — see StickerFormatTests
    // — so animated stickers hold GIF bytes under a .png name quite happily.
    // Keeping one extension is what let the APNG-to-GIF switch ship without
    // migrating files already on users' phones.
    // Previously this comment asserted the opposite; it was wrong. Cross-refs:
    // the path extension, so GIF bytes stored here would fail construction.
    // APNG output legitimately keeps this extension, which is why animated
    // output stays PNG-family for now. If animated output ever switches to
    // GIF, this must change together with the temp file name in
    // `StickerCommitter.commit` and the `pathExtension == "png"` filter in
    // `rebuildFromImages` below.
    public func fileURL(for id: String) -> URL {
        imagesDirectory.appendingPathComponent("\(id).png")
    }

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
        queue.sync {
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

    /// Overwrites a stored entry's non-identity fields from a backup.
    ///
    /// `restore` re-downloads through `EmojiDownloader`, which necessarily
    /// creates a fresh entry — so every field that is not part of a
    /// `ParsedEmoji` is lost unless it is written back. Four separate fields
    /// have been lost this way one at a time; copying the whole record is
    /// what stops a fifth.
    public func restoreMetadata(from backup: StickerEntry) {
        queue.sync {
            guard let index = entries.firstIndex(where: { $0.id == backup.id })
            else { return }
            entries[index].useCount = backup.useCount
            entries[index].favoritedAt = backup.favoritedAt
            entries[index].addedAt = backup.addedAt
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
        guard let data = try? Data(contentsOf: url) else {
            // No manifest (missing or unreadable): there is nothing to
            // quarantine, but there may still be salvageable images on disk
            // from an earlier launch that never got to write one out.
            return rebuildFromImages(in: imagesDirectory)
        }

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

        return rebuildFromImages(in: imagesDirectory)
    }

    /// Reconstructs entries from whatever `.png` files are present, with no
    /// manifest to consult. Names are unrecoverable, so the file's ID stands
    /// in as its name; search is degraded until the user re-pastes. Favorites
    /// are unrecoverable too — this rebuild uses the initializer that
    /// defaults `favoritedAt` to nil, so any favorite is silently lost along
    /// with everything else this recovery path cannot restore. Shared by
    /// both the missing-manifest and corrupt-manifest recovery paths so they
    /// cannot drift apart.
    private static func rebuildFromImages(in imagesDirectory: URL) -> [StickerEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: imagesDirectory, includingPropertiesForKeys: nil
        )) ?? []

        // Hardcodes ".png": `MSSticker` resolves conformance (PNG/GIF/JPEG)
        // from the path extension, so GIF bytes would be skipped here. APNG
        // output legitimately keeps this extension, which is why animated
        // output stays PNG-family for now. If animated output ever switches
        // to GIF, this must change together with the temp file name in
        // `StickerCommitter.commit` and `fileURL(for:)` above.
        return files
            .filter { $0.pathExtension == "png" }
            .map { file in
                let id = file.deletingPathExtension().lastPathComponent
                return StickerEntry(id: id, name: id, source: .pasted,
                                    addedAt: Date(), useCount: 0)
            }
    }
}
