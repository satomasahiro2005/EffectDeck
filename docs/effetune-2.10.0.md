# EffeTune 2.10.0 integration

Branch: `codex/effetune-2.10.0`, based on `bf1f6c9`.
Upstream: release tag `v2.10.0` (`abca7ff`). App version/build numbering is unchanged.

Correction (2026-09-26): preview now plays only in five analyzers, and the host prepares 2–16 channels; see `effetune-2.11.0.md`.

## Implementation

- Regenerated the 103-effect catalog and 146 factory presets (28 effects).
- Spatial Mapper: native DSP, component/output routing controls, all three 16×16
  matrices encoded as upstream flat arrays (`dm`, `fm`, `rm`), six factory presets.
- Pitch Meter: native monophonic detector, note/cents/Hz readout and two-second
  scrolling piano roll, reference pitch and note range controls.
- TV Audio Simulator: native DSP, generated parameter controls and nine regional presets.
- Spectrum Analyzer and Spectrogram: Log (HQ), validated version 2 telemetry,
  logarithmic cell frequencies; Spectrum Analyzer also has 24/48-band Bar display.
- Frequency graphs built with `ETAxis.frequency`, both spectrum graphs, Note
  Spectrogram and Pitch Meter can audition a sine tone while dragging. The stereo
  -24 dBFS signal enters before resampling and the effect chain, with 5 ms ramps.
  Release, gesture cancellation, view removal and backgrounding stop the preview.
- Sync Visuals to Audio: persisted, default off; delays telemetry publication by
  the reported audio output/buffer and resampler latency, using a bounded queue.
- Setup keeps the native 64-bit asset-pointer patch, tolerates checkout whitespace
  and now fails if the patch cannot be applied or verified.

## Verification

On Windows, built the C++ DSP core and ran the five upstream native test targets:
Pitch Meter, Spatial Mapper, TV Audio Simulator, Spectrum Analyzer, Spectrogram.
All passed. Local preview-tone tests passed (frequency, stereo equality, level,
release to silence and suppression above Nyquist). Catalog/preset/version generation
and asset patch reverse-check passed.

Swift regression tests cover flat matrix JSON round trips and legacy analyzer
presets, and update the factory-preset coverage expectations. They have not been
run here: this environment has no Xcode/iOS SDK. No device installation or testing
was performed.

## Handoff / current host limits

On macOS, initialize the submodule and run `bash Scripts/setup.sh`, then build in
Xcode. Run the `Logic` scheme for the Swift regression tests.

The current audio host prepares two channels. Spatial Mapper preserves all 16×16
routes for preset exchange, but this change does not add multichannel hardware
output. Display synchronization compensates the output path; it does not model
each analyzer's position in a branched DSP graph. The pre-existing display-only
settings remain view state (Linear/Log and Bar); HQ is a DSP parameter and is saved.
Windows desktop automatic updating is upstream application functionality and does
not apply to this iOS host.
