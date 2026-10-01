import Foundation

// MARK: - PlaylistPanelItemParser

/// Parses `playlistPanelVideoRenderer` items from the `next` and `music/get_queue` endpoints.
///
/// A track that has both a song and a music-video version is delivered by YouTube Music as a
/// `playlistPanelVideoWrapperRenderer` carrying a `primaryRenderer` and an optional
/// `counterpart[].counterpartRenderer`. The counterpart is the UI's song/video switcher: it
/// identifies the paired variant so Kaset can play the song version while remembering the video.
enum PlaylistPanelItemParser {
    /// The primary and optional counterpart renderers inside one panel item.
    struct Renderers {
        let primary: [String: Any]
        let counterpart: [String: Any]?
    }

    /// Extracts the primary renderer and, when the item is a wrapper, its counterpart.
    /// Handles both the direct and `playlistPanelVideoWrapperRenderer` shapes.
    static func renderers(from item: [String: Any]) -> Renderers? {
        if let direct = item["playlistPanelVideoRenderer"] as? [String: Any] {
            return Renderers(primary: direct, counterpart: nil)
        }

        guard let wrapper = item["playlistPanelVideoWrapperRenderer"] as? [String: Any],
              let primary = (wrapper["primaryRenderer"] as? [String: Any])?["playlistPanelVideoRenderer"] as? [String: Any]
        else {
            return nil
        }

        return Renderers(primary: primary, counterpart: counterpartRenderer(in: wrapper))
    }

    /// The counterpart `playlistPanelVideoRenderer` of a wrapper, when one is present.
    static func counterpartRenderer(in wrapper: [String: Any]) -> [String: Any]? {
        guard let counterparts = wrapper["counterpart"] as? [[String: Any]],
              let first = counterparts.first,
              let counterpartRenderer = first["counterpartRenderer"] as? [String: Any]
        else {
            return nil
        }
        return counterpartRenderer["playlistPanelVideoRenderer"] as? [String: Any]
    }

    /// Builds a minimal `Song` from a panel renderer. Menu data (feedback tokens, library and
    /// like status) is intentionally omitted here: it is only meaningful for the entry that is
    /// about to play, which the metadata fetch supplies.
    static func song(fromRenderer renderer: [String: Any]) -> Song? {
        guard let videoId = renderer["videoId"] as? String else { return nil }

        return Song(
            id: videoId,
            title: SongMetadataParser.parseTitle(from: renderer),
            artists: songArtists(from: renderer),
            album: nil,
            duration: SongMetadataParser.parseDuration(from: renderer),
            thumbnailURL: SongMetadataParser.parseThumbnail(from: renderer),
            videoId: videoId,
            musicVideoType: SongMetadataParser.parseMusicVideoType(from: renderer)
        )
    }

    /// Artists for a panel renderer, preferring the full byline and falling back to the short one
    /// used by some queue renderers.
    private static func songArtists(from renderer: [String: Any]) -> [Artist] {
        let artists = SongMetadataParser.parseArtists(from: renderer)
        guard artists.isEmpty, let shortByline = renderer["shortBylineText"] as? [String: Any] else {
            return artists
        }

        var withLongByline = renderer
        withLongByline["longBylineText"] = shortByline
        return SongMetadataParser.parseArtists(from: withLongByline)
    }
}
