import SwiftUI

// MARK: - SyncedLyricsDisplayView

struct SyncedLyricsDisplayView: View {
    let lyrics: SyncedLyrics
    let currentTimeMs: Int
    /// Whether playback is running, so the display clock can freeze and slew.
    let isPlaying: Bool
    /// Strength of the karaoke glow and lift. The narrow panel carries less of it
    /// than the fullscreen view does.
    var emphasis: Double = 0.55
    /// Whether something is drawn over this panel — the fullscreen player covers it — so
    /// the highlight has to stay correct but does not have to be drawn for anybody.
    var isCovered: Bool = false
    let onSeek: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Interpolated playback clock. Only the line being sung reads it, and it lives
    /// here so the highlight survives line changes and view re-renders.
    @State private var clock = LyricsPlaybackClock()
    /// Measured line layouts, kept across the sheet's re-renders.
    @State private var layoutCache = KaraokeLayoutCache()
    @State private var currentLineId: UUID?
    @State private var currentLineIndex: Int?
    /// Whether the panel is still opening: its first paint (a whole lyric sheet) is the
    /// most expensive frame of its life, and the sidebar is sliding in at the same time, so
    /// during that window the sheet jumps instead of scrolling and applies the highlight
    /// without a spring. Running either through that frame is what made opening the panel
    /// look choppy, and sometimes land in the wrong place.
    @State private var isSettling = true
    /// Whether the user has manually scrolled (pauses auto-scroll).
    @State private var userIsScrolling = false
    /// Timer task to resume auto-scroll after user interaction.
    @State private var scrollResumeTask: Task<Void, Never>?
    @State private var resumeScrollGeneration = 0

    /// How often a row may redraw.
    ///
    /// The line being sung gets the full live rate; the line after it, and the line that
    /// has just finished while it settles, lean on the same clock at the lower *armed*
    /// rate — nothing on them is moving, and their own transitions are Core Animation's,
    /// not ours, so the redraw rate does not affect how they look.
    /// - Parameter animatesWhilePaused: the bouncing pause dot is decorative motion that
    ///   only exists while it is moving, so it keeps its rate when playback is paused.
    private func frameInterval(lineIndex: Int, animatesWhilePaused: Bool = false) -> Double? {
        guard let currentLineIndex, self.isLive(lineIndex: lineIndex) else { return nil }
        // Covered by the fullscreen player: the clock still has to move so the highlight
        // is correct the moment it is visible again, but no one can see the frames.
        if self.isCovered { return KaraokeFrameBudget.covered }
        if self.reduceMotion { return KaraokeFrameBudget.reducedMotion }
        if !self.isPlaying, !animatesWhilePaused { return KaraokeFrameBudget.paused }
        return lineIndex == currentLineIndex ? KaraokeFrameBudget.live : KaraokeFrameBudget.armed
    }

    private var karaokeEmphasis: Double {
        self.reduceMotion ? 0 : self.emphasis
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 60)

                    ForEach(Array(self.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        let status = self.currentStatus(for: index)
                        if self.lyrics.isPauseLine(at: index) || (line.words == nil && line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            KaraokeTimeSource(
                                line: line,
                                status: status,
                                isLive: self.isLive(lineIndex: index),
                                clock: self.clock,
                                minimumFrameInterval: self.frameInterval(lineIndex: index)
                            ) { displayTimeMs in
                                SyncedPauseDotsLineView(
                                    dotStatuses: self.lyrics.pauseDotStatuses(forLineAt: index, at: Int(displayTimeMs)),
                                    status: status,
                                    isSettling: self.isSettling,
                                    minimumFrameInterval: self.frameInterval(lineIndex: index, animatesWhilePaused: true),
                                    onTap: { self.onSeek(line.timeInMs) }
                                )
                            }
                            .id(line.id)
                        } else {
                            SyncedLineView(
                                line: line,
                                lineIndex: index,
                                status: status,
                                isLive: self.isLive(lineIndex: index),
                                clock: self.clock,
                                layoutCache: self.layoutCache,
                                isSettling: self.isSettling,
                                minimumFrameInterval: self.frameInterval(lineIndex: index),
                                emphasis: self.karaokeEmphasis,
                                onTap: { self.onSeek(line.timeInMs) }
                            )
                            .id(line.id)
                        }
                    }

                    Spacer().frame(height: 120)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            // Attach scrolling state to the actual ScrollView rather than relying
            // on a competing gesture recognizer over its content.
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
                        self.scrollToCurrentLine(using: proxy, animated: true)
                    }
                default:
                    break
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        self.userIsScrolling = true
                        self.resumeScrollGeneration += 1
                        self.scrollResumeTask?.cancel()
                    }
                    .onEnded { _ in
                        let generation = self.resumeScrollGeneration
                        self.scrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }
                            self.userIsScrolling = false
                            self.scrollToCurrentLine(using: proxy, animated: true)
                        }
                    }
            )
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                self.receiveClockSample(timeMs: newTimeMs, isPlaying: self.isPlaying)
                self.syncCurrentLine(using: newTimeMs, proxy: proxy, animate: !self.userIsScrolling)
            }
            .onChange(of: self.isPlaying) { _, newIsPlaying in
                // The poll keeps reporting the same position while paused, so it takes
                // the play state to freeze the clock instead of extrapolating past it.
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
                SingletonPlayerWebView.shared.startLyricsPoll()
                SingletonPlayerWebView.shared.sendCurrentLyricsTime()
            }
            .task {
                await self.settleScroll(using: proxy)
            }
            .onDisappear {
                self.scrollResumeTask?.cancel()
            }
        }
    }

    private func receiveClockSample(timeMs: Int, isPlaying: Bool) {
        self.clock.receive(LyricsClockSample(hostTime: Date(), timeMs: timeMs, isPlaying: isPlaying))
    }

    /// Puts the sheet in position after it appears or after it is replaced, and turns the
    /// panel's transitions back on once it has.
    ///
    /// The lazy stack has usually not materialized the scroll target yet, and scrolling to a
    /// row that does not exist does nothing — which left the panel opening at the wrong
    /// position, after which the first line change animated a scroll from there. A jump is
    /// repeated instead: it never animates, so repeating it is invisible, and it always reads
    /// the target from state rather than from the playback time the caller captured (that
    /// value is frozen for the life of this task, and writing the highlight from it dragged
    /// the highlight back to wherever playback was when the panel opened).
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

    /// Whether this row draws from the live display clock. See
    /// `KaraokeFillModel.isLiveRow` for why the line that has just finished is included:
    /// a row that switches between the live and settled frames *while* its status changes
    /// has its subtree replaced mid-transition, and SwiftUI does not animate that.
    private func isLive(lineIndex: Int) -> Bool {
        let line = self.lyrics.lines.indices.contains(lineIndex) ? self.lyrics.lines[lineIndex] : nil
        return KaraokeFillModel.isLiveRow(
            lineIndex: lineIndex,
            currentLineIndex: self.currentLineIndex,
            lineEndMs: line.map { Double($0.timeInMs + max($0.duration, 0)) },
            clockMs: self.clock.displayPositionMs
        )
    }

    private func syncCurrentLine(using timeMs: Int, proxy: ScrollViewProxy, animate: Bool) {
        // Follow slightly ahead of the line's own start so the scroll lands with the
        // first word instead of a poll interval after it.
        let lookahead = Int(KaraokeTiming.standard.scrollLookaheadMs)
        guard let index = self.lyrics.currentLineIndex(at: timeMs + lookahead) else { return }
        let id = self.lyrics.lines[index].id
        self.currentLineIndex = index
        let lineChanged = id != self.currentLineId
        self.currentLineId = id
        guard lineChanged, !self.userIsScrolling else { return }
        // While the panel is still opening, jump: an animated scroll competing with the
        // open animation and the sheet's first paint is what made it stutter.
        if animate, !self.isSettling {
            withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func scrollToCurrentLine(using proxy: ScrollViewProxy, animated: Bool) {
        guard let index = self.currentLineIndex,
              self.lyrics.lines.indices.contains(index)
        else { return }
        let id = self.lyrics.lines[index].id
        if animated {
            withAnimation(.easeInOut(duration: 0.42)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func currentStatus(for lineIndex: Int) -> SyncedLyrics.LineStatus {
        guard let currentLineIndex else { return .upcoming }
        if lineIndex < currentLineIndex { return .previous }
        if lineIndex == currentLineIndex { return .current }
        return .upcoming
    }

}

// MARK: - KaraokeFrameBudget

/// How often a lyric row redraws.
@available(macOS 26.0, *)
enum KaraokeFrameBudget {
    /// The line being sung redraws 60 times a second.
    ///
    /// A karaoke wipe is a slow fill — a few pixels a frame — so 60 is already smoother
    /// than the eye can follow, while a 120 Hz display would pay twice as much for frames
    /// nobody can see. Halving the rate is the single cheapest thing to do about the
    /// animation's cost, and it changes nothing about the animation itself.
    static let live = 1.0 / 60.0

    /// The line *after* the one being sung redraws at half that. It is on screen and filled
    /// by the same clock so it arrives without a jump, but nothing on it moves until its own
    /// start — and by then it is the current line, at the live rate.
    static let armed = 1.0 / 30.0

    /// While the panel is covered by the fullscreen player there is nothing to see, but the
    /// clock still has to be advanced so the highlight is right the moment it reappears
    /// (and so it keeps correcting rather than snapping back from a stale position).
    ///
    /// One frame per playback sample: the clock moves in step with the samples it is fed,
    /// so it neither drifts behind them nor pays for frames in between.
    static let covered = 1.0 / 10.0

    /// While playback is paused the fill is frozen, so a row's frames only exist to take up
    /// a sample correction or a seek — 20 a second is prompt enough for both, and it stops
    /// a paused lyric sheet from repainting an unchanging line 60 times a second.
    static let paused = 1.0 / 20.0

    /// Reduce Motion keeps the fill — it is the information — but drops the decorative
    /// motion and the display-rate redraw that goes with it.
    static let reducedMotion = 1.0 / 20.0
}

// MARK: - KaraokeTimeSource

/// Feeds a lyric row the live display clock while it is being animated, and a
/// settled position otherwise.
///
/// This is what keeps the karaoke animation affordable: past and far-off lines
/// render a single static frame, so only the line being sung and the one after it
/// redraw per display frame.
@available(macOS 26.0, *)
struct KaraokeTimeSource<Content: View>: View {
    let line: SyncedLyricLine
    /// The line's own words, when the caller already has them, so a settled row does
    /// not have to derive them again and again.
    var words: [KaraokeWord] = []
    let status: SyncedLyrics.LineStatus
    /// Whether this row is run by the display clock. The line being sung *and the
    /// line after it* are live, so by the time the highlight moves on, the next
    /// line's fill and swell are already running from their own start — a line can
    /// never first be seen part-way through its first word.
    let isLive: Bool
    let clock: LyricsPlaybackClock
    let minimumFrameInterval: Double?
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        if self.isLive {
            TimelineView(.animation(minimumInterval: self.minimumFrameInterval)) { timeline in
                self.content(self.clock.advance(to: timeline.date))
            }
        } else {
            self.content(KaraokeFillModel.staticTimeMs(for: self.status, words: self.words, line: self.line))
        }
    }
}

// MARK: - SyncedPauseDotsLineView

@available(macOS 26.0, *)
struct SyncedPauseDotsLineView: View {
    let dotStatuses: [SyncedLyrics.PauseDotStatus]
    let status: SyncedLyrics.LineStatus
    /// Whether the panel is still opening, in which case the highlight is applied without
    /// a spring rather than animating through the sheet's most expensive frame.
    var isSettling: Bool = false
    /// The bouncing dot is the only thing here that redraws; it shares the karaoke
    /// frame budget rather than running at the display's refresh rate.
    var minimumFrameInterval: Double?
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { dotIndex in
                self.dotView(for: self.safeDotStatus(at: dotIndex))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .opacity(self.lineOpacity(for: self.status))
        .scaleEffect(self.lineScale(for: self.status), anchor: .leading)
        .animation(.easeInOut(duration: 0.35), value: self.dotStatuses)
        .animation(self.isSettling ? nil : AppAnimation.lyricLine, value: self.status)
        .contentShape(Rectangle())
        .onTapGesture {
            self.onTap()
        }
    }

    @ViewBuilder
    private func dotView(for dotStatus: SyncedLyrics.PauseDotStatus) -> some View {
        let dot = Circle()
            .fill(Color.primary)
            .frame(width: 7, height: 7)
            .opacity(self.dotOpacity(for: dotStatus))

        if dotStatus == .active {
            TimelineView(.animation(minimumInterval: self.minimumFrameInterval)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: 0.72) / 0.72
                let yOffset = -2.8 * (0.5 + 0.5 * sin(phase * 2 * .pi))

                dot.offset(y: yOffset)
            }
        } else {
            dot
        }
    }

    private func safeDotStatus(at index: Int) -> SyncedLyrics.PauseDotStatus {
        guard self.dotStatuses.indices.contains(index) else { return .notSung }
        return self.dotStatuses[index]
    }

    private func dotOpacity(for status: SyncedLyrics.PauseDotStatus) -> Double {
        switch status {
        case .notSung:
            0.28
        case .active:
            1.0
        case .sung:
            0.65
        }
    }

    private func lineScale(for status: SyncedLyrics.LineStatus) -> CGFloat {
        switch status {
        case .current:
            1.0
        case .previous:
            0.95
        case .upcoming:
            0.965
        }
    }

    private func lineOpacity(for status: SyncedLyrics.LineStatus) -> Double {
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

// MARK: - SyncedLineView

struct SyncedLineView: View {
    let line: SyncedLyricLine
    /// Index of this line, so the pause-dot lookup never scans the whole lyric sheet.
    let lineIndex: Int
    let status: SyncedLyrics.LineStatus
    let isLive: Bool
    let clock: LyricsPlaybackClock
    /// Measured line layouts, so a re-render of the sheet never measures a line again.
    let layoutCache: KaraokeLayoutCache
    /// Whether the panel is still opening: the line's emphasis is then applied without a
    /// spring, because a spring running through the sheet's first paint is what made the
    /// panel's opening look choppy and its scaling look like it jumped.
    var isSettling: Bool = false
    let minimumFrameInterval: Double?
    let emphasis: Double
    let onTap: () -> Void

    private static let fontSize: CGFloat = 16

    var body: some View {
        // Measured once per line, not once per frame or per sheet re-render: a frame of
        // the wipe of this line is then arithmetic and drawing only.
        let layout = self.layoutCache.layout(for: self.line, fontSize: Self.fontSize)

        return KaraokeTimeSource(
            line: self.line,
            words: layout.words,
            status: self.status,
            isLive: self.isLive,
            clock: self.clock,
            minimumFrameInterval: self.minimumFrameInterval
        ) { displayTimeMs in
            self.content(at: displayTimeMs, layout: layout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(self.opacity(for: self.status))
        .scaleEffect(self.scale(for: self.status), anchor: .leading)
        .offset(y: self.drift(for: self.status))
        .padding(.vertical, 5)
        .animation(self.isSettling ? nil : AppAnimation.lyricLine, value: self.status)
        .contentShape(Rectangle())
        .onTapGesture {
            self.onTap()
        }
    }

    @ViewBuilder
    private func content(at displayTimeMs: Double, layout: KaraokeLineLayout) -> some View {
        if self.line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A short instrumental gap that is not long enough for the pause dots.
            Text("♪")
                .font(.system(size: Self.fontSize, weight: .bold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            KaraokeLyricsLineView(
                layout: layout,
                displayTimeMs: displayTimeMs,
                color: .primary,
                emphasis: self.emphasis,
                lineSpacing: 2
            )
            .fixedSize(horizontal: false, vertical: true)
        }
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

    /// Neighbouring lines sit slightly off their slot, so a line settles into place
    /// as it becomes the line being sung.
    private func drift(for status: SyncedLyrics.LineStatus) -> CGFloat {
        switch status {
        case .current:
            0
        case .previous:
            -3
        case .upcoming:
            3
        }
    }
}
