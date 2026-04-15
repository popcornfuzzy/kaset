import Foundation

// MARK: - Album

/// Represents an album from YouTube Music.
struct Album: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artists: [Artist]?
    let thumbnailURL: URL?
    let year: String?
    let trackCount: Int?

    /// Display string for artists (comma-separated).
    var artistsDisplay: String {
        self.artists?.map(\.name).joined(separator: ", ") ?? ""
    }

    /// Whether the album has a valid browse ID for navigation.
    /// YouTube Music album IDs start with "MPRE" (e.g., "MPREb_...").
    /// UUIDs (fallback IDs) contain hyphens and are not navigable.
    var hasNavigableId: Bool {
        // Valid YouTube Music IDs start with specific prefixes and don't contain hyphens
        !self.id.contains("-") && (self.id.hasPrefix("MPRE") || self.id.hasPrefix("OLAK"))
    }
}

extension Album {
    /// Creates an Album from YouTube Music API response data.
    init?(from data: [String: Any]) {
        // Album ID can come from different fields
        guard let albumId = data["browseId"] as? String ?? data["id"] as? String ?? data["albumId"] as? String else {
            // For inline album references (e.g., in song data), create a minimal album
            if let name = data["name"] as? String {
                self.id = UUID().uuidString
                self.title = name
                self.artists = nil
                self.thumbnailURL = nil
                self.year = nil
                self.trackCount = nil
                return
            }
            return nil
        }

        self.id = albumId
        self.title = (data["title"] as? String) ?? (data["name"] as? String) ?? "Unknown Album"

        // Parse artists
        if let artistsData = data["artists"] as? [[String: Any]] {
            self.artists = artistsData.compactMap { Artist(from: $0) }
        } else {
            self.artists = nil
        }

        // Parse thumbnail
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }

        self.year = data["year"] as? String

        // Parse track count
        if let count = data["trackCount"] as? Int {
            self.trackCount = count
        } else {
            self.trackCount = nil
        }
    }

    /// Best-effort author used when an album is represented as a playlist destination.
    /// Prefers a navigable artist so playlist detail headers can link to artist pages.
    var preferredPlaylistAuthor: Artist? {
        if let navigableArtist = self.artists?.first(where: \.hasNavigableId) {
            return navigableArtist
        }

        if let firstArtist = self.artists?.first {
            let name = firstArtist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return Artist.inline(name: name, namespace: "album-artist")
            }
        }

        let display = self.artistsDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty {
            return Artist.inline(name: display, namespace: "album-artist")
        }

        return nil
    }
}
