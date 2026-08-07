import Foundation

/// One Discord custom emoji recovered from pasted markup.
public struct ParsedEmoji: Equatable, Hashable {
    public let id: String
    public let name: String
    public let isAnimated: Bool

    public init(id: String, name: String, isAnimated: Bool) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
    }
}
