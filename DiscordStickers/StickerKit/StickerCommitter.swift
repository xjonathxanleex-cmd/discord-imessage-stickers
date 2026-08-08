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
