import SwiftUI

// MARK: - PlayerBar

/// Player bar shown at the bottom of the content area, styled like Apple Music with Liquid Glass.
@available(macOS 26.0, *)
struct PlayerBar: View {
    private static let brandAccent = PackageResourceLookup.brandAccent

    @Environment(PlayerService.self) private var playerService
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?

    /// Namespace for glass effect morphing and unioning.
    @Namespace private var playerNamespace

    @State private var isHovering = false

    /// Local seek value for smooth slider dragging without network calls on every change.
    @State private var seekValue: Double = 0
    @State private var isSeeking = false

    /// Local volume value for smooth slider dragging.
    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false

    /// Cached formatted progress string to avoid repeated formatting.
    @State private var formattedProgress: String = "0:00"
    @State private var formattedRemaining: String = "-0:00"
    /// Last integer second of progress to reduce string formatting frequency.
    @State private var lastProgressSecond: Int = -1

    var body: some View {
        // TEMPORARY: scroll diagnostics (see PerfHUD).
        if PerfHUD.isEnabled, !PerfHUD.shared.showsPlayerBar {
            EmptyView()
        } else {
            self.barBody
        }
    }

    private var barBody: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                // Left section: Playback controls
                self.playbackControls

                Spacer()

                // Center section: Track info OR seek bar (on hover)
                self.centerSection

                Spacer()

                // Right section: Volume control
                self.volumeControl
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(height: 52)
            .modifier(PlayerBarGlassModifier(namespace: self.playerNamespace))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovering = hovering
            }
        }
        .background {
            // Keyboard shortcuts for media controls.
            //
            // Deliberately re-enabled while the fullscreen overlay hides and disables this bar: these key
            // equivalents are the window's media controls, and the overlay disables the whole subtree it
            // covers (which is what resigns focus so no hidden control can be activated). `allowsHitTesting`
            // keeps these invisible buttons unclickable while they are covered.
            Group {
                // Space: Play/Pause
                Button("") {
                    Task { await self.playerService.playPause() }
                }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)

                // Command + Right Arrow: Next track, or forward 30s for a podcast episode
                Button("") {
                    if self.playerService.isCurrentTrackPodcast {
                        Task { await self.seek(by: 30) }
                    } else {
                        Task { await self.playerService.next() }
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(self.playerService.currentEpisode != nil)
                .opacity(0)

                // Command + Left Arrow: Previous track, or back 15s for a podcast episode
                Button("") {
                    if self.playerService.isCurrentTrackPodcast {
                        Task { await self.seek(by: -15) }
                    } else {
                        Task { await self.playerService.previous() }
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(self.playerService.currentEpisode != nil)
                .opacity(0)

                // Command + Up Arrow: Volume up
                Button("") {
                    Task { await self.playerService.setVolume(min(1.0, self.playerService.volume + 0.1)) }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .opacity(0)

                // Command + Down Arrow: Volume down
                Button("") {
                    Task { await self.playerService.setVolume(max(0.0, self.playerService.volume - 0.1)) }
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .opacity(0)
            }
            .disabled(false)
        }
        .onChange(of: self.playerService.progress) { _, newValue in
            // Sync local seek value when not actively seeking
            if !self.isSeeking, self.playerService.duration > 0 {
                self.seekValue = newValue / self.playerService.duration
            }
            // Only update formatted strings when the second changes to reduce Text view updates
            let currentSecond = Int(newValue)
            if currentSecond != self.lastProgressSecond {
                self.lastProgressSecond = currentSecond
                self.formattedProgress = self.formatTime(newValue)
                self.formattedRemaining = "-\(self.formatTime(self.playerService.duration - newValue))"
            }
        }
        .onChange(of: self.playerService.volume) { _, newValue in
            // Sync local volume value when not actively adjusting
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onAppear {
            // Sync local volume value from saved state on initial load
            self.volumeValue = self.playerService.volume
        }
    }

    // MARK: - Center Section (track info blurs, seek bar appears on hover)

    private var centerSection: some View {
        ZStack {
            // Error state display with retry option
            if case let .error(message) = playerService.state {
                self.errorView(message: message)
            } else {
                // Track info (blurred when hovering and track is playing)
                self.trackInfoView
                    .blur(radius: self.isHovering && self.playerService.currentTrack != nil ? 8 : 0)
                    .opacity(self.isHovering && self.playerService.currentTrack != nil ? 0 : 1)

                // On hover: seek bar for normal tracks, LIVE indicator for live streams.
                if self.isHovering, self.playerService.currentTrack != nil {
                    if self.playerService.isCurrentItemLive {
                        self.liveIndicatorView
                            .transition(.opacity)
                    } else {
                        self.seekBarView
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(maxWidth: 400)
    }

    // MARK: - Live Indicator View (replaces seek bar for live streams)

    private var liveIndicatorView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)

            Text("LIVE", comment: "Label shown on the player bar when playing a live radio stream")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .tracking(0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Live stream"))
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))

            Text(message)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    if let track = playerService.currentTrack {
                        await self.playerService.play(song: track)
                    }
                }
            } label: {
                Text("Retry", comment: "Button to retry failed playback")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(.capsule)
        }
    }

    // MARK: - Track Info View

    private var trackInfoView: some View {
        HStack(spacing: 10) {
            // Thumbnail
            CachedAsyncImage(
                url: self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL,
                fallbackURL: self.playerService.currentTrack?.thumbnailURL,
                identity: self.playerService.currentTrack?.videoId
            ) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay {
                        CassetteIcon(size: 20)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Track info
            if let track = playerService.currentTrack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text(track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 200, alignment: .leading)
            }
        }
    }

    // MARK: - Seek Bar View (replaces track info on hover)

    private var seekBarView: some View {
        HStack(spacing: 10) {
            // Elapsed time - use cached formatted string when not seeking
            Text(self.isSeeking ? self.formatTime(self.seekValue * self.playerService.duration) : self.formattedProgress)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 45, alignment: .trailing)
                .monospacedDigit()

            // Seek slider
            Slider(value: self.$seekValue, in: 0 ... 1) { editing in
                if editing {
                    // User started dragging
                    self.isSeeking = true
                } else {
                    // User finished dragging - perform seek
                    self.performSeek()
                }
            }
            .controlSize(.small)
            .tint(Self.brandAccent)

            // Remaining time - use cached formatted string when not seeking
            Text(self.isSeeking ? "-\(self.formatTime(self.playerService.duration - self.seekValue * self.playerService.duration))" : self.formattedRemaining)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 45, alignment: .leading)
                .monospacedDigit()
        }
    }

    /// Performs the actual seek operation after slider interaction ends.
    private func performSeek() {
        guard self.isSeeking else { return }
        let seekTime = self.seekValue * self.playerService.duration
        Task {
            await self.playerService.seek(to: seekTime)
            self.isSeeking = false
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        } else {
            return String(format: "%d:%02d", mins, secs)
        }
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 16) {
            // Shuffle
            Button {
                HapticService.toggle()
                self.playerService.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.shuffleEnabled ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(String(localized: "Shuffle"))
            .accessibilityValue(self.playerService.shuffleEnabled ? String(localized: "On") : String(localized: "Off"))

            // Previous track, or back 15 seconds while a podcast episode is playing.
            //
            // `isCurrentTrackPodcast` — not `currentEpisode` — is the signal here: a podcast played
            // from a show page is a queued `Song` with the "podcast" artist marker and leaves
            // `currentEpisode` nil. `currentEpisode` is set only for standalone artist-page episodes
            // (live streams), which have no duration and therefore keep the track controls disabled.
            if self.playerService.isCurrentTrackPodcast {
                self.skipButton(seconds: -15, systemImage: "gobackward.15")
            } else {
                Button {
                    HapticService.playback()
                    Task {
                        await self.playerService.previous()
                    }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.pressable)
                .disabled(self.playerService.currentEpisode != nil)
                .accessibilityLabel(String(localized: "Previous track"))
            }

            // Play/Pause
            Button {
                HapticService.playback()
                Task {
                    await self.playerService.playPause()
                }
            } label: {
                Image(systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .glassEffectID("playPause", in: self.playerNamespace)
            .accessibilityLabel(self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play"))

            // Next track, or forward 30 seconds while a podcast episode is playing.
            if self.playerService.isCurrentTrackPodcast {
                self.skipButton(seconds: 30, systemImage: "goforward.30")
            } else {
                Button {
                    HapticService.playback()
                    Task {
                        await self.playerService.next()
                    }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.pressable)
                .disabled(self.playerService.currentEpisode != nil)
                .accessibilityLabel(String(localized: "Next track"))
            }

            // Repeat
            Button {
                HapticService.toggle()
                self.playerService.cycleRepeatMode()
            } label: {
                Image(systemName: self.repeatIcon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.repeatMode != .off ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(String(localized: "Repeat"))
            .accessibilityValue(self.repeatAccessibilityValue)
        }
    }

    /// A rewind/forward button used in place of the previous/next controls while a podcast
    /// episode is playing, mirroring the transport row of the fullscreen podcast view.
    private func skipButton(seconds: Int, systemImage: String) -> some View {
        Button {
            HapticService.playback()
            Task {
                await self.seek(by: seconds)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.pressable)
        .disabled(self.playerService.duration <= 0)
        .accessibilityLabel(
            seconds < 0
                ? String(localized: "Back 15 Seconds")
                : String(localized: "Forward 30 Seconds")
        )
    }

    /// Seeks relative to the current position, clamped to the episode's bounds.
    private func seek(by seconds: Int) async {
        guard self.playerService.duration > 0 else { return }
        let target = max(0, min(self.playerService.duration, self.playerService.progress + Double(seconds)))
        await self.playerService.seek(to: target)
    }

    private var repeatIcon: String {
        switch self.playerService.repeatMode {
        case .off, .all:
            "repeat"
        case .one:
            "repeat.1"
        }
    }

    private var repeatAccessibilityValue: String {
        switch self.playerService.repeatMode {
        case .off:
            String(localized: "Off")
        case .all:
            String(localized: "All")
        case .one:
            String(localized: "One")
        }
    }

    // MARK: - Volume Control

    private var volumeControl: some View {
        HStack(spacing: 8) {
            // Like/Dislike/Library actions
            self.actionButtons


            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            Image(systemName: self.volumeIcon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 18)

            // Volume slider with immediate updates
            Slider(value: self.$volumeValue, in: 0 ... 1) { editing in
                if editing {
                    // User started dragging
                    self.isAdjustingVolume = true
                } else {
                    // User finished dragging/clicking - apply volume change
                    self.isAdjustingVolume = false
                    // Always apply volume when interaction ends to ensure WebView is synced
                    Task {
                        await self.playerService.setVolume(self.volumeValue)
                    }
                }
            }
            .frame(width: 80)
            .controlSize(.small)
            .tint(Self.brandAccent)
            .onChange(of: self.volumeValue) { oldValue, newValue in
                // Apply volume changes in real-time during dragging for immediate feedback
                if self.isAdjustingVolume {
                    // Haptic feedback at slider boundaries
                    if (oldValue > 0 && newValue == 0) || (oldValue < 1 && newValue == 1) {
                        HapticService.sliderBoundary()
                    }
                    Task {
                        await self.playerService.setVolume(newValue)
                    }
                }
            }
            

            // Cast button
            CastButton()
        }
    }

    // MARK: - Action Buttons (Like/Dislike/Lyrics/Queue)

    private var actionButtons: some View {
        @Bindable var player = self.playerService

        return HStack(spacing: 12) {
            // Dislike button
            Button {
                HapticService.toggle()
                self.playerService.dislikeCurrentTrack()
            } label: {
                Image(systemName: self.playerService.currentTrackLikeStatus == .dislike
                    ? "hand.thumbsdown.fill"
                    : "hand.thumbsdown")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.currentTrackLikeStatus == .dislike ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .symbolEffect(.bounce, value: self.playerService.currentTrackLikeStatus == .dislike)
            .accessibilityLabel(String(localized: "Dislike"))
            .accessibilityValue(self.playerService.currentTrackLikeStatus == .dislike ? String(localized: "Disliked") : String(localized: "Not disliked"))
            .disabled(self.playerService.currentTrack == nil)

            // Like button
            Button {
                HapticService.toggle()
                self.playerService.likeCurrentTrack()
            } label: {
                Image(systemName: self.playerService.currentTrackLikeStatus == .like
                    ? "hand.thumbsup.fill"
                    : "hand.thumbsup")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.currentTrackLikeStatus == .like ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .symbolEffect(.bounce, value: self.playerService.currentTrackLikeStatus == .like)
            .accessibilityLabel(String(localized: "Like"))
            .accessibilityValue(self.playerService.currentTrackLikeStatus == .like ? String(localized: "Liked") : String(localized: "Not liked"))
            .disabled(self.playerService.currentTrack == nil)


            // Add to Playlist button
            if let currentTrack = self.playerService.currentTrack,
               let client = self.libraryViewModel?.client ?? self.playerService.ytMusicClient
            {
                AddToPlaylistPopoverButton(
                    song: currentTrack,
                    client: client,
                    libraryViewModel: self.libraryViewModel,
                    preferredLikeStatus: self.playerService.currentTrackLikeStatus,
                    icon: "plus.circle",
                    iconSize: 15,
                    usePressableStyle: true
                )
                .accessibilityLabel(String(localized: "Add to Playlist"))
            }

            if !self.playerService.showFullscreenNowPlaying {
                // Lyrics button
                Button {
                    HapticService.toggle()
                    withAnimation(AppAnimation.standard) {
                        player.showLyrics.toggle()
                    }
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(self.playerService.showLyrics ? .red : .primary.opacity(0.85))
                }
                .buttonStyle(.pressable)
                .glassEffectID("lyrics", in: self.playerNamespace)
                .accessibilityIdentifier(AccessibilityID.PlayerBar.lyricsButton)
                .accessibilityLabel(String(localized: "Lyrics"))
                .accessibilityValue(self.playerService.showLyrics ? String(localized: "Showing") : String(localized: "Hidden"))

                // Queue button
                Button {
                    HapticService.toggle()
                    withAnimation(AppAnimation.standard) {
                        player.showQueue.toggle()
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(self.playerService.showQueue ? .red : .primary.opacity(0.85))
                }
                .buttonStyle(.pressable)
                .glassEffectID("queue", in: self.playerNamespace)
                .accessibilityIdentifier(AccessibilityID.PlayerBar.queueButton)
                .accessibilityLabel(String(localized: "Queue"))
                .accessibilityValue(self.playerService.showQueue ? String(localized: "Showing") : String(localized: "Hidden"))

                // Mini player toggle button
                Button {
                    HapticService.toggle()
                    self.playerService.toggleMiniPlayerVisibilityByUser()
                } label: {
                    Image(systemName: self.playerService.showMiniPlayer ? "pip.fill" : "pip")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(self.playerService.showMiniPlayer ? .red : .primary.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.pressable)
                .glassEffectID("miniPlayer", in: self.playerNamespace)
                .symbolEffect(.bounce, value: self.playerService.showMiniPlayer)
                .accessibilityIdentifier(AccessibilityID.PlayerBar.miniPlayerButton)
                .accessibilityLabel(String(localized: "Mini Player"))
                .accessibilityValue(self.playerService.showMiniPlayer ? String(localized: "Showing") : String(localized: "Hidden"))
                .disabled(self.playerService.pendingPlayVideoId == nil)
            }

            // Fullscreen now-playing button
            Button {
                HapticService.toggle()
                DiagnosticsLogger.player.debug(
                    "Fullscreen button clicked, toggling showFullscreenNowPlaying from \(self.playerService.showFullscreenNowPlaying)"
                )
                withAnimation(AppAnimation.standard) {
                    player.showFullscreenNowPlaying.toggle()
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.showFullscreenNowPlaying ? .red : .primary.opacity(0.85))
            }
            .buttonStyle(.pressable)
            .glassEffectID("fullscreenNowPlaying", in: self.playerNamespace)
            .accessibilityIdentifier(AccessibilityID.PlayerBar.videoButton)
            .accessibilityLabel(
                self.playerService.isCurrentTrackPodcast
                    ? String(localized: "Fullscreen Podcast")
                    : String(localized: "Fullscreen Now Playing")
            )
            .help(
                self.playerService.isCurrentTrackPodcast
                    ? String(localized: "Fullscreen Podcast")
                    : String(localized: "Fullscreen Now Playing")
            )
            .accessibilityValue(self.playerService.showFullscreenNowPlaying ? String(localized: "On") : String(localized: "Off"))
        }
    }

    private var volumeIcon: String {
        let currentVolume = self.isAdjustingVolume ? self.volumeValue : self.playerService.volume
        if currentVolume == 0 {
            return "speaker.slash.fill"
        } else if currentVolume < 0.5 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }
}

// MARK: - PlayerBarGlassModifier

/// TEMPORARY: applies the player bar's Liquid Glass treatment unless the PerfHUD turned it off
/// to test whether backdrop sampling over the scrolling list is what caps the frame rate.
@available(macOS 26.0, *)
private struct PlayerBarGlassModifier: ViewModifier {
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if PerfHUD.isEnabled, !PerfHUD.shared.usesGlass {
            content
        } else {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("playerBar", in: self.namespace)
        }
    }
}

@available(macOS 26.0, *)
#Preview {
    PlayerBar()
        .environment(PlayerService())
        .environment(WebKitManager.shared)
        .environment(CastService())
        .frame(width: 600)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}
