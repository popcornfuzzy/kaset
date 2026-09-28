import Testing
@testable import Kaset

/// Measuring a lyric line is the expensive part of drawing it — a CoreText pass per
/// character — and a row's body is re-evaluated whenever the sheet re-renders, which is on
/// every playback sample. So the measurement has to happen once per line and the frames
/// have to be arithmetic only.
///
/// A row now draws **two** lines, its lead and its backing vocal, at **two** font sizes. The
/// cache was keyed by the line alone, so alternating the two lookups evicted one another on
/// every frame: every frame re-measured one of the two, which is exactly the per-frame text
/// measurement the cache exists to keep off the clock. Keying by line *and* size is the fix,
/// and these hold it in place.
@MainActor
@Suite(.tags(.model))
struct KaraokeLayoutCacheTests {
    private static func line(background: Bool) -> SyncedLyricLine {
        let words = ["alpha", " bravo", " charlie"].enumerated().map { index, text in
            TimedWord(timeInMs: index * 400, word: text)
        }
        let backgroundWords: [TimedWord]? = background ? [
            TimedWord(timeInMs: 100, word: "ooh", isBackground: true),
            TimedWord(timeInMs: 700, word: " ah", isBackground: true),
        ] : nil
        return SyncedLyricLine(
            timeInMs: 0,
            duration: 2_000,
            text: "alpha bravo charlie",
            words: words,
            backgroundWords: backgroundWords
        )
    }

    @Test("A row that re-renders measures its line once")
    func repeatedLookupsMeasureOnce() {
        let cache = KaraokeLayoutCache()
        let line = Self.line(background: false)

        for _ in 0 ..< 200 {
            _ = cache.layout(for: line, fontSize: 16)
        }

        #expect(cache.measurementCount == 1)
    }

    @Test("A row's lead and backing vocal are measured at their own sizes without evicting each other")
    func leadAndBackgroundCoexist() {
        let cache = KaraokeLayoutCache()
        let line = Self.line(background: true)

        for _ in 0 ..< 200 {
            _ = cache.layout(for: line, fontSize: 16)
            _ = cache.backgroundLayout(for: line, fontSize: 14)
        }

        // One measurement each — not one per frame. A cache keyed by the line alone gives
        // 400 here.
        #expect(cache.measurementCount == 2)
        // And the two really are at the two sizes, so the lookup is not returning the same
        // layout for both.
        #expect(cache.layout(for: line, fontSize: 16).fontSize == 16)
        #expect(cache.backgroundLayout(for: line, fontSize: 14)?.fontSize == 14)
    }

    @Test("The backing vocal is measured from the backing words, not the lead line")
    func backingLayoutUsesBackingWords() throws {
        let cache = KaraokeLayoutCache()
        let line = Self.line(background: true)

        let backing = try #require(cache.backgroundLayout(for: line, fontSize: 14))

        #expect(backing.words.map(\.text) == ["ooh", "ah"])
        #expect(backing.words.allSatisfy { $0.fillStartMs < 1_000 })
        // The lead's layout is untouched by it.
        #expect(cache.layout(for: line, fontSize: 14).words.map(\.text) == ["alpha", "bravo", "charlie"])
        #expect(cache.measurementCount == 2)
    }

    @Test("The lead line and the backing vocal stay separate entries even at one size")
    func sameSizeDoesNotCollide() throws {
        let cache = KaraokeLayoutCache()
        let line = Self.line(background: true)

        let lead = cache.layout(for: line, fontSize: 14)
        let backing = try #require(cache.backgroundLayout(for: line, fontSize: 14))

        // The two are different text, so a size that happens to be shared must not let one
        // be drawn with the other's words.
        #expect(lead.words.map(\.text) == ["alpha", "bravo", "charlie"])
        #expect(backing.words.map(\.text) == ["ooh", "ah"])
        #expect(cache.measurementCount == 2)
    }

    @Test("A line with no backing vocal has no backing layout, and measuring it costs nothing")
    func noBackingLayoutWithoutBackingWords() {
        let cache = KaraokeLayoutCache()
        let line = Self.line(background: false)

        #expect(cache.backgroundLayout(for: line, fontSize: 14) == nil)
        #expect(cache.measurementCount == 0)
    }
}
