import CoreGraphics
import Foundation

// MARK: - PlayerSurfaceHost

/// The window that owns the shared player surface — the singleton WebView's layer.
///
/// The app plays through exactly one `WKWebView`, and the view that shows it re-parents it into
/// whichever container is on screen. A view has one superview, so the surface can only ever be in
/// one window; this names which one. See `PlayerService.playerSurfaceHost` for why that has to be
/// stated rather than assumed.
enum PlayerSurfaceHost: String, Equatable, Sendable {
    /// The app's main window. Everything the app did before the mini player panel existed.
    case mainWindow
    /// The detached mini player panel.
    case miniPlayerPanel

    /// Whether a host may claim the surface for itself.
    ///
    /// The main window is the fallback owner: it hosts the surface whenever nothing else does. The
    /// panel only hosts it once it has actually taken it (`PlayerService.setPlayerSurfaceHost`), so
    /// the panel appearing — or being re-created — can never silently steal the video from the main
    /// window without the app having decided to hand it over.
    func claimsSurface(when host: PlayerSurfaceHost) -> Bool {
        self == host || (self == .mainWindow && host != .miniPlayerPanel)
    }
}

// MARK: - MiniPlayerPanelLayout

/// The detached mini player panel's geometry, as one value.
///
/// The panel is a video surface, so its height follows its width by the track's own aspect ratio —
/// the same rule the in-window mini player already uses. Keeping the arithmetic here (rather than
/// inline in the view or the window controller) is what makes the resize bounds, the restored size
/// and the initial size one statement, and it is the part worth a test: a panel that could be
/// dragged below its own minimum, or restored to a size it cannot be resized back from, is a bug
/// that only shows up as a window the reader cannot fix.
struct MiniPlayerPanelLayout: Equatable {
    /// Smallest the panel may be made by dragging. Wide enough for the transport controls and a
    /// legible title.
    static let minimumWidth: CGFloat = 280
    /// Largest the panel may be made by dragging. Past this it stops being a companion window.
    static let maximumWidth: CGFloat = 960
    /// Width the panel opens at the first time.
    static let defaultWidth: CGFloat = 420

    /// Aspect ratios are the track's video, clamped to the range the app already accepts for the
    /// in-window mini player (see `MainWindow.Layout`).
    static let minimumAspectRatio: CGFloat = 0.3
    static let maximumAspectRatio: CGFloat = 4.0
    /// Ratio used before the player has reported one.
    static let defaultAspectRatio: CGFloat = 16.0 / 9.0

    /// The transport controls below the video. A static because it is a fact about the panel's
    /// content, not about a particular track.
    static let transportHeight: CGFloat = 56

    /// The video area's ratio (width / height).
    let aspectRatio: CGFloat

    init(aspectRatio: CGFloat?) {
        let ratio = aspectRatio ?? Self.defaultAspectRatio
        self.aspectRatio = min(max(ratio, Self.minimumAspectRatio), Self.maximumAspectRatio)
    }

    /// The panel's total height for a given width: the video's height plus the transport.
    func height(forWidth width: CGFloat) -> CGFloat {
        width / self.aspectRatio + Self.transportHeight
    }

    /// The panel's content size for a width, clamped into the panel's own bounds.
    func contentSize(forWidth width: CGFloat) -> CGSize {
        let clamped = Self.clampedWidth(width)
        return CGSize(width: clamped, height: self.height(forWidth: clamped))
    }

    /// The width the panel may actually take.
    ///
    /// Only a `NaN` falls back to the default: it is the one value with no sensible magnitude, and a
    /// window sized from it would be a zero-width window the reader could not resize back. An
    /// infinity *does* have a direction, so it clamps to the bound it is headed for.
    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        guard !width.isNaN else { return Self.defaultWidth }
        return min(max(width, Self.minimumWidth), Self.maximumWidth)
    }
}

// MARK: - MiniPlayerPanelPlacement

/// Where the panel is put when it first appears.
///
/// A companion window that opens on top of the thing it belongs to is worse than one that opens
/// beside it, and a window whose remembered frame is on a display that is no longer attached opens
/// off-screen. Both are avoided by deriving the frame from the main window and the screen it is on,
/// which is the one piece of panel behaviour worth stating and testing separately from AppKit.
enum MiniPlayerPanelPlacement {
    /// The frame for a panel of `size`, given the main window's frame and the visible screen area.
    ///
    /// Placed at the main window's bottom-trailing corner — where the in-window mini player sits —
    /// inset from the screen's visible edge, and nudged inside the screen if that corner is off it.
    static func frame(
        size: CGSize,
        mainWindowFrame: CGRect,
        visibleScreenFrame: CGRect
    ) -> CGRect {
        let margin: CGFloat = 12
        let trailing = mainWindowFrame.maxX - margin
        let bottom = mainWindowFrame.minY + margin

        // Prefer the main window's own corner; fall back to the screen's when the main window is
        // larger than the screen (or is itself partly off it).
        var origin = CGPoint(
            x: trailing - size.width,
            y: bottom
        )

        let screen = visibleScreenFrame
        origin.x = Self.clamp(origin.x, minimum: screen.minX + margin, maximum: screen.maxX - size.width - margin)
        origin.y = Self.clamp(origin.y, minimum: screen.minY + margin, maximum: screen.maxY - size.height - margin)

        return CGRect(origin: origin, size: size)
    }

    /// Clamps a coordinate into a range, tolerating a range that is inside out.
    ///
    /// A panel larger than the screen makes `maximum` fall below `minimum`. Clamping in the usual
    /// order would then take the (meaningless) upper bound and place the panel *past* the screen's
    /// leading edge, which is worse than the corner it started at — so an impossible range resolves
    /// to the leading edge, the closest position the reader can still reach.
    private static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard maximum >= minimum else { return minimum }
        return min(max(value, minimum), maximum)
    }
}
