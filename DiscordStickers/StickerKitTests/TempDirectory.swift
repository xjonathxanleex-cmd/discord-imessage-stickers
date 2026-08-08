import Foundation
import UIKit

/// A throwaway directory that deletes itself when the test's reference drops.
final class TempDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a valid PNG of the given square size and returns its URL.
    /// Used as the "downloaded temp file" a store `add` moves into place.
    func makePNG(named name: String, size: Int = 128) throws -> URL {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size)
        )
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        let fileURL = url.appendingPathComponent(name)
        try image.pngData()!.write(to: fileURL)
        return fileURL
    }
}
