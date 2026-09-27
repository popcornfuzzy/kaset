import Foundation

// MARK: - PlaylistSortOrder

/// Server-side track ordering for a playlist.
///
/// YouTube Music stores this per playlist: the browse response returns the tracks already in the
/// stored order, and the same order is shown on every device and client. Raw values are the
/// integers the API expects in `ACTION_SET_PLAYLIST_VIDEO_ORDER.playlistVideoOrder`.
enum PlaylistSortOrder: Int, CaseIterable, Codable, Sendable, Hashable {
    /// The order the owner arranged by hand (YouTube Music's default).
    case manual = 0

    /// Most recently added first.
    case newestFirst = 1

    /// Most recently added last — YouTube Music labels this "Oldest first".
    case newestLast = 2

    /// Most upvoted first. Only offered on playlists with community voting enabled.
    case topVoted = 6

    /// Options offered for an ordinary owned playlist when the header does not advertise its own
    /// menu. `topVoted` is left out because it only applies to voted playlists.
    static let standard: [PlaylistSortOrder] = [.manual, .newestFirst, .newestLast]

    /// Label matching YouTube Music's wording.
    var displayName: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .newestFirst: String(localized: "Newest first")
        case .newestLast: String(localized: "Oldest first")
        case .topVoted: String(localized: "Top voted")
        }
    }

    /// Icon shown next to the option in the sort menu.
    var systemImage: String {
        switch self {
        case .manual: "hand.draw"
        case .newestFirst: "arrow.down"
        case .newestLast: "arrow.up"
        case .topVoted: "hand.thumbsup"
        }
    }
}
