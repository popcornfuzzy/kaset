# Debugging

How to see what the app is doing while it is running: the logging it emits, how to watch it live, and
which build to watch.

## The logging the app emits

Everything the app logs goes through `DiagnosticsLogger` (`Sources/Kaset/Utilities/DiagnosticsLogger.swift`),
which is a set of `os.Logger`s on **one subsystem** with one category per area:

| Category | `DiagnosticsLogger` | What it covers |
|----------|---------------------|----------------|
| `App` | `.app` | App lifecycle, URL handling, window creation |
| `Player` | `.player` | Playback, the WebView, the mini player, the player panel, surface handover |
| `UI` | `.ui` | Views, the window shell, the sidebar's surface, favorites, canvas |
| `WebKit` | `.webKit` | WebView setup and teardown |
| `Auth` | `.auth` | Login, cookies, session expiry |
| `API` | `.api` | YouTube Music API calls |
| `Network` | `.network` | Connectivity |
| `History` | `.history` | Listening history |
| `Scripting`, `Cast`, `Scrobbling`, `AI`, `Haptic`, `Notification`, `Updater` | — | As named |

Subsystem is **`com.sertacozercan.Kaset`**. That string is the key to every command below: it is what
separates the app's own entries from the hundreds of other subsystems macOS logs every second.

Use `DiagnosticsLogger`, never `print()`. `print()` goes to stdout, which is gone the moment the app is
launched from Finder or `open`, and it carries none of the category, level or redaction information the
log store does.

## Watching the logs live

`Scripts/stream-logs.sh` is a thin wrapper over `log stream` that tees the output to a file as well as
the terminal, so a run can be read back afterwards:

```bash
Scripts/stream-logs.sh                # every category, live
Scripts/stream-logs.sh Player         # just DiagnosticsLogger.player
KASET_LOG_FILE=~/kaset.log Scripts/stream-logs.sh
```

The equivalent by hand:

```bash
log stream --style compact --info --debug \
  --predicate 'subsystem == "com.sertacozercan.Kaset"'
```

`--info --debug` matter. Most of the app's narrative is logged at `info` and the layout diagnostics at
`debug`; without those flags `log stream` prints only the default level and the stream looks empty
while the app is clearly doing something.

Narrow to one category by adding to the predicate:

```bash
log stream --style compact --info --debug \
  --predicate 'subsystem == "com.sertacozercan.Kaset" AND category == "Player"'
```

### Reading it afterwards

`log stream` is the live side of the same store `log show` reads. Once the run is over, the past
window is still there:

```bash
# Everything the app logged in the last five minutes.
log show --last 5m --info --debug --style compact \
  --predicate 'subsystem == "com.sertacozercan.Kaset"'

# One stage of one subsystem — the cast log names the stage it stopped at.
log show --last 5m --predicate 'subsystem == "com.sertacozercan.Kaset"' --info | grep -i cast

# A temporary probe (see below).
log show --last 3m --info --debug --predicate 'process == "Kaset"' | grep LayoutProbe
```

(That last form is from [testing.md](testing.md), along with the rest of the UI-test workflow.)

### `<private>` and why some values are hidden

`os.Logger` redacts interpolated values that are not marked `privacy: .public`, so an entry can read
`... <private>` where a value was expected. That is the logger's default and it is deliberate — it is
what keeps a token out of the log store.

The app's *diagnostic* entries build their message as a plain `String` and log it
`\(message, privacy: .public)`, so the numbers they carry — widths, collapse states, surface hosts —
are readable. Anything the app does not mark stays redacted; do not "fix" that by publishing values
that are sensitive. Never log cookies, tokens or `SAPISID` values, marked or not.

Revealing the redacted values for a local debugging session is possible with the log store's own
switch (`log config --mode "private_data:on"`, which needs administrator rights) — but the right
answer for a value worth seeing is usually to log the part that matters as its own public entry.

## Console.app

Console.app shows the same stream and is easier to keep open. Filter on the subsystem and category:

```
subsystem:com.sertacozercan.Kaset
subsystem:com.sertacozercan.Kaset category:Player
subsystem:com.sertacozercan.Kaset category:UI
```

Select a process in the sidebar first, then use the Action menu → **Include Info Messages** and
**Include Debug Messages**; without those, the app's own `info`/`debug` entries are hidden there too.

## Which build to watch

`Scripts/compile_and_run.sh` kills any running instance, packages the app, launches it and verifies it
stayed up:

```bash
Scripts/compile_and_run.sh          # build, package, relaunch
Scripts/compile_and_run.sh --test   # run the unit suite first
```

It launches `.build/app/Kaset.app` through `open`, so the app is a normal app — real account, real
Keychain — and its logs are the ones the commands above see. The UI-test path is different: it runs a
build in *mock* mode with a marker file, and its workflow lives in [testing.md](testing.md).

Two more things worth knowing while debugging a view:

- **UI test mode** is `UITestConfig.isUITestMode` (launch argument, environment variable, or the
  marker file). Mock data and mock services come from it; anything driven by real content will look
  empty under it.
- **`PerfHUD`** (`PerfHUD.isEnabled`, `PerfHUDOverlay`) is the in-app overlay used for the scroll and
  WebView diagnostics; its switches (`showsWebLayer`, `showsPlayerBar`) hide layers that are otherwise
  in the way.

## The diagnostics this app leaves in place

Rather than reach for a debugger, the window and player code logs the state that the bugs there are
always about. They are `debug`/`info` entries on `player`/`ui`, so the commands above show them:

| Entry | What it answers |
|-------|-----------------|
| `Mini player button pressed: mode=… pending=… detached=… showing=…` | Whether the PiP button's press arrived, which branch it took, and the state it decided from |
| `Mini player panel requested/closed: visible=… surfaceHost=…` | Whether the panel window actually appeared, and who owns the shared player surface |
| `Main window player layer hosted=…` | Whether the main window's WebView layer is mounted or standing down for the panel |
| `Shell layout: split=… inspectorCollapsed=… liveResize=… minWidth=…` | The split view's state during (and at the end of) a resize, which is where a collapsing column shows up |
| `Shell minimum window width: … (columnOpen=…)` | The window's minimum restated for the panes that are open: the panes' own minimums plus the dividers, never below the floor the app states (900). 967 with the Now Playing column closed, 1267 with it open |
| `Shell window widened to its minimum: content=… minimum=… columnOpen=…` | A frame below that minimum — a restored one from a build with different arithmetic, or the gap writing an opened column leaves — being corrected by growing the window. The window is never shrunk this way, and a reader's divider drag never resizes it |
| `Shell pane limits: split=… pageMin=… sidebar=[…,…] inspector=[…,…] columnOpen=… panes=…/…` | How wide each side pane may be at the width the split view has, so the page keeps its own minimum and the three panes always add up |
| `Shell overflow: the split view is … wide in a …pt window (page=… pageMin=… columnOpen=…)` | A pane being drawn past the window's edge — the one symptom all of this arithmetic exists to prevent. Seeing it means the page's content needs more than `MainWindow.Layout.pageMinWidth` states (measured at 765) |
| `Now Playing column collapsed=… source=reader\|app` | Whether the column collapsed from a click on its toggle or from the app's own state |
| `Sidebar surface: windowOpaque=… effectViews=…` | The navigation sidebar's actual compositing: which `NSVisualEffectView`s exist, what material and blending mode they ask for, and whether the window behind them is transparent |
| `Sidebar surface rows: sourceList style=… rowEmphasized=… hostAppearance=… hostLabelColor=…` | What the sidebar's `List` built: the table's style, whether its rows are emphasized, and the appearance the label colour resolves against (`hostLabelColor=a=0.70` under `VibrantLight`; the plain `Aqua` value is 0.85) |
| — | **How a UI report was turned into these lines**: [`.freebuff/skills/macos-ui-debugging/SKILL.md`](../.freebuff/skills/macos-ui-debugging/SKILL.md) — the offscreen probe, the real key-window run driven by `launchctl setenv` + `open`, the pixel probe over `CALayer.render(in:)`, and what each harness cannot see |
| `Sidebar ink: opaque=… darkest=…` / `Sidebar ink bands: rows=[ink=… red=…]` | What the sidebar's rows actually **render**: the layer tree is drawn into a bitmap and the darkest pixel and strongest red in the navigation-rows band and the profile band are measured. Full-contrast text is ≈0.000, the dimmed rendering a container-less `NavigationLink` gives its label is ≈0.498, and the Kaset-red icons show a red channel well above green/blue |
| `Sidebar surface paint: …` | Anything opaque drawn over the sidebar's material — a scroll view, clip view or table background, or a layer colour |
| `Toolbar takeover: installed=… window=… identifier=… items=…` | What the window's toolbar was at the moment the app installed its own: `window=other identifier= items=1` is SwiftUI's own toolbar having replaced the app's, and `window=nil` is it having taken the toolbar away altogether — the two states the titlebar shows as "the bar on top disappears and the controls are gone" |
| `Toolbar replaced, restoring the app's: …` | The app noticing a replacement and re-taking the toolbar, which is the whole of the fix: this line appears on every push into, and pop out of, a page that states a `navigationTitle` |
| `Toolbar title hidden: the page has a back control to lead its region` | The window title giving the page region's leading slot to the back control. AppKit draws the title at that edge and lays the region's items out after it, so the back control only reaches the left of the page while the title is out of the way (see `WindowShellController.applyTitleVisibility`) |
| `Now Playing column top inset: …` | The toolbar band the column's content is inset by — the amount the cover art is pulled up over, so the artwork reaches the window's top edge |

`Sidebar surface` (with its `rows` and `paint` lines) is the one that answers "the sidebar looks grey":
it prints every `NSVisualEffectView` in the window, whether it wraps or sits inside the sidebar's view,
the state of the sidebar's source-list rows, and the appearance plus resolved label colour the SwiftUI
content is drawing in. It is deliberately split across several entries, because `os_log` truncates a long
message in the *middle* — which is where the answer used to land.
