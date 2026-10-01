import AppKit
import SwiftUI

/// In-window fullscreen now-playing experience with artwork, synced lyrics, and transport controls.
@available(macOS 26.0, *)
struct FullscreenNowPlayingView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService
    @Environment(CanvasService.self) private var canvasService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let client: any YTMusicClientProtocol

    private enum Layout {
        /// Largest square the artwork card can take. Also the card's decode target: on a Retina display the
        /// card draws at up to 760px, so leaving the default 320 (a 640px cap) made the still — the largest
        /// artwork surface in the app — render slightly upscaled from its own downloaded data.
        static let artworkMaxDimension: CGFloat = 380
        /// Corner radius of the artwork card. Apple Music's full-screen artwork is only gently rounded —
        /// noticeably squarer than the 22pt card this replaced.
        static let artworkCornerRadius: CGFloat = 14
        /// Where the artwork settles while playback is paused. Apple Music lets the art — and the
        /// shadow under it — dip away from the viewer when the song stops, and springs it back on resume.
        static let pausedArtworkScale: CGFloat = 0.94
    }

    /// How far a new track's artwork travels in from the side it was skipped from, in points.
    private static let trackArrivalDistance: CGFloat = 26

    @State private var lastLoadedVideoId: String?
    @State private var lastLoadedSignature: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var isLoadingFallback = false
    @State private var seekValue: Double = 0
    @State private var lyricsTimeMs: Int = 0
    @State private var isSeeking = false
    /// The fullscreen player's key monitor, installed for one presentation.
    ///
    /// Two things go through it. `Escape` closes the player. Everything else is offered to the
    /// app's own menu first, and swallowed if the menu took it.
    ///
    /// That second part is the fix for the playback shortcuts working or not in here with nothing
    /// to see: a key equivalent is resolved against the window's view hierarchy *before* the main
    /// menu is consulted, and the player puts a seek slider, seven transport buttons and a
    /// scrolling lyric sheet into that window. Whichever of them held keyboard focus last was the
    /// one that got the key, so `Space` and `⌘←`/`⌘→` behaved differently depending on where the
    /// last click landed. A local monitor runs ahead of the responder chain *and* ahead of the key
    /// window, so while the player is on screen the app's commands are answered first and never
    /// depend on focus. It does not restate them — the event is handed to the same menu the
    /// shortcuts are declared in, so there is still exactly one definition of what `Space` does.
    ///
    /// Scoped to the presentation: installed when the player is presented and removed when it is
    /// not (see `startPresentation`/`endPresentation`), so nothing outside the player is affected.
    @State private var keyMonitor: Any?
    /// The window the monitor answers for, so a key typed into another window — Settings, a sheet —
    /// is left alone. The player is an overlay inside the main window, which is found the way
    /// `KasetApp.showMainWindow()` finds it. `nil` (no window identifiable yet) means the monitor
    /// answers for every window, which is what it did before it had this guard.
    @State private var keyMonitorWindowNumber: Int?
    @State private var canvasReady = false
    @State private var canvasFailed = false
    /// How far the incoming artwork is currently nudged off its resting place: positive for a skip
    /// forward, negative for a skip back, zero when nothing is arriving.
    @State private var trackArrivalOffset: CGFloat = 0
    /// Queue row the last track change animated from, so a change can tell which way it went.
    /// `nil` while the queue has no highlight (YouTube autoplay, standalone episodes).
    @State private var lastTrackQueueIndex: Int?

    private var hasLyricsForCurrentTrack: Bool {
        guard let videoId = self.playerService.currentTrack?.videoId else { return false }
        return self.syncedLyricsService.currentLyricsVideoId == videoId
    }

    var body: some View {
        GeometryReader { proxy in
            let stageWidth = proxy.size.width
            let stageHeight = min(max(300, proxy.size.height - 96), 900)
            let panelSpacing = max(8, min(30, stageWidth * 0.022))
            let totalColumnWidth = max(1, stageWidth - panelSpacing)
            let artworkColumnWidth = totalColumnWidth * 0.40
            let lyricsColumnWidth = totalColumnWidth * 0.60

            ZStack {
                self.backgroundLayer

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: panelSpacing) {
                        self.leftColumn(width: artworkColumnWidth, availableHeight: stageHeight)
                            .frame(width: artworkColumnWidth, height: stageHeight, alignment: .center)

                        self.lyricsPanel
                            .frame(width: lyricsColumnWidth, height: stageHeight, alignment: .leading)
                    }
                    .frame(width: stageWidth, height: stageHeight, alignment: .leading)
                    .padding(.top, 56)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            HStack {
                Spacer(minLength: 0)
                self.fullscreenCloseButton
            }
            .padding(.top, 12)
            .padding(.trailing, 20)
            .zIndex(10_000)
        }
        .onExitCommand {
            self.closeFullscreenNowPlaying()
        }
        // Every feature below is scoped to one *presentation* and is (re)initialized from the flag
        // transition, never from this view instance being new. `MainWindow` keeps the content alive
        // behind the overlay, so the presentation is a state machine owned by `showFullscreenNowPlaying`
        // and nothing here may depend on being destroyed and rebuilt between opens.
        .onAppear {
            if self.playerService.showFullscreenNowPlaying {
                self.startPresentation()
            }
        }
        .onChange(of: self.playerService.showFullscreenNowPlaying) { _, isPresented in
            if isPresented {
                self.startPresentation()
            } else {
                self.endPresentation()
            }
        }
        .onChange(of: self.playerService.progress) { _, _ in
            if !self.isSeeking { self.seekValue = self.normalizedProgress }
        }
        .onChange(of: self.playerService.currentTimeMs) { _, newTimeMs in
            self.lyricsTimeMs = newTimeMs
        }
        .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
            self.startLyricsLoad(for: newVideoId)
            self.animateTrackArrival()
        }
        .onChange(of: self.playerService.observedWebMetadata) { _, _ in
            self.retryLyricsLoadIfMetadataImproved()
        }
        .onChange(of: self.playerService.currentTrack?.title) { _, _ in
            self.startLyricsLoad(for: self.playerService.currentTrack?.videoId)
        }
        .onChange(of: self.playerService.duration) { _, newDuration in
            guard newDuration > 0 else { return }
            self.retryLyricsLoadIfMetadataImproved()
        }
        .onChange(of: self.syncedLyricsService.currentLyrics) { _, newLyrics in
            self.updateLyricsPolling(for: newLyrics)
        }
        .onChange(of: self.canvasService.currentCanvasURL) { _, _ in
            self.canvasReady = false
            self.canvasFailed = false
        }
        .task(id: self.canvasTaskID) {
            await self.loadCanvasWhenReady()
        }
        .onDisappear {
            self.endPresentation()
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            if let thumbnailURL = self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL {
                CachedAsyncImage(
                    url: thumbnailURL,
                    fallbackURL: self.playerService.currentTrack?.thumbnailURL,
                    identity: self.playerService.currentTrack?.videoId,
                    // Same decode target as the artwork card: the two views share one fetch per URL, so
                    // matching targets keeps that shared decode at the size the card needs.
                    targetSize: CGSize(width: Layout.artworkMaxDimension, height: Layout.artworkMaxDimension)
                ) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Rectangle().fill(.black) }
                .blur(radius: 68).scaleEffect(1.18)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            } else {
                LinearGradient(colors: [.black, .gray.opacity(0.6), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Rectangle().fill(.black.opacity(0.48))
            Rectangle().fill(LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func leftColumn(width: CGFloat, availableHeight: CGFloat) -> some View {
        let columnSpacing = max(10, min(16, availableHeight * 0.018))
        let artworkMaxHeight = min(max(200, availableHeight * 0.46), Layout.artworkMaxDimension)
        let contentWidth = min(width, 440)
        let mediaWidth = min(contentWidth, artworkMaxHeight)
        return VStack(alignment: .center, spacing: columnSpacing) {
            // The art and the song's name move as one on a skip: Apple Music hands the new
            // song in from the side it was skipped from instead of cutting to it.
            VStack(alignment: .center, spacing: columnSpacing) {
                self.artworkCard.frame(minWidth: mediaWidth, idealWidth: mediaWidth, maxWidth: mediaWidth, maxHeight: artworkMaxHeight).padding(.bottom, 12)
                self.trackMeta.frame(width: mediaWidth, alignment: .leading)
            }
            .offset(x: self.trackArrivalOffset)
            .opacity(self.trackArrivalOpacity)

            self.transportControls(contentWidth: mediaWidth).frame(width: mediaWidth).padding(.top, 6)
        }
        .frame(width: width, height: availableHeight, alignment: .center)
    }

    /// The arriving artwork's opacity: it fades up as it travels back to its resting place, so a
    /// skip reads as one motion rather than a jump.
    private var trackArrivalOpacity: Double {
        let travelled = min(abs(self.trackArrivalOffset) / Self.trackArrivalDistance, 1)
        return 1 - 0.55 * travelled
    }

    /// Falls the artwork back to full size and full presence from the side a skip came from, and
    /// does nothing at all when the track changed for another reason (the first song of a session,
    /// YouTube autoplay, a station) or when Reduce Motion is on.
    @MainActor
    private func animateTrackArrival() {
        let queueIndex = self.playerService.queueHighlightIndex
        defer { self.lastTrackQueueIndex = queueIndex }

        guard self.playerService.showFullscreenNowPlaying,
              !self.reduceMotion,
              let queueIndex,
              let previousIndex = self.lastTrackQueueIndex,
              queueIndex != previousIndex
        else {
            self.trackArrivalOffset = 0
            return
        }

        // The nudge has to be on screen for a frame before it can be animated away from, so the
        // fall back to rest happens in the next update.
        self.trackArrivalOffset = queueIndex > previousIndex ? Self.trackArrivalDistance : -Self.trackArrivalDistance
        Task { @MainActor in
            withAnimation(AppAnimation.smooth) { self.trackArrivalOffset = 0 }
        }
    }

    private var fullscreenCloseButton: some View {
        Button { self.closeFullscreenNowPlaying() } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                .padding(10).background(.black.opacity(0.36), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Exit Fullscreen Now Playing"))
    }

    private var artworkCard: some View {
        ZStack {
            // The clear square the card *is*. Both artwork layers are sized to it and the card's
            // own clip crops them, so art that is not 1:1 — a video thumbnail, a 4:3 upload —
            // covers the square proportionally instead of letterboxing inside it. The artwork sits
            // in an `overlay` so the oversized `aspectRatio(contentMode: .fill)` layer cannot
            // stretch the square itself.
            Rectangle()
                .fill(.clear)
                .overlay { self.artworkStill }

            if self.shouldShowCanvas, let canvasURL = self.canvasService.currentCanvasURL {
                CanvasVideoView(
                    url: canvasURL,
                    onReadyToPlay: { self.canvasReady = true },
                    onFailure: {
                        // Keep the still artwork: stop showing and unmount the
                        // failed player so it is not retried every render.
                        self.canvasReady = false
                        self.canvasFailed = true
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(self.canvasReady ? 1 : 0)
                .animation(self.shouldAnimateCanvas ? .easeInOut(duration: 0.6) : nil, value: self.canvasReady)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Layout.artworkCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .scaleEffect(self.artworkScale)
        .animation(self.reduceMotion ? nil : AppAnimation.spring, value: self.artworkScale)
    }

    /// The YouTube Music still album art: always the base layer, always filling the square card.
    private var artworkStill: some View {
        CachedAsyncImage(
            url: self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL,
            fallbackURL: self.playerService.currentTrack?.thumbnailURL,
            identity: self.playerService.currentTrack?.videoId,
            targetSize: CGSize(width: Layout.artworkMaxDimension, height: Layout.artworkMaxDimension)
        ) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                RoundedRectangle(cornerRadius: Layout.artworkCornerRadius, style: .continuous).fill(.white.opacity(0.08))
                CassetteIcon(size: 76).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    /// Full size while the song plays, a little smaller while it is paused — the way Apple Music
    /// settles the artwork down when playback stops. Reduce Motion keeps the full size: the shrink
    /// is decoration, nothing reads from it.
    private var artworkScale: CGFloat {
        (self.reduceMotion || self.playerService.isPlaying) ? 1 : Layout.pausedArtworkScale
    }

    private var trackMeta: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.playerService.currentTrack?.title ?? String(localized: "No Song Playing"))
                .font(.system(size: 30, weight: .bold)).lineLimit(2).foregroundStyle(.white)
            Text(self.playerService.currentTrack?.artistsDisplay.isEmpty == false ? self.playerService.currentTrack?.artistsDisplay ?? "" : String(localized: "Unknown Artist"))
                .font(.system(size: 17, weight: .medium)).lineLimit(1).foregroundStyle(.white.opacity(0.82))
        }
    }

    private func transportControls(contentWidth: CGFloat) -> some View {
        let buttonRowSpacing = max(12, min(22, contentWidth * 0.055))
        let timeLabelWidth: CGFloat = 46
        return VStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                Text(self.formatTime(self.playerService.progress)).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).monospacedDigit().frame(width: timeLabelWidth, alignment: .leading)
                Slider(value: self.$seekValue, onEditingChanged: { isEditing in
                    self.isSeeking = isEditing
                    if !isEditing { Task { await self.playerService.seek(to: self.seekValue * self.playerService.duration) } }
                }).tint(.white).disabled(self.playerService.duration <= 0)
                Text(self.formatTime(max(0, self.playerService.duration - self.playerService.progress))).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).monospacedDigit().frame(width: timeLabelWidth, alignment: .trailing)
            }.frame(width: contentWidth)
            HStack(spacing: buttonRowSpacing) {
                self.transportButton(
                    systemImage: self.playerService.currentTrackLikeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    size: 18,
                    tint: self.playerService.currentTrackLikeStatus == .dislike ? .red : .white,
                    accessibilityLabel: String(localized: "Dislike"),
                    accessibilityValue: self.playerService.currentTrackLikeStatus == .dislike ? String(localized: "Disliked") : String(localized: "Not disliked")
                ) { HapticService.toggle(); self.playerService.dislikeCurrentTrack() }

                self.transportButton(
                    systemImage: "shuffle",
                    size: 17,
                    tint: self.playerService.shuffleEnabled ? .red : .white,
                    accessibilityLabel: String(localized: "Shuffle"),
                    accessibilityValue: self.playerService.shuffleEnabled ? String(localized: "On") : String(localized: "Off")
                ) { HapticService.toggle(); self.playerService.toggleShuffle() }

                self.transportButton(
                    systemImage: "backward.fill",
                    size: 20,
                    accessibilityLabel: String(localized: "Previous track")
                ) { HapticService.playback(); Task { await self.playerService.previous() } }

                // The play/pause button is the row's anchor: it dips further on press and its
                // glyph morphs between the two states rather than swapping.
                self.transportButton(
                    systemImage: self.playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                    size: 54,
                    weight: .regular,
                    pressScale: 0.92,
                    accessibilityLabel: self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play")
                ) { HapticService.playback(); Task { await self.playerService.playPause() } }

                self.transportButton(
                    systemImage: "forward.fill",
                    size: 20,
                    accessibilityLabel: String(localized: "Next track")
                ) { HapticService.playback(); Task { await self.playerService.next() } }

                self.transportButton(
                    systemImage: self.repeatIcon,
                    size: 17,
                    tint: self.playerService.repeatMode != .off ? .red : .white,
                    accessibilityLabel: String(localized: "Repeat"),
                    accessibilityValue: self.repeatAccessibilityValue
                ) { HapticService.toggle(); self.playerService.cycleRepeatMode() }

                self.transportButton(
                    systemImage: self.playerService.currentTrackLikeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup",
                    size: 18,
                    tint: self.playerService.currentTrackLikeStatus == .like ? .red : .white,
                    accessibilityLabel: String(localized: "Like"),
                    accessibilityValue: self.playerService.currentTrackLikeStatus == .like ? String(localized: "Liked") : String(localized: "Not liked")
                ) { HapticService.toggle(); self.playerService.likeCurrentTrack() }
            }.frame(width: contentWidth)
        }
    }

    /// One button of the transport row.
    ///
    /// The press dip is Apple Music's: the glyph shrinks under the pointer and springs back, and
    /// whichever glyphs *change* — play ⇄ pause, repeat ⇄ repeat-one, like ⇄ liked — morph between
    /// their two states instead of swapping.
    private func transportButton(
        systemImage: String,
        size: CGFloat,
        tint: Color = .white,
        weight: Font.Weight = .semibold,
        pressScale: CGFloat = 0.86,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableButtonStyle(pressScale: pressScale))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
    }

    private var lyricsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                // Scoped so a lyrics swap in the same update is not animated
                // along with the caption.
                if self.syncedLyricsService.searchingForBetterLyrics {
                    ShimmerLine(text: String(localized: "Still searching for lyrics"), onDark: true)
                        .padding(.horizontal, 8)
                        .transition(.lyricsSearchingCaption)
                }
            }
            .animation(.smooth(duration: 0.4), value: self.syncedLyricsService.searchingForBetterLyrics)
            Group {
                if self.playerService.currentTrack == nil {
                    self.emptyLyricsState(icon: "play.circle", title: String(localized: "No Song Playing"), message: String(localized: "Play a song to view synced lyrics."))
                } else if !self.hasLyricsForCurrentTrack || self.syncedLyricsService.isLoading || self.isLoadingFallback {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.regular).tint(.white)
                        Text(String(localized: "Loading lyrics...")).font(.subheadline).foregroundStyle(.white)
                        if let provider = self.syncedLyricsService.loadingProvider {
                            Text(String(localized: "Searching \(provider)"))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch self.syncedLyricsService.currentLyrics {
                    case let .synced(synced):
                        FullscreenSyncedLyricsView(lyrics: synced, currentTimeMs: self.lyricsTimeMs, isPlaying: self.playerService.isPlaying, onSeek: { timeMs in Task { await self.playerService.seek(to: Double(timeMs) / 1000.0) } }).background(.clear).mask(self.lyricsFadeMask)
                    case let .plain(plain):
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(plain.text).font(.system(size: 36, weight: .bold)).lineSpacing(18).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                                if let attribution = plain.attribution, attribution.hasSubmitter {
                                    LyricsSubmitterCredit(attribution: attribution, color: .white.opacity(0.55))
                                        .padding(.top, 24)
                                }
                            }
                        }.scrollIndicators(.hidden).mask(self.lyricsFadeMask)
                    case .unavailable:
                        self.emptyLyricsState(icon: "quote.bubble", title: String(localized: "No Lyrics Available"), message: self.syncedLyricsService.errorMessage ?? String(localized: "Try another song to see synced lyrics here."))
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var lyricsFadeMask: some View { LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) }

    private func emptyLyricsState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) { Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.white.opacity(0.7)); Text(title).font(.headline).foregroundStyle(.white.opacity(0.9)); Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal, 20) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var normalizedProgress: Double { guard self.playerService.duration > 0 else { return 0 }; return min(max(self.playerService.progress / self.playerService.duration, 0), 1) }
    private var repeatIcon: String { switch self.playerService.repeatMode { case .off, .all: "repeat"; case .one: "repeat.1" } }
    private var repeatAccessibilityValue: String {
        switch self.playerService.repeatMode {
        case .off: String(localized: "Off")
        case .all: String(localized: "All")
        case .one: String(localized: "One")
        }
    }
    private func formatTime(_ time: TimeInterval) -> String { guard time.isFinite else { return "0:00" }; let totalSeconds = max(Int(time), 0); return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60) }
    private func updateLyricsPolling(for result: LyricResult) { if case .synced = result { SingletonPlayerWebView.shared.startLyricsPoll() } else { SingletonPlayerWebView.shared.stopLyricsPoll() } }
    private func closeFullscreenNowPlaying() { withAnimation(AppAnimation.standard) { self.playerService.showFullscreenNowPlaying = false } }

    /// Sets up everything scoped to one fullscreen presentation: the local seek/lyrics mirrors, the
    /// canvas crossfade state, the Escape key monitor, the shared lyrics poll, and the lyric lookup for
    /// the track that is on screen.
    ///
    /// Driven by the presentation change rather than by view creation, so no fullscreen feature depends
    /// on this view being destroyed and rebuilt between opens.
    @MainActor
    private func startPresentation() {
        // A previous presentation may have ended mid-drag; the slider has to follow playback again.
        self.isSeeking = false
        self.seekValue = self.normalizedProgress
        self.lyricsTimeMs = self.playerService.currentTimeMs
        // A fresh canvas player reports readiness again; a canvas that failed last time gets retried.
        self.canvasReady = false
        self.canvasFailed = false
        self.installKeyMonitorIfNeeded()
        self.updateLyricsPolling(for: self.syncedLyricsService.currentLyrics)
        self.startLyricsLoad(for: self.playerService.currentTrack?.videoId)
    }

    /// Tears the presentation down and hands the shared lyrics poll over when the sidebar lyrics panel
    /// takes it (exiting fullscreen through the lyrics shortcut opens that panel in the same update).
    ///
    /// Called from the presentation change *and* from `onDisappear`, so it must be idempotent.
    @MainActor
    private func endPresentation() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.removeKeyMonitor()
        if LyricsPollHandoff.shouldStopPollingAfterFullscreenDismiss(
            isSidebarLyricsVisible: self.playerService.showLyrics,
            hasSyncedLyrics: self.syncedLyricsService.hasSyncedLyrics(
                for: self.playerService.currentTrack?.videoId
            )
        ) {
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
    }

    /// Starts (or restarts) the lyric lookup for a track, cancelling any lookup still waiting for the
    /// previous track's metadata so a stale result can never land in the panel.
    @MainActor
    private func startLyricsLoad(for videoId: String?, forceRefresh: Bool = false) {
        self.loadTask?.cancel()
        self.loadTask = nil
        guard let videoId else { return }
        // A new track, a refined metadata signature, or an explicit refresh all warrant a
        // rerun; an unchanged track and metadata do not.
        guard forceRefresh
            || videoId != self.lastLoadedVideoId
            || self.lyricsSignature(for: videoId) != self.lastLoadedSignature
        else { return }
        self.loadTask = Task { await self.loadLyricsWhenReady(for: videoId, forceRefresh: forceRefresh) }
    }

    /// Re-runs a search that already ran for this track when the metadata it used has
    /// since been refined — the failure mode where the pane searched before the WebView
    /// reported the new song and then stayed on "No Lyrics Available". A result already
    /// on screen is never re-searched on a metadata tweak.
    @MainActor
    private func retryLyricsLoadIfMetadataImproved() {
        guard let videoId = self.playerService.currentTrack?.videoId,
              self.playerService.hasObservedWebMetadata(for: videoId),
              self.lyricsSignature(for: videoId) != self.lastLoadedSignature,
              !self.hasDisplayedLyrics(for: videoId)
        else { return }
        self.startLyricsLoad(for: videoId, forceRefresh: self.lastLoadedVideoId == videoId)
    }

    private func hasDisplayedLyrics(for videoId: String) -> Bool {
        self.syncedLyricsService.currentLyricsVideoId == videoId
            && self.syncedLyricsService.currentLyrics.isAvailable
    }

    /// Identity of the metadata a search would run with. It changes when the WebView
    /// refines the title/artist or the duration settles, which is exactly when a search
    /// that ran against incomplete metadata should be retried.
    private func lyricsSignature(for videoId: String) -> String? {
        guard let metadata = self.playerService.lyricsSearchMetadata(for: videoId) else { return nil }
        let duration = self.playerService.duration > 0 ? self.playerService.duration : (self.playerService.currentTrack?.duration ?? 0)
        return "\(videoId)|\(metadata.title)|\(metadata.artist)|\(Int(duration.rounded()))"
    }

    private func installKeyMonitorIfNeeded() {
        guard self.keyMonitor == nil else { return }
        let window = NSApplication.shared.windows.first { $0.frameAutosaveName == "KasetMainWindow" }
            ?? NSApplication.shared.keyWindow
        self.keyMonitorWindowNumber = window?.windowNumber
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // A key destined for another window is not ours to answer: the player is behind
            // whatever the user is actually typing into.
            if let windowNumber = self.keyMonitorWindowNumber, event.window?.windowNumber != windowNumber {
                return event
            }
            if event.keyCode == 53 {
                self.closeFullscreenNowPlaying()
                return nil
            }
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? nil : event
        }
    }
    private func removeKeyMonitor() { guard let monitor = self.keyMonitor else { return }; NSEvent.removeMonitor(monitor); self.keyMonitor = nil }

    /// Canvas is shown only for the current non-podcast track when the feature
    /// is enabled and the video did not fail to load.
    private var shouldShowCanvas: Bool {
        guard self.playerService.showFullscreenNowPlaying,
              SettingsManager.shared.animatedCanvasEnabled,
              !self.canvasFailed,
              let track = self.playerService.currentTrack,
              !self.playerService.isCurrentTrackPodcast
        else { return false }
        return self.canvasService.currentCanvasVideoId == track.videoId
    }

    private var shouldAnimateCanvas: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Restarts the canvas lookup whenever the fullscreen view is presented or the track changes
    /// (`.task(id:)` cancels the previous lookup). The presentation flag is part of the key so the
    /// lookup does not depend on this view being created; the lookup is cache-backed, so re-running it
    /// for an unchanged track costs no network request.
    private var canvasTaskID: String {
        "\(self.playerService.showFullscreenNowPlaying)|\(self.playerService.currentTrack?.videoId ?? "none")"
    }

    @MainActor
    private func loadCanvasWhenReady() async {
        guard self.playerService.showFullscreenNowPlaying else { return }
        guard let videoId = self.playerService.currentTrack?.videoId else { return }
        for _ in 0 ..< 40 {
            guard !Task.isCancelled,
                  self.playerService.showFullscreenNowPlaying,
                  self.playerService.currentTrack?.videoId == videoId
            else { return }
            if let track = self.playerService.currentTrack,
               !track.title.isEmpty,
               track.title != "Loading...",
               !track.artistsDisplay.isEmpty
            {
                let info = CanvasSearchInfo(
                    title: track.title,
                    artist: track.artistsDisplay,
                    album: track.album?.title,
                    videoId: track.videoId
                )
                await self.canvasService.loadCanvas(for: info)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor
    private func loadLyricsWhenReady(for videoId: String, forceRefresh: Bool = false) async {
        for _ in 0 ..< 40 {
            guard !Task.isCancelled,
                  self.playerService.currentTrack?.videoId == videoId
            else { return }
            // Wait for the WebView's observed metadata before searching: it is the
            // authoritative, normalized title/artist. Searching on the queue entry or the
            // "Loading..." placeholder makes the providers match the wrong song (or
            // nothing) and can leave the wrong lyrics on screen.
            if self.playerService.hasObservedWebMetadata(for: videoId),
               self.playerService.lyricsSearchMetadata(for: videoId) != nil
            {
                await self.loadLyrics(for: videoId, forceRefresh: forceRefresh)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        // The WebView never reported metadata in time: fall back to the current track's
        // metadata rather than leaving the pane empty forever.
        if self.playerService.lyricsSearchMetadata(for: videoId) != nil {
            await self.loadLyrics(for: videoId, forceRefresh: forceRefresh)
        }
    }

    @MainActor
    private func loadLyrics(for videoId: String, forceRefresh: Bool = false) async {
        self.isLoadingFallback = false
        guard let track = self.playerService.currentTrack, track.videoId == videoId else { return }
        // Search with the WebView's observed, normalized metadata when it has arrived: a
        // queue entry can carry a title/artist YouTube has since refined, which makes the
        // providers match the wrong song (or nothing) and caches the miss.
        guard let metadata = self.playerService.lyricsSearchMetadata(for: videoId) else { return }
        self.lastLoadedVideoId = videoId
        self.lastLoadedSignature = self.lyricsSignature(for: videoId)
        let info = LyricsSearchInfo(title: metadata.title, artist: metadata.artist, album: track.album?.title, duration: self.playerService.duration > 0 ? self.playerService.duration : track.duration, videoId: videoId)
        if SettingsManager.shared.syncedLyricsEnabled { await self.syncedLyricsService.fetchLyrics(for: info, forceRefresh: forceRefresh) } else { self.syncedLyricsService.currentLyrics = .unavailable; self.syncedLyricsService.activeProvider = nil; self.syncedLyricsService.currentLyricsVideoId = videoId }
        guard self.lastLoadedVideoId == videoId, self.playerService.currentTrack?.videoId == videoId else { return }
        if case .unavailable = self.syncedLyricsService.currentLyrics { self.isLoadingFallback = false; return }
    }
}

@available(macOS 26.0, *)
private struct FullscreenSyncedLyricsView: View {
    let lyrics: SyncedLyrics
    let currentTimeMs: Int
    let isPlaying: Bool
    let onSeek: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Interpolated playback clock for the karaoke wipe. Owned here so the highlight
    /// survives line changes and re-renders.
    @State private var clock = LyricsPlaybackClock()
    /// Measured line layouts, kept across the sheet's re-renders.
    @State private var layoutCache = KaraokeLayoutCache()
    /// The line being sung: what the rows' emphasis and liveness are keyed to. It moves
    /// when the line it is on is settled, never `scrollLookaheadMs` ahead of it (see
    /// `KaraokeFillModel.highlightIndex(in:at:)`).
    @State private var currentLineId: UUID?
    @State private var currentLineIndex: Int?
    /// The line the sheet is scrolled to, which *does* lead playback by
    /// `KaraokeTiming.scrollLookaheadMs` so the line is in place when its first word is sung.
    @State private var scrollLineId: UUID?
    /// Whether the player is still putting itself in position: its first paint (a whole lyric
    /// sheet) is the most expensive frame of its life, so during that window the sheet *jumps*
    /// instead of scrolling. This is about where the sheet is, never about how a line changes —
    /// it must not gate the rows' emphasis (see the initializer).
    @State private var isSettling = true
    @State private var userIsScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?
    @State private var resumeScrollGeneration = 0
    @State private var hoveredLineId: UUID?

    /// Seeds the highlight from the playback position so the sheet's first frame is already
    /// the right one, which means the rows' emphasis animation never has to be switched off
    /// while the player opens — see `SyncedLyricsDisplayView.init` for the bug that caused.
    init(lyrics: SyncedLyrics, currentTimeMs: Int, isPlaying: Bool, onSeek: @escaping (Int) -> Void) {
        self.lyrics = lyrics
        self.currentTimeMs = currentTimeMs
        self.isPlaying = isPlaying
        self.onSeek = onSeek

        let scrollIndex = lyrics.currentLineIndex(at: currentTimeMs + Int(KaraokeTiming.standard.scrollLookaheadMs))
        _scrollLineId = State(initialValue: scrollIndex.map { lyrics.lines[$0].id })

        let highlightIndex = KaraokeFillModel.highlightIndex(in: lyrics, at: currentTimeMs)
        _currentLineIndex = State(initialValue: highlightIndex)
        _currentLineId = State(initialValue: highlightIndex.map { lyrics.lines[$0].id })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Spacer().frame(height: 28)
                    ForEach(Array(self.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        let status = self.currentStatus(for: index)
                        if self.lyrics.isPauseLine(at: index) {
                            KaraokeTimeSource(
                                line: line,
                                status: status,
                                isLive: self.isLive(lineIndex: index),
                                clock: self.clock,
                                minimumFrameInterval: self.frameInterval(lineIndex: index)
                            ) { displayTimeMs in
                                FullscreenPauseDotsLineView(
                                    dots: self.lyrics.pauseDots(forLineAt: index, at: Int(displayTimeMs)),
                                    status: status,
                                    isHovered: self.hoveredLineId == line.id
                                )
                            }
                            .animation(AppAnimation.lyricLine, value: self.currentLineIndex)
                            .animation(.easeOut(duration: 0.16), value: self.hoveredLineId)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onHover { isHovered in if status != .current { self.hoveredLineId = isHovered ? line.id : nil } }
                            .onTapGesture { self.onSeek(line.timeInMs) }
                            .id(line.id)
                        } else {
                            FullscreenSyncedLineView(
                                line: line,
                                status: status,
                                isLive: self.isLive(lineIndex: index),
                                clock: self.clock,
                                layoutCache: self.layoutCache,
                                minimumFrameInterval: self.frameInterval(lineIndex: index),
                                emphasis: self.karaokeEmphasis
                            )
                            .foregroundStyle(.white)
                            .opacity(self.opacity(for: status, lineId: line.id))
                            .scaleEffect(self.scale(for: status, lineId: line.id), anchor: .leading)
                            // Distant lines recede out of focus the way Apple Music lets go
                            // of the lines around the one being sung.
                            .blur(radius: self.blur(for: status))
                            .animation(AppAnimation.lyricLine, value: self.currentLineIndex)
                            .animation(.easeOut(duration: 0.16), value: self.hoveredLineId)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onHover { isHovered in if status != .current { self.hoveredLineId = isHovered ? line.id : nil } }
                            .onTapGesture { self.onSeek(line.timeInMs) }
                            .id(line.id)
                        }
                    }
                    // The submitter credit sits at the end of the sheet, out of the
                    // way until the reader reaches the bottom.
                    if let attribution = self.lyrics.attribution, attribution.hasSubmitter {
                        LyricsSubmitterCredit(attribution: attribution, color: .white.opacity(0.55))
                            .padding(.top, 28)
                    }

                    Spacer().frame(height: 84)
                }
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting:
                    self.userIsScrolling = true
                    self.resumeScrollGeneration += 1
                    self.scrollResumeTask?.cancel()
                case .decelerating:
                    let generation = self.resumeScrollGeneration
                    self.scrollResumeTask?.cancel()
                    self.scrollResumeTask = Task {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }
                        self.userIsScrolling = false
                        if let scrollLineId = self.scrollLineId {
                            withAnimation(.easeInOut(duration: 0.42)) {
                                proxy.scrollTo(scrollLineId, anchor: .center)
                            }
                        }
                    }
                default:
                    break
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 1).onChanged { _ in self.userIsScrolling = true; self.resumeScrollGeneration += 1; self.scrollResumeTask?.cancel() }.onEnded { _ in let generation = self.resumeScrollGeneration; self.scrollResumeTask = Task { try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }; self.userIsScrolling = false; if let scrollLineId = self.scrollLineId { withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(scrollLineId, anchor: .center) } } } })
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                self.receiveClockSample(timeMs: newTimeMs, isPlaying: self.isPlaying)
                self.syncCurrentLine(using: newTimeMs, proxy: proxy, animate: !self.userIsScrolling)
            }
            .onChange(of: self.isPlaying) { _, newIsPlaying in
                // The poll keeps reporting the same position while paused, so freezing
                // the clock takes the play state rather than a fresh sample.
                self.receiveClockSample(timeMs: self.currentTimeMs, isPlaying: newIsPlaying)
            }
            .onChange(of: self.lyrics) { _, _ in
                // A new track's lyrics start at zero: without this the old clock
                // position would flash the new first line as already sung.
                self.clock.reset()
                self.receiveClockSample(timeMs: self.currentTimeMs, isPlaying: self.isPlaying)
                self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false)
                Task { await self.settleScroll(using: proxy) }
            }
            .onAppear {
                self.receiveClockSample(timeMs: self.currentTimeMs, isPlaying: self.isPlaying)
                self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false)
            }
            .task {
                await self.settleScroll(using: proxy)
            }
            .onDisappear { self.scrollResumeTask?.cancel(); self.hoveredLineId = nil }
        }
    }
    /// How often a row may redraw, while it is live. A settled row is paused rather than
    /// removed (see `KaraokeTimeSource`), so this is only about the rate a row that *is*
    /// drawing gets: the line being sung at the full live rate, and any other row that is on
    /// the clock at the cheaper armed rate, which loses nothing because the transitions on
    /// them are Core Animation's rather than redraws of their own.
    private func frameInterval(lineIndex: Int) -> Double? {
        if self.reduceMotion { return KaraokeFrameBudget.reducedMotion }
        if !self.isPlaying { return KaraokeFrameBudget.paused }
        return lineIndex == self.currentLineIndex ? KaraokeFrameBudget.live : KaraokeFrameBudget.armed
    }
    private var karaokeEmphasis: Double { self.reduceMotion ? 0 : 1 }

    private func receiveClockSample(timeMs: Int, isPlaying: Bool) { self.clock.receive(LyricsClockSample(hostTime: Date(), timeMs: timeMs, isPlaying: isPlaying)) }

    /// Puts the sheet in position after it appears or is replaced, and turns the sheet's
    /// transitions back on once it has. A jump is repeated because the lazy stack usually
    /// has not materialized the scroll target yet, and scrolling to a row that does not
    /// exist does nothing; jumping never animates, so repeating it is invisible.
    private func settleScroll(using proxy: ScrollViewProxy) async {
        self.isSettling = true
        defer { self.isSettling = false }

        // Bounded by wall clock rather than by iteration count, so a busy main thread (the
        // very thing this window is for) cannot stretch how long scrolls jump instead of
        // animating.
        let deadline = Date().addingTimeInterval(0.6)
        for _ in 0 ..< 10 {
            guard !Task.isCancelled, !self.userIsScrolling else { return }
            await Task.yield()
            if let scrollLineId = self.scrollLineId {
                proxy.scrollTo(scrollLineId, anchor: .center)
            }
            guard Date() < deadline else { return }
            try? await Task.sleep(for: .milliseconds(70))
        }
    }
    private func currentStatus(for lineIndex: Int) -> SyncedLyrics.LineStatus { guard let currentLineIndex else { return .upcoming }; if lineIndex < currentLineIndex { return .previous }; if lineIndex == currentLineIndex { return .current }; return .upcoming }
    /// Whether this row draws from the live display clock: the line being sung, the line
    /// after it (so a line is never first seen part-way through its own first word), and
    /// the line that has just finished until the clock is past its end — see
    /// `KaraokeFillModel.isLiveRow` for why that last one keeps its scale-down smooth.
    private func isLive(lineIndex: Int) -> Bool {
        let line = self.lyrics.lines.indices.contains(lineIndex) ? self.lyrics.lines[lineIndex] : nil
        return KaraokeFillModel.isLiveRow(
            lineIndex: lineIndex,
            currentLineIndex: self.currentLineIndex,
            line: line,
            clockMs: self.clock.displayPositionMs
        )
    }
    private func scale(for status: SyncedLyrics.LineStatus, lineId: UUID) -> CGFloat { if self.hoveredLineId == lineId, status != .current { return 0.985 }; return switch status { case .current: 1; case .previous: 0.95; case .upcoming: 0.965 } }
    private func opacity(for status: SyncedLyrics.LineStatus, lineId: UUID) -> Double { if self.hoveredLineId == lineId, status != .current { return 0.78 }; return switch status { case .current: 1; case .previous: 0.35; case .upcoming: 0.55 } }
    private func blur(for status: SyncedLyrics.LineStatus) -> CGFloat { self.reduceMotion || status == .current ? 0 : 0.6 }
    private func syncCurrentLine(using timeMs: Int, proxy: ScrollViewProxy, animate: Bool) {
        self.updateHighlight(using: timeMs)

        // The scroll follows slightly ahead of the line's own start so it lands with the
        // first word instead of a poll interval after it. Only the scroll leads.
        let lookahead = Int(KaraokeTiming.standard.scrollLookaheadMs)
        guard let scrollIndex = self.lyrics.currentLineIndex(at: timeMs + lookahead) else { return }
        let newId = self.lyrics.lines[scrollIndex].id
        let targetChanged = newId != self.scrollLineId
        self.scrollLineId = newId
        guard targetChanged else { return }
        guard !self.userIsScrolling else { return }
        // While the player is still opening, jump: an animated scroll competing with the
        // sheet's first paint is what made opening it stutter.
        if animate, !self.isSettling {
            withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(newId, anchor: .center) }
        } else {
            proxy.scrollTo(newId, anchor: .center)
        }
    }

    /// Moves the highlight onto the line being sung, which happens when the previous line's
    /// content is settled rather than `scrollLookaheadMs` before that — a line that starts to
    /// leave while it is still being sung never reaches its sung state.
    private func updateHighlight(using timeMs: Int) {
        guard let index = KaraokeFillModel.highlightIndex(in: self.lyrics, at: timeMs) else { return }
        self.currentLineIndex = index
        self.currentLineId = self.lyrics.lines[index].id
    }
}

@available(macOS 26.0, *)
private struct FullscreenSyncedLineView: View {
    let line: SyncedLyricLine
    let status: SyncedLyrics.LineStatus
    let isLive: Bool
    let clock: LyricsPlaybackClock
    /// Measured line layouts, so a re-render of the sheet never measures a line again.
    let layoutCache: KaraokeLayoutCache
    let minimumFrameInterval: Double?
    let emphasis: Double

    private static let fontSize: CGFloat = 36

    var body: some View {
        // Measured once per line, not once per frame or per sheet re-render. The backing
        // vocal is measured at its own smaller size — the cache keys by size, so the two
        // layouts of one row never evict each other.
        let layout = self.layoutCache.layout(for: self.line, fontSize: Self.fontSize)
        let backgroundLayout = self.layoutCache.backgroundLayout(
            for: self.line,
            fontSize: Self.fontSize * Self.backgroundFontSizeRatio
        )

        return KaraokeTimeSource(
            line: self.line,
            words: layout.words,
            status: self.status,
            isLive: self.isLive,
            clock: self.clock,
            minimumFrameInterval: self.minimumFrameInterval
        ) { displayTimeMs in
            let hasLead = !self.line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if !hasLead, backgroundLayout == nil {
                // A short instrumental gap that is not long enough for the pause dots.
                Text("♪")
                    .font(.system(size: Self.fontSize, weight: .bold))
                    .lineSpacing(18)
                    .foregroundStyle(.white)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if hasLead {
                        KaraokeLyricsLineView(
                            layout: layout,
                            displayTimeMs: displayTimeMs,
                            color: .white,
                            emphasis: self.emphasis,
                            lineSpacing: 18
                        )
                    }
                    if let backgroundLayout {
                        // The backing vocal runs the same per-character wipe as the lead,
                        // driven by the same display clock position — it overlaps the line
                        // in time, so synchrony is simply sharing the clock. It is dimmer
                        // and smaller so it reads as accompaniment, nothing else differs.
                        KaraokeLyricsLineView(
                            layout: backgroundLayout,
                            displayTimeMs: displayTimeMs,
                            color: .white.opacity(0.55),
                            emphasis: self.emphasis,
                            lineSpacing: 8
                        )
                    }
                }
            }
        }
        .offset(y: self.drift)
    }

    private static let backgroundFontSizeRatio: CGFloat = 0.62

    /// Neighbouring lines sit slightly off their slot, so a line settles into place
    /// as it becomes the line being sung.
    private var drift: CGFloat {
        switch self.status {
        case .current: 0
        case .previous: -5
        case .upcoming: 5
        }
    }
}

@available(macOS 26.0, *)
private struct FullscreenPauseDotsLineView: View {
    let dots: SyncedLyrics.PauseDots
    let status: SyncedLyrics.LineStatus
    let isHovered: Bool
    var body: some View { HStack(spacing: 9) { ForEach(0 ..< 3, id: \.self) { dotIndex in self.dotView(for: self.status(of: dotIndex)) } }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13).opacity(self.lineOpacity(for: self.status, isHovered: self.isHovered)).scaleEffect(self.lineScale(for: self.status, isHovered: self.isHovered), anchor: .leading).animation(.easeInOut(duration: 0.35), value: self.dots.statuses).animation(.easeInOut(duration: 0.35), value: self.status) }
    /// The bounce is a value off the row's own display clock rather than a timeline of its own:
    /// the row is already redrawing per frame while it is the one being sung, and two clocks on
    /// one row are two chances to disagree about when that is.
    @ViewBuilder private func dotView(for dotStatus: SyncedLyrics.PauseDotStatus) -> some View { Circle().fill(Color.white).frame(width: 13, height: 13).opacity(self.dotOpacity(for: dotStatus)).offset(y: dotStatus == .active ? -5.2 * self.dots.lift : 0) }
    private func status(of index: Int) -> SyncedLyrics.PauseDotStatus { self.dots.statuses.indices.contains(index) ? self.dots.statuses[index] : .notSung }
    private func dotOpacity(for status: SyncedLyrics.PauseDotStatus) -> Double { switch status { case .notSung: 0.28; case .active: 1; case .sung: 0.65 } }
    private func lineScale(for status: SyncedLyrics.LineStatus, isHovered: Bool) -> CGFloat { if isHovered, status != .current { return 0.985 }; return switch status { case .current: 1; case .previous: 0.95; case .upcoming: 0.965 } }
    private func lineOpacity(for status: SyncedLyrics.LineStatus, isHovered: Bool) -> Double { if isHovered, status != .current { return 0.78 }; return switch status { case .current: 1; case .previous: 0.35; case .upcoming: 0.55 } }
}
