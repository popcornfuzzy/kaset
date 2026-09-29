import Foundation

// MARK: - PlayerBarLoadingIndicator

/// What the player bar's loading strip draws while the shared WebView is bringing something up.
struct PlayerBarLoadingIndicator: Equatable {
    /// How the strip is drawn.
    enum Style: Equatable {
        /// There is a real fraction to draw: the strip fills from the left.
        case determinate
        /// There is nothing to measure: the strip breathes in place.
        case indeterminate
    }

    /// How the strip is drawn.
    let style: Style

    /// How much of the strip is filled, `0...1`. Only meaningful for ``Style/determinate``.
    let fraction: Double

    init(style: Style, fraction: Double = 0) {
        self.style = style
        self.fraction = min(max(fraction, 0), 1)
    }

    /// Whether the strip is drawn in the indeterminate style.
    var isIndeterminate: Bool {
        self.style == .indeterminate
    }
}

// MARK: - PlayerBarLoadingRule

/// Turns what the shared WebView is doing into what the player bar draws.
///
/// Three things can make the bar wait, and they want two different drawings:
///
/// - **A page load**, whose fraction the WebView reports itself. It is the preload at launch and
///   every watch page a track change navigates to, it is the longest of the waits, and it is the
///   only one Kaset can measure — so the strip crosses the bar.
/// - **Playback that has been asked for but has not started.** The page is up and YouTube is
///   working through ads, stream selection and DRM, with nothing to measure; the honest drawing is
///   a strip that keeps breathing rather than one that pretends to know how far along it is.
/// - **A page load that was over too fast to be seen.** The preload can end before the window has
///   finished appearing, and a strip that vanishes with it is indistinguishable from one that was
///   never there. That window is also real work — the page is booting its player — so it draws as
///   the same stripe with nothing to measure, until the tail runs out.
///
/// A page load outranks the other two because it is the measured answer while it lasts.
enum PlayerBarLoadingRule {
    static func indicator(
        pageLoadFraction: Double?,
        isStartingPlayback: Bool,
        isWarmingUp: Bool = false
    ) -> PlayerBarLoadingIndicator? {
        if let pageLoadFraction {
            return PlayerBarLoadingIndicator(style: .determinate, fraction: pageLoadFraction)
        }
        guard isStartingPlayback || isWarmingUp else { return nil }
        return PlayerBarLoadingIndicator(style: .indeterminate)
    }
}

// MARK: - PlayerBarLoadingLinger

/// How long the loading strip keeps pulsing once a page load has ended.
///
/// A page load is not necessarily *seen*. The preload starts as soon as the app is signed in, and it can
/// be over while the window is still appearing — so on a machine where the page takes a second and the
/// window takes three, a strip that ends with the load is indistinguishable from no strip at all. The
/// tail is what makes it visible either way, and it is honest about what it shows: the page still has to
/// boot its player, and none of that reports anything the bar could measure.
///
/// It costs nothing when there is something better to do with the bar: playback starting ends it, and a
/// fresh page load takes it over.
enum PlayerBarLoadingLinger {
    /// How long the stripe keeps pulsing after a page load ends. Long enough to survive a window that is
    /// still coming up, short enough that it is gone before the user wonders what it is waiting for.
    static let tail: TimeInterval = 4
}

// MARK: - PlayerWebViewObservation

/// How much of what the page says Kaset is entitled to believe.
///
/// A page is only worth as much as the state it is in: a warm page has no track, and a page loaded
/// early was told it started playing when its autoplay was swallowed. Splitting *which track the page
/// is showing* from *what its player is doing* is what lets a preload deliver exactly the observations
/// it can be trusted with — the track's title, artist and artwork — while keeping the ones it cannot
/// out of the app's state.
enum PlayerWebViewObservation: Equatable {
    /// Nothing: the page is not showing a track Kaset plays, so it has nothing to say.
    case none
    /// Which track the page is showing: title, artist, artwork, video id.
    case metadata
    /// The above, plus what the page's player is doing — position, duration, playing flag, ads,
    /// track end, remote control, lyric time.
    case playback
}

// MARK: - PlayerWebViewPage

/// What the page in the shared WebView is for. The distinction matters twice over: a page that is not
/// being played from must not report to the app, and a page loaded early must not be replaced.
enum PlayerWebViewPage: Equatable {
    /// Nothing has been navigated to yet.
    case empty
    /// The YouTube Music shell: loaded to be warm, carrying no track, held silent.
    case shell
    /// A track's watch page, loaded early and held silent until Kaset asks it to play.
    case preloaded
    /// A watch page Kaset is playing from, whose own observations are the app's.
    case playback

    /// What the page is allowed to change in the app.
    ///
    /// - `.shell` has no track at all.
    /// - `.preloaded` is a YouTube Music player that was told it started when its autoplay was
    ///   swallowed: its position, duration and playing flag describe a performance that never
    ///   happened, and its queue and end-of-track signals would drive `next()` and `play()` from a page
    ///   that is deliberately silent. Believing any of that would put a track that is not playing into
    ///   the app's state and would zero the progress a restored session is showing. Its *metadata* is a
    ///   different matter — which song the page is showing, and its title, artist and artwork, are
    ///   exactly what a preloaded first song is waiting to have normalized.
    /// - `.playback` is the page Kaset is playing from: its observations are the app's.
    var observation: PlayerWebViewObservation {
        switch self {
        case .empty, .shell: .none
        case .preloaded: .metadata
        case .playback: .playback
        }
    }

    /// Whether the page's own player observations may be applied to playback state.
    var isAuthoritative: Bool {
        self.observation == .playback
    }

    /// Whether the page is being kept quiet on purpose.
    var isSilent: Bool {
        self == .shell || self == .preloaded
    }
}

// MARK: - PlayerWebViewPreload

/// What the app does with the shared WebView before anything is played.
///
/// Creating the WebView and booting YouTube Music used to happen on the user's first press of play,
/// so the first song of every session paid for the whole page: the JS bundle, the service worker,
/// the cookie and DRM machinery, the watch page's own player boot. That is seconds of an app that
/// has been up and looked ready for a while, and it lands exactly when the user asked for music.
///
/// So the WebView is created and given a page as soon as the app is signed in:
///
/// - With a track already known — a restored session knows its song before anything plays — the
///   **track's watch page** is loaded, held silent, and (when the session has a position to resume
///   from) pointed at that position. Pressing play then starts instead of loading.
/// - With no track to be ready for, the **shell** is loaded: the cheapest thing that warms the app,
///   and it carries nothing that could play.
///
/// Neither page may make a sound before the user asks: Kaset permits autoplay, so a watch page left
/// to itself plays. The gate (`SingletonPlayerWebView.preloadGateScript`) holds the page, and every
/// control Kaset drives — or the user's own first click in the page — lifts it.
enum PlayerWebViewPreload {
    /// The page to load.
    enum Target: Equatable {
        /// A track's watch page, held ready and silent.
        case activeSong(videoId: String)
        /// The YouTube Music shell.
        case shell
    }

    /// Whether the player layer should be hosted: a pending video needs it for playback and for a
    /// restored session's resume, and a signed-in session needs it for the preload.
    static func shouldHostPlayerWebView(isSignedIn: Bool, hasPendingVideo: Bool) -> Bool {
        hasPendingVideo || isSignedIn
    }

    /// The page to load into an empty WebView.
    ///
    /// A restored session knows its track before anything is played, and that track's watch page is
    /// exactly the page the first press of play would otherwise spend seconds loading.
    static func target(activeVideoId: String?) -> Target {
        guard let activeVideoId, !activeVideoId.isEmpty else { return .shell }
        return .activeSong(videoId: activeVideoId)
    }

    /// Whether the shell may still be loaded.
    ///
    /// Only into a WebView that has nothing in it: the shell is a placeholder for "no track yet" and
    /// must never replace a page that is being played from.
    static func canLoadShell(currentVideoId: String?, page: PlayerWebViewPage) -> Bool {
        currentVideoId == nil && page == .empty
    }

    /// Whether a track's watch page may still be preloaded.
    ///
    /// Into an empty WebView, or one showing the shell — a shell that was loaded before the session's
    /// track was known is only a placeholder, and the track is worth more. A page that already has a
    /// track in it (preloaded or playing) is never replaced: preloading exists to be ready, never to
    /// change what is on screen.
    static func canLoadPreload(currentVideoId: String?, page: PlayerWebViewPage) -> Bool {
        currentVideoId == nil && (page == .empty || page == .shell)
    }
}
