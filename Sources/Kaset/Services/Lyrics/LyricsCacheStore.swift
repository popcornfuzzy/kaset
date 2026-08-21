import Darwin
import Foundation

// MARK: - LyricsCacheStore

/// Persists one lyrics cache file per song.
///
/// Each song is stored as `<videoId>.json` inside the lyrics cache directory
/// (default: `~/Library/Application Support/Kaset/LyricsCache`).
///
/// The store is a `Sendable` value type, so it can safely be used from the main
/// actor for quick reads/writes as well as from detached tasks for background
/// migration work.
struct LyricsCacheStore: Sendable {
    /// Directory that holds one file per cached song.
    let directoryURL: URL

    /// Legacy single-file cache that should be split into per-song files.
    let legacyFileURL: URL?

    private let logger = DiagnosticsLogger.api

    /// - Parameters:
    ///   - directory: Directory for per-song files. Defaults to Application Support/Kaset/LyricsCache.
    ///   - legacyFileURL: Legacy single-file cache path. Defaults to Application Support/Kaset/lyrics-cache.json.
    init(directory: URL? = nil, legacyFileURL: URL? = nil) {
        self.directoryURL = directory ?? Self.defaultDirectory()
        self.legacyFileURL = legacyFileURL ?? Self.defaultLegacyFileURL()

        try? FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - File Access

    /// URL for a single song's cached lyrics file.
    func fileURL(for videoId: String) -> URL {
        self.directoryURL.appendingPathComponent(Self.safeFileName(for: videoId) + ".json")
    }

    /// Loads cached lyrics for a song, if a valid file exists.
    func load(for videoId: String) -> LyricResult? {
        let url = self.fileURL(for: videoId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let result = try JSONDecoder().decode(LyricResult.self, from: data)
            return result
        } catch {
            self.logger.error("Failed to load cached lyrics for \\(videoId): \\(error.localizedDescription)")
            return nil
        }
    }

    /// Writes cached lyrics for a song to its own file.
    @discardableResult
    func save(_ result: LyricResult, for videoId: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: self.fileURL(for: videoId), options: .atomic)
            return true
        } catch {
            self.logger.error("Failed to save cached lyrics for \\(videoId): \\(error.localizedDescription)")
            return false
        }
    }

    /// Removes a single song's cached lyrics file.
    func remove(for videoId: String) {
        let url = self.fileURL(for: videoId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes all cached lyrics files.
    /// - Parameter keepVideoId: If provided, this song's file is left untouched.
    func removeAll(except keepVideoId: String? = nil) {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: self.directoryURL,
            includingPropertiesForKeys: keys
        ) else { return }

        for file in files where file.pathExtension == "json" {
            if let keepVideoId, file.deletingPathExtension().lastPathComponent == Self.safeFileName(for: keepVideoId) {
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Migration

    /// Detects a legacy single-file lyrics cache and splits it into per-song files.
    ///
    /// The legacy file is a versioned JSON envelope whose `entries` dictionary is
    /// keyed by `videoId`. Each entry carries a `type` discriminator plus its
    /// payload (`synced`, `plain`, or nothing for `unavailable`). After every
    /// entry is written to its own file, the legacy file is deleted. If parsing
    /// or writing fails, the legacy file is left intact so migration can be
    /// retried on the next launch.
    ///
    /// - Returns: Number of entries migrated, or 0 when no legacy file exists.
    @discardableResult
    func migrateLegacyCacheIfNeeded() -> Int {
        guard let legacyFileURL, FileManager.default.fileExists(atPath: legacyFileURL.path) else {
            return 0
        }

        do {
            let data = try Data(contentsOf: legacyFileURL)
            let legacy = try JSONDecoder().decode(LegacyLyricsCacheFile.self, from: data)

            var results: [String: LyricResult] = [:]
            var unmapped = 0
            for (videoId, entry) in legacy.entries {
                switch entry.type {
                case "synced":
                    if let synced = entry.synced {
                        results[videoId] = .synced(synced)
                    } else {
                        unmapped += 1
                    }
                case "plain":
                    if let plain = entry.plain {
                        results[videoId] = .plain(plain)
                    } else {
                        unmapped += 1
                    }
                case "unavailable":
                    results[videoId] = .unavailable
                default:
                    unmapped += 1
                }
            }

            var migrated = 0
            for (videoId, result) in results {
                if self.save(result, for: videoId) {
                    migrated += 1
                }
            }

            // Only clean up when every entry mapped and was written successfully.
            guard unmapped == 0, migrated == legacy.entries.count else {
                self.logger.error(
                    "Legacy lyrics cache migration incomplete: wrote \\(migrated) of \\(legacy.entries.count) entries"
                )
                return migrated
            }

            try FileManager.default.removeItem(at: legacyFileURL)
            self.logger.info("Migrated \\(migrated) cached lyrics from legacy single-file cache")
            return migrated
        } catch {
            self.logger.error("Failed to migrate legacy lyrics cache: \\(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Helpers

    /// Sanitizes a video ID for use as a file name.
    static func safeFileName(for videoId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = videoId.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    static func defaultDirectory() -> URL {
        Self.kasetApplicationSupportDirectory.appendingPathComponent("LyricsCache", isDirectory: true)
    }

    static func defaultLegacyFileURL() -> URL {
        Self.kasetApplicationSupportDirectory.appendingPathComponent("lyrics-cache.json")
    }

    /// Real `~/Library/Application Support/Kaset` directory.
    ///
    /// Resolved from the actual home directory (`getpwuid`) rather than
    /// `.applicationSupportDirectory` because a sandboxed app gets redirected to
    /// its container. The app sandbox grants access to this real path via a
    /// home-relative temporary exception in `Kaset.entitlements`.
    private static var kasetApplicationSupportDirectory: URL {
        let home = Self.realHomeDirectory() ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Kaset", isDirectory: true)
    }

    /// Returns the user's real home directory even when running sandboxed
    /// (`FileManager.homeDirectoryForCurrentUser` points at the container).
    private static func realHomeDirectory() -> URL? {
        guard let passwd = getpwuid(getuid()),
              let home = passwd.pointee.pw_dir
        else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }
}

// MARK: - Legacy single-file cache format

/// Versioned envelope used by the old single-file lyrics cache.
///
/// Example:
/// ```json
/// {
///   "version": 1,
///   "entries": {
///     "<videoId>": { "type": "synced", "synced": { "source": "LRCLib", "lines": [...] } },
///     "<videoId>": { "type": "plain", "plain": { "source": "...", "text": "..." } },
///     "<videoId>": { "type": "unavailable" }
///   }
/// }
/// ```
private struct LegacyLyricsCacheFile: Decodable {
    struct Entry: Decodable {
        let type: String
        let synced: SyncedLyrics?
        let plain: Lyrics?
    }

    let version: Int
    let entries: [String: Entry]
}
