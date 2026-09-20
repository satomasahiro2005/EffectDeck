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

if [ ! -f Vendor/ysfx/include/ysfx.h ]; then
  echo "--- JSFX runtime ---"
  git submodule update --init --recursive Vendor/ysfx || {
    echo "!! Vendor/ysfx を取得できない。git submodule update --init --recursive Vendor/ysfx を確認すること。"
    exit 1
  }
fi

# JSFX compatibility is tied to a reviewed ysfx/WDL revision.  The local
# changes are kept as a normal patch so a fresh clone does not depend on a
# dirty submodule checkout.
YSFX_REV="5c3452fee62583aa3d1b7e877d0c758c4024af89"
YSFX_ACTUAL="$(git -C Vendor/ysfx rev-parse HEAD 2>/dev/null || true)"
if [ -n "$YSFX_ACTUAL" ] && [ "$YSFX_ACTUAL" != "$YSFX_REV" ]; then
  echo "!! Vendor/ysfx is not the reviewed revision $YSFX_REV"
  echo "   run: git submodule update --init --recursive Vendor/ysfx"
  exit 1
fi
if grep -q "g_effectdeck_lice_image_bytes" Vendor/ysfx/sources/ysfx_api_gfx_lice.hpp 2>/dev/null; then
  echo "当たっている: ysfx-effectdeck-ios.diff"
elif git -C Vendor/ysfx apply --check ../../Patches/ysfx-effectdeck-ios.diff 2>/dev/null; then
  git -C Vendor/ysfx apply ../../Patches/ysfx-effectdeck-ios.diff \
    && echo "当てた: ysfx-effectdeck-ios.diff"
elif git -C Vendor/ysfx apply --reverse --check ../../Patches/ysfx-effectdeck-ios.diff 2>/dev/null; then
  echo "当たっている: ysfx-effectdeck-ios.diff"
else
  echo "!! ysfx-effectdeck-ios.diff が当たらない。Vendor/ysfx の版を確かめること"
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
# **まず中身を見る。**判定を git apply だけに任せると、submodule の実体
# （.git/modules）が無い写し（別の機械へコピーした作業ツリーなど）では
# git がリポジトリを開けず、当たっているのに「当たらない」になって止まる。
# 足しているのは関数 1 つなので、それが居るかどうかが当たっているかの答え。
if grep -q et_instance_asset_begin_ptr Vendor/effetune/dsp/core/abi.cpp 2>/dev/null; then
  echo "当たっている: abi-begin-ptr.diff"
elif git -C Vendor/effetune apply --ignore-space-change --check ../../Patches/abi-begin-ptr.diff 2>/dev/null; then
  git -C Vendor/effetune apply --ignore-space-change ../../Patches/abi-begin-ptr.diff && echo "当てた: abi-begin-ptr.diff"
elif git -C Vendor/effetune apply --ignore-space-change --reverse --check ../../Patches/abi-begin-ptr.diff 2>/dev/null; then
  echo "当たっている: abi-begin-ptr.diff"
elif patch -p1 -d Vendor/effetune --forward --dry-run <Patches/abi-begin-ptr.diff >/dev/null 2>&1; then
  # git が開けない写し用の逃げ道。当てる中身は同じ。
  patch -p1 -d Vendor/effetune --forward <Patches/abi-begin-ptr.diff >/dev/null \
    && echo "当てた: abi-begin-ptr.diff (patch)"
else
  echo "!! abi-begin-ptr.diff が当たらない。Vendor/effetune の版を確かめること"
  echo "   当たっていないと、資産を使う 7 種が黙って素通しになる"
  exit 1
fi

# External pipeline nodes let the host run AU/JSFX callbacks at the exact
# position where their descriptor node appears. Keep this as a reversible
# patch because Vendor/effetune is a pinned submodule until the change lands
# upstream.
if grep -q "et_pipeline_set_external_callback" Vendor/effetune/dsp/core/abi.cpp 2>/dev/null; then
  echo "当たっている: effetune-external-node.diff"
elif git -C Vendor/effetune apply --ignore-space-change --ignore-whitespace --check ../../Patches/effetune-external-node.diff 2>/dev/null; then
  git -C Vendor/effetune apply --ignore-space-change --ignore-whitespace ../../Patches/effetune-external-node.diff \
    && echo "当てた: effetune-external-node.diff"
elif git -C Vendor/effetune apply --ignore-space-change --ignore-whitespace --reverse --check ../../Patches/effetune-external-node.diff 2>/dev/null; then
  echo "当たっている: effetune-external-node.diff"
elif patch --batch --dry-run --ignore-whitespace -p1 -d Vendor/effetune < Patches/effetune-external-node.diff >/dev/null 2>&1; then
  patch --batch --ignore-whitespace -p1 -d Vendor/effetune < Patches/effetune-external-node.diff \
    && echo "当てた: effetune-external-node.diff (patch)"
elif patch --batch --dry-run --ignore-whitespace -R -p1 -d Vendor/effetune < Patches/effetune-external-node.diff >/dev/null 2>&1; then
  echo "当たっている: effetune-external-node.diff (patch)"
else
  echo "!! effetune-external-node.diff が当たらない。Vendor/effetune の版を確かめること"
  exit 1
fi

# External nodes participate in the same latency graph as native nodes.  The
# first external-node patch deliberately only added processing; this follow-up
# gives the engine a per-node latency callback so parallel buses get correct
# delay compensation as well (a host-side post sum cannot do that).
if grep -q "et_pipeline_external_latency latency" Vendor/effetune/dsp/core/abi.cpp 2>/dev/null; then
  echo "当たっている: effetune-external-latency.diff"
elif git -C Vendor/effetune apply --ignore-space-change --ignore-whitespace --check ../../Patches/effetune-external-latency.diff 2>/dev/null; then
  git -C Vendor/effetune apply --ignore-space-change --ignore-whitespace ../../Patches/effetune-external-latency.diff \
    && echo "当てた: effetune-external-latency.diff"
elif patch --batch --dry-run --ignore-whitespace -p1 -d Vendor/effetune < Patches/effetune-external-latency.diff >/dev/null 2>&1; then
  patch --batch --ignore-whitespace -p1 -d Vendor/effetune < Patches/effetune-external-latency.diff \
    && echo "当てた: effetune-external-latency.diff (patch)"
else
  echo "!! effetune-external-latency.diff が当たらない。Vendor/effetune の版を確かめること"
  exit 1
fi

# External nodes must terminate their own processing branch.  They also need
# the same selected-channel merge/PDC rules as native nodes when routing from
# one bus into another.  Without the continue below an external node falls
# through to processSlot with a null native instance and crashes the audio
# thread immediately.
if grep -A45 "if (node.external)" Vendor/effetune/dsp/core/engine.cpp 2>/dev/null \
    | grep -q "actual_channel"; then
  echo "当たっている: effetune-external-routing.diff"
elif git -C Vendor/effetune apply --ignore-space-change --ignore-whitespace --check ../../Patches/effetune-external-routing.diff 2>/dev/null; then
  git -C Vendor/effetune apply --ignore-space-change --ignore-whitespace ../../Patches/effetune-external-routing.diff \
    && echo "当てた: effetune-external-routing.diff"
elif patch --batch --dry-run --ignore-whitespace -p1 -d Vendor/effetune < Patches/effetune-external-routing.diff >/dev/null 2>&1; then
  patch --batch --ignore-whitespace -p1 -d Vendor/effetune < Patches/effetune-external-routing.diff \
    && echo "当てた: effetune-external-routing.diff (patch)"
else
  echo "!! effetune-external-routing.diff が当たらない。Vendor/effetune の版を確かめること"
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
