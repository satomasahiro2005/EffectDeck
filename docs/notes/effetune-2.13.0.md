# EffeTune 2.13.0 integration

Branch: `feature/effetune-2.13.0`, based on `b92defc` (main).
Upstream: release tag `v2.13.0` (`6791afdf`, DSP 0.13.0, tag `dsp-v0.13.0` on the same
commit). App version/build numbering is unchanged; nothing is tagged or released here.

**Nothing in this branch has been built in Xcode or run on a simulator or a device.** The Mac
was offline. Everything below that is marked as run was run on Windows (Python, Node) or on
Linux (WSL: the Swift Logic bundle, the native engine). SwiftUI views, the AVFoundation and
document-picker code and the Xcode project are only read, not compiled.

## Implementation

### Import and build (DSP side)

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
    the new file. No new third-party code in `dsp/`.
- Catalog: 112 effects, 711 parameters.
  - New: Adaptive Prediction (resonator) and SFZ Note Player (others).
  - Note Spectrogram loses `nc` (Regular Note Limit). Chains that carry `nc` still load.
  - Cassette Artifacts gains `md` (Mode, default All, listed first). A chain without `md` loads
    as All, which is the previous behaviour.
  - 167 effect presets in 30 effects (Adaptive Prediction brings four; the five Cassette
    presets gain `"md":"All"`). `chain/v0.13.0/` is added, `chain/v0.12.0/` is kept, and
    `CHAIN.md` and the README badge point at 0.13.0.
- `gen_catalog.py`:
  - It reads rows kept in a table and fed to the factory in a loop (`[key, label, min, max,
    step, unit]`, `[key, label]`), and helpers that take the parent element first
    (`addParameter(parent, key, label, min, max, step, unit, toDisplay)`). With a `toDisplay`
    only the label is taken, so Weight Decay and Autonomy keep the params.json range and step
    (the card's slider steps are 0.1 and 0.001, not upstream's 0.5 and 0.01).
  - `resetToken` is `runtimeOnly`: it is not saved, not read, and not compared.
  - SFZ Note Player is in `CHAIN_UNSUPPORTED`.
- Loading follows upstream's `setParameters`: Adaptive Prediction Weight Decay (0 stays 0, values
  between 0 and 0.5 become 0.5); SFZ Note Player (Highest Note raised to Lowest Note, Velocity
  127 Level to Velocity 1 Level + 1 dB, note range, Max Voices and Octave rounded like
  `Math.round`).
- Adaptive Prediction on All (-2) is passed to the engine disabled (`ETChainEditing.isChannelBypassed`):
  upstream supports mono, single and stereo-pair only.
- The generic card hides `runtimeOnly` parameters.

### Telemetry and the analyzer views

- Telemetry queue: `Telemetry` kept only the latest frame per tap and type. Note Spectrogram
  frames now come at 50 fps (a frame every 20 ms) and the app polls at 30 Hz, so a latest-only
  read dropped about 40 % of them, and the revisions target the frames 2, 4 and 8 back. Frames
  of type 24 (Note Spectrogram) and 28 (Rhythm Analyzer) are queued per tap and type, in order,
  up to 256 each, and drained with `Telemetry.drainFrames(tap:type:)`. `ETFrameType` gains
  `noteSpectrogram = 24`. The same queue serves frames injected from a PC.
- Note Spectrogram:
  - Frames are version 5, 8840 bytes (see `DSP/NoteSpectrogramFrame.swift`).
  - `ETNoteBand` takes all drained frames and builds the image once per drain, keeps 512
    columns (a Time Span of 10 s is 500 columns at 50 fps) and remembers which frame each
    column holds. A revision rewrites the column of frame `frameIndex - age`
    (`ETNoteLayout.revisionColumn`, which also handles the 32-bit wrap) and repaints it. dB
    (Volume) is not revised, as upstream.
  - Version 3 frames from a fork PC on 2.11/2.12 are not read.
- Rhythm Analyzer (frames version 4, 1496 bytes): the model (`DSP/RhythmAnalyzerModel.swift`)
  follows upstream's v2.13.0 display logic:
  - Generations: a newer kernel generation continues the display (`spliceGeneration`,
    `rebaseSnapshot`: frame counts continue, epochs get `+2^32`, so epochs are `UInt64`).
    Telemetry's `clearCount` (the engine was rebuilt) still clears everything, as do Reset and a
    Min/Max BPM change.
  - Tempogram: columns come from the analysed time since the first frame; the adopted tempo of
    a newly committed anchor is back-filled into the column of the anchor's audio time.
  - Beat clock: committed beats (flags 5) are the history, forward beats (2, 4) and the preview
    beats (offset 1344) are the tail; `clockPosition` interpolates inside the history and
    follows the tail beyond the anchor. The constant default period is gone.
  - Display: the clock and the onset positions ease to corrections with a 100 ms exponential;
    while telemetry is idle the lanes keep moving at the last period (`idleScroll`). The view
    drives a 30 fps `TimelineView` while the lanes are shown and a period is known.
  - Onsets are stored by identity (`generation:frame:fractionBits:band`), so a provisional onset
    is replaced in place when its committed version arrives, and pending onsets are re-placed
    from every new preview path. Reference medians are cached.
  - Metronome Click switched off clears the beat LED; the lamp uses the shown beats (flags 2),
    scaled by their strength.
  - The view: header (`Analysis unavailable at this sample rate` below 48 kHz; `LOCKED` /
    `searching` from the tick gate; tempo, swing and jitter fade with confidence; `○ timing
    unavailable`), lanes with display offsets and a forward-tail pseudo segment, alpha scaled by
    confidence, hollow dots for unlocated onsets, a tempogram line without the 0.15 alpha floor
    that is extended to the right edge at draw time only, and a lens whose three rows match the
    lane rows. Tempogram and Echo rows are off by default (`vt`, `ve`), also in
    `DisplayParams.defaults`. Chains saved before 2.13.0 have neither key and used to show both
    rows, so a stage with neither key is read as `vt` / `ve` true (`ETDisplayParam.legacyRead`),
    and a chain now always writes the Rhythm Analyzer's display keys, as upstream's
    `getParameters` does, so a 2.13.0 stage that was never touched round-trips as false.
- Analog Meter: label spacing is measured as the chord between neighbouring labels.
- The generic card's row gate (`ETParamGate`, Foundation-only) is now a rule over the card's
  values and keeps its old "toggle off" entries. Cassette Artifacts: damage rows (Deck Grade,
  Tape Type, Bias, Wow/Flutter, Hiss, Dropouts, Azimuth) are disabled for Encode Only and
  Decode Only; Dolby Level Error when the decode stage is inactive or Noise Reduction is Off;
  Record Level when the damage rows are disabled and Noise Reduction is Off.

### Adaptive Prediction

`Views/Effects/AdaptivePredictionView.swift` follows upstream's UI: Weight Decay 0.5..60 s with an
Infinity toggle that remembers the last finite value (default 10, not saved), Autonomy shown as 1
and Freeze checked while Hold is on, Learn / Weight Decay / Infinity disabled while Freeze or
Hold is on, a Reset button (`resetToken`, wrapping at 16777215; also sent to a PC with a
`params` op), the `Bypassed` word on All, and upstream's fault sentence in red when
`et_instance_runtime_event` reports a latched fault (polled every 0.5 s while the card is
visible). The Hold hint paragraph is not shown. A chain that holds an enabled, reachable
Adaptive Prediction stage never lets the power gate rest (`PowerGate.idleSeconds(mustProcess:)`,
re-evaluated whenever the chain is published), because Autonomy and Hold keep sounding after the
input goes silent. `ParameterRow` gained `shown` and `lowerBound` for the overridden display.

### SFZ Note Player

- Foundation-only ports of upstream's `js/sfz/`: `SFZParser.swift`, `SFZBank.swift`,
  `SFZAsset.swift`, `SFZLibraryFiles.swift`. They are checked byte for byte against upstream's
  own output (`Tools/golden/sfz_golden.mjs` writes `Tests/Fixtures/SFZ/sfz-golden.json`): parser
  results and diagnostics, the bank container and its id, the asset payload, the budget
  reduction, and whole folder imports including the reduced banks. Because the container JSON
  is written exactly like `JSON.stringify`, importing the same folder here and in the desktop
  EffeTune gives the same 24-hex bank id.
- App side (`DSP/SFZLoader.swift`, `Views/Effects/SFZNotePlayerView.swift`): the library lives
  in Application Support/SFZ (excluded from backup); sample files are opened with
  `AVAudioFile`; reading, decoding and packing run off the main thread and only
  `AssetUpload.send` runs on it. The limit is upstream's default, 256 MiB, with no setting.
  `AssetUpload.send` and `beginRequest` take the slot capacity (SFZ: 1 GiB, the others stay at
  32 MiB). A bank key is carried in the node's `irId` and saved as `sf` for SFZ Note Player
  (`ir` for IR Reverb; `ETChainText.assetKey(forType:)`); invalid keys are read as empty.
- The card: a bank menu (None, the banks, `Missing SFZ`), Import Folder… (`fileImporter` with
  `.folder`; the folder is walked up to depth 32 and 10000 files), a second menu and Import when
  the folder has several `.sfz`, Remove, a red error line, one alert with the load warnings
  after an import, then the parameter rows in upstream's order; Lowest and Highest Note use the
  note-name row of the Note Spectrogram (`ETNoteRangeRow`).
- `setParameters` rules: on load, Lowest / Highest Note, Max Voices, Octave, Velocity 1 and 127
  Level are clamped to their `params.json` ranges first, then rounded, then Highest Note is raised
  to Lowest Note and Velocity 127 Level to Velocity 1 Level + 1 dB (`ETUpstreamNormalize`). The
  two cross rules also run on every edit from the card (`EffeTuneDSP.setValue`), like upstream's
  slider path. Reset, or removing the bank, also resets the loader state (`SFZLoader.forget`):
  a Reset during a load discards the result, and a red error line goes away.
- SFZ Note Player is in the picker and listed under New.

### LAN remote control (official EffeTune 2.13.0)

- `ETFeatures.remoteControl` is `true` in every build. The flag, its doc comment and every guard
  stay, so returning `false` closes all entry points again.
- The official hello reply has `appName`, `app`, `features` (`origin`, `savePreset`, `irSync`,
  `sync1`) and `effects` (113 names, equal to the catalog plus Section); no `dsp`, no `build`,
  no `telemetry` / `overlays`. `Tools/gen_version.py` now also writes `ETUpstreamAppVersion`
  (`package.json` version, "2.13.0"). A host that reports no `dsp` and a different `app` shows
  `EffeTune 2.14.0 on the PC, 2.13.0 here` in the Version row; a host that reports `dsp` is
  compared by `dsp` as before. This is display only.
- The Options section (Mirror Analyzers) is shown only for a host that advertises `telemetry`.
- `params` cannot unset a key. A flush where a stage lost a key since the last send (an IR or an
  SFZ bank cleared, a Room EQ measurement removed, a display or design key dropped) sends the
  whole chain instead (`ETRemoteProjection.removedKeys`). On the PC a `chain` goes through the
  preset loader: it adds an undo entry, shows "preset loaded" and clears the preset name, and
  with master bypass on it can briefly be audible.
- `docs/notes/effetune-remote-followup.md` is marked resolved.

### Tests

- New or changed in `Tests/Unit`: `Upstream213Tests`, `ParamGateTests`, `SFZTests`,
  `RhythmAnalyzerTests` (29 tests; version 4 frames, tempogram buckets, clock positions, LED,
  provisional onsets, idle scroll, generation splice), `RemoteProtocolTests` (official
  2.13.0 host, removed keys), `Upstream212Tests` (new display defaults).
- Python: the table rows, the parent-first helper, the 2.13.0 tables, and
  `ETUpstreamAppVersion` in `test_gen_version.py`.

## Verification

Run this session unless noted (the Mac was offline; no Xcode build, no simulator, no device).

- Swift Logic bundle on Linux (WSL, Swift 6.4, `Tests/Linux/run.sh`): 1020 tests, 0 failures,
  1 skipped (`RemoteFileDownloadTests`, a Linux URLSession limit). That is after the last code
  change in this branch.
- Python tools (`Tests/Tools`, Windows): 251 tests OK, 9 skipped (none related to these
  changes); `node --test Tools/*.test.mjs` 5/5; `check_repo.py` ok. Generators were run with
  `ET_STRICT=1` at the import commit: 112 effects, 711 parameters, 17 presets in 9 categories,
  167 effect presets in 30 effects, 7 licences, version 0.13.0.
- `Tools/golden/sfz_golden.mjs` was run against `extract_pin.sh` at `6791afdf`; the Swift port
  matches its output in all 14 `SFZTests`.
- Earlier, at the import commits and unchanged since (no `dsp/`, `Patches/` or `Scripts/` file
  was touched afterwards):
  - `Tools/golden` against the pin: only `designers-b-golden.json` changed (`upstreamVersion`).
  - Real patched engine on Linux (WSL, GCC 13.3, ASan + UBSan, `-Werror`), `Tests/Native` engine
    preset with the four patches: 121/121 passed with the preset's `lsan.supp`. Without it the
    11 tests that publish external descriptors report the intentional
    `ETPipeline_SetExternalProcessorAt` leak.
  - Upstream native tests (GCC 13.3, Release, `BUILD_TESTING=ON`) on a copy of the whole v2.13.0
    tree with the four patches (`patch --fuzz=0`, all hunks at offset 0): 87/87 passed, including
    SFZ, Adaptive Prediction, Note Spectrogram, Rhythm Analyzer and `spectrum_tap`.
  - `embed_models.py --target macho` for the three Rhythm Analyzer models: OK.

Not done: Xcode, simulator and device. Not yet compiled with Apple clang or swiftc on the Mac:
- `spectrum_tap.cpp` (NEON and atomics), the 1.2 MB `harmnet_weights.h`, and the `eval.cpp`
  exclusion. If the exclusion does not take, the link fails on a duplicate `_main`.
- All SwiftUI and AVFoundation code of this change: `RhythmAnalyzerView.swift`,
  `AdaptivePredictionView.swift`, `SFZNotePlayerView.swift`, `SFZLoader.swift`,
  `NoteSpectrogramView.swift`, `RemoteScannerView.swift`, `ParameterRow.swift`, the
  `EffeTuneDSP` and `AudioIO` edits. Expect to fix small compile errors first.

## Differences from upstream and things left out

- Rhythm Analyzer: the cursor readout (`plainCursor`, "Tempo support") is not ported, nor are
  the outlined texts, nor the stream-boundary reset at a player track change (EffectDeck has no
  player). `et_rhythm_analyzer_warm_up` stays `__EMSCRIPTEN__`-only. The view is a port by
  reading, not by pixel comparison.
- Note Spectrogram: Volume bars are still not joined via `volumeFrameEnds`; the readout keeps
  using the strongest subdivision's level.
- Adaptive Prediction: Weight Decay and Autonomy use the params.json steps (0.1 and 0.001,
  upstream's UI uses 0.5 and 0.01). The Hold hint is not shown, and the fault line appears only
  for a stage that runs locally.
- Cassette Artifacts uses the generic card. Upstream's status line (record level to tape peak,
  hiss estimate) is not shown.
- SFZ Note Player:
  - No size-limit setting (fixed 256 MiB) and no Electron native service. Peak memory during an
    import can reach about 3 to 4 times the limit (the container, the decoded PCM, the payload and
    the kernel's copy), which may be too much on a phone with little memory.
  - The analysis of an upstream Note Spectrogram is not shared (`et_instance_set_analysis_source`,
    new in this ABI; upstream rules in `audio-processor.js` `findNoteAnalysisSources`). The kernel
    runs its own analysis when it is not linked, so with both stages in a chain the analysis runs
    twice.
  - Without a bank the wet signal is silent and Dry defaults to 20 %, so the stage attenuates the
    signal until a bank is loaded (same as upstream).
  - Over the remote control, `sf` is only an id: there is no bank transfer op upstream, so a PC
    shows `Missing SFZ` unless the same folder was imported there (which gives the same id).
  - Audio files are opened with `AVAudioFile` (WAV, AIFF, FLAC, CAF, MP3, AAC). Ogg is not
    readable on iOS, so a bank that refers to `.ogg` samples fails to load.
- Remote control:
  - Not done: the optional sync1 `edit` path (`set` with `d`) that would avoid the preset-loader
    side effects of `chain`; it needs a record of stage ids and a safe fallback.
  - Not confirmed: that `URLSessionWebSocketTask` sends no `Origin` header (the host rejects
    `Origin: null`), and the behaviour of `chain` on a PC (undo history, preset name) with a real
    EffeTune.
  - The Version row can show for harmless patch-level differences of the PC (2.13.1).
- `-ffp-contract=off`: upstream now sets it on 16 kernels (new: Note Spectrogram, SFZ Note
  Player, Adaptive Prediction; `/fp:strict` for Rhythm Analyzer under MSVC). The Xcode project
  still builds all kernels with the default. Not changed here.
- New C exports not used: `et_instance_set_analysis_source` and
  `et_pipeline_refresh_latency` / `_reserve_latency` / `_refresh_latency_realtime`.
  `EffeTuneDSP.settleAfterParams` already republishes when `et_instance_latency` changes, which
  covers SFZ's `tm` and the saturation kernels that now report a latency range.
- No change needed: Stereo Meter (denormal samples are excluded inside the kernel), Gate, Power
  Amp Sag, 5Band Dynamic EQ, Chorus and Multiband Saturation (processor and kernel
  optimisations; no parameter, default or telemetry change). Out of scope (web only): Guitar in
  the Visualizer and `meterAppearance`, the SpectrumTap timing contract in `spectrum-overlay.js`
  and `multires-spectrum.js`, the frequency preview and pitch audition, `plainCursor`, the
  plugin-base number-input plumbing, Tube Simulator's fault notice (the same
  `et_instance_runtime_event` plumbing could serve it later).
- Release text: `Tools/review_notes.txt` still says "EffeTune Remote Control is off". It must be
  rewritten before the next App Store submission (Remote Control now asks for local-network and
  camera access, and App Review may ask for a demo PC setup). It was not edited.

## Handoff

On macOS:
1. Copy the tree with `Vendor/effetune` at `v2.13.0`, unpatched.
2. Run `bash Scripts/setup.sh`. It applies the four patches, regenerates, and embeds three
   models.
3. Build in Xcode, fix what the compiler finds in the unbuilt views above, then run the `Logic`
   scheme.

First things to check on a device:
1. Pair with an official EffeTune 2.13.0 through the QR code. No Version row should appear and
   the Options section should be hidden. Edit knobs, add and remove stages, clear an IR or a Room
   EQ measurement and check that the PC follows; look at the PC's undo history and preset name.
2. Note Spectrogram: notes appear, Time Span 10 s fills the width, no blank card.
3. Rhythm Analyzer: at 48 kHz, lock, LED, lanes and lens, and Tempogram and Echo rows off for a
   new instance; on a 44.1 kHz route, `Analysis unavailable at this sample rate`.
4. Adaptive Prediction: the four presets, Infinity / Freeze / Hold gating, Reset, Hold keeps
   sounding through silence with Power at 1 s and 3 s, Channel All shows `Bypassed`.
5. Cassette Mode dims the right rows.
6. SFZ: import a folder with several `.sfz` files, pick one, play, then Remove; check the missing
   bank state by opening a chain whose bank is gone.
