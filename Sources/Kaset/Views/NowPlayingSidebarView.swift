import AppKit
import SwiftUI

// MARK: - NowPlayingSidebarView

/// The artwork-first right sidebar: a real column of the window, not a panel floating over it.
///
/// `MainWindow` lays it out in an `HStack` beside the navigation split view, so it behaves like the
/// navigation sidebar — a resizable column with a toolbar toggle — rather than floating over the
/// content. (The system `.inspector` is not used: resizing its nested split controller aborts the
/// app.) It is the alternative to the classic `LyricsView`/`QueueSidePanelView` panels and is chosen
/// in Settings (`SettingsManager.nowPlayingSidebarEnabled`); both designs stay in the app and each
/// keeps its own presentation state.
///
/// The overview *is* the column: the cover art edge to edge at the top, the title and artist under
/// it, then a live three-line lyric window and the next song. Each of those two sections opens its
/// full page inside the same column.
@available(macOS 26.0, *)
struct NowPlayingSidebarView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService
    @Environment(CanvasService.self) private var canvasService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the column this view is drawn in, supplied by the window.
    ///
    /// The column's width is owned by `MainWindow` — the divider drags it and the window's minimum is
    /// derived from it — so the sidebar takes it as input rather than measuring itself. A *measured*
    /// width lags the frame it measures by one layout pass, which is what left the artwork and the
    /// embedded queue a step behind the column while the divider was being dragged, so the contents
    /// looked like they were tearing away from their own width.
    var columnWidth: CGFloat = 380

    /// Height of the column this view is drawn in, supplied by the window's pane.
    ///
    /// Measured by `ShellPane` **in the same layout pass** it is drawn in — the artwork gives up height
    /// on a short window, so it needs the column's height as well as its width, and a height remembered
    /// from a previous pass would make the artwork step a frame behind during a drag.
    var columnHeight: CGFloat = 0

    /// Lyrics lookup state, owned here rather than by the lyric surfaces.
    ///
    /// The three-line window, the expanded sheet and the empty states are views over one lookup, and
    /// the page can flip between them at any moment; keeping the state on the root (which stays
    /// mounted for as long as the sidebar is up) means a page change never looks like a new track and
    /// never re-runs the search. Same pipeline as `LyricsView`, so the sidebar states lyrics exactly
    /// the way the classic panel does.
    /// AppKit's inset for the window's toolbar, handed down with the column's size (see `ShellPane`).
    ///
    /// The column's pane reaches the window's top edge, but its *content* is inset by this much — the
    /// toolbar band — which is why the cover art used to start below a blank strip. The artwork is pulled
    /// up by exactly this amount so it is flush with the window's top edge (the documented design: the
    /// artwork is genuinely *behind* the toolbar, not below it) while the pages' own headers stay below it.
    var topInset: CGFloat = 0
    @State private var lastLoadedVideoId: String?
    @State private var lastLoadedSignature: String?
    @State private var loadTask: Task<Void, Never>?

    /// What the lyric surfaces can show for the current track.
    private enum LyricsState {
        case noTrack
        case loading
        case synced(SyncedLyrics)
        case plain(Lyrics)
        case unavailable(String?)
    }

    var body: some View {
        if let page = self.playerService.nowPlayingSidebarPage {
            self.pageContent(page)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // The background is a modifier, never a ZStack sibling: it can then fill the column and
                // bleed under the toolbar without ever taking part in the content's layout. As a stack
                // child it could grow the column's layout box and push everything in the page off the
                // column's edge, which is exactly what happened.
                .background {
                    // The wash bleeds *up* only, so the sidebar's colour still reaches the window's top
                    // edge and reads as one surface behind the toolbar. Ignoring every edge (as this
                    // once did) also let it bleed sideways into the content, which looked like the whole
                    // column had been padded on the left. And because it is a background modifier it can
                    // never take part in the content's layout, so it cannot grow the column either.
                    NowPlayingSidebarBackground(
                        artworkURL: self.playerService.currentTrack?.thumbnailURL?.highQualityThumbnailURL
                            ?? self.playerService.currentTrack?.thumbnailURL,
                        identity: self.playerService.currentTrack?.videoId
                    )
                    .ignoresSafeArea(edges: .top)
                }
                // The column's height arrives as `columnHeight`: `ShellPane` resolves it in the layout
                // pass that draws this view, so the artwork follows a resize in the same frame. This
                // used to measure its own height here, which handed the page the *previous* pass's
                // number and made the cover step behind the divider during a drag.
                //
                // The *artwork* is pulled up over the toolbar band (see `overview`), so the cover reaches
                // the window's top edge; nothing else in the column ignores the inset, so the pages'
                // headers keep their normal place below the toolbar.
                //
                // The inset comes from the pane (`ShellPane`), not from a measurement here — it is a
                // property of the pane's safe area, and measuring it in the column made the artwork's
                // top edge a second, later-reading of it.
                // The artwork's top edge is a function of this number, so it is the one value that says
                // whether the cover reaches the window's top edge.
                .onChange(of: self.topInset) { _, newInset in
                    let message = "Now Playing column top inset: \(Int(newInset)) "
                        + "columnWidth=\(Int(self.columnWidth)) columnHeight=\(Int(self.columnHeight))"
                    DiagnosticsLogger.ui.info("\(message, privacy: .public)")
                }
                .accessibilityIdentifier(AccessibilityID.NowPlayingSidebar.container)
            .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
                self.loadTask?.cancel()
                self.startLyricsLoad(for: newVideoId)
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
            .onChange(of: self.playerService.isPlaying) { _, isPlaying in
                guard isPlaying else { return }
                self.startLyricsLoad(for: self.playerService.currentTrack?.videoId)
            }
            .onChange(of: self.syncedLyricsService.currentLyrics) { _, newLyrics in
                self.updateLyricsPolling(for: newLyrics)
            }
            .task(id: self.canvasTaskID) {
                await self.loadCanvasWhenReady()
            }
            .task {
                self.updateLyricsPolling(for: self.syncedLyricsService.currentLyrics)
                if case .synced = self.syncedLyricsService.currentLyrics {
                    SingletonPlayerWebView.shared.sendCurrentLyricsTime()
                }
                guard let videoId = self.playerService.currentTrack?.videoId else { return }
                await self.loadLyricsWhenReady(for: videoId)
            }
            .onDisappear {
                // Hand the poll over when the fullscreen player takes the lyrics (opening it closes
                // the sidebar in the same update); otherwise the sidebar was closed for good.
                if !LyricsPollHandoff.shouldKeepPollingAfterSidebarDisappears(
                    isFullscreenPresented: self.playerService.showFullscreenNowPlaying,
                    hasSyncedLyrics: self.syncedLyricsService.hasSyncedLyrics(
                        for: self.playerService.currentTrack?.videoId
                    )
                ) {
                    SingletonPlayerWebView.shared.stopLyricsPoll()
                }
            }
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private func pageContent(_ page: NowPlayingSidebarPage) -> some View {
        switch page {
        case .lyrics:
            self.lyricsPage
        case .queue:
            self.queuePage
        case .overview:
            self.overview
        }
    }

    // MARK: - Overview

    private var overview: some View {
        VStack(spacing: 0) {
            NowPlayingSidebarArtwork(
                track: self.playerService.currentTrack,
                canvasURL: self.canvasURL,
                height: self.artworkHeight,
                reduceMotion: self.reduceMotion
            )
            // Up by the toolbar band, so the cover is flush with the window's top edge and runs behind
            // the toolbar instead of starting below a blank strip. The negative padding, not an offset:
            // it moves the artwork's frame *and* takes the same amount off its layout height, so the rows
            // under it still begin at the artwork's visible bottom edge.
            .padding(.top, -self.topInset)

            self.trackTitles
                .padding(.horizontal, NowPlayingSidebarLayout.padding)
                .padding(.top, 2)
                .padding(.bottom, 14)

            self.lyricsSection
                .padding(.horizontal, NowPlayingSidebarLayout.padding)

            self.upNextSection
                .padding(.horizontal, NowPlayingSidebarLayout.padding)
                .padding(.top, 10)

            Spacer(minLength: 0)
        }
    }

    /// Title and artist. Not a card: Apple Music puts them straight on the artwork's own color, under
    /// the cover, and so does this.
    private var trackTitles: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.playerService.currentTrack?.title ?? String(localized: "No Song Playing"))
                .font(.system(size: 17, weight: .bold))
                .lineLimit(2)
                .accessibilityIdentifier(AccessibilityID.NowPlayingSidebar.trackTitle)

            Text(self.trackArtistText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The artwork is a square until a short window makes it give up height to the rows below it.
    ///
    /// It follows the column's authoritative width, so it is always exactly as wide as the column -
    /// no lag, no overshoot that would push it past the column's edge mid-resize.
    private var artworkHeight: CGFloat {
        let width = self.columnWidth > 0
            ? self.columnWidth
            : NowPlayingSidebarLayout.artworkMaxDimension

        // Before the first layout the height is unknown, not zero: sizing from the width alone
        // (a square) is stable and correct on a normal window, whereas treating the height as zero
        // would open the column on a 150pt stub and pop it to full a frame later.
        guard self.columnHeight > 0 else {
            return min(width, NowPlayingSidebarLayout.artworkMaxHeight)
        }

        let leftover = self.columnHeight - NowPlayingSidebarLayout.reservedHeight
        return min(
            width,
            NowPlayingSidebarLayout.artworkMaxHeight,
            max(NowPlayingSidebarLayout.artworkMinHeight, leftover)
        )
    }

    // MARK: - Lyrics Section

    private var lyricsSection: some View {
        NowPlayingSidebarCard {
            VStack(alignment: .leading, spacing: 4) {
                self.sectionHeader(
                    title: String(localized: "Lyrics"),
                    systemImage: "quote.bubble",
                    expandLabel: String(localized: "Open the full lyrics"),
                    identifier: AccessibilityID.NowPlayingSidebar.lyricsSection,
                    action: { self.expand(to: .lyrics) }
                )

                Group {
                    if self.syncedLyricsService.searchingForBetterLyrics, self.hasSyncedLyricsOnScreen {
                        LyricsSearchingCaption(horizontalPadding: 0, verticalPadding: 2)
                    }
                }
                .animation(.smooth(duration: 0.4), value: self.syncedLyricsService.searchingForBetterLyrics)

                self.lyricsPreview
                    .frame(height: NowPlayingSidebarLayout.lyricsPreviewHeight)
            }
        }
    }

    /// Three lines of the *same* sheet the classic panel and the fullscreen player render: same rows,
    /// same karaoke wipe, same emphasis, and the sheet's own centering keeps the line being sung in
    /// the middle of the window.
    ///
    /// It is windowed, not a different renderer: the only difference is that it may not be dragged
    /// (a stray scroll in a window this short would push the highlight out of it), and its rows open
    /// the full page rather than seeking, which is what "expandable" means here.
    @ViewBuilder
    private var lyricsPreview: some View {
        switch self.lyricsState {
        case .noTrack:
            LyricsStateView(
                icon: "play.circle",
                title: String(localized: "No Song Playing"),
                message: String(localized: "Play a song to view its lyrics here.", comment: "No song playing lyrics message"),
                compact: true
            )
        case .loading:
            LyricsStateView(
                icon: nil,
                title: String(localized: "Loading lyrics...", comment: "Lyrics panel loading state"),
                message: self.loadingProviderText,
                isLoading: true,
                compact: true
            )
        case let .synced(synced):
            // The clock stream stops at the sheet (`LyricsClockReader`): this column's artwork,
            // cards and wash do not change with playback, and rebuilding all of them ten times a
            // second to hand the preview a position was the largest thing the column did.
            LyricsClockReader { currentTimeMs, isPlaying, isFullscreenPresented in
                SyncedLyricsDisplayView(
                    lyrics: synced,
                    currentTimeMs: currentTimeMs,
                    isPlaying: isPlaying,
                    // The fullscreen player covers the window and deliberately leaves this column
                    // open behind it, so a preview behind the player is covered: it draws no frames
                    // rather than a line being sung at full rate where nobody can see it.
                    isCovered: isFullscreenPresented,
                    allowsScrolling: false,
                    onSeek: { _ in self.expand(to: .lyrics) }
                )
            }
            .mask(NowPlayingSidebarLayout.lyricsPreviewFadeMask)
        case .plain:
            LyricsStateView(
                icon: "text.quote",
                title: String(localized: "These lyrics aren't synced"),
                message: String(localized: "Open them to read the whole song."),
                compact: true
            )
        case .unavailable:
            LyricsStateView(
                icon: "music.note",
                title: String(localized: "No Lyrics Available"),
                message: self.syncedLyricsService.errorMessage
                    ?? String(localized: "There aren't any lyrics available for this song."),
                compact: true
            )
        }
    }

    // MARK: - Up Next Section

    private var upNextSection: some View {
        NowPlayingSidebarCard {
            VStack(alignment: .leading, spacing: 8) {
                self.sectionHeader(
                    title: String(localized: "Up Next"),
                    systemImage: "list.bullet",
                    trailing: self.upNextCountText,
                    expandLabel: String(localized: "Open the queue"),
                    identifier: AccessibilityID.NowPlayingSidebar.upNextSection,
                    action: { self.expand(to: .queue) }
                )

                Button {
                    self.expand(to: .queue)
                } label: {
                    NowPlayingSidebarUpNext(song: self.upNextSong)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open the queue"))
            }
        }
    }

    // MARK: - Expanded Pages

    @ViewBuilder
    private var lyricsPage: some View {
        // No header of its own: the back control and this page's name are the window toolbar's, in the
        // band above the column (`NowPlayingSidebarToolbarHeader`). A header drawn here would sit *below*
        // that band — the band is the window's chrome, so content cannot be laid out in it — which is what
        // left a strip of empty column above every page while only the artwork filled it.
        VStack(spacing: 0) {
            switch self.lyricsState {
            case .noTrack:
                LyricsStateView(
                    icon: "play.circle",
                    title: String(localized: "No Song Playing"),
                    message: String(localized: "Play a song to view its lyrics here.", comment: "No song playing lyrics message")
                )
            case .loading:
                LyricsStateView(
                    icon: nil,
                    title: String(localized: "Loading lyrics...", comment: "Lyrics panel loading state"),
                    message: self.loadingProviderText,
                    isLoading: true
                )
            case let .synced(synced):
                VStack(spacing: 0) {
                    LyricsClockReader { currentTimeMs, isPlaying, isFullscreenPresented in
                        SyncedLyricsDisplayView(
                            lyrics: synced,
                            currentTimeMs: currentTimeMs,
                            isPlaying: isPlaying,
                            // Covered while the fullscreen player is up: no frames at all.
                            isCovered: isFullscreenPresented,
                            onSeek: { timeMs in
                                Task { await self.playerService.seek(to: Double(timeMs) / 1000.0) }
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(AccessibilityID.NowPlayingSidebar.lyricsPage)

                    LyricsSourceFooter(
                        source: synced.source,
                        horizontalPadding: NowPlayingSidebarLayout.padding
                    )
                }
            case let .plain(plain):
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(plain.text)
                                .font(.system(size: 15, weight: .medium))
                                .lineSpacing(8)
                                .textSelection(.enabled)

                            if let attribution = plain.attribution, attribution.hasSubmitter {
                                LyricsSubmitterCredit(attribution: attribution)
                                    .padding(.top, 24)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                    }
                    .scrollIndicators(.hidden)

                    LyricsSourceFooter(
                        source: plain.source,
                        horizontalPadding: NowPlayingSidebarLayout.padding
                    )
                }
            case let .unavailable(message):
                LyricsStateView(
                    icon: "quote.bubble",
                    title: String(localized: "No Lyrics Available"),
                    message: message ?? String(localized: "There aren't any lyrics available for this song.")
                )
            }
        }
        .padding(.horizontal, NowPlayingSidebarLayout.padding)
    }

    @ViewBuilder
    private var queuePage: some View {
        // The column's own header is the toolbar's (see `lyricsPage`), so the queue starts at the top of
        // the column: its rows run from the toolbar band's bottom edge down to the footer.
        VStack(spacing: 0) {
            // The queue's own header would be a second title under the column's header, and its card
            // chrome belongs to the floating panel — everything else (automix chips, reordering,
            // undo/redo, clear) is the same queue the classic panel shows.
            //
            // No width is handed to it: a scalar width here was this page's own copy of the column's
            // width, one layout pass behind the divider, so the queue's rows and their trailing controls
            // moved a frame after the column edge did. The panel fills the width it is inside instead,
            // and its table sizes its column to that width in its own layout pass.
            QueueSidePanelView(
                width: nil,
                showsHeader: false,
                usesMaterialBackground: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, NowPlayingSidebarLayout.padding)
            .accessibilityIdentifier(AccessibilityID.NowPlayingSidebar.queuePage)
        }
    }

    // MARK: - Section Header

    /// A section's label and its expand affordance. The section's *content* is what expands on a
    /// click, so this stays the quiet part of the row — the way a sidebar noun behaves.
    private func sectionHeader(
        title: String,
        systemImage: String,
        trailing: String? = nil,
        expandLabel: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expandLabel)
        .accessibilityIdentifier(identifier)
        .accessibilityHint(expandLabel)
    }

    // MARK: - Model

    private var lyricsState: LyricsState {
        guard let track = self.playerService.currentTrack else { return .noTrack }
        if self.syncedLyricsService.isLoading
            || self.syncedLyricsService.currentLyricsVideoId != track.videoId
        {
            return .loading
        }

        switch self.syncedLyricsService.currentLyrics {
        case let .synced(synced): return .synced(synced)
        case let .plain(plain): return .plain(plain)
        case .unavailable: return .unavailable(self.syncedLyricsService.errorMessage)
        }
    }

    /// Whether the sheet currently on screen is a synced one. Gates the "still searching for better
    /// lyrics" caption, which only means something while a lower-fidelity synced result is drawn.
    private var hasSyncedLyricsOnScreen: Bool {
        if case .synced = self.lyricsState { return true }
        return false
    }

    private var trackArtistText: String {
        guard let track = self.playerService.currentTrack else { return String(localized: "Nothing playing") }
        return track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay
    }

    private var loadingProviderText: String? {
        guard let provider = self.syncedLyricsService.loadingProvider else { return nil }
        return String(localized: "Searching \(provider)")
    }

    /// Index of the first song still to play: everything after the highlighted row, or the whole
    /// queue while it has no highlight (YouTube autoplay, a station).
    private var upNextIndex: Int {
        (self.playerService.queueHighlightIndex ?? -1) + 1
    }

    private var upNextSong: Song? {
        let queue = self.playerService.queue
        let index = self.upNextIndex
        guard queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    private var upNextCountText: String? {
        let remaining = max(0, self.playerService.queue.count - self.upNextIndex)
        guard remaining > 0 else { return nil }
        return String(localized: "\(remaining) left")
    }

    /// Canvas to crossfade over the still artwork, or `nil` when there is nothing to show: the feature
    /// is off, the track is an episode, or the lookup has not resolved a canvas for this track.
    private var canvasURL: URL? {
        guard SettingsManager.shared.animatedCanvasEnabled,
              !self.playerService.isCurrentTrackPodcast,
              let track = self.playerService.currentTrack,
              self.canvasService.currentCanvasVideoId == track.videoId
        else { return nil }
        return self.canvasService.currentCanvasURL
    }

    // MARK: - Actions

    private func expand(to page: NowPlayingSidebarPage) {
        HapticService.toggle()
        withAnimation(AppAnimation.standard) {
            self.playerService.setNowPlayingSidebarPage(page)
        }
    }

    // MARK: - Canvas Loading

    /// Restarts the canvas lookup when the sidebar appears or the track changes (`.task(id:)` cancels
    /// the previous lookup). The lookup is cache-backed, so re-running it for an unchanged track costs
    /// no network request.
    private var canvasTaskID: String {
        "\(self.playerService.isNowPlayingSidebarVisible)|\(self.playerService.currentTrack?.videoId ?? "none")"
    }

    @MainActor
    private func loadCanvasWhenReady() async {
        guard self.playerService.isNowPlayingSidebarVisible else { return }
        guard let videoId = self.playerService.currentTrack?.videoId else { return }

        for _ in 0 ..< 40 {
            guard !Task.isCancelled,
                  self.playerService.isNowPlayingSidebarVisible,
                  self.playerService.currentTrack?.videoId == videoId
            else { return }

            // Wait for the WebView's observed metadata: searching on the queue entry or the
            // "Loading..." placeholder matches the wrong artwork.
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

    // MARK: - Lyrics Loading

    private func updateLyricsPolling(for result: LyricResult) {
        if case .synced = result {
            SingletonPlayerWebView.shared.startLyricsPoll()
        } else {
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
    }

    @MainActor
    private func startLyricsLoad(for videoId: String?, forceRefresh: Bool = false) {
        self.loadTask?.cancel()
        self.loadTask = nil
        guard let videoId else { return }
        // A new track, a refined metadata signature, or an explicit refresh all warrant a rerun; an
        // unchanged track and metadata do not.
        guard forceRefresh
            || videoId != self.lastLoadedVideoId
            || self.lyricsSignature(for: videoId) != self.lastLoadedSignature
        else { return }
        self.loadTask = Task { await self.loadLyricsWhenReady(for: videoId, forceRefresh: forceRefresh) }
    }

    /// Re-runs a search that already ran for this track when the metadata it used has since been
    /// refined — the failure mode where the panel searched before the WebView reported the new song
    /// and then stayed on "No Lyrics Available". A result already on screen is never re-searched on a
    /// metadata tweak.
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

    /// Identity of the metadata a search would run with. It changes when the WebView refines the
    /// title/artist or the duration settles, which is exactly when a search that ran against
    /// incomplete metadata should be retried.
    private func lyricsSignature(for videoId: String) -> String? {
        guard let metadata = self.playerService.lyricsSearchMetadata(for: videoId) else { return nil }
        let duration = self.playerService.duration > 0
            ? self.playerService.duration
            : (self.playerService.currentTrack?.duration ?? 0)
        return "\(videoId)|\(metadata.title)|\(metadata.artist)|\(Int(duration.rounded()))"
    }

    @MainActor
    private func loadLyricsWhenReady(for videoId: String, forceRefresh: Bool = false) async {
        for _ in 0 ..< 40 {
            guard !Task.isCancelled,
                  self.playerService.currentTrack?.videoId == videoId
            else { return }

            // Wait for the WebView's observed metadata before searching: it is the authoritative,
            // normalized title/artist. Searching on the queue entry or the "Loading..." placeholder
            // makes the providers match the wrong song (or nothing) and can leave the wrong lyrics on
            // screen.
            if self.playerService.hasObservedWebMetadata(for: videoId),
               self.playerService.lyricsSearchMetadata(for: videoId) != nil
            {
                await self.loadLyrics(for: videoId, forceRefresh: forceRefresh)
                return
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        // The WebView never reported metadata in time: fall back to the current track's metadata
        // rather than leaving the panel empty forever.
        if self.playerService.lyricsSearchMetadata(for: videoId) != nil {
            await self.loadLyrics(for: videoId, forceRefresh: forceRefresh)
        }
    }

    @MainActor
    private func loadLyrics(for videoId: String, forceRefresh: Bool = false) async {
        guard let track = self.playerService.currentTrack, track.videoId == videoId else { return }
        guard let metadata = self.playerService.lyricsSearchMetadata(for: videoId) else { return }

        self.lastLoadedVideoId = videoId
        self.lastLoadedSignature = self.lyricsSignature(for: videoId)

        let info = LyricsSearchInfo(
            title: metadata.title,
            artist: metadata.artist,
            album: track.album?.title,
            duration: self.playerService.duration > 0 ? self.playerService.duration : track.duration,
            videoId: videoId
        )

        if SettingsManager.shared.syncedLyricsEnabled {
            await self.syncedLyricsService.fetchLyrics(for: info, forceRefresh: forceRefresh)
        } else {
            self.syncedLyricsService.currentLyrics = .unavailable
            self.syncedLyricsService.activeProvider = nil
            self.syncedLyricsService.currentLyricsVideoId = videoId
        }
    }
}

@available(macOS 26.0, *)
#Preview {
    NowPlayingSidebarView()
        .environment(PlayerService())
        .environment(SyncedLyricsService())
        .environment(CanvasService())
        .frame(width: 380, height: 760)
}
