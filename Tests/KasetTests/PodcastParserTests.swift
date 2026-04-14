import Foundation
import Testing
@testable import Kaset

/// Tests for the PodcastParser.
@Suite(.tags(.parser))
struct PodcastParserTests {
    // MARK: - parseDiscovery Tests

    @Test("Parse empty response returns empty sections")
    func parseEmptyResponse() {
        let data: [String: Any] = [:]
        let sections = PodcastParser.parseDiscovery(data)
        #expect(sections.isEmpty)
    }

    @Test("Parse discovery response with carousel section")
    func parseDiscoveryWithCarouselSection() {
        let data = self.makeDiscoveryData(withCarousel: true, withShelf: false)
        let sections = PodcastParser.parseDiscovery(data)
        #expect(sections.count == 1)
        #expect(sections.first?.title == "Popular Podcasts")
    }

    @Test("Parse discovery response with music shelf section")
    func parseDiscoveryWithMusicShelfSection() {
        let data = self.makeDiscoveryData(withCarousel: false, withShelf: true)
        let sections = PodcastParser.parseDiscovery(data)
        #expect(sections.count == 1)
        #expect(sections.first?.title == "Episodes for You")
    }

    @Test("Parse discovery response with multiple sections")
    func parseDiscoveryWithMultipleSections() {
        let data = self.makeDiscoveryData(withCarousel: true, withShelf: true)
        let sections = PodcastParser.parseDiscovery(data)
        #expect(sections.count == 2)
    }

    @Test("Parse two-row podcast episode includes playback progress")
    func parseTwoRowPodcastEpisodeWithProgress() {
        let data = self.makeDiscoveryDataWithTwoRowEpisodeProgress()
        let sections = PodcastParser.parseDiscovery(data)
        guard let firstSection = sections.first,
              case let .episode(episode) = firstSection.items.first
        else {
            Issue.record("Expected first discovery item to be a podcast episode")
            return
        }

        #expect(episode.playbackProgress == 0.42)
        #expect(episode.isPlayed == false)
    }

    @Test("Parse two-row item with show browse and watch endpoint as episode")
    func parseTwoRowItemWithBrowseAndWatchPrefersEpisode() {
        let data = self.makeDiscoveryDataWithTwoRowBrowseAndWatchEpisodeProgress()
        let sections = PodcastParser.parseDiscovery(data)
        guard let firstSection = sections.first,
              case let .episode(episode) = firstSection.items.first
        else {
            Issue.record("Expected first discovery item to be parsed as episode")
            return
        }

        #expect(episode.id == "ep-browse-watch")
        #expect(episode.showBrowseId == "MPSPPshow123")
        #expect(episode.playbackProgress == 0.28)
    }

    @Test("Parse multi-row onTap watchPlaylistEndpoint videoId")
    func parseMultiRowOnTapWatchPlaylistEndpointVideoId() {
        let data = self.makeDiscoveryDataWithMultiRowWatchPlaylistEpisode()
        let sections = PodcastParser.parseDiscovery(data)
        guard let firstSection = sections.first,
              case let .episode(episode) = firstSection.items.first
        else {
            Issue.record("Expected first discovery item to be parsed as episode")
            return
        }

        #expect(episode.id == "ep-ontap-playlist")
    }

    @Test("Parse two-row MPED browseId as episode videoId")
    func parseTwoRowMPEDBrowseIdVideoId() {
        let data = self.makeDiscoveryDataWithTwoRowMPEDBrowseEpisode()
        let sections = PodcastParser.parseDiscovery(data)
        guard let firstSection = sections.first,
              case let .episode(episode) = firstSection.items.first
        else {
            Issue.record("Expected first discovery item to be parsed as episode")
            return
        }

        #expect(episode.id == "correct-from-mped")
    }

    // MARK: - parseContinuation Tests

    @Test("Parse empty continuation returns empty sections")
    func parseEmptyContinuation() {
        let data: [String: Any] = [:]
        let sections = PodcastParser.parseContinuation(data)
        #expect(sections.isEmpty)
    }

    @Test("Parse continuation response with sections")
    func parseContinuationWithSections() {
        let data = self.makeContinuationData(sectionCount: 2)
        let sections = PodcastParser.parseContinuation(data)
        #expect(sections.count == 2)
    }

    // MARK: - parseShowDetail Tests

    @Test("Parse empty show detail returns placeholder show")
    func parseEmptyShowDetail() {
        let data: [String: Any] = [:]
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")
        #expect(detail.show.id == "MPSPP123")
        #expect(detail.show.title.isEmpty)
        #expect(detail.episodes.isEmpty)
    }

    @Test("Parse show detail with header")
    func parseShowDetailWithHeader() {
        let data = self.makeShowDetailData(
            title: "Tech Podcast",
            author: "Tech Company",
            description: "A great tech podcast",
            episodeCount: 3
        )
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")
        #expect(detail.show.title == "Tech Podcast")
        #expect(detail.show.author == "Tech Company")
        #expect(detail.show.description == "A great tech podcast")
        #expect(detail.episodes.count == 3)
    }

    @Test("Parse show detail with subscription status")
    func parseShowDetailWithSubscriptionStatus() {
        let data = self.makeShowDetailDataTwoColumn(title: "Subscribed Show", isSubscribed: true)
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")
        #expect(detail.isSubscribed == true)
    }

    @Test("Parse show detail with continuation token")
    func parseShowDetailWithContinuation() {
        let data = self.makeShowDetailData(title: "Long Show", continuationToken: "token123")
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")
        #expect(detail.continuationToken == "token123")
        #expect(detail.hasMore == true)
    }

    @Test("Parse show detail responsive episodes with playback progress")
    func parseShowDetailWithResponsiveEpisodeProgress() {
        let data = self.makeShowDetailDataWithEpisodeProgress()
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")

        #expect(detail.episodes.count == 1)
        #expect(detail.episodes.first?.playbackProgress == 0.64)
        #expect(detail.episodes.first?.isPlayed == false)
    }

    @Test("Parse show detail responsive episodes with nested resume overlay progress")
    func parseShowDetailWithNestedResumeProgress() {
        let data = self.makeShowDetailDataWithNestedResumeProgress()
        let detail = PodcastParser.parseShowDetail(data, showId: "MPSPP123")

        #expect(detail.episodes.count == 1)
        #expect(detail.episodes.first?.playbackProgress == 0.37)
        #expect(detail.episodes.first?.isPlayed == false)
    }

    // MARK: - parseEpisodesContinuation Tests

    @Test("Parse empty episodes continuation")
    func parseEmptyEpisodesContinuation() {
        let data: [String: Any] = [:]
        let continuation = PodcastParser.parseEpisodesContinuation(data)
        #expect(continuation.episodes.isEmpty)
        #expect(continuation.continuationToken == nil)
        #expect(continuation.hasMore == false)
    }

    @Test("Parse episodes continuation with episodes")
    func parseEpisodesContinuationWithEpisodes() {
        let data = self.makeEpisodesContinuationData(episodeCount: 5, hasMore: true)
        let continuation = PodcastParser.parseEpisodesContinuation(data)
        #expect(continuation.episodes.count == 5)
        #expect(continuation.hasMore == true)
    }

    @Test("Parse episodes continuation without more pages")
    func parseEpisodesContinuationWithoutMore() {
        let data = self.makeEpisodesContinuationData(episodeCount: 2, hasMore: false)
        let continuation = PodcastParser.parseEpisodesContinuation(data)
        #expect(continuation.episodes.count == 2)
        #expect(continuation.hasMore == false)
    }

    // MARK: - isPodcastShow Tests

    @Test("isPodcastShow returns true for MPSPP prefix")
    func isPodcastShowWithMPSPPPrefix() {
        #expect(PodcastParser.isPodcastShow("MPSPP12345") == true)
    }

    @Test("isPodcastShow returns false for non-MPSPP prefix")
    func isPodcastShowWithOtherPrefix() {
        #expect(PodcastParser.isPodcastShow("VL12345") == false)
        #expect(PodcastParser.isPodcastShow("UC12345") == false)
        #expect(PodcastParser.isPodcastShow("MPRE12345") == false)
    }

    // MARK: - Test Data Helpers

    private func makeDiscoveryData(withCarousel: Bool, withShelf: Bool) -> [String: Any] {
        var sections: [[String: Any]] = []

        if withCarousel {
            sections.append([
                "musicCarouselShelfRenderer": [
                    "header": [
                        "musicCarouselShelfBasicHeaderRenderer": [
                            "title": ["runs": [["text": "Popular Podcasts"]]],
                        ],
                    ],
                    "contents": [self.makePodcastShowItem(id: "MPSPP1", title: "Show 1")],
                ],
            ])
        }

        if withShelf {
            sections.append([
                "musicShelfRenderer": [
                    "title": ["runs": [["text": "Episodes for You"]]],
                    "contents": [self.makeEpisodeItem(id: "ep1", title: "Episode 1")],
                ],
            ])
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": sections,
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeContinuationData(sectionCount: Int) -> [String: Any] {
        var sections: [[String: Any]] = []
        for i in 0 ..< sectionCount {
            sections.append([
                "musicCarouselShelfRenderer": [
                    "header": [
                        "musicCarouselShelfBasicHeaderRenderer": [
                            "title": ["runs": [["text": "Section \(i)"]]],
                        ],
                    ],
                    "contents": [self.makePodcastShowItem(id: "MPSPP\(i)", title: "Show \(i)")],
                ],
            ])
        }

        return [
            "continuationContents": [
                "sectionListContinuation": [
                    "contents": sections,
                ],
            ],
        ]
    }

    private func makeShowDetailData(
        title: String,
        author: String? = nil,
        description: String? = nil,
        episodeCount: Int = 0,
        isSubscribed: Bool = false,
        continuationToken: String? = nil
    ) -> [String: Any] {
        var episodes: [[String: Any]] = []
        for i in 0 ..< episodeCount {
            episodes.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "ep\(i)"],
                    "flexColumns": [[
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [["text": "Episode \(i)"]]],
                        ],
                    ]],
                ],
            ])
        }

        var data: [String: Any] = [
            "header": [
                "musicDetailHeaderRenderer": [
                    "title": ["runs": [["text": title]]],
                    "subtitle": ["runs": [["text": author ?? ""]]],
                    "description": description.map { ["runs": [["text": $0]]] } as Any,
                    "menu": [
                        "menuRenderer": [
                            "items": isSubscribed ? [[
                                "menuServiceItemRenderer": [
                                    "icon": ["iconType": "LIBRARY_REMOVE"],
                                ],
                            ]] : [],
                        ],
                    ],
                ],
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": episodes,
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]

        if let token = continuationToken {
            // Add continuation to the music shelf
            if var contents = data["contents"] as? [String: Any],
               var singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
               var tabs = singleColumn["tabs"] as? [[String: Any]],
               var firstTab = tabs.first,
               var tabRenderer = firstTab["tabRenderer"] as? [String: Any],
               var content = tabRenderer["content"] as? [String: Any],
               var sectionList = content["sectionListRenderer"] as? [String: Any],
               var sectionContents = sectionList["contents"] as? [[String: Any]],
               var firstSection = sectionContents.first,
               var musicShelf = firstSection["musicShelfRenderer"] as? [String: Any]
            {
                musicShelf["continuations"] = [[
                    "nextContinuationData": ["continuation": token],
                ]]
                firstSection["musicShelfRenderer"] = musicShelf
                sectionContents[0] = firstSection
                sectionList["contents"] = sectionContents
                content["sectionListRenderer"] = sectionList
                tabRenderer["content"] = content
                firstTab["tabRenderer"] = tabRenderer
                tabs[0] = firstTab
                singleColumn["tabs"] = tabs
                contents["singleColumnBrowseResultsRenderer"] = singleColumn
                data["contents"] = contents
            }
        }

        return data
    }

    /// Creates show detail data using the twoColumnBrowseResultsRenderer format
    /// which is the current format the parser uses for subscription status.
    private func makeShowDetailDataTwoColumn(
        title: String,
        isSubscribed: Bool = false
    ) -> [String: Any] {
        [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicResponsiveHeaderRenderer": [
                                            "title": ["runs": [["text": title]]],
                                            "buttons": [[
                                                "toggleButtonRenderer": [
                                                    "isToggled": isSubscribed,
                                                ],
                                            ]],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeEpisodesContinuationData(episodeCount: Int, hasMore: Bool) -> [String: Any] {
        var episodes: [[String: Any]] = []
        for i in 0 ..< episodeCount {
            episodes.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "ep\(i)"],
                    "flexColumns": [[
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [["text": "Episode \(i)"]]],
                        ],
                    ]],
                ],
            ])
        }

        var shelfContinuation: [String: Any] = [
            "contents": episodes,
        ]

        if hasMore {
            shelfContinuation["continuations"] = [[
                "nextContinuationData": ["continuation": "next-token"],
            ]]
        }

        return [
            "continuationContents": [
                "musicShelfContinuation": shelfContinuation,
            ],
        ]
    }

    private func makeDiscoveryDataWithTwoRowEpisodeProgress() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicCarouselShelfRenderer": [
                                            "header": [
                                                "musicCarouselShelfBasicHeaderRenderer": [
                                                    "title": ["runs": [["text": "Keep listening"]]],
                                                ],
                                            ],
                                            "contents": [[
                                                "musicTwoRowItemRenderer": [
                                                    "title": ["runs": [["text": "Episode with progress"]]],
                                                    "navigationEndpoint": [
                                                        "watchEndpoint": ["videoId": "ep-progress"],
                                                    ],
                                                    "subtitle": ["runs": [["text": "Podcast Show"]]],
                                                    "playbackProgress": ["playbackProgressPercentage": 42],
                                                ],
                                            ]],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeDiscoveryDataWithTwoRowBrowseAndWatchEpisodeProgress() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicCarouselShelfRenderer": [
                                            "header": [
                                                "musicCarouselShelfBasicHeaderRenderer": [
                                                    "title": ["runs": [["text": "Keep listening"]]],
                                                ],
                                            ],
                                            "contents": [[
                                                "musicTwoRowItemRenderer": [
                                                    "title": ["runs": [["text": "Episode browse+watch"]]],
                                                    "navigationEndpoint": [
                                                        "browseEndpoint": ["browseId": "MPSPPshow123"],
                                                        "watchEndpoint": ["videoId": "ep-browse-watch"],
                                                    ],
                                                    "subtitle": ["runs": [["text": "Podcast Show"]]],
                                                    "playbackProgress": ["playbackProgressPercentage": 28],
                                                ],
                                            ]],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeDiscoveryDataWithMultiRowWatchPlaylistEpisode() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "title": ["runs": [["text": "Your new episodes"]]],
                                            "contents": [[
                                                "musicMultiRowListItemRenderer": [
                                                    "title": ["runs": [["text": "Episode via watchPlaylistEndpoint"]]],
                                                    "onTap": [
                                                        "watchPlaylistEndpoint": [
                                                            "videoId": "ep-ontap-playlist",
                                                            "playlistId": "PL123",
                                                        ],
                                                    ],
                                                    // Intentionally conflicting fallback endpoint to verify priority.
                                                    "navigationEndpoint": [
                                                        "watchEndpoint": ["videoId": "ep-fallback-wrong"],
                                                    ],
                                                ],
                                            ]],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeDiscoveryDataWithTwoRowMPEDBrowseEpisode() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicCarouselShelfRenderer": [
                                            "header": [
                                                "musicCarouselShelfBasicHeaderRenderer": [
                                                    "title": ["runs": [["text": "Your new episodes"]]],
                                                ],
                                            ],
                                            "contents": [[
                                                "musicTwoRowItemRenderer": [
                                                    "title": ["runs": [["text": "Episode from MPED"]]],
                                                    "navigationEndpoint": [
                                                        "browseEndpoint": ["browseId": "MPEDcorrect-from-mped"],
                                                    ],
                                                    // Conflicting fallback that should not win.
                                                    "thumbnailOverlay": [
                                                        "musicItemThumbnailOverlayRenderer": [
                                                            "content": [
                                                                "musicPlayButtonRenderer": [
                                                                    "playNavigationEndpoint": [
                                                                        "watchEndpoint": ["videoId": "wrong-fallback-id"],
                                                                    ],
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                            ]],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeShowDetailDataWithEpisodeProgress() -> [String: Any] {
        [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "secondaryContents": [
                        "sectionListRenderer": [
                            "contents": [[
                                "musicShelfRenderer": [
                                    "contents": [[
                                        "musicResponsiveListItemRenderer": [
                                            "playlistItemData": ["videoId": "ep-progress"],
                                            "flexColumns": [[
                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                    "text": ["runs": [["text": "Episode with progress"]]],
                                                ],
                                            ]],
                                            "playbackProgress": ["playbackProgressPercentage": 64],
                                        ],
                                    ]],
                                ],
                            ]],
                        ],
                    ],
                ],
            ],
        ]
    }

    private func makeShowDetailDataWithNestedResumeProgress() -> [String: Any] {
        [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "secondaryContents": [
                        "sectionListRenderer": [
                            "contents": [[
                                "musicShelfRenderer": [
                                    "contents": [[
                                        "musicResponsiveListItemRenderer": [
                                            "playlistItemData": ["videoId": "ep-progress-overlay"],
                                            "flexColumns": [[
                                                "musicResponsiveListItemFlexColumnRenderer": [
                                                    "text": ["runs": [["text": "Episode with nested progress"]]],
                                                ],
                                            ]],
                                            "overlay": [
                                                "musicItemThumbnailOverlayRenderer": [
                                                    "content": [
                                                        "thumbnailOverlayResumePlaybackRenderer": [
                                                            "percentDurationWatched": 37,
                                                        ],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ]],
                                ],
                            ]],
                        ],
                    ],
                ],
            ],
        ]
    }

    private func makePodcastShowItem(id: String, title: String) -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": title]]],
                "navigationEndpoint": [
                    "browseEndpoint": ["browseId": id],
                ],
            ],
        ]
    }

    private func makeEpisodeItem(id: String, title: String) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": id],
                "flexColumns": [[
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": title]]],
                    ],
                ]],
            ],
        ]
    }
}
