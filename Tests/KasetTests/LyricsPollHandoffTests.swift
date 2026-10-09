import Foundation
import Testing
@testable import Kaset

/// The high-frequency lyric poll is a single flag inside the shared WebView, but the sidebar lyrics
/// panel and the fullscreen now-playing lyrics both consume it. When one of them goes away it has to
/// *hand the poll over* instead of stopping it — otherwise the surviving view's karaoke highlight
/// freezes until the next track change. These tests pin that hand-off, including the videoId match that
/// decides whether the loaded lyrics can be highlighted at all.
@Suite(.serialized, .tags(.model))
@MainActor
struct LyricsPollHandoffTests {
    @Test("The sidebar leaves the poll running when fullscreen lyrics take over")
    func sidebarKeepsPollForFullscreen() {
        #expect(LyricsPollHandoff.shouldKeepPollingAfterSidebarDisappears(
            isFullscreenPresented: true,
            hasSyncedLyrics: true
        ))
    }

    @Test("The sidebar stops the poll when the user closes it")
    func sidebarStopsPollWhenClosed() {
        #expect(LyricsPollHandoff.shouldKeepPollingAfterSidebarDisappears(
            isFullscreenPresented: false,
            hasSyncedLyrics: true
        ) == false)
        #expect(LyricsPollHandoff.shouldKeepPollingAfterSidebarDisappears(
            isFullscreenPresented: true,
            hasSyncedLyrics: false
        ) == false)
    }

    @Test("Dismissing fullscreen stops the poll unless a lyrics sheet takes it")
    func fullscreenHandsPollToSidebar() {
        // Exiting fullscreen through the lyrics shortcut opens a lyrics panel in the same update, so the
        // panel is already the new consumer when the fullscreen view is torn down.
        #expect(LyricsPollHandoff.shouldStopPollingAfterFullscreenDismiss(
            isLyricsSheetVisible: true,
            hasSyncedLyrics: true
        ) == false)
        #expect(LyricsPollHandoff.shouldStopPollingAfterFullscreenDismiss(
            isLyricsSheetVisible: false,
            hasSyncedLyrics: true
        ))
        #expect(LyricsPollHandoff.shouldStopPollingAfterFullscreenDismiss(
            isLyricsSheetVisible: true,
            hasSyncedLyrics: false
        ))
        #expect(LyricsPollHandoff.shouldStopPollingAfterFullscreenDismiss(
            isLyricsSheetVisible: false,
            hasSyncedLyrics: false
        ))
    }

    @Test("A lyrics sheet is on screen when the reader's sidebar shows its lyrics card")
    func sidebarLyricsCardCountsAsAVisibleSheet() {
        // The column stays open behind the fullscreen player, so on the way out of the player it is the
        // sidebar's own page that decides whether the poll still has a consumer. Asking only the classic
        // panel's flag stopped the poll out from under the sidebar's lyrics and froze its karaoke.
        #expect(LyricsPollHandoff.isLyricsSheetVisible(
            isClassicPanelVisible: false,
            nowPlayingSidebarPage: .lyrics
        ))
        #expect(LyricsPollHandoff.isLyricsSheetVisible(
            isClassicPanelVisible: true,
            nowPlayingSidebarPage: nil
        ))

        // Both of the sidebar's lyric surfaces are sheets, and `overview` is the one the column opens on:
        // it carries the three-line preview under the artwork. Counting only the full sheet stopped the
        // poll on every exit from the player taken with the column on its overview, which froze that
        // preview on the line it had reached — and nothing re-starts a poll for a column that was never
        // closed.
        #expect(LyricsPollHandoff.isLyricsSheetVisible(
            isClassicPanelVisible: false,
            nowPlayingSidebarPage: .overview
        ))

        // The queue page replaces the overview, and a closed column shows nothing at all.
        #expect(LyricsPollHandoff.isLyricsSheetVisible(
            isClassicPanelVisible: false,
            nowPlayingSidebarPage: .queue
        ) == false)
        #expect(LyricsPollHandoff.isLyricsSheetVisible(
            isClassicPanelVisible: false,
            nowPlayingSidebarPage: nil
        ) == false)
    }

    @Test("Only synced lyrics for the playing track count")
    func onlySyncedLyricsForPlayingTrack() {
        let synced = Self.makeSyncedLyrics()

        #expect(LyricsPollHandoff.hasSyncedLyrics(
            lyrics: .synced(synced),
            lyricsVideoId: "video-1",
            trackVideoId: "video-1"
        ))

        // The panel still shows the previous song while the next one loads.
        #expect(LyricsPollHandoff.hasSyncedLyrics(
            lyrics: .synced(synced),
            lyricsVideoId: "video-1",
            trackVideoId: "video-2"
        ) == false)

        // Plain or missing lyrics have no word timing to highlight.
        #expect(LyricsPollHandoff.hasSyncedLyrics(
            lyrics: .plain(Lyrics(text: "Plain lyrics", source: "Test")),
            lyricsVideoId: "video-1",
            trackVideoId: "video-1"
        ) == false)
        #expect(LyricsPollHandoff.hasSyncedLyrics(
            lyrics: .unavailable,
            lyricsVideoId: "video-1",
            trackVideoId: "video-1"
        ) == false)

        // Nothing to compare against without both ids.
        #expect(LyricsPollHandoff.hasSyncedLyrics(
            lyrics: .synced(synced),
            lyricsVideoId: nil,
            trackVideoId: "video-1"
        ) == false)
        #expect(LyricsPollHandoff.hasSyncedLyrics(
            lyrics: .synced(synced),
            lyricsVideoId: "video-1",
            trackVideoId: nil
        ) == false)
    }

    @Test("The service answers the hand-off question for the track it serves")
    func serviceReportsSyncedLyricsForTrack() {
        let service = SyncedLyricsService(providers: [])

        #expect(service.hasSyncedLyrics(for: "video-1") == false)

        service.currentLyrics = .synced(Self.makeSyncedLyrics())
        service.currentLyricsVideoId = "video-1"

        #expect(service.hasSyncedLyrics(for: "video-1"))
        #expect(service.hasSyncedLyrics(for: "video-2") == false)

        // A plain result never owns the poll, even for the right track.
        service.currentLyrics = .plain(Lyrics(text: "Plain lyrics", source: "Test"))
        #expect(service.hasSyncedLyrics(for: "video-1") == false)
    }

    private static func makeSyncedLyrics() -> SyncedLyrics {
        SyncedLyrics(
            lines: [SyncedLyricLine(timeInMs: 0, duration: 5000, text: "Line", words: nil)],
            source: "Test"
        )
    }
}
