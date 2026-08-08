import XCTest
import UIKit
@testable import StickerKit

final class TransferPayloadIntegrationTests: XCTestCase {

    private var temp: TempDirectory!
    private var store: StickerStore!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        store = try StickerStore(root: temp.url, writeDebounce: 0)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        store = nil
        temp = nil
    }

    private func pngData(width: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: width)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    func testAPayloadBecomesStickersFromTheRightServices() async throws {
        let payload = """
        DSTK1
        d 1481800758532903104 67
        7 01G3WEGZN0000ET2J0MQP5YJ0G GAMBA
        """

        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let parsed = TransferPayloadParser.parse(payload)
        XCTAssertEqual(parsed.count, 2)

        let downloader = EmojiDownloader(
            store: store, session: StubURLProtocol.makeSession()
        )
        let outcome = await downloader.download(parsed)

        XCTAssertEqual(outcome.added.count, 2)

        let bySource = Dictionary(
            uniqueKeysWithValues: store.all().map { ($0.source, $0) }
        )
        XCTAssertEqual(bySource[.pasted]?.name, "67")
        XCTAssertEqual(bySource[.sevenTV]?.name, "GAMBA")

        let hosts = Set(StubURLProtocol.requestedURLs.compactMap(\.host))
        XCTAssertEqual(hosts, ["cdn.discordapp.com", "cdn.7tv.app"])
    }

    func testAPayloadSurvivesBackupAndRestore() async throws {
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        let downloader = EmojiDownloader(
            store: store, session: StubURLProtocol.makeSession()
        )
        _ = await downloader.download(TransferPayloadParser.parse("""
        DSTK1
        d 1481800758532903104 67
        7 01G3WEGZN0000ET2J0MQP5YJ0G GAMBA
        """))

        let backup = ManifestTransfer.export(from: store)

        // A fresh device: new store, same backup text.
        let secondTemp = try TempDirectory()
        let secondStore = try StickerStore(root: secondTemp.url, writeDebounce: 0)
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, self.pngData(width: 128)) }

        _ = await ManifestTransfer.restore(
            ManifestTransfer.parseImport(backup),
            store: secondStore,
            downloader: EmojiDownloader(store: secondStore,
                                        session: StubURLProtocol.makeSession())
        )

        XCTAssertEqual(secondStore.all().count, 2)
        XCTAssertEqual(
            Set(secondStore.all().map(\.source)), [.pasted, .sevenTV]
        )
        XCTAssertEqual(
            Set(StubURLProtocol.requestedURLs.compactMap(\.host)),
            ["cdn.discordapp.com", "cdn.7tv.app"]
        )
    }
}
