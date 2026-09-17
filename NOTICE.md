# What is bundled

**EffectDeck is not part of the EffeTune project.** It is a separate app built by nemut.ai
that bundles EffeTune's DSP core under the MIT license. It is not endorsed by or supported
by the author of EffeTune. Send anything about this app to nemut.ai, and do not open
issues about it on the EffeTune repository.

## EffeTune

The audio processing is EffeTune's DSP core (`dsp/`), used as it is:
[EffeTune](https://github.com/Frieve-A/effetune), included here as the submodule at
`Vendor/effetune`.

MIT License / Copyright (c) 2025-2026, Yoshiyuki Kobayashi

EffeTune's `dsp/` is host-neutral C++20 with no browser or WebAudio API in it, so it
builds for iOS arm64 directly, without going through WASM.

## PFFFT

Used for the FFT inside EffeTune's DSP core. `Vendor/effetune/dsp/vendor/pffft`.

Copyright (c) 2020 Dario Mambro
Copyright (c) 2019 Hayati Ayguen
Copyright (c) 2013 Julien Pommier
Copyright (c) 2004 the University Corporation for Atmospheric Research (UCAR)

Full text in `Vendor/effetune/plugins/dsp/NOTICE.txt`.
