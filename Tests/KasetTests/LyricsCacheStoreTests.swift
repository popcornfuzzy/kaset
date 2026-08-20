import Foundation
import Testing

@testable import Kaset

// MARK: - LyricsCacheStoreTests

@Suite(.tags(.service))
struct LyricsCacheStoreTests {
    @Test("save writes one file per song and load round-trips")
    func saveAndLoadRoundTrip() throws {
        let dir = try Self.makeTempDirectory()
        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("legacy.json"))
        let videoId = "video-roundtrip"
        let result = LyricResult.plain(Lyrics(text: "Line one\nLine two", source: "Test Source"))

        #expect(store.save(result, for: videoId))
        #expect(store.load(for: videoId) == result)
        #expect(Self.jsonFiles(in: dir).count == 1)
    }

    @Test("two songs are stored as two separate files")
    func storesSeparateFilesPerSong() throws {
        let dir = try Self.makeTempDirectory()
        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("legacy.json"))
        let first = LyricResult.plain(Lyrics(text: "First", source: nil))
        let second = LyricResult.synced(
            SyncedLyrics(lines: [SyncedLyricLine(timeInMs: 0, duration: 1000, text: "Second", words: nil)], source: "LRCLib")
        )

        store.save(first, for: "video-one")
        store.save(second, for: "video-two")

        let files = Self.jsonFiles(in: dir)
        #expect(files.count == 2)
        #expect(store.load(for: "video-one") == first)
        #expect(store.load(for: "video-two") == second)
    }

    @Test("unavailable results are persisted and reloaded")
    func unavailableResultRoundTrips() throws {
        let dir = try Self.makeTempDirectory()
        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("legacy.json"))

        store.save(.unavailable, for: "video-missing")
        #expect(store.load(for: "video-missing") == .unavailable)
    }

    @Test("remove deletes only the requested song file")
    func removeDeletesSingleFile() throws {
        let dir = try Self.makeTempDirectory()
        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("legacy.json"))
        store.save(.plain(Lyrics(text: "A", source: nil)), for: "video-a")
        store.save(.plain(Lyrics(text: "B", source: nil)), for: "video-b")

        store.remove(for: "video-a")

        #expect(store.load(for: "video-a") == nil)
        #expect(store.load(for: "video-b") != nil)
    }

    @Test("removeAll except keeps the current song file")
    func removeAllExceptKeepsCurrent() throws {
        let dir = try Self.makeTempDirectory()
        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("legacy.json"))
        store.save(.plain(Lyrics(text: "Keep", source: nil)), for: "video-keep")
        store.save(.plain(Lyrics(text: "Drop", source: nil)), for: "video-drop")

        store.removeAll(except: "video-keep")

        #expect(store.load(for: "video-keep") != nil)
        #expect(store.load(for: "video-drop") == nil)
    }

    @Test("migration splits legacy single-file cache into per-song files")
    func migrationSplitsLegacyFile() throws {
        let dir = try Self.makeTempDirectory()
        let legacyURL = dir.appendingPathComponent("lyrics-cache.json")
        let store = LyricsCacheStore(directory: dir.appendingPathComponent("LyricsCache"), legacyFileURL: legacyURL)

        let plain = Lyrics(text: "Plain text", source: "Source A")
        let synced = SyncedLyrics(
            lines: [SyncedLyricLine(timeInMs: 0, duration: 5000, text: "Timed", words: nil)],
            source: "Source B"
        )
        let legacy = LegacyFileDTO(
            version: 1,
            entries: [
                "video-plain": LegacyEntryDTO(type: "plain", synced: nil, plain: plain),
                "video-synced": LegacyEntryDTO(type: "synced", synced: synced, plain: nil),
                "video-missing": LegacyEntryDTO(type: "unavailable", synced: nil, plain: nil),
            ]
        )
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let migrated = store.migrateLegacyCacheIfNeeded()

        #expect(migrated == 3)
        #expect(store.load(for: "video-plain") == .plain(plain))
        #expect(store.load(for: "video-synced") == .synced(synced))
        #expect(store.load(for: "video-missing") == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("migration leaves legacy file intact when parsing fails")
    func migrationLeavesInvalidLegacyFileIntact() throws {
        let dir = try Self.makeTempDirectory()
        let legacyURL = dir.appendingPathComponent("lyrics-cache.json")
        let store = LyricsCacheStore(directory: dir.appendingPathComponent("LyricsCache"), legacyFileURL: legacyURL)

        try Data("not json".utf8).write(to: legacyURL)

        let migrated = store.migrateLegacyCacheIfNeeded()

        #expect(migrated == 0)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(Self.jsonFiles(in: dir.appendingPathComponent("LyricsCache")).isEmpty)
    }

    @Test("migration leaves legacy file intact when an entry has an unknown type")
    func migrationLeavesLegacyFileIntactOnUnknownType() throws {
        let dir = try Self.makeTempDirectory()
        let legacyURL = dir.appendingPathComponent("lyrics-cache.json")
        let store = LyricsCacheStore(directory: dir.appendingPathComponent("LyricsCache"), legacyFileURL: legacyURL)

        let legacy = LegacyFileDTO(
            version: 1,
            entries: [
                "video-known": LegacyEntryDTO(type: "plain", synced: nil, plain: Lyrics(text: "Known", source: nil)),
                "video-unknown": LegacyEntryDTO(type: "future-type", synced: nil, plain: nil),
            ]
        )
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let migrated = store.migrateLegacyCacheIfNeeded()

        #expect(migrated == 1)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("migration is a no-op without a legacy file")
    func migrationNoOpWithoutLegacyFile() throws {
        let dir = try Self.makeTempDirectory()
        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("missing.json"))

        #expect(store.migrateLegacyCacheIfNeeded() == 0)
    }

    @Test("safeFileName sanitizes path-hostile characters")
    func safeFileNameSanitizes() {
        #expect(LyricsCacheStore.safeFileName(for: "abc-123_XYZ") == "abc-123_XYZ")
        #expect(LyricsCacheStore.safeFileName(for: "../evil") == "___evil")
        #expect(LyricsCacheStore.safeFileName(for: "") == "unknown")
    }

    // MARK: - Helpers

    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsCacheStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func jsonFiles(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "json" }
    }
}

// MARK: - SyncedLyricsServicePersistenceTests

@Suite(.tags(.service))
@MainActor
struct SyncedLyricsServicePersistenceTests {
    @Test("fetchLyrics writes to disk and a new instance reads from disk")
    func fetchLyricsPersistsAcrossInstances() async throws {
        let dir = try FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncedLyricsPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("legacy.json"))
        let synced = SyncedLyrics(
            lines: [SyncedLyricLine(timeInMs: 0, duration: 5000, text: "Persisted line", words: nil)],
            source: "Persisted Source"
        )
        let provider = PersistenceMockProvider(result: .synced(synced))
        let first = SyncedLyricsService(providers: [provider], cacheStore: store)

        await first.fetchLyrics(for: LyricsSearchInfo(
            title: "Song", artist: "Artist", album: nil, duration: nil, videoId: "video-persisted"
        ))

        #expect(first.currentLyrics == .synced(synced))

        // A brand-new service backed by the same directory should find the cache
        // without calling the provider again.
        let secondProvider = PersistenceMockProvider(result: .unavailable)
        let second = SyncedLyricsService(providers: [secondProvider], cacheStore: store)

        await second.fetchLyrics(for: LyricsSearchInfo(
            title: "Song", artist: "Artist", album: nil, duration: nil, videoId: "video-persisted"
        ))

        #expect(second.currentLyrics == .synced(synced))
        #expect(await secondProvider.callCount() == 0)
    }

    @Test("clearCache removes per-song files except the current song")
    func clearCacheRemovesDiskFiles() throws {
        let dir = try FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncedLyricsClearTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("legacy.json"))
        let service = SyncedLyricsService(providers: [], cacheStore: store)

        // The last one loaded becomes the "current" song.
        service.fallbackToPlainLyrics(Lyrics(text: "Old", source: nil), videoId: "video-old")
        service.fallbackToPlainLyrics(Lyrics(text: "Current", source: nil), videoId: "video-current")

        #expect(store.load(for: "video-current") != nil)
        #expect(store.load(for: "video-old") != nil)

        service.clearCache(keepCurrent: true)

        #expect(store.load(for: "video-current") != nil)
        #expect(store.load(for: "video-old") == nil)
    }
}

// MARK: - PersistenceMockProvider

private final class PersistenceMockProvider: LyricsProvider, @unchecked Sendable {
    let name = "PersistenceMockProvider"

    private let result: LyricResult
    private let counter = PersistenceSearchCounter()

    init(result: LyricResult) {
        self.result = result
    }

    func search(info _: LyricsSearchInfo) async -> LyricResult {
        await self.counter.increment()
        return self.result
    }

    func callCount() async -> Int {
        await self.counter.value()
    }
}

private actor PersistenceSearchCounter {
    private var count = 0

    func increment() {
        self.count += 1
    }

    func value() -> Int {
        self.count
    }
}

// MARK: - Legacy file fixtures

private struct LegacyFileDTO: Encodable {
    let version: Int
    let entries: [String: LegacyEntryDTO]
}

private struct LegacyEntryDTO: Encodable {
    let type: String
    let synced: SyncedLyrics?
    let plain: Lyrics?
}
