import AppKit
import SwiftUI

// MARK: - MiniPlayerPanel

/// The detached mini player's content: the shared player surface with a transport under it.
///
/// ## What this window is for
///
/// A companion window is only worth having if it survives the thing it detached from, so the panel
/// is a real `NSWindow` (an `NSPanel`, see `MiniPlayerPanelController`) rather than a floating view
/// inside the main window. Closing the main window leaves the panel — and playback — alone, which is
/// the one behaviour a detached player has to get right.
///
/// ## Why it hosts the player surface
///
/// The app has a single `WKWebView` and it can only be in one window at a time, so detaching means
/// *moving* the surface here rather than copying it. `MiniPlayerPanelHostView` only claims it while
/// `PlayerService.playerSurfaceHost` says this panel owns it, and the main window stands down when
/// it does (see `MainWindow.hostsPlayerWebView`). The artwork behind the transport is what the panel
/// shows whenever the surface is not its to draw — a video-less track, or the brief window while the
/// WebView is being re-parented.
@available(macOS 26.0, *)
struct MiniPlayerPanel: View {
    private enum Layout {
        /// The panel's own padding, and the inset of the transport from its edges.
        static let transportPadding: CGFloat = 10
        /// Artwork shown behind the transport when the panel is not drawing the video surface.
        static let artworkSize: CGFloat = 44
    }

    @Environment(PlayerService.self) private var playerService

    var body: some View {
        VStack(spacing: 0) {
            // The video area: the shared WebView's layer while this panel owns the surface, the
            // artwork otherwise. Either way it takes the space the layout reserved for it, so the
            // transport never moves when the surface is handed over.
            self.videoArea

            self.transport
        }
        // The panel is a single surface, not a stack of panes: one material behind everything keeps
        // the video's rounded corners and the transport reading as one piece.
        .background {
            NowPlayingSidebarBackground(
                artworkURL: self.artworkURL,
                identity: self.playerService.currentTrack?.videoId
            )
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Video

    private var artworkURL: URL? {
        self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL
    }

    @ViewBuilder
    private var videoArea: some View {
        if self.panelHostsSurface {
            // The surface itself: the same `PersistentPlayerView` the main window uses, so the
            // WebView is moved here rather than a second one being created. `isExpanded` stays true
            // for the panel's whole life — it is what hands the page's own controls to the user and
            // keeps the `<video>` element in the app's container (see
            // `SingletonPlayerWebView.updateMiniPlayerPresentation`).
            MiniPlayerPanelHostView(claimsSurface: self.panelHostsSurface)
        } else {
            self.artwork
        }
    }

    /// Whether the panel is currently the surface's owner.
    private var panelHostsSurface: Bool {
        self.playerService.playerSurfaceHost == .miniPlayerPanel
            && self.playerService.pendingPlayVideoId != nil
    }

    private var artwork: some View {
        ZStack {
            Color.black.opacity(0.25)

            CachedAsyncImage(
                url: self.artworkURL,
                identity: self.playerService.currentTrack?.videoId,
                targetSize: CGSize(width: 640, height: 640)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 12) {
            self.trackIdentity
            Spacer(minLength: 8)
            self.controls
        }
        .padding(.horizontal, Layout.transportPadding)
        .frame(height: MiniPlayerPanelLayout.transportHeight)
    }

    /// Artwork + title + artist, the Apple Music "what is playing" line.
    private var trackIdentity: some View {
        HStack(spacing: 8) {
            CachedAsyncImage(
                url: self.artworkURL,
                identity: self.playerService.currentTrack?.videoId,
                targetSize: CGSize(width: Layout.artworkSize * 2, height: Layout.artworkSize * 2)
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.12)
            }
            .frame(width: Layout.artworkSize, height: Layout.artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(self.playerService.currentTrack?.title ?? String(localized: "Not Playing"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(self.artistLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artistLine: String {
        let artists = self.playerService.currentTrack?.artists.map(\.name).joined(separator: ", ")
        guard let artists, !artists.isEmpty else { return String(localized: "Unknown Artist") }
        return artists
    }

    private var controls: some View {
        HStack(spacing: 14) {
            self.transportButton(
                systemImage: "backward.fill",
                help: "Previous",
                identifier: AccessibilityID.MiniPlayerPanel.previousButton
            ) {
                Task { await self.playerService.previous() }
            }

            self.transportButton(
                systemImage: self.playerService.isPlaying ? "pause.fill" : "play.fill",
                help: self.playerService.isPlaying ? "Pause" : "Play",
                identifier: AccessibilityID.MiniPlayerPanel.playPauseButton
            ) {
                Task { await self.playerService.playPause() }
            }

            self.transportButton(
                systemImage: "forward.fill",
                help: "Next",
                identifier: AccessibilityID.MiniPlayerPanel.nextButton
            ) {
                Task { await self.playerService.next() }
            }
        }
    }

    private func transportButton(
        systemImage: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticService.toggle()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.9))
        .help(String(localized: String.LocalizationValue(help)))
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - MiniPlayerPanelHostView

/// Hosts the shared player surface inside the detached panel.
///
/// Deliberately the *same* `PersistentPlayerView` the main window uses, with the same
/// `isExpanded: true` presentation the in-window mini player uses — the panel is a bigger, more
/// permanent version of that floating layer, not a second kind of player. Because the surface is the
/// singleton WebView, this view only claims it while the app says the panel owns it; the moment the
/// host changes, this renders nothing and the main window's layer takes it back.
@available(macOS 26.0, *)
private struct MiniPlayerPanelHostView: View {
    @Environment(PlayerService.self) private var playerService

    /// Whether the app has handed the surface to this panel. Passed in rather than re-derived so the
    /// panel's `body` and the host's own claim are one decision.
    let claimsSurface: Bool

    var body: some View {
        GeometryReader { proxy in
            PersistentPlayerView(
                videoId: self.playerService.pendingPlayVideoId,
                isExpanded: true,
                prefersVideo: self.playerService.hasVideoSurface,
                viewportSize: proxy.size,
                claimsSurface: self.claimsSurface
            )
        }
    }
}
