import Foundation

// MARK: - LyricsPollHandoff

/// Who owns the shared WebView lyrics poll while the lyrics UI changes presenter.
///
/// The high-frequency lyric poll is a single flag inside the shared WebView, but two views consume it:
/// the sidebar lyrics panel and the fullscreen now-playing lyrics. When one of them goes away it must
/// *hand the poll over* instead of stopping it, or the surviving view's karaoke highlight freezes until
/// the next track change.
///
/// Both rules are evaluated while the presentation transition is in flight, which is why they take the
/// flag values directly: `showLyrics` and `showFullscreenNowPlaying` already hold their post-transition
/// values by the time a disappearing view runs its teardown.
enum LyricsPollHandoff {
    /// Whether the sidebar lyrics panel must leave the poll running when it disappears.
    ///
    /// The panel disappears for two reasons: the user closed it, or the fullscreen view took over the
    /// lyrics (opening fullscreen closes the sidebar). Only the second one still needs the poll.
    static func shouldKeepPollingAfterSidebarDisappears(
        isFullscreenPresented: Bool,
        hasSyncedLyrics: Bool
    ) -> Bool {
        isFullscreenPresented && hasSyncedLyrics
    }

    /// Whether the fullscreen view must stop the poll once it is dismissed.
    ///
    /// Exiting fullscreen through the lyrics shortcut opens the sidebar panel in the same update, so the
    /// panel can already be the new consumer by the time this view is torn down.
    static func shouldStopPollingAfterFullscreenDismiss(
        isSidebarLyricsVisible: Bool,
        hasSyncedLyrics: Bool
    ) -> Bool {
        !(isSidebarLyricsVisible && hasSyncedLyrics)
    }

    /// Whether the loaded lyrics are synced *and* belong to the track on screen.
    ///
    /// Lyrics for another track (the panel still shows the previous song while a new one loads) cannot
    /// be highlighted by the poll, so they must not keep it alive.
    static func hasSyncedLyrics(
        lyrics: LyricResult,
        lyricsVideoId: String?,
        trackVideoId: String?
    ) -> Bool {
        guard let trackVideoId, let lyricsVideoId, trackVideoId == lyricsVideoId else { return false }
        if case .synced = lyrics { return true }
        return false
    }
}

extension SyncedLyricsService {
    /// Whether the lyrics currently loaded are synced and belong to `videoId` — the only case where the
    /// high-frequency poll has anything to highlight.
    func hasSyncedLyrics(for videoId: String?) -> Bool {
        LyricsPollHandoff.hasSyncedLyrics(
            lyrics: self.currentLyrics,
            lyricsVideoId: self.currentLyricsVideoId,
            trackVideoId: videoId
        )
    }
}
