import Foundation

// MARK: - PlayerService + WebView Loading

/// The player bar's loading strip reads what the shared WebView is doing. The WebView's navigation
/// delegate reports page loads in here, and `state` already says when playback has been asked for
/// but audio has not started, so the bar has one observable source rather than a second channel.
///
/// The page-load fraction is quantized: WebKit reports `estimatedProgress` on every frame of a load,
/// and an `@Observable` write per frame would redraw the bar (and everything else reading the
/// service) far more often than a strip this thin can show. Steps smaller than the quantum are
/// dropped; the value is cleared on the load's own end, so a load can never leave a stale one.
@MainActor
extension PlayerService {
    /// The page-load fraction the strip should step to when a page load starts.
    static let webViewPageLoadQuantum = 0.01

    /// Starts a page load: the strip has a fraction from here until the load ends.
    func beginWebViewPageLoad() {
        self.stopWebViewLoadLinger()
        self.webViewPageLoadFraction = 0
    }

    /// Reports the WebView's own estimate for the page load in flight.
    func updateWebViewPageLoadProgress(_ progress: Double) {
        // The fraction only exists between a load's start and its end. WebKit can report its last
        // estimate in the same turn `didFinish` arrives, and a finished load that takes that estimate
        // would leave a full strip on the bar until the next navigation.
        guard let current = self.webViewPageLoadFraction else { return }

        let clamped = min(max(progress, 0), 1)
        guard abs(current - clamped) >= Self.webViewPageLoadQuantum else { return }

        self.webViewPageLoadFraction = clamped
    }

    /// The page load ended — finished, failed or was replaced. The measurable part is over, so the
    /// strip has no fraction left to cross the bar with; it keeps pulsing for a tail instead, because
    /// the bar cannot know whether anyone saw the load at all (see ``PlayerBarLoadingLinger``).
    func finishWebViewPageLoad() {
        self.webViewPageLoadFraction = nil

        let tail = self.webViewLoadingLingerDuration
        guard tail > 0, self.state != .playing else {
            self.stopWebViewLoadLinger()
            return
        }

        self.isWebViewLoadWarmingUp = true
        self.webViewLoadLingerTask?.cancel()
        self.webViewLoadLingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(tail))
            guard !Task.isCancelled else { return }
            self?.isWebViewLoadWarmingUp = false
            self?.webViewLoadLingerTask = nil
        }
    }

    /// What the player bar's loading strip should draw, or `nil` when there is nothing to wait for.
    var playerBarLoading: PlayerBarLoadingIndicator? {
        PlayerBarLoadingRule.indicator(
            pageLoadFraction: self.webViewPageLoadFraction,
            // `.loading` is exactly "playback has been asked for and the observer has not reported
            // it playing" — the same flag the mini player's fallback and the restored-session resume
            // run on. A paused or idle player has nothing to wait for and reports `nil`.
            isStartingPlayback: self.state == .loading,
            // The tail is about a page that is still being brought up. Once the track it was loaded
            // for is playing there is nothing left to say.
            isWarmingUp: self.isWebViewLoadWarmingUp && self.state != .playing
        )
    }

    /// Ends the lingering strip: a new page load is starting, or the load it belonged to turned out
    /// not to need one.
    private func stopWebViewLoadLinger() {
        self.webViewLoadLingerTask?.cancel()
        self.webViewLoadLingerTask = nil
        self.isWebViewLoadWarmingUp = false
    }
}
