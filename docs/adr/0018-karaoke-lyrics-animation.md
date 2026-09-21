# ADR-0018: Karaoke Lyrics Animation (Word-by-Word Fill)

## Status

Accepted

## Context

Word-synced lyrics arrived with ADR-0013, and `SyncedLyricsDisplayView` rendered them by rebuilding an
`AttributedString` on every playback sample: each word got a binary colour (`progress > 0 ? 1 : 0.30`)
with an 80 ms linear animation attached to `currentTimeMs`.

That reads as chunky rather than sung, for three reasons:

1. **Whole-word steps.** A word switches colour all at once instead of filling across itself, so the eye
   sees words blink rather than a highlight travelling through the line.
2. **A 10 Hz clock.** The only playback position available for lyrics is the hidden WebView's
   `LYRICS_TIME` poll, which reports every 100 ms (`SingletonPlayerWebView+ObserverScript.swift`).
   Rendering straight from those samples steps once per poll, and a late, dropped or out-of-order
   sample stalls the highlight and then jumps it.
3. **No shape to the motion.** There is no leading edge, no glow, no emphasis on the word being sung,
   and no sense of the line settling as it becomes current.

The bar to hit is Apple Music's karaoke presentation: an edge that sweeps continuously through each
word, a soft glowing head, the word being sung swelling slightly, and surrounding lines receding out
of focus.

Constraints:

1. **No new settings.** The animation is always on; it honours the system Reduce Motion setting and
   nothing else. (A user-facing toggle and a lyric sync offset were considered and deliberately
   rejected for this change.)
2. **The high-frequency clock stays where it is.** Playback lives in the hidden WebView, and 10 Hz
   polling is the available signal; the fix belongs in how that signal is used, not in polling more.
3. **Both lyric surfaces.** The 280 pt sidebar panel and the fullscreen lyrics must animate, tuned per
   surface (the panel carries a lighter glow).
4. **Localisation-safe.** Arabic (RTL) and CJK lyrics must fill the way they read.
5. **No third-party dependencies, Swift 6 concurrency only.** Per-frame work must stay small.

## Decision

Three pieces, each independently testable: a display clock, a fill model, and a renderer.

### 1. `LyricsPlaybackClock` — interpolation and jitter absorption

`Sources/Kaset/Models/LyricsPlaybackClock.swift`

The clock is fed `LyricsClockSample` values (`hostTime`, `timeMs`, `isPlaying`) as they arrive, and
`advance(to:)` is called once per display frame from a `TimelineView(.animation)`. It:

- **advances on its own between samples**, so 10 Hz input renders as continuous motion;
- **absorbs sample error by changing its own rate**, not by jumping. Error is divided by a 250 ms
  correction window and clamped to ±40% of nominal speed, so a sample that lands 120 ms late costs a
  brief catch-up rather than a visible skip, and a steady stream carries no tracking lag;
- **snaps** when a sample disagrees by more than 400 ms (a seek, or a new track getting its first
  sample) and on explicit `reset()`;
- **freezes** when `isPlaying` is false, driven by an `onChange(of: isPlaying)` rather than by waiting
  for a new sample, because the poll keeps reporting the same position while paused;
- **never runs backwards**: only a seek moves the display position back, so the fill never un-fills;
- caps both its extrapolation (2 s) and a single frame's delta (100 ms), so a stalled poll cannot race
  the highlight down the page and a rendering hitch cannot teleport it.

It is deliberately **not** `@Observable`: it is mutated inside `TimelineView`'s update, and publishing
that would invalidate the view hierarchy every frame.

### 2. `KaraokeFillModel` — timings in, fill fractions out

`Sources/Kaset/Models/KaraokeFillModel.swift`

Pure, SwiftUI-free, so the timing behaviour is unit-testable. `words(for:)` returns `KaraokeWord`
values: the text to draw, whether the word starts a new word, and the fill window. Word timings are
**onsets**, so each word's ramp starts 70 ms before its timestamp (the edge is already moving when the
word is heard), ends 40 ms before the next onset (it lands as the next word begins), is clamped to a
90 ms floor and a 1200 ms ceiling (a long gap between onsets settles instead of crawling), and the
last word ends with the line.

Providers signal a word boundary with a leading space and write the syllables of one word as separate
runs without one (`PaxsenixProvider.normalizeWordSpacing`). That distinction is preserved as
`isNewWord`, so a syllable-split word still renders as one word while every word boundary keeps the
spacing a text layout would give it.

**Lines without word timings stay whole.** A line the provider timed only as a whole yields a single
unit covering the line, because word timings are never invented: a line-synced lyric is sung as a
line, so it is treated as a line. This is not negotiable in the model — distributing a line's duration
across its words was implemented first and reverted, since evenly spaced word boundaries that come
from nothing read as word-synced karaoke with the wrong timings.

That unit drives an **appear** animation rather than a fill: `KaraokeWord.appearProgress` ramps the
line from dim to fully lit over ~200 ms from its own start, and then holds at 1 for the rest of the
line. Line-synced lyrics are read while they are sung, so a line that brightened gradually across its
own duration would be dim exactly when the listener needs to read it. The unit also carries the halo,
which blooms in with the ramp and settles to a soft residue (`haloStrength`).

`staticTimeMs(for:line:)` gives the position to render a line at when it is not the line being sung:
finished lines read as fully sung, upcoming lines as untouched, and a wordless gap past its end. That
is what confines the live clock to one line.

### 3. `KaraokeLyricsLineView` — the wipe itself

`Sources/Kaset/Views/SharedViews/KaraokeLyricsLineView.swift`

Each word is drawn twice in a `ZStack`: the dim base layer, and a full-brightness copy masked by a
linear-gradient alpha ramp whose edge sits at that word's fill fraction. The ramp **overshoots the
glyphs by its feather**, so a fully sung word reaches full brightness exactly at its end while the head
still leads the edge mid-word; the feather is a fixed distance (`0.7 × font size`), so short and long
words carry the same halo instead of the halo growing with the word.

The halo is the **blurred image of the sung layer** — `masked.blur(radius:).opacity(…)`, blur applied
*after* the mask — rather than a second blurred copy sharing the same mask. Blurring after masking
lets the bloom spread past the word's own box and taper into the line, instead of ending on the edge
of the text box; the halo also eases in with the word (`min(1, fill × 3)`) so it does not snap on at
the word's first pixel.

The word being sung swells and lifts. That envelope is measured in **time** (`KaraokeWord.swell`,
rising over 130 ms, releasing over 170 ms, zero slope at both ends) rather than in fill, so a short
word no longer reaches full size within its first few frames — the original fill-indexed curve hit half
its peak at 5% of a word's fill, which read as a pop rather than as an animation.

A line a provider timed only as a whole takes the other path in the same view (`lineSyncedText`): the
whole line is one `Text` under the dim layer, the lit copy's opacity is its appear progress, and the
halo is that lit copy blurred. There is no fill mask, no word boundary, and no swell.

Words are laid out by a small `Layout` (`KaraokeWordFlowLayout`) that wraps them at the container
width and keeps each word its own view, which is what makes per-word masking possible. Greedy
first-fit wrapping mirrors what `Text` does with the same words as one string, the gap a word asks for
is carried as a layout value (so syllable runs stay glued), and a wrapped row starts at the margin
instead of inheriting the gap of its first word. Fill direction is per word: a right-to-left word fills
from its trailing edge, so Arabic and Hebrew lyrics fill the way they read.

`KaraokeTimeSource` decides per row whether it is live: the row is wrapped in a `TimelineView` when
it is the line being sung **or the line after it**, and every other row renders a single static frame.
Per-frame work is therefore two lines' worth of masking at most, not the whole lyric sheet.

Running the next line live is what makes a line change continuous: by the time a line becomes the
current one its fill and swell have already been running since their own start, so it can never first
be seen part-way through its first word (which is what made the first word appear to jump to full
swell the moment the line changed). The line-level emphasis — opacity, scale, drift, and the fullscreen
recede blur — still animates across the change on `AppAnimation.lyricLine`.

### A line that leaves

A row renders either from the display clock or from a settled frame, and those are two
different subtrees. Switching between them **in the same update** that changes the row's status
replaces that subtree mid-transition, and SwiftUI does not animate a subtree it replaces: the line
that had just been sung snapped to its resting size instead of scaling down to it, while the line
arriving behind it — whose row stayed live throughout — animated correctly. That asymmetry was the
bug.

`KaraokeFillModel.isLiveRow` therefore keeps the finished line on the display clock until the clock
is past the line's own end (plus `KaraokeTiming.trailingSettleMs`). At that point the settled frame
and the live frame are pixel-identical — the fill is complete and the halo has settled — so the swap
is invisible and the scale-down is left to animate on `AppAnimation.lyricLine`. The same rule fixes
word-synced lines, whose last word used to jump to complete when the highlight moved on. It is
covered by a unit test for the rule and a pixel test asserting the two frames are identical
(`settledFrameIsPixelIdentical`).

### Opening the sheet

Opening the panel (or the fullscreen player) was occasionally choppy and landed in the wrong place,
for three concrete reasons:

- The settling loop that jumps the sheet into position re-derived the highlight from the playback
time **its task captured**, which is frozen for the life of the task. Writing state from a stale
position could drag the highlight backwards just as the panel opened.
- It also only scrolled on its first attempt, so if the lazy stack had not materialized the target row
yet, the jump silently did nothing; the panel opened at the top and the first line change then
animated a scroll from there.
- The sheet's first paint (a whole lyric sheet, with the sidebar sliding in beside it) is the most
expensive frame of its life, and it was being drawn *through* a scroll animation and a spring on
every row's emphasis — which is what those animations looked like: choppy.

`settleScroll(using:)` now owns all three: it reads the target from state, repeats an unanimated jump
until the sheet has settled (a repeated jump is invisible, and it is idempotent), and holds
`isSettling` while it does — during which scrolls jump instead of animating and the rows apply their
emphasis without a spring. It runs when the view appears and again when the lyric sheet is replaced.

### Cost — what a frame is allowed to do

This is the most per-frame work in the app, so the frame budget is deliberately narrow:

**Measurement happens once per line, never per frame.** `KaraokeLineLayout` carries the measured word
widths and the font metrics, and `KaraokeLayoutCache` memoizes it per line. A frame is arithmetic on
numbers that are already known: the flow layout is *handed* the widths instead of asking each subview
for its size, and the fill mask is computed from the word's measured width instead of a
`GeometryReader` per word. Measuring in the row body would not have been safe — a row carries a tap
closure, SwiftUI re-evaluates a view whose properties include a closure on every parent update, and a
row therefore rebuilds for each of the 10 Hz playback samples. The cache is what keeps that at a
dictionary lookup, and handing every frame the same `Equatable` layout is what lets SwiftUI skip a
settled row's drawing entirely.

**A fully sung word costs one layer, not three.** Once a word is complete its dim base and its fill
mask are dropped: the lit copy covers the base exactly, so most of a line is single-layer words, and
only the word actually being sung carries a mask and the halo blur.

**Rows redraw at the rate they need** (`KaraokeFrameBudget`): the line being sung at 60 Hz; the line
after it, and a finished line while it settles, at 30 Hz (nothing on either is moving — their
transitions are Core Animation's, not redraws of their own); 10 Hz while the fullscreen player covers
the panel, which is one frame per playback sample and keeps the clock correct without paying for
frames nobody can see; and 20 Hz while playback is paused, where the fill is frozen and a frame only
exists to take up a sample correction or a seek. Reduce Motion uses 20 Hz. A karaoke fill is slow — a
few pixels a frame — so 60 Hz is already smoother than the motion needs; on a 120 Hz display, halving
the rate is the single largest saving. The one row that must not be throttled is the bouncing pause
dot, which is decorative motion that only exists while it is moving.

### Line transitions, emphasis and Reduce Motion

Line emphasis moves from `.easeInOut(0.4)` to `AppAnimation.lyricLine`, a crisp spring, with a small
status-keyed drift so a line settles as it becomes current; fullscreen also blurs the lines around the
one being sung. Auto-scroll follows playback 120 ms ahead of a line's own start, so the line is in
place when its first word is sung.

Reduce Motion (via the SwiftUI `accessibilityReduceMotion` environment, the reactive counterpart of
the `NSWorkspace` check used elsewhere) keeps the fill — it is the information — and drops the
decorative parts: no glow, no swell, no feather, no blur, and a 20 Hz redraw instead of display rate.

## Consequences

### Positive

- The highlight reads as sung rather than stepped: continuous motion from a 10 Hz source, with jitter
  absorbed instead of shown.
- Line-synced lyrics improve too, without any provider work, and without pretending to timing
  data the provider never sent.
- The timing behaviour is pure and covered by unit tests, including the properties that matter
  (monotone, no jumps, frame-rate independent, snaps on seek, and a swell that is zero before a word
  and zero again by its end), and the rendering is covered by offscreen pixel tests
  (`KaraokeLyricsRenderTests`) that assert fill position, dim-vs-sung alpha, edge feathering, a halo
  that blooms past the text box instead of being cut off at it, word gaps, and wrapping.
- Only one line redraws per frame, and only while it is current.

### Negative

- **Per-frame cost is real, though bounded**: one animating line measures ~1.7 ms/frame in
  `KaraokeLyricsPerformanceTests` (construction, layout, masking, blur and rasterization into a bitmap
  — the part the app does on the GPU), which is roughly 10% of one core per surface at 60 Hz plus ~4%
  for the armed line. It remains the most expensive per-frame work in the app, and the frame budgets
  and the measured-layout cache are what keep it from growing; the harness test fails if a frame's
  cost regresses past its (loose) budget.
- **The clock is stateful and outside SwiftUI's model**: it must be reset on track change
  (`onChange(of: lyrics)`), and it must be fed on `isPlaying` changes as well as position samples.
- **Provider timings are onsets**: the fill compensates with a fixed lead and tail rather than per-song
  calibration, so a badly timed provider still looks badly timed.
- **Two lyric looks, by capability**: word-synced lyrics fill word by word, line-synced lyrics appear
  at the line's start and stay lit. That difference is honest to the data, but it does mean the two
  feel different.
- Custom layout means line breaking is our own greedy wrap rather than `Text`'s, and long
  unspaced tokens (a CJK line that arrives as one word) cannot break inside a row.

### Neutral

- The old `FlowKaraokeLine` is gone; both surfaces render through `KaraokeLyricsLineView`.
- `SyncedLineView` no longer scans `lyrics.lines.firstIndex(of:)` per line per frame; rows are indexed.
- Pause dots are driven from the same interpolated position, so they stay in lockstep with the wipe.

## Alternatives considered

- **Poll the WebView faster.** More IPC and more main-actor hops to paper over the same problem, and
  it would make the highlight *arrive* later, not render smoother.
- **`TextRenderer` with per-glyph clipping.** The cleanest typographic route (one `Text` for the line,
  glyph-accurate clipping), but it re-lays out and re-draws the whole line every frame and depends on
  per-glyph slice bounds and `TextAttribute` plumbing. Per-word masked views give the same visual
  result from stable APIs, with the fill and lift under direct control.
- **A user-facing animation toggle and lyric sync offset.** Rejected for this change: the animation is
  the feature, and Reduce Motion is the accessibility escape hatch.
- **Driving the fill with SwiftUI animations instead of a display-rate clock.** An animation restarts
  on every sample, which is exactly the lag-and-restart behaviour being removed.
