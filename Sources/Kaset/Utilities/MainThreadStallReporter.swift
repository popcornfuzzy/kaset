import Foundation
import os

/// Reports a UI that has stopped responding, and names what the app was doing at the time.
///
/// Every "the UI froze, and then a click let it go" report has one shape — the main thread stopped
/// getting through its work — and `os_log` is the wrong instrument for it: the app's own lines are
/// written *by* that thread, so the lines around a freeze arrive together afterwards with nothing
/// between them to say how long the gap was. This measures from a detached task, which is still running,
/// in the two ways that between them say which failure it was:
///
/// - **How long the main actor took to answer a hop.** A hop comes back when the main actor runs, so the
///   round trip is a stall of the main thread itself.
/// - **Which mode the main runloop is sitting in.** A runloop parked in a mode its observers are not
///   registered for keeps running the app's work while never reaching the point where its UI updates are
///   applied — so the model changes and the screen does not, which reads as a freeze and is not a slow
///   thread at all. Naming the mode settles which of the two happened.
///
/// One line per stall, with the duration and the last step the app said it was on (``note(_:)``), so a
/// freeze names itself instead of being inferred from a missing line. It costs one hop and one mode read
/// every ``interval``, and writes nothing at all while the app is well.
final class MainThreadStallReporter: @unchecked Sendable {
    static let shared = MainThreadStallReporter()

    /// How long an unanswered hop, or a stretch off the default runloop mode, is tolerated before it is
    /// reported.
    private let thresholdSeconds = 0.4
    /// How often the main thread is pinged and its runloop mode read.
    private let interval = Duration.milliseconds(150)
    /// Wall-clock quiet period after a report, so one long stall is one line rather than a burst.
    private let cooldown: TimeInterval = 2

    private let lock = NSLock()
    private var lastStep = "launch"
    private var lastReportedAt = Date.distantPast
    private var isRunning = false
    /// When the current stretch in a mode other than the default one began.
    private var offDefaultModeSince: Date?
    /// The mode that stretch is in, so a change of mode starts a new one rather than extending it.
    private var offDefaultModeName: String?

    private init() {}

    func start() {
        self.lock.lock()
        guard !self.isRunning else {
            self.lock.unlock()
            return
        }
        self.isRunning = true
        self.lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let started = clock.now
                // The hop the measurement *is*: it is answered when the main actor next runs.
                await MainActor.run {}
                let waited = started.duration(to: clock.now)
                self?.check(waited)
                try? await Task.sleep(for: self?.interval ?? .milliseconds(150))
            }
        }
    }

    /// Where the app is, for a stall to be attributed to. Cheap and callable from anywhere on the main
    /// actor — deliberately not a log line: the freeze being measured is the reason its own log line
    /// would not arrive.
    func note(_ step: @autoclosure () -> String) {
        let step = step()
        self.lock.lock()
        self.lastStep = step
        self.lock.unlock()
    }

    private func check(_ waited: Duration) {
        self.reportIfRunLoopIsParked()
        self.reportIfThreadStalled(waited)
    }

    // MARK: - The two measurements

    private func reportIfThreadStalled(_ waited: Duration) {
        let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
        guard seconds > self.thresholdSeconds else { return }
        self.report(seconds: seconds, reason: "main thread")
    }

    /// Reports the main runloop sitting in a mode that is not the default one.
    ///
    /// The main actor keeps its appointments in every mode (its executor is a common-mode source), so the
    /// app keeps working and logging while the runloop is off the default mode — and the updates that
    /// mode is not registered for are the ones that never happen. Measured in stretches, so a mode the app
    /// legitimately enters for a fraction of a second is not reported.
    private func reportIfRunLoopIsParked() {
        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain())
            .map { String(describing: $0) } ?? "none"
        // `String(describing:)` of a runloop mode reads `CFRunLoopMode(rawValue: kCFRunLoopDefaultMode)`, so
        // this is a containment test rather than a suffix one.
        let isDefault = mode.contains("DefaultMode") || mode == "none"
        let now = Date()

        self.lock.lock()
        guard !isDefault else {
            self.offDefaultModeSince = nil
            self.offDefaultModeName = nil
            self.lock.unlock()
            return
        }
        // A different mode is a different stretch, not a longer one.
        if self.offDefaultModeName != mode {
            self.offDefaultModeSince = now
            self.offDefaultModeName = mode
            self.lock.unlock()
            return
        }
        guard let since = self.offDefaultModeSince else {
            self.lock.unlock()
            return
        }
        let seconds = now.timeIntervalSince(since)
        guard seconds > self.thresholdSeconds,
              now.timeIntervalSince(self.lastReportedAt) >= self.cooldown
        else {
            self.lock.unlock()
            return
        }
        self.lastReportedAt = now
        let step = self.lastStep
        self.lock.unlock()

        let message = "Main runloop parked in \(mode) for \(String(format: "%.2f", seconds))s "
            + "— last step: \(step)"
        DiagnosticsLogger.ui.notice("\(message, privacy: .public)")
    }

    private func report(seconds: Double, reason: String) {
        self.lock.lock()
        let now = Date()
        guard now.timeIntervalSince(self.lastReportedAt) >= self.cooldown else {
            self.lock.unlock()
            return
        }
        self.lastReportedAt = now
        let step = self.lastStep
        self.lock.unlock()

        let message = "\(reason) stalled for \(String(format: "%.2f", seconds))s — last step: \(step)"
        DiagnosticsLogger.ui.notice("\(message, privacy: .public)")
    }
}
