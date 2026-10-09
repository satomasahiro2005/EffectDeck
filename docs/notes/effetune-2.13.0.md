# EffeTune 2.13.0 integration

Branch: `feature/effetune-2.13.0`, based on `b92defc` (main).
Upstream: release tag `v2.13.0` (`6791afdf`, DSP 0.13.0, tag `dsp-v0.13.0` on the same
commit). App version/build numbering is unchanged; nothing is tagged or released here.

## Implementation

- Vendor: `Vendor/effetune` is pinned to `6791afdf`. Upstream did not take over any of the
  four patches, so all four stay:
  - `abi-begin-ptr`: unchanged content, regenerated so that it applies at offset 0.
  - `effetune-external-node`, `-latency` and `-routing` no longer applied, because
    `dsp/core/abi.cpp` and `engine.cpp` moved a lot: new `et_pipeline_refresh_latency`,
    `_reserve_latency` and `_refresh_latency_realtime`, and `processPipeline` now passes a
    `ProcessInfo` from `nodeProcessInfo`. They were rebased with the same content. The external
    branch still passes `time_seconds`, so host transport does not reach AU or JSFX nodes (it
    never did).
  - The node patch has two new guards for code that 2.13.0 added and that would dereference a
    null instance for an external node (instance 0): `Engine::reservePipelineLatency` gives an
    external node the range `{current, current}`, and `Engine::pipelineTapLatency` skips
    external nodes. EffectDeck does not call the reserve and refresh APIs yet.
  - Upstream's `Engine::setPipelineObserver` (PR #67) is a C++-only, read-only before/after
    observer. It cannot run host processing at a node, so it does not replace the patches.
  - The `setup.sh` markers still match.
- Build:
  - The embedded models are down to the Rhythm Analyzer's three onset-lane models
    (`rhythm_d_low/mid/high`, now in the `oblivious` layout; `oblivious_tree_model.h` is in
    `tree_models/`, already on `HEADER_SEARCH_PATHS`). Note Spectrogram moved to compiled
    HarmNet weights (`harmnet_weights.h`, 1.2 MB of source compiled into the Note Spectrogram
    and SFZ Note Player translation units), and G2 is gone. `Scripts/setup.sh` loops over the
    three. The old entries would make `embed_models.py` fail, because their manifests no longer
    exist.
  - `plugins/analyzer/rhythm_analyzer/eval.cpp` is an evaluation driver with an `int main`
    (upstream builds it only as a test, with `ET_RHYTHM_EVALUATION`). It is excluded in
    `project.yml` and in `check_release_binary.py` `SOURCE_ROLES` (with a test), like
    `calibrate_tables.cpp`.
  - New sources are picked up by the existing globs: `core/spectrum_tap.cpp` (compiled, unused),
    `others/sfz_note_player/`, `resonator/adaptive_prediction_effect/`, the HarmNet headers, the
    `rd6_*` Rhythm Analyzer headers.
  - fdlibm moved from `g2_math.h` to `rd6_math.h`. The header comment is now the notice alone,
    so `gen_licenses.py` compares the whole comment without skipped lines; `NOTICE.md` points at
    the new file. Upstream now ships `plugins/dsp/NOTICE.txt`, which `NOTICE.md` already named.
    No new third-party code in `dsp/`.
- Catalog: 112 effects, 711 parameters.
  - New: Adaptive Prediction (resonator) and SFZ Note Player (others).
  - Note Spectrogram loses `nc` (Regular Note Limit; hash `0x9d70750b`). Chains that carry `nc`
    still load.
  - Cassette Artifacts gains `md` (Mode, default All, listed first; hash `0x328491ae`). A chain
    without `md` loads as All, which is the previous behaviour.
  - 167 effect presets in 30 effects (Adaptive Prediction brings four; the five Cassette
    presets gain `"md":"All"`). `chain/v0.13.0/` is added, `chain/v0.12.0/` is kept, and
    `CHAIN.md` and the README badge point at 0.13.0.
- `gen_catalog.py`:
  - It reads rows kept in a table and fed to the factory in a loop (`[key, label, min, max,
    step, unit]`, `[key, label]`). Without this, SFZ Note Player showed the params.json names
    ("Retrigger Drop Db") with no units. Rows on one line keep their written order (Highest,
    Middle, Lowest).
  - It reads helpers that take the parent element first (`addParameter(parent, key, label, min,
    max, step, unit, toDisplay)`). With a `toDisplay`, only the label is taken. Weight Decay
    keeps 0..60, because 0 means infinity. Gap gets upstream's 0.1 ms step.
  - `resetToken` is `runtimeOnly`: it is not saved, not read, and not compared.
  - SFZ Note Player is in `CHAIN_UNSUPPORTED`.
- Loading follows upstream's `setParameters`:
  - Adaptive Prediction Weight Decay: 0 stays 0, and values between 0 and 0.5 become 0.5.
  - SFZ Note Player: Highest Note is raised to at least Lowest Note, and Velocity 127 Level is
    raised to at least Velocity 1 Level + 1 dB. The note range, Max Voices and Octave are
    rounded like `Math.round`.
- Adaptive Prediction on All (-2) is passed to the engine disabled (`ETChainEditing.isChannelBypassed`):
  upstream supports mono, single and stereo-pair only, and the kernel passes 3+ channels through.
- The generic card hides `runtimeOnly` parameters (it showed a Reset Token slider).
- SFZ Note Player is in the catalog, so presets, links and PC chains that name it still decode,
  but it is hidden from the picker (`EffectPickerView.hiddenTypes`) until SFZ import exists.
  Without an asset it plays only its dry mix (20%). `newTypes` lists Adaptive Prediction.
- Telemetry:
  - Note Spectrogram frames are version 5, 8840 bytes. Confidence starts at 32 and dB at 1792.
    A frame carries revised confidences for the frames 2, 4 and 8 hops back. `ETNoteBand`
    remembers which frame each column holds and rewrites that column (upstream
    `_applyFrameRevision`; dB is not revised). The frame reader moved to the Foundation-only
    `DSP/NoteSpectrogramFrame.swift`.
  - Rhythm Analyzer frames are version 4, 1496 bytes. The item flags are now a kind: committed,
    invalid and provisional onsets, and shown forward, hidden forward and committed beats.
    Preview beats follow at 1344. The existing view is driven from this:
    - The beat clock runs from the anchor (the last analysed beat).
    - The LED runs from the shown beats and is scaled by their strength.
    - Provisional onsets are not stored, because the committed onset arrives later.
  - Versions 1 and 3 are no longer read.
- Tests (`Tests/Unit`):
  - New `Upstream213Tests`.
  - `RhythmAnalyzerTests` were moved to version 4, with cases for beats, preview beats and the
    LED.
  - Counts updated: 167 presets in 30 effects, 471 string values.
  - `Upstream212Tests` no longer pins the version or the effect count.
  - `OversamplingTests` skips SFZ Note Player, whose `os` is Octave Shift.
  - Python: the table rows, the parent-first helper, and the 2.13.0 tables.

## Verification

Run on the branch (the working tree equal to the last code commit unless noted).

- Python tools (`Tests/Tools`, Windows): 250 tests OK (9 skipped, none for these changes);
  `node --test Tools/*.test.mjs` 5/5; `check_repo.py` ok. Generators run with `ET_STRICT=1`:
  112 effects, 711 parameters, 17 presets in 9 categories, 167 effect presets in 30 effects,
  7 licences, version 0.13.0.
- `Tools/golden` against `extract_pin.sh` at `6791afdf`: only `designers-b-golden.json` changed
  (`upstreamVersion` 2.13.0). The designer inputs did not move upstream.
- `embed_models.py --target macho` for the three Rhythm Analyzer models: OK (writes
  `*.generated.h` and `.S`).
- Swift Logic bundle on Linux (WSL, Swift 6.4, `Tests/Linux/run.sh`): 971 tests, 0 failures,
  1 skipped (`RemoteFileDownloadTests`, a Linux URLSession limit). This includes 13
  `Upstream213Tests` and 19 `RhythmAnalyzerTests`. The first run failed once in
  `OversamplingTests` (SFZ Note Player's `os`); that was fixed.
- Real patched engine on Linux (WSL, GCC 13.3, Debug, ASan + UBSan, `-Werror`):
  - `Tests/Native` `engine` preset against v2.13.0, with the four patches applied by the CMake
    script, and the preset's `LSAN_OPTIONS` (`lsan.supp`): 121/121 passed, including the 6
    `engine` tests. Without the suppression file, the 11 tests that publish external
    descriptors report the intentional `ETPipeline_SetExternalProcessorAt` leak.
- Upstream native tests (WSL, GCC 13.3, Release, `BUILD_TESTING=ON`):
  - Run on a copy of the whole v2.13.0 tree with the four patches applied by
    `patch --fuzz=0` (all hunks at offset 0): 87/87 passed.
  - These include `effetune_dsp_tests` (ABI), `graph`, `spectrum_tap`,
    `sfz_note_player`, `adaptive_prediction_effect`, `note_spectrogram`, `rhythm_analyzer`,
    `rhythm_analyzer_eval`, `cassette_artifacts`, `heap_tree_model`, `tree_model_embedding`,
    `codegen` and both Tube Simulator fixture tests.
  - Not built with MSVC, and apart from the flags upstream lists, built with GCC's default
    contraction.

Not done: Xcode, simulator and device. The Mac was offline, so nothing has been built with
Apple clang. Not yet compiled there:
- `spectrum_tap.cpp` (NEON and atomics)
- the 1.2 MB `harmnet_weights.h`
- the `eval.cpp` exclusion. If the exclusion does not take, the link fails on a duplicate
  `_main`.

## Differences from upstream and things left out

- SFZ Note Player has no import, library, bank picker or asset upload yet. It is hidden from
  the picker, and a stage that arrives in a chain plays only its dry mix. The asset contract
  is:
  - slot 0, `ET_ASSET_F32_MULTICH`
  - the 32-byte ETA1 header, then the `0x53465A` header, the 30-field regions and interleaved
    float PCM
  - the bank is built in JS upstream (`js/sfz/`)
  - preparation runs incrementally on the audio thread
  - its latency depends on `tm`
- Adaptive Prediction uses the generic card:
  - No Reset button: `resetToken` is runtime-only and hidden. `EffeTuneDSP.resetState(at:)`
    also resets the kernel.
  - No Infinity toggle: Weight Decay is a 0..60 s slider, where 0 means infinity.
  - No disabled states for Freeze and Hold, no hold hint, no fault status.
  - On All it is bypassed, as upstream does, without upstream's status text.
- Rhythm Analyzer: upstream's view was largely rewritten (forward beats and preview beats,
  committed beat history, provisional onsets replaced by identity). Only the frame and the
  existing view's clock and LED were ported, so beat positions and the tempogram's adopted line
  are close to, but not the same as, upstream's.
- Note Spectrogram: only the revisions are new. Volume bars are still not joined across frames.
- New C exports not used: `et_instance_set_analysis_source` (an SFZ Note Player can reuse a
  preceding Note Spectrogram's analysis; a CPU saving for later) and
  `et_pipeline_refresh_latency` / `_reserve_latency` / `_refresh_latency_realtime`.
  `EffeTuneDSP.settleAfterParams` already republishes when `et_instance_latency` changes. That
  covers SFZ's `tm` and the saturation kernels that now report a latency range.
- `-ffp-contract=off`: upstream now sets it on 16 kernels (new: Note Spectrogram, SFZ Note
  Player, Adaptive Prediction; `/fp:strict` for Rhythm Analyzer under MSVC). The Xcode project
  still builds all kernels with the default. Not changed here.
- Out of scope (web only): Guitar in the Visualizer, the JS UI refinements (frequency axis,
  graph readout, spectrum overlay), `TELEMETRY_RING_BYTES` 512 KiB (EffectDeck already uses
  1 MiB).
- The LAN remote control (upstream now ships it) is not part of this change.

## Handoff

On macOS:
1. Copy the tree with `Vendor/effetune` at `v2.13.0`, unpatched.
2. Run `bash Scripts/setup.sh`. It applies the four patches, regenerates, and embeds three
   models.
3. Build in Xcode, then run the `Logic` scheme.

First things to look at on a device:
- The Note Spectrogram (revisions) and the Rhythm Analyzer (clock, LED, onsets on version 4).
- Adaptive Prediction on a stereo pair and on All.
- That SFZ Note Player is absent from the picker.
