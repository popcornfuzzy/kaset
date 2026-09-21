import AVFoundation
import AppKit
import SwiftUI

/// Displays a looping, muted canvas video inside the fullscreen artwork card.
///
/// The video plays with `aspectFill` inside the square artwork frame. The view
/// reports readiness through callbacks so the host can crossfade from the still
/// album artwork only when the first frame can actually render.
struct CanvasVideoView: NSViewRepresentable {
    let url: URL
    var onReadyToPlay: (() -> Void)?
    var onFailure: (() -> Void)?

    func makeNSView(context: Context) -> CanvasVideoNSView {
        let view = CanvasVideoNSView()
        view.onReadyToPlay = self.onReadyToPlay
        view.onFailure = self.onFailure
        view.load(url: self.url)
        return view
    }

    func updateNSView(_ nsView: CanvasVideoNSView, context: Context) {
        nsView.onReadyToPlay = self.onReadyToPlay
        nsView.onFailure = self.onFailure
        if nsView.playerURL != self.url {
            nsView.load(url: self.url)
        }
    }

    /// Tears the player down when SwiftUI removes the view (closing fullscreen
    /// or a track change). Runs on the main thread like the rest of the view.
    static func dismantleNSView(_ nsView: CanvasVideoNSView, coordinator: Void) {
        nsView.teardown()
    }
}

/// AppKit host view that renders a looping `AVPlayerLayer` as a sublayer.
final class CanvasVideoNSView: NSView {
    var onReadyToPlay: (() -> Void)?
    var onFailure: (() -> Void)?

    private(set) var playerURL: URL?

    /// The stalling policy in force for the loaded player. Exposed so a test can
    /// pin the invariant documented in `load(url:)`; setting this to `false`
    /// silently freezes streaming canvases.
    var waitsToMinimizeStalling: Bool {
        self.player?.automaticallyWaitsToMinimizeStalling ?? true
    }

    /// Current position of the loaded player in seconds, or `nil` when nothing
    /// is loaded. Readiness is defined as this value moving, so tests use it to
    /// assert that a ready canvas really is playing.
    var currentPlaybackTime: Double? {
        guard let player = self.player else { return nil }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }

    private var playerLayer: AVPlayerLayer?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentItemObservation: NSKeyValueObservation?
    private var looperStatusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var hasReportedReady = false

    /// Interval for the "has playback actually started" probe. Small enough to
    /// feel instant, large enough to stay off the CPU budget.
    private static let readinessProbeInterval = CMTime(seconds: 0.1, preferredTimescale: 600)

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Keeps the player layer exactly the size of the view. SwiftUI only sizes
    /// the hosted view after `load(url:)` has already run, so at that point
    /// `bounds` is still zero; sizing on layout guarantees the video is never
    /// left in a zero-sized layer.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.playerLayer?.frame = self.bounds
        CATransaction.commit()
    }

    func load(url: URL) {
        self.teardown()
        self.playerURL = url
        self.hasReportedReady = false

        // Create the player layer as a sublayer so it tracks the view bounds
        // and renders reliably regardless of how SwiftUI sizes the view.
        let playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = self.bounds
        self.layer?.addSublayer(playerLayer)
        self.playerLayer = playerLayer

        // NOTE: the template item must NOT be inserted into the queue
        // ourselves — AVPlayerLooper adds its own copies of it. Passing it to
        // AVQueuePlayer(playerItem:) as well makes the item fail immediately.
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        queuePlayer.volume = 0
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        // Leave this at its default. Setting it to `false` tells AVFoundation
        // to never wait for media, and for a stream that cannot start instantly
        // the player then settles at `rate == 0` while still reporting
        // `.playing` — it draws the first frame and never advances the
        // timeline. Every Apple Music canvas is a remote, video-only HLS
        // stream, which is exactly that case: measured over 10s+ the timeline
        // stayed at 0.00 with `false` and started playing immediately with the
        // default. Local files are unaffected, so this only ever hurt the
        // streaming path, but the default is correct for both.
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        playerLayer.player = queuePlayer
        self.player = queuePlayer

        let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        self.looper = looper

        // AVPlayerLooper enqueues its copies of the template item
        // asynchronously: right after init the queue is still empty and
        // `currentItem` is nil. The template item itself is never enqueued, so
        // its status stays `.unknown` forever. Watching `currentItem` instead
        // lets us observe the item the looper actually enqueued.
        self.currentItemObservation = queuePlayer.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let currentItem = player.currentItem
            DispatchQueue.main.async {
                guard let self, self.playerURL == url else { return }
                self.observeFailure(of: currentItem, url: url)
            }
        }

        // The looper reports its own failure separately from the item status.
        self.looperStatusObservation = looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            DispatchQueue.main.async {
                guard let self, self.playerURL == url else { return }
                DiagnosticsLogger.ui.error(
                    "Canvas looper failed: \(url.absoluteString, privacy: .public) — \(looper.error?.localizedDescription ?? "unknown error", privacy: .public)"
                )
                self.onFailure?()
            }
        }

        // Readiness means "the timeline is actually moving", which is the only
        // signal that proves the video is decoding and rendering. An item's
        // `status == .readyToPlay` is not enough: HLS reports it as soon as the
        // playlist has been read, seconds before any frame exists, so
        // crossfading on it reveals an empty black card. This observer fires
        // only while playback advances, so it also never reports readiness for
        // a stalled player; it removes itself after the first tick.
        self.timeObserver = queuePlayer.addPeriodicTimeObserver(
            forInterval: Self.readinessProbeInterval,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playerURL == url else { return }
                self.reportReady(url: url)
            }
        }

        queuePlayer.play()
    }

    /// Reports playback failure through the callback so the host can keep the
    /// still artwork instead of showing a player that will never render.
    private func observeFailure(of item: AVPlayerItem?, url: URL) {
        guard let item else { return }
        self.itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                guard let self, self.playerURL == url else { return }
                DiagnosticsLogger.ui.error(
                    "Canvas video failed: \(url.absoluteString, privacy: .public) — \(item.error?.localizedDescription ?? "unknown error", privacy: .public)"
                )
                self.onFailure?()
            }
        }
    }

    /// Signals readiness exactly once per loaded URL.
    private func reportReady(url: URL) {
        guard !self.hasReportedReady else { return }
        self.hasReportedReady = true
        self.removeTimeObserver()
        DiagnosticsLogger.ui.debug("Canvas video ready: \(url.absoluteString)")
        self.onReadyToPlay?()
    }

    private func removeTimeObserver() {
        guard let timeObserver = self.timeObserver else { return }
        self.player?.removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }

    func teardown() {
        self.currentItemObservation?.invalidate()
        self.currentItemObservation = nil
        self.looperStatusObservation?.invalidate()
        self.looperStatusObservation = nil
        self.itemStatusObservation?.invalidate()
        self.itemStatusObservation = nil
        self.removeTimeObserver()
        self.looper?.disableLooping()
        self.looper = nil
        self.playerLayer?.player = nil
        self.playerLayer?.removeFromSuperlayer()
        self.playerLayer = nil
        self.player?.pause()
        self.player = nil
        self.playerURL = nil
        self.hasReportedReady = false
    }
}
