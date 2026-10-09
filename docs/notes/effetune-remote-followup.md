# EffeTune remote control follow-up

**Protocol compatibility done for EffeTune 2.13.0; device verification against an official EffeTune 2.13.0 is pending.** The notes for that update, [effetune-2.13.0.md](effetune-2.13.0.md), say what was compared and what changed. The Origin header and the PC-side chain behaviour are not confirmed yet (step 1 of that note's device checklist); until it passes, `ETFeatures.remoteControl` can be set to `false` to close every entry point.

Background. Upstream [PR #69](https://github.com/Frieve-A/effetune/pull/69), "Add a LAN remote control API with a browser client", was merged on 2026-10-04 and shipped in EffeTune 2.13.0 (the author also changed the final protocol in 5f6a2a8c: `d` in a `set` op now unsets any optional short key). EffectDeck pins v2.13.0, so the Release build opens the client (`ETFeatures.remoteControl` is `true`; returning `false` closes every entry point again).

Checked against the released protocol (docs/remote-v1.md):

- Official hello replies carry `appName`, `app`, `features` (`origin`, `savePreset`, `irSync`, `sync1`) and `effects`. There is no `dsp`, no `build` and no `telemetry` / `overlays`. Capabilities come from `features` and `effects` only; the app version and the pinned `ETUpstreamAppVersion` are compared for display.
- `params` cannot unset a key, so a stage that loses a key between two sends (an IR cleared, a Room EQ measurement removed) is sent as a whole `chain` instead.
- The Options section (Mirror Analyzers) is shown only for a PC that advertises `telemetry`.
