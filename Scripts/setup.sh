#!/bin/bash
# 生成物を作って EffeTuneLive.xcodeproj を組む。
#
#   bash Scripts/setup.sh
#   open EffeTuneLive.xcodeproj
#
# .xcodeproj は追跡していない（project.yml が正）。Xcode で開く前と、
# Vendor/effetune を進めたあとに叩く。Scripts/build.sh もこれを呼ぶ。
set -u
export PATH="/opt/homebrew/bin:$PATH"   # xcodegen と、3.10 以降の python3
cd "$(dirname "$0")/.." || exit 1

if [ ! -d Vendor/effetune/dsp ]; then
  echo "!! Vendor/effetune が無い。git submodule update --init --depth 1 を先に。"
  exit 1
fi

# **上流のパッチを当てる。**
#
# et_instance_asset_begin は staging の番地を uint32 へ切り落とす。WASM では
# 足りるが arm64 では上位 32bit が落ちる。Patches/abi-begin-ptr.diff が
# et_instance_asset_begin_ptr を足していて、AssetUpload.swift の beginPointer が
# dlsym で拾う。
#
# **当てないと黙って壊れる。**資産を使う 7 種（IR Reverb と designer 6 種）が
# 落ちも警告もせずに素通しになる。clone したままの人の手元でそうなっていた。
#
# 既に当たっていれば --check が落ちるので、そのときは何もしない（二度当てない）。
echo "--- 上流のパッチ ---"
if git -C Vendor/effetune apply --ignore-space-change --check ../../Patches/abi-begin-ptr.diff 2>/dev/null; then
  git -C Vendor/effetune apply --ignore-space-change ../../Patches/abi-begin-ptr.diff && echo "当てた: abi-begin-ptr.diff"
elif git -C Vendor/effetune apply --ignore-space-change --reverse --check ../../Patches/abi-begin-ptr.diff 2>/dev/null; then
  echo "当たっている: abi-begin-ptr.diff"
else
  echo "!! abi-begin-ptr.diff が当たらない。Vendor/effetune の版を確かめること"
  echo "   当たっていないと、資産を使う 7 種が黙って素通しになる"
  exit 1
fi

echo "--- エフェクトのカタログを作る ---"
python3 Tools/gen_catalog.py 2>&1 | tail -5
python3 Tools/gen_presets.py 2>&1 | tail -1
# カードごとの出荷時プリセット。**node が要る**（Tube Simulator のグループだけ
# 静的な表ではなく組み立てなので、評価しないと取れない）。無ければ飛ばして、
# 追跡してある Generated/EffectPresets.swift をそのまま使う。
python3 Tools/gen_effect_presets.py 2>&1 | tail -1
python3 Tools/gen_licenses.py 2>&1 | tail -1

echo "--- Note Spectrogram のモデルを埋め込む ---"
# upstream の models.cmake と同じことをする。
# kernel.cpp が読む *.generated.h と、中身を持つアセンブリを吐く。
NS="Vendor/effetune/dsp/plugins/analyzer/note_spectrogram"
rm -rf Generated/note-models && mkdir -p Generated/note-models
for m in learned_model fine_model octave_model; do
  python3 "$NS/embed_models.py" "$NS/$m.json" Generated/note-models --target macho 2>&1 | tail -2
done
ls Generated/note-models

echo "--- プロジェクトを作る ---"
python3 Tools/gen_version.py 2>&1 | tail -1
xcodegen generate --spec project.yml 2>&1 | tail -5
