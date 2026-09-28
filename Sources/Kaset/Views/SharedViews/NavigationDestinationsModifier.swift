import SwiftUI

// MARK: - NavigationDestinationsModifier

/// View modifier that adds common navigation destinations for Playlist, Artist, MoodCategory, and TopSongsDestination.
/// Note: Lyrics sidebar is handled globally in MainWindow, outside the NavigationSplitView.
///
/// It also forwards the enclosing stack's path to the pages that need to push something themselves —
/// currently only the album/playlist header's artist credit. A pushed page cannot append to the stack's
/// path on its own, and it must not declare a second `navigationDestination` for the artist instead: the
/// page is itself a destination, and a second destination on the same stack re-lays out the page in a
/// loop and freezes the app (ADR-0023).
@available(macOS 26.0, *)
struct NavigationDestinationsModifier: ViewModifier {
    let client: any YTMusicClientProtocol

    /// The path of the stack these destinations are registered on. `NavigationLink(value:)` pushes onto
    /// it by itself; pages that push with a button need it handed to them.
    let artistPath: Binding<NavigationPath>

    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: Playlist.self) { playlist in
                // Check if this is a mood/genre category disguised as a playlist
                if MoodCategory.isMoodCategory(playlist.id) {
                    // Parse the ID and navigate to mood category view
                    if let parsed = MoodCategory.parseId(playlist.id) {
                        let category = MoodCategory(
                            browseId: parsed.browseId,
                            params: parsed.params,
                            title: playlist.title
                        )
                        MoodCategoryDetailView(
                            viewModel: MoodCategoryViewModel(
                                category: category,
                                client: self.client
                            )
                        )
                    } else {
                        // Fallback - shouldn't happen
                        PlaylistDetailView(
                            playlist: playlist,
                            viewModel: PlaylistDetailViewModel(
                                playlist: playlist,
                                client: self.client
                            ),
                            onNavigateToArtist: { artist in self.artistPath.wrappedValue.append(artist) }
                        )
                    }
                } else {
                    PlaylistDetailView(
                        playlist: playlist,
                        viewModel: PlaylistDetailViewModel(
                            playlist: playlist,
                            client: self.client
                        ),
                        onNavigateToArtist: { artist in self.artistPath.wrappedValue.append(artist) }
                    )
                }
            }
            .navigationDestination(for: MoodCategory.self) { (category: MoodCategory) in
                MoodCategoryDetailView(
                    viewModel: MoodCategoryViewModel(
                        category: category,
                        client: self.client
                    )
                )
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    artist: artist,
                    viewModel: ArtistDetailViewModel(
                        artist: artist,
                        client: self.client,
                        libraryViewModel: self.libraryViewModel
                    )
                )
            }
            .navigationDestination(for: TopSongsDestination.self) { destination in
                TopSongsView(viewModel: TopSongsViewModel(
                    destination: destination,
                    client: self.client
                ))
            }
            .navigationDestination(for: PodcastShow.self) { [libraryViewModel] show in
                PodcastShowView(show: show, client: self.client)
                    .environment(libraryViewModel)
            }
            .navigationDestination(for: ArtistSeeAllDestination.self) { destination in
                switch destination.endpoint.pageType {
                case .discography:
                    ArtistDiscographyView(viewModel: ArtistDiscographyViewModel(
                        destination: destination,
                        client: self.client
                    ))
                case .artist:
                    ArtistEpisodesListView(viewModel: ArtistEpisodesListViewModel(
                        destination: destination,
                        client: self.client
                    ))
                case .playlist:
                    // Playlist destinations route through the `Playlist` value
                    // instead of `ArtistSeeAllDestination`, so this branch is
                    // structurally unreachable. Fall back gracefully.
                    EmptyView()
                }
            }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Adds common navigation destinations for Playlist, Artist, MoodCategory, and TopSongsDestination,
    /// and hands `artistPath` to the pages that push an artist with a button.
    func navigationDestinations(client: any YTMusicClientProtocol, artistPath: Binding<NavigationPath>) -> some View {
        modifier(NavigationDestinationsModifier(client: client, artistPath: artistPath))
    }
}
