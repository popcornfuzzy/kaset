import Foundation

// MARK: - SongVariantMatcher

/// Matches music-video tracks with their song-only (audio) counterparts.
///
/// Kaset plays the song version everywhere: the queue, direct play, radio/mix and session
/// restore all resolve to the audio variant, which is what shows the album art. The video
/// variant is remembered as the entry's `counterpart` so the PiP miniplayer can switch to
/// it on demand.
///
/// The pairing comes from two sources, in order:
/// 1. The `playlistPanelVideoWrapperRenderer.counterpart` that some watch/queue responses
///    carry (the same data behind YouTube Music's song/video switcher).
/// 2. Filtered song search, used to backfill entries whose response carried no counterpart.
///
/// Resolution is cached per video id, and failures are remembered so a track is not retried
/// on every queue pass.
@MainActor
final class SongVariantMatcher {
    private let logger = DiagnosticsLogger.player

    /// Audio variants resolved from a video entry, keyed by the *video* video id.
    private var audioByVideoId: [String: Song] = [:]
    /// Video variants paired with an audio entry, keyed by the *audio* video id.
    private var videoByAudioVideoId: [String: Song] = [:]
    /// Video ids that were looked up and produced no match, so they are not retried.
    private var unresolvedVideoIds: Set<String> = []
    /// Video ids currently being resolved, to coalesce concurrent passes.
    private var inFlight: Set<String> = []

    // MARK: - Selection

    /// Returns the entry that should play: the song/audio variant when the track has one.
    ///
    /// The result carries the video variant as `counterpart` (when known) so the PiP toggle
    /// can switch to it.
    func audioPreferred(_ song: Song) -> Song {
        if song.isVideoVariant {
            // A wrapper may already carry the song as its counterpart.
            if let counterpart = song.counterpart, !counterpart.isVideoVariant {
                return counterpart.asSong.paired(with: song)
            }
            if let resolved = self.audioByVideoId[song.videoId] {
                return resolved.paired(with: song)
            }
            // No song variant known: the video is all there is.
            return song
        }

        // Already a song; record its video counterpart when one is known.
        if let counterpart = song.counterpart, counterpart.isVideoVariant {
            return song.paired(with: counterpart)
        }
        if let video = self.videoByAudioVideoId[song.videoId] {
            return song.paired(with: video)
        }
        return song
    }

    /// The video variant to play for PiP, if the audio-preferred entry has one.
    func videoVariant(of song: Song) -> Song? {
        if song.isVideoVariant { return song }
        if let counterpart = song.counterpart, counterpart.isVideoVariant {
            return counterpart.asSong
        }
        return self.videoByAudioVideoId[song.videoId]
    }

    /// Rewrites a batch of songs to their audio-preferred variants, dropping duplicates that
    /// collapse to the same entry (e.g. a playlist listing both the song and its video).
    func normalize(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        var result: [Song] = []
        result.reserveCapacity(songs.count)

        for song in songs {
            let preferred = self.audioPreferred(song)
            guard seen.insert(preferred.videoId).inserted else {
                self.logger.debug("Dropped duplicate variant for \(preferred.videoId)")
                continue
            }
            result.append(preferred)
        }

        return result
    }

    // MARK: - Resolution

    /// Video entries in `songs` that still need a counterpart resolved.
    func pendingResolutions(in songs: [Song]) -> [Song] {
        songs.filter { song in
            guard song.isVideoVariant else { return false }
            guard song.counterpart == nil else { return false }
            guard self.audioByVideoId[song.videoId] == nil else { return false }
            guard !self.unresolvedVideoIds.contains(song.videoId) else { return false }
            return true
        }
    }

    /// Resolves the audio counterpart of a video entry using filtered song search.
    ///
    /// - Returns: The matched audio song, or `nil` when nothing matched.
    @discardableResult
    func resolveAudioVariant(for videoSong: Song, client: (any YTMusicClientProtocol)?) async -> Song? {
        guard videoSong.isVideoVariant else { return nil }
        if let cached = self.audioByVideoId[videoSong.videoId] { return cached }
        if self.unresolvedVideoIds.contains(videoSong.videoId) { return nil }
        guard let client else { return nil }
        guard self.inFlight.insert(videoSong.videoId).inserted else { return nil }
        defer { self.inFlight.remove(videoSong.videoId) }

        let query = Self.searchQuery(for: videoSong)
        guard !query.isEmpty else {
            self.unresolvedVideoIds.insert(videoSong.videoId)
            return nil
        }

        do {
            let candidates = try await client.searchSongs(query: query)
            guard let match = Self.bestAudioMatch(for: videoSong, candidates: candidates) else {
                self.logger.info("No song counterpart found for video \(videoSong.videoId) ('\(videoSong.title)')")
                self.unresolvedVideoIds.insert(videoSong.videoId)
                return nil
            }

            self.audioByVideoId[videoSong.videoId] = match
            self.videoByAudioVideoId[match.videoId] = videoSong.strippingCounterpart()
            self.logger.info(
                "Matched video \(videoSong.videoId) to song \(match.videoId) ('\(match.title)')"
            )
            return match
        } catch {
            self.logger.warning("Failed to resolve counterpart for \(videoSong.videoId): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Matching

    /// Builds the search query for a video entry: a bracket-free title plus its primary artist.
    static func searchQuery(for song: Song) -> String {
        let title = Self.strippingBrackets(song.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = song.artists.first?.name ?? ""
        guard !artist.isEmpty else { return title }
        return title.isEmpty ? artist : "\(title) \(artist)"
    }

    /// Picks the best audio-only candidate for a video entry, or `nil` when none is confident.
    static func bestAudioMatch(for target: Song, candidates: [Song]) -> Song? {
        let targetTitle = Self.normalizedTitle(target.title)
        guard !targetTitle.isEmpty else { return nil }

        let targetArtists = Set(target.artists.map { Self.normalizedArtist($0.name) }.filter { !$0.isEmpty })

        var best: Song?
        var bestScore = 0.0

        for candidate in candidates {
            guard candidate.videoId != target.videoId, !candidate.isVideoVariant else { continue }

            let candidateTitle = Self.normalizedTitle(candidate.title)
            var score = 0.0

            if candidateTitle == targetTitle {
                score += 0.55
            } else if !candidateTitle.isEmpty,
                      candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle)
            {
                score += 0.25
            } else {
                continue
            }

            let candidateArtists = Set(candidate.artists.map { Self.normalizedArtist($0.name) }.filter { !$0.isEmpty })
            if !targetArtists.isEmpty, !candidateArtists.isEmpty {
                if candidateArtists == targetArtists {
                    score += 0.25
                } else if !candidateArtists.isDisjoint(with: targetArtists) {
                    score += 0.15
                } else {
                    // A different artist with the same title is a cover or remix, not the song.
                    score -= 0.4
                }
            }

            if let targetDuration = target.duration, let candidateDuration = candidate.duration {
                let delta = abs(targetDuration - candidateDuration)
                if delta <= 2 {
                    score += 0.2
                } else if delta <= 6 {
                    score += 0.1
                } else {
                    score -= 0.15
                }
            }

            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }

        return bestScore >= 0.7 ? best : nil
    }

    /// Normalizes a title for comparison: folds case/diacritics, drops bracketed suffixes and
    /// common video/audio qualifiers, and reduces to alphanumeric tokens.
    static func normalizedTitle(_ title: String) -> String {
        var text = title
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        text = Self.strippingBrackets(text)
        text = text.replacingOccurrences(
            of: #"\b(official|video|audio|lyric|lyrics|hd|hq|4k|mv|m/v|remaster|remastered|visualizer|explicit|version)\b"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes an artist name for comparison.
    static func normalizedArtist(_ name: String) -> String {
        name
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes parenthesized and bracketed segments, e.g. "Song (Official Video)" -> "Song".
    private static func strippingBrackets(_ text: String) -> String {
        text.replacingOccurrences(of: #"[\(\[]\s*[^\)\]]*\s*[\)\]]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
