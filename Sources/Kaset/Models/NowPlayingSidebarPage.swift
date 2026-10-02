import Foundation

// MARK: - NowPlayingSidebarPage

/// Page the "Now Playing" right sidebar is showing.
///
/// The sidebar is the artwork-first alternative to the classic lyrics/queue panels (see
/// `SettingsManager.nowPlayingSidebarEnabled`). `overview` is the sidebar itself — artwork with
/// animated canvas, a live three-line lyric preview and the next song — and the two cards expand
/// into the full lyrics and full queue experiences.
enum NowPlayingSidebarPage: String, CaseIterable, Hashable, Sendable {
    /// The sidebar itself: artwork, lyric window, next song.
    case overview
    /// The lyric window opened into the full sheet.
    case lyrics
    /// The next-song row opened into the full queue.
    case queue
}
