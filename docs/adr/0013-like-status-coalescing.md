# ADR-0013: Coalesced, Cancellable Like/Dislike Rating Pipeline

## Status
Accepted

## Context

The thumbs up / thumbs down buttons call `PlayerService.likeCurrentTrack()` /
`dislikeCurrentTrack()`, which optimistically update `currentTrackLikeStatus` and then
spawn an unstructured `Task` that awaits `SongLikeStatusManager.like/unlike` → `rate()`.
`rate()` wrote the cache, published a `lastLikeEvent`, and fired exactly one
`client.rateSong()` HTTP request per click — with no cancellation, ordering, coalescing,
or retry.

This caused three problems:

1. **Rapid-click race.** Every click spawned its own request. A like followed quickly by
   an unlike sent two racing HTTP requests; the server could settle in the wrong state and
   the UI reflected whichever response arrived last, not the user's last intent.
2. **Stale rollback.** On failure, `rate()` restored the status captured at the *start of
   that call* — which could clobber a newer, still-in-flight action.
3. **No resilience.** A transient network failure silently dropped the user's rating; there
   was no retry and no way to cancel an in-flight request.

## Decision

Rework the internals of `SongLikeStatusManager.rate()` into a **coalesced, cancellable
pipeline**. The public API (`like/unlike/dislike/undislike`, `status/setStatus`) is
unchanged, so `PlayerService` and `AddToPlaylistPopoverButton` keep their call sites.

- **Bursts & sequences.** Each `(accountID, videoId)` pair has at most one in-flight
  "burst". Every new intent folds into the existing burst, bumps its sequence number, and
  cancels the previous intent's network `Task`. Only the intent with the latest sequence
  may settle state.
- **Debounce.** The HTTP send is delayed by a short debounce (`ratingDebounce`, default
  150 ms). If a newer intent arrives during the window, the older one aborts without
  sending. A rapid like→unlike therefore issues at most one request — and zero if the
  final intent equals the pre-burst state.
- **Bounded retry.** Transient failures are retried with backoff (`ratingRetryDelays`,
  default 2 retries at 0.5 s / 1.5 s). `YTMusicError.isRetryable == false` (auth, parse,
  invalid input) and cancellation skip retrying.
- **Baseline rollback.** The burst records the cache value *before* the first intent as
  its baseline. On final failure (retries exhausted) the cache rolls back to the baseline —
  not to the previous optimistic write — because earlier intents in the burst may never
  have reached the server.
- **Supersede-safe settle.** `rate()` returns the cache-current status when the caller's
  intent settles, so a superseded caller harmlessly reports the newer intent's state.
  `PlayerService`'s completion already guards on account + track match and now writes only
  when the value actually changed, avoiding redundant observation notifications.

### Deliberate deviation from the project's cancellation rule

`docs/common-bug-patterns.md` recommends rolling back the optimistic update on
`CancellationError`. In the coalesced pipeline, cancellation of a request task almost
always means a *newer intent superseded it*, so the newer intent owns the state and no
rollback is correct. Rollback on cancellation still happens in the one case where nothing
superseded the intent: the caller's own task being cancelled during the debounce window
(before any request is sent).

## Consequences

### Easier

- Rapid toggling is reliable: the server receives exactly the user's last intent, and the
  UI can no longer be clobbered by a stale completion.
- Transient network failures no longer silently drop ratings; bounded retries recover
  automatically and the button holds its state during the retry window.
- Fewer network requests under rapid interaction (coalescing + cancellation), and fewer
  redundant state writes per click.

### Harder

- The pipeline's timing behavior (debounce + retries) makes unit tests time-sensitive;
  the knobs (`ratingDebounce`, `ratingRetryDelays`) are `@ObservationIgnored` test seams.
- On a dead network the button now holds the liked state for roughly the retry window
  (~2 s) before reverting, instead of reverting instantly.
- The inherent HTTP last-write-wins limit remains: if a cancelled request's bytes already
  reached the server, a subsequent request is the source of truth; a rare divergence can
  self-heal on the next metadata fetch.
