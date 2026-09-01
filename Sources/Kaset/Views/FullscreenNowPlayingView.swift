import AppKit
import SwiftUI

/// In-window fullscreen now-playing experience with artwork, synced lyrics, and transport controls.
@available(macOS 26.0, *)
struct FullscreenNowPlayingView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService

    let client: any YTMusicClientProtocol

    @State private var lastLoadedVideoId: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var isLoadingFallback = false
    @State private var seekValue: Double = 0
    @State private var lyricsTimeMs: Int = 0
    @State private var isSeeking = false
    @State private var escapeKeyMonitor: Any?

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
        .onAppear {
            self.seekValue = self.normalizedProgress
            self.updateLyricsPolling(for: self.syncedLyricsService.currentLyrics)
            self.lyricsTimeMs = self.playerService.currentTimeMs
            self.installEscapeKeyMonitorIfNeeded()
        }
        .onChange(of: self.playerService.progress) { _, _ in
            if !self.isSeeking { self.seekValue = self.normalizedProgress }
        }
        .onChange(of: self.playerService.currentTimeMs) { _, newTimeMs in
            self.lyricsTimeMs = newTimeMs
        }
        .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
            self.loadTask?.cancel()
            if let videoId = newVideoId, videoId != self.lastLoadedVideoId {
                self.loadTask = Task { await self.loadLyricsWhenReady(for: videoId) }
            }
        }
        .onChange(of: self.playerService.currentTrack?.title) { _, _ in
            guard let videoId = self.playerService.currentTrack?.videoId else { return }
            guard videoId != self.lastLoadedVideoId else { return }
            self.loadTask?.cancel()
            self.loadTask = Task { await self.loadLyricsWhenReady(for: videoId) }
        }
        .onChange(of: self.playerService.duration) { _, newDuration in
            guard let videoId = self.playerService.currentTrack?.videoId, newDuration > 0 else { return }
            guard videoId != self.lastLoadedVideoId else { return }
            self.loadTask?.cancel()
            self.loadTask = Task { await self.loadLyricsWhenReady(for: videoId) }
        }
        .onChange(of: self.syncedLyricsService.currentLyrics) { _, newLyrics in
            self.updateLyricsPolling(for: newLyrics)
        }
        .task {
            if let videoId = self.playerService.currentTrack?.videoId {
                await self.loadLyricsWhenReady(for: videoId)
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
        let artworkMaxHeight = min(max(200, availableHeight * 0.46), 380)
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
        CachedAsyncImage(url: self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            ZStack { RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.08)); CassetteIcon(size: 76).foregroundStyle(.white.opacity(0.7)) }
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
                        FullscreenSyncedLyricsView(lyrics: synced, currentTimeMs: self.lyricsTimeMs, onSeek: { timeMs in Task { await self.playerService.seek(to: Double(timeMs) / 1000.0) } }).background(.clear).mask(self.lyricsFadeMask)
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
    private func installEscapeKeyMonitorIfNeeded() { guard self.escapeKeyMonitor == nil else { return }; self.escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in if event.keyCode == 53 { self.closeFullscreenNowPlaying(); return nil }; return event } }
    private func removeEscapeKeyMonitor() { guard let monitor = self.escapeKeyMonitor else { return }; NSEvent.removeMonitor(monitor); self.escapeKeyMonitor = nil }

    @MainActor
    private func loadLyricsWhenReady(for videoId: String) async {
        for _ in 0 ..< 40 {
            guard !Task.isCancelled,
                  self.playerService.currentTrack?.videoId == videoId
            else { return }
            if let track = self.playerService.currentTrack,
               !track.title.isEmpty,
               track.title != "Loading...",
               !track.artistsDisplay.isEmpty,
               self.playerService.duration > 0,
               self.playerService.isPlaying
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
              !track.artistsDisplay.isEmpty,
              self.playerService.duration > 0,
              self.playerService.isPlaying
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
    let onSeek: (Int) -> Void
    @State private var currentLineId: UUID?
    @State private var currentLineIndex: Int?
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
                            FullscreenPauseDotsLineView(dotStatuses: self.lyrics.pauseDotStatuses(forLineAt: index, at: self.currentTimeMs), status: status, isHovered: self.hoveredLineId == line.id).animation(.easeInOut(duration: 0.4), value: self.currentLineIndex).animation(.easeOut(duration: 0.16), value: self.hoveredLineId).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).onHover { isHovered in if status != .current { self.hoveredLineId = isHovered ? line.id : nil } }.onTapGesture { self.onSeek(line.timeInMs) }.id(line.id)
                        } else {
                            FullscreenSyncedLineView(line: line, status: status, currentTimeMs: self.currentTimeMs).foregroundStyle(.white).opacity(self.opacity(for: status, lineId: line.id)).scaleEffect(self.scale(for: status, lineId: line.id), anchor: .leading).animation(.easeInOut(duration: 0.4), value: self.currentLineIndex).animation(.easeOut(duration: 0.16), value: self.hoveredLineId).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).onHover { isHovered in if status != .current { self.hoveredLineId = isHovered ? line.id : nil } }.onTapGesture { self.onSeek(line.timeInMs) }.id(line.id)
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
            .simultaneousGesture(DragGesture(minimumDistance: 1).onChanged { _ in self.userIsScrolling = true; self.resumeScrollGeneration += 1; self.scrollResumeTask?.cancel() }.onEnded { _ in let generation = self.resumeScrollGeneration; self.scrollResumeTask = Task { try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }; self.userIsScrolling = false; if let currentLineId = self.currentLineId { withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(currentLineId, anchor: .center) } } } }).onChange(of: self.currentTimeMs) { _, newTimeMs in self.syncCurrentLine(using: newTimeMs, proxy: proxy, animate: !self.userIsScrolling) }.onChange(of: self.lyrics) { _, _ in self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false) }.onAppear { self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false); if let currentLineId = self.currentLineId { Task { await Task.yield(); if !Task.isCancelled { proxy.scrollTo(currentLineId, anchor: .center) } } } }.onDisappear { self.scrollResumeTask?.cancel(); self.hoveredLineId = nil }
        }
    }
    private func currentStatus(for lineIndex: Int) -> SyncedLyrics.LineStatus { guard let currentLineIndex else { return .upcoming }; if lineIndex < currentLineIndex { return .previous }; if lineIndex == currentLineIndex { return .current }; return .upcoming }
    private func scale(for status: SyncedLyrics.LineStatus, lineId: UUID) -> CGFloat { if self.hoveredLineId == lineId, status != .current { return 0.985 }; return switch status { case .current: 1; case .previous: 0.95; case .upcoming: 0.965 } }
    private func opacity(for status: SyncedLyrics.LineStatus, lineId: UUID) -> Double { if self.hoveredLineId == lineId, status != .current { return 0.78 }; return switch status { case .current: 1; case .previous: 0.35; case .upcoming: 0.55 } }
    private func syncCurrentLine(using timeMs: Int, proxy: ScrollViewProxy, animate: Bool) { guard let currentIdx = self.lyrics.currentLineIndex(at: timeMs) else { return }; let newId = self.lyrics.lines[currentIdx].id; self.currentLineIndex = currentIdx; guard newId != self.currentLineId else { return }; self.currentLineId = newId; guard !self.userIsScrolling else { return }; if animate { withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(newId, anchor: .center) } } else { proxy.scrollTo(newId, anchor: .center) } }
}

@available(macOS 26.0, *)
private struct FullscreenSyncedLineView: View {
    let line: SyncedLyricLine
    let status: SyncedLyrics.LineStatus
    let currentTimeMs: Int
    var body: some View {
        Group {
            if let words = self.line.words, !words.isEmpty {
                FlowKaraokeLine(words: words, currentTimeMs: self.currentTimeMs, color: .white)
            } else {
                Text(self.line.text.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : self.line.text)
            }
        }
        .font(.system(size: 36, weight: .bold))
        .lineSpacing(18)
    }
}

@available(macOS 26.0, *)
private struct FullscreenPauseDotsLineView: View {
    let dotStatuses: [SyncedLyrics.PauseDotStatus]
    let status: SyncedLyrics.LineStatus
    let isHovered: Bool
    var body: some View { HStack(spacing: 9) { ForEach(0 ..< 3, id: \.self) { dotIndex in self.dotView(for: self.safeDotStatus(at: dotIndex)) } }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13).opacity(self.lineOpacity(for: self.status, isHovered: self.isHovered)).scaleEffect(self.lineScale(for: self.status, isHovered: self.isHovered), anchor: .leading).animation(.easeInOut(duration: 0.35), value: self.dotStatuses).animation(.easeInOut(duration: 0.35), value: self.status) }
    @ViewBuilder private func dotView(for dotStatus: SyncedLyrics.PauseDotStatus) -> some View { let dot = Circle().fill(Color.white).frame(width: 13, height: 13).opacity(self.dotOpacity(for: dotStatus)); if dotStatus == .active { TimelineView(.animation) { timeline in let elapsed = timeline.date.timeIntervalSinceReferenceDate; let phase = elapsed.truncatingRemainder(dividingBy: 0.72) / 0.72; dot.offset(y: -5.2 * (0.5 + 0.5 * sin(phase * 2 * .pi))) } } else { dot } }
    private func safeDotStatus(at index: Int) -> SyncedLyrics.PauseDotStatus { self.dotStatuses.indices.contains(index) ? self.dotStatuses[index] : .notSung }
    private func dotOpacity(for status: SyncedLyrics.PauseDotStatus) -> Double { switch status { case .notSung: 0.28; case .active: 1; case .sung: 0.65 } }
    private func lineScale(for status: SyncedLyrics.LineStatus, isHovered: Bool) -> CGFloat { if isHovered, status != .current { return 0.985 }; return switch status { case .current: 1; case .previous: 0.95; case .upcoming: 0.965 } }
    private func lineOpacity(for status: SyncedLyrics.LineStatus, isHovered: Bool) -> Double { if isHovered, status != .current { return 0.78 }; return switch status { case .current: 1; case .previous: 0.35; case .upcoming: 0.55 } }
}
