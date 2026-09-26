# ADR-0022: Per-Provider Lyrics Settings with Priority and Status

## Status

Accepted

Supersedes the provider-selection decision in
[ADR-0021](0021-betterlyrics-provider.md).

## Context

Lyrics providers were chosen through a single preset picker (`LyricsProviderChoice`):
"BetterLyrics + Paxsenix + KuGo + LRCLIB", "BetterLyrics", "KuGo + LRCLIB", or
"LRCLIB". That model could not express the combinations users actually want —
enabling BetterLyrics and LRCLIB but not Paxsenix, for example — and it bundled
settings into the General tab.

## Decision

Replace the preset picker with a per-provider model owned by `SettingsManager`:

- `LyricsProviderID` enumerates the sources (`betterLyrics`, `paxsenix`,
  `kugou`, `lrclib`).
- `lyricsProviderOrder` stores the priority order (highest first).
- `disabledLyricsProviders` stores the switched-off set separately, so
  re-enabling a provider restores it to its previous priority.
- `enabledLyricsProviders` derives exactly what `SyncedLyricsService` searches.

The legacy `settings.lyricsProvider` value is migrated once into the new model on
first launch, so no user loses their previous choice.

A dedicated **Lyrics** settings tab (`LyricsSettingsView`) is added as the first
tab. It hosts the enable toggle, per-provider toggles with drag-and-chevron
reordering, and a collapsed **Provider Status** card. The status card probes each
provider's host concurrently (`LyricsProviderStatusService`) and renders a
red/green LED: any response below `5xx` is green, since a `404` on a root path
still means the host is up.

## Consequences

- Users can enable any subset of providers and choose their priority.
- Changing the enabled set or order reloads the service and clears the lyrics
  cache, so a cached lower-priority result cannot mask a newly preferred source.
- The status probe performs unauthenticated GETs to provider hosts; it is
  opt-in (collapsed card) and never logged with credentials.
- Reordering is live and animated: dragging a provider row (the handle is its
  affordance) runs a `DropDelegate` that moves the dragged provider the moment
  it enters another row, so the list shifts out of the way as the pointer
  travels. The service reloads once, on drop, rather than on every hover move.
  Explicit up/down chevrons and a context menu remain as accessible fallbacks,
  since `.onMove` reordering inside a grouped `Form` is not dependable on macOS.
- New user-facing strings ship in the English source of truth; other locales
  fall back to English until translated.
