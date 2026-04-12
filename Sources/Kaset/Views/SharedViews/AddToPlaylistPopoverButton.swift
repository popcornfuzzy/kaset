import SwiftUI

// MARK: - AddToPlaylistPopoverButton

/// Reusable button that opens a popover for adding/removing a song to playlists.
@available(macOS 26.0, *)
struct AddToPlaylistPopoverButton: View {
    let song: Song
    let client: any YTMusicClientProtocol
    let libraryViewModel: LibraryViewModel?
    var icon: String = "text.badge.plus"
    var iconSize: CGFloat = 14
    var usePressableStyle = false

    @State private var isPresented = false

    var body: some View {
        Group {
            if self.usePressableStyle {
                self.baseButton
                    .buttonStyle(.pressable)
            } else {
                self.baseButton
                    .buttonStyle(.plain)
            }
        }
    }

    private var baseButton: some View {
        Button {
            HapticService.toggle()
            self.isPresented.toggle()
        } label: {
            Image(systemName: self.icon)
                .font(.system(size: self.iconSize, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .popover(isPresented: self.$isPresented, arrowEdge: .top) {
            AddToPlaylistPopoverContent(
                song: self.song,
                client: self.client,
                libraryViewModel: self.libraryViewModel
            )
        }
    }
}

// MARK: - AddToPlaylistContextMenu

/// Reusable context-menu submenu for playlist actions.
@available(macOS 26.0, *)
struct AddToPlaylistContextMenu: View {
    let song: Song
    let client: any YTMusicClientProtocol
    let libraryViewModel: LibraryViewModel?

    private var playlists: [Playlist] {
        self.libraryViewModel?.playlists ?? []
    }

    var body: some View {
        Menu {
            if self.playlists.isEmpty {
                Text("No playlists in library")
            } else {
                ForEach(Array(self.playlists.prefix(12))) { playlist in
                    Button {
                        Task {
                            do {
                                _ = try await self.client.addSongToPlaylist(videoId: self.song.videoId, playlistId: playlist.id)
                                self.libraryViewModel?.markNeedsReloadOnActivation()
                            } catch {
                                DiagnosticsLogger.api.error("Failed to add song to playlist from context menu: \(error.localizedDescription)")
                            }
                        }
                    } label: {
                        Label(playlist.title, systemImage: "music.note.list")
                    }
                }
            }

            Divider()

            Button {
                Task {
                    do {
                        let created = try await self.client.createPlaylist(
                            title: self.song.title,
                            privacy: .private
                        )
                        _ = try await self.client.addSongToPlaylist(videoId: self.song.videoId, playlistId: created.id)
                        self.libraryViewModel?.addToLibrary(playlist: created)
                    } catch {
                        DiagnosticsLogger.api.error("Failed to create playlist from context menu: \(error.localizedDescription)")
                    }
                }
            } label: {
                Label("Create Playlist", systemImage: "plus.circle")
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
    }
}

// MARK: - AddToPlaylistPopoverContent

@available(macOS 26.0, *)
struct AddToPlaylistPopoverContent: View {
    let song: Song
    let client: any YTMusicClientProtocol
    let libraryViewModel: LibraryViewModel?

    @State private var entries: [AddToPlaylistEntry] = []
    @State private var loadingState = LoadingState.idle
    @State private var mutatingIds: Set<String> = []
    @State private var showCreateComposer = false
    @State private var createTitle = ""
    @State private var isCreating = false

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add to Playlist")
                    .font(.headline)

                Text(self.song.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Group {
                    switch self.loadingState {
                    case .idle, .loading:
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    case let .error(error):
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    case .loaded, .loadingMore:
                        self.entriesList
                    }
                }
                .frame(minHeight: 180)
            }
            .padding(12)
            .frame(width: 340)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        }
        .task {
            if self.createTitle.isEmpty {
                self.createTitle = self.song.title
            }
            await self.loadEntries()
        }
    }

    private var entriesList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(self.entries) { entry in
                    Button {
                        Task {
                            await self.toggleSongMembership(for: entry)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if let thumbnailURL = entry.thumbnailURL {
                                CachedAsyncImage(url: thumbnailURL) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(.quaternary)
                                }
                                .frame(width: 28, height: 28)
                                .clipShape(.rect(cornerRadius: 4))
                            } else {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 12))
                                    .frame(width: 28, height: 28)
                                    .background(.quaternary)
                                    .clipShape(.rect(cornerRadius: 4))
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let subtitle = entry.subtitle {
                                    Text(subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            Spacer(minLength: 8)

                            if self.mutatingIds.contains(entry.id) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: entry.containsVideo ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(entry.containsVideo ? .red : .secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(self.mutatingIds.contains(entry.id) || self.isCreating)
                }

                Button {
                    if self.createTitle.isEmpty {
                        self.createTitle = self.song.title
                    }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        self.showCreateComposer.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add Playlist")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Create a new playlist")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: self.showCreateComposer ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(self.isCreating)

                if self.showCreateComposer {
                    HStack(spacing: 6) {
                        TextField("Playlist title", text: self.$createTitle)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            Task { await self.createPlaylistAndAddSong() }
                        } label: {
                            if self.isCreating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Create")
                                    .fontWeight(.semibold)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(self.isCreating || self.createTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func toggleSongMembership(for entry: AddToPlaylistEntry) async {
        if Self.isLikedSongsPlaylistId(entry.id) {
            await self.toggleLikedSongsMembership(for: entry)
            return
        }

        if entry.containsVideo, entry.canRemoveVideoById {
            await self.removeSong(from: entry)
        } else {
            await self.addSong(to: entry)
        }
    }

    private static func isLikedSongsPlaylistId(_ playlistId: String) -> Bool {
        playlistId == "LM" || playlistId == "VLLM"
    }

    private func toggleLikedSongsMembership(for entry: AddToPlaylistEntry) async {
        self.mutatingIds.insert(entry.id)
        defer { self.mutatingIds.remove(entry.id) }

        do {
            let rating: LikeStatus = entry.containsVideo ? .indifferent : .like
            try await self.client.rateSong(videoId: self.song.videoId, rating: rating)
            self.updateMembership(for: entry.id, containsVideo: !entry.containsVideo)
            self.libraryViewModel?.markNeedsReloadOnActivation()
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                await self.loadEntries()
            }
        } catch {
            DiagnosticsLogger.api.error("Failed toggling Liked Songs membership: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func loadEntries() async {
        self.loadingState = .loading
        do {
            self.entries = try await self.client.getAddToPlaylistEntries(videoId: self.song.videoId)
            self.loadingState = .loaded
        } catch {
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func addSong(to entry: AddToPlaylistEntry) async {
        self.mutatingIds.insert(entry.id)
        defer { self.mutatingIds.remove(entry.id) }

        do {
            _ = try await self.client.addSongToPlaylist(videoId: self.song.videoId, playlistId: entry.id)
            self.updateMembership(for: entry.id, containsVideo: true)
            self.libraryViewModel?.markNeedsReloadOnActivation()
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                await self.loadEntries()
            }
        } catch {
            DiagnosticsLogger.api.error("Failed adding song to playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func removeSong(from entry: AddToPlaylistEntry) async {
        self.mutatingIds.insert(entry.id)
        defer { self.mutatingIds.remove(entry.id) }

        do {
            try await self.client.removeSongFromPlaylist(videoId: self.song.videoId, playlistId: entry.id, setVideoId: nil)
            self.updateMembership(for: entry.id, containsVideo: false)
            self.libraryViewModel?.markNeedsReloadOnActivation()
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                await self.loadEntries()
            }
        } catch {
            DiagnosticsLogger.api.error("Failed removing song from playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func createPlaylistAndAddSong() async {
        let trimmedTitle = self.createTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        self.isCreating = true
        defer { self.isCreating = false }

        do {
            let playlist = try await self.client.createPlaylist(title: trimmedTitle, privacy: .private)
            _ = try await self.client.addSongToPlaylist(videoId: self.song.videoId, playlistId: playlist.id)
            self.libraryViewModel?.addToLibrary(playlist: playlist)
            self.entries.insert(
                AddToPlaylistEntry(
                    id: playlist.id,
                    title: playlist.title,
                    subtitle: nil,
                    thumbnailURL: playlist.thumbnailURL,
                    canAddVideo: true,
                    canRemoveVideoById: true,
                    containsVideo: true
                ),
                at: 0
            )
            self.showCreateComposer = false
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                await self.loadEntries()
            }
        } catch {
            DiagnosticsLogger.api.error("Failed creating playlist from popover: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func updateMembership(for playlistId: String, containsVideo: Bool) {
        guard let index = self.entries.firstIndex(where: { $0.id == playlistId }) else { return }
        let current = self.entries[index]
        self.entries[index] = AddToPlaylistEntry(
            id: current.id,
            title: current.title,
            subtitle: current.subtitle,
            thumbnailURL: current.thumbnailURL,
            canAddVideo: current.canAddVideo,
            canRemoveVideoById: current.canRemoveVideoById,
            containsVideo: containsVideo
        )
    }
}
