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

    private var playerLayer: AVPlayerLayer?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentItemObservation: NSKeyValueObservation?
    private var looperStatusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var hasReportedReady = false

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
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
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
                self.observeStatus(of: currentItem, url: url)
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

        queuePlayer.play()
    }

    /// Observes the status of the item the looper enqueued and reports
    /// readiness/failure through the callbacks.
    private func observeStatus(of item: AVPlayerItem?, url: URL) {
        guard let item else { return }
        self.itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.playerURL == url else { return }
                switch item.status {
                case .readyToPlay:
                    guard !self.hasReportedReady else { return }
                    self.hasReportedReady = true
                    DiagnosticsLogger.ui.debug("Canvas video ready: \(url.absoluteString)")
                    self.onReadyToPlay?()
                case .failed:
                    DiagnosticsLogger.ui.error(
                        "Canvas video failed: \(url.absoluteString, privacy: .public) — \(item.error?.localizedDescription ?? "unknown error", privacy: .public)"
                    )
                    self.onFailure?()
                default:
                    break
                }
            }
        }
    }

    func teardown() {
        self.currentItemObservation?.invalidate()
        self.currentItemObservation = nil
        self.looperStatusObservation?.invalidate()
        self.looperStatusObservation = nil
        self.itemStatusObservation?.invalidate()
        self.itemStatusObservation = nil
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
