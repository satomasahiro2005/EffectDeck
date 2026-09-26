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

## Bass Management

Bass Management (EffeTune 2.11.0) runs only when routed to All, as upstream requires. On
any other Routing the host publishes it disabled and the card offers **Use all output
channels**. A card added from the picker starts on All with every output channel Managed;
presets, share links and saved chains keep their own Routing.

Sub Outputs lists only channels inside the current width. Choosing one makes that channel
LFE and routes every channel in the width to it, so on a two-channel route the sub takes
one of the two main channels. A configuration that does not fit the width shows upstream's
configuration error and the kernel does not apply it. Linear phase is designed on the
device and resent after a route rebuild, a preset apply or a chain load, also for
collapsed cards. Sub output on an interface has not been checked on a device.

## Verification boundary

The native preview-tone test covers a four-channel buffer and verifies that the preview
tone is added only to the input L/R pair. EffeTune's upstream Spatial Mapper native test
also passes (including its multichannel cases). Device routing and `AVAudioEngine`
negotiation must still be verified on iOS with the target USB interface; this Windows
host has no Xcode/iOS runtime.
