# AUv3 post-insert

Branch: `codex/au-post-insert`, based on `codex/multichannel-output`.

The current render callback runs the EffeTune pipeline before it writes to the
`AVAudioSourceNode`. Therefore this first AU host deliberately exposes only:

```text
SourceNode (EffeTune processed) → AUv3 effect → MainMixer
```

It does not claim to support `Source → AU → EffeTune` or arbitrary AU/EffeTune
reordering. That requires moving the EffeTune render out of the source callback and is a
separate audio-graph change.

The Audio settings screen can discover registered AUv3 effects, asynchronously load one,
toggle bypass, expose its parameter tree through generic sliders, and persist the selected
component, bypass state, and parameter values. The AU's reported latency is included in
the diagnostics and total-delay display.

The AU itself must accept the active route width for a full-width multichannel path;
many third-party effects are stereo-only. This first implementation does not split a
multichannel bus around a stereo AU.

AU execution is intentionally separate from the future JSFX host. Only the host-facing
concepts—parameters, state, latency, bypass, and routing—are candidates for a shared
model.

This Windows checkout cannot build or run the iOS Audio Unit graph. Device verification
must be done in Xcode with at least one AUv3 effect installed.
