import AppKit
import Testing
@testable import Kaset

/// The queue row's greys, against the system ones they replace.
///
/// The row is drawn inside the Now Playing sidebar's material, whose content lives in a **vibrant**
/// appearance. Measured on this Mac, `secondaryLabelColor` under `VibrantLight` lands as a grey of 0.43
/// and `tertiaryLabelColor` as 0.70 — so the artist, the track number and the duration were drawn in
/// near-background greys, which is the washed-out row these tests are about (the same numbers are in
/// `EmphasizedMaterialView`'s table, and the fix follows `Sidebar.rowForeground(for:)`).
///
/// The values are compared **as they land on the panel**, since the system colours arrive with alpha in
/// the plain appearances: a colour is layered over a light or a dark material and the result is what the
/// reader sees. Under `VibrantLight` the queue's artist lands at 0.19 against the system's 0.43, and under
/// `VibrantDark` at 0.82 against 0.41 — darker than the system in light mode, lighter in dark, in all four
/// appearances.
@Suite(.serialized)
@MainActor
struct QueueRowTextColorTests {
    private static let lightMaterial: CGFloat = 0.95
    private static let darkMaterial: CGFloat = 0.12
    private static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .vibrantLight, .vibrantDark]

    /// The colour as it lands on a panel of `background`, in `appearance`, or nil if it cannot be resolved.
    private func painted(
        _ color: NSColor,
        over background: CGFloat,
        in appearance: NSAppearance
    ) -> CGFloat? {
        var result: CGFloat?
        appearance.performAsCurrentDrawingAppearance {
            guard let gray = color.usingColorSpace(.genericGray) else { return }
            let alpha = gray.alphaComponent
            result = gray.whiteComponent * alpha + background * (1 - alpha)
        }
        return result
    }

    /// Two landed greys are the same colour when they are within a shade of each other.
    ///
    /// A tolerance rather than `==`: one of the two paths goes through a `CGColor` and back, which is not
    /// required to round-trip to the same floating-point white. The greys this file is about are three
    /// tenths of a shade apart, so a hundredth is a comparison and not a fudge.
    private func sameShade(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs - rhs) < 0.01
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for subview in view.subviews {
            found.append(contentsOf: self.textFields(in: subview))
        }
        return found
    }

    private func field(_ text: String, in view: NSView) -> NSTextField? {
        self.textFields(in: view).first { $0.stringValue == text }
    }

    private func waveform(in view: NSView) -> WaveformView? {
        if let wave = view as? WaveformView { return wave }
        for subview in view.subviews {
            if let found = self.waveform(in: subview) { return found }
        }
        return nil
    }

    private func configuredCell(
        appearance: NSAppearance,
        isCurrentTrack: Bool = false,
        isPlaying: Bool = false,
        index: Int = 0
    ) -> QueueTableCellView {
        let cell = QueueTableCellView(frame: NSRect(x: 0, y: 0, width: 350, height: 56))
        cell.appearance = appearance
        cell.configure(
            song: TestFixtures.makeSong(id: "video-1", title: "Song", artistName: "Artist", artistId: "UC1"),
            index: index,
            isCurrentTrack: isCurrentTrack,
            isPlaying: isPlaying,
            actions: QueueCellActions(onPlay: {}, onRevealRemove: {})
        )
        return cell
    }

    @Test("Every appearance answers which side of the line it draws on")
    func appearanceKnowsItsScheme() throws {
        // `bestMatch(from:)` is what a dynamic colour's provider is asked, so a vibrant appearance has to
        // answer with the scheme underneath it rather than falling through to light.
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))
        let vibrantLight = try #require(NSAppearance(named: .vibrantLight))
        let vibrantDark = try #require(NSAppearance(named: .vibrantDark))

        #expect(aqua.isDark == false)
        #expect(darkAqua.isDark)
        #expect(vibrantLight.isDark == false)
        #expect(vibrantDark.isDark)
    }

    @Test("Light mode draws the queue's greys darker than the system's, dark mode lighter")
    func queueGreysBeatTheSystemOnes() throws {
        for name in Self.appearances {
            let appearance = try #require(NSAppearance(named: name))
            let background = appearance.isDark ? Self.darkMaterial : Self.lightMaterial
            let wantsDarker = !appearance.isDark

            for (ours, system) in [
                (QueueRowTextColor.artist, NSColor.secondaryLabelColor),
                (QueueRowTextColor.detail, NSColor.tertiaryLabelColor),
            ] {
                let mine = try #require(self.painted(ours, over: background, in: appearance))
                let theirs = try #require(self.painted(system, over: background, in: appearance))
                let message = "\(name.rawValue): ours \(mine) vs the system's \(theirs)"

                if wantsDarker {
                    #expect(mine < theirs, "not darker — \(message)")
                } else {
                    #expect(mine > theirs, "not lighter — \(message)")
                }
            }
        }
    }

    @Test("The artist line keeps more contrast than the number, the duration and the resting waveform")
    func theTwoGreysAreOrdered() throws {
        for name in Self.appearances {
            let appearance = try #require(NSAppearance(named: name))
            let background = appearance.isDark ? Self.darkMaterial : Self.lightMaterial
            let artist = try #require(self.painted(QueueRowTextColor.artist, over: background, in: appearance))
            let detail = try #require(self.painted(QueueRowTextColor.detail, over: background, in: appearance))

            // Both pull away from the material, the artist a little further than the rest of the row.
            if appearance.isDark {
                #expect(artist > detail && detail > background, "\(name.rawValue)")
            } else {
                #expect(artist < detail && detail < background, "\(name.rawValue)")
            }
        }
    }

    @Test("A row draws its artist, duration and number in the queue's greys")
    func rowsDrawTheQueueGreys() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let background = appearance.isDark ? Self.darkMaterial : Self.lightMaterial

            // A row that is not playing: the number is drawn where the waveform would be.
            let cell = self.configuredCell(appearance: appearance, index: 4)
            let artist = try #require(self.field("Artist", in: cell))
            let duration = try #require(self.field("3:00", in: cell))
            let number = try #require(self.field("5", in: cell))

            for (field, color) in [
                (artist, QueueRowTextColor.artist),
                (duration, QueueRowTextColor.detail),
                (number, QueueRowTextColor.detail),
            ] {
                let drawn = try #require(field.textColor)
                #expect(
                    self.sameShade(
                        self.painted(drawn, over: background, in: appearance),
                        self.painted(color, over: background, in: appearance)
                    ),
                    "\(name.rawValue): \"\(field.stringValue)\" is not drawn in the queue's grey"
                )
            }
        }
    }

    @Test("The paused waveform is drawn in the same grey as the number it replaces")
    func theRestingWaveformUsesTheDetailGrey() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let background = appearance.isDark ? Self.darkMaterial : Self.lightMaterial

            let cell = self.configuredCell(appearance: appearance, isCurrentTrack: true, isPlaying: false)
            let wave = try #require(self.waveform(in: cell))
            let mine = self.painted(QueueRowTextColor.detail, over: background, in: appearance)

            #expect(
                self.sameShade(self.painted(wave.tintColor, over: background, in: appearance), mine),
                "\(name.rawValue): the waveform's tint is not the queue's grey"
            )

            // The bars are layers, which hold a *resolved* colour: this is the one the reader sees.
            let bar = try #require(wave.layer?.sublayers?.first?.backgroundColor)
            let barColor = try #require(NSColor(cgColor: bar))
            #expect(
                self.sameShade(self.painted(barColor, over: background, in: appearance), mine),
                "\(name.rawValue): the waveform's bars are not the queue's grey"
            )
        }
    }

    @Test("Switching the appearance repaints the bars, which hold a resolved colour")
    func appearanceSwitchRepaintsTheBars() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let cell = self.configuredCell(appearance: light, isCurrentTrack: true, isPlaying: false)
        let wave = try #require(self.waveform(in: cell))
        let bar = try #require(wave.layer?.sublayers?.first)

        let lightBar = try #require(bar.backgroundColor)
        let inLight = try #require(NSColor(cgColor: lightBar))
        cell.appearance = dark
        let darkBar = try #require(bar.backgroundColor)
        let inDark = try #require(NSColor(cgColor: darkBar))

        // The dark row's bars are no longer the light row's grey, and they are the dark one's own.
        let lightWhite = try #require(inLight.usingColorSpace(.genericGray)).whiteComponent
        let darkWhite = try #require(inDark.usingColorSpace(.genericGray)).whiteComponent
        #expect(abs(lightWhite - darkWhite) > 0.1, "the bars kept the light appearance's colour")
        #expect(
            self.sameShade(
                self.painted(inDark, over: Self.darkMaterial, in: dark),
                self.painted(QueueRowTextColor.detail, over: Self.darkMaterial, in: dark)
            ),
            "the repainted bars are not the dark appearance's grey"
        )
    }
}
