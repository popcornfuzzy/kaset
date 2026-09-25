import Foundation
import Testing
@testable import Kaset

/// Tests for the automix tuning row (`QueueTunerChip`) and re-tuning the queue.
@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceQueueTunerTests {
    var playerService: PlayerService
    var mockClient: MockYTMusicClient

    init() {
        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.setYTMusicClient(self.mockClient)
        // Enable hasUserInteractedThisSession to avoid the mini player popup.
        self.playerService.confirmPlaybackStarted()
    }

    // MARK: - Fixtures

    private static func makeChips() -> [QueueTunerChip] {
        [
            QueueTunerChip(
                id: "All",
                label: "All",
                isSelected: true,
                playlistId: "RDAMVMseed",
                params: "params-all"
            ),
            QueueTunerChip(
                id: "Discover",
                label: "Discover",
                isSelected: false,
                playlistId: "RDATdiscover",
                params: "params-discover"
            ),
        ]
    }

    // MARK: - Populating the row

    @Test("playWithMix exposes the server's tuning row")
    func playWithMixExposesTunerChips() async {
        self.mockClient.mixQueueResult = RadioQueueResult(
            songs: TestFixtures.makeSongs(count: 3),
            continuationToken: "mix-token",
            tunerChips: Self.makeChips()
        )

        await self.playerService.playWithMix(playlistId: "RDEMmix", startVideoId: nil)

        #expect(self.playerService.queueTunerChips.count == 2)
        #expect(self.playerService.activeQueueTunerId == "All")
    }

    @Test("playWithRadio exposes the server's tuning row")
    func playWithRadioExposesTunerChips() async {
        let seed = TestFixtures.makeSong(id: "radio-seed", title: "Seed Song")
        self.mockClient.radioQueueSongs["radio-seed"] = [
            seed,
            TestFixtures.makeSong(id: "radio-next", title: "Next Song"),
        ]
        self.mockClient.radioQueueTunerChips = Self.makeChips()

        await self.playerService.playWithRadio(song: seed)

        #expect(self.playerService.queueTunerChips.count == 2)
        #expect(self.playerService.activeQueueTunerId == "All")
    }

    @Test("playQueue clears a stale tuning row")
    func playQueueClearsTunerChips() async {
        self.playerService.setQueueTunerChips(Self.makeChips())
        #expect(!self.playerService.queueTunerChips.isEmpty)

        await self.playerService.playQueue(TestFixtures.makeSongs(count: 2), startingAt: 0)

        #expect(self.playerService.queueTunerChips.isEmpty)
        #expect(self.playerService.activeQueueTunerId == nil)
    }

    @Test("clearQueue clears the tuning row")
    func clearQueueClearsTunerChips() async {
        await self.playerService.playQueue(TestFixtures.makeSongs(count: 3), startingAt: 0)
        self.playerService.setQueueTunerChips(Self.makeChips())

        self.playerService.clearQueue()

        #expect(self.playerService.queueTunerChips.isEmpty)
    }

    // MARK: - Applying a chip

    @Test("Applying a chip replaces upcoming songs and keeps the current track playing")
    func applyChipReplacesUpcomingSongs() async {
        let songs = [
            TestFixtures.makeSong(id: "video-a", title: "A"),
            TestFixtures.makeSong(id: "video-b", title: "B"),
            TestFixtures.makeSong(id: "video-c", title: "C"),
        ]
        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.setQueueTunerChips(Self.makeChips())

        self.mockClient.tunedMixQueueResults["RDATdiscover"] = RadioQueueResult(
            songs: [
                TestFixtures.makeSong(id: "video-b", title: "B"),
                TestFixtures.makeSong(id: "video-d", title: "D"),
                TestFixtures.makeSong(id: "video-e", title: "E"),
            ],
            continuationToken: "tuned-token"
        )

        await self.playerService.applyQueueTunerChip(Self.makeChips()[1])

        #expect(self.mockClient.getTunedMixQueueCalled == true)
        #expect(self.mockClient.getTunedMixQueuePlaylistIds == ["RDATdiscover"])
        #expect(self.mockClient.getTunedMixQueueParams == ["params-discover"])
        #expect(self.mockClient.getTunedMixQueueVideoIds == ["video-b"])
        #expect(self.playerService.queue.map(\.videoId) == ["video-b", "video-d", "video-e"])
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentTrack?.videoId == "video-b")
        #expect(self.playerService.mixContinuationToken == "tuned-token")
    }

    @Test("Applying a chip keeps the current track at the front when the tuned mix omits it")
    func applyChipPrependsCurrentTrack() async {
        let songs = [
            TestFixtures.makeSong(id: "video-a", title: "A"),
            TestFixtures.makeSong(id: "video-b", title: "B"),
        ]
        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.setQueueTunerChips(Self.makeChips())

        self.mockClient.tunedMixQueueResults["RDATdiscover"] = RadioQueueResult(
            songs: [TestFixtures.makeSong(id: "video-d", title: "D")],
            continuationToken: nil
        )

        await self.playerService.applyQueueTunerChip(Self.makeChips()[1])

        #expect(self.playerService.queue.map(\.videoId) == ["video-b", "video-d"])
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Tuned songs are de-duplicated by video ID")
    func applyChipDeduplicatesSongs() async {
        await self.playerService.playQueue([TestFixtures.makeSong(id: "video-a")], startingAt: 0)
        self.playerService.setQueueTunerChips(Self.makeChips())

        self.mockClient.tunedMixQueueResults["RDATdiscover"] = RadioQueueResult(
            songs: [
                TestFixtures.makeSong(id: "video-d", title: "D"),
                TestFixtures.makeSong(id: "video-d", title: "D again"),
                TestFixtures.makeSong(id: "video-a", title: "A"),
            ],
            continuationToken: nil
        )

        await self.playerService.applyQueueTunerChip(Self.makeChips()[1])

        #expect(self.playerService.queue.map(\.videoId) == ["video-a", "video-d"])
    }

    @Test("Selection moves to the tapped chip when the response omits the tuning row")
    func applyChipMovesSelection() async {
        await self.playerService.playQueue([TestFixtures.makeSong(id: "video-a")], startingAt: 0)
        self.playerService.setQueueTunerChips(Self.makeChips())
        self.mockClient.tunedMixQueueResults["RDATdiscover"] = RadioQueueResult(
            songs: [TestFixtures.makeSong(id: "video-d")],
            continuationToken: nil
        )

        await self.playerService.applyQueueTunerChip(Self.makeChips()[1])

        #expect(self.playerService.queueTunerChips.count == 2)
        #expect(self.playerService.activeQueueTunerId == "Discover")
        #expect(self.playerService.queueTunerChips.first(where: { $0.id == "Discover" })?.isSelected == true)
        #expect(self.playerService.queueTunerChips.first(where: { $0.id == "All" })?.isSelected == false)
    }

    @Test("Selecting the already active chip does nothing")
    func applySelectedChipIsIgnored() async {
        await self.playerService.playQueue(TestFixtures.makeSongs(count: 2), startingAt: 0)
        self.playerService.setQueueTunerChips(Self.makeChips())

        await self.playerService.applyQueueTunerChip(Self.makeChips()[0])

        #expect(self.mockClient.getTunedMixQueueCalled == false)
    }

    @Test("An empty tuned mix keeps the current queue and selection")
    func applyChipKeepsQueueWhenTunedMixIsEmpty() async {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.setQueueTunerChips(Self.makeChips())
        self.mockClient.tunedMixQueueResults["RDATdiscover"] = RadioQueueResult(songs: [], continuationToken: nil)

        await self.playerService.applyQueueTunerChip(Self.makeChips()[1])

        #expect(self.playerService.queue.map(\.videoId) == songs.map(\.videoId))
        #expect(self.playerService.activeQueueTunerId == "All")
        #expect(self.playerService.isApplyingQueueTuner == false)
    }

    @Test("A failed tuning request keeps the current queue and restores the selection")
    func applyChipKeepsQueueOnFailure() async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.setQueueTunerChips(Self.makeChips())
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.playerService.applyQueueTunerChip(Self.makeChips()[1])

        #expect(self.playerService.queue.map(\.videoId) == songs.map(\.videoId))
        // The tap moved the selection immediately, so a failure has to move it back.
        #expect(self.playerService.activeQueueTunerId == "All")
        #expect(self.playerService.queueTunerChips.first(where: { $0.id == "All" })?.isSelected == true)
        #expect(self.playerService.isApplyingQueueTuner == false)
    }

    @Test("Tuning works without a client and without a current track")
    func applyChipWithoutClientDoesNothing() async {
        let service = PlayerService()
        let chip = Self.makeChips()[1]

        await service.applyQueueTunerChip(chip)

        #expect(service.queue.isEmpty)
        #expect(service.activeQueueTunerId == nil)
    }
}
