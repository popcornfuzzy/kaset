# ADR-0027: Player WebView Preload and the Player Bar Loading Strip

## Status

Accepted

## Context

Kaset plays audio through one hidden `WKWebView` (see [playback.md](../playback.md)). The WebView was
created on the user's first press of play, and that press paid for all of it at once: the WebView and
its configuration (ad-blocking, observer and media-override user scripts), the YouTube Music document,
the JS bundle, the service worker, and the DRM/cookie machinery — several seconds of work landing
exactly when the user asked for music, on an app that has been up and looked ready for a while. Every
later track change was cheap (the same page, one navigation); only the first one was slow, which is
why it read as a bug rather than as a wait.

There was nothing on screen for that wait in either case. The player bar sat in its empty state while
the WebView loaded a watch page, and again after the document was up while YouTube worked through ads,
stream selection and DRM before audio actually started. The two waits are different in kind: the page
load has a fraction WebKit reports itself, the start-up wait has nothing to measure at all.

## Decision

### Preload a page at launch

`MainWindow` hosts the player layer as soon as `AuthService` reports a signed-in session, not only
when `pendingPlayVideoId` is set, and hands `PersistentPlayerView` the pending video id (`nil` when
there is none). The representable then gives the empty WebView one of two pages:

- **The active track's watch page**, when a session restored a song that has not been resumed. This is
the case that matters: the restored session knows its track and its position, so the page the first
press of play would have loaded is loaded there and then — held silent, and pointed at the resume
position through YouTube's own `t` parameter, so the press starts the song instead of navigating to it.
- **The YouTube Music shell** (`https://music.youtube.com/`), when there is no track to be ready for.
  The cheapest page that warms the app's JS, caches and DRM machinery.

The rules are pure and unit-tested (`PlayerWebViewPreload`): host the layer when signed in or when a
video is pending; which page to load; and what may still be loaded into what.

### Keep a preloaded page silent

Kaset sets `mediaTypesRequiringUserActionForPlayback = []` — that is what makes playback work at all —
so a watch page left to itself starts playing the moment it is up. A page loaded only to be ready
must not: it would be audio the user did not ask for, on a track the app is deliberately not tracking
yet. Such a page carries a `kaset_preload=1` query flag, and a document-start gate
(`SingletonPlayerWebView.preloadGateScript`) reads it and swallows the page's own `play()` calls. The
hold is lifted by every control Kaset drives (`releasePreloadHold()`), by the first click or keystroke
the user makes in the page (the mini player *is* the page's controls), and by revealing the mini
player.

Lifting the hold also realigns the page: YouTube's player was told playback started and would
otherwise take the next play/pause click as a *pause*.

### A page that is not being played from must not report

`SingletonPlayerWebView.page` records what the page is for — `empty`, `shell`, `preloaded`,
`playback` — and what each of those may report is one scale, `PlayerWebViewObservation`:

| Page | May report |
|------|------------|
| `empty`, `shell` | Nothing |
| `preloaded` | Which track it is holding: title, artist, artwork, video id |
| `playback` | That, plus everything about its player |

The shell has no track at all. A preloaded page is a player that was told it started when its autoplay
was swallowed, so its position, duration and playing flag describe a performance that never happened,
and its queue and end-of-track signals would drive `next()` and `play()` from a page that is
deliberately quiet; believing any of it would put a track that is not playing into the app's state and
would zero the progress and duration a restored session is showing. Those messages never reach the
service.

Its *metadata* is a different matter, and it is the reason the scale has a middle rung. Which song the
page is showing — and how YouTube itself renders its title and artist — is the same observation a
playing page makes, and it is what the artist separator normalization, the lyrics gate
(`observedWebMetadata`) and the artwork fallback have been waiting for. The coordinator routes it to
`PlayerService.reconcilePreloadedTrackMetadata`, which is deliberately narrower than
`updateTrackMetadata`: it normalizes the artist, publishes the complete observation, refines the
playback kind, takes the page's artwork when the held track has none, and writes the page's title and
artist over the held row's — and no more. The queue stays the authority on what is playing, on the
order and on everything that makes its row richer (album, duration, like state); the divergence
handlers that drive the queue are never fed from a silent page.

The title and artist are the exception, and they are the reason the rung exists at all. Shelf rows carry
the album and year as extra artist entries, so a row's display ("SXTN, Leben am Limit, 2017") can never
equal the player-bar byline ("SXTN") — and a restored session showed the row. Pressing play corrected it,
by replacing the track with the page's own rendering; at rest nothing did. The preload *is* that page, so
it makes the same correction before the first press. It only does so when the page also says *which video*
it is describing and it is the held one: a shell, a page still settling or an ad reports a byline that can
belong to anything, and is left to describe only the artwork. Without any of this, a restored session's
first song reached play without ever having been described, its lyrics panel stayed empty until then, and
its artist line disagreed with itself before and after the first press.

The same model answers the other two questions: a preload that has *finished* counts as loaded, so a
resume plays it instead of navigating (`canPlay(videoId:)`); one still in flight does not, and the
track is loaded properly — which cancels the held load rather than asking a document that does not
exist yet to play, the case that would otherwise leave a resumed track silent.

### Instrument the page load, and derive the strip from it

The WebView's navigation delegate reports into `PlayerService`:
`didStartProvisionalNavigation` starts a load, `estimatedProgress` (observed with KVO) updates it,
and `didFinish`/`didFailProvisionalNavigation`/a terminated content process end it. The fraction is
quantized (`PlayerService.webViewPageLoadQuantum`) because WebKit reports progress on every frame of a
load and an `@Observable` write per frame redraws everything reading the service.

`PlayerBarLoadingRule` turns that plus `state == .loading` — already, exactly, "playback has been asked
for and the observer has not reported it playing" — into what the bar draws:

| Situation | Strip |
|-----------|-------|
| A page load with a fraction (the preload, a track change) | `.determinate`: fills left to right |
| Playback asked for, audio not started | `.indeterminate`: pulses across its whole length |
| The tail after a page load ended (4s) | `.indeterminate`: pulses across its whole length |
| Everything else | No strip at all |

A page load outranks the others: it is the measured answer while it lasts.

The third row is what makes the strip work at launch. The preload starts as soon as the app is signed in
and is often over before the window has finished appearing, so a stripe that ends with the load is a flash
nobody sees — indistinguishable from a bar that never had one. The tail is **fixed** rather than "the
remainder of a minimum": a load that took three seconds still gets one, which is exactly the case the
window is late for. Playing the track ends it, the next navigation takes it over, and a load that ends
after playback started leaves none behind at all.

### One press resumes a restored session

A restored session is inert until the user asks for it — but `resume()` is only ever reached *because*
something asked: the play button, a media key, AppleScript. It used to gate starting playback on the
user having interacted with the WebView earlier, which made the first press after launch seek and then
sit paused, needing a second press. It now resumes, which is what the press meant.

### Draw it in the bar

`PlayerBarLoadingWash` fills the player bar's **own capsule** — that shape is its mask — and is drawn in
the glass's content *under* the bar's controls, so the whole bar takes on a light grey while it works and
nothing the user is reaching for is covered or moved. A stripe of a few points pinned to the bar's top
edge was tried first and abandoned: over the light bar's glass it was too easy to miss, and a line beside
the controls says "something else is loading", where a wash under them says "this bar is still working".

It is drawn in the bar's **foreground colour** (`Color.primary`), not the brand accent: the accent
disappeared into the light bar's glass, while `primary` is grey on the light bar and a light lift on the
dark one, so the wash always reads against the surface it is in a wash of. Where the load has reached it
deepens from the leading end, and the rest of the capsule stays faintly washed, so the bar is up from the
first frame of a load.

The wash **pulses** — a `phaseAnimator` between roughly half and full opacity on a 1.1s cycle — and the
pulse is the one part of it that is always there: it is what a wait with nothing to measure is drawn as,
and it means an appearance too brief to catch still reads as the bar working. Under Reduce Motion the
fraction still fills (it is the information) while the pulse becomes a steady tint.

The strip is not a second progress bar: it is thinner than the track's own scrubber, sits above the
bar's content, and disappears the moment there is nothing to wait for.

## Consequences

### Positive

- A session that restores a track has that track's page loaded before the user asks for it: the first
  play starts the song instead of navigating to it, and the position comes from the session rather than
  from a seek afterwards.
- That track is also fully described before it is played: its artist byline is normalized and its
  artwork is filled in from the page, so the first frame of playback — and the lyrics panel that opens
  with it — already has what the WebView will report a second later anyway.
- The first play of a session with no restored track navigates into an app whose JS, caches and DRM
  machinery are already warm.
- Both waits are now visible in one place, and the one with a real fraction is drawn as a fraction.
- The preload, page-purpose and loading rules are pure and testable (`PlayerBarLoadingTests`), and the
  observed state lives on `PlayerService` where the bar already reads it — no second channel into the
  UI.

### Negative

- A WebView, a page load and (with a restored track) a watch page's player boot happen at every launch
  for a signed-in user, whether or not anything is played: memory, network and CPU the app did not
  previously spend at idle.
- A preloaded track buffers media the user may never play.
- The manually-toggled mini player shows the preloaded page (or the YouTube Music home) instead of a
  blank box.
- `estimatedProgress` is WebKit's estimate, so the strip can sit near the end of a slow load; it is
  quantized and only ever cosmetic.
- A play request that arrives while a preload is still loading falls back to an ordinary load: correct,
  but it gives back the wait the preload was there to remove.

### Neutral

- Autoplay policy is unchanged: a watch page still starts playback by itself, which is why the shell is
  a home page rather than a preloaded track.
- The observer, volume, ad-blocking and media-override scripts run on the shell as they do on any
  page; only the shell's *messages* are ignored.
