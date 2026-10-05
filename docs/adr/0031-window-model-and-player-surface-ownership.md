# ADR-0031: Window Model and Single-Owner Player Surface

## Status

Accepted

## Context

Kaset plays through **one** `WKWebView` for the app's whole lifetime ([ADR-0001](0001-webview-playback.md)),
and the view that shows it — `PersistentPlayerView` — **re-parents** it into whichever container is on
screen (`removeFromSuperview` + `addSubview`). A view has exactly one superview, so that WebView can
only ever be in one window.

Until now that was safe by accident: the app had one window, so there was only ever one candidate
container. The moment the app has a second window that wants to show the player, the rule becomes load
bearing. Left implicit, a second window appearing would silently steal the video mid-song, and because
the re-parenting is a race between two view trees, which window "won" would depend on layout ordering —
the surface would blank in the loser, and a DRM-protected stream does not survive being yanked out of
its view hierarchy.

[ADR-0030](0030-appkit-window-shell.md) made the main window AppKit's, which is what makes adding a
second real window cheap: the app already owns `NSWindow`s, so a companion window is a controller and a
window, not a scene.

## Decision

**The app has a window model: windows are AppKit's, the app owns them, and the shared player surface
has exactly one named owner at a time.**

### The window model

Windows are created and owned by `AppDelegate`, next to the main window:

| Window | Owner | Content |
|---|---|---|
| Main | `AppDelegate.installMainWindow()` | `MainWindow` (the `WindowShell`) |
| Mini player panel | `AppDelegate.makeMiniPlayerPanelController()` | `MiniPlayerPanel` |
| Settings | SwiftUI's `Settings` scene | `SettingsView` |

A window is AppKit's when it has to outlive a scene, be found by the app, or carry an app-owned
toolbar. The main window needs all three ([ADR-0030](0030-appkit-window-shell.md)); the panel needs the
first and the second. `Settings` stays a SwiftUI scene because nothing else has to know about it.

### The single-owner rule

`PlayerService.playerSurfaceHost` (`PlayerSurfaceHost`: `.mainWindow` / `.miniPlayerPanel`) names the
owner. Every host asks before it claims the surface:

```swift
// PlayerSurfaceHost
func claimsSurface(when host: PlayerSurfaceHost) -> Bool {
    self == host || (self == .mainWindow && host != .miniPlayerPanel)
}
```

- The **main window is the fallback owner**: it hosts whenever the panel does not, so launch behaviour
  is unchanged and a panel that is merely being created cannot steal the video.
- The **panel only hosts once the app has handed the surface over** (`setPlayerSurfaceHost`), so the
  rule is a decision rather than an ordering accident.
- The answer reaches the views as `PlayerService.isPlayerSurfaceDetachedToPanel`, and
  `PersistentPlayerView` takes it as `claimsSurface`: a host that does not own the surface **detaches
  the WebView if it somehow holds it and returns without attaching it**. That is the part that makes
  the handover safe in both directions — no pass of a losing host's view tree can pull the surface
  back.

`MainWindow.hostsPlayerWebView` also stands down while detached, so the main window does not even
create the layer. The two are belt and braces on purpose: the view-level rule is what is *correct*, and
the layer not existing is what keeps the surface from being re-parented during the transition at all.

### The panel

`MiniPlayerPanel` is a `NSPanel` because that is what a floating companion window is on macOS:

- **`.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`** — clicking the player to pause it must not
  activate Kaset or pull focus off whatever the reader was doing.
- **`.utilityWindow`** — the smaller, shadowed chrome a companion window gets.
- **`level = .floating`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`** — a detached player that hides
  behind the window you switched to is not a detached player.
- **`isReleasedWhenClosed = false`** — the controller keeps the window, and the surface moves by
  explicit handover rather than by the window ceasing to exist.

The panel's content is the *same* `PersistentPlayerView` with the same `isExpanded: true` presentation
the in-window mini player uses: the panel is a bigger, more permanent version of that floating layer,
not a second kind of player. `MiniPlayerPanelLayout` (ratio-following height, clamped width) and
`MiniPlayerPanelPlacement` (bottom-trailing of the main window, nudged onto the screen) hold the
geometry as testable values.

## Consequences

**Easier**

- A second window is cheap and safe: the ownership rule is stated once and both hosts read it, so
  adding a third surface-showing window later is a `PlayerSurfaceHost` case plus a claim, not a hunt
  through view trees for re-parenting races.
- Playback survives the main window: closing it leaves the panel — and the WebView inside it — alone,
  which is the one behaviour a detached player has to get right.
- The panel behaves like a macOS utility window (non-activating, floats across Spaces) rather than like
  a second document window.

**Harder / accepted trade-offs**

- **Only one window can show the player video at a time.** This is a property of the single-WebView
  design, not of the window model: a second window shows artwork (and can drive playback) but not the
  video. Lifting it would mean either a second WebView — which breaks DRM session/playback identity —
  or a `CALayer`-based surface share, which WebKit does not offer.
- The panel is off by default (`SettingsManager.miniPlayerWindowModeEnabled`), so the player bar's
  Mini Player button keeps doing what it always did unless the reader opts in.
- The surface handover is a re-parent of a live `WKWebView`. It is safe because it only happens when the
  reader asks for it, but it is the one operation here that a UI test cannot assert and only a running
  app can confirm — the same limitation [ADR-0030](0030-appkit-window-shell.md) records for the shell.
- The panel is a window, so it is beyond what a SwiftUI preview or snapshot test covers; the geometry
  and the ownership rule are unit-tested (`MiniPlayerPanelTests`), and the rest is verified by running.
