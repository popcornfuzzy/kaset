import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Kaset

/// Regression coverage for artwork downloads.
///
/// YouTube answers a thumbnail size it does not have for a video with **HTTP 404 whose body is still a
/// valid JPEG** (a 120x90 placeholder, byte-identical for every video). `URLSession`'s `data(from:)`
/// does not throw for HTTP error statuses, so decoding the body presented that placeholder as the
/// album art — the artwork looked like it had vanished — and the disk cache then kept serving it.
@Suite(.serialized, .tags(.service))
@MainActor
struct ImageCacheTests {
    private static let testCacheDirectoryName = "com.kaset.imagecache.tests"

    @Test("An error response body is not treated as artwork")
    func rejectsErrorStatusBody() async {
        defer { Self.cleanup() }
        Self.mockJPEGResponse(statusCode: 404)

        let cache = Self.makeCache()
        let image = await cache.image(for: Self.uniqueURL(prefix: "missing-size"))

        #expect(image == nil, "a 404 body must not be rendered as the album art")
    }

    @Test("A successful response is decoded and cached")
    func acceptsSuccessfulResponse() async {
        defer { Self.cleanup() }
        Self.mockJPEGResponse(statusCode: 200)

        let cache = Self.makeCache()
        let url = Self.uniqueURL(prefix: "artwork")
        #expect(cache.cachedImage(for: url) == nil, "nothing is cached before the first load")

        let image = await cache.image(for: url)
        #expect(image != nil)

        // The synchronous accessor sees it, so a newly created artwork view can paint it on its first
        // frame instead of flashing its placeholder while it reloads the same picture.
        #expect(cache.cachedImage(for: url) != nil)

        // Served from the cache on the next ask, without another request.
        MockURLProtocol.requestHandler = nil
        let cachedImage = await cache.image(for: url)
        #expect(cachedImage != nil)
    }

    @Test("A rejected signature stays retryable")
    func doesNotRememberForbiddenResponses() async {
        defer { Self.cleanup() }
        let requests = RequestCounter()
        Self.mockJPEGResponse(statusCode: 403, counter: requests)

        let cache = Self.makeCache()
        let url = Self.uniqueURL(prefix: "forbidden")
        _ = await cache.image(for: url)
        _ = await cache.image(for: url)

        // 403 can be a rotated signature or rate limiting: a stale artwork URL has to be able to
        // recover within the same session instead of being written off until the next launch.
        #expect(requests.count == 2)
    }

    @Test("A permanent failure is remembered so the artwork chain does not re-request it")
    func remembersPermanentFailures() async {
        defer { Self.cleanup() }
        let requests = RequestCounter()
        Self.mockJPEGResponse(statusCode: 404, counter: requests)

        let cache = Self.makeCache()
        let url = Self.uniqueURL(prefix: "permanent")
        _ = await cache.image(for: url)
        _ = await cache.image(for: url)

        #expect(requests.count == 1, "a thumbnail size YouTube does not have should only be requested once")
    }

    @Test("A transient failure stays retryable")
    func doesNotRememberTransientFailures() async {
        defer { Self.cleanup() }
        let requests = RequestCounter()
        MockURLProtocol.requestHandler = { request in
            requests.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html>service unavailable</html>".utf8))
        }

        let cache = Self.makeCache()
        let url = Self.uniqueURL(prefix: "transient")
        _ = await cache.image(for: url)
        _ = await cache.image(for: url)

        #expect(requests.count == 2, "a 5xx must be retried, not remembered as missing")
    }

    @Test("A decode made for a smaller slot is not reused as a larger one")
    func redecodesForLargerTargets() async {
        defer { Self.cleanup() }
        let requests = RequestCounter()
        // A 200x200 still. A decode is capped at twice the requested target, so the small request yields an
        // 80px image while a larger one can still reach the source's 200px.
        Self.mockJPEGResponse(statusCode: 200, counter: requests, pixelSize: 200)

        let cache = Self.makeCache()
        let url = Self.uniqueURL(prefix: "resolution")

        let small = await cache.image(for: url, targetSize: CGSize(width: 40, height: 40))
        #expect(small?.size.width == 80)

        // The fullscreen artwork card asks for a far larger decode of the same URL. Serving the row's
        // 80px decode is exactly how the high quality still goes missing from the biggest surface.
        let large = await cache.image(for: url, targetSize: CGSize(width: 380, height: 380))
        #expect(large?.size.width == 200)

        // Re-decoded from the cached original bytes, not downloaded again.
        #expect(requests.count == 1)
    }

    @Test("A cached decode only counts for targets it is large enough for")
    func validatesCachedResolution() {
        let fullSize = NSImage(size: NSSize(width: 544, height: 544))
        #expect(ImageCache.isSufficientResolution(fullSize, for: CGSize(width: 380, height: 380)))
        #expect(ImageCache.isSufficientResolution(fullSize, for: CGSize(width: 760, height: 760)) == false)

        let rowSize = NSImage(size: NSSize(width: 80, height: 80))
        #expect(ImageCache.isSufficientResolution(rowSize, for: CGSize(width: 40, height: 40)))
        #expect(ImageCache.isSufficientResolution(rowSize, for: CGSize(width: 380, height: 380)) == false)

        // No target means no requirement.
        #expect(ImageCache.isSufficientResolution(rowSize, for: nil))
    }

    @Test("Only 2xx responses count as artwork")
    func validatesStatusCodes() throws {
        #expect(ImageCache.isSuccessfulImageResponse(try Self.httpResponse(statusCode: 200)))
        #expect(ImageCache.isSuccessfulImageResponse(try Self.httpResponse(statusCode: 206)))
        #expect(ImageCache.isSuccessfulImageResponse(try Self.httpResponse(statusCode: 403)) == false)
        #expect(ImageCache.isSuccessfulImageResponse(try Self.httpResponse(statusCode: 404)) == false)
        #expect(ImageCache.isSuccessfulImageResponse(try Self.httpResponse(statusCode: 503)) == false)

        // Non-HTTP responses (for example `file:` URLs) carry no status and stay usable.
        let fileResponse = URLResponse(
            url: URL(string: "file:///tmp/artwork.jpg")!,
            mimeType: "image/jpeg",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        #expect(ImageCache.isSuccessfulImageResponse(fileResponse))
    }

    // MARK: - Helpers

    private static func makeCache() -> ImageCache {
        ImageCache(
            session: MockURLProtocol.makeMockSession(),
            diskCacheDirectoryName: Self.testCacheDirectoryName,
            monitorsMemoryPressure: false
        )
    }

    private static func mockJPEGResponse(statusCode: Int, counter: RequestCounter? = nil, pixelSize: Int = 4) {
        let jpeg = Self.jpegData(pixelSize: pixelSize)
        MockURLProtocol.requestHandler = { request in
            counter?.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/jpeg"]
            )!
            return (response, jpeg)
        }
    }

    private static func httpResponse(statusCode: Int) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: URL(string: "https://example.com/artwork.jpg")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
    }

    private static func uniqueURL(prefix: String) -> URL {
        URL(string: "https://example.com/\(prefix)-\(UUID().uuidString).jpg")!
    }

    /// JPEG payload standing in for a real thumbnail / YouTube's 404 placeholder body.
    private static func jpegData(pixelSize: Int = 4) -> Data {
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Data()
        }
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }

    private static func cleanup() {
        MockURLProtocol.reset()
        guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(Self.testCacheDirectoryName, isDirectory: true)
        )
    }
}

/// Request counter that can be read from a `@Sendable` mock handler.
private final class RequestCounter: @unchecked Sendable {
    private(set) var count = 0

    func increment() {
        self.count += 1
    }
}
