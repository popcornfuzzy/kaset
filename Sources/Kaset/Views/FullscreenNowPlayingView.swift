import AppKit
import SwiftUI

/// In-window fullscreen now-playing experience with artwork, synced lyrics, and transport controls.
@available(macOS 26.0, *)
struct FullscreenNowPlayingView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService

    let client: any YTMusicClientProtocol

    @State private var lastLoadedVideoId: String?
    @State private var isLoadingFallback = false
    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var escapeKeyMonitor: Any?

    var body: some View {
        GeometryReader { proxy in
            let stageWidth = min(max(860, proxy.size.width - 64), 1480)
            let stageHeight = min(max(500, proxy.size.height - 96), 900)
            let panelSpacing = max(20, min(36, stageWidth * 0.028))
            let artworkColumnWidth = floor(stageWidth * 0.40)
            let lyricsColumnWidth = max(320, stageWidth - artworkColumnWidth - panelSpacing)

            ZStack {
                self.backgroundLayer

                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        self.closeButton
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 14)

                    HStack(alignment: .center, spacing: panelSpacing) {
                        self.leftColumn(width: artworkColumnWidth, availableHeight: stageHeight)
                            .frame(width: artworkColumnWidth, height: stageHeight, alignment: .center)

                        self.lyricsPanel
                            .frame(width: lyricsColumnWidth, height: stageHeight, alignment: .leading)
                    }
                    .frame(width: stageWidth, height: stageHeight, alignment: .center)
                    .padding(.top, 8)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .onExitCommand {
            self.closeFullscreenNowPlaying()
        }
        .onAppear {
            self.seekValue = self.normalizedProgress
            self.updateLyricsPolling(for: self.syncedLyricsService.currentLyrics)
            self.installEscapeKeyMonitorIfNeeded()
        }
        .onChange(of: self.playerService.progress) { _, _ in
            if !self.isSeeking {
                self.seekValue = self.normalizedProgress
            }
        }
        .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
            if let videoId = newVideoId, videoId != self.lastLoadedVideoId {
                Task {
                    await self.loadLyrics(for: videoId)
                }
            }
        }
        .onChange(of: self.syncedLyricsService.currentLyrics) { _, newLyrics in
            self.updateLyricsPolling(for: newLyrics)
        }
        .task {
            if let videoId = self.playerService.currentTrack?.videoId {
                await self.loadLyrics(for: videoId)
            }
        }
        .onDisappear {
            self.removeEscapeKeyMonitor()
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            if let thumbnailURL = self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL {
                CachedAsyncImage(url: thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.black)
                }
                .blur(radius: 68)
                .scaleEffect(1.18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                LinearGradient(
                    colors: [.black, .gray.opacity(0.6), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            Rectangle()
                .fill(.black.opacity(0.48))

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.35), .clear, .black.opacity(0.45)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    private func leftColumn(width: CGFloat, availableHeight: CGFloat) -> some View {
        let columnSpacing = max(10, min(16, availableHeight * 0.018))
        let artworkMaxHeight = min(max(180, availableHeight * 0.42), 340)
        let mediaWidth = min(width, 390)

        return VStack(alignment: .leading, spacing: columnSpacing) {
            self.artworkCard
                .frame(minWidth: mediaWidth, idealWidth: mediaWidth, maxWidth: mediaWidth, maxHeight: artworkMaxHeight, alignment: .topLeading)

            self.trackMeta
                .frame(width: mediaWidth, alignment: .leading)

            self.transportControls
                .frame(width: mediaWidth, alignment: .leading)
        }
        .frame(width: width, height: availableHeight, alignment: .center)
    }

    private var closeButton: some View {
        Button {
            self.closeFullscreenNowPlaying()
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(10)
                .background(.black.opacity(0.36), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Exit Fullscreen Now Playing"))
    }

    private var artworkCard: some View {
        CachedAsyncImage(url: self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.white.opacity(0.08))
                CassetteIcon(size: 76)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    private var trackMeta: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.playerService.currentTrack?.title ?? String(localized: "No Song Playing"))
                .font(.system(size: 30, weight: .bold))
                .lineLimit(2)
                .foregroundStyle(.white)

            Text(self.playerService.currentTrack?.artistsDisplay.isEmpty == false ? self.playerService.currentTrack?.artistsDisplay ?? "" : String(localized: "Unknown Artist"))
                .font(.system(size: 17, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    private var transportControls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Text(self.formatTime(self.playerService.progress))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                Slider(
                    value: self.$seekValue,
                    in: 0 ... 1,
                    onEditingChanged: { isEditing in
                        self.isSeeking = isEditing
                        if !isEditing {
                            Task {
                                let target = self.seekValue * self.playerService.duration
                                await self.playerService.seek(to: target)
                            }
                        }
                    }
                )
                .tint(.white)
                .disabled(self.playerService.duration <= 0)

                Text(self.formatTime(max(0, self.playerService.duration - self.playerService.progress)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }

            HStack(spacing: 22) {
                Button {
                    HapticService.toggle()
                    self.playerService.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(self.playerService.shuffleEnabled ? .red : .white)
                }
                .buttonStyle(.plain)

                Button {
                    HapticService.playback()
                    Task {
                        await self.playerService.previous()
                    }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    HapticService.playback()
                    Task {
                        await self.playerService.playPause()
                    }
                } label: {
                    Image(systemName: self.playerService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 58, weight: .regular))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    HapticService.playback()
                    Task {
                        await self.playerService.next()
                    }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    HapticService.toggle()
                    self.playerService.cycleRepeatMode()
                } label: {
                    Image(systemName: self.repeatIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(self.playerService.repeatMode != .off ? .red : .white)
                }
                .buttonStyle(.plain)

                Button {
                    HapticService.toggle()
                    self.playerService.likeCurrentTrack()
                } label: {
                    Image(systemName: self.playerService.currentTrackLikeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(self.playerService.currentTrackLikeStatus == .like ? .red : .white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private var lyricsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if self.playerService.currentTrack == nil {
                    self.emptyLyricsState(
                        icon: "play.circle",
                        title: String(localized: "No Song Playing"),
                        message: String(localized: "Play a song to view synced lyrics.")
                    )
                } else if self.syncedLyricsService.isLoading || self.isLoadingFallback {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(String(localized: "Loading lyrics..."))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch self.syncedLyricsService.currentLyrics {
                    case let .synced(synced):
                        FullscreenSyncedLyricsView(
                            lyrics: synced,
                            currentTimeMs: self.effectiveLyricsTimeMs,
                            onSeek: { timeMs in
                                Task {
                                    await self.playerService.seek(to: Double(timeMs) / 1000.0)
                                }
                            }
                        )
                        .background(.clear)
                    case let .plain(plain):
                        ScrollView {
                            Text(plain.text)
                                .font(.system(size: 44, weight: .bold))
                                .lineSpacing(18)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        }
                        .scrollIndicators(.hidden)
                    case .unavailable:
                        self.emptyLyricsState(
                            icon: "quote.bubble",
                            title: String(localized: "No Lyrics Available"),
                            message: String(localized: "Try another song to see synced lyrics here.")
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func emptyLyricsState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.7))

            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var normalizedProgress: Double {
        guard self.playerService.duration > 0 else { return 0 }
        return min(max(self.playerService.progress / self.playerService.duration, 0), 1)
    }

    private var effectiveLyricsTimeMs: Int {
        max(self.playerService.currentTimeMs, Int(self.playerService.progress * 1000.0))
    }

    private var repeatIcon: String {
        switch self.playerService.repeatMode {
        case .off, .all:
            "repeat"
        case .one:
            "repeat.1"
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let totalSeconds = max(Int(time), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func updateLyricsPolling(for result: LyricResult) {
        if case .synced = result {
            SingletonPlayerWebView.shared.startLyricsPoll()
        } else {
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
    }

    private func closeFullscreenNowPlaying() {
        withAnimation(AppAnimation.standard) {
            self.playerService.showFullscreenNowPlaying = false
        }
    }

    private func installEscapeKeyMonitorIfNeeded() {
        guard self.escapeKeyMonitor == nil else { return }

        self.escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                self.closeFullscreenNowPlaying()
                return nil
            }
            return event
        }
    }

    private func removeEscapeKeyMonitor() {
        guard let monitor = self.escapeKeyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        self.escapeKeyMonitor = nil
    }

    @MainActor
    private func loadLyrics(for videoId: String) async {
        self.lastLoadedVideoId = videoId
        self.isLoadingFallback = false

        guard let track = self.playerService.currentTrack else { return }
        guard track.videoId == videoId else { return }

        let info = LyricsSearchInfo(
            title: track.title,
            artist: track.artistsDisplay,
            album: track.album?.title,
            duration: track.duration,
            videoId: track.videoId
        )

        if SettingsManager.shared.syncedLyricsEnabled {
            await self.syncedLyricsService.fetchLyrics(for: info)
        } else {
            self.syncedLyricsService.currentLyrics = .unavailable
            self.syncedLyricsService.activeProvider = nil
        }

        guard self.lastLoadedVideoId == videoId else { return }
        guard self.playerService.currentTrack?.videoId == videoId else { return }

        if case .unavailable = self.syncedLyricsService.currentLyrics {
            self.isLoadingFallback = true
            defer {
                if self.lastLoadedVideoId == videoId {
                    self.isLoadingFallback = false
                }
            }

            do {
                let fetchedLyrics = try await self.client.getLyrics(videoId: videoId)
                if self.lastLoadedVideoId == videoId,
                   self.playerService.currentTrack?.videoId == videoId
                {
                    self.syncedLyricsService.fallbackToPlainLyrics(fetchedLyrics, videoId: videoId)
                }
            } catch {
                DiagnosticsLogger.api.error("Failed to load plain lyrics fallback: \(error.localizedDescription)")
            }
        }
    }
}

@available(macOS 26.0, *)
private struct FullscreenSyncedLyricsView: View {
    let lyrics: SyncedLyrics
    let currentTimeMs: Int
    let onSeek: (Int) -> Void

    @State private var currentLineId: UUID?
    @State private var currentLineIndex: Int?
    @State private var userIsScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Spacer().frame(height: 28)

                    ForEach(Array(self.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        let status = self.currentStatus(for: index)

                        Text(line.text.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : line.text)
                            .font(.system(size: 52, weight: .bold))
                            .foregroundStyle(.white)
                            .lineSpacing(8)
                            .opacity(self.opacity(for: status))
                            .scaleEffect(self.scale(for: status), anchor: .leading)
                            .animation(.easeInOut(duration: 0.4), value: self.currentLineIndex)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                self.onSeek(line.timeInMs)
                            }
                            .id(line.id)
                    }

                    Spacer().frame(height: 84)
                }
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        self.userIsScrolling = true
                        self.scrollResumeTask?.cancel()
                    }
                    .onEnded { _ in
                        self.scrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            if !Task.isCancelled {
                                self.userIsScrolling = false
                            }
                        }
                    }
            )
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                guard let currentIdx = self.lyrics.currentLineIndex(at: newTimeMs) else { return }
                let newId = self.lyrics.lines[currentIdx].id

                if newId != self.currentLineId {
                    self.currentLineId = newId
                    self.currentLineIndex = currentIdx
                    if !self.userIsScrolling {
                        withAnimation(.easeInOut(duration: 0.42)) {
                            proxy.scrollTo(newId, anchor: .center)
                        }
                    }
                }
            }
            .onAppear {
                if let initialIdx = self.lyrics.currentLineIndex(at: self.currentTimeMs) {
                    self.currentLineIndex = initialIdx
                    self.currentLineId = self.lyrics.lines[initialIdx].id
                }
            }
            .onDisappear {
                self.scrollResumeTask?.cancel()
            }
        }
    }

    private func currentStatus(for lineIndex: Int) -> SyncedLyrics.LineStatus {
        guard let currentLineIndex else { return .upcoming }
        if lineIndex < currentLineIndex { return .previous }
        if lineIndex == currentLineIndex { return .current }
        return .upcoming
    }

    private func scale(for status: SyncedLyrics.LineStatus) -> CGFloat {
        switch status {
        case .current:
            1.0
        case .previous:
            0.95
        case .upcoming:
            0.965
        }
    }

    private func opacity(for status: SyncedLyrics.LineStatus) -> Double {
        switch status {
        case .current:
            1.0
        case .previous:
            0.35
        case .upcoming:
            0.55
        }
    }
}
