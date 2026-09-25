# ADR-0019: Release Pipeline and Appcast Publication

## Status

Accepted. Refines the release process described in [ADR-0007](0007-sparkle-auto-updates.md).

## Context

Releases are built by `.github/workflows/release.yml` and published to GitHub Releases, with
Sparkle picking up new versions from `appcast.xml` in the repository root. The pipeline that
existed before this decision failed in ways that never reproduced locally:

- **The unit-test step failed on CI but passed locally.** 4 of 11 recorded `Release Build` runs
  died at `Run unit tests`, and never at any later step. The suite is timing-sensitive
  (`CanvasVideoViewTests` needs real AVFoundation playback, several tests wait on fixed sleeps),
  and a paravirtualized runner is slower than a developer machine. Those same suites are
  documented in [testing.md](../testing.md) as environment-dependent and as never gating a merge
  or a release — but the release command did not exclude them, so the documented policy and the
  actual gate disagreed.
- **A manual run published a version called `main`.** The workflow took `github.ref_name` as the
  version, so a `workflow_dispatch` on a branch produced a release named `main`, an asset named
  `kaset-main.dmg`, and a feed item whose `sparkle:shortVersionString` was `main`. It had to be
  reverted by hand twice.
- **The feed step overwrote the feed.** It regenerated the whole file from a heredoc, so every
  previously published version disappeared from the feed and older clients lost their upgrade path.
- **The signature was scraped out of tool output.** `sign_update`'s stdout was parsed with
  `grep -o`/`sed`, and any signature that failed to parse silently skipped the feed update instead
  of failing the run — a release that installed nothing looked successful.
- **The feed could advertise an unpublished download.** The DMG was attached to a *draft* release
  while the feed immediately pointed at its asset URL, which is a 404 for every user until the
  release is published by hand.

## Decision

1. **A tag is the only source of a version.** `.github/workflows/release.yml` accepts `vMAJOR.MINOR[.PATCH][-prerelease]`
   from a tag push, or from a `tag` input on a manual run. Anything else stops the job before an
   artifact exists, and the checkout is compared against the tag's commit so a moved tag cannot
   publish the wrong code.

2. **The release gate is the deterministic part of the suite, with one retry.**
   `KasetUITests`, `MusicIntentIntegrationTests`, and `CanvasVideoViewTests` are excluded, matching
   the policy already documented in [testing.md](../testing.md). The remaining suites are
   deterministic; a single retry absorbs a residual flake, and a real failure still fails both
   attempts. `tests.yml` runs the same command so pull requests and releases are gated identically.

3. **Build, then draft. Publish, then feed.** `release.yml` produces a verified universal `.app`
   (`arm64` + `x86_64`, version and `SUPublicEDKey` checked) and attaches the DMG to a draft
   release. `.github/workflows/appcast.yml` runs on `release: published`, and signs the DMG that is
   actually downloadable at that moment. An update is therefore only ever advertised once its
   download URL is public. Prereleases are kept out of the stable feed, because Sparkle compares
   `CFBundleVersion` and a prerelease is always built later than the last stable release.

4. **The feed is regenerated with Sparkle's own tool, seeded from the committed feed.**
   `Scripts/generate-appcast.sh` copies the repository's `appcast.xml` next to the released DMG and
   runs `generate_appcast --maximum-versions 0`, which *updates* that feed: existing items keep
   their signatures and history is preserved. The private key is passed over stdin (`--ed-key-file -`),
   so it never reaches the filesystem or the process table.

5. **Every claim the pipeline makes is verified before it is published.** The DMG must mount and
   contain `Kaset.app`; the generated item must carry a `sparkle:edSignature` and point at the
   release being published; and `sign_update --verify` must accept that signature against the DMG.
   A missing or mismatched key fails the run loudly instead of committing an unsigned feed, which
   is important because `generate_appcast` *strips* the signature from an existing item when it
   cannot sign with the supplied key.

6. **Packaging lives in `Scripts/`, not in workflow YAML.** `Scripts/create-dmg.sh` prefers the
   styled `create-dmg` layout and falls back to a plain `hdiutil` image (verified by mounting)
   when `create-dmg` is unavailable or its Finder-driven layout fails on a runner, so the release
   cannot be blocked by a GUI-only tool. Both scripts are directly runnable locally.

## Consequences

### Positive

- The release gate fails only for real failures; the environment-dependent suites that caused every
  recorded CI failure no longer gate a release.
- The feed cannot be corrupted by a manual run, cannot lose history, and can never advertise an
  unsigned item, a draft asset, or a prerelease to stable clients.
- A broken key or a build with no `SUPublicEDKey` fails the pipeline instead of silently shipping an
  app that can never update.
- Release logic is testable locally: the shell steps are validated with `bash -n`, and both scripts
  run end to end against a scratch directory.

### Negative

- Publishing is a manual step, so the feed does not update until the draft release is published. That
  is the price of never advertising a URL that 404s.
- Re-running `release.yml` for a tag that is *already published* replaces the DMG under a feed entry
  that still holds the previous signature. The run warns loudly and the **Update Appcast** workflow
  has to be re-run for that tag; the alternative (rewriting a published release's asset silently)
  would leave users downloading a DMG their app rejects.
- Excluding suites means the release is not gated on Apple Intelligence parsing or real AVFoundation
  playback. Those remain nightly coverage in `tests.yml`.

### Neutral

- The pipeline is now two workflows instead of one, because the feed update has to be driven by the
  publish event rather than by the tag push.
