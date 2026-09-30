# ADR-0027: Stable Code Signing Identity for Distributed Builds

## Status

Accepted

## Context

Kaset keeps two kinds of secrets in the macOS Keychain: the YouTube Music auth cookie
archive (`KeychainCookieStorage`) and the Last.fm session key and username
(`KeychainCredentialStore`). That is three items, and the app reads them on launch.

macOS does not simply match an item to a bundle identifier. Each item records the
**designated requirement** of the app that created it, and any later process whose
requirement does not match is asked for the login keychain password before it can read
the item. An ad-hoc signature has no certificate to anchor a requirement to, so codesign
gives it one based on the build's own code:

```
# codesign -d -r- /Applications/Kaset.app
designated => cdhash H"032fb81adb5a8fdca03830868db109ccaa46b31b"
```

Every build produces a different cdhash, so from the Keychain's point of view every
install is a different application. Users were asked three times for their password
after every install, and the "Always Allow" button never stuck, because the app it
granted access to no longer existed by the next install. `docs/testing.md` documents the
same symptom as a UI-test hazard, which is why the test suite runs in mock mode.

## Decision

Distributed builds are signed with a certificate instead of ad-hoc:

- Locally, `Scripts/build-app.sh` keeps `KASET_SIGNING=dev` (the default) as the identity,
  which uses the developer's Apple Development certificate.
- In CI, `Scripts/import-signing-identity.sh` imports a base64 `.p12` from the
  `KASET_SIGNING_P12` and `KASET_SIGNING_P12_PASSWORD` repository secrets into a throwaway
  keychain under `.build/`, prints the identity's fingerprint, and `dev-build.yml` and
  `release.yml` pass that fingerprint to `build-app.sh` as `APP_IDENTITY`.
- The temporary keychain is removed by a `--cleanup` step that runs even on failure, and
  the staged `.p12` never leaves the build directory or becomes world readable.
- When no identity is configured, the build still works: it falls back to ad-hoc signing
  and both the workflow and `build-app.sh` say so loudly in the log.
- Every build uses the same bundle identifier, `com.popcornfuzzy.Kaset`. The identifier is part
  of the code requirement (`identifier "<bundle id>"`), and identifiers are case sensitive, so a
  build that spelled it differently — a local `Scripts/.env` did, in lowercase — had a different
  Keychain identity from the released app and prompted for its own items. `build-app.sh` warns
  when a certificate-signed build overrides the identifier; only throwaway builds (the
  `Scripts/test-update-flow.sh` harness) may.
- The Keychain reads that produce the prompts run off the main actor, so an unanswered prompt
  leaves the app usable instead of freezing it — including its scheduled Sparkle check. The
  prompts are inconvenient; they must not be an outage. See
  [../common-bug-patterns.md](../common-bug-patterns.md).

The identity lives in a keychain of its own, which `codesign` does not look at by
default: it resolves identities through the calling user's keychain search list, and
`security create-keychain` deliberately leaves a new keychain off that list. Signing then
fails with `<fingerprint>: no identity found` even though
`security find-identity <keychain>` reports the identity as valid — the failure mode that
broke every signed `Dev Build`. Two things prevent it now:

- `build-app.sh` passes `--keychain` when a caller supplies `APP_IDENTITY`, which tells
  `codesign` exactly where the identity is. The normal search path is still consulted for
  the certificates that complete the chain, so Apple's intermediate certificates keep
  working.
- `import-signing-identity.sh` also prepends the keychain to the user search list, for the
  tooling that only understands that list, and saves the previous list so `--cleanup`
  restores it instead of leaving a dangling path behind.

A certificate-derived requirement is stable across builds:

```
designated => identifier "com.popcornfuzzy.Kaset" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: ..."
```

So an item created by release N is trusted by release N+1, and "Always Allow" keeps
working.

## Renewal

An Apple Development certificate is valid for one year. `Scripts/import-signing-identity.sh`
prints the expiry on every signed build
(`Certificate valid until: Oct  1 06:28:52 2026 GMT`) and raises a workflow warning when
less than 60 days remain, so renewal is a scheduled chore rather than a release-day
surprise. The date is also visible in Keychain Access under *My Certificates*.

To renew:

1. Xcode → Settings → Accounts → select the team → **Manage Certificates** → `+` →
   **Apple Development**. Xcode issues a fresh one-year certificate into the login
   keychain; the old one can be left to expire.
2. Keychain Access → *My Certificates* → right-click the new identity (the certificate
   *with* its private key) → **Export** → save a `.p12` with a password.
3. `base64 -i <file>.p12 | tr -d '\n' | pbcopy`, then replace the `KASET_SIGNING_P12`
   repository secret, and set `KASET_SIGNING_P12_PASSWORD` to the export password.
4. Before pushing the secret anywhere, check it locally:

   ```bash
   KASET_SIGNING_P12="$(cat file.p12.b64)" KASET_SIGNING_P12_PASSWORD='…' \
     Scripts/import-signing-identity.sh
   Scripts/import-signing-identity.sh --cleanup
   ```

   It prints the identity and its expiry, or explains why the `.p12` is unusable.
5. Delete the exported `.p12`; the secret is now its only home.

A renewal changes the certificate's leaf hash, so installed copies ask for Keychain access
once more and are then trusted again. Nothing else depends on the identity: Sparkle still
validates updates by the EdDSA signature on the feed.

## Consequences

- Keychain prompts stop after a single allow per item, and only come back if the signing
  certificate itself changes.
- Existing installs see one last round of prompts, because their items are owned by the
  cdhash of whatever build wrote them last. Clicking "Always Allow" then is enough.
- Apple Development certificates expire after a year, and a renewed certificate has a
  different common name, so a renewal reintroduces the prompts. A Developer ID
  certificate lasts five years, and is also the prerequisite for the notarization
  mentioned in [ADR-0019](0019-release-pipeline-and-appcast-publication.md).
- Ad-hoc signing remains possible (contributors, forks, CI without the secrets). It is a
  development convenience: those builds prompt for Keychain access on every install.
- Verified signing does not change how Sparkle validates an update: Sparkle still accepts
  the download on its EdDSA signature, and a certificate-signed build additionally has a
  stable code requirement, which removes the
  `Code signature of the new version doesn't match the old version` note from
  `Autoupdate`'s log.

Not done here: the modern *data protection* keychain (`kSecUseDataProtectionKeychain`),
which keys item access to the team's keychain access group rather than a per-item ACL and
would survive even a certificate renewal. It requires an `application-identifier`
entitlement, which only arrives with a provisioning profile, and Kaset is packaged by
`codesign` directly rather than by Xcode's archive and export step. Switching to it is
worth revisiting if the release process ever gains a profile.

Alternatives considered and rejected:

- **An ACL that trusts every application.** Any process running as the user could read
  the session cookies silently, which is exactly what the Keychain is there to prevent.
- **Storing the credentials in the sandbox container instead.** No prompts, but the
  contents sit in a plain file that any process running as the user can read.
- **A custom ad-hoc requirement such as `identifier "com.popcornfuzzy.Kaset"`.** It is
  stable, but a requirement without an Apple anchor can be claimed by any application, so
  it protects nothing.
- **Reducing the number of items** (for example one Last.fm blob instead of two) which
  lowers the prompt count without addressing why the prompts happen at all.
