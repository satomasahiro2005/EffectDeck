# What is bundled

**EffectDeck is not part of the EffeTune project.** It is a separate app built by nemut.ai
that bundles EffeTune's DSP core under the MIT license. It is not endorsed by or supported
by the author of EffeTune. Send anything about this app to nemut.ai, and do not open
issues about it on the EffeTune repository.

The app shows the license texts in Settings → Licenses. `Tools/gen_licenses.py` reads them
from the files named here.

## EffeTune

The audio processing is EffeTune's DSP core (`dsp/`):
[EffeTune](https://github.com/Frieve-A/effetune), included here as the submodule at
`Vendor/effetune`.

MIT License / Copyright (c) 2025-2026, Yoshiyuki Kobayashi

It is used with small patches that connect it to the app. `Scripts/setup.sh` applies
`Patches/abi-begin-ptr.diff` and `Patches/effetune-external-*.diff` to `dsp/core` before
each build; the patches are the complete list of changes.

EffeTune's `dsp/` is host-neutral C++20 with no browser or WebAudio API in it, so it
builds for iOS arm64 directly, without going through WASM.

## PFFFT

Used for the FFT inside EffeTune's DSP core. `Vendor/effetune/dsp/vendor/pffft`.

Copyright (c) 2020 Dario Mambro
Copyright (c) 2019 Hayati Ayguen
Copyright (c) 2013 Julien Pommier
Copyright (c) 2004 the University Corporation for Atmospheric Research (UCAR)

BSD-style license. Full text in `Vendor/effetune/dsp/vendor/pffft/LICENSE.txt` and
`Vendor/effetune/plugins/dsp/NOTICE.txt`.

## ysfx

The JSFX host: [JoepVanlier/ysfx](https://github.com/JoepVanlier/ysfx), included as the
submodule at `Vendor/ysfx`, pinned to `5c3452fe`.

Copyright 2021 Jean Pierre Cimalando; later changes by Joep Vanlier and contributors

Apache License 2.0. Full text in `Vendor/ysfx/LICENSE`.

**Modified.** `Scripts/setup.sh` applies `Patches/ysfx-effectdeck-ios.diff` to ysfx and to
two WDL files under it. The patch is the complete list of changes; its header names the
upstream WDL fixes it carries.

## WDL (EEL2, LICE, FFT)

From Cockos' WDL, as vendored by ysfx at `Vendor/ysfx/thirdparty/WDL`. EffectDeck compiles
the EEL2 interpreter (portable, no JIT), LICE (drawing for `@gfx`) and `fft.c`.

Copyright (C) 2005 and later Cockos Incorporated. Portions copyright other contributors,
see each source file. `fft.c` is based on DJBFFT, Copyright 1999 D. J. Bernstein.

zlib license. Full text in `Vendor/ysfx/thirdparty/WDL/LICENSE.txt`. Altered by
`Patches/ysfx-effectdeck-ios.diff` (the patch lists every file, among them `eel2/nseel-compiler.c`,
`eel2/ns-eel.h` and `lice/lice.cpp`). `eel2/glue_port_vm.h` is not from WDL: EffectDeck added it to
run WDL's portable bytecode in other ways (the bytecode itself is unchanged).

## DPF Base64

ysfx compiles `Vendor/ysfx/sources/base64/Base64.hpp`, taken from the DISTRHO Plugin
Framework (DPF). The license is in the file's header. `Licenses/dpf-base64.LICENSE` is a
copy of it, which `Tools/gen_licenses.py` reads and checks against the header.

Copyright (C) 2012-2021 Filipe Coelho
Copyright (C) 2022 Jean Pierre Cimalando

Permission to use, copy, modify, and/or distribute this software for any purpose with or
without fee is hereby granted, provided that the above copyright notice and this
permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO
THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT
SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR
ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE
USE OR PERFORMANCE OF THIS SOFTWARE.

The same file carries base64 code by René Nyffenegger:

Copyright (C) 2004-2008 René Nyffenegger

This source code is provided 'as-is', without any express or implied warranty. In no
event will the author be held liable for any damages arising from the use of this
software.

Permission is granted to anyone to use this software for any purpose, including
commercial applications, and to alter it and redistribute it freely, subject to the
following restrictions:

1. The origin of this source code must not be misrepresented; you must not claim that you
   wrote the original source code. If you use this source code in a product, an
   acknowledgment in the product documentation would be appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be misrepresented
   as being the original source code.
3. This notice may not be removed or altered from any source distribution.

## fdlibm

EffeTune's Rhythm Analyzer (`Vendor/effetune/dsp/plugins/analyzer/rhythm_analyzer/g2_math.h`)
carries `atan` and `atan2` derived from fdlibm 5.3 (`s_atan.c`, `e_atan2.c`). The notice is
in the file's header. `Licenses/fdlibm.LICENSE` is a copy of it, which
`Tools/gen_licenses.py` reads and checks against the header.

Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.

Developed at SunSoft, a Sun Microsystems, Inc. business.
Permission to use, copy, modify, and distribute this
software is freely granted, provided that this notice
is preserved.
