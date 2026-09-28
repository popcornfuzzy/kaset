import FoundationModels
import SwiftUI

// MARK: - PlaylistDetailView

/// Detail view for a playlist showing its tracks.
@available(macOS 26.0, *)
struct PlaylistDetailView: View {
    let playlist: Playlist
    @State var viewModel: PlaylistDetailViewModel

    /// Pushes an artist page onto the stack this page is shown in. Handed in by whoever registered the
    /// page's navigation destinations, because a pushed page cannot reach the enclosing stack's path
    /// itself and must not declare a second `navigationDestination` (see `contentView(_:)`).
    let onNavigateToArtist: (Artist) -> Void
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @Environment(\.dismiss) private var dismiss

    /// Tracks whether this playlist has been added to library in this session.
    @State private var isAddedToLibrary: Bool = false

    /// Whether the refine playlist sheet is visible.
    @State private var showRefineSheet: Bool = false

    /// AI-generated playlist changes.
    @State private var playlistChanges: PlaylistChanges?

    /// Partial playlist changes during streaming.
    @State private var partialChanges: PlaylistChanges.PartiallyGenerated?

    /// Whether AI is processing the refine request.
    @State private var isRefining: Bool = false

    /// Error message from refine operation.
    @State private var refineError: String?

    /// Whether playlist rename popover is visible.
    @State private var showRenamePlaylistPopover: Bool = false

    /// Whether delete confirmation is visible.
    @State private var showDeletePlaylistAlert: Bool = false

    /// Draft title for rename action.
    @State private var playlistTitleDraft: String = ""

    /// Whether a rename request is currently in progress.
    @State private var isRenamingPlaylist: Bool = false

    /// Whether a delete request is currently in progress.
    @State private var isDeletingPlaylist: Bool = false

    /// Whether a refresh request is currently in progress.
    @State private var isRefreshing: Bool = false

    /// Error message for playlist management actions.
    @State private var playlistActionError: String?

    /// Whether the track list is scrolling. Used to suspend row hover highlighting so rows
    /// passing under a stationary pointer don't animate their background mid-flick.
    @State private var isScrolling: Bool = false

    /// Search query for filtering the playlist's tracks. Typing it triggers a full scan so the
    /// search covers every song in the playlist, not only the rows already loaded.
    @State private var searchText: String = ""

    /// Focus for the compact search field in the toolbar.
    @FocusState private var isSearchFieldFocused: Bool

    /// Scroll distance from the bottom, in points, at which the next page is requested.
    /// Requesting a page this early keeps the fetch and its spinner below the visible
    /// window, so scrolling never waits on the network.
    private static let paginationThreshold: CGFloat = 1200

    /// Bucket size for the near-bottom check. Bucketing instead of a plain boolean means a
    /// short page that still leaves the list near its bottom triggers on the next nudge.
    private static let paginationBucket: CGFloat = 200

    /// How many upcoming rows' artwork to warm in the image cache.
    private static let thumbnailPrefetchWindow = 60

    /// Edge length of the header thumbnail. It also sets the height of the header's info column, so
    /// the action row lines up with the thumbnail's bottom edge.
    private static let artworkSize: CGFloat = 180

    /// Computed property to check if playlist is in library.
    private var isInLibrary: Bool {
        self.libraryViewModel?.isInLibrary(playlistId: self.playlist.id) ?? false
    }

    private let logger = DiagnosticsLogger.ai

    init(
        playlist: Playlist,
        viewModel: PlaylistDetailViewModel,
        onNavigateToArtist: @escaping (Artist) -> Void
    ) {
        self.playlist = playlist
        _viewModel = State(initialValue: viewModel)
        self.onNavigateToArtist = onNavigateToArtist
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading playlist..."))
            case .loaded, .loadingMore:
                if let detail = viewModel.playlistDetail {
                    self.contentView(detail)
                } else {
                    ErrorView(title: String(localized: "Unable to load playlist"), message: String(localized: "Playlist not found")) {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .accentBackground(from: self.viewModel.playlistDetail?.thumbnailURL?.highQualityThumbnailURL)
        .navigationTitle(self.viewModel.playlistDetail?.title ?? self.playlist.title)
        .onChange(of: self.searchText) { _, newValue in
            // Search covers the whole playlist, so pull the remaining pages the first time a query
            // is typed instead of only filtering what has scrolled into view.
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await self.viewModel.loadAllTracksForSearch() }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                self.searchField
            }

            // Included only when the playlist can be sorted. An always-present item with a
            // conditional body collapses to an empty toolbar item.
            if let detail = self.viewModel.playlistDetail, detail.isSortable {
                ToolbarItem(placement: .automatic) {
                    self.sortMenu(detail)
                }
            }

            // `ToolbarSpacer` ends the group the items above belong to. Without it, a toolbar that
            // is down to just the search field and the refresh button draws them inside one shared
            // glass capsule, and the refresh glyph lands on the right edge of the search pill (the
            // sort menu happened to keep them apart while it was there). This is macOS 26's way of
            // giving the refresh button its own background.
            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await self.performRefresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(self.isRefreshing ? 360 : 0))
                        .animation(
                            self.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                            value: self.isRefreshing
                        )
                }
                .help(String(localized: "Refresh"))
                .disabled(self.isRefreshing || self.viewModel.loadingState == .loading || self.viewModel.loadingState == .loadingMore)
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .topFade()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {} else {
                PlayerBar()
            }
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
        }
        .refreshable {
            await self.performRefresh()
        }
        .sheet(isPresented: self.$showRefineSheet) {
            if let detail = viewModel.playlistDetail {
                RefinePlaylistSheet(
                    tracks: detail.tracks,
                    isProcessing: self.$isRefining,
                    changes: self.$playlistChanges,
                    partialChanges: self.$partialChanges,
                    errorMessage: self.$refineError,
                    onRefine: { prompt in
                        await self.refinePlaylist(tracks: detail.tracks, prompt: prompt)
                    },
                    onApply: {
                        // Playlist modification via API not yet implemented
                        // For now, just close the sheet
                        self.showRefineSheet = false
                    }
                )
            }
        }
    }

    // MARK: - Views

    /// The tracks are rendered by an AppKit-backed `List`, whose rows are laid out and reused by
    /// NSTableView. A `ScrollView` + `LazyVStack` re-measures and re-renders the whole realised page
    /// on every scroll frame, which made the per-frame cost proportional to the rows' view-tree size
    /// — see ADR-0014 for the measurements.
    ///
    /// The header is the list's **first row**: it scrolls away with the tracks, and the table measures
    /// it, so the page never has to guess its height (ADR-0023).
    ///
    /// It is deliberately not a section header. On macOS a `List`'s section header is a floating group
    /// row: it parks itself on top of the tracks for the rest of the scroll, and a navigation started
    /// from it still selects it, so the sticky band and the highlight come together.
    ///
    /// Nothing in the header navigates on its own either. A `NavigationLink` (and a `Menu`, which hands
    /// its items the same activation) inside a row makes the table treat the row as the navigation
    /// source: it selects the row, paints that selection across the whole header — accent while the
    /// window is key, gray while it is not — and keeps the row's activation, so a second click on the
    /// same control is swallowed. `.listRowBackground(Color.clear)`, `.borderless`, `.selectionDisabled`
    /// and rebuilding the row on return all left it in place. The credited artists are plain buttons that
    /// push the artist onto the stack's own path instead; see `artistCredit(_:)` and ADR-0023.
    private func contentView(_ detail: PlaylistDetail) -> some View {
        let tracks = self.visibleTracks(detail)

        return self.withScrollObservers(
            List {
                // The header is a row, so the table lays it out and the page never has to guess how
                // tall it is; being a row is also what lets it scroll away with the tracks.
                self.headerView(detail)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24))
                    .listRowBackground(Color.clear)

                Divider()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                    .listRowBackground(Color.clear)

                if !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.searchStatusRow(detail, matchCount: tracks.count)
                }

                self.trackRows(detail, tracks: tracks)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .task(id: detail.tracks.count) {
                await self.prefetchUpcomingThumbnails(for: detail.tracks)
            }
        )
    }

    /// The tracks that match the current query, or every loaded track when there is no query.
    private func visibleTracks(_ detail: PlaylistDetail) -> [Song] {
        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return detail.tracks }

        return detail.tracks.filter { song in
            song.title.localizedCaseInsensitiveContains(query)
                || song.artistsDisplay.localizedCaseInsensitiveContains(query)
                || (song.album?.title.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Status line above the results while a search is running over the whole playlist.
    @ViewBuilder
    private func searchStatusRow(_ detail: PlaylistDetail, matchCount: Int) -> some View {
        Group {
            if self.viewModel.isLoadingAllTracks {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching all songs…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if matchCount == 0 {
                Text("No songs match \u{201C}\(self.searchText)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(matchCount) of \(detail.resolvedTrackCount) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// Paging and hover suppression are attached to whichever scroll container renders the page.
    private func withScrollObservers<V: View>(_ content: V) -> some View {
        content
            .onScrollPhaseChange { _, newPhase, _ in
                // Suspend hover highlighting while rows move under a stationary pointer.
                let isScrolling = newPhase != .idle
                if isScrolling != self.isScrolling {
                    self.isScrolling = isScrolling
                }
            }
            .onScrollGeometryChange(for: Int.self) { geometry in
                // Bucket the remaining scroll distance so the value keeps changing as the user
                // scrolls near the bottom instead of latching true. Paging stays off while a
                // search owns the list, since the search already pulls every page.
                guard self.viewModel.hasMore, self.searchText.isEmpty else { return .max }
                let remaining = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                guard remaining < Self.paginationThreshold else { return .max }
                return max(0, Int(remaining / Self.paginationBucket))
            } action: { _, bucket in
                guard bucket != .max else { return }
                Task {
                    await self.viewModel.loadMore()
                }
            }
    }

    /// Thumbnail, title and credits in a row, with the action row on the thumbnail's bottom edge.
    ///
    /// The actions are aligned rather than pushed down by a `Spacer` in the info column: everything in
    /// the box is then a definite size, so the row's height is the 180 pt thumbnail plus the insets and
    /// the buttons land on its baseline. A `Spacer` left the header free to absorb the row's height and
    /// the buttons drifted ~140 pt below the credits (see ADR-0023).
    private func headerView(_ detail: PlaylistDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            HStack(alignment: .top, spacing: 20) {
                // Thumbnail
                CachedAsyncImage(url: detail.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .clipShape(.rect(cornerRadius: 8))
                .fadeIn(duration: 0.3)
                .accessibilityIdentifier(AccessibilityID.PlaylistDetail.artwork)

                // Info
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.isAlbum ? String(localized: "Album") : String(localized: "Playlist"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Text(detail.title)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    self.creditsView(detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            self.headerButtons(detail)
                .padding(.leading, Self.artworkSize + 20)
        }
    }

    private func makeFallbackAlbum(from detail: PlaylistDetail) -> Album {
        Album(
            id: detail.id,
            title: detail.title,
            // Prefer the credited artists so queued songs keep their channel links.
            artists: detail.artists.isEmpty
                ? detail.author.map { [Artist(id: "unknown", name: $0)] }
                : detail.artists,
            thumbnailURL: detail.thumbnailURL,
            year: nil,
            trackCount: detail.trackCount ?? detail.tracks.count
        )
    }

    /// The playlist's creators or the album's artists, on one line: semibold names, secondary
    /// separators. Every name that carries a channel ID is its own control, so an album crediting
    /// several artists opens the one that was clicked — the row's activation, which handed a single
    /// click to every link in the row and always pushed the last of them, is no longer involved.
    ///
    /// A header that exposed no artists at all falls back to the author string.
    @ViewBuilder
    private func creditsView(_ detail: PlaylistDetail) -> some View {
        if detail.artists.isEmpty {
            if let author = detail.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 0) {
                ForEach(Array(detail.artists.enumerated()), id: \.element.id) { index, artist in
                    if index > 0 {
                        Text(verbatim: ", ")
                            .foregroundStyle(.secondary)
                    }

                    self.artistCredit(artist)
                }
            }
            .font(.subheadline)
        }
    }

    /// A credited artist that opens its page on click.
    ///
    /// A button, not a `NavigationLink`: the credit lives in the header row, and a link in a row makes
    /// the table select that row — painting its highlight over the header and swallowing the row's next
    /// click — as well as handing one click to every link the row contains. Pushing through the stack's
    /// own path, which the page is handed as `onNavigateToArtist`, is the only navigation that does
    /// neither. Names without a channel ID stay plain text.
    ///
    /// The page must not declare its own `navigationDestination` instead: `PlaylistDetailView` is itself
    /// a destination, and a second destination on the same stack re-lays out the page in a loop and
    /// freezes the app (ADR-0023).
    ///
    /// Kept in sync with `PlaylistArtistNavigationUITests`, which clicks a single credit, presses Back
    /// and clicks it again.
    @ViewBuilder
    private func artistCredit(_ artist: Artist) -> some View {
        if artist.hasNavigableId {
            Button {
                self.onNavigateToArtist(artist)
            } label: {
                Text(artist.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.PlaylistDetail.artistCredit(artist.id))
        } else {
            Text(artist.name)
                .foregroundStyle(.secondary)
        }
    }

    private func headerButtons(_ detail: PlaylistDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                // Play all button
                Button {
                    let fallbackAlbum = self.makeFallbackAlbum(from: detail)
                    self.playAll(detail.tracks, fallbackArtist: detail.author, fallbackAlbum: fallbackAlbum)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(detail.tracks.isEmpty)
                .accessibilityIdentifier(AccessibilityID.PlaylistDetail.playButton)

                // Shuffle button
                Button {
                    let fallbackAlbum = self.makeFallbackAlbum(from: detail)
                    self.playShuffled(detail.tracks, fallbackArtist: detail.author, fallbackAlbum: fallbackAlbum)
                } label: {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(detail.tracks.isEmpty)

                // Play Next button
                Button {
                    let fallbackAlbum = self.makeFallbackAlbum(from: detail)
                    SongActionsHelper.addSongsToQueueNext(
                        detail.tracks,
                        playerService: self.playerService,
                        fallbackArtist: detail.author,
                        fallbackAlbum: fallbackAlbum
                    )
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(detail.tracks.isEmpty)

                // Add to Queue button
                Button {
                    let fallbackAlbum = self.makeFallbackAlbum(from: detail)
                    SongActionsHelper.addSongsToQueueLast(
                        detail.tracks,
                        playerService: self.playerService,
                        fallbackArtist: detail.author,
                        fallbackAlbum: fallbackAlbum
                    )
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(detail.tracks.isEmpty)

                // Add/Remove Library button
                let currentlyInLibrary = self.isInLibrary || self.isAddedToLibrary
                if !currentlyInLibrary {
                    Button {
                        self.toggleLibrary()
                    } label: {
                        Label(String(localized: "Add to Library"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                // Refine Playlist button (AI-powered)
                if !detail.isAlbum {
                    Menu {
                        Button {
                            self.playlistTitleDraft = detail.title
                            self.playlistActionError = nil
                            self.showRenamePlaylistPopover = true
                        } label: {
                            Label("Rename Playlist", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            self.playlistActionError = nil
                            self.showDeletePlaylistAlert = true
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(self.isRenamingPlaylist || self.isDeletingPlaylist)
                    .popover(isPresented: self.$showRenamePlaylistPopover, arrowEdge: .top) {
                        self.renamePlaylistPopover
                    }
                    .alert("Delete Playlist?", isPresented: self.$showDeletePlaylistAlert) {
                        Button("Cancel", role: .cancel) {}
                        Button("Delete", role: .destructive) {
                            Task {
                                await self.deletePlaylist()
                            }
                        }
                        .disabled(self.isDeletingPlaylist)
                    } message: {
                        Text("This removes the playlist from YouTube Music. This action cannot be undone.")
                    }

                    Button {
                        self.showRefineSheet = true
                    } label: {
                        Label("Refine", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .requiresIntelligence()
                }
            }

            Text(self.metadataText(for: detail))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let playlistActionError {
                Text(playlistActionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if let sortOrderError = viewModel.sortOrderError {
                Text(sortOrderError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    /// Compact toolbar search field. Fixed width keeps it from stretching across the toolbar; the
    /// toolbar supplies the container background, so no extra glass is layered on top.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField(String(localized: "Search in playlist"), text: self.$searchText)
                .textFieldStyle(.plain)
                .focused(self.$isSearchFieldFocused)
                .frame(width: 140)

            if !self.searchText.isEmpty {
                Button {
                    self.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Toolbar menu that mirrors YouTube Music's playlist sort options. The active order is shown by
    /// the check mark in the dropdown; choosing one writes the order to the account and reloads the
    /// tracks in the new order.
    private func sortMenu(_ detail: PlaylistDetail) -> some View {
        Menu {
            // Toggles render as menu items with a check mark, which is what actually shows the
            // active order in a macOS menu (a `Label` image does not).
            ForEach(detail.sortOptions, id: \.self) { order in
                Toggle(order.displayName, isOn: Binding(
                    get: { detail.effectiveSortOrder == order },
                    set: { isSelected in
                        guard isSelected else { return }
                        Task { await self.viewModel.changeSortOrder(to: order) }
                    }
                ))
            }
        } label: {
            Label(String(localized: "Sort"), systemImage: "arrow.up.arrow.down")
        }
        .help(Text("Sort by \(detail.effectiveSortOrder.displayName). This order is saved to your YouTube Music account."))
        .disabled(self.viewModel.isChangingSortOrder)
    }

    private func metadataText(for detail: PlaylistDetail) -> String {
        if let duration = detail.duration {
            return "\(detail.trackCountDisplay) • \(duration)"
        }

        return detail.trackCountDisplay
    }

    private func performRefresh() async {
        self.isRefreshing = true
        await self.viewModel.refresh()
        await self.libraryViewModel?.refreshFromNetwork()
        self.isRefreshing = false
    }

    private var renamePlaylistPopover: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rename Playlist")
                    .font(.headline)

                TextField("Playlist title", text: self.$playlistTitleDraft)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()

                    Button("Cancel") {
                        self.showRenamePlaylistPopover = false
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await self.renamePlaylist()
                        }
                    } label: {
                        if self.isRenamingPlaylist {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.isRenamingPlaylist || self.playlistTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
            .frame(width: 300)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        }
    }

    /// Tracks list. Rows are individually equatable so player and paging updates no longer
    /// rebuild the visible window, and upcoming artwork is warmed ahead of the scroll.
    /// The track rows plus the paging spinner.
    @ViewBuilder
    private func trackRows(_ detail: PlaylistDetail, tracks: [Song]) -> some View {
        let isAlbum = detail.isAlbum
        // Read the player state once per pass: each row only needs to know whether *it* is the
        // current track, which keeps rows out of the observation dependency for playback.
        let currentVideoId = self.playerService.currentTrack?.videoId
        let isPlaying = self.playerService.isPlaying

        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            PlaylistTrackRow(
                song: track,
                index: index,
                isAlbum: isAlbum,
                isCurrentTrack: currentVideoId == track.videoId,
                isPlaying: isPlaying,
                showsSeparator: index < tracks.count - 1,
                isScrolling: self.isScrolling,
                favoritesManager: self.favoritesManager,
                likeStatusManager: self.likeStatusManager,
                playerService: self.playerService,
                client: self.viewModel.client,
                libraryViewModel: self.libraryViewModel,
                onPlay: { self.playTrack(in: tracks, at: index) },
                onRemoveFromPlaylist: { song in
                    Task {
                        await self.removeTrackFromCurrentPlaylist(song)
                    }
                }
            )
            .equatable()
            .listRowSeparator(.hidden)
            // No row insets: the row spans the full width of the list and insets its own content,
            // so its highlight can be full-bleed like the decoration `List` draws around the row a
            // right-click lands on (see ADR-0014). An inset row cannot be made to line up with it.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        // Loading indicator for pagination. Paging itself is driven by scroll proximity,
        // so the fetch and this spinner sit below the visible window. Hidden while searching,
        // where the status row reports progress instead.
        if self.viewModel.loadingState == .loadingMore, self.searchText.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .padding()
                Spacer()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    /// Plays the row's queue from the list currently on screen, so a filtered result plays the
    /// filtered songs rather than the full playlist.
    private func playTrack(in tracks: [Song], at index: Int) {
        guard let detail = self.viewModel.playlistDetail,
              tracks.indices.contains(index)
        else { return }

        self.playTrackInQueue(
            tracks: tracks,
            startingAt: index,
            fallbackArtist: detail.author,
            fallbackAlbum: self.makeFallbackAlbum(from: detail)
        )
    }

    /// Warms the image cache for the rows the user is about to scroll into, at the same size
    /// the rows decode.
    private func prefetchUpcomingThumbnails(for tracks: [Song]) async {
        guard !Task.isCancelled else { return }

        let start = max(0, tracks.count - Self.thumbnailPrefetchWindow)
        let urls = tracks[start...].compactMap(\.thumbnailURL)
        guard !urls.isEmpty else { return }

        await ImageCache.shared.prefetch(
            urls: urls,
            targetSize: PlaylistTrackRow.thumbnailSize,
            maxConcurrent: 4
        )
    }

    // MARK: - Actions

    private func playTrackInQueue(tracks: [Song], startingAt index: Int, fallbackArtist: String? = nil, fallbackAlbum: Album? = nil) {
        let cleanedTracks = self.cleanTracks(
            tracks,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum,
            forceLikedStatus: Self.isLikedMusicPlaylistId(self.playlist.id)
        )
        Task {
            await self.playerService.playQueue(cleanedTracks, startingAt: index)
        }
    }

    private func playAll(_ tracks: [Song], fallbackArtist: String? = nil, fallbackAlbum: Album? = nil) {
        guard !tracks.isEmpty else { return }
        let cleanedTracks = self.cleanTracks(
            tracks,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum,
            forceLikedStatus: Self.isLikedMusicPlaylistId(self.playlist.id)
        )
        Task {
            await self.playerService.playQueue(cleanedTracks, startingAt: 0)
        }
    }

    private func playShuffled(_ tracks: [Song], fallbackArtist: String? = nil, fallbackAlbum: Album? = nil) {
        guard !tracks.isEmpty else { return }
        let cleanedTracks = self.cleanTracks(
            tracks,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum,
            forceLikedStatus: Self.isLikedMusicPlaylistId(self.playlist.id)
        )
        let shuffledTracks = cleanedTracks.shuffled()
        Task {
            await self.playerService.playQueue(shuffledTracks, startingAt: 0)
        }
    }

    /// Cleans track artists and applies fallback artist/album when needed.
    private func cleanTracks(
        _ tracks: [Song],
        fallbackArtist: String?,
        fallbackAlbum: Album? = nil,
        forceLikedStatus: Bool = false
    ) -> [Song] {
        tracks.map { song in
            var cleanedArtists = song.artists.compactMap { artist -> Artist? in
                if artist.name == "Album" { return nil }
                var cleanName = artist.name
                if cleanName.hasPrefix("Album, ") {
                    cleanName = String(cleanName.dropFirst(7))
                }
                return Artist(id: artist.id, name: cleanName)
            }

            // Use fallback artist if artists are empty (and clean the fallback too)
            if cleanedArtists.isEmpty, let fallback = fallbackArtist, !fallback.isEmpty {
                var cleanFallback = fallback
                if cleanFallback == "Album" {
                    cleanFallback = "Unknown Artist"
                } else if cleanFallback.hasPrefix("Album, ") {
                    cleanFallback = String(cleanFallback.dropFirst(7))
                }
                // Also handle case where it's "Album, Artist" but we got it as a combined string
                if cleanFallback.contains("Album,") {
                    let parts = cleanFallback.split(separator: ",", maxSplits: 1)
                    if parts.count > 1 {
                        cleanFallback = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
                cleanedArtists = [Artist(id: "unknown", name: cleanFallback)]
            }

            // Use fallback album if song doesn't have album info
            let finalAlbum = song.album ?? fallbackAlbum
            // Use fallback thumbnail if song doesn't have one
            let finalThumbnail = song.thumbnailURL ?? fallbackAlbum?.thumbnailURL
            let finalLikeStatus = forceLikedStatus ? .like : song.likeStatus

            return Song(
                id: song.id,
                title: song.title,
                artists: cleanedArtists,
                album: finalAlbum,
                duration: song.duration,
                thumbnailURL: finalThumbnail,
                videoId: song.videoId,
                hasVideo: song.hasVideo,
                musicVideoType: song.musicVideoType,
                likeStatus: finalLikeStatus,
                isInLibrary: song.isInLibrary,
                feedbackTokens: song.feedbackTokens
            )
        }
    }

    private func toggleLibrary() {
        let currentlyInLibrary = self.isInLibrary || self.isAddedToLibrary
        HapticService.success()
        Task {
            if currentlyInLibrary {
                await SongActionsHelper.removePlaylistFromLibrary(
                    self.playlist,
                    client: self.viewModel.client,
                    libraryViewModel: self.libraryViewModel
                )
                self.isAddedToLibrary = false
            } else {
                await SongActionsHelper.addPlaylistToLibrary(
                    self.playlist,
                    client: self.viewModel.client,
                    libraryViewModel: self.libraryViewModel
                )
                self.isAddedToLibrary = true
            }
        }
    }

    private func renamePlaylist() async {
        let trimmedTitle = self.playlistTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        self.isRenamingPlaylist = true
        defer { self.isRenamingPlaylist = false }

        do {
            try await self.viewModel.client.renamePlaylist(playlistId: self.playlist.id, newTitle: trimmedTitle)
            self.libraryViewModel?.updatePlaylistTitle(playlistId: self.playlist.id, newTitle: trimmedTitle)
            self.libraryViewModel?.markNeedsReloadOnActivation()
            self.playlistActionError = nil
            self.showRenamePlaylistPopover = false
            await self.viewModel.refresh()
            await self.libraryViewModel?.refreshFromNetwork()
        } catch {
            self.playlistActionError = error.localizedDescription
            DiagnosticsLogger.api.error("Failed to rename playlist: \(error.localizedDescription)")
        }
    }

    private func removeTrackFromCurrentPlaylist(_ track: Song) async {
        do {
            if Self.isLikedMusicPlaylistId(self.playlist.id) {
                try await self.viewModel.client.rateSong(videoId: track.videoId, rating: .indifferent)
            } else {
                try await self.viewModel.client.removeSongFromPlaylist(
                    videoId: track.videoId,
                    playlistId: self.playlist.id,
                    setVideoId: nil
                )
            }

            self.playlistActionError = nil
            self.libraryViewModel?.markNeedsReloadOnActivation()
            await self.viewModel.refresh()
            await self.libraryViewModel?.refreshFromNetwork()
        } catch {
            self.playlistActionError = error.localizedDescription
            DiagnosticsLogger.api.error("Failed to remove track from playlist: \(error.localizedDescription)")
        }
    }

    private static func isLikedMusicPlaylistId(_ playlistId: String) -> Bool {
        if playlistId == "LM" || playlistId == "VLLM" {
            return true
        }

        if playlistId.hasPrefix("VL") {
            return String(playlistId.dropFirst(2)) == "LM"
        }

        return false
    }

    private func deletePlaylist() async {
        self.isDeletingPlaylist = true
        defer { self.isDeletingPlaylist = false }

        do {
            try await self.viewModel.client.deletePlaylist(playlistId: self.playlist.id)
            self.libraryViewModel?.removeFromLibrary(playlistId: self.playlist.id)
            self.libraryViewModel?.markNeedsReloadOnActivation()
            self.playlistActionError = nil
            await self.libraryViewModel?.refreshFromNetwork()
            self.dismiss()
        } catch {
            self.playlistActionError = error.localizedDescription
            DiagnosticsLogger.api.error("Failed to delete playlist: \(error.localizedDescription)")
        }
    }

    private func refinePlaylist(tracks: [Song], prompt: String) async {
        self.isRefining = true
        self.refineError = nil
        self.playlistChanges = nil
        self.partialChanges = nil

        self.logger.info("Refining playlist with prompt: \(prompt)")

        let instructions = """
        You are a music playlist curator. Analyze songs and suggest changes based on the request.

        IMPORTANT RULES:
        - A "duplicate" means the EXACT same video ID appears twice. Different versions/covers
          of a song by different artists are NOT duplicates.
        - "Last Christmas" by Wham! and "Last Christmas" by Jimmy Eat World are DIFFERENT songs.
        - Only suggest removing tracks that truly don't fit the user's criteria.
        - When in doubt, keep the song.
        """

        // Use analysis session for creative playlist curation
        guard let session = FoundationModelsService.shared.createAnalysisSession(instructions: instructions) else {
            self.refineError = "Apple Intelligence is not available"
            self.isRefining = false
            return
        }

        // Build track list - limit to 25 to reduce content filter issues
        let trackLimit = min(tracks.count, 25)
        let trackList = tracks.prefix(trackLimit).enumerated().map { index, track in
            // Sanitize track info to reduce content filter triggers
            let safeTitle = track.title.prefix(50)
            let safeArtist = track.artistsDisplay.prefix(30)
            return "\(index + 1). \(safeTitle) - \(safeArtist) [id:\(track.videoId)]"
        }.joined(separator: "\n")

        let userPrompt = """
        Playlist (\(tracks.count) songs, showing \(trackLimit)):

        \(trackList)

        Request: \(prompt)
        """

        do {
            // Use streaming for progressive UI updates
            let stream = session.streamResponse(to: userPrompt, generating: PlaylistChanges.self)

            for try await snapshot in stream {
                // Update partial content for streaming UI
                self.partialChanges = snapshot.content
            }

            // Stream complete - convert final partial to complete changes
            if let final = self.partialChanges,
               let removals = final.removals,
               let reasoning = final.reasoning
            {
                self.playlistChanges = PlaylistChanges(
                    removals: removals,
                    reorderedIds: final.reorderedIds,
                    reasoning: reasoning
                )
                self.logger.info("Got playlist changes: \(removals.count) removals")
            }
        } catch {
            // Use centralized error handler for consistent messaging
            if let message = AIErrorHandler.handleAndMessage(error, context: "playlist refinement") {
                self.refineError = message
            }
        }

        self.partialChanges = nil
        self.isRefining = false
    }
}

// MARK: - RefinePlaylistSheet

@available(macOS 26.0, *)
private struct RefinePlaylistSheet: View {
    let tracks: [Song]
    @Binding var isProcessing: Bool
    @Binding var changes: PlaylistChanges?
    @Binding var partialChanges: PlaylistChanges.PartiallyGenerated?
    @Binding var errorMessage: String?
    let onRefine: (String) async -> Void
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var promptText = ""
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Refine Playlist")
                    .font(.headline)
                Spacer()
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding()

            Divider()

            // Content
            if self.isProcessing {
                if let partial = partialChanges {
                    self.streamingChangesView(partial)
                } else {
                    self.loadingView
                }
            } else if let changes {
                self.changesView(changes)
            } else {
                self.promptView
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            self.isPromptFocused = true
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 20, height: 20)
            Text("Analyzing playlist...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shows partial changes as they stream in from the AI.
    private func streamingChangesView(_ partial: PlaylistChanges.PartiallyGenerated) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Reasoning (shows as it streams)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
                if let reasoning = partial.reasoning {
                    Text(reasoning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Analyzing...")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)

            Divider()

            // Changes list (shows as items stream in)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let removals = partial.removals, !removals.isEmpty {
                        Text("Suggested Removals")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)

                        ForEach(removals, id: \.self) { videoId in
                            if let track = tracks.first(where: { $0.videoId == videoId }) {
                                HStack {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(track.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(track.artistsDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            // Disabled actions during streaming
            HStack {
                Spacer()
                Text("Processing...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
    }

    private var promptView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What would you like to change?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("e.g., Remove slow songs, reorder by energy...", text: self.$promptText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3 ... 5)
                .focused(self.$isPromptFocused)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                self.suggestionChip("Remove duplicates")
                self.suggestionChip("Make it more upbeat")
                self.suggestionChip("Better flow")
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    self.dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Refine") {
                    Task {
                        await self.onRefine(self.promptText)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding()
    }

    private func changesView(_ changes: PlaylistChanges) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Reasoning
            Text(changes.reasoning)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Divider()

            // Changes list
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !changes.removals.isEmpty {
                        Text("Suggested Removals")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)

                        ForEach(changes.removals, id: \.self) { videoId in
                            if let track = tracks.first(where: { $0.videoId == videoId }) {
                                HStack {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(track.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(track.artistsDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    if changes.removals.isEmpty, changes.reorderedIds == nil {
                        Text("No changes suggested. The playlist looks good!")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            // Actions
            HStack {
                Button("Try Again") {
                    self.changes = nil
                    self.errorMessage = nil
                }

                Spacer()

                Button("Cancel") {
                    self.dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Apply Changes") {
                    self.onApply()
                }
                .buttonStyle(.borderedProminent)
                .disabled(changes.removals.isEmpty && changes.reorderedIds == nil)
            }
            .padding()
        }
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            self.promptText = text
        } label: {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let playlist = Playlist(
        id: "test",
        title: "Test Playlist",
        description: nil,
        thumbnailURL: nil,
        trackCount: 10,
        author: "Test Author"
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    PlaylistDetailView(
        playlist: playlist,
        viewModel: PlaylistDetailViewModel(
            playlist: playlist,
            client: client
        ),
        // The preview has no navigation stack to push onto.
        onNavigateToArtist: { _ in }
    )
    .environment(PlayerService())
}
