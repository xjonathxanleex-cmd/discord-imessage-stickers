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
    /// ordering, so the two cannot contradict each other.
    public var favoritedAt: Date?

    /// Whether this sticker's stored file is animated.
    ///
    /// Load-bearing, not metadata. `ManifestTransfer.restore` rebuilds
    /// `ParsedEmoji` values from a decoded backup and re-downloads them, and
    /// the CDN returns **HTTP 415** for a static emoji requested as `.gif`.
    /// Without persisting this, every animated sticker would come back
    /// static — or fail outright — after a restore.
    ///
    /// Non-optional, and `Codable` is hand-written rather than synthesized —
    /// that combination is exactly why the hand-written implementation was
    /// needed. A synthesized decoder treats a non-optional key as required
    /// and would throw on every manifest written before this property
    /// existed. `init(from:)` instead reads it with
    /// `decodeIfPresent(...) ?? false`, so old manifests without the key
    /// decode cleanly with `isAnimated` defaulting to `false`.
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

    enum CodingKeys: String, CodingKey {
        case id, name, source, addedAt, useCount, favoritedAt, isAnimated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(StickerSource.self, forKey: .source)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        useCount = try container.decode(Int.self, forKey: .useCount)
        favoritedAt = try container.decodeIfPresent(Date.self, forKey: .favoritedAt)
        isAnimated = try container.decodeIfPresent(Bool.self, forKey: .isAnimated) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(source, forKey: .source)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(useCount, forKey: .useCount)
        try container.encodeIfPresent(favoritedAt, forKey: .favoritedAt)
        if isAnimated {
            try container.encode(isAnimated, forKey: .isAnimated)
        }
    }
}
