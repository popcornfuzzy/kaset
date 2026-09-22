import SwiftUI

// MARK: - CachedAsyncImage

/// A cached version of AsyncImage that uses ImageCache.
/// Includes a smooth crossfade transition when the image loads.
///
/// - Important: Pass ``identity`` for artwork that must not blink. YouTube serves the same
///   artwork from many URLs (it rotates size and signature tokens, and its player bar rewrites
///   the `<img>` while it upgrades resolution), so a URL change alone is *not* a signal that the
///   image content changed. With an ``identity``, the view keeps the artwork it already displays
///   for that identity while the new URL resolves, instead of dropping back to the placeholder.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let fallbackURL: URL?
    /// Stable identity of the artwork (typically a track/album/video id).
    ///
    /// When set, a URL change clears the displayed image only if this value also changed, so a
    /// re-reported URL for the same artwork does not flash the placeholder. Leave it `nil` for
    /// collection rows, where the enclosing view may be recycled for a different item.
    var identity: String?
    /// Target size for image downsampling. Images are downsampled to this size to reduce memory usage.
    /// Pass the actual display size of the image for optimal memory efficiency.
    var targetSize: CGSize = .init(width: 320, height: 320)
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    /// Extra attempts made when a fetch fails. A single failed request must not be able to leave
    /// the artwork blank until the next track change: the task only runs again when its id changes.
    private static var retryDelays: [Duration] {
        [.milliseconds(300), .seconds(1), .seconds(3)]
    }

    /// Cadence of the attempts that follow the quick ones.
    ///
    /// The quick retries only cover a hiccup of a few seconds, but the situations that actually lose
    /// artwork last longer and do resolve themselves: the app is still opening its WebView and the
    /// network is busy, a streamed song's picture is still being upgraded from the player bar, or the
    /// CDN answers a rate-limited 403. A view that gave up after three attempts kept its placeholder
    /// for the rest of the song — nothing later re-runs `.task(id:)` while the artwork URL itself is
    /// unchanged — so the view keeps trying while it is on screen. Attempts are cheap:
    /// ``ImageCache`` dedupes identical requests, remembers sizes YouTube does not have, and a URL that
    /// already succeeded is answered from the memory or disk cache without a request at all.
    private static var recoveryRetryDelays: [Duration] {
        [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60)]
    }

    /// Delay before retry number `retryIndex` (0-based): the quick attempts first, then the recovery
    /// cadence, which bottoms out at its cap. Pure, so the schedule is testable without a view.
    static func retryDelay(afterRetry retryIndex: Int) -> Duration {
        let schedule = Self.retryDelays + Self.recoveryRetryDelays
        return schedule[min(max(retryIndex, 0), schedule.count - 1)]
    }

    @State private var image: NSImage?
    @State private var isLoaded = false
    /// Identity of the artwork this view is showing *or currently loading*.
    ///
    /// Claimed before the download starts, never after: while a song's artwork is still downloading,
    /// an update that re-reports the same song's thumbnail URL must compare equal to this value.
    /// Recording it only on success made that update look like a new song, so the art on screen was
    /// cleared mid-download — and whenever the replacement request failed, it never came back.
    /// Whether that second update lands before or after the download finishes is a race, which is
    /// why the artwork only vanished in some cases.
    @State private var artworkIdentity: String?

    init(
        url: URL?,
        fallbackURL: URL? = nil,
        identity: String? = nil,
        targetSize: CGSize = .init(width: 320, height: 320),
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.identity = identity
        self.targetSize = targetSize
        self.content = content
        self.placeholder = placeholder

        // Paint artwork we already have in memory on the very first frame. Every fullscreen open and
        // every screen switch creates a fresh `PlayerBar` artwork view, and starting from `nil` made the
        // now-playing art fall back to its placeholder while it "reloaded" a picture the app had been
        // showing a moment earlier. The identity is seeded with the image so the retention rule below
        // does not immediately clear it as if a different song had started.
        //
        // Only for views that pass an identity: an identity-less collection row clears its image on every
        // URL change (it may be recycled for another item), so seeding it would just add a flash.
        if identity != nil,
           let cachedImage = Self.cachedImageForDisplay(
               url: url,
               fallbackURL: fallbackURL,
               targetSize: targetSize
           )
        {
            _image = State(initialValue: cachedImage)
            _isLoaded = State(initialValue: true)
            _artworkIdentity = State(initialValue: identity)
        }
    }

    /// Returns the first candidate that is already cached in memory *and* big enough for this view.
    ///
    /// The memory cache is keyed by URL, so an image a small row loaded would otherwise be blown up
    /// into a large artwork slot — a placeholder is better than visibly the wrong resolution.
    private static func cachedImageForDisplay(url: URL?, fallbackURL: URL?, targetSize: CGSize) -> NSImage? {
        for candidate in Self.displayCandidates(url: url, fallbackURL: fallbackURL) {
            guard let image = ImageCache.shared.cachedImage(for: candidate) else { continue }
            guard ArtworkDisplayRule.canSeedDisplayedImage(
                imageSize: image.size,
                targetSize: targetSize
            ) else { continue }
            return image
        }
        return nil
    }

    /// Whether to animate the image appearance.
    private var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        ZStack {
            if let image {
                self.content(Image(nsImage: image))
                    .opacity(self.isLoaded ? 1 : 0)
                    .animation(self.shouldAnimate ? .easeIn(duration: 0.25) : nil, value: self.isLoaded)
            } else {
                self.placeholder()
            }
        }
        .task(id: self.loadTaskID) {
            await self.loadArtwork()
        }
    }

    @MainActor
    private func loadArtwork() async {
        let shouldClearDisplayedImage = ArtworkDisplayRule.shouldClearDisplayedImage(
            identity: self.identity,
            displayedIdentity: self.artworkIdentity
        )
        // Claim the identity before awaiting the download so a URL update that arrives while this
        // artwork is still loading is recognized as the same picture and does not blank it.
        self.artworkIdentity = self.identity
        if shouldClearDisplayedImage {
            self.image = nil
            self.isLoaded = false
        }

        guard self.url != nil || self.fallbackURL != nil else {
            self.isLoaded = true
            return
        }

        var retryIndex = 0
        while true {
            guard !Task.isCancelled else { return }

            if let loadedImage = await self.loadImage(), !Task.isCancelled {
                self.image = loadedImage
                self.isLoaded = true
                return
            }
            guard !Task.isCancelled else { return }

            // Keep the placeholder (or the artwork we retained for this identity) visible instead of
            // leaving the layer transparent while the retry is pending.
            self.isLoaded = true

            if retryIndex == Self.retryDelays.count {
                // Reported once, when the quick attempts are spent: the recovery attempts that follow
                // are quiet because they usually succeed, and a size YouTube does not have is
                // remembered by `ImageCache` and never requested again.
                DiagnosticsLogger.ui.error(
                    "Artwork failed to load after \(Self.retryDelays.count + 1) attempts; still retrying while the view is on screen: \(Self.describe(url: self.url), privacy: .public) fallback \(Self.describe(url: self.fallbackURL), privacy: .public)"
                )
            }

            do {
                try await Task.sleep(for: Self.retryDelay(afterRetry: retryIndex))
            } catch {
                return // Cancelled: a newer URL/identity owns the view now.
            }
            retryIndex += 1
        }
    }

    private var loadTaskID: String {
        "\(self.url?.absoluteString ?? "nil")|\(self.fallbackURL?.absoluteString ?? "nil")"
    }

    /// Loggable description of an artwork URL: host and path only, because the query carries the URL
    /// signature (kept private, per the project's secret-handling rules). Callers log this with
    /// `privacy: .public`; an interpolated `String` is private by default, which is what previously
    /// hid every artwork failure behind `<private>` and made a blank picture impossible to
    /// diagnose from the log.
    static func describe(url: URL?) -> String {
        guard let url else { return "nil" }
        return "\(url.host() ?? "unknown")\(url.path())"
    }

    private func loadImage() async -> NSImage? {
        for candidate in Self.displayCandidates(url: self.url, fallbackURL: self.fallbackURL) {
            if let image = await ImageCache.shared.image(for: candidate, targetSize: self.targetSize) {
                return image
            }
        }

        return nil
    }

    /// The ordered artwork candidates this view tries: the preferred size first, then the other sizes of
    /// the same picture, ending with the exact URLs the caller handed us. A promoted size (for example
    /// `maxresdefault.jpg`) is missing for a share of videos, so trying only the preferred candidate left
    /// the artwork blank for those songs. Shared with the first-frame cache lookup so both agree on which
    /// URLs represent this artwork.
    private static func displayCandidates(url: URL?, fallbackURL: URL?) -> [URL] {
        var candidates: [URL] = []
        if let url {
            candidates.append(contentsOf: url.highQualityThumbnailCandidates)
            candidates.append(url)
        }
        if let fallbackURL {
            candidates.append(contentsOf: fallbackURL.highQualityThumbnailCandidates)
            candidates.append(fallbackURL)
        }

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }
}

// MARK: - ArtworkDisplayRule

/// Decides whether an artwork view may drop the image it is currently showing.
///
/// YouTube serves one picture from many URLs, so a URL change on its own says nothing about the
/// image content. Only a change of artwork identity (the song/album the picture belongs to) may
/// clear the displayed image; with no identity the view cannot tell the two apart and keeps the
/// conservative behavior of treating every URL change as new content. Collection rows rely on that:
/// SwiftUI may recycle a row for a different item, where a stale image would be wrong.
enum ArtworkDisplayRule {
    static func shouldClearDisplayedImage(identity: String?, displayedIdentity: String?) -> Bool {
        identity == nil || identity != displayedIdentity
    }

    /// Whether an already cached image is sharp enough to paint in a view that asks for `targetSize`.
    ///
    /// The memory cache is keyed by URL alone, so the entry may have been downsampled for a much smaller
    /// slot (a 40pt row thumbnail). Seeding a large artwork view with it would render a blurry picture, so
    /// such a view waits for its own load instead.
    static func canSeedDisplayedImage(imageSize: CGSize, targetSize: CGSize) -> Bool {
        let resolvedImageSize = max(imageSize.width, imageSize.height)
        let minimumDimension = max(targetSize.width, targetSize.height)
        return resolvedImageSize >= minimumDimension
    }
}

// MARK: - SizedProgressView

/// A simple ProgressView wrapper with proper sizing to avoid AppKit constraint warnings.
struct SizedProgressView: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(width: 20, height: 20)
    }
}

extension CachedAsyncImage where Placeholder == SizedProgressView {
    /// Convenience initializer with default ProgressView placeholder.
    init(
        url: URL?,
        fallbackURL: URL? = nil,
        identity: String? = nil,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.identity = identity
        self.content = content
        self.placeholder = { SizedProgressView() }
    }
}
