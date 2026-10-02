import CoreGraphics
import Testing
@testable import Kaset

/// The resizable Now Playing column must never be wider than the window can give it, or the detail
/// view is squeezed below its minimum and the column's fixed width draws straight over it — the
/// "content cropped behind the sidebar" bug. These are the invariants that stop that happening, tested
/// as arithmetic so they cannot silently regress behind a layout change.
@Suite(.tags(.model))
struct NowPlayingSidebarColumnGeometryTests {
    /// The real window's numbers, so the tests fail if the app's own limits drift.
    private static let real = NowPlayingSidebarColumnGeometry(
        availableWidth: 1327,
        detailMinWidth: 900,
        handleWidth: 8,
        minWidth: 300,
        maxWidth: 560,
        floorWidth: 240
    )

    @Test("A roomy window lets the column take its full desired width")
    func roomyWindowAllowsDesiredWidth() {
        var wide = Self.real
        wide.availableWidth = 1600 // ceiling = 1600 - 900 - 8 = 692
        #expect(wide.effective(desired: 380) == 380)
        #expect(wide.effective(desired: 520) == 520)
        #expect(wide.effective(desired: 560) == 560)
    }

    @Test("A desired width beyond the column's own maximum is clamped to it")
    func desiredWidthIsClampedToMaximum() {
        // Available is wide enough for the maximum, so only the column's own limit applies.
        var wide = Self.real
        wide.availableWidth = 2000
        #expect(wide.effective(desired: 900) == 560)
        #expect(wide.effective(desired: 10) == 300)
    }

    @Test("A window that cannot fit the maximum caps the column to what it can give")
    func windowCapsColumnBelowItsMaximum() {
        // 1327 - 900 - 8 = 419: the column maxes out there even though its own maximum is 560.
        #expect(Self.real.ceiling == 419)
        #expect(Self.real.effective(desired: 380) == 380)
        #expect(Self.real.effective(desired: 560) == 419)
    }

    @Test("The detail area keeps its minimum width however far the divider is dragged")
    func detailAreaNeverSqueezed() {
        var geometry = Self.real
        for desired in stride(from: 300.0, through: 560.0, by: 10.0) {
            let column = geometry.effective(desired: desired)
            let detail = geometry.availableWidth - column - geometry.handleWidth
            #expect(
                detail >= geometry.detailMinWidth,
                "detail collapsed to \(detail) at column \(column)"
            )
        }
    }

    @Test("A drag wider than the window admits is capped so the stack still fits")
    func dragIsCappedToAvailableSpace() {
        var geometry = Self.real
        geometry.availableWidth = 1100
        // 1100 - 900 - 8 = 192, below the 240 floor, so the floor is what fits.
        #expect(geometry.ceiling == 240)
        #expect(geometry.effective(desired: 560) == 240)
        #expect(geometry.effective(desired: 300) == 240)
    }

    @Test("Below the floor the column stops at the floor rather than vanishing")
    func tinyWindowStopsAtFloor() {
        var geometry = Self.real
        geometry.availableWidth = 800
        #expect(geometry.effective(desired: 380) == geometry.floorWidth)
    }

    @Test("Before the window is measured the desired width is trusted, not guessed at zero")
    func unmeasuredWindowTrustsDesired() {
        var geometry = Self.real
        geometry.availableWidth = 0
        #expect(geometry.ceiling == geometry.maxWidth)
        #expect(geometry.effective(desired: 380) == 380)
    }

    @Test("A non-finite desired width falls back to a clamped value instead of wedging the column")
    func nonFiniteDesiredIsSafe() {
        #expect(Self.real.effective(desired: .nan) == 300)
        #expect(Self.real.effective(desired: .infinity) == 419)
        #expect(Self.real.effective(desired: -.infinity) == 300)
    }
}
