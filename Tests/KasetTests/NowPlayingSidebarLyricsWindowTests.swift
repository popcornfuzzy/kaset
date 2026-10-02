import AppKit
import SwiftUI
import Testing
@testable import Kaset

/// The Now Playing sidebar shows the panel's *own* `SyncedLyricsDisplayView` in a window three lines
/// tall, with the reader's scrolling turned off (`allowsScrolling: false`) so a stray two-finger
/// scroll cannot push the line being sung out of it and stop the sheet following playback.
///
/// Everything the preview is worth rests on one thing: that disabling the reader's scrolling leaves
/// the sheet's own centering working. If it did not, the window would open on the first line of the
/// song and never follow it — a lyric preview showing the wrong lyrics.
///
/// Nothing offscreen can observe a scroll position, so this hosts the real sheet in a window the size
/// of the sidebar's preview and reads the pixels it drew. The line being sung is given a deliberately
/// wide text and every other line a two-letter one, so "which lines are on screen" is a question the
/// ink answers: the window can only be as wide as the widest line visible in it.
@MainActor
@Suite(.tags(.model))
struct NowPlayingSidebarLyricsWindowTests {
    /// Advances the run loop so the hosted view actually renders and its tasks run.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    /// The left-most and right-most inked columns of the hosted sheet, in device pixels.
    private static func inkBounds(_ view: NSView) -> (minX: Int, maxX: Int, scale: CGFloat)? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 4 else { return nil }

        let samples = rep.samplesPerPixel
        let rowBytes = rep.bytesPerRow
        var minX = rep.pixelsWide
        var maxX = -1
        for y in 0 ..< rep.pixelsHigh {
            let row = data + y * rowBytes
            for x in 0 ..< rep.pixelsWide where row[x * samples + 3] > 20 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }
        guard maxX > minX else { return nil }

        let scale = view.bounds.width > 0 ? CGFloat(rep.pixelsWide) / view.bounds.width : 1
        return (minX, maxX, scale)
    }

    /// Nine two-second lines, the fifth of them far wider than the two-letter lines around it.
    private static func sheet(wideLineText: String) -> SyncedLyrics {
        SyncedLyrics(
            lines: (0 ..< 9).map { index in
                SyncedLyricLine(
                    timeInMs: index * 2000,
                    duration: 2000,
                    text: index == 4 ? wideLineText : "ab",
                    words: nil
                )
            },
            source: "SidebarLyricsWindowTest"
        )
    }

    /// Hosts the sidebar's preview — the real sheet, the real height, the real fade mask — offscreen.
    private func host(_ driver: SidebarLyricsWindowDriver, lyrics: SyncedLyrics) -> NSWindow {
        let hosting = NSHostingView(rootView: SidebarLyricsWindowHarness(driver: driver, lyrics: lyrics))
        hosting.frame = NSRect(x: 0, y: 0, width: 352, height: NowPlayingSidebarLayout.lyricsPreviewHeight)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        return window
    }

    @Test("The three-line window follows playback even with the reader's scrolling off")
    func windowFollowsPlaybackWhileScrollingIsDisabled() {
        let sheet = Self.sheet(wideLineText: String(repeating: "W", count: 16))
        let wideLine = sheet.lines[4]
        let layout = KaraokeLineLayout(line: wideLine, fontSize: 16)
        let wideRowWidth = zip(layout.textWidths, layout.gaps).reduce(CGFloat(0)) { $0 + $1.0 + $1.1 }
        #expect(wideRowWidth < 300, "the harness's wide line must stay on one row for the ink to mean anything")

        let driver = SidebarLyricsWindowDriver()
        let window = self.host(driver, lyrics: sheet)
        defer { window.orderOut(nil) }
        guard let hosting = window.contentView as? NSHostingView<SidebarLyricsWindowHarness> else {
            Issue.record("the harness did not install its content view")
            return
        }

        // The sheet's own settle task runs here; it is what puts the window on the right line.
        self.pump(1.0)
        guard let opening = Self.inkBounds(hosting) else {
            Issue.record("the hosted sheet drew nothing")
            return
        }

        // Inside the wide line.
        driver.currentTimeMs = 8200
        self.pump(1.0)
        guard let followed = Self.inkBounds(hosting) else {
            Issue.record("the hosted sheet drew nothing after the playback position moved")
            return
        }

        // The opening window holds only two-letter lines, so it is narrow. If the sheet's centering
        // depended on the reader's scrolling, it would stay exactly like this for the whole song.
        #expect(
            CGFloat(opening.maxX - opening.minX) < wideRowWidth * opening.scale * 0.5,
            "the opening window was already showing the wide line, so this trace proves nothing"
        )

        // After playback moved into the wide line, that line is in the window — which is only true if
        // the sheet scrolled to it programmatically.
        #expect(
            CGFloat(followed.maxX - followed.minX) >= wideRowWidth * followed.scale * 0.8,
            "the window never reached the line being sung (\(followed.maxX - followed.minX)px of \(Int(wideRowWidth * followed.scale))px)"
        )
    }
}

// MARK: - Harness

/// The playback position the harness publishes, in the 100 ms steps the lyrics poll uses.
@MainActor
@Observable
fileprivate final class SidebarLyricsWindowDriver {
    var currentTimeMs = 0
}

@MainActor
private struct SidebarLyricsWindowHarness: View {
    let driver: SidebarLyricsWindowDriver
    let lyrics: SyncedLyrics

    var body: some View {
        SyncedLyricsDisplayView(
            lyrics: self.lyrics,
            currentTimeMs: self.driver.currentTimeMs,
            isPlaying: true,
            allowsScrolling: false,
            onSeek: { _ in }
        )
        .frame(height: NowPlayingSidebarLayout.lyricsPreviewHeight)
        .mask(NowPlayingSidebarLayout.lyricsPreviewFadeMask)
    }
}
