import Foundation
import CryptoKit

/// Content-addressed identity for stickers that arrive without one.
///
/// A Discord emoji carries a snowflake id. A photo or an arbitrary URL does
/// not, and `StickerStore` needs an id that is both unique and stable across
/// re-adds. Hashing the **normalized** bytes gives both, plus two properties
/// worth having on purpose:
///
/// - Re-importing the same image is a no-op, exactly like re-pasting the
///   same Discord emoji. The dedupe users already rely on extends for free.
/// - The same image fetched from two different URLs collapses to one
///   sticker, which is almost always what someone wants.
public enum ContentHash {

    public static func id(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256-\(hex)"
    }
}
