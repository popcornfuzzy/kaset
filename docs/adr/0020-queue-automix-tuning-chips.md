# ADR-0020: Server-Driven Automix Tuning Row in the Queue

## Status

Accepted

## Context

YouTube Music's own clients let listeners retune an automix from the queue: a row of filter chips
("All", "Popular", "Discover", "Deep cuts", "Party", and genre chips like "Pop" / "R&B" / "Rock" in
the web client; the Android app words its own set differently, e.g. "Explore" and "Listen again").
Tapping one swaps the upcoming songs for a differently tuned mix.

Kaset already fetched exactly the response that carries this row — `getRadioQueue(videoId:)` and
`getMixQueue(playlistId:)` both call `next` with an `RDAMVM…` / `RDEM…` playlist — but
`RadioQueueParser` walked past `musicQueueRenderer.subHeaderChipCloud` and kept only the songs, so
the row was discarded.

Checking the endpoint (`api-explorer action next ...`, 2026-09-25) showed:

- The row is server data: the chip set, the labels, the tuned mix playlist IDs, and the opaque
  `params` that select each variant all arrive from the service.
- Each chip carries its own tune request in
  `navigationEndpoint.queueUpdateCommand.fetchContentsCommand.watchEndpoint`, including the
  selected default, and re-issuing `next` with it returns a genuinely different mix seeded from the
  same track (with its own infinite-mix continuation token).
- A re-tuned response does not repeat the row.
- The row is not something Kaset can compute locally, and its membership differs per client,
  account, locale, and experiment.

The alternatives were to hard-code a tuning list (impossible — the service does not offer the same
options everywhere, and there is nothing to send that reproduces a variant without the chip's
opaque params) or to leave the feature out.

## Decision

Treat the tuning row as server-driven data that Kaset renders rather than defines.

- `QueueTunerChip` models one chip: server `uniqueId`, label, selection, and the tuned mix
  `playlistId` + `params`.
- `RadioQueueResult` carries `tunerChips`, parsed by `RadioQueueParser.parseTunerChips(from:)`.
  Chips that lack a complete tune request are dropped so the UI never offers an option it cannot
  apply.
- `getRadioQueue(videoId:)` now returns `RadioQueueResult` instead of `[Song]`, and
  `getTunedMixQueue(playlistId:params:videoId:)` fetches a tuned variant. Both reuse the existing
  `next` endpoint; no new endpoint, WebView use, or dependency is introduced.
- `PlayerService` owns the row (`queueTunerChips`, `activeQueueTunerId`) and applies a chip by
  replacing the upcoming songs while the current track keeps playing: the track is re-seeded at
  index 0, `mixContinuationToken` is refreshed, and the change is recorded for queue undo. Playback
  is never restarted.
- A re-tuned response omits the row, so `PlayerService` keeps the existing row and only moves the
  selection to the tuned chip.
- Queues that are not automixes (playlists, albums, YouTube's own autoplay takeover) clear the row,
  so it can never tune a mix that is no longer loaded.
- `QueueTunerChipsView` renders the row in both queue presentations (popup and side panel), shows
  progress while a tuning is in flight, and disables itself meanwhile.

## Consequences

### Positive

- The queue offers the same tuning capability as YouTube Music's own clients, and it stays correct
  as the service changes its options — no client-side list to maintain.
- `RadioQueueResult` now carries everything the `next` queue response offers (songs, continuation,
  tuning), so future queue work has one place to read from.
- Tuning is undoable through the existing queue history and never interrupts playback.

### Negative

- Chip labels arrive in the service's own language and are not localized by Kaset.
- The tuned queue cannot be re-derived from the mix alone: once YouTube's autoplay takes over or the
  queue is restored from persistence, the row is gone until the next automix is fetched.
- `getRadioQueue(videoId:)` changed its return type, so every caller and mock had to be updated.

### Neutral

- `tunerSettingValue: AUTOMIX_SETTING_NORMAL` remains the only tuner setting Kaset sends; the tuning
  itself is expressed by the chip's playlist ID and params.
- The row renders in both queue presentations, so it is also in the switcher UI tests' accessibility
  tree (`queueView.tunerRow`, `queueView.tunerChip.<id>`).
