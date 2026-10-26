# EffeTune 2.15.0 integration

Branch: `feature/effetune-2.15.0`, based on `origin/main` (`cc4ad34`).
Upstream: tag `dsp-v0.15.0` (`c506bbab`, DSP 0.15.0). App 2.15.0 is tag `v2.15.0` (`45d2f69b`).

Built on Linux (Logic bundle, upstream and Native tests). **The Xcode build and the SwiftUI changes are not
yet proven** (the Mac was offline); see Verification.

## Import

- **Pin: `c506bbab`, not `45d2f69b`.** The two tags are on different commits. `c506bbab` is a child of
  `45d2f69b` and differs only in Python wheel packaging and CI (`tools/repair-dsp-windows-wheel.py`,
  pyproject, BUILD.md, `ci.yml`, two tests). No `dsp/` source and no plugin file differs, and `package.json`
  says 2.15.0 at both. Pinning `45d2f69b` makes `gen_version` write 0.14.0 and `check_repo --version-guard`
  fail (the gitlink must sit on a `dsp-v*` tag).
- Patches: all four apply unchanged (whitespace flags of `setup.sh`). Not regenerated. The engine is
  unchanged except `EMSDK_VERSION`, which is WASM-only.
- Catalog: 112 effects, 719 parameters. Effect presets 170, system presets and licences unchanged.
  `chain/v0.15.0/` added, `CHAIN.md` and the README badge point at 0.15.0.
- Goldens: only `designers-b-golden.json` changes (`upstreamVersion` 2.15.0).
- Upstream `main` is ahead of the tag (`16bd575e`): the Linux Web Audio multichannel fix
  (`getChannelCountForUI`, `remote-control.js` `channelCount`) and CI. EffectDeck does not read
  `channelCount`. Stayed on the tag.

## SFZ Detection

- New param `dt` (enum Classic / Event, default Classic, offset 19, saved). SFZ is now 20 floats, hash
  `0xdfb4bbc5`; `pm` / `pv` stay at 17 / 18. In the catalog `dt` sorts first because upstream's `createUI`
  adds the Detection radio right after the bank row.
- UI: `ETDisplayChoiceRow` "Detection" (Classic (Low Latency) / Event (+140 ms)) above Color, bound to the DSP
  value. It is not `etLocalAudioOnly` (the PC owns the value).
- Threshold (`th`) and Retrigger Drop (`rd`) are disabled while Event is selected, through `ETParamGate`
  (upstream `_syncDetectionControls`). Only the input is disabled; the values are kept.
- Old chains have no `dt` and load as Classic. A string other than Classic / Event loads as Classic (the common
  enum rule of `ETParamCoding.number`; upstream keeps the previous value, which only differs for hand-written text).

## Latency after parameter changes

`et_instance_set_params` only stages the values (`Engine::setInstanceParams` calls `stageParameters`). The
kernel takes them in the next `processSlot`. SFZ's `latencySamples()` reads the applied `params_`, so
`et_instance_latency` right after `setValue` still returns the old value for SFZ `dt` and `tm`, and
`settleAfterParams` never republished. (The saturation family reads the staged values, so it moves at once.)
**The 2.13.0 note saying `settleAfterParams` covers SFZ's `tm` was wrong.**

Checked with a native probe against the patched `c506bbab` (ASan+UBSan, 48 kHz): after a block with Classic the
instance reports 4320 samples; right after `set_params(dt=1)` it still reports 4320; after the next block it
reports 11040 (+6720 samples = 140 ms).

Fix: `ETLatencyWatch` (Foundation-only, `LatencyWatchTests`) remembers a node whose latency did not move
after a value was set, `AudioIO.tick` compares it with `et_instance_latency` (also in the background), and a
change calls `republish`. Entries are kept while audio is not running, dropped after 2 s of running without a
change, and one republish is issued per tick at most. Hooks: one stored property in `EffeTuneDSP`, one call in
`settleAfterParams`, one line in `AudioIO.tick`, the rest in `EffeTuneDSP+LatencyWatch.swift`.
Limit: a stage that is disabled or bypassed is not processed, so its pending value is applied later than the
2 s window; its latency then moves at the next configure that follows the first processed block.

## Note Spectrogram

Lit black keys get an outline (upstream `outlineTint`): white tinted 0.2 toward the key colour, opacity of the
key, width 0.1 of `min(rowHeight, blackDepth)` inset by half, back edge left open. EffectDeck keeps its
note-coloured fill (the fill colour is `band.keyColor(midi:)` rather than upstream's mix by confidence).
`ETNoteRollFrame` rotates like upstream, so the formulas are the same.

## Matrix

2.14.0 reset the routes to the diagonal on any kernel reset (`et_instance_reset`, a temporal reset, reset on
resume) without a new instance. The UI kept showing the user's routes because `onChange(of: node.instance)`
does not fire on a reset. 2.15.0 fixes this in the kernel (routes are parameters, not processing history;
the defaults are member initialisers). Upstream `topology_native_test.cpp` covers it. The re-push on a new
instance stays: a new instance still starts on the diagonal.

## CPU

Event runs its event network inside each SFZ stage's own analysis. EffectDeck still does not link
`et_instance_set_analysis_source`, so every Event stage pays for its own 88-pitch network. Relevant to the
battery issue (#5). Watch the load on the iPhone 16 with Event on.

## Compatibility

- The current store build ignores `dt`: Event links open as Classic there, and a chain text containing `dt`
  reports "Ignored: SFZ Note Player.dt".
- A 2.13.0 PC also ignores `dt` and the 2.14.0 keys. Remote checks (the mismatch line, `dt` round trip) need
  the PC on 2.15.0; the PC here is on 2.13.0 (not updated).

## Not applied

Built-in browser, video playback, ALAC, Visualizer Video / Counter / HDR and the 16x9 preset, MSIX, Electron 45,
MCP 0.14.0, dialog Escape / positioning, locales. Note Spectrogram hover anchor (`at: {x, y}`): EffectDeck's
readout is a fixed row above the graph, not a tooltip at the pointer. Volume half-disc opacity: EffectDeck has no
`_drawVolumeMeters`. The Linux multichannel and CI commits after the tag.
