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
