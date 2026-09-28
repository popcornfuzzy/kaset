# Keyboard Shortcuts

Kaset provides keyboard control for playback and navigation while preserving standard macOS window shortcuts.

## Playback

| Shortcut | Action                              |
| -------- | ----------------------------------- |
| `Space`  | Play / Pause                        |
| `⌘→`     | Next track (forward 30s for a podcast episode) |
| `⌘←`     | Previous track (back 15s for a podcast episode) |
| `⌘↑`     | Volume up                           |
| `⌘↓`     | Volume down                         |
| `⌘S`     | Toggle shuffle                      |
| `⌘R`     | Cycle repeat mode (Off → All → One) |

Mute is still available from the Playback menu and AppleScript, but Kaset intentionally does not assign a default mute shortcut so the native macOS minimize shortcut (`⌘M`) continues to work.

All of these work in the fullscreen now-playing player as well as in the main window. The player
installs a key monitor for the length of a presentation that offers each key to the app's menu before
anything inside the player can take it, so a shortcut there never depends on which control in the
player was clicked last (see [ADR-0026](adr/0026-fullscreen-key-routing.md)).

## Navigation

| Shortcut | Action           |
| -------- | ---------------- |
| `⌘1`     | Go to Home       |
| `⌘2`     | Go to Explore    |
| `⌘3`     | Go to Library    |
| `⌘F`     | Go to Search     |
| `⌘K`     | Open Command Bar |
