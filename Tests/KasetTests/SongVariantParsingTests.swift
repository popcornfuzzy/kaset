import Foundation
import Testing
@testable import Kaset

/// Tests that parsers carry the song/video counterpart and `musicVideoType`.
@Suite(.serialized, .tags(.parser))
struct SongVariantParsingTests {
    // MARK: - Fixtures

    private func makeRenderer(
        videoId: String,
        title: String,
        musicVideoType: String?,
        byline: String = "Test Artist",
        length: String = "3:20"
    ) -> [String: Any] {
        var renderer: [String: Any] = [
            "videoId": videoId,
            "title": ["runs": [["text": title]]],
            "longBylineText": ["runs": [["text": byline]]],
            "lengthText": ["runs": [["text": length]]],
        ]

        if let musicVideoType {
            renderer["navigationEndpoint"] = [
                "watchEndpoint": [
                    "videoId": videoId,
                    "watchEndpointMusicSupportedConfigs": [
                        "watchEndpointMusicConfig": ["musicVideoType": musicVideoType],
                    ],
                ],
            ]
        }

        return renderer
    }

    private func makeWrapperItem(primary: [String: Any], counterpart: [String: Any]) -> [String: Any] {
        [
            "playlistPanelVideoWrapperRenderer": [
                "primaryRenderer": ["playlistPanelVideoRenderer": primary],
                "counterpart": [
                    ["counterpartRenderer": ["playlistPanelVideoRenderer": counterpart]],
                ],
            ],
        ]
    }

    private func makeWatchNextResponse(item: [String: Any]) -> [String: Any] {
        [
            "contents": [
                "singleColumnMusicWatchNextResultsRenderer": [
                    "tabbedRenderer": [
                        "watchNextTabbedResultsRenderer": [
                            "tabs": [
                                [
                                    "tabRenderer": [
                                        "content": [
                                            "musicQueueRenderer": [
                                                "content": [
                                                    "playlistPanelRenderer": [
                                                        "contents": [item],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    // MARK: - Tests

    @Test("SongMetadataParser attaches the counterpart and video type")
    func songMetadataParsesCounterpart() throws {
        let primary = self.makeRenderer(
            videoId: "video-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_OMV"
        )
        let counterpart = self.makeRenderer(
            videoId: "audio-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_ATV"
        )
        let data = self.makeWatchNextResponse(item: self.makeWrapperItem(primary: primary, counterpart: counterpart))

        let song = try SongMetadataParser.parse(data, videoId: "video-id")

        #expect(song.videoId == "video-id")
        #expect(song.musicVideoType == .omv)
        #expect(song.isVideoVariant)
        #expect(song.counterpart?.videoId == "audio-id")
        #expect(song.counterpart?.musicVideoType == .atv)
    }

    @Test("RadioQueueParser carries music video type and counterpart")
    func radioQueueParsesVariant() {
        let primary = self.makeRenderer(
            videoId: "video-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_OMV"
        )
        let counterpart = self.makeRenderer(
            videoId: "audio-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_ATV"
        )
        let data = self.makeWatchNextResponse(item: self.makeWrapperItem(primary: primary, counterpart: counterpart))

        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 1)
        #expect(result.songs[0].videoId == "video-id")
        #expect(result.songs[0].musicVideoType == .omv)
        #expect(result.songs[0].counterpart?.videoId == "audio-id")
    }

    @Test("PlaylistParser queue tracks carry music video type and counterpart")
    func playlistQueueParsesVariant() {
        let primary = self.makeRenderer(
            videoId: "video-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_OMV"
        )
        let counterpart = self.makeRenderer(
            videoId: "audio-id", title: "Song", musicVideoType: "MUSIC_VIDEO_TYPE_ATV"
        )
        let data: [String: Any] = [
            "queueDatas": [
                ["content": self.makeWrapperItem(primary: primary, counterpart: counterpart)],
            ],
        ]

        let tracks = PlaylistParser.parseQueueTracks(data)

        #expect(tracks.count == 1)
        #expect(tracks[0].videoId == "video-id")
        #expect(tracks[0].musicVideoType == .omv)
        #expect(tracks[0].counterpart?.videoId == "audio-id")
    }

    @Test("A song counterpairs with its video")
    func songCounterpartRoundTrips() {
        let video = Song(
            id: "video-id", title: "Song", artists: [],
            videoId: "video-id", musicVideoType: .omv
        )
        let audio = Song(
            id: "audio-id", title: "Song", artists: [],
            videoId: "audio-id", musicVideoType: .atv
        ).paired(with: video)

        #expect(audio.counterpart?.videoId == "video-id")
        #expect(audio.counterpart?.isVideoVariant == true)
        #expect(audio.counterpart?.asSong.isVideoVariant == true)
    }
}
