import AppKit
import SwiftUI

// MARK: - PersistentPlayerView

/// A SwiftUI view that displays the singleton WebView.
/// The WebView is created once and reused for all playback.
///
/// `videoId` is `nil` before anything is played: the layer is hosted from launch so the WebView (and
/// the YouTube Music shell inside it) exists before the user asks for music, and a nil id means this
/// pass is only here for that warm-up.
struct PersistentPlayerView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    let videoId: String?
    let isExpanded: Bool
    let prefersVideo: Bool
    let viewportSize: CGSize

    /// Whether this host is allowed to own the shared player surface.
    ///
    /// The app has one `WKWebView` and it can only be in one window, so ownership is a rule rather
    /// than a consequence of which view happened to lay out last. A host that does not own the
    /// surface must not attach the WebView *even for a moment*: re-parenting is what a losing host
    /// would otherwise do during the handover, and the surface would blank — or, for a DRM stream,
    /// break — in whichever window lost. The default keeps every existing host unchanged; the main
    /// window is the one that stands down (see `MainWindow.hostsPlayerWebView`).
    var claimsSurface: Bool = true

    private let logger = DiagnosticsLogger.player

    func makeNSView(context _: Context) -> NSView {
        self.logger.info("PersistentPlayerView.makeNSView for videoId: \(self.videoId ?? "none")")

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        guard self.claimsSurface else { return container }

        // Get or create the singleton WebView
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        // Remove from any previous superview and add to this container
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        // Keep the shared WebView in a video-focused presentation when the mini player is visible.
        SingletonPlayerWebView.shared.updateMiniPlayerPresentation(
            isExpanded: self.isExpanded,
            prefersVideo: self.prefersVideo,
            viewportSize: self.viewportSize
        )

        self.loadPageIfNeeded()

        return container
    }

    /// Gives the WebView its page: the track that is playing, the track that will be played, or the
    /// shell when there is no track at all (see ``PlayerWebViewPreload``).
    ///
    /// A restored session is the case worth naming: it knows its song and its position before anything
    /// is played, so its watch page is loaded early and held silent instead of being loaded from
    /// scratch by the first press of play.
    private func loadPageIfNeeded() {
        guard let videoId = self.videoId else {
            SingletonPlayerWebView.shared.loadShellIfNeeded()
            return
        }

        if self.playerService.shouldAutoloadPendingVideo,
           SingletonPlayerWebView.shared.currentVideoId != videoId
        {
            self.logger.info("Initial load for videoId: \(videoId)")
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
            return
        }

        SingletonPlayerWebView.shared.preloadVideo(
            videoId: videoId,
            startAt: self.playerService.deferredResumePosition
        )
    }

    func updateNSView(_ container: NSView, context _: Context) {
        guard self.claimsSurface else {
            // Stand down: if this container somehow holds the surface, give it up. Without this a
            // pass that arrives after the handover could pull the WebView back into a host that no
            // longer owns it, and the owning window would then have to steal it back.
            if let webView = SingletonPlayerWebView.shared.webView, webView.superview === container {
                webView.removeFromSuperview()
            }
            return
        }

        // Ensure WebView is in this container
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        if webView.superview !== container {
            self.logger.info("Re-parenting WebView to current container")
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }

        webView.frame = container.bounds

        SingletonPlayerWebView.shared.updateMiniPlayerPresentation(
            isExpanded: self.isExpanded,
            prefersVideo: self.prefersVideo,
            viewportSize: self.viewportSize
        )

        self.loadPageIfNeeded()
    }
}

// MARK: - MiniPlayerToast

/// A small toast-style view that appears when mini player is shown.
/// Uses Liquid Glass materialize transition for smooth appearance.
@available(macOS 26.0, *)
struct MiniPlayerToast: View {
    let videoId: String

    var body: some View {
        PersistentPlayerView(
            videoId: self.videoId,
            isExpanded: true,
            prefersVideo: true,
            viewportSize: CGSize(width: 320, height: 180)
        )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .glassEffectTransition(.materialize)
    }
}
