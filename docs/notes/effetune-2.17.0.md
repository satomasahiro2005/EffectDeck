# EffeTune 2.17.0 integration

Branch: `feature/effetune-2.17.0`, based on `origin/main` (`5d1a558`).
Upstream: tag `dsp-v0.17.0` (`5ffca1b3`, DSP 0.17.0). App 2.17.0 is `b3f2c61d`; the pin is six commits later and only
touches packaging and CI. Previous pin: `3769b9ae` (`dsp-v0.16.0`).

2.17.0 is mostly one thing for EffectDeck: the SFZ Note Player became the **SoundFont Note Player** and its asset payload
changed shape, so every bank that worked on 2.16.0 stopped loading. The first half is the import and the small follow-ups.
The rest is the SFZ / SoundFont work, which is big enough that it has its own sections.

Built and tested on Windows / WSL (Logic bundle on Linux, Native, Python, node). **Nothing was built in Xcode and nothing ran
on a device.** Everything that needs UIKit, SwiftUI, AVFoundation or JavaScriptCore is written but unbuilt; the macOS CI
`logic` and `sim-build` jobs are the first compile. See "Not verified" at the end.

## Import

- Pin `5ffca1b3`. Catalog: **113 effects, 726 parameters** (was 112 / 721). `chain/v0.17.0/` added, `CHAIN.md` and the README
  badge point at 0.17.0.
- `Patches/abi-begin-ptr.diff` is **gone**: upstream now has `et_instance_asset_begin_ptr`. Upstream's version takes a last
  argument `minimum_physical_bpm`; `AssetUpload` passes 0 (prepared at 120 BPM). `Scripts/setup.sh` only checks that the entry
  point exists. The three `effetune-external-*` patches were re-based onto the new pin without changing their content.
- Two new patches for the JS bundle, `Patches/effetune-js-sfz-pool-writer.diff` and `Patches/effetune-js-sfz-stream-table.diff`
  (see "JavaScriptCore" below). They patch `js/sfz` only; the DSP patches are untouched by them.
- **New effect `SoundFontPlayerPlugin` ("SoundFont Player")** plays MIDI songs on SF2 / SF3 / SFZ. EffectDeck has no song player,
  so it is in the catalog (the count and the hashes must match the kernel) but **hidden everywhere a person could reach it**:
  `EffectPickerView.hiddenTypes`, `Automation.excludedTypes` (no Follow Volume), and `Tools/gen_catalog.py` marks it as
  unsupported in the chain docs ("plays MIDI songs"). Its Interpolation default is 1 (FIR32) to match
  `soundfont_player.js:14`; `Tools/gen_catalog.py` `DEFAULT_OVERRIDES` carries that (`sampleQuality` = 1). Test: `Tests/Tools/test_picker_hidden.py`
  reads the picker source, because `hiddenTypes` lives in a SwiftUI file the Linux bundle cannot compile.
- `sp0` (Preset) is a new parameter of the Note Player at offset 20, range -1...8388607, default -1. In `ETParamCoding` it is
  clamped and rounded the way upstream does (`Math.round`, done in Double: Float cannot hold `.5` from 2^23 up).
  `Tests/Unit/Upstream217Tests.swift` covers version, counts, `sp0`, the SoundFont Player entry, its Interpolation default and
  its exclusion from automation.

## The rename and old names

"SFZ Note Player" is now **"SoundFont Note Player"**. The type name stays `SFZNotePlayerPlugin` (saved chains and presets key on
it), and so does the wire name.

- `ETEffectAliases` (Foundation only) maps old display names to the new ones with a `since` version (0.17.0). `PipelineForm`,
  `ETChainText`, `EffectPresetStoreCore` and `RemoteProtocol` go through it, so a chain, a preset or a remote message that still
  says "SFZ Note Player" loads as the same effect, with the same asset key.
- `wireName` / `isBefore` decide what to **send** to a PC: the new name, except when the PC's `effects` list lacks the new name
  and has the old one (and, when the PC reports no `effects`, when its `dsp` is older than 0.17.0); then the old name is
  written. A PC on 2.16.0 or earlier therefore keeps working with a chain from this build (a chain with an effect the PC does
  not know is refused as a whole).
- The screens say "SoundFont" where upstream's 2.17.0 labels do: "SoundFont:", "SoundFont Library…", "Missing SoundFont",
  and the alert title. The error and warning texts are upstream's `sfzNotePlayer.*` / `sfzLibrary.*` strings, collected in
  `SFZMessages.swift` (Foundation only, so Linux covers them).

## Local-key note names (Note Spectrogram)

2.16.0 chose `#` or `b` from the **overall** key (`overallKey`). 2.17.0 chooses them from the **local** key, so Lowest / Highest
Note and chord labels follow a modulation inside a song.

- `ETNoteChordTrack` gained `notationKey` / `notationNames`, both following `localKey`. `ETNoteBand.notationNames` and
  `setNotation(key:)` use them. A local key outside 0..23 (24 = none, or nil) falls back to sharps.
- Chroma Spiral and the SFZ screens still use sharps (as in 2.16.0).
- Test: `NoteSpectrogramLocalKeyTests` (uses `chord-key-telemetry.bin`). The SwiftUI side is unbuilt.

## SFZ / SoundFont: why this was needed

- The 0.17 kernel's `SFZBank::commit` accepts payload versions 6 and 7 (SFZ), 8 / 10 (streamed SFZ) and 9 (SF2 / SF3), and
  requires `header(3) == 113` (the control layout). EffectDeck wrote **version 2 with 30 lanes and 8 header words**, so every
  send failed on the first 0.17 build. There was nothing on disk to convert: the library stores the **source** in
  `.sfzbank`, and that container format did not change. "Migration" is repacking at load time.
- Streaming is not optional any more for some banks. `load_mode`, `load_start` and `load_end` throw "needs sample streaming".
  SF2 and SF3 are always streamed. A SFZ over the memory budget used to be **reduced** to fit; upstream removed that, so it is
  either streamed or it fails with `too-large`.
- A streamed bank in real time needs `et_instance_stream_configure` after commit. `SFZEngine::process` calls `failRuntime()`
  for a streamed ACTIVE bank that has no offline trial, and `configure` is what creates it.

## Decision: run upstream's JS in JavaScriptCore

The alternatives were a Swift port of about 6.5k dense JS lines (`design-swift-port.md`) and a thin legacy-to-v6 repacker
(`design-pragmatic.md`). The port would have to be redone for every upstream change to `js/sfz`; 2.17.0 alone is as big as the
whole 2.13.0 port. So upstream's `js/sfz` + `js/sf2` run **as they are**, bundled, inside JavaScriptCore. Real-time and bulky
work stays native. Plans and scores: `C:\Users\masahiro\workspace\effectdeck-plans\sfzFinal.md` (section 1).

### JavaScriptCore architecture

- **Bundle.** `Tools/sfzjs/build.mjs` extracts the pin (`Tools/golden/extract_pin.sh`), applies the two patches, and runs esbuild
  (**0.28.2, exact**) as one **classic-script IIFE** (`var ETSFZ`), because module loading is not public API in
  JavaScriptCore. Output: `Sources/EffeTuneLive/Resources/SFZ/effetune-sfz.js`, with a header carrying the pin, esbuild
  version, patch hashes and the output's sha256. Input and output are fixed to LF, so `autocrlf` cannot change the hash.
  `Tools/sfzjs/modules.txt` lists the bundled upstream modules; a new upstream import fails the build until someone reads it.
  Entry points are `Tools/sfzjs/entry.mjs`. CI rebuilds the bundle and `git diff --exit-code`s it.
- **Prelude.** `effetune-sfz-prelude.js` installs only what is missing: `TextEncoder` / `TextDecoder` (UTF-8 fatal and the
  WHATWG windows-1252 table), `crypto.subtle.digest` and `getRandomValues` (host calls), `Blob` / `File` backed by bytes or host
  file ranges, `setTimeout`, a `MessageChannel`-like pair, and `AudioDecoder.isConfigSupported`. Upstream uses no `fetch`,
  `DecompressionStream` or `WebAssembly` in `js/sfz` / `js/sf2`; the vendored encoder that does is not reachable.
- **Host.** `ETJSHost.swift` uses the **public C API only** (`JSGlobalContextCreate`, `JSEvaluateScript`,
  `JSObjectMakeFunctionWithCallback`, `JSObjectMakeTypedArrayWithBytesNoCopy`). One context on one serial thread; it is built on
  the first job, `JSGarbageCollect`ed after each job, and dropped after 30 s idle (so a 256 MiB import does not leave a JS heap
  behind). Promises and a fake timer pump run inside `await`; if nothing can run and nothing resolves, it fails instead of waiting.
- **Service.** `ETSFZScriptService.swift` hands upstream the work of reading, compiling, packing, the library index, ids,
  warnings and the cost addition. Swift keeps what must be native: sound decoding (`AVAudioFile`), the six storage operations,
  SHA-256, random bytes, and carrying PCM into the engine's staging area.
- **Pool writer patch.** Upstream copies PCM into the payload one float at a time in JS, which is slow when JIT is off. When
  `globalThis.__effectdeckSfzPoolWriter` exists, `asset.js` calls it with the planes and skips the loop; `SFZPoolFill` writes
  straight into the kernel's staging buffer. PCM is never held twice (JS and Swift). Without the hook the code is upstream's.
  The bundle test checks that both paths give the same bytes.
- **Stream-table patch.** Upstream builds the table of where each streamed sample lives inside `prepareStreamedSfzBank` and does
  not expose it. The patch hands it to `globalThis.__effectdeckSfzSampleTable`; `SFZStreamTable` and the page source use it.
- **Library.** `SFZLibraryBackend` implements upstream's six backend calls on disk (`<root>/index.json`,
  `<root>/<24hex>.sfzbank`). Containers up to 1 GiB are streamed to disk in 1 MiB pieces and never pass through JS.
  `index.json` now keeps unknown keys (`streamedSource`, `format`); the 2.16.0 Swift copy knew five keys and dropped the rest.
  Existing libraries open unchanged. The limit is **256 MiB, fixed** (upstream's default; there is no setting).
- **Retired.** `SFZParser`, `SFZSource`, `SFZBank`, `SFZAsset`, `SFZLibraryFiles` and the 0.16 golden are deleted. What both
  sides still need (error codes, limits) is in `SFZCommon.swift`. `sfz-golden-legacy.json` was only the 0.16 data for the old
  tests and went with them; `legacy-banks.json` stays as migration input.
- **Contingency, not built.** If preparation without JIT is too slow on a device (more than about 3 s for a typical bank after
  the pool-writer patch), fall back to the pragmatic plan's legacy-parse-to-v6 packer (about 200 lines). Do not start the Swift
  port. A plan cache (B9 in the plan) is also not built; build it only if a warm load measures above about 1 s.

## ABI, footprint and the configure rule

`EFFETUNE_DSP_ABI_VERSION` is still 1. New entry points in `abi.h` include host transport, MIDI, sample streaming,
`et_sample_player_preparation_bytes`, offline graph, and a new positive status `ET_NEED_SAMPLE = 1` (only from offline and
SFZ-internal paths). EffectDeck newly uses the preparation query and the stream functions (configure, take requests, publish,
prefetch, readiness); the host transport, MIDI and offline graph entry points are not called.

- **Footprint.** The only valid footprint is `payload bytes + et_sample_player_preparation_bytes(...)`.
  `SamplePlayerPreparation` asks the engine; `SFZPreparationRules` (Foundation) cuts the control prefix (`32 + 4 * u32@48`
  bytes, where the compiled tables end before PCM) and checks the sum against 256 MiB and `UInt32.max`, raising upstream's
  too-large text otherwise. The geometry follows upstream's Android host: bpm 0, the real sample rate, processing channels,
  `maxFrames`. **Footprints are never stored in goldens or on disk; they are always queried**, and they are recomputed on
  every send, because the geometry can change.
- **Channels.** `commitSfzEffects` requires `channels == begin.processingChannels`. The **same** `procCh` goes to the estimate
  and to `BeginInfo.processingChannels`. EffectDeck uses `EffeTuneDSP.routedChannels(of:)` (1 for L / mono, else 2) and
  **reloads the SFZ stage when the routed width, sample rate or `maxFrames` changes** (`EffeTuneDSP.swift`, where it used to be
  marked "redesigned"). Before, the width was a fixed 1.
- **Configure rule.** `et_instance_stream_configure` allocates, and is legal in PREPARING or ACTIVE, so it is a control-side
  call. It is made right after commit **inside `AssetUpload.holdOffAudioThread`** (`ETSFZStream.attach` / `ETSampleStream_Attach`).
  Without it a streamed bank is a runtime failure on the audio thread. The early plan to run the streamer under the bypass
  exclusion was wrong for live playback: the exclusion bypasses the whole chain.
- **After commit** the loader polls `et_instance_asset_state`; ERROR becomes the stage's `.failed` state with upstream's text.
- **Binary size.** Upstream's WASM grew 4,034,935 to 4,905,383 bytes (+870 KB); compiled with `-Os` on x86_64 the changed
  files sum to about +760 KB before linking (SFZ Note Player kernel +342 KB, SoundFont Player 365 KB new, cost bridge 46 KB new).
  Rhythm Analyzer's retrained drum weights are the same size. The arm64 value is not measured (guess: +0.6 to 0.8 MB).
  `stb_vorbis` adds a little more. Compare the real archive size on the Mac.

## Streaming runtime (SF2, SF3, `load_*`, over-budget SFZ)

- `Sources/Shared/ETSampleStream.{c,h}`, hooked into `ETPipeline_Process`. Per instance (up to 4 slots): an SPSC request ring
  (4096), an SPSC ready-page ring, and a pool of 64 pages (4096 x 2 floats, 2 MiB), allocated once at attach.
  `BeforeProcess` publishes **at most 8 pages per block**, round-robin over slots (`ET_STREAM_PUBLISH_PER_BLOCK`, **a guess**:
  lower it if a device shows xruns). `AfterProcess` takes requests in chunks of 256 using the stack only. A generation fence
  drops stale pages.
- For a Note Player, `AfterProcess` also runs upstream's SELECTED_PRESETS forecast (`audio-processor.js:5054-5130`: flags 13 then
  6, windows 1.5 s / 1 s / 0.25 s, refreshed every 0.5 s) so the first page of the selected sound is already resident.
- `ETSFZPageSource` (a utility thread) produces pages: SF2 PCM as `(i16 * 256 + sm24) / 8388608` or `i16 / 32768`; WAV / AIFF via
  `SFZPageDecode` (bit-exact with upstream); FLAC and others via `AVAudioFile`; SF3 via `ETVorbis`. **If the pool is empty it
  waits** (the audio thread may be stopped: bypass, an interruption, background), because the engine does not resend requests.
  **A read it cannot serve is recorded as a failure** (`ETSampleStream_Fail`), not dropped, and the loader unloads the asset.
- A withheld page drops that note with a runtime event; it does not put the instance in ERROR.
- Native tests: `Tests/Native/sample_stream.c`, run as `sample_stream_fake` (order, the N bound, stale generation, **malloc count 0
  on steady state**, counted with `--wrap=malloc` on Linux), `sample_stream_threads` (TSan label) and `sample_stream_engine`
  (real engine with the SF2 host fixture: renders non-silent; missing page drops the note). `sfz_admission.c` checks admission.
- The streaming functions are documented in `abi.h` as CONTROL-only. Calling them between blocks on the render thread is
  single-threaded with `process`, and the malloc test is what backs that. `publish` can allocate once, when an effects bank gets
  its first page (`prepareSfzEffects`); resident pages are published from the control side first, so that never reaches the
  audio thread.

## SoundFont and SFZ on screen

- **SoundFont Library** (`SFZLibraryView`, was SFZ Library). Importing a folder takes **every SFZ and SF2 in it**; a single SF2
  or SF3 file can also be chosen (`.fileImporter` with the extension types). The row's small text is size, format and counts
  in upstream's badge form. Standard controls only.
- **Preset row** (SoundFont Note Player). Built from the existing `ETDisplayChoiceRow` menu. "Default" is -1, then
  `Bank b · p+1. name`; only bank <= 128 and program <= 127, duplicates first-wins (`sfz-instrument.js:397-398,519-539`).
  It is hidden for SFZ banks. `sp0` is not a generic number row (it would show bank * 128 + program) and is re-checked against
  the preset list on every load; it resets to -1 when the SoundFont changes. `ETSFZPresetMenu` builds the list.
- **Missing bank.** A key that points at a bank this device does not have shows "Missing SoundFont" and a red status line
  (upstream 2.17.0's `error.missing`). Banks are not exchanged with a PC.
- **Instrument Details** (D5). A standard `DisclosureGroup` with upstream's rows: Key n, CC n, Output n, Group, Global / Master /
  Region labels, and the image if the bank has one (decoded once per change, not in `body`). Above it, one line for the keyswitch
  held now, "Keyswitch a-b", read from **telemetry frame type 34** (version 1, exactly 32 bytes, 16 x i16, -1 = none, a key
  outside -1...127 drops the whole frame): `ETSFZKeyswitchFrame.parse`. Frames from before the last display change are ignored by
  sequence number. `ETFrameType.sfzScriptMessage = 33` is declared and unread.
- **SF3.** Vendored `stb_vorbis.c` v1.22 **unmodified** (`Sources/Shared/ThirdParty`), MIT or public domain; `Licenses/stb_vorbis.LICENSE`,
  `Tools/gen_licenses.py`, `NOTICE.md` and `Licenses.swift` are regenerated. `ETVorbis.{h,c}` copies and validates the Ogg and
  decodes from the start as far as asked, cropped to the final granule. The prelude's `AudioDecoder.isConfigSupported` reports
  supported; that is the only JS gate (`sf2/asset.js:24-25`), decoding is native. The extension target does not compile
  `ETVorbis`, `ETSampleStream` or `stb_vorbis` (`project.yml` excludes).
- No new keyboard shortcuts, no captions or footers. Strings are upstream's.

## Rhythm Analyzer drum model and Note Spectrogram timbre (upstream, no Swift work)

- **Rhythm Analyzer drums: retrained.** The model is now "Causal CRNN **r4own-vs4**", replacing c6-agc-a1. Same shape (566,669
  parameters, 1,133,338 bytes), same thresholds (0.0 / -0.3 / 0.6 / 2.1 / 0.9), frame version 5 / 2024 bytes unchanged.
  Upstream's IDMT micro F5 at 50 ms went from 0.870 to 0.884. The upstream fixture simply has fewer events (568 to 544
  bytes). Binary size is unchanged. Nothing to change in `RhythmAnalyzerModel`.
- **Note Spectrogram timbre weights: retrained** with extra vocal labels. Same shape (62,547 floats), frame 31 unchanged.
- **To tell the owner.** `drum_weights.provenance.json` still has **no licence field** (unlike `rhythm_d_*.provenance.json`).
  It lists IDMT-SMT-Drums, ENST-Drums and MDB-Drums for threshold calibration and now also a 10% share of
  `owner_supplied_recordings`. This is the same open point as in 2.16.0. `gen_licenses` is unchanged. Whether to raise it
  upstream is the owner's call.

## Tests and goldens

- **`Tools/golden/sfz_golden.mjs` + `sfz_cases.mjs`**: the full case list through the bundle: CC / aftertouch / program conditions,
  triggers, aliases, `set_hdcc`, `offset_mode=percent`, `end=-1`, `md5`, embedded `<sample>`, `<curve>`, `<effect>`, `script=`,
  labels and image, `loop_end_offset`, WAV `smpl`, folder listings with SF2 / SF3; the budget cases are error-only; streamed
  variants with an injected estimator; and **migration cases from 0.16-era containers** (including reduced ones; a former
  `limit-*` import now succeeds as streamed). Output: `Tests/Fixtures/SFZ/sfz-golden.json` and `payloads/*.bin`.
- `sf2_golden.mjs` (the 11 `createSf2Fixture` cases and equality with upstream's `kSf2NativeFixture`, 5,024 bytes),
  `sample_page_golden.mjs`, `vorbis_fixtures.py` (the Ogg fixtures and `vorbis-golden.json`), `stream_table_golden.mjs`.
- `Tools/sfzjs/*.test.mjs`: bundle in a bare `vm` realm (every golden case, pool-writer path equals unpatched path), prelude,
  glue, stream, and build determinism (building twice gives identical bytes).
- **Admission (`Tests/Native/sfz_admission.c`).** Every v6 / v7 / effects golden reaches ACTIVE at exactly `payload + add`;
  `add - 1` is out-of-memory; the 0.16 v2 payload is ERROR; an effects bank whose processing channels differ from the process
  channels fails; the SF2 fixture without configure is a runtime failure and with configure is not.
- Swift (Foundation only, Linux): `EffectAliasTests`, `NoteSpectrogramLocalKeyTests`, `SFZLibraryBackendTests`,
  `SFZLoaderSupportTests`, `SFZMessagesTests`, `SFZPageDecodeTests`, `SFZPoolFillTests`, `SFZSoundFontTests`,
  `SFZStreamTableTests`, `SFZVorbisReaderTests`, `SFZInstrumentDetailsTests`, `Upstream217Tests`.
  `Tests/Unit/SFZScriptHostTests.swift` (the classes under `#if canImport(JavaScriptCore)`: `SFZGoldenThroughJSCTests`, `ETSFZScriptServiceTests`, `ETSFZStreamedServiceTests`) runs **every `sfz-golden.json` case through real JavaScriptCore,
  byte for byte**; it can only run on the macOS CI.
- `project.yml`: Logic target lists the new Foundation-only files and fixtures; the extension excludes `ETSampleStream`,
  `ETVorbis`, `stb_vorbis`; `check_release_binary.py` has the matching role table.

## Compatibility

- Saved chains: the type name and wire name did not change; `sp0` is written like any parameter. The store build
  (v2026.11.03) and a PC on 2.16.0 or earlier report `sp0` as Ignored (harmless).
- Existing banks: the library folder and `index.json` are read as they are; they are repacked at load, so the **first load after
  the update is slower** (a JS context is built and the bank re-prepared). Nothing is deleted.
- A PC on 2.16.0 or earlier gets the old effect name for the Note Player (`ETEffectAliases.wireName`).
- Banks over the old memory budget used to be reduced and now stream instead.

## Not applied

- `SoundFontPlayerPlugin` as a usable effect (MIDI songs, 16-channel playback, real-time MIDI input, mixer frame 35). Hidden on
  purpose; the mixer / MIDI entry points in `abi.h` are not called.
- Upstream desktop features: DSD and MIDI / MusicXML playback, karaoke lyrics, Visualizer MIDI / Event List / lyrics.
- ABI: `et_engine_set_host_transport`, MIDI, offline graph (`et_graph_*_offline`). `et_instance_set_midi_metering` is declared but
  missing from `exports.txt` (WASM-only list; native builds are unaffected). `ScopedDenormalFlush` is x86-only.
- Frame 33 (SFZ script message) is parsed as a type only; no screen shows script messages.
- `PartitionedConvolver::reserve` now does a sizing pass first, so IR / FIR preparation does about twice the pffft setup work on
  the control thread. Output unchanged.

## Not verified

- **Nothing was compiled by Xcode.** Not built: `ETJSHost.swift`, the JSC half of `ETSFZScriptService.swift`,
  `SFZLoader.swift`, `SamplePlayerPreparation.swift`, `ETSFZPageSource.swift` (the `AVAudioFile` reader), `SFZNotePlayerView`,
  `SFZLibraryView`, the `AssetUpload` and `EffeTuneDSP` edits. CI `logic` and `sim-build` have to be the first compile. Likely
  first-build problems: duplicate header names (`engine.h`, `bank.h`) across the DSP sources, the bundle resource, and the
  JavaScriptCore link.
- Snapshot and accessibility tests for `SFZNotePlayerView` may need re-recording (renamed labels, new rows).
- **JIT.** A JSContext in a third-party iOS process should run without JIT (a guess, high confidence). The simulator may JIT, so its
  timings do not count. Measure on the device: preparation time for a typical bank and for one near 256 MiB, and peak memory /
  jetsam while the bank is prepared in background audio. The peak during an import can be 3 to 4 times the limit (container, PCM,
  asset, kernel copy at the same time).
- **By ear.** An existing library bank; Ch switched to L / mono and back to stereo (the stage reloads); an effects bank on a stereo
  route; an SF2 with the Preset menu; a `load_mode` or over-budget bank with no xruns after warm-up; an SF3.
- **DSP workflow.** `gh workflow run DSP --ref feature/effetune-2.17.0` was started on the pushed branch (HEAD `bac9a61`): run
  42216556632. It had not finished when this note was written (jobs `upstream ctest (debug)`, `upstream ctest (asan)`, `fuzz-long` in progress); read the result with `gh run view 42216556632`. Upstream's ctest list grew (the plan counted 21 new targets), so the 60-minute limit of
  `upstream ctest` in `.github/workflows/dsp.yml` is at risk; if it times out, raise `timeout-minutes` or split the matrix.
- The arm64 footprint is unmeasured (see above).

## Verification

Run on 2026-11-06 on Windows / WSL. Nothing on the Mac or the device.

- Linux Logic bundle (`Tests/Linux/run.sh`): **1354 tests, 0 failures, 1 skipped**.
- `python Tools/check_repo.py` ok; `python Tools/check_repo.py --version-guard` ok.
- `python -m pytest Tests/Tools`: 263 passed, 9 skipped.
- `node --test Tools/sfzjs/*.test.mjs Tools/*.test.mjs`: 221 tests, 221 pass.
- `Tests/Native` was not rerun for the documentation unit (no native code changed in it).

## What's New draft (not published)

`Tools/store_notes.txt` and `Tools/beta_notes.txt` hold the text of 2026.11.03, which is already released (`v2026.11.03`), so they
are not edited here. When the next version is cut, the 2.17.0 lines would be:

English

- EffeTune 2.17.0 (DSP 0.17.0): the SFZ Note Player is now the SoundFont Note Player. It plays SF2 and SF3 SoundFonts as well as SFZ, with a Preset menu, Instrument Details and keyswitch display.
- SoundFont Library: import a folder of SFZ and SF2 files, or a single SoundFont.
- Large and streamed instruments (load_mode, over the memory limit, SoundFont) now play from disk.
- Rhythm Analyzer drum detection and Note Spectrogram instrument detection are more accurate.
- Note Spectrogram note names follow the key at each point of the song.

日本語

・EffeTune 2.17.0（DSP 0.17.0）に追従しました。SFZ Note PlayerはSoundFont Note Playerになり、SFZに加えてSF2・SF3のSoundFontも鳴らせます。Presetの選択、Instrument Details、キースイッチの表示に対応しました。
・SoundFont Library：SFZとSF2の入ったフォルダ、またはSoundFont1本を取り込めます。
・大きな音源や、ストリーミングが必要な音源（load_mode、メモリ上限超え、SoundFont）をディスクから再生できるようになりました。
・Rhythm Analyzerのドラム検出とNote Spectrogramの楽器検出の精度が上がりました。
・Note Spectrogramの音名が、曲の途中でも、その場所の調に合わせて表記されます。
