# EffeTune 2.16.0 integration

Branch: `feature/effetune-2.16.0`, based on `origin/main` (`0299af4`).
Upstream: tag `dsp-v0.16.0` (`3769b9ae`, DSP 0.16.0). App 2.16.0 is tag `v2.16.0` and is the same commit.

This note covers the **import** only. The UI for `ck` and `dm` and the type-32 frame are separate work.
Built on Linux (Logic bundle, Native, Python and node tests). **Nothing was built in Xcode** (the Mac was offline).

## Import

- Pin `3769b9ae` (`dsp-v0.16.0` = `v2.16.0`, so no tag-versus-main split as in 2.15.0).
- Patches: all four apply unchanged (offsets only). Not regenerated. Upstream added `Engine::streamBoundaryInstance`
  and `et_instance_stream_boundary` (abi.cpp / abi.h / engine.cpp / engine.h / exports.txt), which the patches do not touch.
- Catalog: 112 effects, 721 parameters (was 719). `chain/v0.16.0/` added, `CHAIN.md` and the README badge point at 0.16.0.
  - Note Spectrogram: new saved toggle `ck` (Chords & Key, offset 3), floatCount 4, hash `0xb8518943`, defaults `[28,91,0,0]`.
  - Rhythm Analyzer: new saved enum `dm` (`band` / `drums`, offset 3), floatCount 4, hash `0xf854c585`, defaults `[40,240,0,0]`.
    Upstream's on-screen labels are "Frequency bands" and "Drums" (`rhythm_analyzer.js`).
- System presets: 28 (was 18). The 10 new ones are `presets/mastering`. `Tools/gen_presets.py` `LABEL` gets
  `"mastering": "Mastering"` (without it the category came out lowercase). Names come from file names, as for the
  existing ones ("Edm", "Hip Hop", "Jpop Dense", "Rnb Soul"); not renamed because ScreenshotSeed ids and
  `preset:system:<name>` drop payloads depend on the current style.
- Goldens: only `designers-b-golden.json` changes (`upstreamVersion` 2.16.0). The others are byte-identical apart from line endings.
- Effect presets (170 / 30 effects) and licences (7) unchanged; `EffectPresets.swift` / `Licenses.swift` show as modified
  only by CRLF and are not committed.
- Native sources: everything new is header-only (`rhythm_analyzer/drum_*.h`, `note_spectrogram/chord_key_*.h`), picked up by
  the existing `Vendor/effetune/dsp/plugins` glob. No change to `project.yml`.
  Binary size grows by about 1.3 MB (drum weights about 1.13 MB, chord weights about 160 KB).

## Telemetry

- **Rhythm Analyzer frame is now version 5, 2024 bytes** (was version 4, 1496). Offsets 0-1495 are unchanged; the new tail is
  1496 u32 drum mode, 1500 u32 drum count (up to 16), 1504 f32 drum latency, 1512 + 32*i drum events (same slot layout as
  the band events). `ETRhythm.version` / `payloadBytes` moved to 5 / 2024 and the tail is not read yet.
  Without this the screen went blank even in band mode (the parser rejected anything but version 4 / 1496).
- Note Spectrogram Chords & Key adds a frame of type 32, version 1, 32 bytes, written after each note frame only while `ck` is on.
  **Not added to `ETFrameType` / `Telemetry.queuedTypes` yet** (UI work). With `ck` off (the default) nothing changes;
  the note frame stays version 6.

## Not used

- `et_instance_stream_boundary` is visible to Swift through the bridging header (`effetune/abi.h`), `EFFETUNE_DSP_ABI_VERSION`
  is still 1. **Not called.** Upstream calls it at track starts and ends in its own player; EffectDeck processes other apps'
  audio and has no track boundary. If it is ever used: it calls the kernel directly without staging (like `et_instance_reset`),
  so it needs `AssetUpload.holdOffAudioThread` as `resetState` does; it returns `ET_ERR_STATE` while a boundary is pending and
  on graph-owned instances (EffectDeck's pipeline instances are not graph-owned).
- SFZ analysis `configure(min, max, false)` is internal; nothing to do.
- Out of scope (desktop app only): Visualizer presets (Visualizer is not on main), Android / AirPlay / network receivers,
  UPnP, lyrics, and the remote-protocol JS changes (not looked at beyond the diff; the PC here stays on 2.13.0).

## Risks to measure on the device

- **CPU / battery.** Upstream `RhythmAnalyzerKernel::process` calls `drums_->push()` on every sample regardless of `dm`, so the
  drum network (a CRNN, 566k parameters, 100 frames per second) runs in band mode too. Native benchmark of `drum::Detector`
  alone in WSL: about 2.9% of one x86 core at gcc -O2, about 3.6% at -Os (EffectDeck builds with `GCC_OPTIMIZATION_LEVEL s`),
  for each Rhythm Analyzer stage, always. Measure on the iPhone 16 together with #5 (battery).
- With `ck` on, Note Spectrogram computes all 88 pitches instead of the visible range, plus the chord network.
- Memory: about 2.27 MB for a shared static float copy of the drum weights, built once on the first Rhythm Analyzer
  prepare (about 10 ms), not on the audio thread.
- **Compatibility.** `shortForm` writes `ck` and `dm` always, so v2026.10.16 (the store build) and the PC on 2.13.0 report
  "Ignored: Note Spectrogram.ck" / "Rhythm Analyzer.dm" for chains from this build. Harmless.

## Verification

Run on 2026-10-30 on Windows / WSL. Nothing on the Mac or the device.

- Linux Logic bundle (WSL, `Tests/Linux/run.sh`): 1154 tests, 0 failures, 1 skipped. Right after the import commit alone: 1148 tests,
  8 failures (all expected: version, floatCount and frame-size expectations). New: `Upstream216Tests` (6).
- Python `Tests/Tools`: 251 tests OK (9 skipped). `node --test Tools/*.test.mjs`: 5 pass.
  `check_repo.py --version-guard` and `check_repo.py`: ok.
- `Tests/Native` engine preset with the four patches (gcc, ASan + UBSan, `lsan.supp`): 121 of 121 pass.
- Generated-files drift (`setup.sh` + every `Tools/golden/*_golden.mjs`, `ir_analysis_golden.mjs`, `ir_prepare_golden.mjs`
  against the HEAD pin): only `designers-b-golden.json` differs in content; the rest differ by line endings only.
- **Not run:** the Xcode build, install on the iPhone 16, CI.
