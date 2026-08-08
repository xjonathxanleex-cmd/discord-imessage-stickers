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
