import UIKit

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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failure(.unreachable)
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return .failure(.unreachable) }

        guard data.count <= Self.maxDownloadBytes else {
            return .failure(.tooLarge)
        }

        // The bytes decide, not the Content-Type header — plenty of servers
        // label images wrongly, and a wrong label should not lose a sticker.
        guard UIImage(data: data) != nil else {
            return .failure(.notAnImage)
        }

        return .success(StickerDraft(
            sourceURL: link.url,
            name: link.suggestedName,
            imageData: data,
            origin: .link,
            isAnimated: link.isAnimated
        ))
    }
}
