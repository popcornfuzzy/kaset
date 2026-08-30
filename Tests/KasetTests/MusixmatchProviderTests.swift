import Testing
@testable import Kaset

@Suite(.tags(.service))
struct MusixmatchProviderTests {
    @Test("Parses rich-sync lines and word offsets")
    func parsesRichSync() {
        let raw = #"[{"ts":1.25,"te":2.5,"l":[{"c":"Hello","o":0.0},{"c":" world","o":0.4}]}]"#

        let result = MusixmatchProvider.parseRichSync(raw)

        #expect(result?.source == "Musixmatch")
        #expect(result?.lines.count == 1)
        #expect(result?.lines.first?.timeInMs == 1250)
        #expect(result?.lines.first?.duration == 1250)
        #expect(result?.lines.first?.text == "Hello world")
        #expect(result?.lines.first?.words?.count == 1)
        #expect(result?.lines.first?.words?.first?.word == "Hello world")
        #expect(result?.lines.first?.words?.first?.timeInMs == 1250)
    }

    @Test("Preserves spaces and combines character fragments")
    func preservesWordFragments() {
        let raw = #"[{"ts":0,"te":1,"l":[{"c":"Com","o":0},{"c":"in","o":0.2},{"c":"g ","o":0.4}]}]"#
        let result = MusixmatchProvider.parseRichSync(raw)
        #expect(result?.lines.first?.text == "Coming ")
        #expect(result?.lines.first?.words?.count == 1)
        #expect(result?.lines.first?.words?.first?.word == "Coming ")
    }

    @Test("Rejects malformed rich-sync payload")
    func rejectsMalformedPayload() {
        #expect(MusixmatchProvider.parseRichSync("not-json") == nil)
    }
}
