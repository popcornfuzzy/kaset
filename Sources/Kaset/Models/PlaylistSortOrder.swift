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

    // `6` ("Top voted") is deliberately not modelled. YouTube Music answers `STATUS_SUCCEEDED` to the
    // write but then returns the playlist in its previous order, so the option selected fine and
    // changed nothing — which reads as the sort being broken. `PlaylistParser` drops order values it
    // has no case for, so a header that advertises it simply does not offer it.

    /// Options offered for an ordinary owned playlist when the header does not advertise its own
    /// menu.
    static let standard: [PlaylistSortOrder] = [.manual, .newestFirst, .newestLast]

    /// Label matching YouTube Music's wording.
    var displayName: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .newestFirst: String(localized: "Newest first")
        case .newestLast: String(localized: "Oldest first")
        }
    }

    /// Icon shown next to the option in the sort menu.
    var systemImage: String {
        switch self {
        case .manual: "hand.draw"
        case .newestFirst: "arrow.down"
        case .newestLast: "arrow.up"
        }
    }
}
