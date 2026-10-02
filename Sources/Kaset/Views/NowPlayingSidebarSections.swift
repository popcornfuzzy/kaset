import AppKit
import SwiftUI

// MARK: - NowPlayingSidebarLayout

/// Shared geometry of the Now Playing sidebar, so its root view and its sections cannot drift apart.
enum NowPlayingSidebarLayout {
    /// Horizontal inset of everything except the artwork, which is edge to edge.
    static let padding: CGFloat = 14

    /// How tall the artwork may be. It is a square until a short window makes it shrink.
    static let artworkMinHeight: CGFloat = 150
    static let artworkMaxHeight: CGFloat = 520
    static let artworkMaxDimension: CGFloat = 520

    /// Height of the three-line lyric window in the sidebar's preview.
    static let lyricsPreviewHeight: CGFloat = 116

    /// Side of the small artwork on the up-next row.
    static let rowArtworkSide: CGFloat = 40

    /// What the fixed content below the artwork needs — title block, both section headers, the lyric
    /// preview, the up-next row and the spacing between them — so the artwork can take what is left.
    static let reservedHeight: CGFloat = 316

    /// Softens the top and bottom of the three-line lyric window, so the rows that run past it fade
    /// instead of being cut through the middle of their glyphs.
    static let lyricsPreviewFadeMask = LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.14),
            .init(color: .black, location: 0.86),
            .init(color: .clear, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - NowPlayingSidebarBackground

/// The sidebar's own background: the cover art itself, blurred into a wash of its colors, filling the
/// whole column.
///
/// It is a blur of the artwork rather than a palette extracted from it. A palette reduces a cover to
/// one flat color; a heavy blur keeps the image's *structure* — light where it is light, warm where it
/// is warm — so the column reads as one continuous surface made of the album rather than a picture
/// sitting on a tinted panel. The hero artwork at the top then dissolves into this same wash (see
/// `NowPlayingSidebarArtwork`), so there is no seam between the real cover and its color.
@available(macOS 26.0, *)
struct NowPlayingSidebarBackground: View {
    let artworkURL: URL?
    /// Identity of the artwork (the track's id), so a re-reported URL for the same cover — YouTube
    /// rotates size and signature tokens — does not re-decode the blur source.
    let identity: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var artwork: NSImage?

    var body: some View {
        // The plain color is what sizes the wash. The artwork is an *overlay* on it, never a stack
        // sibling: a `.resizable()` image with `aspectRatio(contentMode: .fill)` inside a stack sizes
        // itself from the proposal rather than from the available width — it became a square of the
        // column's height (758×758 for a 300pt column) and spilled the whole wash far outside the
        // column, which read as a huge empty band beside the content.
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 42)
                        // Zoom past the blur's soft edges, so the wash reaches every corner instead of
                        // fading out into the window background at the sides.
                        .scaleEffect(1.3)
                        .opacity(self.colorScheme == .dark ? 0.9 : 0.6)
                }
            }
            // A scrim over the wash, so the title, the lyric window and the queue stay legible
            // whatever the cover looks like — a bright cover must not wash the text out.
            .overlay { self.scrim }
            .clipped()
            // The wash is pure decoration, so it must never take a click. It bleeds up behind the
            // toolbar (see the caller), which is exactly where the content's own toolbar controls —
            // the playlist search field, sort, refresh — sit on top of the column's x-range. A
            // `Color` is hit-testable by SwiftUI, so without this the wash silently swallowed every
            // click and scroll that landed on those controls: the visual artifact was gone but the
            // invisible layer stayed.
            .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.5), value: self.identity)
        .animation(.easeInOut(duration: 0.3), value: self.colorScheme)
        .task(id: self.identity ?? self.artworkURL?.absoluteString) {
            await self.loadArtwork()
        }
    }

    private var scrim: some View {
        Group {
            if self.colorScheme == .dark {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.04), location: 0),
                        .init(color: .black.opacity(0.30), location: 0.42),
                        .init(color: .black.opacity(0.68), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.04), location: 0),
                        .init(color: .white.opacity(0.42), location: 0.45),
                        .init(color: .white.opacity(0.72), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func loadArtwork() async {
        guard let url = self.artworkURL else {
            self.artwork = nil
            return
        }

        // A blur needs real pixels: at a tiny size the wash is a flat smear with no structure left.
        // 400pt is still a cheap decode, and it is cached against the same cover the hero shows.
        guard let image = await ImageCache.shared.image(
            for: url,
            targetSize: CGSize(width: 400, height: 400)
        ) else { return }
        guard !Task.isCancelled else { return }

        self.artwork = image
    }
}

// MARK: - NowPlayingSidebarCard

/// The translucent card the sidebar's previews sit in.
///
/// Glass, not a solid panel: the blurred artwork behind it shows through, so a preview still reads
/// as part of the sidebar rather than a card floating on top of it.
@available(macOS 26.0, *)
struct NowPlayingSidebarCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        self.content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: self.cornerRadius))
    }
}

// MARK: - NowPlayingSidebarToggle

/// The Now Playing sidebar's toggle.
///
/// Styled as the window's own sidebar toggle — the mirrored `sidebar.trailing` glyph, the same weight
/// — so the two read as a pair rather than as two different controls. It appears in exactly one place
/// at a time: in the toolbar while the column is closed, and in the column's own top-trailing corner
/// while it is open, so the control looks like it slides into the sidebar rather than being duplicated.
@available(macOS 26.0, *)
struct NowPlayingSidebarToggle: View {
    /// Where the toggle is being shown, which decides whether it needs chrome of its own.
    enum Style {
        /// Inside a `ToolbarItem`. macOS supplies the chrome; adding our own would double it up.
        case toolbar
        /// Floating over the column's artwork, which can be any colour at all, so it gets a glass
        /// disc to stay legible — the same treatment the app's other controls-over-artwork use.
        case floating
    }

    var style: Style = .toolbar
    let action: () -> Void

    var body: some View {
        switch self.style {
        case .toolbar:
            self.button
        case .floating:
            self.button
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    private var button: some View {
        // No explicit button style: in a `ToolbarItem` macOS gives it the same chrome as the content's
        // own toolbar buttons, which is exactly the styling this should share.
        Button(action: self.action) {
            Image(systemName: "sidebar.right")
        }
        .help(String(localized: "Show or hide the Now Playing sidebar"))
        .accessibilityLabel(String(localized: "Now Playing sidebar"))
        .accessibilityIdentifier(AccessibilityID.NowPlayingSidebar.toggleButton)
    }
}

// MARK: - NowPlayingSidebarArtwork

/// The cover art at the top of the sidebar: edge to edge across the whole column, with the track's
/// animated canvas crossfading over it once the video is really drawing.
///
/// The canvas is the same `CanvasVideoView` the fullscreen player uses, with the same readiness rule —
/// the fade waits for the first *rendered* frame, never for "the item is ready", which a streaming
/// canvas reports seconds before there is a picture.
@available(macOS 26.0, *)
struct NowPlayingSidebarArtwork: View {
    let track: Song?
    /// Canvas resolved for the current track, or `nil` when there is nothing to show.
    let canvasURL: URL?
    let height: CGFloat
    let reduceMotion: Bool

    @State private var canvasReady = false
    @State private var canvasFailed = false

    var body: some View {
        ZStack {
            self.artwork

            if let canvasURL = self.canvasURL, !self.canvasFailed {
                CanvasVideoView(
                    url: canvasURL,
                    onReadyToPlay: { self.canvasReady = true },
                    onFailure: {
                        // Keep the still artwork and unmount the failed player so it is not retried
                        // on every render.
                        self.canvasReady = false
                        self.canvasFailed = true
                    }
                )
                .opacity(self.canvasReady ? 1 : 0)
                .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.6), value: self.canvasReady)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: self.height)
        .clipped()
        // The cover dissolves into the blurred wash below it rather than stopping at a hard edge, so
        // the real artwork and its color are one surface.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityArtworkLabel)
        .accessibilityIdentifier(AccessibilityID.NowPlayingSidebar.artwork)
        // Decorative: the cover art accepts no interaction, so it must not stand between a click and
        // whatever is beneath it. The column reaches to the window's top edge, so without this the
        // artwork's frame is another invisible hit target over the toolbar.
        .allowsHitTesting(false)
        .onChange(of: self.canvasURL) { _, _ in
            // A new track's canvas reports readiness again; a canvas that failed is retried.
            self.canvasReady = false
            self.canvasFailed = false
        }
    }

    private var artwork: some View {
        CachedAsyncImage(
            url: self.track?.thumbnailURL?.highQualityThumbnailURL,
            fallbackURL: self.track?.thumbnailURL,
            identity: self.track?.videoId,
            targetSize: CGSize(
                width: NowPlayingSidebarLayout.artworkMaxDimension,
                height: NowPlayingSidebarLayout.artworkMaxDimension
            )
        ) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                CassetteIcon(size: 76).foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityArtworkLabel: String {
        guard let track = self.track else { return String(localized: "No Song Playing") }
        return String(localized: "Artwork for \(track.title)")
    }
}

// MARK: - NowPlayingSidebarUpNext

/// The next song in the queue: artwork, title, artist and length, or a short empty state. Plain
/// content on the sidebar's background — no card, like the lyric window above it.
struct NowPlayingSidebarUpNext: View {
    let song: Song?

    var body: some View {
        HStack(spacing: 10) {
            if let song {
                CachedAsyncImage(
                    url: song.thumbnailURL?.highQualityThumbnailURL,
                    fallbackURL: song.thumbnailURL,
                    identity: song.videoId,
                    targetSize: CGSize(width: 84, height: 84)
                ) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: NowPlayingSidebarLayout.rowArtworkSide, height: NowPlayingSidebarLayout.rowArtworkSide)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(song.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : song.artistsDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(song.durationDisplay)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text(String(localized: "Nothing queued"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
