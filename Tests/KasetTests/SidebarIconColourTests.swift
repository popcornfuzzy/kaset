import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The sidebar's glyphs, as they are actually drawn.
///
/// A navigation row's icon carries the app's own red (`PackageResourceLookup.brandAccent`) while the row
/// is not the selection, and goes **white** with its label once it is: the selection is a filled pill, so
/// a red glyph on top of it is a second, competing colour.
///
/// That rule is a statement about rendered pixels, and nothing offscreen can observe it any other way —
/// the colours are resolved through SwiftUI's `Label` inside an AppKit source list, which is exactly
/// where a `foregroundStyle` on an icon can silently stop being applied. So this hosts the real `Sidebar`
/// in a window of its own and reads the pixels of the icon column, down the source list's own rows and
/// nowhere else: white appears in that column only for the selected row, and every other row keeps its
/// red. The assertion is the difference between the two runs — with nothing selected the column holds no
/// white at all, and with a row selected it holds exactly one white glyph.
@MainActor
@Suite(.tags(.model))
struct SidebarIconColourTests {
    /// Advances the run loop so the hosted list lays out and draws.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    private func host(selection: SidebarSelection?) -> NSWindow {
        // The sidebar's own content — the profile section at its foot — reads the account, so the harness
        // supplies one, exactly as `MainWindow` does.
        let authService = AuthService()
        let client = YTMusicClient(authService: authService)
        let accountService = AccountService(ytMusicClient: client, authService: authService)

        let hosting = NSHostingView(
            rootView: Sidebar(selection: .constant(selection))
                .environment(authService)
                .environment(accountService)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 240, height: 520)
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

    private static func descendants(of root: NSView) -> [NSView] {
        var result: [NSView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            result.append(view)
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    /// What the icon column of the source list drew: rows that carry the app's red, and rows that carry
    /// white. One band is a contiguous run of pixel rows with that colour, so each glyph counts once.
    private struct IconColumn {
        var redBands = 0
        var whiteBands = 0
        var redPixels = 0
        var whitePixels = 0
    }

    /// Reads the icon column: the leading 4…28 points of the source list's rows, and only the rows — the
    /// list's own frame in the window, which is where the profile section below it cannot reach.
    ///
    /// Drawn through the layer tree rather than `cacheDisplay`, which does not see SwiftUI's own layers.
    private func iconColumn(in window: NSWindow) -> IconColumn? {
        guard let content = window.contentView, let layer = content.layer else { return nil }

        let scale: CGFloat = 2
        let width = Int(content.bounds.width * scale)
        let height = Int(content.bounds.height * scale)
        guard width > 1, height > 1 else { return nil }

        guard let table = Self.descendants(of: content).compactMap({ $0 as? NSTableView }).first else {
            return nil
        }
        let tableFrame = table.convert(table.bounds, to: content)
        guard tableFrame.height > 8, tableFrame.width > 32 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            return true
        }
        guard rendered else { return nil }

        let leading = max(0, Int((tableFrame.minX + 4) * scale))
        let trailing = min(width, Int((tableFrame.minX + 28) * scale))
        let bottom = max(0, Int(tableFrame.minY * scale))
        let top = min(height, Int(tableFrame.maxY * scale))
        guard trailing > leading, top > bottom else { return nil }

        var column = IconColumn()
        var inRedBand = false
        var inWhiteBand = false
        for y in bottom ..< top {
            var red = 0
            var white = 0
            for x in leading ..< trailing {
                let offset = (y * width + x) * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                let a = Int(pixels[offset + 3])
                guard a > 200 else { continue }
                if r > 200, g < 100, b < 140 { red += 1 }
                if r > 235, g > 235, b > 235 { white += 1 }
            }
            column.redPixels += red
            column.whitePixels += white
            if red > 0, !inRedBand { column.redBands += 1; inRedBand = true }
            if red == 0 { inRedBand = false }
            if white > 0, !inWhiteBand { column.whiteBands += 1; inWhiteBand = true }
            if white == 0 { inWhiteBand = false }
        }
        return column
    }

    @Test("The selected row's icon is white; with nothing selected the column holds no white at all")
    func selectedRowIconIsWhite() throws {
        let unselected = self.host(selection: nil)
        self.pump(2)
        let quiet = try #require(self.iconColumn(in: unselected), "the sidebar never laid its list out")
        #expect(quiet.redPixels > 0, "the icon column has no red glyphs — the measurement is looking in the wrong place")
        #expect(quiet.whiteBands == 0, "an icon rendered white with no row selected")
        unselected.orderOut(nil)

        let selected = self.host(selection: .navigation(.likedMusic))
        self.pump(2)
        let lit = try #require(self.iconColumn(in: selected), "the sidebar never laid its list out")
        #expect(lit.redPixels > 0, "the unselected rows lost the app's red")
        #expect(lit.whitePixels > 0, "the selected row's icon did not render white")
        #expect(lit.whiteBands == 1, "the icon column should hold exactly one white glyph, for the selection")
        selected.orderOut(nil)
    }
}
