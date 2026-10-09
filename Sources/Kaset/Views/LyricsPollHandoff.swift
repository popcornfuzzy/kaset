import Foundation

// MARK: - LyricsPollHandoff

/// Who owns the shared WebView lyrics poll while the lyrics UI changes presenter.
///
/// The high-frequency lyric poll is a single flag inside the shared WebView, but two views consume it:
/// the lyrics panel and the fullscreen now-playing lyrics. When one of them goes away it must
/// *hand the poll over* instead of stopping it, or the surviving view's karaoke highlight freezes until
/// the next track change — the poll is what reports playback time, so a stop with lyrics still on screen
/// freezes every sheet at once (`PlayerService.currentTimeMs` comes from it).
///
/// Both rules are evaluated while the presentation transition is in flight, which is why they take the
/// flag values directly: `showLyrics` and `showFullscreenNowPlaying` already hold their post-transition
/// values by the time a disappearing view runs its teardown.
enum LyricsPollHandoff {
    /// Whether a lyrics sheet must leave the poll running when it disappears.
    ///
    /// A sheet disappears for two reasons: the reader closed it, or the fullscreen view took over the
    /// lyrics. Only the second one still needs the poll.
    static func shouldKeepPollingAfterSidebarDisappears(
        isFullscreenPresented: Bool,
        hasSyncedLyrics: Bool
    ) -> Bool {
        isFullscreenPresented && hasSyncedLyrics
    }

    /// Whether the fullscreen view must stop the poll once it is dismissed.
    ///
    /// Exiting fullscreen through the lyrics shortcut can open a lyrics panel in the same update, so that
    /// panel can already be the new consumer by the time this view is torn down.
    static func shouldStopPollingAfterFullscreenDismiss(
        isLyricsSheetVisible: Bool,
        hasSyncedLyrics: Bool
    ) -> Bool {
        !(isLyricsSheetVisible && hasSyncedLyrics)
    }

    /// Whether the reader has lyrics on screen, from any of the app's lyric surfaces.
    ///
    /// The reader's right sidebar is a **column**, and a column that was open stays open behind the
    /// fullscreen player. So on the way out of the player it is the sidebar's own page that has to be asked,
    /// not just the classic panel's flag: asking only the flag stopped the poll while the lyrics it feeds
    /// were still on screen, which froze the sidebar's karaoke the moment the player was closed.
    ///
    /// **Both** of the sidebar's pages that show lyrics count. Its `lyrics` page is the full sheet; its
    /// `overview` is the column itself, which carries the three-line lyric preview under the artwork. Asking
    /// only for the full sheet stopped the poll on every exit from the player taken with the column on its
    /// overview — which is the page the column opens on — so the preview froze on the line it had reached and
    /// stayed there: nothing re-starts the poll while the column is never re-created. Its `queue` page shows
    /// no lyrics, and neither does a column that is not open at all (`nil`).
    static func isLyricsSheetVisible(
        isClassicPanelVisible: Bool,
        nowPlayingSidebarPage: NowPlayingSidebarPage?
    ) -> Bool {
        if isClassicPanelVisible { return true }
        switch nowPlayingSidebarPage {
        case .lyrics, .overview: return true
        case .queue, nil: return false
        }
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
