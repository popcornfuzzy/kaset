# Kaset+

<img src="docs/logo-reveal-banner.webp" alt="Kaset Logo Reveal Banner" width="100%"> 

A native macOS YouTube Music client built with Swift and SwiftUI.

This is a fork of [Kaset from sozercan](https://github.com/sozercan/kaset) that removes the option to watch YouTube videos completely, focusing solely on music playback and also add some additional features like the add to playlist button in the player bar and a fullscreen view for lyrics.

<img src="docs/screenshot.png" alt="Kaset Screenshot">

## Features

- ⏯️ **Add Songs to Playlist** – Easily add songs to your playlists from the player bar 
- 🎵 **Native macOS Experience** — Apple Music-style UI with Liquid Glass player bar and clean sidebar navigation
- 🎛️ **System Integration** — Now Playing in Control Center, media key support
- 📳 **Trackpad Support** — Tactile feedback on Force Touch trackpads for player controls and navigation
- 🔊 **Background Audio** — Music continues playing when the window is closed; stops on quit
- ⌨️ **[Keyboard Shortcuts](docs/keyboard-shortcuts.md)** — Full keyboard control for playback, navigation, and more
- 🧭 **Explore** — Discover new releases, charts, and moods & genres
- 🎙️ **Podcasts** — Browse and listen to podcasts with episode progress tracking and support for video
- 📚 **Library Access** — Browse your playlists, liked songs, and subscribed podcasts
- 🔍 **Search** — Find songs, albums, artists, playlists, and podcasts
- 📜 **Lyrics** — View plain and synced lyrics with line-by-line highlighting when timing data is available
- 💾 **Lyrics Caching** – Caches lyrics of songs you have played so lyrics load faster on future plays  
- 📃 **Queue Management** — View, reorder, shuffle, and clear your playback queue
- 📣 **Share** — Share songs, playlists, albums, and artists via the native macOS share sheet
- 🧑‍🎤 **Fullscreen View** – Open fullscreen view to focus on the lyrics with beautiful animations
- ﹗ **Only Youtube Music – no Youtube bloat** – This fork removes the option to watch Youtube videos completely 
- 📼 **Picture in Picture** – Watch music videos in a small window along with your song (unfortunately not supported with song only tracks)
  

## Requirements

- macOS 26.0 or later
- [Google](https://accounts.google.com) account

## Installation

### Download

Download the latest release from the [Releases](https://github.com/popcornfuzzy/kaset/releases) page.


**Note:** The app is not signed.
If you downloaded the app manually, you can clear extended attributes (including quarantine) with:
> ```bash
> xattr -cr /Applications/Kaset.app
> ```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture, and coding guidelines.

We welcome AI-assisted contributions! You can submit traditional PRs or **prompt requests** — share the AI prompt that generates your changes, and maintainers can review the intent before running the code. See the [AI-Assisted Contributions](CONTRIBUTING.md#ai-assisted-contributions--prompt-requests) section for details.

## Disclaimer
Kaset is an unofficial application and not affiliated with YouTube or Google Inc. in any way. "YouTube", "YouTube Music" and the "YouTube Logo" are registered trademarks of Google Inc.
