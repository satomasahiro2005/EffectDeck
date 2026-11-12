# EffeTune 2.18.0 integration

Branch: `feature/effetune-2.18.0`, on top of `feature/effetune-2.17.0` (`baa4a9e`; 2.17.0 is not on `main` yet).
Upstream: tag `v2.18.0` = `dsp-v0.18.0` (`738a3eab`, DSP 0.18.0). Previous pin: `5ffca1b3` (`dsp-v0.17.0`).

2.18.0 is small for EffectDeck. Most of upstream's release is desktop work (Live Audio between EffeTune apps, ReplayGain,
Web MIDI in the built-in browser, system-audio capture on Windows, SoundFont Player's mixer and live MIDI input). What reaches
this app is the new engine, two marker effects that stay hidden, and three small follow-ups in the SFZ streaming path.

Built and tested on Windows / WSL (Logic bundle on Linux, Native, Python, node). **Nothing was built in Xcode and nothing ran
on a device.**

## Import

- Pin `738a3eab`. Catalog: **115 effects, 730 parameters** (was 113 / 726). `chain/v0.18.0/` added, `CHAIN.md` and the README
  badge point at 0.18.0.
- `abi.h` and `dsp/core` did not change. The three `effetune-external-*` patches and `effetune-js-sfz-pool-writer` apply as
  they are. `effetune-js-sfz-stream-table` was re-based (upstream added `let sf2Image = null;` right below the hunk); its
  content is the same.
- System presets (28), effect presets (170 / 30 effects) and licences (8) are unchanged.
- Goldens: only `designers-b-golden.json` changes (`upstreamVersion` 2.18.0). Every SFZ / SF2 golden and payload is
  byte-identical, so the packed output for the existing cases did not move.
- The SFZ bundle (`Sources/EffeTuneLive/Resources/SFZ/effetune-sfz.js`) is rebuilt from the new pin: still 58 modules, no new
  import. What changed inside is upstream's (see "SFZ / SoundFont" below).
- Upstream's WASM shrank a little (4,905,383 to 4,868,256 bytes), so the binary should not grow. Not measured on arm64.

## New effects, both hidden

**Live Audio Receive** (`NetworkReceivePlugin`) and **Live Audio Send** (`NetworkSendPlugin`), category Control, no
parameters. They mark the position in a chain where a live stream from another EffeTune enters, or where the sound is sent
to upstream's Network Output. The kernels do nothing (`process` is empty); all of the behaviour is in upstream's host
(`audio-processor.js`, `network-live-pcm.js`), which EffectDeck does not have.

- In the catalog (the count and hashes must match the kernel; a chain from a PC that names them must still load), but
  **hidden from the picker** (`EffectPickerView.hiddenTypes`) and marked "Not for chains" in the chain vocabulary
  (`Tools/gen_catalog.py` `CHAIN_UNSUPPORTED`).
- In a chain they pass audio through. Upstream skips the effects before an active Receive marker; with no session that never
  happens here, so pass-through is the right behaviour.
- Tests: `Tests/Unit/Upstream218Tests.swift`, `Tests/Tools/test_picker_hidden.py`, `Tests/Tools/test_gen_catalog.py`.

## SoundFont Player: still hidden, not followed

Owner's call for this release: SoundFont Player (the MIDI song player) is not what EffectDeck is for, so it is **not
followed** beyond what the catalog needs.

- It gained four parameters (`af` Automatic Fallback, `pm` / `pc` keyboard preview, `sc` SF2 Compatibility; hash
  `0xf271de51`, 8 floats) and Max Voices now defaults to 256. The generated catalog carries them so a PC's chain still
  loads and `set_params` is accepted. Nothing else was done: no rows, no `RUNTIME_ONLY` entry for `pm` / `pc`, no mixer, no
  live MIDI. It stays in `hiddenTypes` and `Automation.excludedTypes`.
- The existing `DEFAULT_OVERRIDES` entry (Interpolation = FIR32) is kept; upstream's JS still starts at 1.

## SFZ / SoundFont (the Note Player, which EffectDeck does show)

Upstream's `js/sfz` and `js/sf2` run as they are inside JavaScriptCore, so these arrive with the bundle:

- SF2 zones no synthesizer can sound (ROM samples, zero-rate samples, offsets past the sample) are **dropped** instead of
  failing the whole bank; a loop that is still empty after clipping plays unlooped; a sample type without channel flags is
  mono. More distributed SF2 files load.
- Limits raised: samples per bank 10,000 to 65,536, SF2 zones 65,536 to 262,144, SF2 modulation routes 1,048,576 to 4,194,304.
- Packing is faster for big banks (rows are filled once; the SF2 image is copied instead of repacked on a context change).

Native follow-ups:

- `ETSFZStreamTable.maxSamples` 10000 to **65536** (upstream `SFZ_MAX_SAMPLES`, `SamplePageCache::kMaxSamples`). Without it the
  stream table refused banks the kernel now accepts.
- **Forecast keeps advancing while pages are owed** (`ETSampleStream_AfterProcess`). Upstream's poll used to skip the forecast
  when the take returned requests; now it takes, advances, and takes again, because on slow storage the queue never drains and
  a stalled forecast leaves every voice on single-page reads. EffectDeck takes requests every block, so "the pages of the
  previous poll" is counted as the requests taken up to the previous forecast (`pollMark`): the next forecast runs once those
  are settled, even if new requests arrived in between. Before, any outstanding request blocked it.
  `fake_forecast_waits_for_outstanding_requests` is rewritten for the new rule.
- Refill threshold for the known-MIDI scope is half the window (was 0.5 s). The Note Player never uses that scope; changed
  only to stay a copy of upstream.

Kernel-only changes in the SFZ engine (`engine.h`, `sample_cache.h`, `sf2_profile.h`, CC start-controller masks) need
nothing from the host.

## Other upstream DSP changes (no Swift work)

- **Hum Remover**: Auto now also watches the other mains nominal (50 / 60 Hz) and jumps to it when its fundamental stays 6 dB
  stronger.
- **Room EQ, FIR Crossover, 5Band FIR PEQ, Group Delay EQ / PEQ, Crosstalk Cancellation**: after a stream reset an active
  asset starts wet instead of fading in from dry.
- Rhythm Analyzer and Tonal Balance EQ share one `portable_math.h` (`dsp/include/effetune/dsp/`); output unchanged.
- Upstream UI changes to Spectrum Analyzer, Stereo Meter and 5Band Dynamic EQ are redraw-skipping and caching only. The
  pictures are the same, so the Swift views are untouched.

## Not applied

- Live Audio (Network Output, send / receive sessions), ReplayGain, Web MIDI, system-audio capture, MIDI file output,
  preset-dialog search: desktop host features.
- SoundFont Player beyond the catalog (see above).
- Remote: no protocol change in 2.18.0 (the last upstream commit only touches a test).

## Not verified

- **Nothing was compiled by Xcode.** The Swift edits are two constants (`hiddenTypes`, `maxSamples`); `ETSampleStream.c` is
  covered by the native tests on Linux. The macOS CI is the first Apple compile.
- By ear on a device: a streamed bank (SF2, or a `load_mode` SFZ) while many voices start at once, to hear that the forecast
  change did not add dropouts. `ET_STREAM_PUBLISH_PER_BLOCK` is unchanged.
- An SF2 that 2.17.0 refused with "Invalid sample geometry" or "requires external ROM samples" should now load.
