import Foundation
import Testing
@testable import Kaset

/// Tests for the PlaylistParser.
@Suite(.tags(.parser))
struct PlaylistParserTests {
    // MARK: - Library Playlists

    @Test("Parse empty library playlists response")
    func parseLibraryPlaylistsEmpty() {
        let data: [String: Any] = [:]
        let playlists = PlaylistParser.parseLibraryPlaylists(data)
        #expect(playlists.isEmpty)
    }

    @Test("Parse library playlists from grid")
    func parseLibraryPlaylistsFromGrid() {
        let data = self.makeLibraryResponseData(playlistCount: 3)
        let playlists = PlaylistParser.parseLibraryPlaylists(data)
        #expect(playlists.count == 3)
    }

    @Test("Parse mixed library content from grid and responsive shelf")
    func parseLibraryContentFromGridAndResponsiveShelf() {
        let data = self.makeMixedLibraryContentResponseData()
        let content = PlaylistParser.parseLibraryContent(data)

        #expect(content.playlists.map(\.id) == ["VLGRID123", "VLSHELF456"])
        #expect(content.playlists.map(\.title) == ["Grid Playlist", "Shelf Playlist"])
        #expect(content.playlists.map(\.author) == ["Grid Curator", "Shelf Curator"])

        #expect(content.artists.map(\.id) == ["MPLAUCGRIDARTIST123", "MPLAUCSHELFARTIST456"])
        #expect(content.artists.map(\.name) == ["Grid Artist", "Shelf Artist"])

        #expect(content.podcastShows.map(\.id) == ["MPSPPGRID123", "MPSPPSHELF456"])
        #expect(content.podcastShows.map(\.title) == ["Grid Podcast", "Shelf Podcast"])
        #expect(content.podcastShows.map(\.author) == ["Grid Host", "Shelf Host"])
    }

    @Test("Parse dedicated library artists response")
    func parseLibraryArtists() {
        let data = self.makeLibraryArtistsResponseData()
        let artists = PlaylistParser.parseLibraryArtists(data)

        #expect(artists.map(\.id) == ["UCGRIDARTIST123", "UCSHELFARTIST456"])
        #expect(artists.map(\.name) == ["Grid Artist", "Shelf Artist"])
    }

    @Test("Parse dedicated library artists deduplicates equivalent artist IDs")
    func parseLibraryArtistsDeduplicatesEquivalentIds() {
        let data = self.makeDuplicateLibraryArtistsResponseData()
        let artists = PlaylistParser.parseLibraryArtists(data)

        #expect(artists.map(\.id) == ["UCDUPLICATE123"])
        #expect(artists.map(\.name) == ["Duplicate Artist"])
    }

    // MARK: - Playlist Detail

    @Test("Parse playlist detail with header")
    func parsePlaylistDetailWithMusicDetailHeader() {
        let data = self.makePlaylistDetailData(
            title: "My Playlist",
            description: "A great playlist",
            author: "Test User",
            trackCount: 5
        )

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL123")

        #expect(detail.id == "VL123")
        #expect(detail.title == "My Playlist")
        #expect(detail.description == "A great playlist")
        #expect(detail.author == "Test User")
        #expect(detail.tracks.count == 5)
    }

    @Test("Parse playlist detail tracks")
    func parsePlaylistDetailWithTracks() {
        let data = self.makePlaylistDetailData(
            title: "Track Test",
            description: nil,
            author: nil,
            trackCount: 3
        )

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL456")

        #expect(detail.tracks.count == 3)
        #expect(detail.tracks[0].title == "Track 0")
        #expect(detail.tracks[0].videoId == "video0")
    }

    @Test("Parse empty playlist detail")
    func parsePlaylistDetailEmpty() {
        let data: [String: Any] = [:]
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL789")

        #expect(detail.id == "VL789")
        #expect(detail.title == "Unknown Playlist")
        #expect(detail.tracks.isEmpty)
    }

    @Test("Parse responsive playlist header track count and continuation")
    func parseResponsivePlaylistHeaderTrackCount() {
        let response = PlaylistParser.parsePlaylistWithContinuation(
            self.makeResponsivePlaylistDetailData(
                title: "Best Video Game Music",
                author: "Shelltoast",
                reportedTrackCountText: "2,429 tracks",
                duration: "135+ hours",
                loadedTrackCount: 100
            ),
            playlistId: "VL-big-playlist"
        )

        #expect(response.detail.title == "Best Video Game Music")
        #expect(response.detail.author == "Shelltoast")
        #expect(response.detail.trackCount == 2429)
        #expect(response.detail.duration == "135+ hours")
        #expect(response.detail.tracks.count == 100)
        #expect(response.continuationToken == "next_page_token_123")
        #expect(response.hasMore == true)
    }

    // MARK: - Sort Order

    @Test("Parse sort order and editable flag from the sort submenu")
    func parseSortOrderFromSubMenu() {
        let response = PlaylistParser.parsePlaylistWithContinuation(
            self.makeOwnedPlaylistData(sortMenu: self.makeSortSubMenu()),
            playlistId: "VL-owned"
        )

        #expect(response.detail.isEditable == true)
        #expect(response.detail.availableSortOrders == [.manual, .newestFirst, .newestLast])
        #expect(response.detail.sortOrder == .newestFirst)
        #expect(response.detail.isSortable == true)
    }

    @Test("A Top voted option in the header is not offered")
    func parseTopVotedSortOrderIsNotOffered() {
        // A voted playlist's header can advertise `playlistVideoOrder: 6` for Top voted. Selecting it
        // writes fine — YouTube Music answers `STATUS_SUCCEEDED` — but the reloaded playlist still
        // comes back in its previous order, which reads as the sort doing nothing. The option is
        // therefore dropped rather than offered and then ignored.
        let submenu: [String: Any] = [
            "sortFilterSubMenuRenderer": [
                "subMenuItems": [
                    self.makeSortSubMenuItem(title: "Manual", order: 0, selected: true),
                    self.makeSortSubMenuItem(title: "Newest first", order: 1, selected: false),
                    self.makeSortSubMenuItem(title: "Oldest first", order: 2, selected: false),
                    self.makeSortSubMenuItem(title: "Top voted", order: 6, selected: false),
                ],
            ],
        ]

        let response = PlaylistParser.parsePlaylistWithContinuation(
            self.makeOwnedPlaylistData(sortMenu: submenu),
            playlistId: "VL-owned"
        )

        #expect(response.detail.availableSortOrders == [.manual, .newestFirst, .newestLast])
        #expect(response.detail.sortOrder == .manual)
        // The write for it is not modelled at all, so no code path can send `6`.
        #expect(PlaylistSortOrder(rawValue: 6) == nil)
        // The playlist stays sortable: only the unsupported option is gone.
        #expect(response.detail.isSortable == true)
    }

    @Test("Parse sort order from the sort filter button")
    func parseSortOrderFromButton() {
        let button: [String: Any] = [
            "musicSortFilterButtonRenderer": [
                "title": ["runs": [["text": "Oldest first"]]],
                "menu": [
                    "musicMultiSelectMenuRenderer": [
                        "options": [
                            self.makeSortButtonOption(title: "Manual", order: 0),
                            self.makeSortButtonOption(title: "Newest first", order: 1),
                            self.makeSortButtonOption(title: "Oldest first", order: 2),
                        ],
                    ],
                ],
            ],
        ]

        let response = PlaylistParser.parsePlaylistWithContinuation(
            self.makeOwnedPlaylistData(sortMenu: button),
            playlistId: "VL-owned"
        )

        #expect(response.detail.isEditable == true)
        #expect(response.detail.availableSortOrders == [.manual, .newestFirst, .newestLast])
        #expect(response.detail.sortOrder == .newestLast)
    }

    @Test("Liked Music is sortable even without an advertised menu")
    func parseLikedMusicFallsBackToStandardSortOptions() {
        let data = self.makePlaylistDetailData(
            title: "Liked Music",
            description: nil,
            author: nil,
            trackCount: 1
        )

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "LM")

        #expect(detail.isLikedMusic == true)
        #expect(detail.sortOptions == PlaylistSortOrder.standard)
        #expect(detail.isSortable == true)
        #expect(detail.effectiveSortOrder == .manual)
    }

    @Test("A sort menu on a playlist we cannot edit is not offered")
    func parseSortMenuWithoutEditHeaderIsNotActionable() {
        let detail = PlaylistParser.parsePlaylistDetail(
            self.makePlaylistDetailData(
                title: "Someone Else's Playlist",
                description: nil,
                author: "Another User",
                trackCount: 1,
                sortMenu: self.makeSortSubMenu()
            ),
            playlistId: "VL-public"
        )

        // The response advertises the menu, but a reorder from a listener who cannot edit the playlist
        // is rejected with HTTP 400, so the UI must not offer one.
        #expect(detail.availableSortOrders == [.manual, .newestFirst, .newestLast])
        #expect(detail.isEditable == false)
        #expect(detail.isSortable == false)
    }

    @Test("Playlist without an edit header exposes no sort options")
    func parseSortOrderAbsentForUnownedPlaylist() {
        let data = self.makePlaylistDetailData(
            title: "Someone Else's Playlist",
            description: nil,
            author: "Another User",
            trackCount: 2
        )

        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL-public")

        #expect(detail.isEditable == false)
        #expect(detail.availableSortOrders.isEmpty)
        #expect(detail.sortOrder == nil)
        #expect(detail.isSortable == false)
    }

    // MARK: - Album Detection

    @Test(
        "Album detection based on ID prefix",
        arguments: [
            ("MPRE12345", true), // Album prefix
            ("VL12345", false), // Playlist prefix
            ("OLAK12345", true), // Another album prefix
            ("RDCLAK", false), // Radio prefix
        ]
    )
    func isAlbumDetection(playlistId: String, expectedIsAlbum: Bool) {
        let data = self.makePlaylistDetailData(title: "Test", description: nil, author: nil, trackCount: 1)
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: playlistId)
        #expect(detail.isAlbum == expectedIsAlbum)
    }

    // MARK: - Continuation Parsing

    @Test("Parse 2025 continuation format with onResponseReceivedActions")
    func parsePlaylistContinuation2025Format() {
        // Create mock 2025 continuation response format
        var continuationItems: [[String: Any]] = []

        for i in 0 ..< 5 {
            continuationItems.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "cont_video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Continuation Track \(i)"]]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        // Add continuation token at the end (for next page)
        continuationItems.append([
            "continuationItemRenderer": [
                "continuationEndpoint": [
                    "continuationCommand": [
                        "token": "next_page_token_123",
                    ],
                ],
            ],
        ])

        let data: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": continuationItems,
                ],
            ]],
        ]

        let response = PlaylistParser.parsePlaylistContinuation(data)

        #expect(response.tracks.count == 5)
        #expect(response.tracks[0].title == "Continuation Track 0")
        #expect(response.tracks[0].videoId == "cont_video0")
        #expect(response.hasMore == true)
        #expect(response.continuationToken == "next_page_token_123")
    }

    @Test("Parse 2025 continuation format without next token")
    func parsePlaylistContinuation2025FormatNoNextToken() {
        var continuationItems: [[String: Any]] = []

        for i in 0 ..< 3 {
            continuationItems.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "final_video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Final Track \(i)"]]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        // No continuationItemRenderer at the end - this is the last page

        let data: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": continuationItems,
                ],
            ]],
        ]

        let response = PlaylistParser.parsePlaylistContinuation(data)

        #expect(response.tracks.count == 3)
        #expect(response.hasMore == false)
        #expect(response.continuationToken == nil)
    }

    // MARK: - Playlist Mutations Parsing

    @Test("Parse add-to-playlist entries deduplicates and infers membership")
    func parseAddToPlaylistEntriesDeduplicates() {
        let data: [String: Any] = [
            "outer": [
                "items": [
                    [
                        "playlistAddToOptionRenderer": [
                            "playlistId": "VL001",
                            "title": ["runs": [["text": "Chill Mix"]]],
                            "shortBylineText": ["runs": [["text": "You • 20 songs"]]],
                            "isSelected": true,
                            "addToPlaylistServiceEndpoint": [
                                "playlistEditEndpoint": [
                                    "actions": [["action": "ACTION_ADD_VIDEO"]],
                                ],
                            ],
                            "removeFromPlaylistServiceEndpoint": [
                                "playlistEditEndpoint": [
                                    "actions": [["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID"]],
                                ],
                            ],
                        ],
                    ],
                    [
                        "nested": [
                            "playlistAddToOptionRenderer": [
                                "playlistId": "VL002",
                                "title": ["runs": [["text": "Roadtrip"]]],
                                "shortBylineText": ["runs": [["text": "35 songs"]]],
                                "addToPlaylistServiceEndpoint": [
                                    "playlistEditEndpoint": [
                                        "actions": [["action": "ACTION_ADD_VIDEO"]],
                                    ],
                                ],
                            ],
                        ],
                    ],
                    // Duplicate playlist ID should be ignored
                    [
                        "playlistAddToOptionRenderer": [
                            "playlistId": "VL001",
                            "title": ["runs": [["text": "Duplicate Chill Mix"]]],
                            "addToPlaylistServiceEndpoint": [
                                "playlistEditEndpoint": [
                                    "actions": [["action": "ACTION_ADD_VIDEO"]],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let entries = PlaylistParser.parseAddToPlaylistEntries(data)

        #expect(entries.count == 2)
        #expect(entries.map(\.id) == ["VL001", "VL002"])
        #expect(entries[0].title == "Chill Mix")
        #expect(entries[0].subtitle == "You • 20 songs")
        #expect(entries[0].canAddVideo == true)
        #expect(entries[0].canRemoveVideoById == true)
        #expect(entries[0].containsVideo == true)
        #expect(entries[1].canRemoveVideoById == false)
        #expect(entries[1].containsVideo == false)
    }

    @Test("Parse add-to-playlist entries detects membership from selected state")
    func parseAddToPlaylistEntriesDetectsMembershipFromSelectedState() {
        let data: [String: Any] = [
            "playlists": [
                [
                    "playlistAddToOptionRenderer": [
                        "playlistId": "LM",
                        "title": ["runs": [["text": "Liked Music"]]],
                        "isSelected": true,
                    ],
                ],
            ],
        ]

        let entries = PlaylistParser.parseAddToPlaylistEntries(data)

        #expect(entries.count == 1)
        #expect(entries[0].id == "LM")
        #expect(entries[0].containsVideo == true)
    }

    @Test("Parse add-to-playlist entries does not infer Liked Music membership from like endpoint")
    func parseAddToPlaylistEntriesDoesNotInferLikedMusicMembershipFromLikeStatus() {
        let data: [String: Any] = [
            "playlists": [
                [
                    "playlistAddToOptionRenderer": [
                        "playlistId": "LM",
                        "title": ["runs": [["text": "Liked Music"]]],
                        "addToPlaylistServiceEndpoint": [
                            "likeEndpoint": [
                                "status": "LIKE",
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let entries = PlaylistParser.parseAddToPlaylistEntries(data)

        #expect(entries.count == 1)
        #expect(entries[0].id == "LM")
        #expect(entries[0].containsVideo == false)
    }

    @Test("Parse created playlist from playlist/create response")
    func parseCreatedPlaylistFromCreateResponse() {
        let data: [String: Any] = [
            "playlistId": "PLNEW123",
            "actions": [[
                "handlePlaylistCreationCommand": [
                    "createdPlaylist": [
                        "musicTwoRowItemRenderer": [
                            "title": ["runs": [["text": "My New Playlist"]]],
                            "subtitle": ["runs": [["text": "You • 1 song"]]],
                            "thumbnailRenderer": [
                                "musicThumbnailRenderer": [
                                    "thumbnail": [
                                        "thumbnails": [[
                                            "url": "https://example.com/thumb.jpg",
                                        ]],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ]],
        ]

        let playlist = PlaylistParser.parseCreatedPlaylist(data)

        #expect(playlist?.id == "PLNEW123")
        #expect(playlist?.title == "My New Playlist")
        #expect(playlist?.author == "You")
        #expect(playlist?.trackCount == 1)
        #expect(playlist?.thumbnailURL?.absoluteString == "https://example.com/thumb.jpg")
    }

    @Test("Parse created playlist returns nil without playlist ID")
    func parseCreatedPlaylistMissingPlaylistId() {
        let playlist = PlaylistParser.parseCreatedPlaylist([:])
        #expect(playlist == nil)
    }

    // MARK: - Header Artists

    @Test("Parse album artists from the header strapline")
    func parseAlbumArtistsFromStrapline() {
        let data = self.makeAlbumDetailData(
            title: "Dai Dai",
            straplineRuns: [
                ["text": "Shakira", "navigationEndpoint": ["browseEndpoint": ["browseId": "UC-shakira"]]],
                ["text": " & "],
                ["text": "Burna Boy", "navigationEndpoint": ["browseEndpoint": ["browseId": "UC-burna"]]],
            ]
        )

        let response = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: "MPREb_dai-dai")

        #expect(response.detail.isAlbum)
        #expect(response.detail.artists.map(\.name) == ["Shakira", "Burna Boy"])
        #expect(response.detail.artists.map(\.id) == ["UC-shakira", "UC-burna"])
        #expect(response.detail.artists.allSatisfy { $0.hasNavigableId })
        #expect(response.detail.author == "Shakira, Burna Boy")
    }

    @Test("Parse album artist without a channel link is displayable but not navigable")
    func parseAlbumArtistWithoutChannelLink() {
        let data = self.makeAlbumDetailData(
            title: "Dai Dai en español shakiraa",
            straplineRuns: [["text": "AT Musica"]]
        )

        let response = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: "MPREb_karaoke")

        #expect(response.detail.artists.map(\.name) == ["AT Musica"])
        #expect(response.detail.artists.allSatisfy { !$0.hasNavigableId })
        #expect(response.detail.author == "AT Musica")
    }

    @Test("Album page-type keywords never become artists")
    func parseAlbumPageTypeKeywordIsNotAnArtist() {
        let data = self.makeAlbumDetailData(title: "No Recess", straplineRuns: [])

        let response = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: "MPREb_no-recess")

        #expect(response.detail.artists.isEmpty)
        // The subtitle is "Single • 2026", which describes the release, not a credited artist.
        #expect(response.detail.author == nil)
    }

    @Test("Parse playlist creator from the facepile owner link")
    func parsePlaylistCreatorFromFacepile() {
        let data: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicResponsiveHeaderRenderer": [
                                            "title": ["runs": [["text": "Bleach"]]],
                                            "subtitle": ["runs": [["text": "Playlist"], ["text": " • "], ["text": "2025"]]],
                                            "secondSubtitle": ["runs": [["text": "13 tracks"], ["text": " • "], ["text": "43 minutes"]]],
                                            "facepile": [
                                                "avatarStackViewModel": [
                                                    "text": ["content": "Rock Bands"],
                                                    "rendererContext": [
                                                        "commandContext": [
                                                            "onTap": [
                                                                "innertubeCommand": [
                                                                    "browseEndpoint": ["browseId": "UC-rock-bands"],
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                    "secondaryContents": [
                        "sectionListRenderer": [
                            "contents": [[
                                "musicPlaylistShelfRenderer": [
                                    "contents": [
                                        [
                                            "musicResponsiveListItemRenderer": [
                                                "playlistItemData": ["videoId": "track-1"],
                                                "flexColumns": [
                                                    [
                                                        "musicResponsiveListItemFlexColumnRenderer": [
                                                            "text": ["runs": [["text": "Blew"]]],
                                                        ],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ]],
                        ],
                    ],
                ],
            ],
        ]

        let response = PlaylistParser.parsePlaylistWithContinuation(data, playlistId: "PLbleach")

        #expect(!response.detail.isAlbum)
        #expect(response.detail.author == "Rock Bands")
        #expect(response.detail.artists.map(\.name) == ["Rock Bands"])
        #expect(response.detail.artists.map(\.id) == ["UC-rock-bands"])
        #expect(response.detail.artists.allSatisfy { $0.hasNavigableId })
    }

    // MARK: - Helpers

    /// Builds an album page shaped like the real API response: the header (with the artist
    /// strapline) lives in the tab, the track shelf in `secondaryContents`.
    private func makeAlbumDetailData(title: String, straplineRuns: [[String: Any]]) -> [String: Any] {
        var headerRenderer: [String: Any] = [
            "title": ["runs": [["text": title]]],
            "subtitle": ["runs": [["text": "Single"], ["text": " • "], ["text": "2026"]]],
            "secondSubtitle": ["runs": [["text": "1 song"], ["text": " • "], ["text": "3 minutes, 44 seconds"]]],
        ]

        if !straplineRuns.isEmpty {
            headerRenderer["straplineTextOne"] = ["runs": straplineRuns]
        }

        return [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [["musicResponsiveHeaderRenderer": headerRenderer]],
                                ],
                            ],
                        ],
                    ]],
                    "secondaryContents": [
                        "sectionListRenderer": [
                            "contents": [[
                                "musicShelfRenderer": [
                                    "contents": [
                                        [
                                            "musicResponsiveListItemRenderer": [
                                                "playlistItemData": ["videoId": "album-track-1"],
                                                "flexColumns": [
                                                    [
                                                        "musicResponsiveListItemFlexColumnRenderer": [
                                                            "text": ["runs": [["text": title]]],
                                                        ],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ]],
                        ],
                    ],
                ],
            ],
        ]
    }

    private func makeLibraryResponseData(playlistCount: Int) -> [String: Any] {
        var items: [[String: Any]] = []

        for i in 0 ..< playlistCount {
            items.append([
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Playlist \(i)"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "VL\(i)"],
                    ],
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
                                    "contents": [[
                                        "gridRenderer": [
                                            "items": items,
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

    private func makeMixedLibraryContentResponseData() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "gridRenderer": [
                                                "items": self.makeMixedLibraryGridItems(),
                                            ],
                                        ],
                                        [
                                            "musicShelfRenderer": [
                                                "contents": self.makeMixedLibraryShelfItems(),
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeLibraryArtistsResponseData() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "gridRenderer": [
                                                "items": [[
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Grid Artist"]]],
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "MPLAUCGRIDARTIST123"],
                                                        ],
                                                    ],
                                                ]],
                                            ],
                                        ],
                                        [
                                            "musicShelfRenderer": [
                                                "contents": [[
                                                    "musicResponsiveListItemRenderer": [
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "MPLAUCSHELFARTIST456"],
                                                        ],
                                                        "flexColumns": [[
                                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                                "text": ["runs": [["text": "Shelf Artist"]]],
                                                            ],
                                                        ]],
                                                    ],
                                                ]],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeDuplicateLibraryArtistsResponseData() -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": [
                                                [
                                                    "musicResponsiveListItemRenderer": [
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "MPLAUCDUPLICATE123"],
                                                        ],
                                                        "flexColumns": [[
                                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                                "text": ["runs": [["text": "Duplicate Artist"]]],
                                                            ],
                                                        ]],
                                                    ],
                                                ],
                                                [
                                                    "musicResponsiveListItemRenderer": [
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "UCDUPLICATE123"],
                                                        ],
                                                        "flexColumns": [[
                                                            "musicResponsiveListItemFlexColumnRenderer": [
                                                                "text": ["runs": [["text": "Duplicate Artist"]]],
                                                            ],
                                                        ]],
                                                    ],
                                                ],
                                            ],
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

    private func makeMixedLibraryGridItems() -> [[String: Any]] {
        [
            [
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Grid Playlist"]]],
                    "subtitle": ["runs": [["text": "Grid Curator"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "VLGRID123"],
                    ],
                ],
            ],
            [
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Grid Artist"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "MPLAUCGRIDARTIST123"],
                    ],
                ],
            ],
            [
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Grid Podcast"]]],
                    "subtitle": ["runs": [["text": "Grid Host"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "MPSPPGRID123"],
                    ],
                ],
            ],
        ]
    }

    private func makeMixedLibraryShelfItems() -> [[String: Any]] {
        [
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "VLSHELF456"],
                    ],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Playlist"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Curator"]]],
                            ],
                        ],
                    ],
                ],
            ],
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "MPLAUCSHELFARTIST456"],
                    ],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Artist"]]],
                            ],
                        ],
                    ],
                ],
            ],
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "MPSPPSHELF456"],
                    ],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Podcast"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Shelf Host"]]],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    /// Builds a track item shaped like YouTube Music's playlist rows.
    private func makeTrackItem(index: Int) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": "video\(index)"],
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": ["runs": [["text": "Track \(index)"]]],
                        ],
                    ],
                ],
            ],
        ]
    }

    /// Parses the sort menu the same way the app does, from a submenu shape.
    private func makeSortSubMenu() -> [String: Any] {
        [
            "sortFilterSubMenuRenderer": [
                "subMenuItems": [
                    self.makeSortSubMenuItem(title: "Manual", order: 0, selected: false),
                    self.makeSortSubMenuItem(title: "Newest first", order: 1, selected: true),
                    self.makeSortSubMenuItem(title: "Oldest first", order: 2, selected: false),
                ],
            ],
        ]
    }

    private func makeSortSubMenuItem(title: String, order: Int, selected: Bool) -> [String: Any] {
        [
            "title": title,
            "selected": selected,
            "serviceEndpoint": [
                "playlistEditEndpoint": [
                    "actions": [["action": "ACTION_SET_PLAYLIST_VIDEO_ORDER", "playlistVideoOrder": order]],
                ],
            ],
        ]
    }

    private func makeSortButtonOption(title: String, order: Int) -> [String: Any] {
        [
            "musicMultiSelectMenuItemRenderer": [
                "title": ["runs": [["text": title]]],
                "selectedCommand": [
                    "commandExecutorCommand": [
                        "commands": [[
                            "playlistEditEndpoint": [
                                "actions": [["action": "ACTION_SET_PLAYLIST_VIDEO_ORDER", "playlistVideoOrder": order]],
                            ],
                        ]],
                    ],
                ],
            ],
        ]
    }

    /// A playlist response that carries an owned (editable) header plus a sort menu.
    private func makeOwnedPlaylistData(sortMenu: [String: Any]) -> [String: Any] {
        [
            "header": [
                "musicEditablePlaylistDetailHeaderRenderer": [
                    "editHeader": ["musicPlaylistEditHeaderRenderer": ["privacy": "PRIVATE"]],
                    "header": [
                        "musicResponsiveHeaderRenderer": [
                            "title": ["runs": [["text": "My Playlist"]]],
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
                                        "musicPlaylistShelfRenderer": [
                                            "contents": [
                                                self.makeTrackItem(index: 0),
                                                sortMenu,
                                            ],
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

    private func makePlaylistDetailData(
        title: String,
        description: String?,
        author: String?,
        trackCount: Int,
        sortMenu: [String: Any]? = nil
    ) -> [String: Any] {
        var tracks: [[String: Any]] = []

        for i in 0 ..< trackCount {
            tracks.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Track \(i)"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Artist \(i)"]]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        var headerRenderer: [String: Any] = [
            "title": ["runs": [["text": title]]],
        ]

        if let desc = description {
            headerRenderer["description"] = ["runs": [["text": desc]]]
        }

        if let auth = author {
            headerRenderer["subtitle"] = ["runs": [["text": auth]]]
        }

        return [
            "header": [
                "musicDetailHeaderRenderer": headerRenderer,
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": tracks + (sortMenu.map { [$0] } ?? []),
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

    private func makeResponsivePlaylistDetailData(
        title: String,
        author: String,
        reportedTrackCountText: String,
        duration: String,
        loadedTrackCount: Int
    ) -> [String: Any] {
        var tracks: [[String: Any]] = []

        for i in 0 ..< loadedTrackCount {
            tracks.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Track \(i)"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Artist \(i)"]]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        tracks.append([
            "continuationItemRenderer": [
                "continuationEndpoint": [
                    "continuationCommand": [
                        "token": "next_page_token_123",
                    ],
                ],
            ],
        ])

        return [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicResponsiveHeaderRenderer": [
                                            "title": ["runs": [["text": title]]],
                                            "subtitle": [
                                                "runs": [
                                                    ["text": "Playlist"],
                                                    ["text": " • "],
                                                    ["text": "2026"],
                                                ],
                                            ],
                                            "secondSubtitle": [
                                                "runs": [
                                                    ["text": "21M views"],
                                                    ["text": " • "],
                                                    ["text": reportedTrackCountText],
                                                    ["text": " • "],
                                                    ["text": duration],
                                                ],
                                            ],
                                            "facepile": [
                                                "avatarStackViewModel": [
                                                    "text": [
                                                        "content": author,
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                    "secondaryContents": [
                        "sectionListRenderer": [
                            "contents": [[
                                "musicPlaylistShelfRenderer": [
                                    "contents": tracks,
                                ],
                            ]],
                        ],
                    ],
                ],
            ],
        ]
    }
}
