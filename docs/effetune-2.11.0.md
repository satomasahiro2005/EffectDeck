# EffeTune 2.11.0 integration

Branch: `feature/effetune-2.11.0`, based on `240e7c7`.
Upstream: release tag `v2.11.0` (`e200e51`, DSP 0.11.0). App version/build numbering is
unchanged.

## Implementation

- Regenerated the catalog: 107 effects (four new), 662 parameters. Factory presets stay
  at 146 (28 effects); only the three Dynamic Saturation presets gain `"os": 1`. Time
  Alignment now reaches 500 ms.
- Oversampling (`os`) is a segmented 1x/2x/4x/8x choice on Saturation, Dynamic
  Saturation, Exciter, Harmonic Distortion, Multiband Saturation and the existing Brickwall
  Limiter row, and 1x–16x on Hard Clipping. The parameter stays numeric, so the DSP and
  JSON get the factor itself. Other values are ignored like upstream `isAllowedEnum`: a
  loaded chain gets 1x, an applied preset keeps the current value. Chains saved before
  2.11.0 read 1x. Dynamic Saturation now shows the row, first as upstream does.
- Attack Tonal Balance and Bass Extender use generated controls. Attack and Tonal are
  disabled while their Enabled toggle is off. Bass Extender runs only on Stereo or a
  channel pair, as upstream; on other routings the host publishes it disabled and the
  card shows "Bypassed".
- Bass Management: dedicated card in upstream's order (Phase, Linear Quality, Sub
  Outputs, LFE low-pass, gains, per-channel Bass Matrix, response graph, route summary,
  status and latency). Linear phase ports upstream `design-core.js` onto the FIR Crossover
  designer and is sent as a matrix FIR asset. It is redesigned after a preset apply, a
  chain load and a route rebuild, also for collapsed cards. `ro`, `fc`, `sl`, `rt` and
  `ri` round-trip as upstream flat arrays, and decoding applies upstream's
  `setParameters` checks. Routing is described in `multichannel-output.md`.
- Chroma Spiral: dedicated card with the spiral (Normal, Normal 2, Note Colors), octave
  range, Frequency Tilt, Level Range and Display Floor, saved under upstream's keys.
- Analyzer display settings: Color on Spectrum Analyzer and Pitch Meter (Normal, Heatmap,
  Note Colors) and on Spectrogram (Normal, Heatmap; default Heatmap), and Gain on Stereo
  Meter's goniometer. Pitch Meter's layout and the analyzers' keyboard setting have no UI
  but now survive preset round trips. Note Colors use EffectDeck's existing note palette.
- Pitch Meter reads confidence and level from the 2.11.0 telemetry and applies upstream's
  frame checks. Heatmap and Note Colors colour each segment by level or pitch and fade it
  by confidence; Normal and the readout are unchanged.
- Spatial Mapper's matrix shows only the routed channels; all 16×16 values are kept.
- The spectrum overlay no longer smooths HQ frames, as upstream. Upstream's global overlay
  Peak Hold (default off) is not added.
- Frequency preview now plays only in Spectrum Analyzer, Spectrogram, Note Spectrogram,
  Pitch Meter and Chroma Spiral. Moving EQ handles or touching other frequency-response
  graphs no longer plays a tone.
- Preset apply now republishes when an effect's latency changes (Hard Clipping above 1x
  adds 64 samples) and resends designs whose inputs are parameters: IR Reverb
  `cm`/`lt`/`cr`, FIR Crossover and Bass Management.
- Setup: the three external-node patches are rebased onto the 2.11.0 engine, and external
  nodes now get its input alignment (`external-processor.md`). `setup.sh` stops when a
  generator, `embed_models.py` or `xcodegen` fails instead of building with a stale
  catalog; `gen_version` stays non-fatal. `gen_catalog.py` keeps flat-array parameters
  (Spatial Mapper, Bass Management) in one table.

## Verification

On Windows (MSVC), applied `abi-begin-ptr.diff` and the three rebased external patches to
a scratch copy of v2.11.0 with the patch section of `setup.sh` (a second run detected all
four as applied) and with `patch --fuzz=0`. Built the patched DSP core and ran 14 upstream
native test targets: core and graph tests (including the new pipeline input-alignment
test), the four new effects, Spectrum Analyzer, Spectrogram, Oscilloscope, the saturation
descriptor test and the FM Radio, TV Audio, MP3 Codec and Tube simulators. All passed. A
scratch-only native test (not committed) sent audio with unequal input delays through an
external node in five routing cases: all were aligned with the patch, removing the
external `align_input` failed all five, and dropping its channel offset failed the two
channel-pair cases. Host preview-tone and external-processor tests passed. Catalog, preset
and version generation passed (107 effects, 146 factory presets, 17 presets, 0.11.0).

Swift was checked on Linux (WSL) only. Every changed Swift file passes `swiftc -parse`;
the SwiftUI views were not type-checked. Foundation-only code was compiled and run on
Linux against the generated catalog or a copied part of it: `OversamplingTests` under
swift-corelibs XCTest (9/9), the first four `BassManagementTests` (4/4) and 42 Bass
Management model checks. These ran before the last fix pass changed `ETParamCoding.swift`
and `BassManagementSettings.swift`; the final `ETParamCoding.swift` was rebuilt for a
standalone check with the inputs of `testNormalizesLikeSetParameters`. The Bass
Management Linear design matched upstream JavaScript in one 48 kHz, 8192-tap,
four-channel case (same asset header, paths and size; impulses within about 1e-10).
Chroma Spiral's frame checks, level reference, cells, geometry and touch-to-pitch mapping
matched upstream JavaScript on synthetic frames. A harness for the Bass Management
designer's state machine stopped after three steps when WSL failed and was not finished.

No Xcode build, Swift test run in the app's test bundle, device installation or device
testing was performed.

## Handoff / current host limits

On macOS, copy the tree with `Vendor/effetune` at `v2.11.0` unpatched, run
`bash Scripts/setup.sh` (it applies the four patches and regenerates), then build in
Xcode and run the `Logic` scheme. New Swift tests: `OversamplingTests`,
`BassManagementTests` and the Bass Management cases in `ParamCodingTests`.

The host prepares the output route's width, 2–16 channels (`multichannel-output.md`).
Bass Extender and Bass Management on an unsupported routing are published disabled.
Upstream's bypass still copies the input to the output bus, so such a node whose input and
output buses differ sounds different from web EffeTune. A failed Bass Management Linear
design is retried only when its inputs change. After Linear → IIR the host polls the
reported latency for one second; with audio stopped, the old latency stays until the next
republish. Room EQ, Crosstalk Cancellation, Group Delay EQ/PEQ and 5-band FIR PEQ keep
their design inputs in their own stores, so a preset's `lt`/`fd` reaches them only at
their next redesign. Brickwall Limiter drops an invalid `os` and keeps the other values,
where upstream rejects the whole call. Kernels are still built without the
`-ffp-contract=off` that upstream sets on 10 of them, now including Attack Tonal Balance.
The upstream Visualizer and ZIP Backup/Restore are application features not included
here; EffectDeck's JSON backup format is unchanged.
