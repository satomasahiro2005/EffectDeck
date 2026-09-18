# Multichannel audio-interface output

Branch: `codex/multichannel-output`, based on the EffeTune 2.10.0 integration.

## Behavior

- The Media Device Extension link remains stereo. The app places that L/R signal in
  channels 1–2 and starts the remaining output channels at silence.
- After activating `AVAudioSession`, the app requests the current route's maximum output
  width and uses the actual `outputNumberOfChannels`, capped at EffeTune DSP's 16-channel
  limit.
- The DSP engine, planar render buffers, oversampling resampler and `AVAudioSourceNode`
  are prepared with the same output width.
- A stable sample-rate or channel-count change rebuilds the audio path. This covers
  connecting and disconnecting a USB audio interface while the app is running.
- Settings diagnostics show the width currently used by the DSP/output path.

## Routing

Existing effects retain their saved Routing setting. `Stereo` processes channels 1–2;
`All` processes the full hardware width. Spatial Mapper shows a **Use all output
channels** action when it is still routed to Stereo, because outputs 3–16 cannot be
produced until that effect is routed to All.

FIR Crossover also follows the selected routing width. It becomes available with an even
All-channel width from 4 through 16, and its designed assets are reattached after an audio
route rebuild even when its card is collapsed.

## Verification boundary

The native preview-tone test covers a four-channel buffer and verifies that the preview
tone is added only to the input L/R pair. EffeTune's upstream Spatial Mapper native test
also passes (including its multichannel cases). Device routing and `AVAudioEngine`
negotiation must still be verified on iOS with the target USB interface; this Windows
host has no Xcode/iOS runtime.
