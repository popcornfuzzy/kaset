import Foundation
import Testing
@testable import Kaset

// MARK: - CanvasServiceTests

@Suite(.serialized, .tags(.service))
@MainActor
struct CanvasServiceTests {
    // MARK: - Lookup orchestration

    @Test("the first valid canvas wins across concurrent providers")
    func firstValidCanvasWins() async {
        let tidalArtwork = Self.makeArtwork(source: "Tidal", name: "tidal-canvas")
        let service = Self.makeService(providers: [
            MockCanvasProvider(name: "Tidal", result: tidalArtwork),
            MockCanvasProvider(name: "Apple Music", result: nil),
        ])

        await service.loadCanvas(for: Self.makeInfo(videoId: "video-first"))

        #expect(service.currentCanvas == tidalArtwork)
        #expect(service.currentCanvasVideoId == "video-first")
        #expect(service.currentCanvasURL == tidalArtwork.videoURL)
        #expect(service.activeProvider == "Tidal")
        #expect(service.isLoadingCanvas == false)
    }

    @Test("cached lookups skip provider searches")
    func cachedLookupSkipsProviders() async {
        let artwork = Self.makeArtwork(source: "Tidal", name: "tidal-canvas")
        let provider = MockCanvasProvider(name: "Tidal", result: artwork)
        let service = Self.makeService(providers: [provider])
        let info = Self.makeInfo(videoId: "video-cache")

        await service.loadCanvas(for: info)
        #expect(await provider.callCount() == 1)
        #expect(service.currentCanvas == artwork)

        await service.loadCanvas(for: info)
        #expect(await provider.callCount() == 1)
        #expect(service.currentCanvas == artwork)
    }

    @Test("not-found results are cached and not refetched")
    func negativeResultsAreCached() async {
        let provider = MockCanvasProvider(name: "Tidal", result: nil)
        let service = Self.makeService(providers: [provider])
        let info = Self.makeInfo(videoId: "video-miss")

        await service.loadCanvas(for: info)
        #expect(service.currentCanvas == nil)
        #expect(service.currentCanvasVideoId == "video-miss")
        #expect(service.isLoadingCanvas == false)
        #expect(await provider.callCount() == 1)

        await service.loadCanvas(for: info)
        #expect(await provider.callCount() == 1)
        #expect(service.currentCanvas == nil)
    }

    @Test("a fast provider's canvas is delivered without waiting for a slow provider")
    func fastProviderWinsWithoutWaitingForSlowProvider() async {
        let slowGate = CanvasSearchGate()
        let slow = MockCanvasProvider(name: "Slow") { _ in
            await slowGate.markStarted()
            await slowGate.waitUntilReleased() // never resolves on its own
            return Self.makeArtwork(name: "slow-canvas")
        }
        let fast = MockCanvasProvider(name: "Fast", result: Self.makeArtwork(name: "fast-canvas"))
        let service = Self.makeService(providers: [slow, fast])

        let task = Task {
            await service.loadCanvas(for: Self.makeInfo(videoId: "video-race"))
        }
        await slowGate.waitUntilStarted()

        // The fast provider's result must be applied even though the slow
        // provider is still blocked (regression: withTaskGroup awaited every
        // child, delaying the winner by the slowest provider's runtime).
        await task.value
        #expect(service.currentCanvas?.name == "fast-canvas")
        #expect(service.currentCanvasVideoId == "video-race")

        await slowGate.release()
    }

    @Test("stale canvas results do not overwrite a newer track")
    func staleResultsDoNotOverwriteNewerTrack() async {
        let staleGate = CanvasSearchGate()
        let staleArtwork = Self.makeArtwork(name: "stale-canvas")
        let provider = MockCanvasProvider(name: "Tidal") { info in
            if info.videoId == "video-stale" {
                await staleGate.markStarted()
                await staleGate.waitUntilReleased()
                return staleArtwork
            }
            return Self.makeArtwork(name: "fresh-canvas")
        }
        let service = Self.makeService(providers: [provider])

        let staleTask = Task {
            await service.loadCanvas(for: Self.makeInfo(videoId: "video-stale"))
        }
        await staleGate.waitUntilStarted()
        await service.loadCanvas(for: Self.makeInfo(videoId: "video-fresh"))

        #expect(service.currentCanvas?.name == "fresh-canvas")
        #expect(service.currentCanvasVideoId == "video-fresh")

        await staleGate.release()
        await staleTask.value

        #expect(service.currentCanvas?.name == "fresh-canvas")
        #expect(service.currentCanvasVideoId == "video-fresh")
    }

    @Test("lookup results persist to disk across service instances")
    func lookupPersistsToDisk() async throws {
        let dir = try FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasServiceDiskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lookupCache = CanvasCache(directory: dir.appendingPathComponent("lookup"))
        let videoCache = CanvasVideoFileCache(directory: dir.appendingPathComponent("video"))
        let info = Self.makeInfo(videoId: "video-disk")

        let artwork = Self.makeArtwork(source: "Tidal", name: "tidal-canvas")
        let first = CanvasService(
            providers: [MockCanvasProvider(name: "Tidal", result: artwork)],
            lookupCache: lookupCache,
            videoFileCache: videoCache
        )
        await first.loadCanvas(for: info)
        #expect(first.currentCanvas == artwork)

        // A fresh service backed by the same disk cache serves the record
        // without calling any provider.
        let secondProvider = MockCanvasProvider(name: "Tidal", result: nil)
        let second = CanvasService(
            providers: [secondProvider],
            lookupCache: lookupCache,
            videoFileCache: videoCache
        )
        await second.loadCanvas(for: info)
        #expect(await secondProvider.callCount() == 0)
        #expect(second.currentCanvas == artwork)
    }

    // MARK: - Cache clearing

    @Test("clearCache resets state and forces a refetch")
    func clearCacheResetsState() async {
        let artwork = Self.makeArtwork(source: "Tidal", name: "tidal-canvas")
        let provider = MockCanvasProvider(name: "Tidal", result: artwork)
        let service = Self.makeService(providers: [provider])
        let info = Self.makeInfo(videoId: "video-clear")

        await service.loadCanvas(for: info)
        #expect(service.currentCanvas == artwork)
        #expect(await provider.callCount() == 1)

        await service.clearCache()

        #expect(service.currentCanvas == nil)
        #expect(service.currentCanvasURL == nil)
        #expect(service.currentCanvasVideoId == nil)
        #expect(service.isLoadingCanvas == false)

        await service.loadCanvas(for: info)
        #expect(await provider.callCount() == 2)
        #expect(service.currentCanvas == artwork)
    }

    // MARK: - Settings gate

    @Test("disabled animated canvas setting short-circuits lookups")
    func disabledSettingShortCircuits() async {
        let previous = SettingsManager.shared.animatedCanvasEnabled
        SettingsManager.shared.animatedCanvasEnabled = false
        defer { SettingsManager.shared.animatedCanvasEnabled = previous }

        let provider = MockCanvasProvider(name: "Tidal", result: Self.makeArtwork())
        let service = Self.makeService(providers: [provider])

        await service.loadCanvas(for: Self.makeInfo(videoId: "video-off"))

        #expect(await provider.callCount() == 0)
        #expect(service.currentCanvas == nil)
        #expect(service.currentCanvasURL == nil)
        #expect(service.currentCanvasVideoId == nil)
    }

    // MARK: - Helpers

    private static func makeService(
        providers: [any CanvasProvider]
    ) -> CanvasService {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // NOTE: temp dirs are intentionally not cleaned up eagerly here; each
        // test uses a unique UUID so leftovers are harmless.
        return CanvasService(
            providers: providers,
            lookupCache: CanvasCache(directory: dir.appendingPathComponent("lookup")),
            videoFileCache: CanvasVideoFileCache(directory: dir.appendingPathComponent("video"))
        )
    }

    private static func makeInfo(videoId: String) -> CanvasSearchInfo {
        CanvasSearchInfo(
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            videoId: videoId
        )
    }

    /// Test artworks use HLS URLs so the service never attempts a download.
    private static func makeArtwork(source: String = "Tidal", name: String = "canvas") -> CanvasArtwork {
        CanvasArtwork(
            name: name,
            artist: "Test Artist",
            videoURL: URL(string: "https://example.com/\(name).m3u8")!,
            source: source,
            albumName: "Test Album"
        )
    }
}

// MARK: - MockCanvasProvider

private final class MockCanvasProvider: CanvasProvider, @unchecked Sendable {
    let name: String

    private let searchHandler: (CanvasSearchInfo) async -> CanvasArtwork?
    private let counter = CanvasCallCounter()

    init(name: String, result: CanvasArtwork?, gate: CanvasSearchGate? = nil) {
        self.name = name
        self.searchHandler = { _ in
            if let gate {
                await gate.markStarted()
                await gate.waitUntilReleased()
            }
            return result
        }
    }

    init(name: String, searchHandler: @escaping (CanvasSearchInfo) async -> CanvasArtwork?) {
        self.name = name
        self.searchHandler = searchHandler
    }

    func fetchCanvas(for info: CanvasSearchInfo) async -> CanvasArtwork? {
        await self.counter.increment()
        return await self.searchHandler(info)
    }

    func callCount() async -> Int {
        await self.counter.value()
    }
}

// MARK: - Helpers

private actor CanvasCallCounter {
    private var count = 0

    func increment() {
        self.count += 1
    }

    func value() -> Int {
        self.count
    }
}

private actor CanvasSearchGate {
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        guard !self.didStart else { return }
        self.didStart = true
        let waiters = self.startWaiters
        self.startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        if self.didStart {
            return
        }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        if self.isReleased {
            return
        }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func release() {
        guard !self.isReleased else { return }
        self.isReleased = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - CanvasVideoFileCacheTests

@Suite(.serialized, .tags(.service))
struct CanvasVideoFileCacheTests {
    /// AVFoundation cannot open an extension-less local media file (it fails
    /// with "Cannot Open"), so the cache key must always carry an extension.
    @Test("cached video files keep a file extension")
    func cachedVideoFilesKeepAnExtension() {
        let mp4 = URL(string: "https://resources.tidal.com/videos/aa/bb/cc/dd/ee/1280x1280.mp4")!
        #expect(CanvasVideoFileCache.cacheKey(for: mp4).hasSuffix(".mp4"))

        let withoutExtension = URL(string: "https://cdn.example.com/video/abc123")!
        #expect(CanvasVideoFileCache.cacheKey(for: withoutExtension).hasSuffix(".mp4"))
    }

    @Test("a cached file is resolved from the key derived from its source URL")
    func cachedFileIsResolved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-canvas-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let remoteURL = URL(string: "https://resources.tidal.com/videos/aa/bb/cc/dd/ee/1280x1280.mp4")!
        let cacheDirectory = directory.appendingPathComponent("com.kaset.canvascache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cachedFile = cacheDirectory.appendingPathComponent(CanvasVideoFileCache.cacheKey(for: remoteURL))
        try Data([0x00]).write(to: cachedFile)

        let cache = CanvasVideoFileCache(directory: directory)
        #expect(await cache.localFileURL(for: remoteURL) == cachedFile)
    }

    @Test("legacy extension-less cache entries are discarded")
    func legacyEntriesAreDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-canvas-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheDirectory = directory.appendingPathComponent("com.kaset.canvascache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let legacyFile = cacheDirectory
            .appendingPathComponent("8bccd4873326ce26fd8107fa1ac2eb5c3351a72fb5a3f05254ad495d87602ebc")
        try Data([0x00]).write(to: legacyFile)

        _ = CanvasVideoFileCache(directory: directory)

        #expect(FileManager.default.fileExists(atPath: legacyFile.path) == false)
    }
}
