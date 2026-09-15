# ADR-0015: Google Cast Support via Local Audio Streaming

## Status

Accepted

## Context

AirPlay support was removed (see [ADR-0010](0010-airplay-fix.md), now superseded). AirPlay could not be made
reliable for this app: WebKit ties the AirPlay session to the `<video>` element, YouTube Music destroys that
element on every track change, and WebKit exposes no API to reconnect to a device programmatically. The player
bar's cast button was kept, with Google Cast as the target instead.

Casting YouTube Music is not a like-for-like swap for AirPlay, so the design space had to be checked first:

| Option | Why it was rejected |
|--------|--------------------|
| Official Google Cast SDK | Google ships sender SDKs for Android, iOS/tvOS, and Chromium only. The iOS `GoogleCast.xcframework` cannot be linked into a native macOS executable, and adding Google's closed SDK would also break the no-new-dependencies rule. |
| Send YouTube media URLs to the receiver | Kaset plays Widevine-protected audio inside `WKWebView` (ADR-0001). There is no licensable URL to hand to a receiver, and a custom Cast Web Receiver would have to be registered in the Cast Developer Console and hosted. |
| YouTube "second screen" / Lounge protocol | It works — open-source senders exist (`ytcast`, `casttube`) — but it is an undocumented, reverse-engineered API that hands playback to the *device's* YouTube app: Kaset would stop being the player, its queue/seek/lyrics would stop applying, Chromecast devices no longer answer DIAL discovery so every device needs manual TV-code pairing, and the API can break on any YouTube release. |
| Cast the Mac's system audio | There is no Cast audio output driver on macOS, and capturing system audio the `mkchromecast` way requires the user to install a virtual audio device (BlackHole) plus Python and ffmpeg. |

The remaining option is the one `mkchromecast` uses: **be the media server**. Capture audio that Kaset is
already playing, encode it, serve it over the local network, and ask the device's built-in **Default Media
Receiver** (`CC1AD845`) to play that URL. macOS 14.4+ makes this practical without third-party drivers, because
Core Audio can tap a process's audio directly.

## Decision

Cast by streaming Kaset's own decoded audio to the Cast Default Media Receiver over the local network.

1. **Capture** — a Core Audio process tap (`AudioHardwareCreateProcessTap` via the macOS 15 object API) captures
   Kaset and its WebKit audio helper processes. The tap's `mutedWhenTapped` behaviour keeps the captured audio
   out of the Mac's speakers, so the track is not heard twice.
2. **Encode** — an `AudioConverter` produces AAC-LC access units at the tap's sample rate; each access unit is
   wrapped in a 7-byte ADTS header so the receiver can play the stream as `audio/aac`.
3. **Serve** — an `NWListener` HTTP server on an ephemeral port streams the encoded audio as endless chunked
   responses from the local IPv4 address that shares a subnet with the device.
4. **Hand over** — a hand-rolled CASTV2 client (protobuf wire format over TLS to port 8009, no dependencies)
   connects to the platform receiver, launches or attaches to the Default Media Receiver, and sends `LOAD`
   with the stream URL.
5. **Discover** — `NWBrowser` browses `_googlecast._tcp`, reading the friendly name, model, and device id from
   the mDNS TXT record.

Because Kaset remains the source of audio, the queue, seeking, syncing, scrobbling, and track changes all keep
working exactly as they do locally.

## Consequences

### Positive

- **Playback is unchanged** — every track, podcast episode, ad, and DRM-protected stream casts, because the
  audio is captured after WebKit decodes it. No YouTube API is involved beyond what Kaset already uses.
- **No new dependencies** — the CASTV2 codec, ADTS framing, and HTTP streaming layer are ~800 lines of
  first-party Swift over system frameworks.
- **Survives track changes** — unlike AirPlay, the session does not die when YouTube Music recreates its video
  element, because Kaset owns the stream.
- **Works with any Cast device** — audio-only receivers and Google TV devices alike, since the Default Media
  Receiver is built in.

### Negative

- **Audio is re-encoded** — the stream is AAC at 192 kbps. That is transparent for music, but it is a
  generation of lossy encoding, not a bit-perfect handoff.
- **Latency** — encoding plus receiver buffering adds roughly 1–3 seconds.
- **The Mac stays in the loop** — casting requires Kaset to keep playing, so the Mac must stay awake and the app
  running. Closing the window is fine (audio continues); quitting the app stops the cast.
- **Network shape matters** — the device must be able to reach the Mac, so guest Wi-Fi or AP isolation blocks
  casting. The first cast may trigger the macOS local-network and firewall prompts.
- **Device volume is not driven** — Kaset's volume slider shapes the stream; the device's own volume is left
  alone to avoid double attenuation.
- **Not an AV route** — like AVRoutePicker-free AirPlay, this is not a system audio route: only Kaset's audio is
  cast, other apps keep playing locally.

## Known Limitations

- A paused track streams silence rather than stopping the receiver: the live stream keeps the session alive so
  resuming is instant.
- Only the Default Media Receiver is targeted. Casting the queue to the device's own YouTube Music app (which
  would let playback continue if the Mac slept) is the Lounge/MDX approach rejected above.
- The stream is not encrypted or authenticated beyond being on the local network. Anyone on the same network who
  learns the ephemeral URL and port could listen in.

## Verification

Automated coverage lives in `Tests/KasetTests`:

| Suite | Covers |
|-------|--------|
| `CastMessageTests` | CASTV2 protobuf encoding/decoding and stream framing |
| `CastProtocolTests` | Payload builders and receiver/media status decoding |
| `CastDeviceTests` | mDNS TXT parsing and device registry merge/remove |
| `CastReceiverSessionTests` | Handshake, launch, attach, `LOAD`, heartbeat, stop |
| `CastServiceTests` | Cast state and menu text |
| `CastStreamAddressTests` | Local address selection for the stream URL |
| `CastHTTPStreamingTests` | HTTP request parsing, chunked transfer, responses |
| `ADTSHeaderTests` | ADTS header bytes and framing |
| `AudioTapFormatTests` | Tap buffer layout and frame accounting |

Manual verification on hardware:

1. Play a track and open the cast button in the player bar; the device appears within a few seconds.
2. Select the device: it should show the Default Media Receiver, then start playing after ~1–3 seconds.
3. Confirm the Mac's speakers go quiet while casting (the tap mutes them).
4. Skip tracks, seek, and change volume; the device should follow continuously.
5. Stop casting; local audio should return to the Mac's speakers.

## References

- [Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Google Cast: supported media](https://developers.google.com/cast/docs/media)
- [mkchromecast](https://github.com/muammar/mkchromecast) — the same media-server approach, with BlackHole and ffmpeg
- `ytcast` / `casttube` — the Lounge/second-screen approach that was rejected
