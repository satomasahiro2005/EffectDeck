# EffeTune 2.16.0 integration

Branch: `feature/effetune-2.16.0`, based on `origin/main` (`0299af4`).
Upstream: tag `dsp-v0.16.0` (`3769b9ae`, DSP 0.16.0). App 2.16.0 is tag `v2.16.0` and is the same commit.

The first half covers the **import**; the "Chords & Key" and "Rhythm Analyzer Drums" sections cover the follow-up that
wires `ck`, `dm` and the type-32 frame into the screens.
Built on Linux (Logic bundle, Native, Python and node tests). **Nothing was built in Xcode** (the Mac was offline), so the
two SwiftUI files (`NoteSpectrogramView.swift`, `RhythmAnalyzerView.swift`) are unbuilt.

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
  the band events). `ETRhythm.version` / `payloadBytes` moved to 5 / 2024; the tail is read by the Drums follow-up below.
  Without this the screen went blank even in band mode (the parser rejected anything but version 4 / 1496).
- Note Spectrogram Chords & Key adds a frame of type 32, version 1, 32 bytes, written after each note frame only while `ck` is on.
  Read by the Chords & Key follow-up below (`ETFrameType.noteChordKey`, `Telemetry.queuedTypes`). With `ck` off (the default)
  nothing changes; the note frame stays version 6.

## Chords & Key (Note Spectrogram `ck`)

Port of upstream `note_spectrogram.js` `handleChordKeyTelemetry`, `_drawChordLane`, `_layoutKey`, `_drawKeys`.

- **Frame.** Type 32, version 1, exactly 32 bytes, same validity gate as upstream (`ETNoteChordKeyFrame`, in
  `DSP/NoteSpectrogramFrame.swift`, Foundation only). `ETFrameType.noteChordKey = 32`; added to `Telemetry.queuedTypes`
  (frames come at 50 fps, the 30 Hz poll would lose about 40%).
- **Bookkeeping lives in a Foundation struct** (`ETNoteChordTrack`), owned by `ETNoteBand`, so it is covered by the Linux
  bundle: the confirmed chord of frame F labels every stored column whose (generation, frameIndex) is F - 11 (lag 11,
  wrapping UInt32); stale / other-generation frames are ignored; a column rewritten by a new note frame loses its chord;
  runs split on a nil or "no chord" column. Chords are vector overlays, so the image is not rebuilt.
- **Cleared** on band `reset()`, on a new note-frame generation, and when `ck` is toggled (upstream `clearChordKeyHistory`).
- **Row.** `ck` is a real saved parameter. It is shown with the existing `ParameterRow` toggle right after Onsets and before
  Time Span (upstream order), and excluded from the generic `ForEach` so it does not appear twice. Not in `RUNTIME_ONLY`,
  `ETDisplayParam`, `ETParamGate` or `etLocalAudioOnly` (the PC owns the value). No footer or caption text.
- **Drawing** (all lengths in points = upstream CSS px): chord lane 36, bold 28 pt labels, 2 pt colour strip, padding 6.
  Note Colors colours the label by root; otherwise `.secondary`. SwiftUI cannot stroke text, so the halo is two stacked
  `.shadow` filters in the background colour. Labels are fitted by squeezing horizontally (`scaleBy(x:)`), newest first,
  never past the next label's start. Vertical: lane at the top, legend moved below it. Horizontal: labels stand upright at
  the right edge and slide down past the legend items and the key label.
- **Key label** ("Key: D flat major") drawn only while the local key is 0..23; at the bottom-left of the roll.
- **Notation.** The overall key picks the note-name table (`ETNoteChordKey.keyNoteNames`, same construction as upstream
  `MULTI_F0_KEY_NOTE_NAMES`). Used by chord labels, the probe readout ("NOTE", plus "CHORD" when a chord is known) and the
  Lowest / Highest Note value boxes. The boxes watch only a tiny `ETNoteNotation` object (changes when the table changes),
  not the band, because the band publishes at 30 Hz and card-level observation froze the buttons before.
  Chroma Spiral and SFZ keep sharps.
- **Deviation from the design (needs a look on the device).** The Full Screen / Close button is treated as an obstacle in both
  layouts: Horizontal slides labels below it, Vertical stops a label before it (upstream has no such button).
- **Not applied.** `et_instance_stream_boundary` is not called (EffectDeck has no player of its own), so the overall key
  keeps accumulating across songs until the kernel resets.
- **Cost.** The kernel's own scheduled weight with `ck` on is 1,096,605 for every range (+15.6% at the default 28-91, +6.2% at
  21-108, +36.8% at 48-72). Wall time is not measured; compare on the iPhone 16.

## Rhythm Analyzer Drums (`dm`)

- **Frame.** `ETRhythmSnapshot.parse` reads 1496 (mode, rejects > 1), 1500 (drum count, <= 16), 1504 (latency, finite and
  >= 0), 1508 (reserved, must be 0) and `eventCount + drumCount` slots; drum slots at 1512 + 32*i. Drum events: lane <= 4,
  flags in {0, 1, 3}, pad 0, finite logit; strength = max(smallest positive double, sigmoid(logit)); time =
  (frame + fraction) * 256/24000 regardless of the sample rate. Identity is `generation:band|drums:frame:fractionBits:lane`.
  Only the events matching the frame's own mode are kept. Version 4 (1496 bytes) is rejected, as upstream does.
- **State.** `ETRhythmDisplayMode` (names, order, rows, laneCount), `ETRhythmState.setDisplayMode` /
  `clearOnsets` (onset ring, pending set, reference caches, `eventTimed`, serial and lens smoothing only; beats, clock,
  segments and tempogram stay, no generation change), `onsetOpacity` (1 in drums, confidence in band), ingest drops events of a
  frame whose mode differs from the state's and drops Tom (lane 4) in drums mode. `clearHistory` now calls `clearOnsets`
  (so it also clears `eventTimed`, as upstream). Echo row centre = 0.5 + (row - (N-1)/2) * 0.84/N (0.28 steps for N = 3).
  Lens cells = laneCount * 6.
- **Screen.** A `Display` segmented row (`ETDisplayChoiceRow`, "Frequency bands" / "Drums", the SFZ Detection pattern) after
  Metronome Click and before Span. It writes `dm` directly; no `tracker.restart()` and no `resetState`. `RhythmTracker.pump`
  takes the mode and applies it **before** ingesting, so a mode changed by a preset, the PC or while the card was closed is
  handled, and `.onChange(of: displayMode)` re-pumps. The painter takes names, order, rows and lane count from the state
  (separators, guide rows `[0, N-1, 1..<N-1]`, stems, lens rows, `lensLabelHeight`). No new colours or legends.
- **Not ported.** Cursor readout (none in EffectDeck).
- **To tell the owner.** `drum_weights.provenance.json` lists IDMT-SMT-Drums, ENST-Drums and MDB-Drums for threshold
  calibration but has no licence field (unlike `rhythm_d_*.provenance.json`); `gen_licenses` is unchanged.
- **To check on the device.** Four lanes in the narrow 3:5 layout are about 41 pt high instead of 55 pt. A numeric 1 loaded
  from hand-written text loads as drums (upstream ignores non-strings); an unknown string loads as band.

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

- Linux Logic bundle (WSL, `Tests/Linux/run.sh`): 1154 tests, 0 failures, 1 skipped for the import. Right after the import commit alone:
  1148 tests, 8 failures (all expected: version, floatCount and frame-size expectations). New: `Upstream216Tests` (6).
  After the Chords & Key / Drums follow-up: 1172 tests, 0 failures, 1 skipped.
  Device-only (not in the bundle): `Telemetry.queuedTypes` containing 32, all drawing, the shadow halo, label collisions.
- Follow-up native checks (WSL, gcc, Release + ASan + UBSan with `-fno-sanitize=vptr`; upstream's harnesses construct kernels into raw
  storage and trip UBSan's vptr check immediately, in both `note_spectrogram` and `rhythm_analyzer`): upstream
  `effetune_dsp_note_spectrogram_tests` (no args), `--model-fixture <fixtures>` and `effetune_dsp_rhythm_analyzer_tests` all exit 0.
  `Tests/Native` `asan` preset: 115 of 115 pass (the `engine` preset was not rerun; no C changed since the 121 of 121 above).
- Python `Tests/Tools`: 251 tests OK (9 skipped). `node --test Tools/*.test.mjs`: 5 pass.
  `check_repo.py --version-guard` and `check_repo.py`: ok.
- `Tests/Native` engine preset with the four patches (gcc, ASan + UBSan, `lsan.supp`): 121 of 121 pass.
- Generated-files drift (`setup.sh` + every `Tools/golden/*_golden.mjs`, `ir_analysis_golden.mjs`, `ir_prepare_golden.mjs`
  against the HEAD pin): only `designers-b-golden.json` differs in content; the rest differ by line endings only.
- **Not run:** the Xcode build, install on the iPhone 16, CI.
