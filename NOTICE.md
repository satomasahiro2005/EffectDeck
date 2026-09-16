# 同梱しているもの

**このアプリは EffeTune プロジェクトのものではない。**nemut.ai が作った別のアプリで、
EffeTune の DSP を MIT ライセンスのもとで同梱している。本家の作者による承認も支援も
受けていない。このアプリについての問い合わせは nemut.ai へ。EffeTune の
リポジトリへ issue を立てないこと。

公式の iOS 版が出たら、このアプリの配信は終える。

## EffeTune

音の加工は [EffeTune](https://github.com/Frieve-A/effetune) の DSP コア
(`dsp/`) をそのまま使っている。`Vendor/effetune` にサブモジュールとして置いてある。

MIT License / Copyright (c) 2025-2026, Yoshiyuki Kobayashi

EffeTune の `dsp/` は host-neutral な C++20 で、ブラウザや WebAudio の API を
含まない。だから WASM を経由せず iOS 向けに arm64 で直接ビルドできる。

## PFFFT

EffeTune の DSP コアが FFT に使っている。`Vendor/effetune/dsp/vendor/pffft`。

Copyright (c) 2020 Dario Mambro
Copyright (c) 2019 Hayati Ayguen
Copyright (c) 2013 Julien Pommier
Copyright (c) 2004 the University Corporation for Atmospheric Research (UCAR)

全文は `Vendor/effetune/plugins/dsp/NOTICE.txt`。
