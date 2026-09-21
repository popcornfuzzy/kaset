import AppKit
import SwiftUI

/// In-window fullscreen now-playing experience with artwork, synced lyrics, and transport controls.
@available(macOS 26.0, *)
struct FullscreenNowPlayingView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService
    @Environment(CanvasService.self) private var canvasService

    let client: any YTMusicClientProtocol

    private enum Layout {
        /// Largest square the artwork card can take. Also the card's decode target: on a Retina display the
        /// card draws at up to 760px, so leaving the default 320 (a 640px cap) made the still — the largest
        /// artwork surface in the app — render slightly upscaled from its own downloaded data.
        static let artworkMaxDimension: CGFloat = 380
    }

    @State private var lastLoadedVideoId: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var isLoadingFallback = false
    @State private var seekValue: Double = 0
    @State private var lyricsTimeMs: Int = 0
    @State private var isSeeking = false
    @State private var escapeKeyMonitor: Any?
    @State private var canvasReady = false
    @State private var canvasFailed = false

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
        }
        .onChange(of: self.playerService.currentTrack?.title) { _, _ in
            guard let videoId = self.playerService.currentTrack?.videoId,
                  videoId != self.lastLoadedVideoId
            else { return }
            self.startLyricsLoad(for: videoId)
        }
        .onChange(of: self.playerService.duration) { _, newDuration in
            guard newDuration > 0,
                  let videoId = self.playerService.currentTrack?.videoId,
                  videoId != self.lastLoadedVideoId
            else { return }
            self.startLyricsLoad(for: videoId)
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
            self.artworkCard.frame(minWidth: mediaWidth, idealWidth: mediaWidth, maxWidth: mediaWidth, maxHeight: artworkMaxHeight).padding(.bottom, 12)
            self.trackMeta.frame(width: mediaWidth, alignment: .leading)
            self.transportControls(contentWidth: mediaWidth).frame(width: mediaWidth).padding(.top, 6)
        }
        .frame(width: width, height: availableHeight, alignment: .center)
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
            // The YouTube Music still album art is always the base layer; the
            // animated canvas crossfades in above it once ready.
            CachedAsyncImage(
                url: self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL,
                fallbackURL: self.playerService.currentTrack?.thumbnailURL,
                identity: self.playerService.currentTrack?.videoId,
                targetSize: CGSize(width: Layout.artworkMaxDimension, height: Layout.artworkMaxDimension)
            ) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                ZStack { RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.08)); CassetteIcon(size: 76).foregroundStyle(.white.opacity(0.7)) }
            }

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
        .clipShape(RoundedRectangle(cornerRadius: 22)).aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
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
                Button { HapticService.toggle(); self.playerService.dislikeCurrentTrack() } label: { Image(systemName: self.playerService.currentTrackLikeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown").font(.system(size: 18, weight: .semibold)).foregroundStyle(self.playerService.currentTrackLikeStatus == .dislike ? .red : .white) }.buttonStyle(.plain)
                Button { HapticService.toggle(); self.playerService.toggleShuffle() } label: { Image(systemName: "shuffle").font(.system(size: 17, weight: .semibold)).foregroundStyle(self.playerService.shuffleEnabled ? .red : .white) }.buttonStyle(.plain)
                Button { HapticService.playback(); Task { await self.playerService.previous() } } label: { Image(systemName: "backward.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white) }.buttonStyle(.plain)
                Button { HapticService.playback(); Task { await self.playerService.playPause() } } label: { Image(systemName: self.playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 54)).foregroundStyle(.white) }.buttonStyle(.plain)
                Button { HapticService.playback(); Task { await self.playerService.next() } } label: { Image(systemName: "forward.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white) }.buttonStyle(.plain)
                Button { HapticService.toggle(); self.playerService.cycleRepeatMode() } label: { Image(systemName: self.repeatIcon).font(.system(size: 17, weight: .semibold)).foregroundStyle(self.playerService.repeatMode != .off ? .red : .white) }.buttonStyle(.plain)
                Button { HapticService.toggle(); self.playerService.likeCurrentTrack() } label: { Image(systemName: self.playerService.currentTrackLikeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup").font(.system(size: 18, weight: .semibold)).foregroundStyle(self.playerService.currentTrackLikeStatus == .like ? .red : .white) }.buttonStyle(.plain)
            }.frame(width: contentWidth)
        }
    }

    private var lyricsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if self.syncedLyricsService.searchingForBetterLyrics {
                ShimmerLine(text: String(localized: "Still searching for lyrics"))
                    .padding(.horizontal, 8)
            }
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
                        ScrollView { Text(plain.text).font(.system(size: 36, weight: .bold)).lineSpacing(18).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12) }.scrollIndicators(.hidden).mask(self.lyricsFadeMask)
                    case .unavailable:
                        self.emptyLyricsState(icon: "quote.bubble", title: String(localized: "No Lyrics Available"), message: self.syncedLyricsService.errorMessage ?? String(localized: "Try another song to see synced lyrics here."))
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var lyricsFadeMask: some View { LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) }

    private func emptyLyricsState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) { Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.white.opacity(0.7)); Text(title).font(.headline).foregroundStyle(.white.opacity(0.9)); Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal, 20) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var normalizedProgress: Double { guard self.playerService.duration > 0 else { return 0 }; return min(max(self.playerService.progress / self.playerService.duration, 0), 1) }
    private var repeatIcon: String { switch self.playerService.repeatMode { case .off, .all: "repeat"; case .one: "repeat.1" } }
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
        self.installEscapeKeyMonitorIfNeeded()
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
        self.removeEscapeKeyMonitor()
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
    private func startLyricsLoad(for videoId: String?) {
        self.loadTask?.cancel()
        self.loadTask = nil
        guard let videoId, videoId != self.lastLoadedVideoId else { return }
        self.loadTask = Task { await self.loadLyricsWhenReady(for: videoId) }
    }

    private func installEscapeKeyMonitorIfNeeded() { guard self.escapeKeyMonitor == nil else { return }; self.escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in if event.keyCode == 53 { self.closeFullscreenNowPlaying(); return nil }; return event } }
    private func removeEscapeKeyMonitor() { guard let monitor = self.escapeKeyMonitor else { return }; NSEvent.removeMonitor(monitor); self.escapeKeyMonitor = nil }

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
    private func loadLyricsWhenReady(for videoId: String) async {
        for _ in 0 ..< 40 {
            guard !Task.isCancelled,
                  self.playerService.currentTrack?.videoId == videoId
            else { return }
            if let track = self.playerService.currentTrack,
               !track.title.isEmpty,
               track.title != "Loading...",
               !track.artistsDisplay.isEmpty
            {
                await self.loadLyrics(for: videoId)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor
    private func loadLyrics(for videoId: String) async {
        self.isLoadingFallback = false
        guard let track = self.playerService.currentTrack, track.videoId == videoId else { return }
        guard !track.title.isEmpty,
              track.title != "Loading...",
              !track.artistsDisplay.isEmpty
        else { return }
        self.lastLoadedVideoId = videoId
        let info = LyricsSearchInfo(title: track.title, artist: track.artistsDisplay, album: track.album?.title, duration: self.playerService.duration > 0 ? self.playerService.duration : track.duration, videoId: track.videoId)
        if SettingsManager.shared.syncedLyricsEnabled { await self.syncedLyricsService.fetchLyrics(for: info) } else { self.syncedLyricsService.currentLyrics = .unavailable; self.syncedLyricsService.activeProvider = nil; self.syncedLyricsService.currentLyricsVideoId = videoId }
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
    @State private var currentLineId: UUID?
    @State private var currentLineIndex: Int?
    /// Whether the player is still opening: its first paint (a whole lyric sheet) is the
    /// most expensive frame of its life, so during that window the sheet jumps instead of
    /// scrolling and applies the highlight without a spring.
    @State private var isSettling = true
    @State private var userIsScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?
    @State private var resumeScrollGeneration = 0
    @State private var hoveredLineId: UUID?

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
                                    dotStatuses: self.lyrics.pauseDotStatuses(forLineAt: index, at: Int(displayTimeMs)),
                                    status: status,
                                    isHovered: self.hoveredLineId == line.id,
                                    minimumFrameInterval: self.frameInterval(lineIndex: index, animatesWhilePaused: true)
                                )
                            }
                            .animation(self.isSettling ? nil : AppAnimation.lyricLine, value: self.currentLineIndex)
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
                            .animation(self.isSettling ? nil : AppAnimation.lyricLine, value: self.currentLineIndex)
                            .animation(.easeOut(duration: 0.16), value: self.hoveredLineId)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onHover { isHovered in if status != .current { self.hoveredLineId = isHovered ? line.id : nil } }
                            .onTapGesture { self.onSeek(line.timeInMs) }
                            .id(line.id)
                        }
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
                        if let currentLineId = self.currentLineId {
                            withAnimation(.easeInOut(duration: 0.42)) {
                                proxy.scrollTo(currentLineId, anchor: .center)
                            }
                        }
                    }
                default:
                    break
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 1).onChanged { _ in self.userIsScrolling = true; self.resumeScrollGeneration += 1; self.scrollResumeTask?.cancel() }.onEnded { _ in let generation = self.resumeScrollGeneration; self.scrollResumeTask = Task { try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }; self.userIsScrolling = false; if let currentLineId = self.currentLineId { withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(currentLineId, anchor: .center) } } } })
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
    /// How often a row may redraw. The line being sung gets the full live rate; the line
    /// after it and the line that has just finished (while it settles) lean on the same
    /// clock at the cheaper *armed* rate, which loses nothing because the transitions on
    /// them are Core Animation's rather than redraws of their own.
    /// - Parameter animatesWhilePaused: the bouncing pause dot is decorative motion that
    ///   only exists while it is moving, so it keeps its rate when playback is paused.
    private func frameInterval(lineIndex: Int, animatesWhilePaused: Bool = false) -> Double? {
        guard let currentLineIndex, self.isLive(lineIndex: lineIndex) else { return nil }
        if self.reduceMotion { return KaraokeFrameBudget.reducedMotion }
        if !self.isPlaying, !animatesWhilePaused { return KaraokeFrameBudget.paused }
        return lineIndex == currentLineIndex ? KaraokeFrameBudget.live : KaraokeFrameBudget.armed
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

        for _ in 0 ..< 6 {
            guard !Task.isCancelled, !self.userIsScrolling else { return }
            await Task.yield()
            if let currentLineId = self.currentLineId {
                proxy.scrollTo(currentLineId, anchor: .center)
            }
            try? await Task.sleep(for: .milliseconds(80))
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
            lineEndMs: line.map { Double($0.timeInMs + max($0.duration, 0)) },
            clockMs: self.clock.displayPositionMs
        )
    }
    private func scale(for status: SyncedLyrics.LineStatus, lineId: UUID) -> CGFloat { if self.hoveredLineId == lineId, status != .current { return 0.985 }; return switch status { case .current: 1; case .previous: 0.95; case .upcoming: 0.965 } }
    private func opacity(for status: SyncedLyrics.LineStatus, lineId: UUID) -> Double { if self.hoveredLineId == lineId, status != .current { return 0.78 }; return switch status { case .current: 1; case .previous: 0.35; case .upcoming: 0.55 } }
    private func blur(for status: SyncedLyrics.LineStatus) -> CGFloat { self.reduceMotion || status == .current ? 0 : 0.6 }
    private func syncCurrentLine(using timeMs: Int, proxy: ScrollViewProxy, animate: Bool) {
        // Follow slightly ahead of the line's own start so the scroll lands with the
        // first word instead of a poll interval after it.
        let lookahead = Int(KaraokeTiming.standard.scrollLookaheadMs)
        guard let currentIdx = self.lyrics.currentLineIndex(at: timeMs + lookahead) else { return }
        let newId = self.lyrics.lines[currentIdx].id
        self.currentLineIndex = currentIdx
        guard newId != self.currentLineId else { return }
        self.currentLineId = newId
        guard !self.userIsScrolling else { return }
        // While the player is still opening, jump: an animated scroll competing with the
        // sheet's first paint is what made opening it stutter.
        if animate, !self.isSettling {
            withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(newId, anchor: .center) }
        } else {
            proxy.scrollTo(newId, anchor: .center)
        }
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
        // Measured once per line, not once per frame or per sheet re-render.
        let layout = self.layoutCache.layout(for: self.line, fontSize: Self.fontSize)

        return KaraokeTimeSource(
            line: self.line,
            words: layout.words,
            status: self.status,
            isLive: self.isLive,
            clock: self.clock,
            minimumFrameInterval: self.minimumFrameInterval
        ) { displayTimeMs in
            if self.line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A short instrumental gap that is not long enough for the pause dots.
                Text("♪")
                    .font(.system(size: Self.fontSize, weight: .bold))
                    .lineSpacing(18)
                    .foregroundStyle(.white)
            } else {
                KaraokeLyricsLineView(
                    layout: layout,
                    displayTimeMs: displayTimeMs,
                    color: .white,
                    emphasis: self.emphasis,
                    lineSpacing: 18
                )
            }
        }
        .offset(y: self.drift)
    }

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
    let dotStatuses: [SyncedLyrics.PauseDotStatus]
    let status: SyncedLyrics.LineStatus
    let isHovered: Bool
    /// The bouncing dot is the only thing here that redraws; it shares the karaoke
    /// frame budget rather than running at the display's refresh rate.
    var minimumFrameInterval: Double?
    var body: some View { HStack(spacing: 9) { ForEach(0 ..< 3, id: \.self) { dotIndex in self.dotView(for: self.safeDotStatus(at: dotIndex)) } }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13).opacity(self.lineOpacity(for: self.status, isHovered: self.isHovered)).scaleEffect(self.lineScale(for: self.status, isHovered: self.isHovered), anchor: .leading).animation(.easeInOut(duration: 0.35), value: self.dotStatuses).animation(.easeInOut(duration: 0.35), value: self.status) }
    @ViewBuilder private func dotView(for dotStatus: SyncedLyrics.PauseDotStatus) -> some View { let dot = Circle().fill(Color.white).frame(width: 13, height: 13).opacity(self.dotOpacity(for: dotStatus)); if dotStatus == .active { TimelineView(.animation(minimumInterval: self.minimumFrameInterval)) { timeline in let elapsed = timeline.date.timeIntervalSinceReferenceDate; let phase = elapsed.truncatingRemainder(dividingBy: 0.72) / 0.72; dot.offset(y: -5.2 * (0.5 + 0.5 * sin(phase * 2 * .pi))) } } else { dot } }
    private func safeDotStatus(at index: Int) -> SyncedLyrics.PauseDotStatus { self.dotStatuses.indices.contains(index) ? self.dotStatuses[index] : .notSung }
    private func dotOpacity(for status: SyncedLyrics.PauseDotStatus) -> Double { switch status { case .notSung: 0.28; case .active: 1; case .sung: 0.65 } }
    private func lineScale(for status: SyncedLyrics.LineStatus, isHovered: Bool) -> CGFloat { if isHovered, status != .current { return 0.985 }; return switch status { case .current: 1; case .previous: 0.95; case .upcoming: 0.965 } }
    private func lineOpacity(for status: SyncedLyrics.LineStatus, isHovered: Bool) -> Double { if isHovered, status != .current { return 0.78 }; return switch status { case .current: 1; case .previous: 0.35; case .upcoming: 0.55 } }
}
