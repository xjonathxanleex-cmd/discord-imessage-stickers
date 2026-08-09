import Foundation

/// Where a sticker came from.
///
/// String-raw-valued and persisted in `manifest.json`, so cases may be
/// **added** freely but never renamed or removed — an unknown raw value
/// fails to decode the whole entry, silently losing a sticker the user
/// already had.
public enum StickerSource: String, Codable, CaseIterable {
    case pasted
    case server
    case photo
    case link
    case sevenTV
}

/// One row of `manifest.json`. Every entry that reaches the manifest has had
/// an `MSSticker` successfully constructed from its file at least once.
public struct StickerEntry: Codable, Equatable {
    public let id: String
    public let name: String
    public let source: StickerSource
    public var addedAt: Date
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

    /// The sticker's filename inside the images directory.
    ///
    /// Exists because **iOS caches sticker assets by file URL**. Files used to
    /// be named `<id>.png`, so deleting a sticker and re-importing it wrote
    /// different bytes to a path the system had already cached — and
    /// `MSStickerView` kept showing the *old* image while sending the message
    /// read the new one off disk. Device-confirmed: three animated emoji sat
    /// frozen in the drawer and animated correctly in the conversation, and a
    /// clean reinstall (a fresh container, so a fresh path) fixed them.
    ///
    /// Every import now gets a name nothing has ever used, so a re-import can
    /// never collide with a cached asset.
    ///
    /// `nil` on entries written before this existed, which still live at
    /// `<id>.png` — see `StickerStore.fileURL(for:)`.
    public var fileName: String?

    public init(id: String, name: String, source: StickerSource,
                addedAt: Date, useCount: Int, favoritedAt: Date? = nil,
                isAnimated: Bool = false, fileName: String? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.addedAt = addedAt
        self.useCount = useCount
        self.favoritedAt = favoritedAt
        self.isAnimated = isAnimated
        self.fileName = fileName
    }

    enum CodingKeys: String, CodingKey {
        case id, name, source, addedAt, useCount, favoritedAt, isAnimated
        case fileName
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
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
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
        try container.encodeIfPresent(fileName, forKey: .fileName)
    }
}
