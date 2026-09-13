import CryptoKit
import Darwin
import Foundation

// MARK: - CanvasCache

/// Caches canvas lookups (memory + disk, TTL-based) so the provider APIs are
/// not hit repeatedly for the same track.
actor CanvasCache {
    static let shared = CanvasCache()

    /// Outcome of a canvas lookup for a track.
    enum LookupResult: Equatable, Sendable {
        case found(CanvasArtwork)
        case notFound

        var artwork: CanvasArtwork? {
            if case let .found(artwork) = self {
                return artwork
            }
            return nil
        }
    }

    private struct StoredEntry: Codable {
        let artwork: CanvasArtwork?
        let expiresAt: Date

        var result: LookupResult {
            self.artwork.map(LookupResult.found) ?? .notFound
        }
    }

    private static let foundTTL: TimeInterval = 60 * 60 * 24 // 24 hours
    private static let notFoundTTL: TimeInterval = 60 * 60 * 6 // 6 hours

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private var memory: [String: StoredEntry] = [:]

    /// - Parameter directory: Override for unit tests; defaults to
    ///   `~/Library/Application Support/Kaset/CanvasCache`.
    init(directory: URL? = nil) {
        self.directoryURL = directory ?? Self.defaultDirectory()
        try? self.fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    /// Returns the cached lookup for a video ID, or nil when nothing is cached.
    func cachedLookup(for videoId: String) -> LookupResult? {
        let key = Self.key(for: videoId)
        if let entry = self.memory[key] {
            if entry.expiresAt > Date() {
                return entry.result
            }
            self.memory.removeValue(forKey: key)
        }

        let url = self.fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(StoredEntry.self, from: data),
              entry.expiresAt > Date()
        else { return nil }

        self.memory[key] = entry
        return entry.result
    }

    /// Stores a lookup result (found or not-found) for a video ID.
    func storeLookup(_ result: LookupResult, for videoId: String) {
        let key = Self.key(for: videoId)
        let ttl: TimeInterval
        switch result {
        case .found: ttl = Self.foundTTL
        case .notFound: ttl = Self.notFoundTTL
        }
        let entry = StoredEntry(artwork: result.artwork, expiresAt: Date().addingTimeInterval(ttl))
        self.memory[key] = entry
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: self.fileURL(for: key), options: .atomic)
        }
    }

    /// Clears all in-memory and on-disk lookup entries.
    func clear() {
        self.memory.removeAll()
        for file in (try? self.fileManager.contentsOfDirectory(atPath: self.directoryURL.path)) ?? [] {
            let url = self.directoryURL.appendingPathComponent(file)
            try? self.fileManager.removeItem(at: url)
        }
    }

    /// Total size of the on-disk lookup cache in bytes.
    func diskCacheSize() -> Int64 {
        Self.directorySize(directoryURL, fileManager: self.fileManager)
    }

    // MARK: - Helpers

    private func fileURL(for key: String) -> URL {
        self.directoryURL.appendingPathComponent(key + ".json")
    }

    private static func key(for videoId: String) -> String {
        "lookup-" + safeFileName(for: videoId)
    }

    /// Sanitizes a video ID for use as a file name.
    static func safeFileName(for videoId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = videoId.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    static func defaultDirectory() -> URL {
        Self.kasetApplicationSupportDirectory.appendingPathComponent("CanvasCache", isDirectory: true)
    }

    /// Real `~/Library/Application Support/Kaset` directory (sandbox-safe).
    private static var kasetApplicationSupportDirectory: URL {
        let home = Self.realHomeDirectory() ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Kaset", isDirectory: true)
    }

    private static func realHomeDirectory() -> URL? {
        guard let passwd = getpwuid(getuid()),
              let home = passwd.pointee.pw_dir
        else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }
}

// MARK: - CanvasVideoFileCache

/// Caches downloaded canvas video files (Tidal MP4s) on disk so repeat plays
/// do not re-download. HLS streams (Apple Music) are streamed directly and are
/// never stored here.
actor CanvasVideoFileCache {
    static let shared = CanvasVideoFileCache()

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private var knownKeys: Set<String>
    private var inFlightDownloads: [String: Task<URL?, Never>] = [:]

    /// - Parameter directory: Override for unit tests; defaults to the app
    ///   Caches directory.
    init(directory: URL? = nil) {
        let cacheDir = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.directoryURL = cacheDir.appendingPathComponent("com.kaset.canvascache", isDirectory: true)
        try? self.fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)

        // Earlier builds stored videos without a file extension. AVFoundation
        // cannot open those files at all, so they can never be played — drop
        // them and let the next lookup re-download them correctly.
        let existing = (try? self.fileManager.contentsOfDirectory(atPath: self.directoryURL.path)) ?? []
        for entry in existing where !entry.contains(".") {
            try? self.fileManager.removeItem(at: self.directoryURL.appendingPathComponent(entry))
        }

        self.knownKeys = Set((try? self.fileManager.contentsOfDirectory(atPath: self.directoryURL.path)) ?? [])
    }

    /// The local file URL for a remote video, if already cached.
    func localFileURL(for remoteURL: URL) -> URL? {
        let key = Self.cacheKey(for: remoteURL)
        guard self.knownKeys.contains(key) else { return nil }
        let url = self.fileURL(for: key)
        guard self.fileManager.fileExists(atPath: url.path) else {
            self.knownKeys.remove(key)
            return nil
        }
        return url
    }

    /// Returns a local file URL for the video, downloading it first when
    /// necessary. Returns nil when the download fails.
    func ensureLocalFile(for remoteURL: URL) async -> URL? {
        if let existing = self.localFileURL(for: remoteURL) {
            return existing
        }

        let urlString = remoteURL.absoluteString
        if let inFlight = self.inFlightDownloads[urlString] {
            return await inFlight.value
        }

        let task = Task<URL?, Never> {
            await self.download(remoteURL)
        }
        self.inFlightDownloads[urlString] = task
        let result = await task.value
        self.inFlightDownloads.removeValue(forKey: urlString)
        return result
    }

    private func download(_ remoteURL: URL) async -> URL? {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 30
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let key = Self.cacheKey(for: remoteURL)
            let destination = self.fileURL(for: key)
            try? self.fileManager.removeItem(at: destination)
            try self.fileManager.moveItem(at: temporaryURL, to: destination)
            self.knownKeys.insert(key)
            return destination
        } catch {
            DiagnosticsLogger.api.error("Canvas video download failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Clears all cached video files.
    func clear() {
        self.inFlightDownloads.values.forEach { $0.cancel() }
        self.inFlightDownloads.removeAll()
        self.knownKeys.removeAll()
        try? self.fileManager.removeItem(at: self.directoryURL)
        try? self.fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    /// Total size of the cached video files in bytes.
    func diskCacheSize() -> Int64 {
        CanvasCache.directorySize(directoryURL, fileManager: self.fileManager)
    }

    // MARK: - Helpers

    private func fileURL(for key: String) -> URL {
        self.directoryURL.appendingPathComponent(key)
    }

    /// SHA-256 of the remote URL plus a file extension.
    ///
    /// AVFoundation refuses to open a local media file that has no recognizable
    /// extension (it fails with "Cannot Open" when building the asset), so the
    /// cached file must keep one. Direct-download files are always MP4
    /// containers, which is the fallback when the source URL has no extension.
    static func cacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: data)
        let digest = hash.compactMap { String(format: "%02x", $0) }.joined()
        let sanitizedExtension = url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        return sanitizedExtension.isEmpty ? "\(digest).mp4" : "\(digest).\(sanitizedExtension)"
    }
}

// MARK: - Shared directory sizing

extension CanvasCache {
    /// Sums the file sizes under a directory (non-recursive for cache flat layouts).
    static func directorySize(_ directory: URL, fileManager: FileManager = .default) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(fileSize)
            }
        }
        return total
    }
}
