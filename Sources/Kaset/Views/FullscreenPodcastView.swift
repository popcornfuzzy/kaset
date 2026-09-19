import AppKit
import SwiftUI

// MARK: - PodcastVideoSlotModel

/// Coordinates the episode video surface between ``FullscreenPodcastView`` (which lays the slot
/// out) and `MainWindow` (which owns the singleton player WebView).
///
/// The WebView can only live in one place, so the fullscreen view never hosts it directly:
/// it reports where the video belongs and `MainWindow` places the shared layer there. That keeps
/// playback untouched when the fullscreen experience opens and closes.
@MainActor
@Observable
final class PodcastVideoSlotModel {
    /// Named coordinate space the slot frame is reported in (declared by `MainWindow`).
    nonisolated static let coordinateSpaceName = "kasetPodcastVideoSlot"

    /// Frame of the video slot, or `.zero` while the layout offers no slot.
    private(set) var frame: CGRect = .zero

    /// Whether the user wants the episode video shown ("Video deaktivieren" toggle).
    var isVideoEnabled = true

    /// Whether a usable slot is currently laid out.
    var hasSlot: Bool {
        self.frame.width >= 1 && self.frame.height >= 1
    }

    /// Records the slot frame, ignoring sub-pixel churn from repeated layout passes.
    func updateSlotFrame(_ newFrame: CGRect) {
        let current = self.frame
        guard abs(newFrame.minX - current.minX) > 0.5
            || abs(newFrame.minY - current.minY) > 0.5
            || abs(newFrame.width - current.width) > 0.5
            || abs(newFrame.height - current.height) > 0.5
        else {
            return
        }

        self.frame = newFrame
    }

    /// Drops the slot when the video is not on screen (disabled or no room laid out).
    func clearSlot() {
        guard self.frame != .zero else { return }
        self.frame = .zero
    }
}

// MARK: - FullscreenPodcastView

/// Fullscreen podcast listening experience: the episode video beside YouTube's transcript.
///
/// Shown instead of ``FullscreenNowPlayingView`` whenever the current playback item is a podcast
/// episode. Layout and controls follow the Apple Podcasts-style player: video and episode metadata
/// on the left, the episode transcript — which is also the seek bar of the experience — on the right.
@available(macOS 26.0, *)
struct FullscreenPodcastView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(PodcastTranscriptService.self) private var transcriptService

    /// Shared slot the video surface is placed into by `MainWindow`.
    let slotModel: PodcastVideoSlotModel

    private enum Layout {
        /// Share of the width the transcript column takes while it is visible.
        static let transcriptWidthRatio: CGFloat = 0.56
        static let columnSpacingRatio: CGFloat = 0.03
        static let horizontalPadding: CGFloat = 56
        static let videoAspectRatio: CGFloat = 16.0 / 9.0
        static let maximumContentWidth: CGFloat = 1320
        static let artworkSize: CGFloat = 52
        /// Vertical offset of the top bar, keeping the controls clear of the window traffic lights.
        static let topBarTopPadding: CGFloat = 46
        static let transcriptFontSize: CGFloat = 24
    }

    /// Playback rates offered by the speed control.
    private static let playbackRates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// Sleep-timer durations, in minutes.
    private static let sleepTimerOptions: [Int] = [5, 15, 30, 45, 60]

    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var transcriptTimeMs: Int = 0
    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false
    @State private var showsTranscript = true
    @State private var escapeKeyMonitor: Any?
    @State private var sleepTimerEnd: Date?
    @State private var sleepTimerRemaining: TimeInterval?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - (Layout.horizontalPadding * 2), Layout.maximumContentWidth)
            let columnSpacing = max(24, contentWidth * Layout.columnSpacingRatio)
            let transcriptWidth = self.showsTranscript ? contentWidth * Layout.transcriptWidthRatio : 0
            let mediaWidth = self.showsTranscript ? contentWidth - transcriptWidth - columnSpacing : contentWidth * 0.62

            ZStack {
                self.backgroundLayer

                VStack(spacing: 0) {
                    self.topBar
                        .padding(.horizontal, 24)
                        // Clears the window's traffic lights: the view ignores the safe area, so the
                        // buttons would otherwise sit on top of them.
                        .padding(.top, Layout.topBarTopPadding)

                    HStack(alignment: .center, spacing: columnSpacing) {
                        self.mediaColumn(width: mediaWidth, availableHeight: proxy.size.height)
                            .frame(width: mediaWidth)

                        if self.showsTranscript {
                            self.transcriptPanel
                                .frame(width: transcriptWidth)
                                .frame(maxHeight: .infinity)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, Layout.horizontalPadding)
                    .padding(.bottom, 28)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier(AccessibilityID.FullscreenPodcast.container)
        .onExitCommand {
            self.close()
        }
        .onAppear {
            self.startPresentation()
        }
        .onDisappear {
            self.endPresentation()
        }
        .onChange(of: self.playerService.progress) { _, _ in
            if !self.isSeeking {
                self.seekValue = self.progressSeconds
            }
        }
        .onChange(of: self.playerService.currentTimeMs) { _, newTimeMs in
            self.transcriptTimeMs = newTimeMs
        }
        .onChange(of: self.playerService.volume) { _, newValue in
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onChange(of: self.playerService.currentTrack?.videoId) { _, _ in
            self.startTranscriptLoad()
        }
        .onChange(of: self.playerService.currentTrack?.title) { _, _ in
            self.startTranscriptLoad()
        }
        .task(id: self.sleepTimerEnd) {
            await self.runSleepTimer()
        }
    }

    // MARK: - Presentation

    @MainActor
    private func startPresentation() {
        self.isSeeking = false
        self.seekValue = self.progressSeconds
        self.transcriptTimeMs = self.playerService.currentTimeMs
        self.volumeValue = self.playerService.volume
        self.showsTranscript = true
        self.slotModel.isVideoEnabled = true
        self.installEscapeKeyMonitorIfNeeded()
        // The transcript highlights the paragraph being spoken, so it needs the same
        // high-resolution playback clock the synced lyrics use.
        SingletonPlayerWebView.shared.startLyricsPoll()
        self.startTranscriptLoad()
    }

    @MainActor
    private func endPresentation() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.removeEscapeKeyMonitor()
        self.sleepTimerEnd = nil
        self.sleepTimerRemaining = nil
        self.slotModel.clearSlot()
        self.transcriptService.reset()
        // The transcript only needs the shared high-frequency clock while it is on screen. The
        // sidebar lyrics panel can take it over in the same update (the lyrics shortcut opens it
        // while exiting fullscreen), so it is only stopped when nothing else is consuming it.
        if !self.playerService.showLyrics {
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
    }

    /// Kicks off the transcript lookup once the episode metadata has settled, cancelling any
    /// lookup still waiting on the previous episode.
    @MainActor
    private func startTranscriptLoad() {
        guard let videoId = self.playerService.currentTrack?.videoId else { return }
        self.loadTask?.cancel()
        self.loadTask = Task { [videoId] in
            for _ in 0 ..< 40 {
                guard !Task.isCancelled else { return }
                guard self.playerService.currentTrack?.videoId == videoId else { return }
                if let track = self.playerService.currentTrack,
                   !track.title.isEmpty,
                   track.title != "Loading..."
                {
                    await self.transcriptService.loadTranscript(for: videoId)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func installEscapeKeyMonitorIfNeeded() {
        guard self.escapeKeyMonitor == nil else { return }
        self.escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == 53 else { return event }
            self.close()
            return nil
        }
    }

    private func removeEscapeKeyMonitor() {
        guard let monitor = escapeKeyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        self.escapeKeyMonitor = nil
    }

    private func close() {
        withAnimation(AppAnimation.standard) {
            self.playerService.showFullscreenNowPlaying = false
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            if let artwork = self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL {
                CachedAsyncImage(
                    url: artwork,
                    fallbackURL: self.playerService.currentTrack?.thumbnailURL,
                    identity: self.playerService.currentTrack?.videoId
                ) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.black)
                }
                .blur(radius: 72)
                .scaleEffect(1.2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                Rectangle().fill(.black)
            }

            Rectangle().fill(.black.opacity(0.62))
            Rectangle().fill(
                LinearGradient(
                    colors: [.black.opacity(0.45), .black.opacity(0.72), .black.opacity(0.86)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                HapticService.toggle()
                self.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close"))
            .accessibilityIdentifier(AccessibilityID.FullscreenPodcast.closeButton)

            Button {
                HapticService.toggle()
                withAnimation(AppAnimation.standard) {
                    self.showsTranscript.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(self.showsTranscript ? .white : .white.opacity(0.55))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(self.showsTranscript ? 0.12 : 0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help(self.showsTranscript ? String(localized: "Hide Transcript") : String(localized: "Show Transcript"))
            .accessibilityIdentifier(AccessibilityID.FullscreenPodcast.transcriptToggle)
            .accessibilityLabel(self.showsTranscript ? String(localized: "Hide Transcript") : String(localized: "Show Transcript"))

            Spacer(minLength: 0)

            self.volumeControl
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 10) {
            Image(systemName: self.volumeIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 18)

            Slider(value: self.$volumeValue, in: 0 ... 1) { editing in
                self.isAdjustingVolume = editing
                if !editing {
                    Task { await self.playerService.setVolume(self.volumeValue) }
                }
            }
            .frame(width: 120)
            .controlSize(.small)
            .tint(.white)
            .onChange(of: self.volumeValue) { _, newValue in
                guard self.isAdjustingVolume else { return }
                Task { await self.playerService.setVolume(newValue) }
            }
            .accessibilityLabel(String(localized: "Volume"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.white.opacity(0.1), in: Capsule())
    }

    private var volumeIcon: String {
        let currentVolume = self.isAdjustingVolume ? self.volumeValue : self.playerService.volume
        if currentVolume == 0 {
            return "speaker.slash.fill"
        }
        if currentVolume < 0.5 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.2.fill"
    }

    // MARK: - Media column

    private func mediaColumn(width: CGFloat, availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The visual is always part of the layout: the shared WebView layer covers it with the
            // episode video when there is one, and the still artwork stands in otherwise.
            self.mediaVisual(width: width)
                .padding(.bottom, 20)

            self.episodeMeta
                .padding(.bottom, 16)

            self.progressRow
                .padding(.bottom, 10)

            self.videoToggleRow
                .padding(.bottom, 18)

            self.transportRow
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: max(320, availableHeight - 120), alignment: .center)
    }

    /// The episode's video slot, measured so `MainWindow` can place the player WebView inside it.
    private func mediaVisual(width: CGFloat) -> some View {
        let slotHeight = width / Layout.videoAspectRatio

        return CachedAsyncImage(
            url: self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL,
            fallbackURL: self.playerService.currentTrack?.thumbnailURL,
            identity: self.playerService.currentTrack?.videoId,
            targetSize: CGSize(width: width, height: slotHeight)
        ) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            ZStack {
                Rectangle().fill(.black)
                CassetteIcon(size: 60).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: width, height: slotHeight)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(PodcastVideoSlotModel.coordinateSpaceName))
        } action: { newFrame in
            self.reportSlotFrame(newFrame)
        }
        // `onGeometryChange` reports every move, but the *first* frame has to be reliable or the
        // shared WebView layer stays at 1×1 while the slot is on screen and the video toggle looks
        // inert: this reader reports as soon as the slot has been laid out.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { self.reportSlotFrame(self.slotFrame(from: proxy)) }
                    .onChange(of: proxy.size) { _, _ in
                        self.reportSlotFrame(self.slotFrame(from: proxy))
                    }
            }
        }
    }

    private func slotFrame(from proxy: GeometryProxy) -> CGRect {
        proxy.frame(in: .named(PodcastVideoSlotModel.coordinateSpaceName))
    }

    /// Publishes the slot to `MainWindow`, ignoring frames that carry no usable slot (such as the
    /// zero geometry reported before the first layout) so the video never blinks out mid-animation.
    private func reportSlotFrame(_ frame: CGRect) {
        guard frame.width >= 1, frame.height >= 1 else { return }
        self.slotModel.updateSlotFrame(frame)
    }

    private var episodeMeta: some View {
        HStack(alignment: .top, spacing: 12) {
            CachedAsyncImage(
                url: self.playerService.currentTrack?.thumbnailURL,
                identity: self.playerService.currentTrack?.videoId,
                targetSize: CGSize(width: Layout.artworkSize * 2, height: Layout.artworkSize * 2)
            ) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.white.opacity(0.12))
            }
            .frame(width: Layout.artworkSize, height: Layout.artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(self.showName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                Text(self.playerService.currentTrack?.title ?? String(localized: "Loading…"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            self.episodeMenu
        }
    }

    private var showName: String {
        let artists = self.playerService.currentTrack?.artistsDisplay ?? ""
        return artists.isEmpty ? String(localized: "Podcast") : artists
    }

    private var episodeMenu: some View {
        Menu {
            Button {
                guard let videoId = self.playerService.currentTrack?.videoId else { return }
                Task { await self.transcriptService.loadTranscript(for: videoId, forceRefresh: true) }
            } label: {
                Label(String(localized: "Refresh Transcript"), systemImage: "arrow.clockwise")
            }
            .disabled(self.playerService.currentTrack?.videoId == nil)

            Button {
                self.copyEpisodeLink()
            } label: {
                Label(String(localized: "Copy Link"), systemImage: "link")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .accessibilityLabel(String(localized: "Episode Options"))
    }

    // MARK: - Progress

    private var progressRow: some View {
        VStack(spacing: 6) {
            Slider(value: self.$seekValue, in: 0 ... max(1, self.totalSeconds)) { editing in
                self.isSeeking = editing
                if !editing {
                    Task { await self.playerService.seek(to: self.seekValue) }
                }
            }
            .tint(.white)
            .disabled(self.totalSeconds <= 0)
            .accessibilityLabel(String(localized: "Playback Position"))

            HStack {
                Text(self.formatTime(self.isSeeking ? self.seekValue : self.playerService.progress))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))

                Spacer(minLength: 0)

                Text("-\(self.formatTime(max(0, self.totalSeconds - (self.isSeeking ? self.seekValue : self.playerService.progress))))")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    @ViewBuilder
    private var videoToggleRow: some View {
        if self.playerService.hasVideoSurface {
            HStack {
                Spacer(minLength: 0)
                Button {
                    HapticService.toggle()
                    withAnimation(AppAnimation.standard) {
                        self.slotModel.isVideoEnabled.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: self.slotModel.isVideoEnabled ? "video.slash" : "video")
                            .font(.system(size: 11, weight: .medium))
                        Text(self.slotModel.isVideoEnabled ? String(localized: "Turn Off Video") : String(localized: "Turn On Video"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 0) {
            self.speedControl

            Spacer(minLength: 0)

            self.skipButton(seconds: -15, systemImage: "gobackward.15")
            Spacer(minLength: 0)

            Button {
                HapticService.playback()
                Task { await self.playerService.playPause() }
            } label: {
                Image(systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play"))

            Spacer(minLength: 0)

            self.skipButton(seconds: 30, systemImage: "goforward.30")
            Spacer(minLength: 0)

            self.sleepTimerControl
        }
    }

    private var speedControl: some View {
        Menu {
            ForEach(Self.playbackRates, id: \.self) { rate in
                Button {
                    HapticService.toggle()
                    self.playerService.setPlaybackRate(rate)
                } label: {
                    if abs(rate - self.playerService.playbackRate) < 0.01 {
                        Label(self.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(self.rateLabel(rate))
                    }
                }
            }
        } label: {
            Text(self.rateLabel(self.playerService.playbackRate))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 28)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Playback Speed"))
    }

    private var sleepTimerControl: some View {
        Menu {
            if self.sleepTimerEnd != nil {
                Button(String(localized: "Turn Off Sleep Timer")) {
                    self.stopSleepTimer()
                }
                Divider()
            }
            ForEach(Self.sleepTimerOptions, id: \.self) { minutes in
                Button(String(localized: "\(minutes) minutes")) { // key: "%lld minutes"
                    self.startSleepTimer(minutes: minutes)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: self.sleepTimerEnd == nil ? "moon" : "moon.fill")
                    .font(.system(size: 14, weight: .semibold))
                if let remaining = self.sleepTimerRemaining {
                    Text(self.countdownLabel(remaining))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(self.sleepTimerEnd == nil ? .white.opacity(0.85) : .white)
            .frame(minWidth: 44, minHeight: 28)
            .padding(.horizontal, self.sleepTimerRemaining == nil ? 0 : 8)
            .background(
                .white.opacity(self.sleepTimerEnd == nil ? 0 : 0.14),
                in: Capsule()
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Sleep Timer"))
        .accessibilityLabel(String(localized: "Sleep Timer"))
    }

    private func skipButton(seconds: Int, systemImage: String) -> some View {
        Button {
            HapticService.playback()
            let target = max(0, min(self.totalSeconds, self.playerService.progress + Double(seconds)))
            Task { await self.playerService.seek(to: target) }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(self.totalSeconds <= 0)
        .accessibilityLabel(
            seconds < 0
                ? String(localized: "Back 15 Seconds")
                : String(localized: "Forward 30 Seconds")
        )
    }

    // MARK: - Transcript

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(String(localized: "Transcript"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))

                if let languageCode = self.transcriptService.transcript.languageCode,
                   self.transcriptService.transcript.isAvailable
                {
                    Text(self.transcriptCaption(languageCode))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer(minLength: 0)
            }

            Group {
                if self.transcriptService.isLoading {
                    self.transcriptPlaceholder(
                        icon: nil,
                        title: String(localized: "Loading transcript…"),
                        message: nil
                    )
                } else if self.transcriptService.transcript.isAvailable {
                    PodcastTranscriptTextView(
                        lines: self.transcriptService.transcript.lines,
                        currentTimeMs: self.transcriptTimeMs,
                        fontSize: Layout.transcriptFontSize,
                        onSeek: { timeMs in
                            HapticService.toggle()
                            self.transcriptTimeMs = timeMs
                            Task { await self.playerService.seek(to: TimeInterval(timeMs) / 1000) }
                        }
                    )
                } else {
                    self.transcriptPlaceholder(
                        icon: "text.bubble",
                        title: String(localized: "No Transcript Available"),
                        message: self.transcriptService.errorMessage
                            ?? String(localized: "This episode has no captions on YouTube, so there is no transcript to show.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(AccessibilityID.FullscreenPodcast.transcript)
        }
        .padding(.top, 4)
    }

    private func transcriptCaption(_ languageCode: String) -> String {
        let language = Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode.uppercased()
        guard self.transcriptService.transcript.isAutoGenerated else { return language }
        return "\(language) · \(String(localized: "Auto-generated"))"
    }

    private func transcriptPlaceholder(icon: String?, title: String, message: String?) -> some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ProgressView().controlSize(.regular).tint(.white)
            }

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var totalSeconds: Double {
        self.playerService.duration
    }

    private var progressSeconds: Double {
        min(self.playerService.progress, max(0, self.totalSeconds))
    }

    private func rateLabel(_ rate: Double) -> String {
        if abs(rate - rate.rounded()) < 0.001 {
            return "\(Int(rate.rounded()))x"
        }
        return String(format: "%.2gx", rate)
    }

    private func countdownLabel(_ remaining: TimeInterval) -> String {
        let totalSeconds = max(0, Int(remaining.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let totalSeconds = max(Int(time), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func copyEpisodeLink() {
        guard let videoId = self.playerService.currentTrack?.videoId,
              let url = URL(string: "https://music.youtube.com/watch?v=\(videoId)")
        else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    // MARK: - Sleep timer

    private func startSleepTimer(minutes: Int) {
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        self.sleepTimerEnd = end
        self.sleepTimerRemaining = TimeInterval(minutes * 60)
    }

    private func stopSleepTimer() {
        self.sleepTimerEnd = nil
        self.sleepTimerRemaining = nil
    }

    @MainActor
    private func runSleepTimer() async {
        guard let end = self.sleepTimerEnd else { return }

        while !Task.isCancelled, self.sleepTimerEnd == end {
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 {
                await self.playerService.pause()
                self.stopSleepTimer()
                return
            }

            self.sleepTimerRemaining = remaining
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// MARK: - PodcastTranscriptTextView

/// The scrolling transcript column: the paragraph being spoken is highlighted and followed.
@available(macOS 26.0, *)
private struct PodcastTranscriptTextView: View {
    let lines: [PodcastTranscriptLine]
    let currentTimeMs: Int
    let fontSize: CGFloat
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
                LazyVStack(alignment: .leading, spacing: 22) {
                    Spacer().frame(height: 40)

                    ForEach(Array(self.lines.enumerated()), id: \.element.id) { index, line in
                        let isCurrent = index == self.currentLineIndex
                        let isSpoken = self.isSpoken(index)
                        let isHovered = self.hoveredLineId == line.id

                        // Emphasis rides on opacity and a scale transform, never on the font itself: changing
                        // the weight (or animating between weights) re-flows the paragraph, so words jump
                        // between wrap points while the spoken paragraph moves. A scale effect redraws the
                        // same layout — the technique the fullscreen synced lyrics use.
                        Text(line.text)
                            .font(.system(size: self.fontSize, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineSpacing(8)
                            .opacity(self.opacity(isCurrent: isCurrent, isSpoken: isSpoken, isHovered: isHovered))
                            .scaleEffect(self.scale(isCurrent: isCurrent, isSpoken: isSpoken, isHovered: isHovered), anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onHover { isHovered in
                                self.hoveredLineId = isHovered ? line.id : nil
                            }
                            .onTapGesture {
                                self.currentLineIndex = index
                                self.currentLineId = line.id
                                self.onSeek(line.timeInMs)
                            }
                            .animation(.easeInOut(duration: 0.35), value: self.currentLineIndex)
                            .animation(.easeOut(duration: 0.16), value: self.hoveredLineId)
                            .id(line.id)
                    }

                    Spacer().frame(height: 120)
                }
                .padding(.trailing, 8)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting:
                    self.beginUserScroll()
                case .decelerating:
                    self.scheduleScrollResume(proxy: proxy)
                default:
                    break
                }
            }
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                self.syncCurrentLine(using: newTimeMs, proxy: proxy, animate: !self.userIsScrolling)
            }
            .onChange(of: self.lines) { _, _ in
                self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false)
            }
            .onAppear {
                self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false)
                if let currentLineId = self.currentLineId {
                    Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(currentLineId, anchor: .center)
                    }
                }
            }
            .onDisappear {
                self.scrollResumeTask?.cancel()
                self.hoveredLineId = nil
            }
        }
    }

    private func isSpoken(_ index: Int) -> Bool {
        guard let currentLineIndex else { return false }
        return index < currentLineIndex
    }

    private func opacity(isCurrent: Bool, isSpoken: Bool, isHovered: Bool) -> Double {
        if isCurrent {
            return 1
        }
        if isHovered {
            return 0.78
        }
        return isSpoken ? 0.35 : 0.55
    }

    /// Render-only emphasis transform, mirroring the fullscreen synced lyrics lines so paragraph
    /// layout never changes while playback moves through the transcript.
    private func scale(isCurrent: Bool, isSpoken: Bool, isHovered: Bool) -> CGFloat {
        if isCurrent {
            return 1
        }
        if isHovered {
            return 0.985
        }
        return isSpoken ? 0.95 : 0.965
    }

    private func beginUserScroll() {
        self.userIsScrolling = true
        self.resumeScrollGeneration += 1
        self.scrollResumeTask?.cancel()
    }

    /// Re-enables following the spoken paragraph after the user stops scrolling.
    private func scheduleScrollResume(proxy: ScrollViewProxy) {
        let generation = self.resumeScrollGeneration
        self.scrollResumeTask?.cancel()
        self.scrollResumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }
            self.userIsScrolling = false
            guard let currentLineId = self.currentLineId else { return }
            withAnimation(.easeInOut(duration: 0.42)) {
                proxy.scrollTo(currentLineId, anchor: .center)
            }
        }
    }

    private func syncCurrentLine(using timeMs: Int, proxy: ScrollViewProxy, animate: Bool) {
        let newIndex = self.lines.lastIndex(where: { $0.timeInMs <= timeMs })

        guard let newIndex else {
            // Playback has not reached the first paragraph yet.
            self.currentLineIndex = nil
            self.currentLineId = nil
            return
        }

        let newId = self.lines[newIndex].id
        guard newId != self.currentLineId else { return }

        self.currentLineIndex = newIndex
        self.currentLineId = newId
        guard !self.userIsScrolling else { return }

        if animate {
            withAnimation(.easeInOut(duration: 0.42)) {
                proxy.scrollTo(newId, anchor: .center)
            }
        } else {
            proxy.scrollTo(newId, anchor: .center)
        }
    }
}
