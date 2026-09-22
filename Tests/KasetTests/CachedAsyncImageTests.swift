import Foundation
import SwiftUI
import Testing
@testable import Kaset

/// Regression coverage for the now-playing artwork display rule behind `CachedAsyncImage`.
///
/// YouTube serves the same artwork from many URLs (size and `sqp` signature tokens rotate, and the
/// WebView rewrites the player bar's `<img>` while it upgrades resolution), so a URL change is not a
/// content change. The view may only drop the image it is showing when the *identity* of the artwork
/// changes — and it has to record the identity it is loading for before the download starts, because
/// a re-reported URL can arrive while that download is still in flight.
@Suite(.serialized, .tags(.service))
@MainActor
struct CachedAsyncImageTests {
    @Test("Displayed artwork is kept when the identity is unchanged")
    func keepsArtworkForSameIdentity() {
        #expect(ArtworkDisplayRule.shouldClearDisplayedImage(identity: "video-1", displayedIdentity: "video-1") == false)
    }

    @Test("Displayed artwork is cleared when a different track starts")
    func clearsArtworkForNewIdentity() {
        #expect(ArtworkDisplayRule.shouldClearDisplayedImage(identity: "video-2", displayedIdentity: "video-1"))
        #expect(ArtworkDisplayRule.shouldClearDisplayedImage(identity: "video-1", displayedIdentity: nil))
    }

    @Test("Views without an identity still treat every URL change as new artwork")
    func clearsArtworkWithoutIdentity() {
        // Collection rows are recycled by SwiftUI for other items, so a stale image would be wrong.
        #expect(ArtworkDisplayRule.shouldClearDisplayedImage(identity: nil, displayedIdentity: nil))
        #expect(ArtworkDisplayRule.shouldClearDisplayedImage(identity: nil, displayedIdentity: "video-1"))
    }

    @Test("A cached image is only painted on the first frame when it is sharp enough")
    func seedsFirstFrameOnlyWithSharpEnoughArtwork() {
        let target = CGSize(width: 320, height: 320)

        // A fullsize artwork load (or another view with the same target) is fine to show immediately.
        #expect(ArtworkDisplayRule.canSeedDisplayedImage(imageSize: CGSize(width: 640, height: 640), targetSize: target))
        #expect(ArtworkDisplayRule.canSeedDisplayedImage(imageSize: target, targetSize: target))

        // A thumbnail a 40pt row downsampled must not be blown up into a large artwork slot.
        #expect(ArtworkDisplayRule.canSeedDisplayedImage(imageSize: CGSize(width: 96, height: 96), targetSize: target) == false)
        // Views without a downsampling target accept anything cached.
        #expect(ArtworkDisplayRule.canSeedDisplayedImage(imageSize: CGSize(width: 96, height: 96), targetSize: .zero))
    }

    @Test("A failed artwork load keeps retrying while the view is on screen")
    func failedArtworkKeepsRetryingWhileVisible() {
        // The quick attempts absorb a momentary hiccup. The recovery cadence after them covers the
        // situations that actually lose artwork and that do resolve themselves — a busy network while
        // the WebView is still opening, a re-signed URL, a rate-limited 403 — because nothing later
        // re-runs the load while the artwork URL itself is unchanged. A view that gave up after three
        // attempts therefore kept its placeholder for the rest of the song.
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: 0) == .milliseconds(300))
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: 1) == .seconds(1))
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: 2) == .seconds(3))
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: 3) == .seconds(5))
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: 4) == .seconds(10))
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: 5) == .seconds(20))
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: 6) == .seconds(40))
        // The cadence bottoms out at a minute, so keeping a long-lived view retrying stays cheap.
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: 7) == .seconds(60))
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: 500) == .seconds(60))
        // A defensive index below the first retry uses the first delay rather than trapping.
        #expect(CachedAsyncImage<EmptyView, EmptyView>.retryDelay(afterRetry: -1) == .milliseconds(300))
    }

    @Test("Claiming the identity before the download protects artwork that is still loading")
    func claimBeforeDownloadPreventsMidLoadClear() {
        // The sequence for one song: display video-1, then start loading a re-reported URL for the
        // *same* video. The view must claim "video-1" before awaiting, otherwise this second update
        // compares against the old identity, wipes the artwork mid-download, and stays blank whenever
        // the replacement request fails.
        var artworkIdentity = "video-1"
        #expect(ArtworkDisplayRule.shouldClearDisplayedImage(identity: "video-1", displayedIdentity: artworkIdentity) == false)

        // A genuine new track still clears, and the view claims the new identity immediately.
        #expect(ArtworkDisplayRule.shouldClearDisplayedImage(identity: "video-2", displayedIdentity: artworkIdentity))
        artworkIdentity = "video-2"
        #expect(ArtworkDisplayRule.shouldClearDisplayedImage(identity: "video-2", displayedIdentity: artworkIdentity) == false)
    }
}
