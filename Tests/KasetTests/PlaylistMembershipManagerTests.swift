import Testing
@testable import Kaset

@MainActor
struct PlaylistMembershipManagerTests {
    @Test("Stores and reads membership in active account")
    func storesAndReadsMembership() {
        let manager = PlaylistMembershipManager.shared
        manager.clearCache()
        manager.setActiveAccountID(nil)

        manager.setMembership(
            true,
            videoId: "video-1",
            playlistId: "playlist-1",
            confidence: .apiDeclared
        )

        #expect(manager.isMember(videoId: "video-1", in: "playlist-1") == true)
        #expect(manager.confidence(videoId: "video-1", in: "playlist-1") == .apiDeclared)
    }

    @Test("Membership cache is isolated per account")
    func accountIsolation() {
        let manager = PlaylistMembershipManager.shared
        manager.clearCache()

        manager.setActiveAccountID("account-a")
        manager.setMembership(
            true,
            videoId: "video-1",
            playlistId: "playlist-1",
            confidence: .optimisticWrite
        )

        manager.setActiveAccountID("account-b")
        #expect(manager.isMember(videoId: "video-1", in: "playlist-1") == nil)

        manager.setMembership(
            false,
            videoId: "video-1",
            playlistId: "playlist-1",
            confidence: .probeConfirmed
        )

        #expect(manager.isMember(videoId: "video-1", in: "playlist-1") == false)

        manager.setActiveAccountID("account-a")
        #expect(manager.isMember(videoId: "video-1", in: "playlist-1") == true)
    }

    @Test("Expired entry is evicted on read")
    func expiredEntryEviction() {
        let manager = PlaylistMembershipManager.shared
        manager.clearCache()
        manager.setActiveAccountID(nil)

        manager.setMembership(
            true,
            videoId: "video-2",
            playlistId: "playlist-2",
            confidence: .apiDeclared,
            ttl: 0
        )

        #expect(manager.isMember(videoId: "video-2", in: "playlist-2") == nil)
        #expect(manager.confidence(videoId: "video-2", in: "playlist-2") == nil)
    }

    @Test("Optimistic helper methods update membership")
    func optimisticHelpers() {
        let manager = PlaylistMembershipManager.shared
        manager.clearCache()
        manager.setActiveAccountID(nil)

        manager.markOptimisticAdd(videoId: "video-3", playlistId: "playlist-3")
        #expect(manager.isMember(videoId: "video-3", in: "playlist-3") == true)
        #expect(manager.confidence(videoId: "video-3", in: "playlist-3") == .optimisticWrite)

        manager.markOptimisticRemove(videoId: "video-3", playlistId: "playlist-3")
        #expect(manager.isMember(videoId: "video-3", in: "playlist-3") == false)
        #expect(manager.confidence(videoId: "video-3", in: "playlist-3") == .optimisticWrite)
    }

    @Test("Probe result helper sets probe confidence")
    func probeResultHelper() {
        let manager = PlaylistMembershipManager.shared
        manager.clearCache()
        manager.setActiveAccountID(nil)

        manager.markProbeResult(videoId: "video-4", playlistId: "playlist-4", isMember: true)

        #expect(manager.isMember(videoId: "video-4", in: "playlist-4") == true)
        #expect(manager.confidence(videoId: "video-4", in: "playlist-4") == .probeConfirmed)
    }
}
