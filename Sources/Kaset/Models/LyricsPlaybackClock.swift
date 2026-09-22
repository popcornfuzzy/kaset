import Foundation

// MARK: - KaraokeTiming

/// Tunable timing constants for the karaoke lyrics animation.
///
/// Kept in one place so the fill feel can be tuned without hunting through the
/// renderer, and so tests can drive the model with their own values.
struct KaraokeTiming: Equatable, Sendable {
    /// How far ahead of a word's timestamp its fill starts moving, in milliseconds.
    /// Provider timings mark onsets, so leading the fill slightly means the edge is
    /// already moving by the time the word is heard.
    var attackLeadMs: Double = 70

    /// How far before a word's end its fill finishes, so a word completes just as
    /// the next one starts filling.
    var releaseTailMs: Double = 40

    /// Shortest fill ramp, so even a clipped word visibly fills instead of popping.
    var minimumFillMs: Double = 90

    /// Longest fill ramp between two word onsets. Providers timestamp onsets only,
    /// so an unusually long gap should settle rather than crawl across the screen.
    var maximumFillMs: Double = 1200

    /// Fill ramp for a word whose line has no usable duration.
    var fallbackWordMs: Double = 420

    /// Fill ramp for a whole line whose duration is unknown.
    var fallbackLineMs: Double = 3000

    /// A new sample this far from the display clock is a seek or a track change,
    /// not sample jitter.
    var snapThresholdMs: Double = 400

    /// Sample error is spread over this window: the clock changes speed rather than
    /// jumping, so a late sample costs a brief catch-up instead of a visible skip.
    var correctionWindowMs: Double = 250

    /// Fastest the clock may run ahead of (or behind) its nominal rate while
    /// correcting. Below 1.0 so the highlight never rewinds on jitter.
    var maximumRateBias: Double = 0.4

    /// Longest the clock extrapolates past its newest sample before stalling, so a
    /// stalled poll cannot race the highlight down the page.
    var maximumExtrapolationMs: Double = 2000

    /// Longest frame delta applied to the clock, so a rendering hitch cannot
    /// teleport the highlight.
    var maximumFrameMs: Double = 100

    /// How far ahead of a line's own start the auto-scroll starts following it, so
    /// the line is in place when its first word is sung.
    ///
    /// This leads the *scroll* only. The highlight moves when the line it is on is
    /// settled (`KaraokeFillModel.highlightIndex`), never this much ahead of it:
    /// a highlight that arrives early is a line that starts leaving while it is still
    /// being sung.
    var scrollLookaheadMs: Double = 120

    static let standard = KaraokeTiming()
}

// MARK: - LyricsClockSample

/// One playback position sample from the hidden WebView's high-frequency lyrics poll.
struct LyricsClockSample: Equatable, Sendable {
    /// When the sample reached the app.
    let hostTime: Date
    /// Playback position reported by the player, in milliseconds.
    let timeMs: Int
    /// Whether playback was running when the sample was taken.
    let isPlaying: Bool
}

// MARK: - LyricsPlaybackClock

/// Turns the WebView's 10 Hz playback samples into a continuous, display-synced
/// clock for the karaoke highlight.
///
/// Rendering straight from the samples makes the fill step once per poll, and a
/// late or out-of-order sample makes it jump. This clock instead advances on its
/// own between samples and absorbs sample error by *changing its rate*: a sample
/// that lands 120 ms late costs a brief catch-up, not a visible skip. Seeks and
/// track changes snap, because there the sample really has moved.
///
/// Not `@Observable` on purpose: views read it inside `TimelineView`, so mutating
/// it must not invalidate the view hierarchy.
final class LyricsPlaybackClock {
    private let timing: KaraokeTiming
    private var anchor: LyricsClockSample?
    private var displayMs: Double?
    private var lastFrameDate: Date?

    init(timing: KaraokeTiming = .standard) {
        self.timing = timing
    }

    /// The most recent position the clock has been advanced to.
    var displayPositionMs: Double { self.displayMs ?? 0 }

    /// Records a playback sample.
    ///
    /// A sample that disagrees with the display clock by more than
    /// `KaraokeTiming.snapThresholdMs` is treated as a seek: the display position
    /// follows it immediately. Everything smaller is corrected by slewing.
    func receive(_ sample: LyricsClockSample) {
        defer { self.anchor = sample }

        guard let displayMs = self.displayMs else {
            self.displayMs = Double(sample.timeMs)
            return
        }

        let projected = self.projectedPositionMs(sample, at: sample.hostTime)
        if abs(projected - displayMs) > self.timing.snapThresholdMs {
            self.displayMs = projected
        }
    }

    /// Advances the clock to a display frame and returns the position to render.
    @discardableResult
    func advance(to date: Date) -> Double {
        guard let anchor = self.anchor else { return 0 }

        guard let currentDisplayMs = self.displayMs else {
            let start = Double(anchor.timeMs)
            self.displayMs = start
            self.lastFrameDate = date
            return start
        }

        // The first frame establishes the frame origin without moving the highlight,
        // so starting or resetting the clock never steps the fill forward.
        guard let lastFrame = self.lastFrameDate else {
            self.lastFrameDate = date
            return currentDisplayMs
        }

        let target = self.projectedPositionMs(anchor, at: date)
        let error = target - currentDisplayMs
        defer { self.lastFrameDate = date }

        if abs(error) > self.timing.snapThresholdMs {
            self.displayMs = target
            return target
        }

        let frameMs = min(max(date.timeIntervalSince(lastFrame) * 1000, 0), self.timing.maximumFrameMs)
        guard frameMs > 0 else { return currentDisplayMs }

        let bias = min(
            max(error / self.timing.correctionWindowMs, -self.timing.maximumRateBias),
            self.timing.maximumRateBias
        )
        let rate = (anchor.isPlaying ? 1.0 : 0.0) + bias
        // Only a seek moves the highlight backwards, so the fill never un-fills.
        let displayMs = currentDisplayMs + max(0, rate) * frameMs
        self.displayMs = displayMs
        return displayMs
    }

    /// Clears the clock, for a new track.
    func reset() {
        self.anchor = nil
        self.displayMs = nil
        self.lastFrameDate = nil
    }

    private func projectedPositionMs(_ sample: LyricsClockSample, at date: Date) -> Double {
        guard sample.isPlaying else { return Double(sample.timeMs) }
        let elapsed = date.timeIntervalSince(sample.hostTime) * 1000
        return Double(sample.timeMs) + min(max(elapsed, 0), self.timing.maximumExtrapolationMs)
    }
}
