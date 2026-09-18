import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Thread-safe image cache with memory and disk caching.
actor ImageCache {
    static let shared = ImageCache()

    /// Maximum concurrent network fetches during prefetching.
    private static let maxConcurrentPrefetch = 4

    /// Maximum disk cache size in bytes (200MB).
    private static let maxDiskCacheSize: Int64 = 200 * 1024 * 1024

    /// Maximum number of remembered unavailable URLs (see ``unavailableURLs``).
    private static let maxRememberedUnavailableURLs = 512

    /// Disk cache folder name. Versioned because the caching contract changed: older versions stored
    /// the body of YouTube's HTTP 404 as artwork (see ``isSuccessfulImageResponse(_:)``), and those
    /// poisoned entries would be served from disk before any network request was made.
    private static let diskCacheDirectoryName = "com.kaset.imagecache.v2"

    /// `NSCache` is thread-safe, and the synchronous ``cachedImage(for:)`` accessor needs to reach it
    /// off the actor, so it is held as `nonisolated(unsafe)` on purpose.
    nonisolated(unsafe) private let memoryCache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    /// Artwork URLs that answered with a permanent failure (for example a thumbnail size YouTube does
    /// not have for this video). Remembered so the candidate chain does not re-request them on every
    /// render; transient failures are deliberately not remembered.
    private var unavailableURLs: Set<URL> = []
    private let fileManager = FileManager.default
    private let session: URLSession
    private let diskCacheURL: URL

    /// - Parameters:
    ///   - session: Session used to download images. Injectable so tests can serve canned responses.
    ///   - diskCacheDirectoryName: Disk cache folder. Injectable so tests do not touch the real cache.
    ///   - monitorsMemoryPressure: Whether to install the memory-pressure observer. Only the shared
    ///     cache needs it — a test instance must not replace the shared observer.
    init(
        session: URLSession = .shared,
        diskCacheDirectoryName: String = ImageCache.diskCacheDirectoryName,
        monitorsMemoryPressure: Bool = true
    ) {
        self.memoryCache.countLimit = 200
        self.memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
        self.session = session

        // Set up disk cache directory
        let cacheDir = self.fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskCacheURL = cacheDir.appendingPathComponent(diskCacheDirectoryName, isDirectory: true)
        try? self.fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)

        // Set up memory pressure monitoring
        if monitorsMemoryPressure {
            Self.setupMemoryPressureMonitoring(cache: self)
        }

        // Evict disk cache if needed on startup.
        // Perform file system I/O off the main actor.
        Task(priority: .utility) {
            await self.evictDiskCacheIfNeeded()
        }
    }

    /// Sets up monitoring for system memory pressure notifications.
    private static func setupMemoryPressureMonitoring(cache: ImageCache) {
        // Use DispatchSource for memory pressure monitoring
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            Task {
                await cache.clearMemoryCache()
            }
        }
        source.resume()
        // Store the source to prevent deallocation
        Self.memoryPressureSource = source
    }

    // swiftformat:disable modifierOrder
    /// Dispatch source for memory pressure monitoring.
    nonisolated(unsafe) private static var memoryPressureSource: DispatchSourceMemoryPressure?
    // swiftformat:enable modifierOrder

    /// Fetches an image from cache or network.
    /// - Parameters:
    ///   - url: The URL of the image to fetch.
    ///   - targetSize: Optional target size for downsampling. If provided, the image will be
    ///                 downsampled to fit this size, significantly reducing memory usage.
    func image(for url: URL, targetSize: CGSize? = nil) async -> NSImage? {
        // Check memory cache. A decode made for a smaller slot is treated as a miss: returning it would
        // make the biggest artwork surface in the app (the fullscreen card) render from the same 80px
        // decode a 40pt list row asked for, which is exactly how "the high quality version" goes missing.
        // The disk copy holds the original bytes, so the re-decode costs no network request.
        if let cached = memoryCache.object(forKey: url as NSURL),
           Self.isSufficientResolution(cached, for: targetSize)
        {
            return cached
        }

        // Check disk cache
        if let diskImage = loadFromDisk(url: url, targetSize: targetSize) {
            self.memoryCache.setObject(diskImage, forKey: url as NSURL)
            return diskImage
        }

        // Skip artwork this process already learned is unavailable.
        if self.unavailableURLs.contains(url) {
            return nil
        }

        // Check if already fetching
        if let existing = inFlight[url] {
            return await existing.value
        }

        // Fetch from network
        let task = Task<NSImage?, Never> {
            do {
                let (data, response) = try await self.session.data(from: url)
                guard Self.isSuccessfulImageResponse(response) else {
                    if let statusCode = (response as? HTTPURLResponse)?.statusCode {
                        self.rememberUnavailableIfPermanent(url: url, statusCode: statusCode)
                        // Host and path only: the query carries the URL signature, which stays private.
                        DiagnosticsLogger.ui.error(
                            "Artwork request rejected with HTTP \(statusCode, privacy: .public) for \(url.host() ?? "unknown", privacy: .public)\(url.path(), privacy: .public)"
                        )
                    }
                    return nil
                }
                guard let image = Self.createImage(from: data, targetSize: targetSize) else { return nil }
                let cost = targetSize != nil ? Int(image.size.width * image.size.height * 4) : data.count
                self.memoryCache.setObject(image, forKey: url as NSURL, cost: cost)
                self.saveToDisk(url: url, data: data)
                return image
            } catch {
                return nil
            }
        }

        self.inFlight[url] = task
        let result = await task.value
        self.inFlight.removeValue(forKey: url)
        return result
    }

    /// Returns artwork for `url` if it is already in the memory cache, without awaiting the actor.
    ///
    /// Artwork views are created and destroyed constantly (every fullscreen open/close, every screen
    /// switch), and each new view started from its placeholder while it "reloaded" a picture the app
    /// already had in memory — the now-playing art blinked on every transition. Seeding a view's first
    /// frame synchronously avoids that.
    nonisolated func cachedImage(for url: URL) -> NSImage? {
        self.memoryCache.object(forKey: url as NSURL)
    }

    /// Whether a cached decode is at least as large as the caller asked for.
    ///
    /// The memory cache is keyed by URL alone (see ``cachedImage(for:)``), so the entry can have been
    /// downsampled for a much smaller slot than the caller renders into. ``createImage(from:targetSize:)``
    /// caps a decode at twice the requested size for Retina, so a caller may accept anything at least as
    /// large as its own target.
    static func isSufficientResolution(_ image: NSImage, for targetSize: CGSize?) -> Bool {
        guard let targetSize else { return true }
        let required = max(targetSize.width, targetSize.height)
        guard required > 0 else { return true }
        return max(image.size.width, image.size.height) >= required
    }

    /// Whether a response may be treated as artwork.
    ///
    /// `URLSession`'s `data(from:)` hands back the body of HTTP error statuses too, and YouTube answers
    /// a thumbnail size it does not have for a video with **HTTP 404 whose body is still a valid
    /// 120x90 JPEG** (the same placeholder for every video). Decoding that body presented the
    /// placeholder as the album art — the artwork looked like it had vanished — and because the bogus
    /// image was written to the disk cache it survived relaunches instead of recovering. Non-HTTP
    /// responses (for example `file:` URLs) carry no status and are accepted.
    static func isSuccessfulImageResponse(_ response: URLResponse) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else { return true }
        return (200 ..< 300).contains(httpResponse.statusCode)
    }

    /// Remembers a URL as unavailable when the failure cannot resolve itself on retry.
    private func rememberUnavailableIfPermanent(url: URL, statusCode: Int) {
        // Only "this variant does not exist" is permanent: retrying those would re-request a URL that
        // YouTube will keep answering with 404 on every artwork view creation. 401/403 can be a rotated
        // signature or rate limiting, and 408/429/5xx are transient by definition, so they stay
        // retryable — a stale artwork URL must be able to recover inside the same session.
        guard statusCode == 404 || statusCode == 410 else { return }
        if self.unavailableURLs.count >= Self.maxRememberedUnavailableURLs {
            self.unavailableURLs.removeAll()
        }
        self.unavailableURLs.insert(url)
    }

    /// Prefetches images with controlled concurrency to avoid network congestion.
    /// Supports cooperative cancellation from SwiftUI's structured concurrency.
    /// - Parameters:
    ///   - urls: URLs to prefetch.
    ///   - targetSize: Optional target size for downsampling.
    ///   - maxConcurrent: Maximum number of concurrent fetches (default: 4).
    func prefetch(urls: [URL], targetSize: CGSize? = nil, maxConcurrent: Int = maxConcurrentPrefetch) async {
        // Use structured concurrency directly - cancellation propagates automatically
        // when SwiftUI's .task is cancelled (view disappears or id changes)
        await withTaskGroup(of: Void.self) { group in
            var inProgress = 0
            for url in urls {
                // Check cancellation before starting new work
                guard !Task.isCancelled else { break }

                // Skip if already in memory cache
                if self.memoryCache.object(forKey: url as NSURL) != nil {
                    continue
                }

                // Wait for a slot if we're at capacity
                if inProgress >= maxConcurrent {
                    await group.next()
                    inProgress -= 1
                }

                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return }
                    _ = await self.image(for: url, targetSize: targetSize)
                }
                inProgress += 1
            }
            // Wait for remaining tasks (will be cancelled if parent is cancelled)
            await group.waitForAll()
        }
    }

    // MARK: - Image Creation with Downsampling

    /// Creates an NSImage from data, optionally downsampling for memory efficiency.
    private static func createImage(from data: Data, targetSize: CGSize?) -> NSImage? {
        guard let targetSize else {
            return NSImage(data: data)
        }

        // Use ImageIO for memory-efficient downsampling
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]

        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return NSImage(data: data)
        }

        let maxDimension = max(targetSize.width, targetSize.height) * 2 // Account for Retina
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, downsampleOptions as CFDictionary
        )
        else {
            return NSImage(data: data)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Clears the memory cache.
    func clearMemoryCache() {
        self.memoryCache.removeAllObjects()
        self.inFlight.removeAll()
    }

    /// Clears both memory and disk caches.
    func clearAllCaches() {
        self.clearMemoryCache()
        self.unavailableURLs.removeAll()
        try? self.fileManager.removeItem(at: self.diskCacheURL)
        try? self.fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
    }

    /// Returns the total size of the disk cache in bytes.
    func diskCacheSize() -> Int64 {
        var totalSize: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: diskCacheURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }

    // MARK: - Disk Cache Helpers

    private func cacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func diskCachePath(for url: URL) -> URL {
        self.diskCacheURL.appendingPathComponent(self.cacheKey(for: url))
    }

    private func loadFromDisk(url: URL, targetSize: CGSize? = nil) -> NSImage? {
        let path = self.diskCachePath(for: url)
        guard let data = try? Data(contentsOf: path) else {
            return nil
        }
        return Self.createImage(from: data, targetSize: targetSize)
    }

    private func saveToDisk(url: URL, data: Data) {
        let path = self.diskCachePath(for: url)
        try? data.write(to: path, options: .atomic)

        // Evict old files if disk cache exceeds limit.
        // Perform file system I/O off the main actor.
        Task(priority: .utility) {
            await self.evictDiskCacheIfNeeded()
        }
    }

    // MARK: - Disk Cache Eviction

    /// Metadata for a cached file used during eviction.
    private struct CachedFileInfo {
        let url: URL
        let modificationDate: Date
        let fileSize: Int
    }

    /// Evicts oldest files until disk cache is under the size limit.
    /// Uses LRU (Least Recently Used) eviction based on file modification dates.
    /// Marked async to document the I/O-bound nature and satisfy actor isolation.
    private func evictDiskCacheIfNeeded() async {
        let currentSize = self.diskCacheSize()
        guard currentSize > Self.maxDiskCacheSize else { return }

        // Get all cached files sorted by modification date (oldest first)
        guard let files = try? fileManager.contentsOfDirectory(
            at: diskCacheURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sortedFiles = files.compactMap { url -> CachedFileInfo? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate,
                  let size = values.fileSize
            else { return nil }
            return CachedFileInfo(url: url, modificationDate: date, fileSize: size)
        }.sorted { $0.modificationDate < $1.modificationDate } // Sort by date ascending (oldest first)

        var sizeToFree = currentSize - Self.maxDiskCacheSize
        for fileInfo in sortedFiles where sizeToFree > 0 {
            try? self.fileManager.removeItem(at: fileInfo.url)
            sizeToFree -= Int64(fileInfo.fileSize)
        }
    }
}
