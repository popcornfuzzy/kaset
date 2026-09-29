# ADR-0007: Sparkle Auto-Updates

## Status

Accepted

## Context

Kaset is distributed outside the Mac App Store via GitHub Releases and Homebrew Cask. Users need a reliable way to receive updates without manually downloading new versions. The lack of automatic updates creates friction for users and delays security fixes and feature rollouts.

Requirements:
- **Non-App Store distribution**: App Store's built-in update mechanism is not available
- **User trust**: Updates must be cryptographically signed to prevent tampering
- **Seamless UX**: Updates should happen with minimal user intervention
- **macOS native**: The solution should follow Apple's design patterns
- **Sandbox compatible**: Must work with macOS app sandboxing

## Decision

We integrate [Sparkle 2.x](https://sparkle-project.org/) for automatic update checks and installation.

### Key Design Choices

1. **Sparkle 2.x via Swift Package Manager**
   - Modern Swift-compatible API
   - Supports sandboxed apps via XPC services
   - EdDSA (Ed25519) signatures for security
   - Automatic delta updates for bandwidth efficiency

2. **Appcast hosted on GitHub**
   - `appcast.xml` in repository root
   - Served via GitHub raw content
   - Updated by CI on each release

3. **EdDSA code signing**
   - Private key stored in GitHub Secrets
   - Public key embedded in app bundle
   - Signatures verified before installation

4. **User preferences**
   - Toggle for automatic checks (default: enabled)
   - Manual "Check for Updates..." menu item
   - Settings UI showing last check date

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        KasetApp                              │
│  ┌─────────────────┐    ┌────────────────────────────────┐  │
│  │  UpdaterService │───▶│ SPUStandardUpdaterController   │  │
│  │  (@Observable)  │    │        (Sparkle)               │  │
│  └────────┬────────┘    └───────────────┬────────────────┘  │
│           │                             │                    │
│           ▼                             ▼                    │
│  ┌─────────────────┐    ┌────────────────────────────────┐  │
│  │GeneralSettings  │    │    Sparkle Update UI           │  │
│  │  View (Toggle)  │    │  (Download/Install dialogs)    │  │
│  └─────────────────┘    └────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │   GitHub (appcast.xml)        │
              │   https://raw.githubusercontent│
              │   .com/sozercan/kaset/main/   │
              │   appcast.xml                 │
              └───────────────────────────────┘
```

### Update Flow

1. **On app launch** (if automatic checks enabled):
   - Sparkle fetches `appcast.xml` from GitHub
   - Compares version against current app version
   - If newer version exists, shows update dialog

2. **User clicks "Install Update"**:
   - Sparkle downloads the DMG from GitHub Releases
   - Verifies EdDSA signature
   - Extracts and replaces app bundle
   - Relaunches the app

3. **Manual check** (Kaset → Check for Updates...):
   - Same flow but user-initiated
   - Shows "You're up to date" if no update available

### Release Process

> The concrete pipeline is defined by [ADR-0019](0019-release-pipeline-and-appcast-publication.md),
> which keeps the feed out of the tag-push job: a release is built into a draft, and the feed is
> signed once that release is published, so an update is never advertised before its download URL
> is public.

1. Tag new version: `git tag v1.2.3`
2. CI builds, archives, and creates DMG, then opens a draft release with it
3. The release is published, which signs the DMG with the EdDSA key
4. CI updates `appcast.xml` with the new entry and commits it
5. Users receive the update on their next check

## Consequences

### Positive

- **Seamless updates**: Users receive updates automatically without visiting GitHub
- **Security**: EdDSA signatures prevent malicious update injection
- **Standard UX**: Sparkle is the de facto standard for macOS app updates
- **Delta updates**: Sparkle can generate deltas to reduce download size
- **Rollback support**: Users can skip versions if needed
- **No infrastructure cost**: Hosted entirely on GitHub

### Negative

- **Framework dependency**: Adds ~2MB to app size (Sparkle.framework)
- **Key management**: EdDSA private key must be secured in CI secrets
- **Manual appcast updates**: Initial setup requires manual appcast management
- **Sandbox complexity**: May require XPC entitlements for sandboxed installation

### Neutral

- **Info.plist configuration**: Requires `SUFeedURL`, `SUPublicEDKey` entries
- **Homebrew Cask**: Users installing via Cask may see duplicate update prompts

## Implementation Notes

### Required Info.plist Keys

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/sozercan/kaset/main/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>YOUR_BASE64_ENCODED_PUBLIC_KEY</string>

<key>SUEnableAutomaticChecks</key>
<true/>

<key>SUScheduledCheckInterval</key>
<integer>86400</integer>

<!-- Required because Kaset is sandboxed; see Sandboxed Installation below. -->
<key>SUEnableInstallerLauncherService</key>
<true/>
```

### Sandboxed Installation

Kaset runs in the sandbox (`com.apple.security.app-sandbox`), so Sparkle cannot install an update
from inside the app process: mounting the downloaded disk image and replacing a bundle under
`/Applications` are both outside what the sandbox permits. Sparkle hands the work to its
`Installer.xpc` service, which runs outside the sandbox, and talks to it over Mach services named
after the **host bundle identifier** — `<bundle id>-spki` for the installer connection and
`<bundle id>-spks` for installation status.

Two settings therefore have to line up, and when either is missing the failure looks identical:
the update downloads and then reports `An error occurred while launching the installer. Please try
again later.`

1. `SUEnableInstallerLauncherService` in `Info.plist` tells Sparkle to route installation through
the XPC service. Without it Sparkle tries to submit the installer job itself and the sandbox
refuses the authorization request (`Failed to gain authorization required to update target`).
2. `Kaset.entitlements` grants `com.apple.security.temporary-exception.mach-lookup.global-name` for
`<bundle id>-spks` and `<bundle id>-spki`. Without it the service is unreachable even when it is
enabled.

The service names embed the bundle identifier, so the entitlements file writes them as
`$(PRODUCT_BUNDLE_IDENTIFIER)`. Xcode expands that when it signs; `codesign` does not, which is why
`Scripts/build-app.sh` renders the file through `Scripts/generate-entitlements.sh` first. The
release workflow re-checks both the key and the rendered exceptions on the packaged app before it
publishes a DMG.

Sparkle's own helpers are re-signed by `Scripts/build-app.sh` with the Hardened Runtime option kept
and the Downloader service's entitlements preserved, following
[Sparkle's code signing instructions](https://sparkle-project.org/documentation/sandboxing/#code-signing).
Dropping that option changes the helpers' code requirements and is a `--deep`-style mistake that
only shows up at install time.

`Scripts/test-update-flow.sh` proves the whole path end to end on a developer machine: it builds two
versions of Kaset, serves a signed appcast on `localhost`, and lets the older build update itself.
See [testing.md](../testing.md#update-installation-sparkle).

#### Migration Note

The entitlement belongs to the **installed** build, not to the update: the running app is the one
that has to reach the installer service. Releases published before this was fixed (0.7 and 0.7.1)
ship without it, so their copy of Kaset cannot install any later update, including the first fixed
one. Those users have to download that release from GitHub once, after which automatic updates work
again. This is worth a line in the release notes rather than a silent dead end.

### Key Generation

```bash
# Generate EdDSA keypair (run once, store private key securely)
./DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

### Signing a Release

```bash
./Tools/sign-update.sh ./build/Kaset-v1.2.3.dmg
```

## References

- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [Sparkle GitHub Repository](https://github.com/sparkle-project/Sparkle)
- [Apple Code Signing Guide](https://developer.apple.com/documentation/security/code_signing_services)
