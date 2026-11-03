# EffeTune 2.12.0 integration

Branch: `feature/effetune-2.12.0`, based on `36b01de` (main).
Upstream: release tag `v2.12.0` (`1d4d33b2`, DSP 0.12.0, tag `dsp-v0.12.0` on the same
commit). App version/build numbering is unchanged; nothing is tagged or released here.

## Implementation

- Vendor: `Vendor/effetune` is pinned to `1d4d33b2`. The four patches apply unchanged
  (`abi-begin-ptr`, the three `effetune-external-*`), also with `patch --fuzz=0` (a few hunks
  at an offset of 5 lines).
- Build:
  - The embedded models moved from `analyzer/note_spectrogram/` to
    `analyzer/tree_models/` and grew from 3 to 8 (the Rhythm Analyzer's onset lanes and G2
    models). `Scripts/setup.sh` embeds all 8 into `Generated/note-models` (the folder name
    stays, so `project.yml`, `check_release_binary` and `.gitignore` keep working);
    `tree_models/` is on `HEADER_SEARCH_PATHS` for `heap_tree_model.h`.
  - `plugins/eq/tonal_balance_eq/calibrate_tables.cpp` is a standalone generator with an
    `int main`; it would collide with the Swift `@main`. It is excluded in `project.yml` and
    in `check_release_binary.py` `SOURCE_ROLES` (with a test).
  - fdlibm 5.3 (`atan`/`atan2` in `rhythm_analyzer/g2_math.h`, Sun Microsystems licence) is
    added to `Licenses/`, `NOTICE.md` and `gen_licenses.py` (the copy is checked against
    the header).
- Catalog: 110 effects, 685 parameters. New: Analog Meter, Rhythm Analyzer, Tonal Balance
  EQ. Oscilloscope's Trigger Mode gains `Off` (free run), so its hash changes. Analog Meter
  brings 17 factory presets (163 in 29 effects). `chain/v0.12.0/` is added, `chain/v0.11.0/`
  is kept; `CHAIN.md` points at 0.12.0; `EffectPickerView.newTypes` lists the three.
- `gen_catalog.py` resolves `...CONSTANT` spreads in `createUI` (Min/Max BPM lost their
  step and unit, Corner its label), orders Averaging Time after Smoothing and marks
  parameters that upstream neither saves nor shows (`ETParam.runtimeOnly`: Tonal Balance
  EQ's `mp`). The flag keeps `mp` in the float packing but out of the saved form and of the
  chain vocabulary.
- Display-only settings are saved under upstream's spellings (`DisplayParams.swift`):
  Analog Meter `rl rg sc ph ln tg ls` (numbers), Rhythm Analyzer `sp` (number) and
  `vt vm ve vl` (flags). Effect presets now apply them (`EffeTuneDSP.applyDisplay`), user
  presets save them (with upstream's defaults for the types that have a table), and preset
  matching compares them. The 17 Analog Meter presets differ from each other only in
  these keys, so without this every one of them looked like the first.
- Loading follows upstream's `setParameters`: Rhythm Analyzer `mx >= 1.25 * mn` (a lone
  in-range Max lowers Min, otherwise Max rises), Tonal Balance EQ shelf Q capped at 2.
- Telemetry: frame types 27/28/29. A Rhythm Analyzer frame carries the onsets since the
  previous frame, so `Telemetry` keeps every one in a per-tap queue
  (`drainRhythmFrames`, 256 frames per tap) instead of only the latest. `Telemetry.clearCount`
  tells a view that the engine was rebuilt (generations restart).
- `EffeTuneDSP.resetState(at:)` calls `et_instance_reset` for one stage (upstream's
  `resetPluginState`). It holds the audio thread off first (the same bypass-and-wait
  `AssetUpload.holdOffAudioThread` uses): the engine resets a kernel directly, without
  staging. The chain is not graph-owned, so it returns `ET_OK`.
- Dedicated views, models in Foundation-only files so they are testable:
  - Analog Meter (`AnalogMeterModel.swift`, `AnalogMeterView.swift`): needle dials for VU,
    PPM (DIN, BBC, dB), RMS, Sample Peak, True Peak and Loudness, per channel (Loudness adds
    a Program dial with M/S/I/LRA/TP/Time), peak hold with the over lamp, up to 4 columns
    (2 when narrow). Rows that do not act in the current mode are hidden. Reset (Loudness
    only) restarts Integrated, LRA and max True Peak.
    Scales, behaviour and colors follow upstream's dark theme (black face, `--et-danger`
    red); only the layout is adapted: the block is centered, and the Program statistics sit
    in the empty grid slot (3 dials on 2 columns) or a band under the dials, at 12 pt.
  - Tonal Balance EQ (`TonalBalanceModel.swift`, `TonalBalanceEQView.swift`): the 41 ERB
    bands with target mean and spread, measured level, EQ response, withheld lift and the
    five Target adjust handles (same editing as the 5Band PEQ card), Averaging Time on a
    log slider whose top is infinity, Reset.
  - Rhythm Analyzer (`RhythmAnalyzerModel.swift`, `RhythmAnalyzerView.swift`): header with
    beat LED, tempo, x1/2 and x2, strongest candidate, swing and jitter; tempogram with the
    adopted tempo line; timing lanes; echo rows; beat lens. Changing Min/Max BPM or pressing
    Reset starts the analysis again and only frames of a newer kernel generation are
    accepted afterwards (the kernel bumps its generation in both cases).
- Note Spectrogram: the keyboard follows upstream's proportions (depth = one octave's
  length * 150/(7*23.5)/2, capped at half the cross length, black keys 95/150 of it); the
  octave labels are skipped when the white part is too narrow for them. In High resolution
  the Volume bar is centred with upstream's parabolic sub-bin peak offset.
- Tests (`Tests/Unit`): `AnalogMeterTests`, `TonalBalanceTests`, `RhythmAnalyzerTests`,
  `Upstream212Tests`; existing preset, chain-vocabulary and round-trip tests were adjusted
  (163 presets, 466 string values, runtime-only flags, the Q cap). Python: new cases for the
  spread resolution, `runtimeOnly`, ordering, fdlibm and `calibrate_tables.cpp`.

## Verification

Run on the branch (working tree equal to the last commit unless noted).

- Python tools (`Tests/Tools`, Windows): 210 tests OK (9 skipped, none for these
  changes); `node --test Tools/effect_presets_dump.test.mjs` 5/5; `check_repo.py` ok;
  generators run with `ET_STRICT=1` (110 effects, 685 parameters, 17 presets, 163 effect
  presets, 0.12.0).
- Swift Logic bundle on Linux (WSL, Swift 6.4, `Tests/Linux/run.sh`): 762 tests, 0
  failures, 1 skipped (`RemoteFileDownloadTests`, a Linux URLSession limit). The existing
  `FuzzFindingsTests` found a real crash in the first version of the Tonal Balance Q
  normalisation (`Int(Float)` on an unbounded value); fixed.
- Real patched engine on Linux (WSL, GCC 13, ASan + UBSan, `-Werror`): `Tests/Native`
  `engine` preset against v2.12.0 with the four patches applied by the CMake script: build
  of the whole DSP core (all 110 kernels) and 121/121 tests passed, including the 6 engine
  tests.
- Upstream native tests of the new and changed kernels, on a copy of v2.12.0 `dsp/` with
  the four patches applied (`patch --fuzz=0`, a few hunks at an offset of 5 lines; WSL, GCC 13,
  Release): 11 of 11 test targets passed (`analog_meter`, `rhythm_analyzer`,
  `tonal_balance_eq`, `note_spectrogram`, `note_spectrogram_model`, `heap_tree_model`,
  `oscilloscope`, `graph`, `level_meter`, `pitch_meter`, `dynamics_group_a`). Not built with
  MSVC, and apart from the flags upstream lists, with GCC's default contraction.
- Mac (Xcode 27.0, macOS 26.6.2, fresh tree `~/work/effetune-2120` fed from `git archive`
  with `Vendor/effetune` at `1d4d33b2` unpatched): `Scripts/setup.sh` applies the patches,
  regenerates and embeds the 8 models; `Scripts/build.sh` (Debug, iphoneos arm64, via the
  GUI Terminal, install skipped) `BUILD SUCCEEDED`; the `Logic` scheme `build-for-testing`
  for the generic iOS Simulator `TEST BUILD SUCCEEDED` (compile only; no simulator was
  booted).

Not done: any device or simulator run. The three new views and the Note Spectrogram changes
have been compiled but never looked at; the Tonal Balance handles, the Rhythm Analyzer
layout on a phone and the dial geometry need an eye.

## Differences from upstream and things left out

- Analog Meter is `stateless` upstream: stopping and resuming keeps Integrated, LRA and max
  True Peak. Here `AudioIO.stop()` calls `et_engine_reset`, which resets every stage, so a
  stop clears them (Reset does the same on demand). Keeping them would need a reset that
  skips one kernel, which the engine does not offer. Tonal Balance EQ is
  `reset-on-resume`, which matches.
- Tonal Balance EQ: no "Copy as PEQ" (it needs a port of `features/measurement/peq-calculator`),
  no legend or cursor readout, and no pausing of the measurement while the frequency preview
  plays (`mp`; the card's graph does not play the preview tone).
- Rhythm Analyzer: no cursor readout; text is not outlined (SwiftUI `Canvas` cannot stroke
  text), so overlapping labels are dropped, as upstream does, but over the tempogram they
  are less legible. The tempogram is smoothed when scaled.
- Note Spectrogram Volume: the bars are not joined across frames with tapered bands
  (`volumeFrameEnds`); the thickness stays in whole sub-rows. Piano key shading and the
  dark-mode key colours (221 -> 238, 34 -> 17) do not apply: this app paints the keys with
  its own shading styles.
- `-ffp-contract=off`: upstream now sets it on 13 kernels (new: Analog Meter, Rhythm
  Analyzer, Tonal Balance EQ; the three that include `k_weighting.h` must agree). The Xcode
  project still builds all kernels with the default, so results are close to, but not
  bit-identical with, upstream's goldens. Not changed here.
- Out of scope (web or Electron only): Visualizer, hover crosshairs (`GraphReadout`), themed
  dropdowns, library and SQLite catalog, MIDI app targets, the worklet's `gate` crossfade
  and `assetPending`, the Room EQ host-plot refactor, `et_rhythm_analyzer_warm_up`
  (`__EMSCRIPTEN__` only), the offline generators (`learn_targets.py`, `compact_model.py`).
- Showing a version mismatch when connecting to the PC (the remote control): not part of this
  branch. It is done on `feature/remote-poc` (merged with this branch) and the fork
  (`poc/remote-control`): the PC's hello reply carries `dsp` and `effects`, EffectDeck's hello
  carries `dsp`; a Version row in Remote Control shows the difference, effects the PC lacks are
  not sent (chain or presets) and their cards show the unsupported text. A PC that does not
  report `effects` is compared by `dsp` only, and one that reports neither is not refused anything.
- Sub Synth graph: the dry curve is scaled by Dry Level (upstream `_dryResponseDb`).

## Handoff

On macOS, copy the tree with `Vendor/effetune` at `v2.12.0` unpatched, run
`bash Scripts/setup.sh`, build in Xcode and run the `Logic` scheme. The Mac's `~/work`
tree for this work is `effetune-2120` (a throwaway; the scripts `~/gui_compile_2120.sh` and
`~/gui_logic_2120.sh` point at it).

The remote PoC fork is still based on 2.11.0 (it reports `effects` and `dsp` now): a PC that does
not know Analog Meter, Rhythm Analyzer or Tonal Balance EQ is told apart and those stages are not sent.
