import Foundation
import Testing

/// Bounded, deterministic rendezvous for tests that have to interleave async work.
///
/// A coalescing burst is defined by *when* the next intent arrives: it must land
/// while the previous intent is still waiting out its debounce, or while its
/// request is in flight. Those tests used to create that interleaving with
/// `Task.sleep(for: .milliseconds(10))`, which assumes the machine starts the
/// first task within 10 ms. On a loaded CI runner the assumption breaks — the
/// first intent reaches the network before the second one registers, the burst is
/// no longer coalesced, and the test fails on a machine where it passes locally.
///
/// Wait for an event the code under test emits instead (the optimistic cache
/// write, or the request arriving at the mock client). The rendezvous then
/// depends on ordering rather than on the machine being fast.
///
/// - Parameters:
///   - description: What is being waited for, used in the failure message.
///   - timeout: How long to keep polling before recording an issue.
///   - condition: The event being waited for. Polled on the main actor, so it can
///     read state the code under test mutates there.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    if condition() { return }

    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        // Yield (and give the code under test a chance to run) before re-checking.
        try? await Task.sleep(for: .milliseconds(2))
        if condition() { return }
    }

    Issue.record(
        "timed out after \(timeout) waiting for \(description)",
        sourceLocation: sourceLocation
    )
}
