import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Kaset

// MARK: - SingerTurnsTests

/// Two singers in one sheet.
///
/// Apple Music attributes each TTML paragraph to an **agent** and declares those agents in the
/// document's metadata, which is how a duet alternates between two of them; Paxsenix says the
/// same thing with an `oppositeTurn` flag on a content line and a `{v2}` voice marker in its
/// ELRC. A line the source gives to a singer other than the one the document leads with is
/// drawn against the other edge of the sheet.
@MainActor
@Suite(.tags(.model))
struct SingerTurnsTests {
    // MARK: - Apple Music TTML

    /// Apple's own beat-by-beat example for *Dancing With A Stranger*, trimmed to one
    /// paragraph per agent: Sam Smith (`v1`), Normani (`v2`), and `v3` declared as a group —
    /// the two of them singing together.
    private static let duetTTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" \
    xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions" \
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en-US">
      <head>
        <metadata>
          <ttm:title>Dancing With A Stranger</ttm:title>
          <ttm:agent type="person" xml:id="v1"><ttm:name type="full">Sam Smith</ttm:name></ttm:agent>
          <ttm:agent type="person" xml:id="v2"><ttm:name type="full">Normani</ttm:name></ttm:agent>
          <ttm:agent type="group" xml:id="v3"/>
        </metadata>
      </head>
      <body dur="02:51.030">
        <div begin="00:07.621" end="00:20.471" itunes:song-part="Verse">
          <p begin="00:07.621" end="00:10.267" ttm:agent="v1">
            <span begin="00:07.621" end="00:07.920">I</span>
            <span begin="00:07.920" end="00:08.253"> don't</span>
            <span begin="00:08.253" end="00:10.267"> wanna be alone tonight</span>
          </p>
          <p begin="00:12.395" end="00:15.728" ttm:agent="v2">
            <span begin="00:12.395" end="00:12.795">I</span>
            <span begin="00:12.795" end="00:15.728"> wasn't even going out tonight</span>
          </p>
          <p begin="00:17.141" end="00:20.976" ttm:agent="v3">
            <span begin="00:17.141" end="00:17.491">Dancing</span>
            <span begin="00:17.491" end="00:20.976"> with a stranger</span>
          </p>
          <p begin="00:21.271" end="00:24.175" ttm:agent="v1">
            <span begin="00:21.271" end="00:21.588">Look</span>
            <span begin="00:21.588" end="00:24.175"> what you made me do</span>
          </p>
        </div>
      </body>
    </tt>
    """

    @Test("a TTML paragraph's agent decides which edge of the sheet the line belongs on")
    func ttmlAgentsResolveToTurns() throws {
        let lyrics = try #require(TTMLParser.parse(Self.duetTTML, source: "Test"))

        #expect(lyrics.lines.count == 4)
        #expect(lyrics.lines.map(\.text) == [
            "I don't wanna be alone tonight",
            "I wasn't even going out tonight",
            "Dancing with a stranger",
            "Look what you made me do",
        ])
        // The document leads with `v1`, so Normani's paragraph is the other singer's turn. The
        // group is both of them together — not one singer taking over from the other — so it
        // stays where the lead's lines are.
        #expect(lyrics.lines.map(\.isOppositeTurn) == [false, true, false, false])
        #expect(lyrics.hasOppositeTurns)
        // The turn changes nothing about the line itself.
        #expect(lyrics.lines[1].words?.count == 2)
        #expect(lyrics.lines[1].timeInMs == 12_395)
    }

    /// The shape the live providers actually serve: one agent, declared and repeated on every
    /// paragraph. Nothing about a solo song may change.
    @Test("a single-agent document has no turns at all")
    func singleAgentHasNoTurns() throws {
        let raw = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" \
        itunes:timing="Word" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
          <head><metadata><ttm:agent type="person" xml:id="v1"/></metadata></head>
          <body dur="3:16.541">
            <div begin="8.243" end="27.566" itunes:songPart="Verse">
              <p begin="8.243" end="11.073" itunes:key="L1" ttm:agent="v1"><span begin="8.243" end="11.073">To be</span></p>
              <p begin="11.073" end="14.073" itunes:key="L2" ttm:agent="v1"><span begin="11.073" end="14.073">Alone</span></p>
            </div>
          </body>
        </tt>
        """

        let lyrics = try #require(TTMLParser.parse(raw, source: "Test"))

        #expect(lyrics.lines.count == 2)
        #expect(lyrics.hasOppositeTurns == false)
        #expect(lyrics.lines.map(\.text) == ["To be", "Alone"])
    }

    /// A document that declares no agents still says who sings first, and reading it that way
    /// is what keeps a hand-written duet from coming out with both singers everywhere.
    @Test("a document that declares no agents is led by the first one it sings")
    func undeclaredAgentsUseTheFirstSung() throws {
        let raw = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="0:01.000" end="0:02.000" ttm:agent="v1"><span begin="0:01.000" end="0:02.000">First</span></p>
            <p begin="0:02.000" end="0:03.000" ttm:agent="v2"><span begin="0:02.000" end="0:03.000">Second</span></p>
            <p begin="0:03.000" end="0:04.000" ttm:agent="v1"><span begin="0:03.000" end="0:04.000">First again</span></p>
            <p begin="0:04.000" end="0:05.000"><span begin="0:04.000" end="0:05.000">Nobody's</span></p>
          </div>
        </body></tt>
        """

        let lyrics = try #require(TTMLParser.parse(raw, source: "Test"))

        // The undeclared paragraph is not attributed to anybody, so it is not a turn either.
        #expect(lyrics.lines.map(\.isOppositeTurn) == [false, true, false, false])
    }

    /// TTML metadata attributes are inherited, so a document that attributes a whole section
    /// rather than each paragraph reads the same way; a paragraph that names its own agent
    /// still wins over the section's.
    @Test("an agent on the section is inherited by its paragraphs")
    func sectionAgentIsInherited() throws {
        let raw = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <head><metadata>
            <ttm:agent type="person" xml:id="v1"/>
            <ttm:agent type="person" xml:id="v2"/>
          </metadata></head>
          <body>
            <div begin="0:00.000" end="0:10.000" ttm:agent="v2">
              <p begin="0:01.000" end="0:02.000"><span begin="0:01.000" end="0:02.000">She sings</span></p>
              <p begin="0:02.000" end="0:03.000" ttm:agent="v1"><span begin="0:02.000" end="0:03.000">He answers</span></p>
              <p begin="0:03.000" end="0:04.000"><span begin="0:03.000" end="0:04.000">She sings on</span></p>
            </div>
          </body></tt>
        """

        let lyrics = try #require(TTMLParser.parse(raw, source: "Test"))

        #expect(lyrics.lines.map(\.text) == ["She sings", "He answers", "She sings on"])
        #expect(lyrics.lines.map(\.isOppositeTurn) == [true, false, true])
    }

    // MARK: - Paxsenix

    @Test("a Paxsenix content line flagged as the opposite turn is the second singer's")
    func paxsenixContentOppositeTurn() throws {
        let content: [PaxsenixLyricsResponse.ContentLine] = [
            PaxsenixLyricsResponse.ContentLine(
                timestamp: 1_000,
                background: nil,
                oppositeTurn: nil,
                text: [.init(text: "I don't wanna be alone", timestamp: 1_000, endtime: nil)]
            ),
            PaxsenixLyricsResponse.ContentLine(
                timestamp: 5_000,
                background: nil,
                oppositeTurn: true,
                text: [.init(text: "I wasn't even going out", timestamp: 5_000, endtime: nil)]
            ),
            PaxsenixLyricsResponse.ContentLine(
                timestamp: 9_000,
                background: true,
                oppositeTurn: true,
                text: [.init(text: "Ooh", timestamp: 9_000, endtime: nil)]
            ),
        ]

        guard case let .synced(lyrics) = PaxsenixProvider.parseContent(content, syllable: true) else {
            Issue.record("expected synced lyrics")
            return
        }

        #expect(lyrics.lines.map(\.isOppositeTurn) == [false, true, true])
        // Including the flagged backing line: the flag says who sings it, the backing flag
        // says over what.
        #expect(lyrics.lines[2].isBackgroundOnly)
    }

    @Test("Paxsenix ELRC voice markers name the singer")
    func elrcVoiceMarkers() throws {
        let raw = """
        [00:01.000]{v1}I don't wanna be alone tonight
        [00:05.000]{v2}I wasn't even going out tonight
        [00:09.000]{v1}Alone tonight
        [00:13.000]{v2}Alone tonight
        """

        let lyrics = try #require(PaxsenixProvider.parseELRC(raw))

        #expect(lyrics.lines.map(\.isOppositeTurn) == [false, true, false, true])
        // The marker is metadata: it is still stripped from the line's text.
        #expect(lyrics.lines.map(\.text) == [
            "I don't wanna be alone tonight",
            "I wasn't even going out tonight",
            "Alone tonight",
            "Alone tonight",
        ])
    }

    /// ELRC writes more than voices in braces — a backing marker among them — and only the
    /// shape Apple's agent ids have is read as one.
    @Test("a brace marker that is not a voice does not make a duet")
    func elrcNonVoiceMarker() throws {
        let raw = """
        [00:01.000]{bg}Half a world away
        [00:05.000]{bg}Half a world away
        """

        let lyrics = try #require(PaxsenixProvider.parseELRC(raw))

        #expect(lyrics.hasOppositeTurns == false)
        #expect(lyrics.lines.map(\.text) == ["Half a world away", "Half a world away"])
    }

    // MARK: - Model

    @Test("a turn survives a cache round-trip")
    func turnRoundTrip() throws {
        let lyrics = SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 1_000, text: "Lead", words: nil),
                SyncedLyricLine(timeInMs: 1_000, duration: 1_000, text: "Other", words: nil, isOppositeTurn: true),
            ],
            source: "Test"
        )

        let decoded = try JSONDecoder().decode(SyncedLyrics.self, from: JSONEncoder().encode(lyrics))

        #expect(decoded.lines.map(\.isOppositeTurn) == [false, true])
        // Only the turn is written: a line that is not one costs the cache nothing.
        let encoded = String(decoding: try JSONEncoder().encode(lyrics.lines[0]), as: UTF8.self)
        #expect(encoded.contains("isOppositeTurn") == false)
    }

    @Test("lyrics cached before singer turns existed still decode")
    func decodesLegacyCachedLine() throws {
        let json = #"{"timeInMs":1000,"duration":2000,"text":"Lead","words":[{"timeInMs":1000,"word":"Lead"}]}"#

        let line = try JSONDecoder().decode(SyncedLyricLine.self, from: Data(json.utf8))

        #expect(line.isOppositeTurn == false)
    }

    /// The display pass reshapes every line: it moves a parenthesized backing vocal onto the
    /// backing row, and it inserts a pause row for every interlude. A duet line has to come out
    /// of both still knowing whose turn it is.
    @Test("a turn survives the passes that reshape the sheet")
    func turnSurvivesTheDisplayPasses() {
        let sheet = SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 2_000, text: "I don't wanna be alone tonight", words: nil),
                SyncedLyricLine(
                    timeInMs: 5_000,
                    duration: 4_000,
                    text: "I wasn't even going out tonight (oh)",
                    words: nil,
                    isOppositeTurn: true
                ),
                SyncedLyricLine(timeInMs: 9_000, duration: 2_000, text: "Alone tonight", words: nil),
            ],
            source: "Test"
        )

        // Exactly what `SyncedLyricsService.forDisplay` applies, in the same order.
        let displayed = sheet.convertingParenthesizedBackingVocals().withPauseInterludes()

        #expect(displayed.lines.map(\.text) == [
            "I don't wanna be alone tonight",
            "",
            "I wasn't even going out tonight",
            "Alone tonight",
        ])
        #expect(displayed.isPauseLine(at: 1))
        #expect(displayed.lines.map(\.isOppositeTurn) == [false, false, true, false])
        #expect(displayed.lines[2].untimedBackgroundText == "oh")
    }

    // MARK: - Pauses

    /// Nothing is sung on a pause row and it has no singer of its own, so it is drawn on the
    /// edge of the line above it — an interlude inside the second singer's part is a pause in
    /// *their* section, not the lead's.
    @Test("a pause follows the line above it")
    func pauseFollowsTheLineAbove() {
        // Lead, then the other singer, then a gap long enough for the dots, then a line.
        let sheet = SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 2_000, text: "Lead line", words: nil),
                SyncedLyricLine(timeInMs: 5_000, duration: 2_000, text: "Other singer", words: nil, isOppositeTurn: true),
                SyncedLyricLine(timeInMs: 12_000, duration: 2_000, text: "Back to the lead", words: nil),
            ],
            source: "Test"
        ).withPauseInterludes()

        #expect(sheet.lines.map(\.text) == ["Lead line", "", "Other singer", "", "Back to the lead"])
        // The pause inside the other singer's part ends where their line does. The gap rows are
        // inserted by the sheet, so this is the pass knowing whose section it is inserting into.
        #expect(sheet.isTrailingAligned(at: 0) == false)
        #expect(sheet.isTrailingAligned(at: 1) == false)
        #expect(sheet.isTrailingAligned(at: 2))
        #expect(sheet.isTrailingAligned(at: 3))
        #expect(sheet.isTrailingAligned(at: 4) == false)
    }

    /// Two interludes in a row follow the last line that was actually sung, and a pause with
    /// nothing above it has only its own declaration to go on.
    @Test("a pause steps over the pauses above it and starts from nothing")
    func pauseLooksPastOtherPauses() {
        let sheet = SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 5_000, text: "", words: nil),
                SyncedLyricLine(timeInMs: 6_000, duration: 5_000, text: "", words: nil),
                SyncedLyricLine(timeInMs: 20_000, duration: 2_000, text: "Other singer", words: nil, isOppositeTurn: true),
            ],
            source: "Test"
        )

        // Nothing above the first row was sung, and it declares nothing either.
        #expect(sheet.isTrailingAligned(at: 0) == false)
        #expect(sheet.isTrailingAligned(at: 1) == false)
        #expect(sheet.isTrailingAligned(at: 2))
    }

    @Test("the dots are drawn where the line above them is drawn")
    func pauseDotsAreDrawnOnTheLinesEdge() {
        let dots = SyncedLyrics.PauseDots(statuses: [.active, .notSung, .notSung], lift: 0.5)

        for trailingAligned in [false, true] {
            let root = SyncedPauseDotsLineView(
                dots: dots,
                status: .current,
                isTrailingAligned: trailingAligned,
                onTap: {}
            )
            guard let ink = self.host(root) else {
                Issue.record("the dots drew nothing")
                return
            }

            let width = Self.rowWidth * ink.scale
            if trailingAligned {
                #expect(ink.maxX >= width - 6 * ink.scale, "the dots did not reach the trailing edge")
                #expect(ink.minX > 40 * ink.scale, "the dots did not leave the leading edge")
            } else {
                #expect(ink.minX <= 6 * ink.scale, "the dots did not start at the leading edge")
                #expect(ink.maxX < width - 40 * ink.scale, "the dots reached the trailing edge anyway")
            }
        }
    }

    // MARK: - Rendering

    /// Advances the run loop so the hosted view actually renders.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    /// The left-most and right-most inked columns of a hosted view, in device pixels.
    private static func inkBounds(_ view: NSView) -> (minX: CGFloat, maxX: CGFloat, scale: CGFloat)? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 4 else { return nil }

        let samples = rep.samplesPerPixel
        let rowBytes = rep.bytesPerRow
        var minX = rep.pixelsWide
        var maxX = -1
        for y in 0 ..< rep.pixelsHigh {
            let row = data + y * rowBytes
            for x in 0 ..< rep.pixelsWide where row[x * samples + 3] > 20 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }
        guard maxX > minX else { return nil }

        let scale = view.bounds.width > 0 ? CGFloat(rep.pixelsWide) / view.bounds.width : 1
        return (CGFloat(minX), CGFloat(maxX), scale)
    }

    private static let rowWidth: CGFloat = 420

    /// Hosts one karaoke row at a known width and reports the ink it drew.
    private func ink(of line: SyncedLyricLine, trailingAligned: Bool) -> (minX: CGFloat, maxX: CGFloat, scale: CGFloat)? {
        let root = KaraokeLyricsLineView(
            layout: KaraokeLineLayout(line: line, fontSize: 16),
            // Past the line's end: everything on it is sung, so the ink is the whole row.
            displayTimeMs: Double(line.timeInMs + line.duration + 1_000),
            isTrailingAligned: trailingAligned
        )
        return self.host(root)
    }

    /// A line the provider timed only as a whole, and a word-timed one: the two render paths a
    /// duet line can take, neither of which may be shifted by anything but the row's edge.
    private static func lineTextOnly(oppositeTurn: Bool) -> SyncedLyricLine {
        SyncedLyricLine(
            timeInMs: 0,
            duration: 4_000,
            text: "I wasn't even going out tonight",
            words: nil,
            isOppositeTurn: oppositeTurn
        )
    }

    private static func lineWithWords(oppositeTurn: Bool) -> SyncedLyricLine {
        SyncedLyricLine(
            timeInMs: 0,
            duration: 4_000,
            text: "I wasn't even going out tonight",
            words: [
                TimedWord(timeInMs: 0, word: "I"),
                TimedWord(timeInMs: 400, word: " wasn't"),
                TimedWord(timeInMs: 800, word: " even"),
                TimedWord(timeInMs: 1_200, word: " going"),
                TimedWord(timeInMs: 1_600, word: " out"),
                TimedWord(timeInMs: 2_000, word: " tonight"),
            ],
            isOppositeTurn: oppositeTurn
        )
    }

    /// Hosts one row of a real sheet, as the panel draws it, and reports the ink it drew.
    private func rowInk(lyrics: SyncedLyrics, index: Int) -> (minX: CGFloat, maxX: CGFloat, scale: CGFloat)? {
        let root = SyncedLineView(
            line: lyrics.lines[index],
            lineIndex: index,
            isTrailingAligned: lyrics.isTrailingAligned(at: index),
            status: .current,
            isLive: false,
            clock: LyricsPlaybackClock(),
            layoutCache: KaraokeLayoutCache(),
            minimumFrameInterval: nil,
            emphasis: 0,
            onTap: {}
        )
        return self.host(root)
    }

    /// Hosts a view at the row width and reports the ink it drew.
    private func host(_ root: some View) -> (minX: CGFloat, maxX: CGFloat, scale: CGFloat)? {
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.rowWidth, height: 90)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        self.pump(0.25)

        return Self.inkBounds(hosting)
    }

    /// The whole path a duet takes: the agent in the document, through the model, to the row
    /// the panel draws — the second singer's line ends on the other edge of the same width of
    /// panel the first singer's line starts on.
    @Test("a duet's second singer is drawn against the trailing edge of the sheet")
    func duetSheetDrawsTheSecondSingerOnTheRight() throws {
        let lyrics = try #require(TTMLParser.parse(Self.duetTTML, source: "Test"))

        guard let lead = self.rowInk(lyrics: lyrics, index: 0),
              let other = self.rowInk(lyrics: lyrics, index: 1)
        else {
            Issue.record("a row drew nothing")
            return
        }

        let width = Self.rowWidth * lead.scale
        #expect(lead.minX <= 6 * lead.scale, "the lead singer's line did not start at the left edge")
        #expect(lead.maxX < width - 40 * lead.scale, "the line is too wide to tell the edges apart")
        #expect(other.maxX >= width - 6 * other.scale, "the second singer's line did not reach the right edge")
        #expect(other.minX > 40 * other.scale, "the second singer's line did not leave the left edge")
        // The group's line follows the lead, not the second singer.
        guard let group = self.rowInk(lyrics: lyrics, index: 2) else {
            Issue.record("the group's row drew nothing")
            return
        }
        #expect(group.minX <= 6 * group.scale, "a group line was pushed to the second singer's edge")
    }

    @Test("the other singer's line is drawn against the trailing edge of its row")
    func turnsAreDrawnAgainstTheTrailingEdge() throws {
        for line in [Self.lineTextOnly(oppositeTurn: true), Self.lineWithWords(oppositeTurn: true)] {
            guard let lead = self.ink(of: line, trailingAligned: false),
                  let trailing = self.ink(of: line, trailingAligned: true)
            else {
                Issue.record("the row drew nothing")
                return
            }

            let width = Self.rowWidth * lead.scale
            // Sung by the first singer: hard against the left edge, and clearly short of the
            // right one — which is what makes the trailing measurement mean something.
            #expect(lead.minX <= 6 * lead.scale, "the lead line did not start at the left edge")
            #expect(lead.maxX < width - 40 * lead.scale, "the line is too wide to tell the edges apart")

            // Sung by the other: the same text, with its right end on the right edge.
            #expect(trailing.maxX >= width - 6 * trailing.scale, "the other singer's line did not reach the right edge")
            #expect(trailing.minX > 40 * trailing.scale, "the other singer's line did not move right")
        }
    }
}
