import Foundation

// MARK: - PlaylistMembershipConfidence

/// Confidence level for playlist membership state.
enum PlaylistMembershipConfidence: String {
    /// Derived from add-to-playlist API payload (may be missing/unreliable).
    case apiDeclared

    /// Derived from successful local mutation flow (add/remove).
    case optimisticWrite

    /// Derived from probing full playlist contents.
    case probeConfirmed
}

// MARK: - PlaylistMembershipEntry

/// Cached membership information for one (videoId, playlistId) pair.
struct PlaylistMembershipEntry {
    let isMember: Bool
    let confidence: PlaylistMembershipConfidence
    let timestamp: Date
    let ttl: TimeInterval

    var isExpired: Bool {
        Date().timeIntervalSince(self.timestamp) > self.ttl
    }
}

// MARK: - PlaylistMembershipManager

/// Central cache for song membership across playlists.
///
/// Cache is account-scoped and optimized for fast UI lookups in add-to-playlist surfaces.
@MainActor
@Observable
final class PlaylistMembershipManager {
    static let shared = PlaylistMembershipManager()

    enum TTL {
        static let apiDeclared: TimeInterval = 5 * 60
        static let optimisticWrite: TimeInterval = 60 * 60
        static let probeConfirmed: TimeInterval = 30 * 60
    }

    private static let primaryAccountID = "primary"

    /// accountId -> videoId -> playlistId -> entry
    private var cacheByAccount: [String: [String: [String: PlaylistMembershipEntry]]] = [:]

    /// Active account scope for reads/writes.
    private(set) var activeAccountID = PlaylistMembershipManager.primaryAccountID

    private init() {}

    // MARK: - Account Scope

    func setActiveAccountID(_ accountID: String?) {
        self.activeAccountID = Self.resolvedAccountID(accountID)
    }

    func clearCache() {
        self.cacheByAccount.removeAll()
    }

    // MARK: - Queries

    func isMember(videoId: String, in playlistId: String) -> Bool? {
        self.entry(videoId: videoId, playlistId: playlistId, accountID: self.activeAccountID)?.isMember
    }

    func confidence(videoId: String, in playlistId: String) -> PlaylistMembershipConfidence? {
        self.entry(videoId: videoId, playlistId: playlistId, accountID: self.activeAccountID)?.confidence
    }

    // MARK: - Mutations

    func setMembership(
        _ isMember: Bool,
        videoId: String,
        playlistId: String,
        confidence: PlaylistMembershipConfidence,
        ttl: TimeInterval? = nil,
        accountID: String? = nil
    ) {
        let resolvedAccountID = accountID.map(Self.resolvedAccountID) ?? self.activeAccountID
        let resolvedTTL = ttl ?? Self.defaultTTL(for: confidence)
        let entry = PlaylistMembershipEntry(
            isMember: isMember,
            confidence: confidence,
            timestamp: Date(),
            ttl: resolvedTTL
        )

        var videoMap = self.cacheByAccount[resolvedAccountID] ?? [:]
        var playlistMap = videoMap[videoId] ?? [:]
        playlistMap[playlistId] = entry
        videoMap[videoId] = playlistMap
        self.cacheByAccount[resolvedAccountID] = videoMap
    }

    func removeMembership(videoId: String, playlistId: String, accountID: String? = nil) {
        let resolvedAccountID = accountID.map(Self.resolvedAccountID) ?? self.activeAccountID

        guard var videoMap = self.cacheByAccount[resolvedAccountID],
              var playlistMap = videoMap[videoId]
        else {
            return
        }

        playlistMap.removeValue(forKey: playlistId)

        if playlistMap.isEmpty {
            videoMap.removeValue(forKey: videoId)
        } else {
            videoMap[videoId] = playlistMap
        }

        if videoMap.isEmpty {
            self.cacheByAccount.removeValue(forKey: resolvedAccountID)
        } else {
            self.cacheByAccount[resolvedAccountID] = videoMap
        }
    }

    func markOptimisticAdd(videoId: String, playlistId: String) {
        self.setMembership(
            true,
            videoId: videoId,
            playlistId: playlistId,
            confidence: .optimisticWrite
        )
    }

    func markOptimisticRemove(videoId: String, playlistId: String) {
        self.setMembership(
            false,
            videoId: videoId,
            playlistId: playlistId,
            confidence: .optimisticWrite
        )
    }

    func markProbeResult(videoId: String, playlistId: String, isMember: Bool) {
        self.setMembership(
            isMember,
            videoId: videoId,
            playlistId: playlistId,
            confidence: .probeConfirmed
        )
    }

    // MARK: - Helpers

    private func entry(videoId: String, playlistId: String, accountID: String) -> PlaylistMembershipEntry? {
        guard let videoMap = self.cacheByAccount[accountID],
              let playlistMap = videoMap[videoId],
              let entry = playlistMap[playlistId]
        else {
            return nil
        }

        if entry.isExpired {
            self.removeMembership(videoId: videoId, playlistId: playlistId, accountID: accountID)
            return nil
        }

        return entry
    }

    private static func defaultTTL(for confidence: PlaylistMembershipConfidence) -> TimeInterval {
        switch confidence {
        case .apiDeclared:
            TTL.apiDeclared
        case .optimisticWrite:
            TTL.optimisticWrite
        case .probeConfirmed:
            TTL.probeConfirmed
        }
    }

    private static func resolvedAccountID(_ accountID: String?) -> String {
        accountID ?? self.primaryAccountID
    }
}
