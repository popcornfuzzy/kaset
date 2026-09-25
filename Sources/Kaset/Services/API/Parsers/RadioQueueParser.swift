import Foundation

// MARK: - RadioQueueResult

/// Result from parsing a radio queue, including songs and continuation token.
struct RadioQueueResult {
    let songs: [Song]
    /// Continuation token for fetching more songs (infinite mix).
    let continuationToken: String?
    /// Server-provided tuning row for automix queues. Empty for queues the server does not tune
    /// (and for re-tuned responses, which omit the row).
    var tunerChips: [QueueTunerChip] = []
}

// MARK: - RadioQueueParser

/// Parses radio queue responses from YouTube Music API.
enum RadioQueueParser {
    private static let logger = DiagnosticsLogger.api

    /// Parses the radio queue from the "next" endpoint response.
    /// - Parameter data: The response from the "next" endpoint with a radio playlist ID
    /// - Returns: RadioQueueResult containing songs and optional continuation token
    static func parse(from data: [String: Any]) -> RadioQueueResult {
        guard let contents = data["contents"] as? [String: Any],
              let watchNextRenderer = contents["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any],
              let tabbedRenderer = watchNextRenderer["tabbedRenderer"] as? [String: Any],
              let watchNextTabbedResults = tabbedRenderer["watchNextTabbedResultsRenderer"] as? [String: Any],
              let tabs = watchNextTabbedResults["tabs"] as? [[String: Any]],
              let firstTab = tabs.first,
              let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
              let tabContent = tabRenderer["content"] as? [String: Any],
              let musicQueueRenderer = tabContent["musicQueueRenderer"] as? [String: Any],
              let queueContent = musicQueueRenderer["content"] as? [String: Any],
              let playlistPanelRenderer = queueContent["playlistPanelRenderer"] as? [String: Any],
              let playlistContents = playlistPanelRenderer["contents"] as? [[String: Any]]
        else {
            self.logger.debug("RadioQueueParser: Failed to parse radio queue structure. Top keys: \(data.keys.sorted())")
            return RadioQueueResult(songs: [], continuationToken: nil)
        }

        // Extract continuation token for infinite mix
        var continuationToken: String?
        if let continuations = playlistPanelRenderer["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextRadioData = firstContinuation["nextRadioContinuationData"] as? [String: Any],
           let token = nextRadioData["continuation"] as? String
        {
            continuationToken = token
        }

        let songs = Self.parseSongs(from: playlistContents)
        let tunerChips = Self.parseTunerChips(from: musicQueueRenderer)
        return RadioQueueResult(songs: songs, continuationToken: continuationToken, tunerChips: tunerChips)
    }

    /// Parses a continuation response for more queue items.
    /// - Parameter data: The continuation response
    /// - Returns: RadioQueueResult with additional songs and next continuation token
    static func parseContinuation(from data: [String: Any]) -> RadioQueueResult {
        guard let continuationContents = data["continuationContents"] as? [String: Any],
              let playlistPanelContinuation = continuationContents["playlistPanelContinuation"] as? [String: Any],
              let contents = playlistPanelContinuation["contents"] as? [[String: Any]]
        else {
            return RadioQueueResult(songs: [], continuationToken: nil)
        }

        // Extract next continuation token
        var continuationToken: String?
        if let continuations = playlistPanelContinuation["continuations"] as? [[String: Any]],
           let firstContinuation = continuations.first,
           let nextRadioData = firstContinuation["nextRadioContinuationData"] as? [String: Any],
           let token = nextRadioData["continuation"] as? String
        {
            continuationToken = token
        }

        let songs = Self.parseSongs(from: contents)
        return RadioQueueResult(songs: songs, continuationToken: continuationToken)
    }

    /// Parses songs from playlist panel contents.
    private static func parseSongs(from playlistContents: [[String: Any]]) -> [Song] {
        var songs: [Song] = []
        for item in playlistContents {
            // Handle both direct and wrapped renderer structures
            // Direct: item.playlistPanelVideoRenderer
            // Wrapped: item.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer
            let panelVideoRenderer: [String: Any]? = if let direct = item["playlistPanelVideoRenderer"] as? [String: Any] {
                direct
            } else if let wrapper = item["playlistPanelVideoWrapperRenderer"] as? [String: Any],
                      let primary = wrapper["primaryRenderer"] as? [String: Any],
                      let wrapped = primary["playlistPanelVideoRenderer"] as? [String: Any]
            {
                wrapped
            } else {
                nil
            }

            guard let panelVideoRenderer else {
                continue
            }

            // Extract videoId - required field
            guard let videoId = panelVideoRenderer["videoId"] as? String else {
                continue
            }

            let title = self.parseTitle(from: panelVideoRenderer)
            let artists = self.parseArtists(from: panelVideoRenderer)
            let thumbnailURL = self.parseThumbnail(from: panelVideoRenderer)
            let duration = self.parseDuration(from: panelVideoRenderer)

            let song = Song(
                id: videoId,
                title: title,
                artists: artists,
                album: nil,
                duration: duration,
                thumbnailURL: thumbnailURL,
                videoId: videoId
            )
            songs.append(song)
        }

        return songs
    }

    /// Parses the server-provided automix tuning row from `musicQueueRenderer`.
    ///
    /// Only chips that carry a complete tune request are kept, so the UI never renders an option
    /// it cannot apply.
    /// - Parameter musicQueueRenderer: The queue renderer from the "next" response.
    /// - Returns: The tuning chips, in server order; empty when the queue has no tuning row.
    static func parseTunerChips(from musicQueueRenderer: [String: Any]) -> [QueueTunerChip] {
        guard let chipCloud = musicQueueRenderer["subHeaderChipCloud"] as? [String: Any],
              let chipCloudRenderer = chipCloud["chipCloudRenderer"] as? [String: Any],
              let chips = chipCloudRenderer["chips"] as? [[String: Any]]
        else {
            return []
        }

        return chips.compactMap { item -> QueueTunerChip? in
            guard let chip = item["chipCloudChipRenderer"] as? [String: Any],
                  let label = Self.parseTunerChipLabel(from: chip),
                  let tuneRequest = Self.parseTunerChipRequest(from: chip)
            else {
                return nil
            }

            return QueueTunerChip(
                id: Self.parseTunerChipId(from: chip, fallback: label),
                label: label,
                isSelected: chip["isSelected"] as? Bool ?? false,
                playlistId: tuneRequest.playlistId,
                params: tuneRequest.params
            )
        }
    }

    /// Parses the chip's visible label, falling back to its accessibility label.
    private static func parseTunerChipLabel(from chip: [String: Any]) -> String? {
        if let text = chip["text"] as? [String: Any],
           let runs = text["runs"] as? [[String: Any]],
           let label = runs.first?["text"] as? String,
           !label.isEmpty
        {
            return label
        }

        guard let accessibility = chip["accessibilityData"] as? [String: Any],
              let inner = accessibility["accessibilityData"] as? [String: Any],
              let label = inner["label"] as? String,
              !label.isEmpty
        else {
            return nil
        }

        return label
    }

    /// Parses the chip's server identifier, falling back to its label.
    private static func parseTunerChipId(from chip: [String: Any], fallback: String) -> String {
        guard let uniqueId = chip["uniqueId"] as? String, !uniqueId.isEmpty else {
            return fallback
        }

        return uniqueId
    }

    /// Parses the tune request a chip issues (`queueUpdateCommand.fetchContentsCommand.watchEndpoint`).
    private static func parseTunerChipRequest(from chip: [String: Any]) -> (playlistId: String, params: String?)? {
        guard let navigationEndpoint = chip["navigationEndpoint"] as? [String: Any],
              let queueUpdateCommand = navigationEndpoint["queueUpdateCommand"] as? [String: Any],
              let fetchContentsCommand = queueUpdateCommand["fetchContentsCommand"] as? [String: Any],
              let watchEndpoint = fetchContentsCommand["watchEndpoint"] as? [String: Any],
              let playlistId = watchEndpoint["playlistId"] as? String,
              !playlistId.isEmpty
        else {
            return nil
        }

        return (playlistId, watchEndpoint["params"] as? String)
    }

    /// Parses the song title from the panel video renderer.
    private static func parseTitle(from renderer: [String: Any]) -> String {
        if let titleData = renderer["title"] as? [String: Any],
           let runs = titleData["runs"] as? [[String: Any]],
           let firstRun = runs.first,
           let text = firstRun["text"] as? String
        {
            return text
        }
        return "Unknown"
    }

    /// Parses artists from the panel video renderer's longBylineText.
    private static func parseArtists(from renderer: [String: Any]) -> [Artist] {
        var artists: [Artist] = []
        guard let bylineData = renderer["longBylineText"] as? [String: Any],
              let runs = bylineData["runs"] as? [[String: Any]]
        else { return artists }

        for run in runs {
            guard let text = run["text"] as? String,
                  text != " • ", text != " & ", text != ", ", text != " · "
            else { continue }

            let artistId: String = if let navEndpoint = run["navigationEndpoint"] as? [String: Any],
                                      let browseEndpoint = navEndpoint["browseEndpoint"] as? [String: Any],
                                      let browseId = browseEndpoint["browseId"] as? String
            {
                browseId
            } else {
                // Generate stable ID from artist name when no browse ID available
                ParsingHelpers.stableId(title: "artist", components: text)
            }
            artists.append(Artist(id: artistId, name: text))
        }
        return artists
    }

    /// Parses the thumbnail URL from the panel video renderer.
    private static func parseThumbnail(from renderer: [String: Any]) -> URL? {
        guard let thumbnail = renderer["thumbnail"] as? [String: Any],
              let thumbnails = thumbnail["thumbnails"] as? [[String: Any]],
              let lastThumb = thumbnails.last,
              let urlString = lastThumb["url"] as? String
        else { return nil }

        let normalizedURL = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        return URL(string: normalizedURL)
    }

    /// Parses the duration from the panel video renderer.
    private static func parseDuration(from renderer: [String: Any]) -> TimeInterval? {
        guard let lengthText = renderer["lengthText"] as? [String: Any],
              let runs = lengthText["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let text = firstRun["text"] as? String
        else { return nil }

        return ParsingHelpers.parseDuration(text)
    }
}
