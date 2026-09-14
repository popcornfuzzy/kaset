import AppKit
import SwiftUI

// MARK: - PerfHUD
//
// TEMPORARY DIAGNOSTIC — remove this file and its call sites once the scroll investigation is
// finished. See docs/adr/0014-playlist-scroll-performance.md for the investigation notes.
//
// Purpose: turn "scrolling feels like 30fps" into numbers, and let the expensive layers be
// switched off one at a time so the cause can be isolated in a single session instead of by
// guessing.
//
// Enable with either:
//   defaults write <bundle-id> KasetPerfHUD -bool YES
//   KASET_PERF_HUD=1 (only reaches the process when launched from a shell, not via `open`)

/// Samples main-run-loop passes. A rendered frame shows up as one pass whose *active* phase is
/// the main-thread work for that frame, which is what distinguishes "our CPU is too slow" from
/// "the compositor is too slow".
///
/// - `busy` ≈ the main-thread time each frame needs. If this is small while frames still arrive
///   every ~33ms, the cost is in compositing (glass/backdrop sampling, materials), not our code.
/// - `interval` ≈ the time between frames, i.e. the real frame cadence.
///
/// All access happens on the main thread: the run-loop observer fires there and `snapshot()` is
/// called from the main actor.
private final class FramePassSampler: @unchecked Sendable {
    /// Ignore gaps longer than this between passes — the app was idle, not rendering frames.
    private static let maximumTrackedInterval: Double = 100

    /// How many samples to keep for the rolling statistics.
    private static let windowSize = 240

    private var observer: CFRunLoopObserver?
    private var passStart: CFAbsoluteTime = 0
    private var intervals: [Double] = []
    private var busyTimes: [Double] = []
    private var observerCount = 0

    struct Snapshot {
        let passesPerSecond: Double
        let medianInterval: Double
        let p95Interval: Double
        let worstInterval: Double
        let medianBusy: Double
        let p95Busy: Double
        let worstBusy: Double
        /// Passes whose active phase exceeded 8 ms (missed a 120 Hz+ deadline) and 16 ms (missed
        /// even a 60 Hz deadline). Counting these is the honest jank metric — the pass *rate* is
        /// not a frame rate, because the run loop cycles many times per rendered frame.
        let over8ms: Int
        let over16ms: Int
        let samples: Int
    }

    func start() {
        guard self.observer == nil else { return }

        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        self.observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities.rawValue,
            true,
            0
        ) { [weak self] _, activity in
            self?.record(activity: activity)
        }

        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private func record(activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()

        switch activity {
        case .afterWaiting:
            // A pass is starting: the main thread is awake and about to do work.
            if self.passStart > 0 {
                let interval = (now - self.passStart) * 1000
                if interval < Self.maximumTrackedInterval {
                    self.intervals.append(interval)
                    if self.intervals.count > Self.windowSize {
                        self.intervals.removeFirst(self.intervals.count - Self.windowSize)
                    }
                }
            }
            self.passStart = now

        case .beforeWaiting:
            // The pass is done with its work; whatever is left before the next frame is waiting.
            guard self.passStart > 0 else { return }
            self.busyTimes.append((now - self.passStart) * 1000)
            if self.busyTimes.count > Self.windowSize {
                self.busyTimes.removeFirst(self.busyTimes.count - Self.windowSize)
            }

        default:
            break
        }
    }

    func reset() {
        self.intervals.removeAll()
        self.busyTimes.removeAll()
        self.passStart = 0
    }

    func snapshot() -> Snapshot {
        let intervals = self.intervals.sorted()
        let busy = self.busyTimes.sorted()
        let sampleCount = intervals.count

        guard sampleCount > 3, let medianInterval = Self.percentile(intervals, 0.5) else {
            return Snapshot(
                passesPerSecond: 0,
                medianInterval: 0,
                p95Interval: 0,
                worstInterval: 0,
                medianBusy: 0,
                p95Busy: 0,
                worstBusy: 0,
                over8ms: 0,
                over16ms: 0,
                samples: sampleCount
            )
        }

        return Snapshot(
            passesPerSecond: medianInterval > 0 ? 1000 / medianInterval : 0,
            medianInterval: medianInterval,
            p95Interval: Self.percentile(intervals, 0.95) ?? 0,
            worstInterval: intervals.last ?? 0,
            medianBusy: Self.percentile(busy, 0.5) ?? 0,
            p95Busy: Self.percentile(busy, 0.95) ?? 0,
            worstBusy: busy.last ?? 0,
            over8ms: self.busyTimes.filter { $0 > 8 }.count,
            over16ms: self.busyTimes.filter { $0 > 16 }.count,
            samples: sampleCount
        )
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

// MARK: - PerfHUD

/// Temporary frame-rate readout plus layer switches used to isolate scroll cost.
@available(macOS 26.0, *)
@MainActor
@Observable
final class PerfHUD {
    static let shared = PerfHUD()

    /// Whether the HUD should be shown at all.
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["KASET_PERF_HUD"] == "1"
        || UserDefaults.standard.bool(forKey: "KasetPerfHUD")

    // MARK: Layer switches

    /// Liquid Glass effects (the player bar's interactive glass, panels, popovers).
    var usesGlass = true
    /// The bottom player bar, including its 2 Hz progress updates and hover tracking.
    var showsPlayerBar = true
    /// Per-page accent background gradient and top fade overlay.
    var usesPageEffects = true
    /// The persistent WebView / mini player layer.
    var showsWebLayer = true
    /// Backdrop materials inside cards and badges.
    var usesMaterials = true

    // MARK: Measurements

    var passesPerSecond: Double = 0
    var medianFrameMilliseconds: Double = 0
    var p95FrameMilliseconds: Double = 0
    var medianBusyMilliseconds: Double = 0
    var p95BusyMilliseconds: Double = 0
    var worstBusyMilliseconds: Double = 0
    var slowPasses: Int = 0
    var verySlowPasses: Int = 0
    var sampleCount = 0
    /// The display's refresh rate, for reference.
    var displayMaximumFPS = 0

    private let sampler = FramePassSampler()
    private var publishTask: Task<Void, Never>?
    private var didStart = false

    private init() {}

    func start() {
        guard Self.isEnabled, !self.didStart else { return }
        self.didStart = true

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            self.displayMaximumFPS = screen.maximumFramesPerSecond
        }

        self.sampler.start()

        // Publish at 4 Hz: the HUD must not add per-frame work of its own.
        self.publishTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.publish()
            }
        }
    }

    private func publish() {
        let snapshot = self.sampler.snapshot()
        self.passesPerSecond = snapshot.passesPerSecond
        self.medianFrameMilliseconds = snapshot.medianInterval
        self.p95FrameMilliseconds = snapshot.p95Interval
        self.medianBusyMilliseconds = snapshot.medianBusy
        self.p95BusyMilliseconds = snapshot.p95Busy
        self.worstBusyMilliseconds = snapshot.worstBusy
        self.slowPasses = snapshot.over8ms
        self.verySlowPasses = snapshot.over16ms
        self.sampleCount = snapshot.samples
    }

    /// Resets the rolling window so a before/after comparison within one session is meaningful.
    func reset() {
        self.sampler.reset()
        self.passesPerSecond = 0
        self.medianFrameMilliseconds = 0
        self.p95FrameMilliseconds = 0
        self.medianBusyMilliseconds = 0
        self.p95BusyMilliseconds = 0
        self.worstBusyMilliseconds = 0
        self.slowPasses = 0
        self.verySlowPasses = 0
        self.sampleCount = 0
    }
}

// MARK: - PerfHUDOverlay

/// The on-screen readout. Deliberately drawn without glass, materials, or shadows so measuring
/// does not change what is being measured.
@available(macOS 26.0, *)
struct PerfHUDOverlay: View {
    @State private var hud = PerfHUD.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(String(format: "%.0f loop/s", self.hud.passesPerSecond))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Text("display \(self.hud.displayMaximumFPS) Hz")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(String(
                format: "busy p50 %.1f  p95 %.1f  max %.1f\npass p50 %.1f  p95 %.1f\nover 8ms %d/%d   over 16ms %d",
                self.hud.medianBusyMilliseconds,
                self.hud.p95BusyMilliseconds,
                self.hud.worstBusyMilliseconds,
                self.hud.medianFrameMilliseconds,
                self.hud.p95FrameMilliseconds,
                self.hud.slowPasses,
                self.hud.sampleCount,
                self.hud.verySlowPasses
            ))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)

            Divider()

            self.toggle("Glass", isOn: self.hud.usesGlass) { self.hud.usesGlass.toggle() }
            self.toggle("PlayerBar", isOn: self.hud.showsPlayerBar) { self.hud.showsPlayerBar.toggle() }
            self.toggle("PageFX", isOn: self.hud.usesPageEffects) { self.hud.usesPageEffects.toggle() }
            self.toggle("WebLayer", isOn: self.hud.showsWebLayer) { self.hud.showsWebLayer.toggle() }
            self.toggle("Materials", isOn: self.hud.usesMaterials) { self.hud.usesMaterials.toggle() }

            Button("Reset") { self.hud.reset() }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.black.opacity(0.82))
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .foregroundStyle(.white)
        .padding(10)
    }

    private func toggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "square.fill" : "square")
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(isOn ? .white : .white.opacity(0.45))
        }
        .buttonStyle(.plain)
    }
}
