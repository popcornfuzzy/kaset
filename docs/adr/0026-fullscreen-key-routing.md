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

### Neutral

- `Escape` keeps its existing single-path behaviour: the monitor consumes it, so `onExitCommand`
  does not also fire and the player cannot be closed twice from one keystroke.
- The monitor swallows a key on the strength of the menu's return value, which is documented to mean
  the item was found *and its action performed* — a `true` that did not perform would leave the key
  dead rather than merely unshadowed. `MenuKeyEquivalentRoutingTests` pins both halves for the two
  shapes the app uses: an unmodified `Space` (the key that was reported broken, and the one AppKit's
  normal route hands to the responder chain first) and a `⌘`-modified function key. It also pins the
  scaffolding that made the first version of it lie: a menu that is not the app's main menu matches the
  key but has nothing to send the action through.
