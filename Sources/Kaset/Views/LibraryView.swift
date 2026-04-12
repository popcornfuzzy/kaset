import SwiftUI

// MARK: - LibraryFilter

/// Filter options for the Library view.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case playlists = "Playlists"
    case artists = "Artists"
    case podcasts = "Podcasts"

    var id: String {
        self.rawValue
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .playlists: "music.note.list"
        case .artists: "person.fill"
        case .podcasts: "mic.fill"
        }
    }

    var displayName: String {
        switch self {
        case .all:
            String(localized: "All")
        case .playlists:
            String(localized: "Playlists")
        case .artists:
            String(localized: "Artists")
        case .podcasts:
            String(localized: "Podcasts")
        }
    }
}

// MARK: - LibraryView

/// Library view displaying user's playlists and podcast shows.
@available(macOS 26.0, *)
struct LibraryView: View {
    @State var viewModel: LibraryViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager
    @State private var networkMonitor = NetworkMonitor.shared

    @State private var navigationPath = NavigationPath()
    @State private var selectedFilter: LibraryFilter = .all
    @State private var showCreatePlaylistPopover = false

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            Group {
                if !self.networkMonitor.isConnected {
                    ErrorView(
                        title: String(localized: "No Connection"),
                        message: String(localized: "Please check your internet connection and try again.")
                    ) {
                        Task { await self.viewModel.refreshFromNetwork() }
                    }
                } else {
                    switch self.viewModel.loadingState {
                    case .idle, .loading:
                        LoadingView(String(localized: "Loading your library..."))
                    case .loaded, .loadingMore:
                        self.contentView
                    case let .error(error):
                        ErrorView(error: error) {
                            Task { await self.viewModel.refreshFromNetwork() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Library")
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: PlaylistDetailViewModel(
                        playlist: playlist,
                        client: self.viewModel.client
                    )
                )
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: self.viewModel.client,
                        libraryViewModel: self.viewModel
                    )
                )
            }
            .navigationDestination(for: PodcastShow.self) { show in
                PodcastShowView(show: show, client: self.viewModel.client)
            }
        }
        .environment(self.viewModel)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
            await self.viewModel.reloadIfNeededOnActivation()
        }
        .task(id: "\(self.navigationPath.count)-\(self.viewModel.activationReloadGeneration)") {
            guard self.navigationPath.isEmpty else { return }
            await self.viewModel.reloadIfNeededOnActivation()
        }
        .refreshable {
            await self.viewModel.refreshFromNetwork()
        }
    }

    // MARK: - Views

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Filter chips
                self.filterChips

                // Combined grid with filtered content
                self.libraryGrid
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(LibraryFilter.allCases) { filter in
                self.filterChip(filter)
            }
            Spacer()

            Button {
                Task {
                    await self.viewModel.refreshFromNetwork()
                }
            } label: {
                if self.viewModel.loadingState == .loading || self.viewModel.loadingState == .loadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(self.viewModel.loadingState == .loading || self.viewModel.loadingState == .loadingMore)
            .help(String(localized: "Refresh Library"))
        }
    }

    private func filterChip(_ filter: LibraryFilter) -> some View {
        let isSelected = self.selectedFilter == filter

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.selectedFilter = filter
            }
        } label: {
            Text(filter.displayName)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                }
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// All library items combined and filtered.
    private var filteredItems: [LibraryItem] {
        var items: [LibraryItem] = []

        switch self.selectedFilter {
        case .all:
            items = self.viewModel.playlists.map { .playlist($0) }
                + self.viewModel.artists.map { .artist($0) }
                + self.viewModel.podcastShows.map { .podcast($0) }
        case .playlists:
            items = self.viewModel.playlists.map { .playlist($0) }
        case .artists:
            items = self.viewModel.artists.map { .artist($0) }
        case .podcasts:
            items = self.viewModel.podcastShows.map { .podcast($0) }
        }

        return items
    }

    private var libraryGrid: some View {
        let shouldShowCreatePlaylistCard = self.selectedFilter == .all || self.selectedFilter == .playlists

        return Group {
            if self.filteredItems.isEmpty, !shouldShowCreatePlaylistCard {
                self.emptyStateView
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16),
                ], spacing: 16) {
                    if shouldShowCreatePlaylistCard {
                        self.createPlaylistCard
                    }

                    ForEach(self.filteredItems) { item in
                        switch item {
                        case let .playlist(playlist):
                            self.playlistCard(playlist)
                        case let .artist(artist):
                            self.artistCard(artist)
                        case let .podcast(show):
                            self.podcastCard(show)
                        }
                    }
                }
            }
        }
    }

    private var createPlaylistCard: some View {
        Button {
            self.showCreatePlaylistPopover = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 160, height: 160)

                Text("Add Playlist")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                Text("0 songs", comment: "Playlist track count")
                    .font(.system(size: 11))
                    .opacity(0)
            }
            .frame(width: 160, height: 214, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: self.$showCreatePlaylistPopover, arrowEdge: .top) {
            CreatePlaylistPopover(
                client: self.viewModel.client,
                libraryViewModel: self.viewModel
            )
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: self.selectedFilter.icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(self.emptyStateTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(self.emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var emptyStateTitle: String {
        switch self.selectedFilter {
        case .all:
            String(localized: "Your library is empty")
        case .playlists:
            String(localized: "No playlists yet")
        case .artists:
            String(localized: "No artists yet")
        case .podcasts:
            String(localized: "No podcasts yet")
        }
    }

    private var emptyStateMessage: String {
        switch self.selectedFilter {
        case .all:
            String(localized: "Save playlists, follow artists, and subscribe to podcasts on YouTube Music to see them here.")
        case .playlists:
            String(localized: "Create or save playlists on YouTube Music to see them here.")
        case .artists:
            String(localized: "Follow artists on YouTube Music to see them here.")
        case .podcasts:
            String(localized: "Subscribe to podcasts on YouTube Music to see them here.")
        }
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        let trackCountText = playlist.trackCount.map { "\($0) songs" } ?? "0 songs"
        let shouldShowTrackCount = playlist.trackCount != nil

        return Button {
            self.navigationPath.append(playlist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: playlist.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 160, height: 160)
                .clipShape(.rect(cornerRadius: 8))

                // Title
                Text(playlist.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                // Track count
                Text(trackCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .opacity(shouldShowTrackCount ? 1 : 0)
            }
            .frame(width: 160, height: 214, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }

    private func podcastCard(_ show: PodcastShow) -> some View {
        Button {
            self.navigationPath.append(show)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                CachedAsyncImage(url: show.thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "mic.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 160, height: 160)
                .clipShape(.rect(cornerRadius: 8))

                // Title
                Text(show.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 160, alignment: .leading)

                // Author
                if let author = show.author {
                    Text(author)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            FavoritesContextMenu.menuItem(for: show, manager: self.favoritesManager)
        }
    }

    private func artistCard(_ artist: Artist) -> some View {
        Button {
            self.navigationPath.append(artist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: artist.thumbnailURL?.highQualityThumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 128, height: 128)
                .clipShape(Circle())
                .frame(width: 160)

                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 160)

                Text(String(localized: "Artist"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 160)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            FavoritesContextMenu.menuItem(for: artist, manager: self.favoritesManager)
            ShareContextMenu.menuItem(for: artist)
        }
    }
}

// MARK: - LibraryItem

/// Represents a library item that can be a playlist, artist, or podcast show.
enum LibraryItem: Identifiable {
    case playlist(Playlist)
    case artist(Artist)
    case podcast(PodcastShow)

    var id: String {
        switch self {
        case let .playlist(playlist):
            "playlist-\(playlist.id)"
        case let .artist(artist):
            "artist-\(artist.id)"
        case let .podcast(show):
            "podcast-\(show.id)"
        }
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LibraryView(viewModel: LibraryViewModel(client: client))
        .environment(PlayerService())
        .environment(FavoritesManager.shared)
}
