import AppKit
import SwiftUI
import Testing
@testable import Kaset

/// What the Now Playing column's footer rows do when the column is dragged narrow.
///
/// The column can be dragged down to 300pt, and the queue's footer had four *titled* controls in it:
/// SwiftUI kept the labels and wrapped them ("Undo" over two lines, "Shuffle" cut in half), so the row
/// grew twice as tall as its own buttons and read as broken. The row now states two versions of itself
/// — names while there is room for them, glyphs (each with a tooltip and a VoiceOver label) when there
/// is not — so these tests render the real views at the widths the column can have and read what they
/// drew. A wrapped row would be twice as tall as a row of buttons, which is what the height says, and
/// the two versions are about 257pt and 94pt wide, which is what the ink says.
@Suite("Queue and lyric footers")
@MainActor
struct QueueFooterLayoutTests {
    /// Reports the size the hosted content laid out to, and the ink it drew.
    @MainActor
    final class Probe {
        var size: CGSize = .zero
    }

    private struct Sized<Content: View>: View {
        let probe: Probe
        let content: Content

        init(probe: Probe, @ViewBuilder content: () -> Content) {
            self.probe = probe
            self.content = content()
        }

        var body: some View {
            self.content
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { self.probe.size = proxy.size }
                            .onChange(of: proxy.size) { _, newSize in self.probe.size = newSize }
                    }
                )
        }
    }

    /// What a view laid out to and drew: its height, and the left-most and right-most inked points.
    ///
    /// The ink is what tells the two versions of the queue's footer apart — the names make the row
    /// about three times as wide as the glyphs — and where the lyric footer's refresh control sits,
    /// since nothing but the pixels says whether it is at the leading or the trailing edge.
    private struct Rendered {
        let height: CGFloat
        let minX: CGFloat
        let maxX: CGFloat
    }

    /// Hosts `content` offscreen at exactly `width` and reports what it laid out to and drew.
    private func render<Content: View>(_ content: Content, width: CGFloat) -> Rendered {
        let probe = Probe()
        let hosting = NSHostingView(rootView: Sized(probe: probe) { content })
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        // The probe reports from the layout pass and the text from the display pass, so give both one.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }

        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let samples = rep.samplesPerPixel
            if let data = rep.bitmapData, samples >= 4, hosting.bounds.width > 0 {
                let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
                for y in 0 ..< rep.pixelsHigh {
                    let row = data + y * rep.bytesPerRow
                    for x in 0 ..< rep.pixelsWide where row[x * samples + 3] > 20 {
                        let point = CGFloat(x) / scale
                        if point < minX { minX = point }
                        if point > maxX { maxX = point }
                    }
                }
            }
        }

        return Rendered(
            height: probe.size.height,
            minX: minX == .greatestFiniteMagnitude ? -1 : minX,
            maxX: maxX == -.greatestFiniteMagnitude ? -1 : maxX
        )
    }

    private func queueFooter() -> some View {
        let playerService = PlayerService()
        playerService.queue = TestFixtures.makeSongs(count: 3)
        return QueueFooterActions().environment(playerService)
    }

    @Test("The queue's footer is one line of controls at every width the column can have")
    func queueFooterNeverWraps() {
        // The column's floor and up. The queue is the one page the column does not inset, so the panel's
        // own width is the width the footer is given.
        for panel in [CGFloat(300), 400, 560] {
            let rendered = self.render(self.queueFooter(), width: panel)
            // A row of names is one 12pt line plus the footer's 12pt insets (about 41pt). A wrapped row
            // measured around 70, because a two-line label is what sets the height.
            #expect(rendered.height < 55, "the footer wrapped at \(panel)pt")
        }
    }

    @Test("The names are shown while they fit, and only glyphs are left when they do not")
    func queueFooterKeepsNamesWhileTheyFit() {
        // 289pt is what the named row needs (257pt of controls plus its own 16pt insets), and the column's
        // floor of 300pt has it. The glyph version is the row's answer to being squeezed below the floor —
        // a width the column itself cannot produce, so it is asked for directly.
        let floorWidth = self.render(self.queueFooter(), width: 300)
        let squeezed = self.render(self.queueFooter(), width: 240)

        // Named at the floor: the row runs from its leading inset out past the width of four glyphs.
        #expect(floorWidth.minX < 25)
        #expect(floorWidth.maxX > 240)
        // Glyph-ed when squeezed: the same four controls in about a third of the width.
        #expect(squeezed.minX < 25)
        #expect(squeezed.maxX < 170, "the squeezed row is still showing names")
        #expect(squeezed.maxX > floorWidth.maxX - 200)
    }

    @Test("The lyric sheet's footer carries the refresh control at the trailing edge of the source row")
    func lyricFooterRefreshSitsAtTheTrailingEdge() {
        func footer(onRefresh: (() -> Void)?) -> some View {
            LyricsSourceFooter(source: "Genius", horizontalPadding: 14, onRefresh: onRefresh)
                .environment(SyncedLyricsService())
        }

        // 280pt is the width of the Now Playing column's own sheet at its narrowest.
        let width: CGFloat = 280
        let without = self.render(footer(onRefresh: nil), width: width)
        let with = self.render(footer(onRefresh: {}), width: width)

        // The source line is the row's leading content, in both versions.
        #expect(without.minX < 25)
        #expect(with.minX < 25)

        // Without the control the row's ink stops at the source line's own end…
        #expect(without.maxX < 150)
        // …and with it the row's last ink is the glyph in the trailing inset, not a control beside the
        // title: the trailing edge is where the reader asked for it (its 18pt box ends at 280 - 14).
        #expect(with.maxX > width - 45, "the refresh control is not at the trailing edge of the source row")
        #expect(with.maxX > without.maxX)
    }
}
