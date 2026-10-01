# ADR-0028: Song/Video Variant Matching

## Status

Accepted

## Context

A track on YouTube Music often exists twice: as an audio "song" (`MUSIC_VIDEO_TYPE_ATV`) and as
the official music video (`MUSIC_VIDEO_TYPE_OMV`). Playlists, radio mixes and YouTube autoplay
routinely put the video variant in the queue. The video variant disrupts listening:

- the now-playing artwork becomes the video still instead of the album cover;
- the audio is the video's mix/master, which can differ from the song release;
- the queue and history show a different track than the user thinks they are playing.

Kaset is an audio player that shows music in a small PiP-style miniplayer. The goal is for the
song version to play **everywhere** (queue, direct play, radio/mix, session restore) with its
album art, while the video stays available for the miniplayer when the user asks for it.

## Decision

Play the **audio (song) variant** wherever a track has one, and remember the paired video as the
entry's *counterpart*. Surface the video only through the miniplayer.

### Where the pairing comes from

The `next` and `music/get_queue` responses wrap a paired track as a
`playlistPanelVideoWrapperRenderer`:

```
playlistPanelVideoWrapperRenderer
  primaryRenderer.playlistPanelVideoRenderer        -> the entry that plays
  counterpart[0].counterpartRenderer.playlistPanelVideoRenderer -> the other variant
```

This is the data behind YouTube Music's own song/video switcher. The counterpart carries its own
`videoId`, title, byline, thumbnail and `musicVideoType`. Parsing it is deterministic — no title
heuristics. `PlaylistPanelItemParser` extracts both sides, and `RadioQueueParser`,
`PlaylistParser` and `SongMetadataParser` attach the counterpart and the `musicVideoType`.

In practice the public API does not always include the counterpart (verified with
`swift run api-explorer variants <videoId>`): a radio of music videos came back with no
counterparts, and the per-track `next` response did not include one either. So a second source is
needed.

### Backfill by filtered search

For a video entry with no counterpart, `SongVariantMatcher` searches the filtered song catalogue
(`searchSongs`, which excludes videos) with the title plus primary artist, then scores candidates
on normalized title, artist overlap and duration. A title-equal, artist-equal, length-equal match
is accepted; a same-title/different-artist result (a cover) is rejected. Results are cached by
video id, and lookups that found nothing are remembered so a track is not retried on every pass.

Resolution happens **ahead of playback**, for the next `variantResolutionWindow` (4) queue
entries, so a video is swapped for its song before it starts. Entries that arrive already paired
cost no extra request.

### Model

`Song` cannot recursively store a `Song`, so the pairing is a flat `SongCounterpart`
(`videoId`, title, artists, duration, thumbnail, `musicVideoType`). `Song.counterpart` holds the
*other* variant. `SongVariantMatcher.audioPreferred(_:)` returns the entry to play, carrying the
video as its counterpart when one was chosen.

### Playback and the miniplayer

- Every queue entry point (`playQueue`, `playWithRadio`, `playWithMix`, radio application,
  infinite-mix continuations, insert/append, tuner chips, session restore) runs songs through the
  matcher, and `play(song:)`/`play(videoId:)` always load the audio variant.
- A known video counterpart makes `currentTrackHasVideo` true, so the miniplayer's existing
  `prefersVideo` path clicks YouTube's "Video" tab when the miniplayer is expanded. The page then
  reports the video's id; `canonicalPlaybackVideoId(for:)` folds that observation back onto the
  song entry so `PlayerService+WebQueueSync` does not treat the switch as queue drift and does not
  replace the album art with the video still.
- `SettingsManager.preferAudioVersionsEnabled` (General → "Prefer Audio (Song) Versions", default
  on) gates the whole behavior. When off, Kaset plays whatever the API returns, as before.

## Consequences

- Matched tracks show the song's album art in the bar, queue and fullscreen views; the video is
  one miniplayer toggle away.
- The queue and history now reference the song's video id. Like/library state is fetched for that
  id; a rating made against the video variant does not follow automatically.
- Backfilling costs one filtered search per unmatched video entry, bounded by the resolution
  window and the per-id cache. Playlists that are already songs cost nothing.
- A video with no song counterpart is left untouched, and a region-blocked song variant falls back
  to the video (logged, not silent).
- The counterpart is persisted with the queue (`SongCounterpart` is `Codable`); sessions saved
  before this feature simply decode without one.

## Alternatives considered

- **Counterpart only.** Rejected: the public API frequently omits it, which would leave the very
  tracks this feature targets unmatched.
- **Title/artist heuristics only (no counterpart).** Rejected as the primary source: less precise
  than the switcher data, which is exact when present.
- **Rewrite browse/search list thumbnails too.** Out of scope: matching is applied at playback,
  not to every browse shelf.
