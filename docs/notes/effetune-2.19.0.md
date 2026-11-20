# EffeTune 2.19.0 integration

Branch: `feature/effetune-2.19.0`, based on `feature/effetune-2.18.0` (`56ac4b4`).
The 2.17 / 2.18 work is still part of this branch's ancestry; `main` has not absorbed it.
Upstream: `v2.19.0` = `dsp-v0.19.0`, `0ffa5c709ed1` (2026-11-20). Previous pin: `738a3eab`.

## Imported engine and generated files

- DSP 0.19.0; **117 effects / 742 parameters**, formerly 115 / 730. `chain/v0.19.0/`,
  `CHAIN.md`, README badge and app / DSP version constants agree. The app's own release version is unchanged.
- The three external-node patches and two SFZ bundle patches apply without changes.
- The shared FIR asset kernel now also implements Headphone EQ. The new distortion identification C ABI
  and kernel compile with the existing `project.yml` source globs; no hand-maintained source list is needed.
- SoundFont Player gains `rg`, `rs`, `rx`, `tr`, `mco`: 13 floats, hash `0x25427170`.
  It remains hidden, as in 2.18; no MIDI song player was added.
- SFZ bundle rebuilt from the new pin (58 modules). Context rematerialization keeps the receiver's operation
  revision and external asset identity. GM / GS / XG changes in the shared sampler arrive with upstream's engine.
- System / effect presets and licenses have no content changes. Existing SFZ / SF2 assets and other goldens
  are unchanged; the FIR golden updates its Room EQ source hash. Designer B gains headphone correction cases.

## Headphone EQ

- Available in the picker. Search AutoEQ by model, paste an HTTP(S) measurement URL, or import measurement /
  target CSV or text files. AutoEQ index and curve data are downloaded only on use; attribution links to the project.
- Uses upstream's 241-point, 20 Hz–20 kHz log grid and the `raw` / `target` CSV columns. Empty cells keep their
  column positions. Bad imports preserve the previous curves. A measurement CSV with a target loads both together.
- Minimum / linear phase, taps, latency, correction amount including negative amounts, upper limit, boost cap,
  smoothing, auto headroom and five target-adjust bands. Shelf Q is capped at 2.
- The native Room EQ designer now follows upstream's signed correction and peak-gain limit. Three new golden
  cases compare positive, zero and negative correction with headroom and additional EQ against upstream.
- Curves and settings use upstream's `mr` / `mt`, `mn` / `tn` and other keys in presets, chain text, undo and
  remote edits. Arrays stay JSON arrays on the wire. A processing-rate change rebuilds the coefficients even if
  the card is collapsed. The graph shows the measured deviation and the correction, including applied headroom.
- CSV rounding at an exact half-tenth dB can differ by 0.1 dB between V8 and libm. Import comparison allows that
  one storage quantum; filter synthesis is compared with the existing FIR numerical tolerances.

## Distortion Correction

- Available in the picker. Imports the JSON exported by EffeTune's Acoustic Measurement, including its encoded
  `speakerModel`. The iPhone does not perform the new acoustic measurement / identification or re-check workflow.
- Saves the playback part of the model under `Documents/DistortionCorrection/`; the chain carries the upstream
  measurement reference and name. Re-importing the same measurement replaces its local model. Factory reset
  clears the files. Like upstream's chain format, a shared chain does not embed its measurement: import the
  measurement separately on the receiving device. These files are not in the existing preset-only backup format.
- Short / Long, Reduce / Add, amplifier volume change, and Auto / On / Off for even and odd correction per channel.
  Imports the last checked amplifier change when present. Playback uses the checked Auto decisions until overridden.
- Packs the exact 16 × 1247-float upstream asset, including the odd weights and bounds. Invalid lengths, non-finite
  weights, weights at or outside ±1000, and non-positive bounds are rejected before staging.
- `_scf` / `_scc` are derived from the physical channel selection every time parameters are pushed, including
  pair-to-pair routing changes. They are runtime-only and do not appear as controls or in presets / chain vocabulary.
- Output changes, preset load, reset and undo reconnect the asset without needing its card to be open. A missing
  measurement is reported and clears the old correction. Pending work checks instance lifetime and engine generation.
- Displays the upstream overload indication for five seconds. Rates below 44.1 kHz report the kernel's bypass.
- No measurement diagnosis / sweep graphs, automatic fresh-measurement adoption or re-measure buttons were ported.

## 15Band PEQ

- Master Gain is editable, included in the response curve and Invert Gains, and reads AutoEQ's `Preamp:` on import.
- Follow Volume weights each companion's Master Gain once in dB. A dormant companion has 0 dB master gain,
  so it cannot double the overall preamp. Older chains without `mg` retain the default 0 dB.

## Verification

Windows / WSL, 2026-11-20:

- Python tool tests: 273, 0 failures, 9 platform-dependent skips.
- Node tool / SFZ bundle tests: 221, 0 failures.
- Linux Swift Logic suite: 1364 tests, 0 failures, 1 platform-dependent skip (before the final malformed-model test).
- Final import / PEQ subset after that test: 21 tests, 0 failures.
- Native host tests with the actual pinned, patched engine: 179, 0 failures.
- Upstream Distortion Correction kernel tests, linked to that engine: passed.
- New portable import / asset goldens: 6 headphone imports, 5 speaker settings / output-width combinations.
  Speaker payloads match upstream byte for byte.
- Generated files regenerated from the clean pin; repository version / chain consistency checks pass.
- Whitespace check passes outside the generated SFZ bundle; its embedded WASM string contains significant trailing
  whitespace and is kept byte-for-byte as generated.

**Not built in Xcode or run on an iPhone / iPad.** SwiftUI changes have only been syntax checked. Device checks still
needed: AutoEQ search and file import at phone / accessibility sizes; correction after output-rate changes while
collapsed; undo / reset while a design is pending; speaker-model playback with the measured speakers and amplifier
settings, channel routing, mode / length changes, overload indication and latency compensation.
