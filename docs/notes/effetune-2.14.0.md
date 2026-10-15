# EffeTune 2.14.0 integration

Branch: `feature/effetune-2.14.0`, based on `8a03209`-era `main` (`5b5e82b`).
Upstream: tag `v2.14.0` (`01c96f00`, DSP 0.14.0, tag `dsp-v0.14.0` on the same commit).

Built in Xcode (Release) on the Mac and installed on an iPhone 16. Not yet tried by hand on the device.

## Import

- Patches: all four are unchanged in content and regenerated against 2.14.0 so that they apply at
  offset 0 (`git apply`). 2.14.0's engine change is a C++-only off-thread asset preparation API
  (`captureInstanceAssetSnapshot` / `prepareInstanceAssetUpdate` / `applyInstanceAssetUpdate`); it does
  not touch the pipeline walk, so external nodes need no new guard. EffectDeck does not use it.
- Catalog: 112 effects, 718 parameters. Effect presets 170 (Analog Meter: Bouncy VU, Slow RMS, Fast Peak).
  System preset `Visualize/Instrument Colors`. `chain/v0.14.0/` added, `CHAIN.md` points at 0.14.0.
- Runtime-only (not saved): SFZ Note Player `pm` / `pv` (preview note), Note Spectrogram `te`
  (upstream derives it from Color and Highlight in `getWorkletPluginData`).
- Display parameters: Analog Meter `dc` (Custom dial, default 0), Note Spectrogram `hl` (Highlight),
  SFZ Note Player `cl` (Normal / Rainbow).

## SFZ

- Parser (`parser.js`): `*sine` and other generated samples (`ETSFZGenerator`, `generators.js`), envelope
  times clamped to 0..100 s with an `envelope-times-adjusted` warning, `sw_lolast` / `sw_hilast`,
  `sustain_sw` / `sostenuto_sw` are now ignored rather than conditional, no `unsupported-regions` any more.
- Source (`source.js`): text falls back to windows-1252; ARIA `.bank.xml` `<Define>`s are applied before the
  SFZ's own `#define`s and the matched bank file is stored in the container (so the bank id matches
  upstream). The folder walk now limits `.sfz` files only.
- Golden (`Tools/golden/sfz_golden.mjs`) gained generator, switch-range, ARIA bank, unlisted bank,
  windows-1252 and generator-only cases. The Swift port matches all of them byte for byte.
- UI: voice display (telemetry type 30, version 1) with a keyboard; touching it plays the preview note
  (velocity 100 on the keys, by height above them). While previewing, the power gate does not rest.
  Color radio. The bank row is `SFZ Library…`, the name and `Clear`; the SFZ Library sheet lists, searches,
  sorts (name / recent), deletes unused banks and imports every SFZ of a chosen folder.
  The library index now records `size`, `fileCount`, `importedAt`.

## Analog Meter

Custom mode: Detector (DSP `de`), Needle Response (DSP `nr`, logarithmic slider), Overshoot (DSP `os`),
Dial (display `dc`). In Custom every applicable row stays visible; rows the detector or dial make
ineffective are dimmed and disabled (`isAnalogMeterParameterVisible` / `isAnalogMeterParameterActive`).
The dial picks the scale (VU, PPM DIN, PPM BBC, the RMS dB scale, dBFS or dBTP).

## Oscilloscope

Display Time 1..10000 ms on a logarithmic slider. Version 3 envelope frames: triggered windows in 4096
buckets, and free-run windows that roll (the newest bucket at the right). Drawn as a min/max band per
pixel. Ticks and the axis name switch to seconds at 1 s and above. Not done: upstream's render clock
that scrolls smoothly between frames; here the band moves when a frame arrives.

## Note Spectrogram

Frames are version 6 (9192 bytes, 88 pitch offsets in cents at 8840). Version 5 frames are still read.
**Not done:** the instrument colours (Instrument (3) / (9)), Highlight, the timbre events (frame type 31),
the legend and the onset marks. `te` stays 0, so the kernel does not run the timbre analysis.
A chain or preset that carries `cl: Instrument3` or `hl` keeps the value.

## Not reviewed yet

Smaller upstream UI changes: 5 Band Dynamic EQ, Room EQ, IR Reverb, Phase Select EQ, Tube Simulator,
Crosstalk Cancellation, `plugin-base.js`, `graph-point-interaction.js`. The remote `describeEffects` op and
the MCP server are PC-side and do not apply.

## Verification

- Linux Logic bundle (WSL, Swift 6.4): 1046 tests, 0 failures, 1 skipped.
- Python tools: 251 OK (9 skipped). `check_repo.py` ok. Privacy manifest ok.
- Mac: Release build succeeded, installed on iPhone 16.
