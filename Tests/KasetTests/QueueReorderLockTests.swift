import Foundation
import Testing
@testable import Kaset

/// The queue's reorder lock.
///
/// The row that is playing may not be reordered: it can be neither the row dragged nor a row that moves
/// as a result of someone else's drag. That second half is what this rule states, and it is why a drag
/// across the playing row does nothing — the highlight, the list's auto-scroll and the WebView's own
/// alignment all read that row's index, so a reorder that changes it makes the whole queue jump.
///
/// One rule, used by the model (`PlayerService.reorderQueue(from:to:)`) and by the row table's own drop
/// feedback, so the table can never offer a drop the model will refuse.
@Suite("Queue reorder lock")
@MainActor
struct QueueReorderLockTests {
    @Test(
        "A move that would shift the playing row is refused",
        arguments: [
            // source, destination, currentIndex, expected — current is the row at `currentIndex`.
            (0, 3, 1, true),    // from above the playing row to below it
            (3, 0, 1, true),    // from below it to above it
            (0, 2, 1, true),    // from above it to just below it
            (2, 3, 1, false),   // both below it: it stays where it is
            (3, 2, 1, false),   // both below it, moved up one
            (3, 0, 2, true),    // a long drag from the end to the top crosses it
            (0, 1, 2, false),   // both above it: it stays where it is
            (0, 1, 0, false),   // the playing row is not moved by its own index
            (2, 0, -1, false),  // no highlighted row (YouTube autoplay) locks nothing
        ]
    )
    func ruleTable(source: Int, destination: Int, currentIndex: Int, expected: Bool) {
        #expect(
            PlayerService.reorderMovesPlayingRow(
                from: source, to: destination, currentIndex: currentIndex
            ) == expected
        )
    }

    @Test("Dropping directly above the playing row is refused — it would push the row down")
    func dropDirectlyAboveThePlayingRow() {
        // `move(fromOffsets:toOffset:)` inserts *before* the destination, so dropping above the playing
        // row moves it from index 1 to 0. The table's own drop feedback asks this question, which is why
        // it is stated here and not only as `destination != currentIndex` at the call sites.
        #expect(PlayerService.reorderMovesPlayingRow(from: 0, to: 1, currentIndex: 1))
    }

    @Test("A reorder within one side of the playing row keeps it where it is")
    func reorderWithinOneSide() async {
        let service = PlayerService()
        let songs = TestFixtures.makeSongs(count: 4)
        await service.playQueue(songs, startingAt: 2)

        // [video-0, video-1, video-2*, video-3] — the two rows above the playing row swap, which is a
        // move that stays on its own side of it (`move(fromOffsets:toOffset:)` inserts before `toOffset`).
        service.reorderQueue(from: IndexSet(integer: 1), to: 0)

        // The playing row is still index 2 and still the same song.
        #expect(service.queue.map(\.videoId) == ["video-1", "video-0", "video-2", "video-3"])
        #expect(service.currentIndex == 2)
        #expect(service.currentTrack?.videoId == "video-2")
    }

    @Test("A reorder across the playing row is refused and changes nothing")
    func reorderAcrossThePlayingRow() async {
        let service = PlayerService()
        let songs = TestFixtures.makeSongs(count: 4)
        await service.playQueue(songs, startingAt: 1)

        // [video-0, video-1*, video-2, video-3] — dragging video-0 past the playing row would move it.
        service.reorderQueue(from: IndexSet(integer: 0), to: 3)

        #expect(service.queue.map(\.videoId) == ["video-0", "video-1", "video-2", "video-3"])
        #expect(service.currentIndex == 1)
    }
}
