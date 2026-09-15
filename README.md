# EffeTune Live

[EffeTune](https://github.com/Frieve-A/effetune) for iOS.

It takes the audio other apps are playing, runs it through EffeTune's effects, and sends
it to the built-in speaker. No virtual cable, no input device to configure. Pick
**EffeTune** as the output in Control Center and that is the whole setup.

```
Spotify / YouTube / games
  ↓ pick EffeTune as the output in Control Center
extension (Media Device Extension)   ← receives
  ↓ 127.0.0.1:47101
app                                  ← runs EffeTune's DSP
  ↓
built-in speaker
```

## The iOS 27 Media Device Extension

iOS 27 added `MediaDevice.framework`, which lets an app present itself as an output
device the way an AirPlay speaker does. EffeTune Live advertises itself that way, and
once it is picked the system hands it the audio as samples.

It runs as two processes. The extension advertises the device and receives the audio;
the app processes it and plays it. They are split because the extension's sandbox denies
files, shared memory and `bind`. Outbound connections are allowed, so the audio goes over
a single TCP connection to the app. It ships as one app, and the user installs one app.

Signing the app itself with `com.apple.developer.media-device-extension` stops it from
opening an `AVAudioSession` — every category fails with `'!pla'`. The check only looks at
whether the entitlement's array is empty, so the app carries an empty array and the
extension carries the protocol identifier. That also gets past App Store Connect's
ITMS-91183.

## Building

```bash
git clone --recurse-submodules https://github.com/satomasahiro2005/effetune-live
cd effetune-live
bash Scripts/build.sh          # build and install on the attached device
```

To open it in Xcode, generate first. The `.xcodeproj` is not tracked; `project.yml` is the
source.

```bash
bash Scripts/setup.sh
open EffeTuneLive.xcodeproj
```

You need:

- macOS with Xcode 27 or later
- A device running iOS 27 or later. The extension needs iOS 27, so no audio flows in the simulator
- Apple Developer Program membership (set `DEVELOPMENT_TEAM` in `project.yml` to yours)
- `xcodegen` and python3 3.10+ from Homebrew

The script finds the attached device. With more than one, use
`DEV_ID=<UDID> bash Scripts/build.sh`.

### Building under your own Apple ID

Change the bundle IDs to yours, then create the following in the Apple Developer portal.

1. A **Media Device Sharing Extension** identifier (Identifiers > new). There is no review
2. Put that value in the extension's entitlements and in `UTExportedTypeDeclarations` in
   its Info.plist. The entitlement value must be an array with one element; a bare string
   stops the extension from launching
3. App IDs for the app and the extension

## License

MIT. See [NOTICE.md](NOTICE.md) for what is bundled.
