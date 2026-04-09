import SwiftUI

// MARK: - PersistentPlayerView

/// A SwiftUI view that displays the singleton WebView.
/// The WebView is created once and reused for all playback.
struct PersistentPlayerView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    let videoId: String
    let isExpanded: Bool
    let prefersVideo: Bool
    let viewportSize: CGSize

    private let logger = DiagnosticsLogger.player

    func makeNSView(context _: Context) -> NSView {
        self.logger.info("PersistentPlayerView.makeNSView for videoId: \(self.videoId)")

        let container = NSView(frame: .zero)
        container.wantsLayer = true

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

        // Restored sessions keep the hidden WebView inert until the user explicitly resumes.
        if self.playerService.shouldAutoloadPendingVideo,
           SingletonPlayerWebView.shared.currentVideoId != self.videoId
        {
            self.logger.info("Initial load for videoId: \(self.videoId)")
            SingletonPlayerWebView.shared.loadVideo(videoId: self.videoId)
        }

        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
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

        if self.playerService.shouldAutoloadPendingVideo {
            SingletonPlayerWebView.shared.loadVideo(videoId: self.videoId)
        }
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
