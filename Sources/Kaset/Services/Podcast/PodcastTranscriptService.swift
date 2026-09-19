import Foundation
import Observation

// MARK: - PodcastTranscriptService

/// Loads and caches the timed transcript of the podcast episode that is playing.
///
/// Mirrors ``SyncedLyricsService``: one request per episode, results for an episode that is no
/// longer current are discarded by generation, and parsed transcripts are cached for the session.
@MainActor
@Observable
final class PodcastTranscriptService {
    /// Transcript for ``transcriptVideoId``, or `.unavailable` while loading or without captions.
    var transcript: PodcastTranscript = .unavailable

    /// Episode the current ``transcript`` belongs to.
    private(set) var transcriptVideoId: String?

    /// Whether a transcript request is in flight.
    private(set) var isLoading = false

    /// Human-readable reason why the current episode has no transcript, if any.
    private(set) var errorMessage: String?

    private let client: any YTMusicClientProtocol
    private var cache: [String: PodcastTranscript] = [:]
    private var generation = 0

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    /// Whether a transcript is on screen for the given episode.
    func hasTranscript(for videoId: String?) -> Bool {
        guard let videoId else { return false }
        return self.transcriptVideoId == videoId && self.transcript.isAvailable
    }

    /// Loads the transcript for an episode, reusing the session cache unless `forceRefresh` is set.
    ///
    /// Safe to call concurrently for different episodes: only the newest request may publish its
    /// result, so a slow request for a previous episode can never replace the current one.
    func loadTranscript(for videoId: String, forceRefresh: Bool = false) async {
        guard !videoId.isEmpty else { return }

        // Already showing this episode: keep it instead of re-requesting on every re-render.
        if !forceRefresh, self.transcriptVideoId == videoId, self.transcript.isAvailable {
            return
        }

        if !forceRefresh, let cached = cache[videoId] {
            self.generation += 1
            self.apply(cached, videoId: videoId, requestID: self.generation)
            return
        }

        self.generation += 1
        let requestID = self.generation

        self.transcript = .unavailable
        self.transcriptVideoId = nil
        self.errorMessage = nil
        self.isLoading = true

        do {
            let transcript = try await client.getPodcastTranscript(
                videoId: videoId,
                preferredLanguageCode: Self.currentLanguageCode()
            )

            guard !Task.isCancelled, requestID == self.generation else { return }
            self.cache[videoId] = transcript
            self.apply(transcript, videoId: videoId, requestID: requestID)
        } catch {
            guard !Task.isCancelled, requestID == self.generation else { return }
            Self.logger.error("Podcast transcript failed for \(videoId): \(error.localizedDescription)")
            self.isLoading = false
            self.errorMessage = Self.message(for: error)
        }
    }

    /// Clears the displayed transcript (used when the experience is dismissed).
    ///
    /// The session cache is intentionally kept: reopening the same episode must not refetch.
    func reset() {
        self.generation += 1
        self.transcript = .unavailable
        self.transcriptVideoId = nil
        self.isLoading = false
        self.errorMessage = nil
    }

    private func apply(_ transcript: PodcastTranscript, videoId: String, requestID: Int) {
        guard requestID == self.generation else { return }
        self.transcript = transcript
        self.transcriptVideoId = videoId
        self.isLoading = false
        self.errorMessage = transcript.isAvailable
            ? nil
            : String(localized: "No transcript is available for this episode.")
    }

    private static func message(for error: Error) -> String {
        if let ytMusicError = error as? YTMusicError {
            return ytMusicError.userFriendlyMessage
        }
        return error.localizedDescription
    }

    private static func currentLanguageCode() -> String? {
        Locale.current.language.languageCode?.identifier
    }

    private static let logger = DiagnosticsLogger.api
}
