import SwiftUI
import WebKit

// MARK: - MiniPlayerWebView

/// A visible WebView that displays the YouTube Music player.
/// This is required because YouTube Music won't initialize the video player
/// without user interaction - autoplay is blocked in hidden WebViews.
/// Uses SingletonPlayerWebView for the actual WebView instance.
struct MiniPlayerWebView: NSViewRepresentable {
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(PlayerService.self) private var playerService

    /// The video ID to play.
    let videoId: String

    /// Callback for player state changes.
    var onStateChange: ((PlayerState) -> Void)?

    /// Callback for metadata updates (title, artist, duration).
    var onMetadataChange: ((String, String, Double) -> Void)?

    enum PlayerState {
        case loading
        case playing
        case paused
        case ended
        case error(String)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onStateChange: self.onStateChange, onMetadataChange: self.onMetadataChange)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true

        // Get or create the singleton WebView
        let webView = SingletonPlayerWebView.shared.getWebView(
            webKitManager: self.webKitManager,
            playerService: self.playerService
        )

        // Remove existing handler if present to avoid duplicates, then add fresh one
        // This handles the case where makeNSView is called multiple times
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: "miniPlayer")
        contentController.add(context.coordinator, name: "miniPlayer")

        // Ensure WebView is in this container
        SingletonPlayerWebView.shared.ensureInHierarchy(container: container)

        // Load the video if needed
        SingletonPlayerWebView.shared.loadVideo(videoId: self.videoId)

        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        // Update WebView frame if needed
        SingletonPlayerWebView.shared.ensureInHierarchy(container: container)
    }

    static func dismantleNSView(_: NSView, coordinator _: Coordinator) {
        // WebView is managed by SingletonPlayerWebView.shared - it persists
        // Remove the message handler to avoid duplicate handlers
        SingletonPlayerWebView.shared.webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "miniPlayer")
    }

    // MARK: - Observer Script

    /// Script that observes the YouTube Music player bar and sends updates
    private static var observerScript: String {
        """
        (function() {
            'use strict';

            const bridge = window.webkit.messageHandlers.miniPlayer;

            function log(msg) {
                console.log('[MiniPlayer] ' + msg);
            }

            // Wait for the player bar to appear and observe it
            function waitForPlayerBar() {
                const playerBar = document.querySelector('ytmusic-player-bar');
                if (playerBar) {
                    log('Player bar found, setting up observer');
                    setupObserver(playerBar);
                    return;
                }
                setTimeout(waitForPlayerBar, 500);
            }

            function setupObserver(playerBar) {
                const observer = new MutationObserver(function(mutations) {
                    sendUpdate();
                });

                observer.observe(playerBar, {
                    attributes: true,
                    characterData: true,
                    childList: true,
                    subtree: true,
                    attributeOldValue: true,
                    characterDataOldValue: true
                });

                // Send initial update
                sendUpdate();

                // Also send periodic updates
                setInterval(sendUpdate, 1000);
            }

            function sendUpdate() {
                try {
                    const titleEl = document.querySelector('.ytmusic-player-bar.title');
                    const artistEl = document.querySelector('.ytmusic-player-bar.byline');
                    const progressBar = document.querySelector('#progress-bar');

                    const title = titleEl ? titleEl.textContent : '';
                    const artist = artistEl ? artistEl.textContent : '';
                    const progress = progressBar ? parseInt(progressBar.getAttribute('value') || '0') : 0;
                    const duration = progressBar ? parseInt(progressBar.getAttribute('aria-valuemax') || '0') : 0;

                    // Use video element's paused property for language-agnostic detection
                    // Previously checked button title/aria-label which fails for non-English locales
                    const video = document.querySelector('video');
                    const isPlaying = video ? !video.paused : false;

                    bridge.postMessage({
                        type: 'STATE_UPDATE',
                        title: title,
                        artist: artist,
                        progress: progress,
                        duration: duration,
                        isPlaying: isPlaying
                    });
                } catch (e) {
                    log('Error sending update: ' + e);
                }
            }

            // Start waiting
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', waitForPlayerBar);
            } else {
                waitForPlayerBar();
            }
        })();
        """
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onStateChange: ((PlayerState) -> Void)?
        var onMetadataChange: ((String, String, Double) -> Void)?

        init(
            onStateChange: ((PlayerState) -> Void)?,
            onMetadataChange: ((String, String, Double) -> Void)?
        ) {
            self.onStateChange = onStateChange
            self.onMetadataChange = onMetadataChange
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            // Page loaded
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            self.onStateChange?(.error(error.localizedDescription))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebView content process crashed - attempt recovery by reloading
            DiagnosticsLogger.player.error("MiniPlayer WebView content process terminated, attempting reload")
            self.onStateChange?(.error("Player crashed, reloading..."))
            webView.reload()
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            if type == "STATE_UPDATE" {
                let title = body["title"] as? String ?? ""
                let artist = body["artist"] as? String ?? ""
                let duration = body["duration"] as? Double ?? 0
                let isPlaying = body["isPlaying"] as? Bool ?? false

                if !title.isEmpty {
                    self.onMetadataChange?(title, artist, duration)
                }

                self.onStateChange?(isPlaying ? .playing : .paused)
            }
        }
    }
}

// MARK: - SingletonPlayerWebView

/// Manages a single WebView instance for the entire app lifetime.
/// This ensures there's only ever ONE WebView playing audio.
///
/// Extensions provide:
/// - Playback controls (SingletonPlayerWebView+PlaybackControls.swift)
/// - Observer script (SingletonPlayerWebView+ObserverScript.swift)
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    private(set) var webView: WKWebView?
    var currentVideoId: String?
    var coordinator: Coordinator?
    let logger = DiagnosticsLogger.player

    /// What the page in the WebView is for. A page that is not being played from must not report, and
    /// a page loaded early must not be replaced (see ``PlayerWebViewPage``).
    private(set) var page: PlayerWebViewPage = .empty

    /// Progress observation for the page load in flight, replaced with each WebView.
    private var estimatedProgressObservation: NSKeyValueObservation?

    /// The YouTube Music shell: the cheapest page that warms the app, and one that carries no track.
    /// It is held silent like a preloaded track — a shell left to itself could play something the app
    /// is not tracking.
    private static var shellURL: URL? {
        Self.url(path: "/", queryItems: [Self.preloadHoldQueryItem])
    }

    /// Name of the query flag that marks a page Kaset loads only to have ready. The page's own gate
    /// reads it (see ``preloadGateScript``) so a warm page cannot make a sound before the user asks.
    static let preloadQueryFlagName = "kaset_preload"

    /// Value of the query flag that marks a page loaded only to be ready.
    static let preloadQueryFlagValue = "1"

    /// The query item that marks a page as loaded only to be ready.
    private static var preloadHoldQueryItem: URLQueryItem {
        URLQueryItem(name: Self.preloadQueryFlagName, value: Self.preloadQueryFlagValue)
    }

    /// Builds a YouTube Music URL.
    private static func url(path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.youtube.com"
        components.path = path
        components.queryItems = queryItems
        return components.url
    }

    /// A watch URL for the shared WebView.
    ///
    /// - Parameter startAt: position the player should begin from, passed as YouTube's own `t`
    ///   parameter. A restored session resumes from where it left off, and having the page *start*
    ///   there is what makes the resume instant instead of a seek after the fact.
    /// - Parameter holdsSilent: marks the page as one loaded only to be ready, so its own autoplay is
    ///   held until Kaset or the user asks for sound.
    static func watchURL(videoId: String, startAt: TimeInterval? = nil, holdsSilent: Bool = false) -> URL? {
        var queryItems = [URLQueryItem(name: "v", value: videoId)]

        if let startAt, startAt >= 1 {
            queryItems.append(URLQueryItem(name: "t", value: "\(Int(startAt.rounded(.down)))s"))
        }
        if holdsSilent {
            queryItems.append(Self.preloadHoldQueryItem)
        }

        return Self.url(path: "/watch", queryItems: queryItems)
    }

    /// Whether this URL is the shell rather than a watch page.
    static func isShellURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.host() == "music.youtube.com" && (url.path().isEmpty || url.path() == "/")
    }

    /// How `loadVideo` behaves when Swift already tracks a `videoId` (repeat-one vs queue drift recovery).
    enum VideoLoadStrategy: Equatable {
        /// Skip navigation when `videoId` matches `currentVideoId`.
        case standard
        /// Same `videoId` as tracked: `seek(0)` + play only (fast). Different id: full watch URL load.
        case preferInPlaceWhenSameVideoId
        /// Same `videoId` as tracked: full `webView.load` (DOM out of sync with Swift). Different id: full load.
        case forceFullPageWhenSameVideoId
    }

    private var mediaControlUsesNextPrev: Bool
    private var miniPlayerPresentationEnabled = false
    private var miniPlayerPrefersVideo = false
    private var miniPlayerViewportSize = CGSize(width: 320, height: 180)

    private init() {
        self.mediaControlUsesNextPrev = SettingsManager.shared.mediaControlStyle == .nextPreviousTrack
    }

    /// Get or create the singleton WebView.
    func getWebView(
        webKitManager: WebKitManager,
        playerService: PlayerService
    ) -> WKWebView {
        if let existing = webView {
            return existing
        }

        self.logger.info("Creating singleton WebView")

        // Create coordinator
        self.coordinator = Coordinator(playerService: playerService)

        let configuration = webKitManager.createWebViewConfiguration()

        // Add script message handler
        configuration.userContentController.add(self.coordinator!, name: "singletonPlayer")

        // Note: We do NOT inject a static volume init script here because the volume
        // may change between WebView creation and page loads. Instead, we:
        // 1. Set __kasetTargetVolume in loadVideo() before loading a new page
        // 2. Update it in didFinish after each page load completes
        // This ensures we always use the CURRENT volume, not a stale value.

        // Keep the page preference in sync before any page script reads localStorage.
        let mediaControlBootstrapScript = WKUserScript(
            source: self.mediaControlBootstrapScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(mediaControlBootstrapScript)

        let adBlockingFlagScript = WKUserScript(
            source: "window.__kasetSafeAdBlockingEnabled = \(SettingsManager.shared.safeAdBlockingEnabled ? "true" : "false");",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(adBlockingFlagScript)

        if SettingsManager.shared.safeAdBlockingEnabled {
            // Strip ad payload fields from player responses before YouTube Music consumes them.
            let adPruningScript = WKUserScript(
                source: Self.adPruningScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(adPruningScript)
        }

        // Inject mediaSession override at document end without allowing duplicate RAF loops.
        let mediaOverrideScript = WKUserScript(
            source: Self.mediaControlOverrideScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(mediaOverrideScript)

        // Inject observer script (at document end)
        let script = WKUserScript(
            source: Self.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)

        // The preload gate, ahead of everything: a page Kaset loads only to have ready must not be
        // able to make a sound before the user asks for it. See `preloadGateScript`.
        let preloadGateScript = WKUserScript(
            source: Self.preloadGateScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(preloadGateScript)

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = self.coordinator
        newWebView.customUserAgent = WebKitManager.userAgent

        #if DEBUG
            newWebView.isInspectable = true
        #endif

        // The page load's own estimate, which is what the player bar's loading strip fills from. It
        // is the only measurable wait the player has, so it is read from WebKit rather than
        // guessed at: nothing about a YouTube Music page load is observable from the outside.
        self.estimatedProgressObservation = newWebView.observe(\.estimatedProgress, options: [.new]) { webView, _ in
            MainActor.assumeIsolated {
                playerService.updateWebViewPageLoadProgress(webView.estimatedProgress)
            }
        }

        self.webView = newWebView
        return newWebView
    }

    /// Loads the YouTube Music shell into a WebView that has nothing in it, so the first play of a
    /// session does not have to wait for the app to boot (see ``PlayerWebViewPreload``).
    ///
    /// Safe to call on every layout pass: it does nothing once a page has been navigated to.
    func loadShellIfNeeded() {
        guard let webView,
              PlayerWebViewPreload.canLoadShell(currentVideoId: self.currentVideoId, page: self.page),
              let shellURL = Self.shellURL
        else { return }

        self.page = .shell
        self.logger.info("Preloading the YouTube Music shell")
        webView.load(URLRequest(url: shellURL))
    }

    /// Loads a track's watch page early, held silent, so the first press of play starts the song
    /// instead of loading it (see ``PlayerWebViewPreload``).
    ///
    /// - Parameter startAt: position to resume from, for a restored session that has not been resumed
    ///   yet. Passing it in the URL means the page is already in place when play is pressed.
    ///
    /// Safe to call on every layout pass: it does nothing once a watch page is up.
    func preloadVideo(videoId: String, startAt: TimeInterval? = nil) {
        guard let webView,
              PlayerWebViewPreload.canLoadPreload(currentVideoId: self.currentVideoId, page: self.page),
              let url = Self.watchURL(videoId: videoId, startAt: startAt, holdsSilent: true)
        else { return }

        self.logger.info("Preloading watch page for \(videoId)")
        self.currentVideoId = videoId
        self.page = .preloaded
        webView.load(URLRequest(url: url))
    }

    /// Lifts the preload hold, so the page may make sound again.
    ///
    /// Called by every control Kaset drives. The page's own player was told it started playing when
    /// the hold swallowed its autoplay, so the gate also brings the page back in line with reality:
    /// without that, the first play/pause click in a preloaded page would be a *pause*.
    func releasePreloadHold() {
        guard self.page == .preloaded else { return }
        self.page = .playback
        self.logger.info("Releasing the preload hold")
        self.webView?.evaluateJavaScript(
            "window.__kasetPreloadStandDown && window.__kasetPreloadStandDown();",
            completionHandler: nil
        )
    }

    /// Hands a page the user can now see back to them.
    ///
    /// The mini player *is* the page's own controls, so a visible page is no longer a placeholder and
    /// no longer held: whatever it plays, the user asked for it there and the app tracks it like any
    /// other page. Nothing else makes a silent page authoritative.
    func handOverToUser() {
        guard self.page.isSilent else { return }
        self.logger.info("Handing the visible page over to the user")
        self.releasePreloadHold()
        self.page = .playback
    }

    /// Whether the page in the WebView has finished loading.
    ///
    /// A preload still in flight is not ready to be asked to play: its own scripts have not run yet.
    var isPageReady: Bool {
        !(self.webView?.isLoading ?? true)
    }

    /// Whether a page for `videoId` is up and usable for playback.
    ///
    /// Kaset's own watch page for the track qualifies, and so does a finished preload of it — that is
    /// the case the preload exists for, and playing it needs no navigation. A preload still loading
    /// does not: the track then takes the ordinary path, which navigates properly rather than asking a
    /// page that is not there yet to play.
    func canPlay(videoId: String) -> Bool {
        guard self.currentVideoId == videoId else { return false }
        guard self.page == .preloaded else { return true }
        return self.isPageReady
    }

    /// Ensures the WebView is in the given container's view hierarchy.
    func ensureInHierarchy(container: NSView) {
        guard let webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)

        // Use autoresizing to match container size.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
    }

    /// Updates the DOM presentation for the mini player overlay.
    /// When expanded, the page chrome is hidden and the video surface is prioritized.
    func updateMiniPlayerPresentation(isExpanded: Bool, prefersVideo: Bool, viewportSize: CGSize) {
        let previousIsExpanded = self.miniPlayerPresentationEnabled
        let previousPrefersVideo = self.miniPlayerPrefersVideo

        self.miniPlayerPresentationEnabled = isExpanded
        self.miniPlayerPrefersVideo = prefersVideo
        self.miniPlayerViewportSize = CGSize(
            width: max(1, viewportSize.width),
            height: max(1, viewportSize.height)
        )

        // A page the user can see is the page's own controls: if the mini player has just been
        // revealed, a silent page stops being silent and stops being treated as a placeholder.
        if isExpanded, !previousIsExpanded {
            self.handOverToUser()
        }

        // Ignore pure size changes while staying expanded; the container now scales with 100% sizing.
        guard previousIsExpanded != isExpanded || previousPrefersVideo != prefersVideo else {
            return
        }

        self.applyMiniPlayerPresentationScript()
    }

    /// Re-applies mini player DOM presentation after navigation finishes.
    func reapplyMiniPlayerPresentationIfNeeded() {
        self.applyMiniPlayerPresentationScript()
    }

    private func applyMiniPlayerPresentationScript() {
        guard let webView else { return }

        let isExpandedLiteral = self.miniPlayerPresentationEnabled ? "true" : "false"
        let prefersVideoLiteral = self.miniPlayerPrefersVideo ? "true" : "false"

        let script = """
            (function() {
                const enabled = \(isExpandedLiteral);
                const prefersVideo = \(prefersVideoLiteral);

                const styleId = 'kaset-mini-player-video-style';
                const containerId = 'kaset-video-container';
                const blackoutId = 'kaset-video-blackout';
                const timerIdKey = '__kasetMiniPlayerVideoTimer';

                window.__kasetMiniPlayerPresentationEnabled = enabled;
                window.__kasetMiniPlayerPrefersVideo = prefersVideo;

                function clearPresentationTimer() {
                    if (window[timerIdKey]) {
                        clearInterval(window[timerIdKey]);
                        window[timerIdKey] = null;
                    }
                }

                function ensureStyle() {
                    let style = document.getElementById(styleId);
                    if (!style) {
                        style = document.createElement('style');
                        style.id = styleId;
                        (document.head || document.documentElement).appendChild(style);
                    }

                    style.textContent = `
                        html, body, ytmusic-app, #layout, #content, #contents {
                            background: #000 !important;
                            overflow: hidden !important;
                            pointer-events: none !important;
                            cursor: default !important;
                        }

                        *, *::before, *::after {
                            cursor: default !important;
                        }

                        ytmusic-nav-bar,
                        ytmusic-player-bar,
                        ytmusic-guide-renderer,
                        tp-yt-app-drawer,
                        ytmusic-notification-action-renderer,
                        ytmusic-player-page #tabs,
                        ytmusic-player-page #side-panel,
                        .ytp-chrome-top,
                        .ytp-chrome-bottom,
                        .ytp-gradient-top,
                        .ytp-gradient-bottom,
                        .ytp-cards-button,
                        .ytp-endscreen-content,
                        .ytp-ce-element,
                        .ytmusic-player-page-player-controls {
                            display: none !important;
                        }

                        #${containerId} {
                            position: fixed !important;
                            inset: 0 !important;
                            width: 100% !important;
                            height: 100% !important;
                            background: #000 !important;
                            z-index: 2147483646 !important;
                            overflow: hidden !important;
                            pointer-events: none !important;
                        }

                        #${containerId} video {
                            width: 100% !important;
                            height: 100% !important;
                            object-fit: contain !important;
                            background: #000 !important;
                            pointer-events: none !important;
                        }
                    `;
                }

                function removeStyle() {
                    const style = document.getElementById(styleId);
                    if (style) style.remove();
                }

                function ensureContainer() {
                    let container = document.getElementById(containerId);
                    if (!container) {
                        container = document.createElement('div');
                        container.id = containerId;
                        (document.body || document.documentElement).appendChild(container);
                    }
                    return container;
                }

                function removeContainer() {
                    const container = document.getElementById(containerId);
                    if (container) container.remove();
                }

                function ensureBlackout() {
                    let blackout = document.getElementById(blackoutId);
                    if (!blackout) {
                        blackout = document.createElement('div');
                        blackout.id = blackoutId;
                        blackout.style.position = 'fixed';
                        blackout.style.inset = '0';
                        blackout.style.background = '#000';
                        blackout.style.zIndex = '2147483645';
                        blackout.style.pointerEvents = 'none';
                        (document.body || document.documentElement).appendChild(blackout);
                    }
                    return blackout;
                }

                function removeBlackout() {
                    const blackout = document.getElementById(blackoutId);
                    if (blackout) blackout.remove();
                }

                function findVideoToggle() {
                    const controls = Array.from(
                        document.querySelectorAll('button, tp-yt-paper-button, [role="button"], [role="tab"]')
                    );
                    return controls.find((element) => {
                        const text = (element.textContent || element.innerText || '').trim().toLowerCase();
                        const label = (element.getAttribute('aria-label') || '').trim().toLowerCase();
                        return text === 'video'
                            || text === 'musikvideo'
                            || text === 'music video'
                            || label === 'video'
                            || label.includes('video');
                    });
                }

                function ensureVideoTabSelected() {
                    if (!window.__kasetMiniPlayerPrefersVideo) return;

                    const button = findVideoToggle();
                    if (!button) return;

                    const isSelected = button.getAttribute('aria-selected') === 'true'
                        || button.getAttribute('aria-pressed') === 'true'
                        || button.classList.contains('selected')
                        || button.classList.contains('is-selected');

                    if (!isSelected) {
                        button.click();
                    }
                }

                function extractVideoToContainer() {
                    const video = document.querySelector('video');
                    if (!video) return false;

                    const hasFrame = video.readyState >= 2 || video.videoWidth > 0;
                    if (!hasFrame) return false;

                    const container = ensureContainer();

                    if (!window.__kasetMiniPlayerVideoExtracted) {
                        window.__kasetMiniPlayerOriginalParent = video.parentElement || null;
                        window.__kasetMiniPlayerOriginalNextSibling = video.nextSibling || null;
                        window.__kasetMiniPlayerVideoExtracted = true;
                    }

                    if (video.parentElement !== container) {
                        container.appendChild(video);
                    }

                    video.controls = false;
                    return true;
                }

                function restoreVideoToOriginalParent() {
                    const video = document.querySelector('video');
                    const originalParent = window.__kasetMiniPlayerOriginalParent;
                    const originalNextSibling = window.__kasetMiniPlayerOriginalNextSibling;

                    if (video && originalParent) {
                        if (originalNextSibling && originalNextSibling.parentNode === originalParent) {
                            originalParent.insertBefore(video, originalNextSibling);
                        } else {
                            originalParent.appendChild(video);
                        }
                    }

                    window.__kasetMiniPlayerVideoExtracted = false;
                    window.__kasetMiniPlayerOriginalParent = null;
                    window.__kasetMiniPlayerOriginalNextSibling = null;
                    removeContainer();
                    removeStyle();
                    removeBlackout();
                }

                if (!enabled) {
                    clearPresentationTimer();
                    restoreVideoToOriginalParent();
                    return;
                }

                ensureStyle();
                ensureBlackout();
                ensureVideoTabSelected();

                let attempts = 0;
                clearPresentationTimer();
                window[timerIdKey] = setInterval(function() {
                    if (!window.__kasetMiniPlayerPresentationEnabled) {
                        clearPresentationTimer();
                        restoreVideoToOriginalParent();
                        return;
                    }

                    attempts += 1;
                    ensureStyle();
                    ensureVideoTabSelected();

                    const extracted = extractVideoToContainer();
                    if (extracted) {
                        clearPresentationTimer();
                        removeBlackout();
                        return;
                    }

                    if (attempts >= 40) {
                        clearPresentationTimer();
                        removeBlackout();
                    }
                }, 150);
            })();
        """

        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                self?.logger.debug("Failed to apply mini player presentation script: \(error.localizedDescription)")
            }
        }
    }

    /// Starts high frequency polling for synced lyrics
    func startLyricsPoll() {
        self.webView?.evaluateJavaScript("if (window.startLyricsPoll) { window.startLyricsPoll(); }")
    }

    func sendCurrentLyricsTime() {
        self.webView?.evaluateJavaScript("if (window.sendLyricsTime) { window.sendLyricsTime(); }")
    }

    /// Stops high frequency polling for synced lyrics
    func stopLyricsPoll() {
        self.webView?.evaluateJavaScript("if (window.stopLyricsPoll) { window.stopLyricsPoll(); }")
    }

    /// Updates runtime ad-blocking flag inside the persistent WebView without requiring a reload.
    func setSafeAdBlockingEnabled(_ enabled: Bool) {
        self.webView?.evaluateJavaScript("window.__kasetSafeAdBlockingEnabled = \(enabled ? "true" : "false");")
    }

    /// Load a video, stopping any currently playing audio first.
    /// Note: Full page navigation destroys the video element; same-id restarts use ``restartInPlaceFromBeginning()`` when possible.
    func loadVideo(videoId: String, strategy: VideoLoadStrategy = .standard) {
        guard let webView else {
            self.logger.error("loadVideo called but webView is nil")
            return
        }

        let previousVideoId = self.currentVideoId

        switch strategy {
        case .standard:
            if videoId == previousVideoId {
                // That page may be the preload for this very track, which is already where the
                // navigation would have gone. It only has to be let go of and started, exactly as a
                // fresh page would have started itself — and the hold *must* be lifted here, because
                // this path returns before any control could ask for it, leaving the track silent.
                if self.page == .preloaded, self.isPageReady {
                    self.logger.info("Using the preloaded page for \(videoId)")
                    self.releasePreloadHold()
                    self.play()
                    return
                }

                // A preload that has not finished is not ready to play from, and the hold it carries
                // cannot be lifted into a document that does not exist yet: the track is loaded
                // properly below instead, which cancels the held load and plays the ordinary way.
                if self.page == .preloaded {
                    self.logger.info("Preload for \(videoId) is still loading; loading it for playback")
                } else {
                    self.logger.debug("Video \(videoId) already loaded, skipping")
                    return
                }
            }
        case .preferInPlaceWhenSameVideoId:
            if videoId == previousVideoId {
                self.logger.debug("In-place restart for \(videoId) (same id — avoid full page reload)")
                self.restartInPlaceFromBeginning()
                return
            }
        case .forceFullPageWhenSameVideoId:
            if videoId == previousVideoId {
                self.logger.info("Force full navigation for \(videoId) (DOM/WebView resync)")
            }
        }

        if videoId != previousVideoId {
            self.logger.info("Loading video: \(videoId) (was: \(previousVideoId ?? "none"))")
        }

        // Update currentVideoId immediately to prevent duplicate loads
        self.currentVideoId = videoId
        // A watch page is a playback page: from here the page's observations are the app's own.
        self.page = .playback

        // Get current volume from PlayerService via coordinator
        let currentVolume = self.coordinator?.playerService.volume ?? 1.0
        self.logger.info("Will apply volume \(currentVolume) after page load")

        // Stop current playback first, then load new video. A playback load carries no preload hold:
        // this page is meant to play.
        guard let urlToLoad = Self.watchURL(videoId: videoId) else { return }
        webView.evaluateJavaScript("document.querySelector('video')?.pause()") { [weak self] _, _ in
            guard let self, let webView = self.webView else { return }

            // Set target volume BEFORE loading so it's ready when video element appears
            let setTargetScript = "window.__kasetTargetVolume = \(currentVolume);"
            webView.evaluateJavaScript(setTargetScript, completionHandler: nil)

            webView.load(URLRequest(url: urlToLoad))
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let playerService: PlayerService

        init(playerService: PlayerService) {
            self.playerService = playerService
        }

        // MARK: Page loads

        /// A page load started: the player bar's strip has a fraction to fill now.
        func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            self.playerService.beginWebViewPageLoad()
        }

        /// A page load ended without a document. Nothing measurable is left, so the strip's fraction
        /// goes away; whether the bar keeps waiting is `PlayerBarLoadingRule`'s question.
        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            self.playerService.finishWebViewPageLoad()
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            // A page that is not being played from must not report: the shell has no track, and a
            // preloaded page is a player that was told it started when its autoplay was swallowed.
            // Believing either would put a track that is not playing into the app's state.
            let observation = SingletonPlayerWebView.shared.page.observation
            guard observation != .none else { return }

            // A page Kaset is not playing from gets to report one thing only: which track it is
            // showing. Everything else it could say — its player's position, its end-of-track and
            // remote-control signals, its ads — describes playback Kaset does not want; see
            // `PlayerWebViewObservation`.
            let isAuthoritative = observation == .playback
            if !isAuthoritative, type != "STATE_UPDATE" {
                return
            }

            let observedVideoId: String? = if let videoId = body["videoId"] as? String, !videoId.isEmpty {
                videoId
            } else {
                nil
            }

            if type == "TRACK_ENDED" {
                Task { @MainActor in
                    await self.playerService.handleTrackEnded(observedVideoId: observedVideoId)
                }
                return
            }

            if type == "AD_STATE" {
                guard SettingsManager.shared.safeAdBlockingEnabled else { return }
                let isAd = body["isAd"] as? Bool ?? false
                Task { @MainActor in
                    self.playerService.updateAdPlaybackState(isAd)
                }
                return
            }

            if type == "REMOTE_NEXT" {
                Task { @MainActor in
                    await self.playerService.nextFromRemoteControl()
                }
                return
            }

            if type == "REMOTE_PREVIOUS" {
                Task { @MainActor in
                    await self.playerService.previousFromRemoteControl()
                }
                return
            }

            // Handle high frequency lyrics time updates
            if type == "LYRICS_TIME" {
                if let time = body["time"] as? Double {
                    Task { @MainActor in
                        self.playerService.currentTimeMs = Int(time * 1000)
                    }
                }
                return
            }

            guard type == "STATE_UPDATE" else { return }

            let isPlaying = body["isPlaying"] as? Bool ?? false
            let progress = body["progress"] as? Int ?? 0
            let duration = body["duration"] as? Int ?? 0
            let title = body["title"] as? String ?? ""
            let artist = body["artist"] as? String ?? ""
            let thumbnailUrl = body["thumbnailUrl"] as? String ?? ""
            let trackChanged = body["trackChanged"] as? Bool ?? false
            let likeStatusString = body["likeStatus"] as? String ?? "INDIFFERENT"
            let hasVideo = body["hasVideo"] as? Bool ?? false
            let isAd = body["isAd"] as? Bool ?? false
            let videoWidth = (body["videoWidth"] as? Int) ?? Int((body["videoWidth"] as? Double) ?? 0)
            let videoHeight = (body["videoHeight"] as? Int) ?? Int((body["videoHeight"] as? Double) ?? 0)
            let adBlockingEnabled = SettingsManager.shared.safeAdBlockingEnabled

            // Parse like status
            let likeStatus: LikeStatus = switch likeStatusString {
            case "LIKE":
                .like
            case "DISLIKE":
                .dislike
            default:
                .indifferent
            }

            Task { @MainActor in
                guard isAuthoritative else {
                    // A preloaded page describes a performance that never happened, so none of its
                    // playback state applies — but the track it is holding does, and reconciling it
                    // here is what leaves the first press of play landing on a song that is already
                    // fully described rather than one that fills itself in seconds later.
                    self.playerService.reconcilePreloadedTrackMetadata(
                        title: title,
                        artist: artist,
                        thumbnailUrl: thumbnailUrl,
                        videoId: observedVideoId
                    )
                    return
                }

                self.playerService.updatePlaybackState(
                    isPlaying: isPlaying,
                    progress: Double(progress),
                    duration: Double(duration)
                )

                self.playerService.updateAdPlaybackState(adBlockingEnabled ? isAd : false)

                // Update video availability
                self.playerService.updateVideoAvailability(hasVideo: hasVideo)
                self.playerService.updateMiniPlayerVideoDimensions(width: videoWidth, height: videoHeight)

                // Update like status only when track changes (initial state)
                if trackChanged {
                    self.playerService.updateLikeStatus(likeStatus)
                }

                // Repeat-one must keep enforcing queue/current song even if WebView doesn't flag `trackChanged`
                // for a transient autoplay swap. In other modes, keep the existing trackChanged gate.
                // A state update that is not a track change still has to be reconciled when it carries
                // the artwork of the playing track and that track has none: nothing else would ever
                // deliver the picture, which left the now-playing art blank for the whole song (see
                // `shouldReconcileMissingArtwork`).
                let shouldReconcileMetadata = (trackChanged
                    || self.playerService.repeatMode == .one
                    || self.playerService.shouldReconcileMissingArtwork(
                        observedVideoId: observedVideoId,
                        title: title,
                        artist: artist,
                        thumbnailUrl: thumbnailUrl
                    ))
                    && (observedVideoId != nil || !title.isEmpty)

                if shouldReconcileMetadata {
                    self.playerService.updateTrackMetadata(
                        title: title,
                        artist: artist,
                        thumbnailUrl: thumbnailUrl,
                        videoId: observedVideoId
                    )
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            DiagnosticsLogger.player.info(
                "Singleton WebView finished loading: \(webView.url?.absoluteString ?? "nil")"
            )

            // The document is up; anything still to wait for is the player starting, which has no
            // fraction to report.
            self.playerService.finishWebViewPageLoad()

            SingletonPlayerWebView.shared.reapplyMiniPlayerPresentationIfNeeded()

            // Apply the current volume when page finishes loading
            // This is critical because YouTube may set its own default volume
            let savedVolume = self.playerService.volume
            let savedRate = self.playerService.playbackRate
            let applyVolumeScript = """
                (function() {
                    // Set target volume for enforcement
                    window.__kasetTargetVolume = \(savedVolume);
                    // Podcast playback speed survives page loads for the same reason volume does:
                    // a fresh page (track change, reload) starts at the platform default.
                    window.__kasetTargetPlaybackRate = \(savedRate);
                    const rateVideo = document.querySelector('video');
                    if (rateVideo) { rateVideo.playbackRate = \(savedRate); }
                    window.__kasetSafeAdBlockingEnabled = \(SettingsManager.shared.safeAdBlockingEnabled ? "true" : "false");
                    // Set flag to prevent enforcement from reverting our change
                    window.__kasetIsSettingVolume = true;

                    // Apply to video element if it exists
                    const video = document.querySelector('video');
                    if (video) {
                        video.volume = \(savedVolume);
                    }

                    // Sync YouTube's internal player APIs to prevent overrides
                    const ytVolume = Math.round(\(savedVolume) * 100);
                    const player = document.querySelector('ytmusic-player');
                    if (player && player.playerApi) {
                        player.playerApi.setVolume(ytVolume);
                    }
                    const moviePlayer = document.getElementById('movie_player');
                    if (moviePlayer && moviePlayer.setVolume) {
                        moviePlayer.setVolume(ytVolume);
                    }

                    // Clear flag after a moment
                    setTimeout(() => { window.__kasetIsSettingVolume = false; }, 100);

                    return video ? 'applied' : 'no-video-yet';
                })();
            """
            webView.evaluateJavaScript(applyVolumeScript) { result, error in
                if let error {
                    DiagnosticsLogger.player.error(
                        "Failed to apply saved volume \(savedVolume): \(error.localizedDescription)"
                    )
                } else if let resultString = result as? String {
                    DiagnosticsLogger.player.debug("Volume apply result: \(resultString)")
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebView content process crashed - attempt recovery
            DiagnosticsLogger.player.error("Singleton WebView content process terminated, attempting recovery")

            // The crashed page's load is over whether or not it ever finished. What the reload shows
            // is unchanged — the same URL comes back — so which page this is stays as it was.
            self.playerService.finishWebViewPageLoad()

            // Get the current video ID before reloading
            let currentVideoId = SingletonPlayerWebView.shared.currentVideoId

            // Reload the WebView
            webView.reload()

            // If we had a video playing, reload it after a brief delay
            if let videoId = currentVideoId {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    // Reset currentVideoId to force reload
                    SingletonPlayerWebView.shared.currentVideoId = nil
                    SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
                }
            }
        }
    }

    /// Keeps a page Kaset loaded only to have ready from making a sound.
    ///
    /// Kaset permits autoplay (`mediaTypesRequiringUserActionForPlayback` is empty — that is what
    /// makes playback work at all), so a watch page left to itself starts playing the moment it is up.
    /// A warm page sitting in the background must not: it would be audio the user did not ask for, on a
    /// track the app is deliberately not tracking yet. So a page carrying the preload flag swallows its
    /// own `play()` calls until the hold is lifted — by Kaset driving a control, or by the user
    /// clicking or typing in the page (the mini player's own play button is the user asking the page).
    ///
    /// Lifting the hold also realigns the page: YouTube's player was told playback started and would
    /// otherwise take the next play/pause click as a *pause*.
    private static var preloadGateScript: String {
        """
        (function() {
            'use strict';
            if (window.__kasetPreloadGateInstalled) { return; }
            window.__kasetPreloadGateInstalled = true;

            const preloadFlag = /[?&]\(Self.preloadQueryFlagName)=\(Self.preloadQueryFlagValue)/;
            window.__kasetPreloadHold = preloadFlag.test(window.location.search);

            const originalPlay = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function() {
                if (!window.__kasetPreloadHold) {
                    return originalPlay.apply(this, arguments);
                }

                // Swallowed rather than started-and-paused: the track must not sound at all. The promise
                // is resolved so the page's own player continues as if the call had succeeded.
                try { this.pause(); } catch (error) {}
                return Promise.resolve();
            };

            function holdPlaying(event) {
                if (!window.__kasetPreloadHold) { return; }
                try { event.target.pause(); } catch (error) {}
            }

            function standDown() {
                const wasHolding = window.__kasetPreloadHold;
                window.__kasetPreloadHold = false;
                document.removeEventListener('pointerdown', standDown, true);
                document.removeEventListener('keydown', standDown, true);
                document.removeEventListener('play', holdPlaying, true);

                if (!wasHolding) { return; }

                // The page's player believes it is playing. Tell it otherwise, so the next play/pause
                // click in the page is a play.
                const player = document.querySelector('ytmusic-player');
                if (player && player.playerApi && typeof player.playerApi.pauseVideo === 'function') {
                    try { player.playerApi.pauseVideo(); } catch (error) {}
                }
                const video = document.querySelector('video');
                if (video) { try { video.pause(); } catch (error) {} }
            }

            window.__kasetPreloadStandDown = standDown;
            document.addEventListener('pointerdown', standDown, true);
            document.addEventListener('keydown', standDown, true);
            document.addEventListener('play', holdPlaying, true);
        })();
        """
    }

    /// Removes known ad payload keys from YTM responses in a defensive, no-throw way.
    private static var adPruningScript: String {
        """
        (function() {
            'use strict';
            if (window.__kasetAdPruningInstalled) return;
            window.__kasetAdPruningInstalled = true;
            if (typeof window.__kasetSafeAdBlockingEnabled !== 'boolean') {
                window.__kasetSafeAdBlockingEnabled = true;
            }

            const AD_KEYS = new Set([
                'playerAds',
                'adPlacements',
                'adSlots',
                'adBreakHeartbeatParams'
            ]);

            function prune(node) {
                if (window.__kasetSafeAdBlockingEnabled === false) return;
                if (!node || typeof node !== 'object') return;
                if (Array.isArray(node)) {
                    for (const item of node) prune(item);
                    return;
                }
                for (const key of Object.keys(node)) {
                    if (AD_KEYS.has(key)) {
                        delete node[key];
                        continue;
                    }
                    prune(node[key]);
                }
            }

            function patchJsonResponseBody(body) {
                if (!body || typeof body !== 'object') return body;
                try {
                    const clone = typeof structuredClone === 'function'
                        ? structuredClone(body)
                        : JSON.parse(JSON.stringify(body));
                    prune(clone);
                    return clone;
                } catch (_) {
                    return body;
                }
            }

            const originalJsonParse = JSON.parse;
            JSON.parse = function(text, reviver) {
                const parsed = originalJsonParse.call(this, text, reviver);
                prune(parsed);
                return parsed;
            };

            const originalFetch = window.fetch;
            if (typeof originalFetch === 'function') {
                window.fetch = async function(...args) {
                    const response = await originalFetch.apply(this, args);
                    if (!response || typeof response.clone !== 'function') return response;

                    try {
                        const contentType = response.headers.get('content-type') || '';
                        if (!contentType.includes('application/json')) return response;

                        const json = await response.clone().json();
                        const pruned = patchJsonResponseBody(json);
                        return new Response(JSON.stringify(pruned), {
                            status: response.status,
                            statusText: response.statusText,
                            headers: response.headers
                        });
                    } catch (_) {
                        return response;
                    }
                };
            }
        })();
        """
    }
}

// MARK: - SingletonPlayerWebView Media Controls

extension SingletonPlayerWebView {
    /// Updates the current page and the bootstrap state used by future page loads.
    func setMediaControlStyle(useNextPrev: Bool) {
        self.mediaControlUsesNextPrev = useNextPrev

        guard let webView = self.webView else { return }
        let script = Self.mediaControlStyleSyncScript(useNextPrev: useNextPrev)
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func mediaControlBootstrapScript() -> String {
        Self.mediaControlStyleBootstrapScript(useNextPrev: self.mediaControlUsesNextPrev)
    }

    static func mediaControlStyleBootstrapScript(useNextPrev: Bool) -> String {
        let jsBoolean = useNextPrev ? "true" : "false"
        return """
            (function() {
                try {
                    localStorage.setItem('kasetUseNextPrev', '\(jsBoolean)');
                } catch (e) {}
                window.__kasetUseNextPrev = \(jsBoolean);
            })();
        """
    }

    static func mediaControlStyleSyncScript(useNextPrev: Bool) -> String {
        let jsBoolean = useNextPrev ? "true" : "false"
        let restoreSeekHandlers = if useNextPrev {
            ""
        } else {
            """
                try {
                    var ms = navigator.mediaSession;
                    ms.setActionHandler('nexttrack', null);
                    ms.setActionHandler('previoustrack', null);
                    ms.setActionHandler('seekforward', function(d) {
                        var v = document.querySelector('video');
                        if (v) v.currentTime = Math.min(v.duration,
                            v.currentTime + ((d && d.seekOffset) || 15));
                    });
                    ms.setActionHandler('seekbackward', function(d) {
                        var v = document.querySelector('video');
                        if (v) v.currentTime = Math.max(0,
                            v.currentTime - ((d && d.seekOffset) || 15));
                    });
                } catch (e) {}
            """
        }

        return """
            (function() {
                try {
                    localStorage.setItem('kasetUseNextPrev', '\(jsBoolean)');
                } catch (e) {}
                window.__kasetUseNextPrev = \(jsBoolean);
                if (typeof window.__kasetRefreshMediaControlStyle === 'function') {
                    window.__kasetRefreshMediaControlStyle();
                }
                \(restoreSeekHandlers)
            })();
        """
    }

    static var mediaControlOverrideScript: String {
        """
        (function() {
            if (typeof window.__kasetUseNextPrev !== 'boolean') {
                try {
                    window.__kasetUseNextPrev =
                        localStorage.getItem('kasetUseNextPrev') === 'true';
                } catch (e) {
                    window.__kasetUseNextPrev = false;
                }
            }

            var overrideFrameId = null;

            function applyOverride() {
                if (!window.__kasetUseNextPrev) {
                    return;
                }
                try {
                    var ms = navigator.mediaSession;
                    ms.setActionHandler('seekforward', null);
                    ms.setActionHandler('seekbackward', null);
                    ms.setActionHandler('nexttrack', function() {
                        window.webkit.messageHandlers.singletonPlayer
                            .postMessage({ type: 'REMOTE_NEXT' });
                    });
                    ms.setActionHandler('previoustrack', function() {
                        window.webkit.messageHandlers.singletonPlayer
                            .postMessage({ type: 'REMOTE_PREVIOUS' });
                    });
                } catch (e) {}
            }

            function scheduleOverrideLoop() {
                if (overrideFrameId !== null || !window.__kasetUseNextPrev) {
                    return;
                }

                overrideFrameId = requestAnimationFrame(function() {
                    overrideFrameId = null;
                    if (!window.__kasetUseNextPrev) {
                        return;
                    }
                    applyOverride();
                    scheduleOverrideLoop();
                });
            }

            window.__kasetRefreshMediaControlStyle = function() {
                applyOverride();
                scheduleOverrideLoop();
            };

            window.__kasetRefreshMediaControlStyle();

            // Re-apply on video events where YouTube re-registers handlers.
            function attachVideoOverride() {
                var v = document.querySelector('video');
                if (!v || v.__kasetOverrideAttached) return;
                v.__kasetOverrideAttached = true;
                ['playing','loadedmetadata','loadeddata','canplay','seeked']
                    .forEach(function(e) { v.addEventListener(e, applyOverride); });
            }

            attachVideoOverride();
            new MutationObserver(attachVideoOverride)
                .observe(document.documentElement, {childList:true, subtree:true});
        })();
        """
    }
}
