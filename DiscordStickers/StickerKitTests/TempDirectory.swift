import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

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

    /// Builds an animated GIF in memory. Each frame is a different solid
    /// colour so frame-dropping can be observed, not just counted.
    func makeAnimatedGIFData(frameCount: Int = 10,
                             width: Int = 76,
                             height: Int = 61,
                             delay: Double = 0.05) -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            out, UTType.gif.identifier as CFString, frameCount, nil
        )!

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        for index in 0..<frameCount {
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: width, height: height)
            )
            let image = renderer.image { context in
                UIColor(hue: CGFloat(index) / CGFloat(max(frameCount, 1)),
                        saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CGImageDestinationAddImage(destination, image.cgImage!, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay
                ]
            ] as CFDictionary)
        }

        CGImageDestinationFinalize(destination)
        return out as Data
    }
}
