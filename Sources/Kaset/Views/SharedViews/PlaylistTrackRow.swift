import SwiftUI

// MARK: - PlaylistTrackRow

/// A single track row in a playlist or album detail list.
///
/// Extracted from `PlaylistDetailView` so SwiftUI can invalidate rows individually:
/// the row's `body` is skipped entirely while its `==` inputs are unchanged, so player,
/// favorites, library, and pagination updates no longer rebuild every realized row.
///
/// Rows are laid out by an AppKit-backed `List` (see `PlaylistTrackRow.body`'s caller), which is
/// what keeps the per-frame cost independent of the row's view-tree size. See
/// `docs/adr/0014-playlist-scroll-performance.md`.
@available(macOS 26.0, *)
struct PlaylistTrackRow: View, Equatable {
    /// On-screen size of the row artwork. `ImageCache` doubles this for Retina, so passing
    /// it keeps the cache from decoding a 320×320 bitmap for a 40×40 slot.
    static let thumbnailSize = CGSize(width: 40, height: 40)

    /// Horizontal inset applied to the row's *content*. The row itself and its highlight span the
    /// full width of the list — see `body`.
    static let contentInset: CGFloat = 24

    /// Hover/press highlight fill, matching `InteractiveRowStyle`'s default.
    static let highlightColor = Color.primary.opacity(0.06)

    /// Rows that get the staggered entrance animation. Only the first page animates so rows
    /// realized mid-flick appear instantly instead of animating while the list scrolls.
    static let entranceAnimationRowLimit = 25

    let song: Song
    let index: Int
    let isAlbum: Bool
    let isCurrentTrack: Bool
    let isPlaying: Bool
    /// Whether to draw the separator under this row (false for the last row).
    let showsSeparator: Bool
    /// True while the list is scrolling; suppresses hover highlighting.
    let isScrolling: Bool

    /// Services needed by the row's menu and add-to-playlist popover.
    let favoritesManager: FavoritesManager
    let likeStatusManager: SongLikeStatusManager
    let playerService: PlayerService
    let client: any YTMusicClientProtocol
    let libraryViewModel: LibraryViewModel?

    /// Plays this row's queue. Implementations must read live playlist state rather than
    /// capturing a track snapshot — that is what makes excluding it from `==` safe.
    let onPlay: () -> Void
    /// Removes the song from the playlist this row belongs to.
    let onRemoveFromPlaylist: (Song) -> Void

    /// Whether the add-to-playlist popover is presented for this row.
    @State private var isShowingAddToPlaylist = false

    /// Whether the pointer is anywhere over this row.
    @State private var isPointerInside = false

    /// Compares only what the row draws. The action closures and service references are
    /// deliberately excluded: `onPlay` and `onRemoveFromPlaylist` are stateless, and the
    /// menu reads favorites/like state from live services inside `PlaylistTrackMenuContent`.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index
            && lhs.isAlbum == rhs.isAlbum
            && lhs.isCurrentTrack == rhs.isCurrentTrack
            && lhs.isPlaying == rhs.isPlaying
            && lhs.showsSeparator == rhs.showsSeparator
            && lhs.isScrolling == rhs.isScrolling
            && lhs.song.videoId == rhs.song.videoId
            && lhs.song.title == rhs.song.title
            && lhs.song.artistsDisplay == rhs.song.artistsDisplay
            && lhs.song.duration == rhs.song.duration
            && lhs.song.thumbnailURL == rhs.song.thumbnailURL
            && lhs.song.album?.id == rhs.song.album?.id
    }

    var body: some View {
        HStack(spacing: 8) {
            self.playButton

            Menu {
                self.menuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Self.contentInset)
        // The highlight is drawn at row level, not by the play button's style, so that it covers
        // the whole row. `List` draws its own decoration around a right-clicked row spanning the
        // entire row, and that decoration cannot be turned off or reshaped (see ADR-0014), so the
        // row's element is made the same shape instead of an inset rounded pill that does not line
        // up with it. Zero `listRowInsets` at the call site is what lets this fill reach the edges.
        .background(Rectangle().fill(self.showsHighlight ? Self.highlightColor : .clear))
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isPointerInside = hovering
        }
        .animation(AppAnimation.quick, value: self.showsHighlight)
        .overlay(alignment: .bottom) {
            if self.showsSeparator {
                Divider()
                    // For albums: 28 (index) + 12 (spacing)
                    // For playlists: 28 (index) + 12 (spacing) + 40 (thumbnail) + 16 (spacing)
                    .padding(.leading, Self.contentInset + (self.isAlbum ? 40 : 96))
            }
        }
    }

    /// Highlight is shown only while hovering *and* not scrolling: rows passing under a stationary
    /// pointer during a flick must not swap their background mid-scroll.
    private var showsHighlight: Bool {
        self.isPointerInside && !self.isScrolling
    }

    /// The tappable row content, with its context menu and add-to-playlist popover.
    @ViewBuilder
    private var playButton: some View {
        let button = Button {
            self.onPlay()
        } label: {
            self.rowLabel
        }
        // This row draws its own full-bleed highlight, so the style contributes only its press
        // feedback.
        .buttonStyle(.interactiveRow(cornerRadius: 6, drawsBackground: false))
        .contextMenu {
            self.menuContent
        }
        .popover(isPresented: self.$isShowingAddToPlaylist, arrowEdge: .top) {
            AddToPlaylistPopoverContent(
                song: self.song,
                client: self.client,
                libraryViewModel: self.libraryViewModel
            )
        }

        if self.index < Self.entranceAnimationRowLimit {
            button.staggeredAppearance(index: self.index, itemId: self.song.videoId)
        } else {
            button
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            // Now playing indicator or index
            Group {
                if self.isCurrentTrack {
                    NowPlayingIndicator(isPlaying: self.isPlaying, size: 14)
                } else {
                    Text("\(self.index + 1)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, alignment: .trailing)

            // Thumbnail - only show for playlists (different album art per track)
            // Albums share the same artwork, so we hide per-track thumbnails
            if !self.isAlbum {
                CachedAsyncImage(url: self.song.thumbnailURL, targetSize: Self.thumbnailSize) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                }
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 4))
            }

            // Title and artist
            VStack(alignment: .leading, spacing: 2) {
                Text(self.song.title)
                    .font(.system(size: 14))
                    .foregroundStyle(self.isCurrentTrack ? .red : .primary)
                    .lineLimit(1)

                Text(self.song.artistsDisplay)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Duration
            Text(self.song.durationDisplay)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var menuContent: some View {
        PlaylistTrackMenuContent(
            song: self.song,
            isAlbum: self.isAlbum,
            favoritesManager: self.favoritesManager,
            likeStatusManager: self.likeStatusManager,
            playerService: self.playerService,
            onPlay: self.onPlay,
            onAddToPlaylist: { self.isShowingAddToPlaylist = true },
            onRemoveFromPlaylist: self.onRemoveFromPlaylist
        )
    }
}

// MARK: - PlaylistTrackMenuContent

/// Menu items shared by a playlist track row's context menu and its trailing ellipsis menu.
///
/// This is a dedicated view so the favorites/like lookups happen inside *this* view's body
/// rather than the playlist list's body. Otherwise every visible row would subscribe the
/// list to `FavoritesManager`, and pinning a favorite anywhere in the app would rebuild all
/// of them.
@available(macOS 26.0, *)
struct PlaylistTrackMenuContent: View {
    let song: Song
    let isAlbum: Bool
    let favoritesManager: FavoritesManager
    let likeStatusManager: SongLikeStatusManager
    let playerService: PlayerService
    let onPlay: () -> Void
    let onAddToPlaylist: () -> Void
    let onRemoveFromPlaylist: (Song) -> Void

    var body: some View {
        Button {
            self.onPlay()
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Divider()

        FavoritesContextMenu.menuItem(for: self.song, manager: self.favoritesManager)

        Divider()

        LikeDislikeContextMenu(song: self.song, likeStatusManager: self.likeStatusManager)

        Divider()

        StartRadioContextMenu.menuItem(for: self.song, playerService: self.playerService)

        Divider()

        Button {
            SongActionsHelper.addToLibrary(self.song, playerService: self.playerService)
        } label: {
            Label("Add to Library", systemImage: "plus.circle")
        }

        Divider()

        ShareContextMenu.menuItem(for: self.song)

        Divider()

        AddToQueueContextMenu(song: self.song, playerService: self.playerService)

        Divider()

        Button {
            self.onAddToPlaylist()
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        if !self.isAlbum {
            Divider()

            Button(role: .destructive) {
                self.onRemoveFromPlaylist(self.song)
            } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
        }

        Divider()

        if let artist = self.song.artists.first(where: { $0.hasNavigableId }) {
            NavigationLink(value: artist) {
                Label("Go to Artist", systemImage: "person")
            }
        }

        if let album = self.song.album, album.hasNavigableId {
            let playlist = Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL ?? self.song.thumbnailURL,
                trackCount: album.trackCount,
                author: album.artistsDisplay
            )
            NavigationLink(value: playlist) {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
    }
}
