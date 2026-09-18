import Foundation
import Testing
@testable import Kaset

/// Tests for utility extensions.
@Suite(.tags(.model))
struct ExtensionsTests {
    // MARK: - Collection Safe Subscript Tests

    @Test("Safe subscript returns value for valid indices")
    func arraySafeSubscriptInBounds() {
        let array = [1, 2, 3, 4, 5]
        #expect(array[safe: 0] == 1)
        #expect(array[safe: 2] == 3)
        #expect(array[safe: 4] == 5)
    }

    @Test("Safe subscript returns nil for out of bounds indices")
    func arraySafeSubscriptOutOfBounds() {
        let array = [1, 2, 3]
        #expect(array[safe: 3] == nil)
        #expect(array[safe: 10] == nil)
        #expect(array[safe: -1] == nil)
    }

    @Test("Safe subscript returns nil for empty array")
    func arraySafeSubscriptEmptyArray() {
        let array: [Int] = []
        #expect(array[safe: 0] == nil)
    }

    @Test("Safe subscript works with character arrays")
    func stringSafeSubscript() {
        let string = "Hello"
        let array = Array(string)
        #expect(array[safe: 0] == "H")
        #expect(array[safe: 4] == "o")
        #expect(array[safe: 5] == nil)
    }

    // MARK: - TimeInterval Formatted Duration Tests

    @Test(
        "Formats seconds correctly",
        arguments: [
            (0.0, "0:00"),
            (5.0, "0:05"),
            (59.0, "0:59"),
        ]
    )
    func formattedDurationSeconds(seconds: TimeInterval, expected: String) {
        #expect(seconds.formattedDuration == expected)
    }

    @Test(
        "Formats minutes correctly",
        arguments: [
            (60.0, "1:00"),
            (65.0, "1:05"),
            (125.0, "2:05"),
            (3599.0, "59:59"),
        ]
    )
    func formattedDurationMinutes(seconds: TimeInterval, expected: String) {
        #expect(seconds.formattedDuration == expected)
    }

    @Test(
        "Formats hours correctly",
        arguments: [
            (3600.0, "1:00:00"),
            (3661.0, "1:01:01"),
            (7325.0, "2:02:05"),
            (36000.0, "10:00:00"),
        ]
    )
    func formattedDurationHours(seconds: TimeInterval, expected: String) {
        #expect(seconds.formattedDuration == expected)
    }

    @Test("Truncates decimal seconds")
    func formattedDurationDecimal() {
        #expect(TimeInterval(65.5).formattedDuration == "1:05")
        #expect(TimeInterval(65.9).formattedDuration == "1:05")
    }

    // MARK: - URL High Quality Thumbnail Tests

    @Test("Upgrades ytimg URL to high quality")
    func highQualityThumbnailYtimg() throws {
        let url = try #require(URL(string: "https://i.ytimg.com/vi/abc/w60-h60-l90-rj"))
        let highQuality = url.highQualityThumbnailURL
        #expect(highQuality != nil)
        #expect(try #require(highQuality?.absoluteString.contains("w544-h544")))
    }

    @Test("Upgrades googleusercontent URL to high quality")
    func highQualityThumbnailGoogleusercontent() throws {
        let url = try #require(URL(string: "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"))
        let highQuality = url.highQualityThumbnailURL
        #expect(highQuality != nil)
        #expect(try #require(highQuality?.absoluteString.contains("w544-h544")))
    }

    @Test("Returns original URL for non-YouTube URLs")
    func highQualityThumbnailNonYouTubeURL() throws {
        let url = try #require(URL(string: "https://example.com/image.jpg"))
        let highQuality = url.highQualityThumbnailURL
        #expect(highQuality == url)
    }

    @Test("Returns same URL for already high quality thumbnails")
    func highQualityThumbnailAlreadyHighQuality() throws {
        let url = try #require(URL(string: "https://i.ytimg.com/vi/abc/w400-h400-l90-rj"))
        let highQuality = url.highQualityThumbnailURL
        #expect(highQuality?.absoluteString == "https://i.ytimg.com/vi/abc/w400-h400-l90-rj")
    }

    @Test("Promotes an sddefault still to the large named variants first")
    func promotesSddefaultStill() throws {
        // `i.ytimg.com` serves its large stills only by name, and the API answers `sddefault.jpg`
        // (640x480) for a large share of tracks. Without this promotion the preferred candidate *was*
        // the 640x480 still, so the fullscreen artwork (up to 380pt / 760px on Retina) drew it upscaled
        // while a `maxresdefault.jpg` (1280x720) existed for the same video.
        let url = try #require(URL(string: "https://i.ytimg.com/vi/abc/sddefault.jpg"))

        #expect(url.highQualityThumbnailURL?.absoluteString.hasSuffix("/maxresdefault.jpg") == true)
        #expect(url.highQualityThumbnailCandidates.map(\.absoluteString) == [
            "https://i.ytimg.com/vi/abc/maxresdefault.jpg",
            "https://i.ytimg.com/vi/abc/hq720.jpg",
            "https://i.ytimg.com/vi/abc/sddefault.jpg",
            "https://i.ytimg.com/vi/abc/hqdefault.jpg",
        ])
    }

    @Test("Promotes mqdefault and hqdefault stills, keeping the original as a fallback")
    func promotesOtherNamedStills() throws {
        let mqdefault = try #require(URL(string: "https://i.ytimg.com/vi/abc/mqdefault.jpg"))
        #expect(mqdefault.highQualityThumbnailCandidates.map(\.absoluteString) == [
            "https://i.ytimg.com/vi/abc/maxresdefault.jpg",
            "https://i.ytimg.com/vi/abc/hq720.jpg",
            "https://i.ytimg.com/vi/abc/sddefault.jpg",
            "https://i.ytimg.com/vi/abc/hqdefault.jpg",
            "https://i.ytimg.com/vi/abc/mqdefault.jpg",
        ])

        let hqdefault = try #require(URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg"))
        #expect(hqdefault.highQualityThumbnailCandidates.map(\.absoluteString) == [
            "https://i.ytimg.com/vi/abc/maxresdefault.jpg",
            "https://i.ytimg.com/vi/abc/hq720.jpg",
            "https://i.ytimg.com/vi/abc/sddefault.jpg",
            "https://i.ytimg.com/vi/abc/hqdefault.jpg",
        ])
    }

    @Test("Keeps an hq720 still first and degrades to the smaller named variants")
    func keepsHq720StillFirst() throws {
        // `hq720.jpg` is the shape most of the API's track thumbnails already use (1280x720), so it must
        // stay the preferred candidate — only the fallback tail changes.
        let url = try #require(URL(string: "https://i.ytimg.com/vi/abc/hq720.jpg"))

        #expect(url.highQualityThumbnailURL?.absoluteString.hasSuffix("/hq720.jpg") == true)
        #expect(url.highQualityThumbnailCandidates.map(\.absoluteString) == [
            "https://i.ytimg.com/vi/abc/hq720.jpg",
            "https://i.ytimg.com/vi/abc/sddefault.jpg",
            "https://i.ytimg.com/vi/abc/hqdefault.jpg",
        ])
    }

    // MARK: - String Truncated Tests

    @Test("Returns full string when shorter than limit")
    func stringTruncatedShorterThanLimit() {
        let string = "Hello"
        #expect(string.truncated(to: 10) == "Hello")
    }

    @Test("Returns full string when exactly at limit")
    func stringTruncatedExactlyAtLimit() {
        let string = "Hello"
        #expect(string.truncated(to: 5) == "Hello")
    }

    @Test("Truncates with ellipsis when longer than limit")
    func stringTruncatedLongerThanLimit() {
        let string = "Hello, World!"
        #expect(string.truncated(to: 5) == "Hello…")
    }

    @Test("Uses custom trailing string")
    func stringTruncatedWithCustomTrailing() {
        let string = "Hello, World!"
        #expect(string.truncated(to: 5, trailing: "...") == "Hello...")
    }

    @Test("Handles empty string")
    func stringTruncatedEmptyString() {
        let string = ""
        #expect(string.truncated(to: 10).isEmpty)
    }

    @Test("Handles zero length")
    func stringTruncatedZeroLength() {
        let string = "Hello"
        #expect(string.truncated(to: 0) == "…")
    }

    @Test("Handles one character")
    func stringTruncatedOneCharacter() {
        let string = "Hello"
        #expect(string.truncated(to: 1) == "H…")
    }
}
