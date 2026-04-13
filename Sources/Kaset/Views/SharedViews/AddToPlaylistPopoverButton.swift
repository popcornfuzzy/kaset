import SwiftUI

// MARK: - AddToPlaylistEntriesCache

@MainActor
private final class AddToPlaylistEntriesCache {
    static let shared = AddToPlaylistEntriesCache()

    private struct Entry {
        let videoId: String
        let entries: [AddToPlaylistEntry]
        let timestamp: Date
    }

    private var cacheByAccount: [String: Entry] = [:]

    private init() {}

    func entries(videoId: String, accountID: String, maxAge: TimeInterval) -> [AddToPlaylistEntry]? {
        guard let entry = self.cacheByAccount[accountID] else { return nil }
        guard entry.videoId == videoId else { return nil }

        if Date().timeIntervalSince(entry.timestamp) > maxAge {
            self.cacheByAccount.removeValue(forKey: accountID)
            return nil
        }

        return entry.entries
    }

    func setEntries(_ entries: [AddToPlaylistEntry], videoId: String, accountID: String) {
        self.cacheByAccount[accountID] = Entry(videoId: videoId, entries: entries, timestamp: Date())
    }
}

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
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    let song: Song
    let client: any YTMusicClientProtocol
    let libraryViewModel: LibraryViewModel?
    private let membershipProbeLimit = 8
    private let entriesCacheMaxAge: TimeInterval = 10 * 60

    @State private var entries: [AddToPlaylistEntry] = []
    @State private var loadingState = LoadingState.idle
    @State private var mutatingIds: Set<String> = []
    @State private var showCreateComposer = false
    @State private var createTitle = ""
    @State private var isCreating = false
    @State private var resolvedMembershipByPlaylistId: [String: Bool] = [:]
    @State private var probingMembershipPlaylistIds: Set<String> = []

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
        .onChange(of: self.likeStatusManager.lastLikeEvent) { _, event in
            guard let event, event.videoId == self.song.videoId else { return }
            self.updateLikedSongsMembership(containsVideo: event.status == .like)
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
                            } else if self.shouldShowMembershipLoading(for: entry) {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.8)
                            } else {
                                let containsVideo = self.containsVideo(for: entry)
                                Image(systemName: containsVideo ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(containsVideo ? .red : .secondary)
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

        if self.containsVideo(for: entry) {
            let removed = await self.removeSong(from: entry, showErrorOnFailure: false)
            if !removed {
                await self.addSong(to: entry)
            }
        } else {
            await self.addSong(to: entry)
        }
    }

    private static func isLikedSongsPlaylistId(_ playlistId: String) -> Bool {
        if playlistId == "LM" || playlistId == "VLLM" {
            return true
        }

        if playlistId.hasPrefix("VL") {
            return String(playlistId.dropFirst(2)) == "LM"
        }

        return false
    }

    private static func isAlreadyInPlaylistError(_ error: any Error) -> Bool {
        let message: String = if let ytError = error as? YTMusicError,
                                 case let .apiError(apiMessage, _) = ytError
        {
            apiMessage
        } else {
            error.localizedDescription
        }

        let lowercasedMessage = message.lowercased()
        return (lowercasedMessage.contains("already") && lowercasedMessage.contains("playlist"))
            || lowercasedMessage.contains("duplicate")
    }

    private func toggleLikedSongsMembership(for entry: AddToPlaylistEntry) async {
        self.mutatingIds.insert(entry.id)
        defer { self.mutatingIds.remove(entry.id) }

        let containsVideo = self.containsVideo(for: entry)
        let activeAccountID = self.likeStatusManager.activeAccountID
        let finalStatus: LikeStatus = if containsVideo {
            await SongLikeStatusManager.shared.unlike(
                self.song,
                accountID: activeAccountID,
                client: self.client
            )
        } else {
            await SongLikeStatusManager.shared.like(
                self.song,
                accountID: activeAccountID,
                client: self.client
            )
        }

        do {
            self.updateLikedSongsMembership(containsVideo: finalStatus == .like)
            self.libraryViewModel?.markNeedsReloadOnActivation()
        }
    }

    private func loadEntries() async {
        if let cachedEntries = AddToPlaylistEntriesCache.shared.entries(
            videoId: self.song.videoId,
            accountID: self.activeAccountID,
            maxAge: self.entriesCacheMaxAge
        ) {
            self.entries = cachedEntries
            self.seedMembershipCacheFromEntries()
            self.seedLikedSongsMembershipFromSongStatus()
            self.loadingState = .loaded

            Task {
                await self.refreshEntriesFromNetwork(showLoadingIndicator: false)
            }
            return
        }

        await self.refreshEntriesFromNetwork(showLoadingIndicator: true)
    }

    private func refreshEntriesFromNetwork(showLoadingIndicator: Bool) async {
        if showLoadingIndicator {
            self.loadingState = .loading
        }

        do {
            self.entries = try await self.client.getAddToPlaylistEntries(videoId: self.song.videoId)
            AddToPlaylistEntriesCache.shared.setEntries(
                self.entries,
                videoId: self.song.videoId,
                accountID: self.activeAccountID
            )
            self.seedMembershipCacheFromEntries()
            self.seedLikedSongsMembershipFromSongStatus()
            self.loadingState = .loaded

            Task {
                await self.resolveMembershipFromPlaylistContents()
            }
        } catch {
            if showLoadingIndicator {
                self.loadingState = .error(LoadingError(from: error))
            } else {
                DiagnosticsLogger.api.debug(
                    "Failed refreshing add-to-playlist entries in background: \(error.localizedDescription)"
                )
            }
        }
    }

    private func addSong(to entry: AddToPlaylistEntry) async {
        self.mutatingIds.insert(entry.id)
        defer { self.mutatingIds.remove(entry.id) }

        do {
            _ = try await self.client.addSongToPlaylist(videoId: self.song.videoId, playlistId: entry.id)
            PlaylistMembershipManager.shared.markOptimisticAdd(videoId: self.song.videoId, playlistId: entry.id)
            self.resolvedMembershipByPlaylistId[entry.id] = true
            self.updateMembership(for: entry.id, containsVideo: true)
            self.libraryViewModel?.markNeedsReloadOnActivation()
        } catch {
            if Self.isAlreadyInPlaylistError(error) {
                // Some API responses don't mark membership up front; duplicate-add confirms membership.
                PlaylistMembershipManager.shared.markOptimisticAdd(videoId: self.song.videoId, playlistId: entry.id)
                self.resolvedMembershipByPlaylistId[entry.id] = true
                self.updateMembership(for: entry.id, containsVideo: true)
                return
            }
            DiagnosticsLogger.api.error("Failed adding song to playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func removeSong(from entry: AddToPlaylistEntry, showErrorOnFailure: Bool = true) async -> Bool {
        self.mutatingIds.insert(entry.id)
        defer { self.mutatingIds.remove(entry.id) }

        do {
            try await self.client.removeSongFromPlaylist(videoId: self.song.videoId, playlistId: entry.id, setVideoId: nil)
            PlaylistMembershipManager.shared.markOptimisticRemove(videoId: self.song.videoId, playlistId: entry.id)
            self.resolvedMembershipByPlaylistId[entry.id] = false
            self.updateMembership(for: entry.id, containsVideo: false)
            self.libraryViewModel?.markNeedsReloadOnActivation()
            return true
        } catch {
            DiagnosticsLogger.api.error("Failed removing song from playlist: \(error.localizedDescription)")
            if showErrorOnFailure {
                self.loadingState = .error(LoadingError(from: error))
            }
            return false
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
            PlaylistMembershipManager.shared.markOptimisticAdd(videoId: self.song.videoId, playlistId: playlist.id)
            self.resolvedMembershipByPlaylistId[playlist.id] = true
            self.showCreateComposer = false
            self.persistEntriesCache()
        } catch {
            DiagnosticsLogger.api.error("Failed creating playlist from popover: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func containsVideo(for entry: AddToPlaylistEntry) -> Bool {
        if Self.isLikedSongsPlaylistId(entry.id),
           let likedSongsMembership = self.currentLikedSongsMembershipFromSongStatus()
        {
            return likedSongsMembership
        }

        if !Self.isLikedSongsPlaylistId(entry.id),
           let cachedMembership = PlaylistMembershipManager.shared.isMember(videoId: self.song.videoId, in: entry.id)
        {
            return cachedMembership
        }

        if let resolvedMembership = self.resolvedMembershipByPlaylistId[entry.id] {
            return resolvedMembership
        }

        return entry.containsVideo
    }

    private func seedMembershipCacheFromEntries() {
        for entry in self.entries where !Self.isLikedSongsPlaylistId(entry.id) {
            if entry.containsVideo {
                PlaylistMembershipManager.shared.setMembership(
                    true,
                    videoId: self.song.videoId,
                    playlistId: entry.id,
                    confidence: .apiDeclared
                )
            }
        }
    }

    private func currentLikedSongsMembershipFromSongStatus() -> Bool? {
        if let cachedStatus = self.likeStatusManager.status(for: self.song.videoId) {
            return cachedStatus == .like
        }

        if let songLikeStatus = self.song.likeStatus, songLikeStatus != .indifferent {
            return songLikeStatus == .like
        }

        return nil
    }

    private func currentLikedSongsStatus() -> LikeStatus? {
        if let cachedStatus = self.likeStatusManager.status(for: self.song.videoId) {
            if cachedStatus != .indifferent {
                return cachedStatus
            }
        }

        if let songLikeStatus = self.song.likeStatus, songLikeStatus != .indifferent {
            return songLikeStatus
        }

        return nil
    }

    private func seedLikedSongsMembershipFromSongStatus() {
        guard let containsVideo = self.currentLikedSongsMembershipFromSongStatus() else { return }

        for entry in self.entries where Self.isLikedSongsPlaylistId(entry.id) {
            self.resolvedMembershipByPlaylistId[entry.id] = containsVideo
            self.updateMembership(for: entry.id, containsVideo: containsVideo)
        }
    }

    private func updateLikedSongsMembership(containsVideo: Bool) {
        for entry in self.entries where Self.isLikedSongsPlaylistId(entry.id) {
            self.resolvedMembershipByPlaylistId[entry.id] = containsVideo
            self.updateMembership(for: entry.id, containsVideo: containsVideo)
        }
    }

    private func resolveMembershipFromPlaylistContents() async {
        let candidates = Array(self.entries
            .filter { !Self.isLikedSongsPlaylistId($0.id) }
            .filter { self.resolvedMembershipByPlaylistId[$0.id] == nil }
            .filter { PlaylistMembershipManager.shared.isMember(videoId: self.song.videoId, in: $0.id) == nil }
            .prefix(self.membershipProbeLimit))

        guard !candidates.isEmpty else { return }

        let probeCandidates = candidates.filter { !self.mutatingIds.contains($0.id) }
        guard !probeCandidates.isEmpty else { return }

        let probingIDs = Set(probeCandidates.map(\.id))
        self.probingMembershipPlaylistIds.formUnion(probingIDs)
        defer { self.probingMembershipPlaylistIds.subtract(probingIDs) }

        let results = await withTaskGroup(of: (String, Bool?, String?).self, returning: [(String, Bool?, String?)].self) {
            group in
            for entry in probeCandidates {
                group.addTask {
                    do {
                        let tracks = try await self.client.getPlaylistAllTracks(playlistId: entry.id)
                        let containsVideo = tracks.contains { $0.videoId == self.song.videoId }
                        return (entry.id, containsVideo, nil)
                    } catch {
                        return (entry.id, nil, error.localizedDescription)
                    }
                }
            }

            var collected: [(String, Bool?, String?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for result in results {
            if let containsVideo = result.1 {
                PlaylistMembershipManager.shared.markProbeResult(
                    videoId: self.song.videoId,
                    playlistId: result.0,
                    isMember: containsVideo
                )
                self.resolvedMembershipByPlaylistId[result.0] = containsVideo
                self.updateMembership(for: result.0, containsVideo: containsVideo)
            } else if let message = result.2 {
                DiagnosticsLogger.api.debug(
                    "Membership probe failed for playlist \(result.0): \(message)"
                )
            }
        }
    }

    private func shouldShowMembershipLoading(for entry: AddToPlaylistEntry) -> Bool {
        if Self.isLikedSongsPlaylistId(entry.id) {
            return false
        }

        return self.probingMembershipPlaylistIds.contains(entry.id)
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
        self.persistEntriesCache()
    }

    private var activeAccountID: String {
        PlaylistMembershipManager.shared.activeAccountID
    }

    private func persistEntriesCache() {
        AddToPlaylistEntriesCache.shared.setEntries(
            self.entries,
            videoId: self.song.videoId,
            accountID: self.activeAccountID
        )
    }
}
