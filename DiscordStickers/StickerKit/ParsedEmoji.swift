import Foundation

/// One custom emoji recovered from pasted markup or a transfer payload.
public struct ParsedEmoji: Equatable, Hashable {
    public let id: String
    public let name: String
    public let isAnimated: Bool

    /// Which service hosts this emoji. Defaults to `.pasted` — Discord — so
    /// every existing call site keeps compiling, and so `EmojiMarkupParser`,
    /// which only ever produces Discord emoji, needs no change.
    public let source: StickerSource

    public init(id: String, name: String, isAnimated: Bool,
                source: StickerSource = .pasted) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
        self.source = source
    }
}
