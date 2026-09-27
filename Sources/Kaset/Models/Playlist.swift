import Foundation

// MARK: - Playlist

/// Represents a playlist from YouTube Music.
struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let description: String?
    let thumbnailURL: URL?
    let trackCount: Int?
    let author: String?

    /// Whether this is an album (vs a playlist).
    /// Albums have IDs starting with "OLAK" or "MPRE".
    var isAlbum: Bool {
        self.id.hasPrefix("OLAK") || self.id.hasPrefix("MPRE")
    }

    /// Display string for track count.
    var trackCountDisplay: String {
        guard let count = trackCount else { return "" }
        return count == 1 ? "1 song" : "\(count) songs"
    }
}

extension Playlist {
    /// Creates a Playlist from YouTube Music API response data.
    init?(from data: [String: Any]) {
        guard let playlistId = data["playlistId"] as? String ?? data["browseId"] as? String else {
            return nil
        }

        self.id = playlistId
        self.title = (data["title"] as? String) ?? "Unknown Playlist"
        self.description = data["description"] as? String

        // Parse thumbnail
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }

        // Parse track count
        if let count = data["trackCount"] as? Int {
            self.trackCount = count
        } else if let countString = data["trackCount"] as? String,
                  let count = Int(countString.replacingOccurrences(of: ",", with: ""))
        {
            self.trackCount = count
        } else {
            self.trackCount = nil
        }

        // Parse author
        if let authors = data["authors"] as? [[String: Any]],
           let firstAuthor = authors.first
        {
            self.author = firstAuthor["name"] as? String
        } else {
            self.author = data["author"] as? String
        }
    }
}

// MARK: - PlaylistDetail

/// Detailed playlist information including tracks.
struct PlaylistDetail: Identifiable {
    let id: String
    let title: String
    let description: String?
    let thumbnailURL: URL?
    let author: String?
    let trackCount: Int?
    let tracks: [Song]
    let duration: String?
    /// Artists credited on the album, or the playlist's creators. Carries channel IDs when the
    /// response exposed them, which is what makes the names navigable to artist pages.
    let artists: [Artist]
    /// The server's stored track ordering. `nil` when the playlist is not owned by the signed-in
    /// user, or the header did not expose a sort menu.
    let sortOrder: PlaylistSortOrder?
    /// Sort options the header advertised, in menu order. Empty when the playlist is not sortable.
    let availableSortOrders: [PlaylistSortOrder]
    /// Whether the signed-in user can edit this playlist — and therefore reorder it.
    let isEditable: Bool

    /// Whether this is an album (vs a playlist).
    /// Albums have IDs starting with "OLAK" or "MPRE".
    var isAlbum: Bool {
        self.id.hasPrefix("OLAK") || self.id.hasPrefix("MPRE")
    }

    /// Whether this is the Liked Music auto-playlist. Its browse response does not carry the
    /// editable header a normal playlist has, but the account can still sort it.
    var isLikedMusic: Bool {
        let normalized = self.id.hasPrefix("VL") ? String(self.id.dropFirst(2)) : self.id
        return normalized == "LM"
    }

    /// Sort options to offer. Prefers the header's own menu and falls back to the standard set for
    /// Liked Music, which is sortable even though its header does not advertise a menu.
    var sortOptions: [PlaylistSortOrder] {
        if !self.availableSortOrders.isEmpty {
            return self.availableSortOrders
        }
        return self.isLikedMusic ? PlaylistSortOrder.standard : []
    }

    /// Whether the track list can be sorted in place.
    ///
    /// Albums cannot, and the server only accepts a reorder for a playlist the signed-in user can
    /// edit — the same `musicEditablePlaylistDetailHeaderRenderer` marker that gates every other
    /// playlist write. A menu advertised for a playlist we do not own is therefore not actionable,
    /// and offering it produced an `HTTP 400` when the write was sent. Liked Music is the exception:
    /// the account can reorder it although its header carries no editable marker.
    var isSortable: Bool {
        !self.isAlbum && !self.sortOptions.isEmpty && (self.isEditable || self.isLikedMusic)
    }

    /// The option to mark as selected. Falls back to Manual — the documented server default — when
    /// the header did not name its current order.
    var effectiveSortOrder: PlaylistSortOrder {
        self.sortOrder ?? .manual
    }

    init(
        playlist: Playlist,
        tracks: [Song],
        duration: String? = nil,
        artists: [Artist] = [],
        sortOrder: PlaylistSortOrder? = nil,
        availableSortOrders: [PlaylistSortOrder] = [],
        isEditable: Bool = false
    ) {
        self.id = playlist.id
        self.title = playlist.title
        self.description = playlist.description
        self.thumbnailURL = playlist.thumbnailURL
        self.author = playlist.author
        self.trackCount = playlist.trackCount
        self.tracks = tracks
        self.duration = duration
        self.artists = artists
        self.sortOrder = sortOrder
        self.availableSortOrders = availableSortOrders
        self.isEditable = isEditable
    }

    /// Track count to show in the UI, preferring the API-reported total over the loaded row count.
    var resolvedTrackCount: Int {
        self.trackCount ?? self.tracks.count
    }

    /// Display string for the resolved track count.
    var trackCountDisplay: String {
        let count = self.resolvedTrackCount
        return count == 1 ? "1 song" : "\(count.formatted()) songs"
    }
}

// MARK: - LikedSongsResponse

/// Response from the liked songs API, including pagination support.
struct LikedSongsResponse {
    /// The liked songs returned in this response.
    let songs: [Song]

    /// Continuation token for fetching more songs, if available.
    let continuationToken: String?

    /// Whether more songs are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}

// MARK: - PlaylistTracksResponse

/// Response from the playlist tracks API, including pagination support.
struct PlaylistTracksResponse {
    /// The playlist detail with header info and initial tracks.
    let detail: PlaylistDetail

    /// Continuation token for fetching more tracks, if available.
    let continuationToken: String?

    /// Whether more tracks are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}

// MARK: - PlaylistContinuationResponse

/// Response from a playlist continuation request.
struct PlaylistContinuationResponse {
    /// The additional tracks from this continuation.
    let tracks: [Song]

    /// Continuation token for fetching more tracks, if available.
    let continuationToken: String?

    /// Whether more tracks are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}

// MARK: - Playlist Management

/// Privacy options supported by YouTube Music playlist creation/editing.
enum PlaylistPrivacy: String, CaseIterable, Codable, Sendable {
    case `private` = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"

    var displayName: String {
        switch self {
        case .private:
            String(localized: "Private")
        case .unlisted:
            String(localized: "Unlisted")
        case .public:
            String(localized: "Public")
        }
    }
}

/// A playlist entry returned by the Add-to-Playlist API for a specific song.
struct AddToPlaylistEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let thumbnailURL: URL?
    let canAddVideo: Bool
    let canRemoveVideoById: Bool
    let containsVideo: Bool
}

/// Result metadata from adding a song to a playlist.
struct PlaylistVideoAddResult: Sendable {
    let setVideoId: String?
    let status: String?
}
