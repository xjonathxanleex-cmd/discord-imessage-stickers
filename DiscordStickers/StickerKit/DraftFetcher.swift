import Foundation

public enum DraftFetchError: Equatable, Error {
    case unreachable
    case tooLarge
    case notAnImage
}

/// Fetches one image URL into a draft, with hard bounds.
///
/// Arbitrary URLs mean arbitrary responses, so both the size and the
/// deadline are capped before anything reaches the image decoder. The
/// extension is killed between 40 and 120 MB, which a single careless URL
/// could reach on its own.
public final class DraftFetcher: Sendable {

    /// Ten megabytes, inclusive. Far above any real sticker and far below
    /// anything that threatens the extension.
    public static let maxDownloadBytes = 10_000_000

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ link: ParsedLink) async -> Result<StickerDraft, DraftFetchError> {
        var request = URLRequest(url: link.url)
        request.timeoutInterval = 15

        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(for: request)
        } catch {
            return .failure(.unreachable)
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return .failure(.unreachable) }

        // Check the advertised length first — a well-behaved server lets us
        // refuse before transferring anything at all.
        if http.expectedContentLength > 0,
           http.expectedContentLength > Int64(Self.maxDownloadBytes) {
            return .failure(.tooLarge)
        }

        // Then enforce it against reality, since Content-Length is a claim.
        // Streaming and checking as bytes arrive is what keeps a 300 MB
        // response from ever being fully resident — the whole body is never
        // buffered before the cap is checked.
        var data = Data()
        data.reserveCapacity(min(Int(max(http.expectedContentLength, 0)),
                                 Self.maxDownloadBytes))
        do {
            for try await byte in stream {
                data.append(byte)
                if data.count > Self.maxDownloadBytes {
                    return .failure(.tooLarge)
                }
            }
        } catch {
            return .failure(.unreachable)
        }

        // Dimensions decide from metadata alone, before anything is decoded.
        // A byte cap does not bound a bitmap: flat artwork at 8000x6000
        // compresses under 10 MB and decodes to ~192 MB, past the window
        // where the extension is killed. The bytes decide, not the
        // Content-Type header — plenty of servers label images wrongly, and
        // a wrong label should not lose a sticker.
        guard let dimensions = ImageDownsampler.pixelSize(of: data) else {
            return .failure(.notAnImage)
        }
        guard dimensions.width <= StickerLimits.maxSourcePixelDimension,
              dimensions.height <= StickerLimits.maxSourcePixelDimension
        else {
            return .failure(.tooLarge)
        }

        // Animated drafts are left untouched — AnimatedStickerProcessor
        // already streams one frame at a time, and the dimension check above
        // bounds a single frame. Static drafts are downsampled here, at
        // decode time, so the full-resolution bitmap this byte cap was
        // supposed to bound is never actually materialized downstream.
        let imageData: Data
        if !link.isAnimated,
           max(dimensions.width, dimensions.height) > StickerLimits.maxDimension,
           let downsampled = ImageDownsampler.downsampled(data, maxPixel: StickerLimits.maxDimension) {
            imageData = downsampled
        } else {
            imageData = data
        }

        return .success(StickerDraft(
            name: link.suggestedName,
            imageData: imageData,
            origin: .link,
            isAnimated: link.isAnimated
        ))
    }
}
