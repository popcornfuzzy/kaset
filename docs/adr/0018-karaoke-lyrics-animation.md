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

A word's window is then **sliced per character** (`KaraokeFillModel.characters(for:weightedBy:)`), in
proportion to the measured advance of each character, because the character is the unit the **lift** is
timed by: the character whose slice the edge is inside is the one that rises. The slices **tile** the word's window — the first starts where the word starts
and the last ends where the word ends — so the word still fills over exactly the interval it always did,
while the emphasis travels through it one character at a time. The model measures nothing itself: the
widths are handed in by the renderer, which has already measured the word for the flow layout, and a
word whose widths are missing falls back to equal slices. A character is one *grapheme cluster*, not one
code point, so a character written with several scalars is never cut in half by its own lift.

**Lines without word timings stay whole.** A line the provider timed only as a whole yields a single
unit covering the line, because word timings are never invented: a line-synced lyric is sung as a
line, so it is treated as a line. This is not negotiable in the model — distributing a line's duration
across its words was implemented first and reverted, since evenly spaced word boundaries that come
from nothing read as word-synced karaoke with the wrong timings.

That unit drives an **appear** animation rather than a fill: `KaraokeFillUnit.appearProgress` ramps the
line from dim to fully lit over ~200 ms from its own start, and then holds at 1 for the rest of the
line. Line-synced lyrics are read while they are sung, so a line that brightened gradually across its
own duration would be dim exactly when the listener needs to read it. The unit also carries the halo,
which blooms in with the ramp and settles to a soft residue (`haloStrength`).

`staticTimeMs(for:line:)` gives the position to render a line at when it is not the line being sung:
finished lines read as fully sung, upcoming lines as untouched, and a wordless gap past its end. That
is what confines the live clock to one line.

### 3. `KaraokeLyricsLineView` — the wipe itself

`Sources/Kaset/Views/SharedViews/KaraokeLyricsLineView.swift`

A word is drawn as a dim base under a full-brightness copy masked by a linear-gradient alpha ramp whose
edge sits at the **word's** own fill fraction and whose box is the word's measured width. The ramp
**overshoots the glyphs by its feather**, so a fully sung word reaches full brightness exactly at its end
while the head still leads the edge mid-word; the feather is a fixed distance (`0.7 × font size`). The
character slices tile the word's window, so the edge is continuous across the word: the character at it is
the one mid-ramp, and the characters behind it are complete. (The ramp is clamped to the word's box, and
its feather to half of it, so a word too narrow for its own feather is not cut off.)

The fill, the mask and the halo are the **word's**; the emphasis is the only thing sliced per character. A
per-character halo was implemented first and read as *no* halo at all: a character's slice of a word's
window is a fraction of the 130 ms its own bloom takes to rise and the 170 ms it takes to fade, so the
bloom never gets going, and all it has to blur is one glyph's half-filled sliver.

**A word's text is drawn as one run, cut by a mask — never a run per character.** The character being sung
has to be drawn apart from the text around it, since a lift is a translation of a raster and no glyph in a
text layer can move without being pulled out of that layer. Drawing the runs either side of it as their own
`Text` layers is the obvious way to do that, and it is the wrong one: a text layer's origin snaps to a
whole pixel, so every time the boundary between two runs crossed a character, all the text behind the
boundary stepped by a pixel — measured as a **1.00 px jump of every character after the edge**, and back
again when the wave moved on. (The cells the runs were placed on were the differences between the
*bounding* widths of the text's prefixes, which carry the side bearings of their first and last glyph and
so are not the advances the text is drawn at: even a run per cell jittered by more than a point.
`characterCellsAreWhereTheTextDraws` pins the measurement against `CTLineGetOffsetForStringIndex`.)

So the word is drawn as the **whole word's text in every layer**, at one origin, and the lift is a
**mask over it**: the text with the character's cell cut out, and the same text masked to *only* that cell
and offset by the lift. Nothing is repositioned when the wave moves — only the mask changes — so the
characters at rest cannot move. `theWaveMovesNothingElse` reads the alpha-weighted centre of every
character's cell across a whole sweep of the word and holds each to under half a pixel of drift, and
`theCutTakesNothingOutOfTheWord` holds the two halves of the cut to covering the word exactly, which is
what a mask placed against the wrong cell of it (an `overlay` centres a fixed-width child) took away.

That costs the word's text drawn twice while a character is lifting, once per half, against three narrow
runs before. Drawing each character as its own layer is what per-character emphasis costs if it is taken
literally, and it measured **4.65 ms per frame against 1.24 ms** for the same line drawn per word — 3.75×,
because a row is mostly *settled* words and their characters were the ones being paid for. Runs brought that
to 1.55 ms and the mask cut measures **1.87 ms** on the same line: the extra third of a millisecond is what
it costs for the characters at rest to stay exactly where the word draws them, and it is paid only by the
one word the edge is inside. `theLiftMovesOneCharacterAtATime` pins the structure that keeps it there (one
character lifted at a time, and a word at rest one layer) so the cost cannot creep back in by accident.

The halo is the **blurred image of the sung layer** — `masked.blur(radius:).opacity(…)`, blur applied
*after* the mask — rather than a second blurred copy sharing the same mask. Blurring after masking
lets the bloom spread past the word's own box and taper into the line, instead of ending on the edge
of the text box.

The halo's strength is its own **time** envelope (`KaraokeFillUnit.glowStrength`), rising over 130 ms and
fading back to *exactly zero* over the last 170 ms of the word, with zero slope at both ends. It was
originally a function of the fill (`min(1, fill × 3)`), which meant it was still at full strength on the
frame the word finished and then vanished with the word's mask — a full-brightness halo disappearing
in a single frame, measured at 1.08 where an ordinary frame of the same wipe is 0.03. Ending the
envelope with the unit means a finished unit is a unit nothing is happening to, which is also what
lets the completed-unit layer reduction above be invisible — a word whose ramp is over drops its mask and
its halo.

The character being sung **lifts, and is never scaled**, by `fontSize × 0.02` at the peak — a fraction of
a pixel at 16 pt, deliberately: it exists to keep the character being sung from being perfectly static,
not to be read as movement. The glow is what marks it. (It was first written at `fontSize × 0.06`, which
was visible enough to be distracting.) That envelope is likewise measured in time
(`KaraokeFillUnit.swell`, rising over 130 ms, releasing over 170 ms, zero slope at both ends) rather than
in fill, so a short window no longer reaches full lift within its first few frames. Scaling was
implemented first and reverted: SwiftUI rasterizes text at the scale it is asked for, so a scale driven
frame by frame re-rasterizes the text's anti-aliasing on nearly every frame (measured steps of
0.1–0.6 alternating, against 0.03 for the fill alone) and snaps hardest on the frame it returns to its
resting size — a 1.05 step, the largest single-frame change in the whole animation. That frame lands
40 ms before the line ends, in the middle of the line's own scale-down, and read as the word (and so
the line) jumping in place. Scaling a *line* is fine because that animation is Core Animation's, not a
per-frame redraw. A sub-pixel translation is a transform of an unchanged raster, so the lift steps
cleanly; `emphasisLiftsRatherThanScales` pins it by asserting that the character being sung covers the same
rows of its own cell at full emphasis as it does with the emphasis off, and sits higher.

The lift is also the reason the emphasis had to become per *character* rather than per word: a lift is a
translation of a raster, so one glyph of a text layer cannot move without being pulled out of that layer
and cut out of the text around it. The effect is small on purpose — a lift is there so the character under the edge is
not perfectly static — but it is the wave that follows the fill edge, and `liftTravelsAcrossTheWord`
follows it through the pixels: the same character is a pixel or two higher on the frame the edge is on it
than on the frame the edge has passed it.

A line a provider timed only as a whole takes the other path in the same view (`lineSyncedText`): the
whole line is one `Text` under the dim layer, the lit copy's opacity is its appear progress, and the
halo is that lit copy blurred. There is no fill mask, no word boundary, and no swell.

Words are laid out by a small `Layout` (`KaraokeWordFlowLayout`) that wraps them at the container
width and keeps each word its own view, which is what makes per-word masking possible — and, inside a
word, the mask that cuts the character being sung out of the word's own text. Greedy
first-fit wrapping mirrors what `Text` does with the same words as one string, the gap a word asks for
is carried as a layout value (so syllable runs stay glued), and a wrapped row starts at the margin
instead of inheriting the gap of its first word. Fill direction is per word: a right-to-left word fills
from its trailing edge, so Arabic and Hebrew lyrics fill the way they read.

`KaraokeTimeSource` decides per row whether it is live: the line being sung, the line after it, and
the line that has just finished until its content is settled run on the display clock; every other row
is handed a settled position and its timeline is **paused in place** rather than removed. Per-frame work
is therefore two lines' worth of masking at most, not the whole lyric sheet — see *A line that leaves*
for why the settled rows keep their timeline instead of dropping it.

Running the next line live is what makes a line change continuous: by the time a line becomes the
current one its fill and swell have already been running since their own start, so it can never first
be seen part-way through its first word (which is what made the first word appear to jump to full
swell the moment the line changed). The line-level emphasis — opacity, scale, drift, and the fullscreen
recede blur — still animates across the change on `AppAnimation.lyricLine`.

### When the highlight moves

The panel used to compute the rows' status from `currentLineIndex(at: timeMs + scrollLookaheadMs)` —
the *same* 120 ms lead the auto-scroll uses. So the departing line began to dim, shrink and recede
120 ms before its own content was settled: on a word-synced line its last word was still sweeping
(typically 65–85 % of the way across), and on a line-synced line its halo was still decaying into its
residue. A line that starts to leave while it is still being sung never reaches its sung state, which is
exactly how the bug was reported.

`KaraokeFillModel.highlightIndex(in:at:)` is the rule now: the line being sung is the last line that has
started whose content has not settled. That is the cheap declared rule — the last line that has started
and has not run past its own duration — plus one guard, for a line whose last word is still filling past
its declared end. The guard costs one comparison against one line's fill windows, not a derivation over
the sheet. `scrollLookaheadMs` now leads the *scroll* only: the sheet is put in place before the line's
first word, and the highlight arrives when the line it is on is sung.

The two are deliberately different instants, and the difference is a few tens of milliseconds either way:
the incoming line's first word starts filling `attackLeadMs` before the outgoing line's declared end, so a
highlight that moved only when the outgoing content settled would brighten the incoming line just after
its fill had started. Erring that way is a line that is briefly dim while the first of it is being sung;
erring the other way — how it was — is the line that is leaving, which is the one the eye is following.

### A line that leaves

A row renders either from the display clock or from a settled frame, and those are two different
subtrees **if the row branches between them**. It used to:

```swift
if self.isLive {
    TimelineView(.animation(minimumInterval: …)) { self.content(self.clock.advance(to: $0.date)) }
} else {
    self.content(KaraokeFillModel.staticTimeMs(for: self.status, words: self.words, line: self.line))
}
```

An `if`/`else` in a `ViewBuilder` builds `_ConditionalContent`, so switching branches **replaces** the
subtree — and SwiftUI does not animate a subtree it replaces. That switch happens in the same update
that changes the row's status, which is the frame the line that has just been sung begins its
departure: the row being replaced was the row being animated out.

It was papered over by keeping the finished row on the display clock until the settled frame and the
live frame were pixel-identical — `KaraokeFillModel.settleBoundaryMs` plus a trailing settle window
(`KaraokeTiming.trailingSettleMs`, since removed). That made the replacement invisible but left two
problems behind. *When* the swap landed was still at the mercy of the interpolated clock — on the frame
of the status change if the clock had run ahead, mid-spring if it lagged, since the window was measured
against the display clock while the change was driven by the poll — and for as long as it lasted the row
went on redrawing a frozen fill inside a changing 5 % scale, and in fullscreen a changing blur.

`KaraokeTimeSource` now keeps **one** `TimelineView` in both states and only pauses it:

```swift
TimelineView(.animation(minimumInterval: self.minimumFrameInterval, paused: !self.isLive)) { timeline in
    self.content(self.position(at: timeline.date))
}
```

The hand-off is a value change inside an unchanged subtree, so the frame it lands on no longer matters,
and the row's content keeps its identity across it. That is asserted directly: `KaraokeRowHandoffTests`
hosts the row's time source, hands it a `@State` value from inside its content — which outlives
re-renders but not a replaced subtree — and fails if a second identity ever appears, as it does when the
`if`/`else` is put back. The same test pins the other half: a live row is handed a new position every
frame, and a settled row is handed its settled position exactly once and then draws nothing at all.

Paused rather than removed is also what makes the departure Core Animation's. A line that has finished
is a line nothing is happening to, so its scale, opacity, drift and blur animate a frozen raster instead
of a per-frame redraw of scaled text — which is the same mechanism the word-level fix above was about,
applied to the whole line. `isLiveRow` therefore ends its trailing window at `settleBoundaryMs` with no
extra slack: the last frame the row draws is the frame it settles to (`settledFrameIsPixelIdentical`
asserts the two are identical), which is also the frame the highlight moves on.

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
`isSettling` while it does — during which scrolls jump instead of animating. It runs when the view
appears and again when the lyric sheet is replaced, and it is bounded by **wall clock** rather than by
iteration count, because the busy main thread this window exists for is exactly what stretches
`Task.sleep`.

#### The departing line still snapped, for a while

For a long time the leaving line was reported to still snap in place, and three fixes were attempted at
the wrong level. Two were decoration: the halo that popped off a completing word, and the word lift that
re-rasterized as it returned to rest. Both were real defects, both are still fixed (`glowStrength` and
lift-not-scale above), and neither was the one being described. The third was the panel's settling
window, which suppressed the rows' emphasis spring while the sheet was being put in position —
`.animation(isSettling ? nil : AppAnimation.lyricLine, value: status)`. That window is not short-lived
(it restarts whenever the lyric sheet is replaced and it stretches with main-thread load, which is
precisely when lines change), and inside it the departing line's scale, opacity and drift were applied
with **no animation at all** while its words kept animating, because the fill is driven by the display
clock rather than by an implicit animation. That asymmetry matched the report well enough to look
right — and removing the gate was worth doing, since a line change must never be conditional — but it
was not the cause either: the emphasis animation had been switched off to hide a pop-in, and the pop-in
is better removed at its source (the sheet **seeds** `currentLineIndex`/`currentLineId` from the
playback position it is handed, so its first frame already carries the right emphasis and there is no
spring to suppress).

What was actually wrong, in the end, was three things that no fix at the decoration level could reach:

1. **The highlight moved 120 ms early**, because the rows' status was computed with the scroll lead
   (see *When the highlight moves*), so the line was still being sung when it started to leave.
2. **The row's hand-off replaced its subtree**, on the frame the departure began (see *A line that
   leaves*), so the departure was applied to a subtree SwiftUI had just built.
3. **The row kept redrawing during the departure**, because a finished line stayed on the display clock
   for a trailing window that had no job left once the hand-off stopped being a replacement.

Measuring any of that needed an instrument that can see an implicit animation, which nothing offscreen
can: `ImageRenderer` draws one frame at model values and never runs a timeline. `LyricsEmphasisAnimationTests`
hosts the real panel in a window, publishes playback positions at the 10 Hz the lyrics poll uses, pumps
the run loop and reads the rendered pixels. Its line that leaves is deliberately wide — so its right edge
is the widest ink on screen and its width can be followed frame by frame — and its last word fills late,
so "was this line still being sung when it left?" is a question the pixels answer: the fraction of that
row which is bright rather than at the dim base, measured on the frame before the departure is visible.

The harness is honest about its own limit. Reading a frame out of a hosted `NSView` costs ~60 ms here
(AppKit's offscreen caching path, not the drawing), so the trace runs at ~15 Hz however tightly the loop
is written; the departure assertions are therefore shaped as "the change takes several sampled frames to
arrive, and no single sample carries most of it" — which a change applied in one step cannot satisfy —
rather than pretending to follow a 0.42 s spring at display rate. Both halves were checked by putting the
old behaviour back: the emphasis lead fails the fully-sung assertion, and the `if`/`else` hand-off fails
the identity assertion in `KaraokeRowHandoffTests`.

Honest footnote on the seeding: in the harness the pop-in did *not* reproduce without it — SwiftUI
appears to fold `onAppear`'s first highlight write into the commit that contains the sheet, so the
frame measured already had the right emphasis either way. The seeding is therefore not a fix for a
reproduced defect but the thing that makes the first frame correct *regardless* of when that write
lands, which is what lets the animation be unconditional. It is cheap and it cannot be wrong; a pixel
test was tried for it, passed with the seeding removed, and was deleted rather than kept as noise.

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

**A fully sung word costs one layer.** Once a word is complete its dim base, its fill mask and the cut for
the lift are all dropped: the lit copy covers the base exactly, so most of a line is single-layer words,
and only the word actually being sung carries a mask and the halo blur.

**Rows redraw at the rate they need** (`KaraokeFrameBudget`): the line being sung at 60 Hz; the line
after it at 30 Hz (nothing on it is moving — its transitions are Core Animation's, not redraws of its
own); 10 Hz while the fullscreen player covers the panel, which is one frame per playback sample and
keeps the clock correct without paying for frames nobody can see; and 20 Hz while playback is paused,
where the fill is frozen and a frame only exists to take up a sample correction or a seek. Reduce Motion
uses 20 Hz. A karaoke fill is slow — a few pixels a frame — so 60 Hz is already smoother than the motion
needs; on a 120 Hz display, halving the rate is the single largest saving. The one row that must not be
throttled is the bouncing pause dot, which is decorative motion that only exists while it is moving.

**A settled row draws nothing.** It is not merely throttled: its timeline is paused
(`KaraokeTimeSource`), so it is handed its settled position once and then not drawn again until the
highlight comes back for it. That is what the third defect above was — a departed line redrawing its
frozen fill, scaled — and it is also the cheapest frame in the sheet, since a sheet is mostly lines that
have already been sung.

### Line transitions, emphasis and Reduce Motion

Line emphasis moves from `.easeInOut(0.4)` to `AppAnimation.lyricLine`, a crisp spring, with a small
status-keyed drift so a line settles as it becomes current; fullscreen also blurs the lines around the
one being sung. The emphasis changes when the line being sung changes — that is, when the previous
line's content is settled — while the *scroll* follows playback 120 ms ahead of a line's own start, so
the line is in place when its first word is sung. The two leads are deliberately different; using the
scroll's for the emphasis is what put the departure ahead of the singing.

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
  that blooms past the text box instead of being cut off at it, character cells landing where the text
  draws them, the characters at rest not moving while the edge crosses the word, word gaps, and wrapping.
- A line that has finished is sung to the end of its own content *before* it starts to leave, and it
  leaves on a frozen raster in a subtree that keeps its identity — the two halves of the hand-off are
  covered by `KaraokeRowHandoffTests` and the panel-level `LyricsEmphasisAnimationTests`.
- Only the rows the highlight needs redraw, and a settled row is paused rather than merely cheap.

### Negative

- **Per-frame cost is real, though bounded**: one animating line measures ~1.9 ms/frame in
  `KaraokeLyricsPerformanceTests` (construction, layout, masking, blur and rasterization into a bitmap
  — the part the app does on the GPU), which is roughly 11% of one core per surface at 60 Hz plus ~3.5%
  for the armed line. It remains the most expensive per-frame work in the app, and the frame budgets
  and the measured-layout cache are what keep it from growing; the harness test fails if a frame's
  cost regresses past its (loose) budget.
- **The clock is stateful and outside SwiftUI's model**: it must be reset on track change
  (`onChange(of: lyrics)`), and it must be fed on `isPlaying` changes as well as position samples.
- **The highlight and the scroll are separate indices now** (`currentLineIndex`/`scrollLineId` on both
  surfaces): the scroll leads playback and the emphasis does not. Collapsing them again would reintroduce
  the early departure.
- **The emphasis change is a few tens of milliseconds after the incoming line's first word starts
  filling** (the incoming line is armed, so its fill is already running). Erred deliberately in that
  direction: a line briefly dim at its first word is much less noticeable than a line that starts to
  leave while it is still being sung.
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
