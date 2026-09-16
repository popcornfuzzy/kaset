# ADR-0016: `.lproj` String Files as the Localization Source of Truth

## Status

Accepted

Supersedes [ADR-0012: Localization Strategy (String Catalogs)](0012-localization-strategy.md).

## Context

`swift build` (the default build system, and therefore the command documented in
`AGENTS.md`) failed:

```
error: Multiple commands produce '.../Kaset_Kaset.bundle/Contents/Resources/ar.lproj/Localizable.strings'
error: Multiple commands produce '.../Kaset_Kaset.bundle/Contents/Resources/ko.lproj/Localizable.strings'
error: Multiple commands produce '.../Kaset_Kaset.bundle/Contents/Resources/tr.lproj/Localizable.strings'
```

Two localization mechanisms had coexisted in `Sources/Kaset/Resources`:

| Mechanism | Locales | Keys |
|-----------|---------|------|
| `Localizable.xcstrings` | `ar` 267, `tr` 267, `ko` 4, `id` 1 | 267 |
| `<lang>.lproj/Localizable.strings` | `en` 279, `ar` 279, `ko` 290, `tr` 279 | 279-290 |

Both are recognized by the `.process("Resources")` rule, so SwiftPM generated two
build tasks writing the same output path for each locale defined in both
(`ar`, `ko`, `tr`). `en` did not collide (the catalog declares no `en`
localization, `en` being its source language) and `id` did not collide (no
`id.lproj` existed).

A key-by-key comparison showed the catalog was a **strict subset** of the
`.lproj` files: zero catalog-only keys for `ar`, `ko`, and `tr`, and zero value
mismatches. The catalog arrived through the merge commit `8ffcee1` and was never
updated afterwards — it lacks the entire History feature's strings
(`History`, `Listening History`, `Keep listening even when the window is
closed`, …) that the `.lproj` files already contain. Its only unique content was
a single dormant entry, `"Home" -> "Beranda"` (`id`).

[ADR-0012 (localization strategy)](0012-localization-strategy.md) declared the
catalog the single source of truth, and `Scripts/build-app.sh` compiled it with
`xcrun xcstringstool`. That ADR was never indexed (the ADR index maps 0012 to
*Synced Lyrics Provider Architecture*), carries a duplicated number, and is
still in `Proposed` status; its own consequences section flagged that
"SPM + xcstrings is relatively new" with Phase 0 validating it before committing.
That validation has now failed: a catalog cannot share a target's resources with
`.lproj` files of the same name.

## Decision

`.lproj/Localizable.strings` files are the single source of truth for
translations. `Sources/Kaset/Resources/Localizable.xcstrings` was deleted, and no
string catalog may be added back alongside the `.lproj` files.

The string-wrapping API surface from ADR-0012 is unaffected and still applies —
only the storage format changed:

| Context | Pattern |
|---------|---------|
| Static `Text` in SwiftUI | implicit `LocalizedStringKey` |
| Computed properties, models, non-SwiftUI | `String(localized:)` |
| Interpolated strings | `String(localized:)` with interpolation |
| Accessibility labels | `String(localized:)` |

Packaging follows suit: `Scripts/build-app.sh` no longer runs `xcstringstool`,
and instead mirrors each packaged `*.lproj` into the app's top-level `Resources`
directory, preserving the previous intent that both the SwiftPM resource bundle
and `Bundle.main` lookups can resolve packaged localizations.

The catalog's one unique entry was preserved as `Sources/Kaset/Resources/id.lproj/Localizable.strings`.

## Consequences

### Positive

- **The documented build commands work again** — `swift build` and
  `swift test --skip KasetUITests` succeed under the default build system, with
  no need for `--build-system native`.
- **One mechanism, no divergence** — a translation now has exactly one home, so
  the two copies cannot drift apart as they did between `8ffcee1` and today.
- **No translation is lost** — the `.lproj` files were the superset, and the
  catalog's single unique string was migrated.
- **Comments survive** — the developer comments that lived in the catalog
  (`Playlist track count`, `Button to retry failed playback`, …) were already
  mirrored into the `.lproj` files.

### Negative

- **No String Catalog editor** — Xcode's translation-status UI and its automatic
  extraction of new `LocalizedStringKey` usages are unavailable; keys are added
  by hand to each `.lproj` file.
- **Plural variants need `.stringsdict`** — Arabic's six plural categories cannot
  be expressed in a `.strings` file. Today the only count strings use the simple
  `"%lld songs"` format, so nothing regresses; a language needing real plural
  rules requires a per-locale `Localizable.stringsdict` (never a catalog, which
  would reintroduce the collision).
- **Non-UTF-16 encoding is unvalidated by tooling** — the files are plain text
  that only SwiftPM's resource rule checks, not a compiler.

### Neutral

- Adding a language means copying `en.lproj`, translating the values, and adding
  the code to `CFBundleLocalizations` in `Scripts/build-app.sh` if it should be
  advertised. `ko` and `tr` already ship without being advertised, and `id` now
  follows that same pattern.

## Alternatives Considered

1. **Merge the `.lproj` content into the catalog and delete the `.lproj` files**
   — would have kept the Apple-recommended format, but required mechanically
   rewriting ~850 translation entries (286 of them Korean) into a 4,500-line JSON
   file: high churn, real risk of corrupting translations, and no user-visible
   gain, since the `.lproj` files already contained everything the catalog had.
2. **Keep the catalog and delete the `.lproj` files** — would have silently
   dropped 286 Korean strings and roughly a dozen keys per Arabic/Turkish locale,
   including the History feature's strings.
3. **Move the catalog outside the target's `Resources`** — would have unblocked
   the build while leaving a stale second copy of the translations in the
   repository, which is exactly the duplication that caused this bug.
