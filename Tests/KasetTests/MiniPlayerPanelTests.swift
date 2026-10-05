import CoreGraphics
import Testing

@testable import Kaset

// MARK: - PlayerSurfaceHostTests

/// The rule that decides which window owns the shared player surface.
///
/// This is the invariant the detached mini player rests on: there is one `WKWebView`, a view has one
/// superview, so exactly one window may host it. The cases below are the ones that would otherwise
/// show up as the video vanishing from whichever window lost the race.
struct PlayerSurfaceHostTests {
    @Test func mainWindowClaimsTheSurfaceWhenItOwnsIt() {
        #expect(PlayerSurfaceHost.mainWindow.claimsSurface(when: .mainWindow))
    }

    @Test func mainWindowIsTheFallbackHostForAnythingThatIsNotThePanel() {
        // The main window hosts the surface whenever the panel does not — including before the app
        // has ever named a host, which is what keeps launch behaviour unchanged.
        #expect(PlayerSurfaceHost.mainWindow.claimsSurface(when: .mainWindow))
    }

    @Test func mainWindowDoesNotClaimTheSurfaceWhileThePanelOwnsIt() {
        // The whole point: once detached, the main window must stand down, or the two containers
        // pull the same view back and forth and the surface blanks in the loser.
        #expect(!PlayerSurfaceHost.mainWindow.claimsSurface(when: .miniPlayerPanel))
    }

    @Test func panelClaimsTheSurfaceOnlyWhenItOwnsIt() {
        #expect(PlayerSurfaceHost.miniPlayerPanel.claimsSurface(when: .miniPlayerPanel))
        // A panel that appears — or is re-created — must not steal the video from the main window
        // on its own; the app has to hand it over.
        #expect(!PlayerSurfaceHost.miniPlayerPanel.claimsSurface(when: .mainWindow))
    }

    @Test func exactlyOneHostClaimsTheSurface() {
        let hosts: [PlayerSurfaceHost] = [.mainWindow, .miniPlayerPanel]
        for owner in hosts {
            let claimants = hosts.filter { $0.claimsSurface(when: owner) }
            #expect(claimants == [owner], "owner \(owner) must have exactly one claimant, got \(claimants)")
        }
    }
}

// MARK: - MiniPlayerPanelLayoutTests

/// The panel's geometry: the size bounds, the ratio, and the restored size.
struct MiniPlayerPanelLayoutTests {
    @Test func heightFollowsTheTracksAspectRatio() {
        let layout = MiniPlayerPanelLayout(aspectRatio: 2)
        // 400 wide at 2:1 is 200 of video, plus the transport.
        #expect(layout.height(forWidth: 400) == 200 + MiniPlayerPanelLayout.transportHeight)
    }

    @Test func missingAspectRatioFallsBackToWidescreen() {
        let layout = MiniPlayerPanelLayout(aspectRatio: nil)
        #expect(layout.aspectRatio == MiniPlayerPanelLayout.defaultAspectRatio)
    }

    @Test func aspectRatioIsClampedToTheRangeTheAppAccepts() {
        #expect(MiniPlayerPanelLayout(aspectRatio: 0.01).aspectRatio == MiniPlayerPanelLayout.minimumAspectRatio)
        #expect(MiniPlayerPanelLayout(aspectRatio: 99).aspectRatio == MiniPlayerPanelLayout.maximumAspectRatio)
    }

    @Test func widthIsClampedIntoThePanelsBounds() {
        #expect(MiniPlayerPanelLayout.clampedWidth(10) == MiniPlayerPanelLayout.minimumWidth)
        #expect(MiniPlayerPanelLayout.clampedWidth(5000) == MiniPlayerPanelLayout.maximumWidth)
        #expect(MiniPlayerPanelLayout.clampedWidth(400) == 400)
    }

    @Test func nonFiniteWidthFallsBackToTheDefault() {
        // A stored width that decoded as garbage must not produce a zero-width window the reader
        // cannot resize back. Only `NaN` has no direction to clamp towards.
        #expect(MiniPlayerPanelLayout.clampedWidth(.nan) == MiniPlayerPanelLayout.defaultWidth)
        // An infinity does have a direction, so it clamps to the bound it is headed for.
        #expect(MiniPlayerPanelLayout.clampedWidth(.infinity) == MiniPlayerPanelLayout.maximumWidth)
        #expect(MiniPlayerPanelLayout.clampedWidth(-.infinity) == MiniPlayerPanelLayout.minimumWidth)
    }

    @Test func contentSizeKeepsTheRatioWithinBounds() {
        let layout = MiniPlayerPanelLayout(aspectRatio: 16.0 / 9.0)
        let size = layout.contentSize(forWidth: 100)
        // Below the minimum, so it is clamped rather than honoured.
        #expect(size.width == MiniPlayerPanelLayout.minimumWidth)
        #expect(size.height == layout.height(forWidth: MiniPlayerPanelLayout.minimumWidth))
    }
}

// MARK: - MiniPlayerPanelPlacementTests

/// Where the panel first appears.
struct MiniPlayerPanelPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let mainWindow = CGRect(x: 200, y: 100, width: 1280, height: 820)

    @Test func panelSitsAtTheMainWindowsBottomTrailingCorner() {
        let size = CGSize(width: 400, height: 300)
        let frame = MiniPlayerPanelPlacement.frame(
            size: size,
            mainWindowFrame: self.mainWindow,
            visibleScreenFrame: self.screen
        )

        #expect(frame.maxX == self.mainWindow.maxX - 12)
        #expect(frame.minY == self.mainWindow.minY + 12)
        #expect(frame.size == size)
    }

    @Test func panelIsNudgedBackOntoTheScreenWhenTheMainWindowHangsOffIt() {
        // A main window partly off the right edge of the display would otherwise place the panel
        // where it cannot be reached.
        let offScreenMainWindow = CGRect(x: 1600, y: 100, width: 1280, height: 820)
        let size = CGSize(width: 400, height: 300)
        let frame = MiniPlayerPanelPlacement.frame(
            size: size,
            mainWindowFrame: offScreenMainWindow,
            visibleScreenFrame: self.screen
        )

        #expect(frame.maxX <= self.screen.maxX)
        #expect(frame.minX >= self.screen.minX)
    }

    @Test func panelStaysInsideTheScreenForEveryMainWindowPosition() {
        let size = CGSize(width: 400, height: 300)
        for x in stride(from: -400.0, through: 2200.0, by: 200.0) {
            for y in stride(from: -400.0, through: 1400.0, by: 200.0) {
                let frame = MiniPlayerPanelPlacement.frame(
                    size: size,
                    mainWindowFrame: CGRect(x: x, y: y, width: 1280, height: 820),
                    visibleScreenFrame: self.screen
                )
                #expect(frame.minX >= self.screen.minX, "x=\(x) placed the panel off the left edge")
                #expect(frame.maxX <= self.screen.maxX, "x=\(x) placed the panel off the right edge")
                #expect(frame.minY >= self.screen.minY, "y=\(y) placed the panel off the bottom edge")
                #expect(frame.maxY <= self.screen.maxY, "y=\(y) placed the panel off the top edge")
            }
        }
    }

    @Test func panelWiderThanTheScreenIsStillPinnedToItsLeadingEdge() {
        // The clamp cannot fit the panel — the range is inside out — so it must not take the
        // meaningless upper bound and push the panel *past* the screen's leading edge. Pinning to
        // the leading edge is the closest position the reader can still reach.
        let smallScreen = CGRect(x: 0, y: 0, width: 300, height: 300)
        let size = CGSize(width: 400, height: 300)
        let frame = MiniPlayerPanelPlacement.frame(
            size: size,
            mainWindowFrame: self.mainWindow,
            visibleScreenFrame: smallScreen
        )
        #expect(frame.minX == smallScreen.minX + 12)
    }
}
