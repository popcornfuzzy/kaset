# ADR-0026: The Fullscreen Player Answers the App's Keys Ahead of Focus

## Status

Accepted

## Context

Playback and navigation shortcuts in Kaset are menu commands (`KasetApp.commands`), and AppKit
resolves a key equivalent against the key window's view hierarchy **before** it consults the main
menu. That is fine for the main window, where the shortcuts' own views are the only thing that could
answer them. The fullscreen now-playing player is not: while it is up the window also contains a seek
slider, seven transport buttons and a scrolling lyric sheet, and whichever of them held keyboard
focus last was the one that got the key. `Space` and `⌘←`/`⌘→` therefore worked or did not work
depending on where the last click landed, with nothing on screen to say which — a report of
"keyboard controls sometimes break in fullscreen and I can't tell when they do" is exactly this.

Disabling the obscured main window behind the overlay (ADR-0018's `FullscreenObscureModifier`) is
necessary but not sufficient: it resigns *that* subtree's focus and says nothing about what the
player itself focuses.

## Decision

For the length of one presentation the player installs a single local key monitor
(`FullscreenNowPlayingView.installKeyMonitorIfNeeded`), removed in `endPresentation`. A local monitor
runs ahead of the responder chain and ahead of the key window, so nothing inside the player can
swallow a key before it sees it. The monitor does two things:

- `Escape` closes the player. This was the monitor's original and only job; `onExitCommand` is kept
  as the declarative counterpart for a focused view.
- Every other `keyDown` is offered to `NSApp.mainMenu.performKeyEquivalent(with:)`, and swallowed if
  the menu took it.

A presentation also claims its window (`FullscreenNowPlayingView.claimHostWindow`): if the app is not
active it activates, and if the host window is not key it makes it key. The player covers that window,
so both halves of "leaving fullscreen is not possible" depended on it — `Escape` typed into a window
that is not key is that window's key and the monitor leaves it alone (correctly, which is why the guard
and the claim have to exist together), and a click on a control in a window that is not key is spent
activating the window before it is a click on the control. A window presenting a sheet is left alone:
taking the key back would put the sheet behind the window it belongs to.

The player is **mounted from its first presentation on and then driven by attributes** — opacity,
hit-testing, accessibility — rather than being inserted and removed for each one (`MainWindow`'s overlay,
latched by `hasPresentedFullscreenNowPlaying`). A `.transition` makes the disappearance something that has
to *complete* before the view leaves the tree, in a transaction the reader's key or click only starts: a
removal still waiting to settle is a player still on screen with its state already cleared, reported as
"leaving fullscreen sometimes takes really long". Opacity has no completion step, so the state change is
never waiting on an animation; the presentation's own lifecycle was already driven by the flag, so nothing
depended on the view being new. What the hidden player must not cost is stated where it is spent: the
lyrics mirror and the lyric lookup stop while it is hidden (`FullscreenNowPlayingView`), and the canvas
lookup was already keyed on the flag.

Both ends of a presentation also stay out of the dispatch that asked for them. The dismissal
(`closeFullscreenNowPlaying`), the claim above, and the window's chrome change
(`MainWindow.scheduleWindowChromeUpdate`) each run one runloop turn later, from a
`Task { @MainActor … }`. Every
route in is an event — `Escape` arrives inside AppKit's dispatch (the monitor runs from
`nextEventMatchingMask`, `onExitCommand` from the responder chain), and the button inside the click
that pressed it — and clearing the flag from there tears the overlay down, restores the window's
toolbar and re-lays the titlebar *while that dispatch is still open*. A titlebar layout waiting on the
runloop turn the event itself is holding is a window that stops responding until something else
happens: reported as "pressing `Escape` or the button hangs, and then pressing play/pause with the
mouse lets it go". One turn later none of it is re-entrant, and that turn is not visible.

It deliberately does **not** restate any shortcut. The event goes to the same menu the shortcuts are
declared in, so there is still exactly one definition of what `Space` does, and the monitor cannot
drift from it as shortcuts are added or changed.

## Consequences

### Positive

- The shortcuts the player is on screen for are deterministic: no control inside the player, and no
  focus state it can get into, changes whether they work.
- No shortcut is duplicated. A command added to the Playback menu works in the fullscreen player
  without being mentioned again anywhere.
- The mechanism is scoped to the presentation and removed with it, so nothing outside the player is
  affected — in particular the shortcuts a text field would need elsewhere in the app.

### Negative

- Every `keyDown` while the player is open is offered to the menu first: one menu traversal per
  keystroke. On a player with no text input that is the whole point, but it does mean a text field
  added to the player later would have to be excluded from the monitor.
- Commands reached this way run from the monitor's context, ahead of the responder chain, so a
  command must not depend on the responder that would otherwise have handled the key.
- The monitor is a second thing the presentation has to install and tear down correctly. It is
  idempotent (`installKeyMonitorIfNeeded` guards on the existing monitor) and `endPresentation` is
  already required to be, because it is called from both the flag change and `onDisappear`.
- The monitor has to decide *whose* key it is looking at, and that decision is made per keystroke
  against a host window resolved at that moment (`FullscreenKeyRouting`). Remembering the window
  number when the monitor was installed was the first version of this, and it is wrong the moment the
  app has a window the monitor's snapshot did not know about: the app's window list is not fixed (a
  settings window opens, the mini player panel is created, the window is re-keyed), and a number
  captured once is wrong for every key after it — which reads as `Escape` doing nothing while the
  player covers the window, one of the two halves of the report this settled.
- A local monitor also sees `Escape` from windows that are not the player's, so the host has to be
  identified at all: the player is scoped to the window wearing the app's main autosave name, which is
  now the only window allowed to wear it (`AppDelegate.setupWindowDelegate`). Two windows sharing that
  name did not merely remember the wrong frame — it made every lookup of the app's main window, the
  monitor's included, a coin-flip between them.

### Neutral

- `Escape` keeps its existing single-path behaviour: the monitor consumes it, so `onExitCommand`
  does not also fire and the player cannot be closed twice from one keystroke.
- The close button deliberately carries **no** `.keyboardShortcut(.cancelAction)`. It reads like a free
  second route for `Escape` for a presentation whose monitor is not installed, but it registers the
  button with AppKit's key-equivalent machinery — and the button's action is the removal of the very
  view whose registration is being dispatched, so the window's chrome and its command table would be
  mutated from inside the dispatch of the key that just ran. `Escape` keeps two routes that do not do
  that: `onExitCommand`, which is the responder chain's own cancel action, and the monitor.
- Measured end to end: `Fullscreen now playing exit sequence completed in 0.02s` — the dismissal, the
  window hearing it, the chrome coming back and the presentation ending, from a driver that posts a real
  `Escape` at the app. Leaving is a state change now, not a transition that has to finish.
- Measured with a driver that posts real events at the app (a `keyDown` through
  `NSApp.postEvent`, a click at the close button's own reported frame): both routes run the whole exit
  sequence — dismissal, the window hearing the flag, the chrome coming back, the presentation ending —
  in ≈0.35 s, in a window **and** in system full screen. The close button sits 44 pt below the window's
  top because the overlay respects the titlebar band, and 12 pt below it in system full screen; a click
  that assumed 12 pt in a window hits nothing at all, which is a harness that missed rather than a
  button that does not respond.
- The monitor swallows a key on the strength of the menu's return value, which is documented to mean
  the item was found *and its action performed* — a `true` that did not perform would leave the key
  dead rather than merely unshadowed. `MenuKeyEquivalentRoutingTests` pins both halves for the two
  shapes the app uses: an unmodified `Space` (the key that was reported broken, and the one AppKit's
  normal route hands to the responder chain first) and a `⌘`-modified function key. It also pins the
  scaffolding that made the first version of it lie: a menu that is not the app's main menu matches the
  key but has nothing to send the action through.
