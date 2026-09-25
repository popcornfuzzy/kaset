import Foundation

// MARK: - QueueTunerChip

/// A server-provided option that re-tunes the current automix queue.
///
/// YouTube Music ships its own tuning row inside the `next` response, under
/// `musicQueueRenderer.subHeaderChipCloud`. Each chip carries the mix playlist and opaque params
/// that select that variant, so the app renders exactly the options the server offers
/// ("All", "Discover", "Deep cuts", "Party", genre chips, …) instead of hard-coding them.
struct QueueTunerChip: Identifiable, Hashable, Sendable {
    /// Server identifier for the tuning, e.g. `Discover`.
    let id: String

    /// Label the server sent for the chip.
    let label: String

    /// Whether the server marked this chip as the queue's active tuning.
    let isSelected: Bool

    /// Playlist ID of the tuned mix this chip fetches.
    let playlistId: String

    /// Opaque server params that select the tuning variant.
    let params: String?

    /// Returns a copy of the chip with a different selection state.
    func selecting(_ isSelected: Bool) -> QueueTunerChip {
        QueueTunerChip(
            id: self.id,
            label: self.label,
            isSelected: isSelected,
            playlistId: self.playlistId,
            params: self.params
        )
    }
}
