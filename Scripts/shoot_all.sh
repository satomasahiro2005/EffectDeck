#!/bin/bash
# 全エフェクトを 1 つずつシミュレータで撮る。
# 使い方: bash Scripts/shoot_all.sh [型名...]（省略すると全部）
#
# 撮ったものは shots-all/<型名>.png。
# **iPad で撮るが、アプリ側が iPhone の幅に絞る。**
# 高さは iPad が要る（長いカードが iPhone だと切れる）が、
# 幅まで iPad になると実機の見え方にならない。
# 音は来ないが画面は同じものが出る。図は無音ぶんが出る。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
OUT="$ROOT/shots-all"
APPID=ai.nemut.effetune

DEV=$(xcrun simctl list devices available | grep -F "${SIM:-iPad Pro 13-inch (M5)} (" | head -1 \
      | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p')
[ -n "$DEV" ] || { echo "!! シミュレータが無い"; exit 1; }
# 撮る端末以外は落とす。前の回の取り残しが並ぶと重いし紛らわしい。
xcrun simctl list devices | grep Booted | grep -oE "[0-9A-F-]{36}" | while read -r other; do
  if [ "$other" != "$DEV" ]; then xcrun simctl shutdown "$other" >/dev/null 2>&1; fi
done
xcrun simctl boot "$DEV" 2>/dev/null
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  python3 Tools/gen_catalog.py 2>&1 | tail -1
  python3 Tools/gen_presets.py 2>&1 | tail -1
  python3 Tools/gen_licenses.py 2>&1 | tail -1
  NS="Vendor/effetune/dsp/plugins/analyzer/note_spectrogram"
  rm -rf Generated/note-models && mkdir -p Generated/note-models
  for m in learned_model fine_model octave_model; do
    python3 "$NS/embed_models.py" "$NS/$m.json" Generated/note-models --target macho >/dev/null 2>&1
  done
  python3 Tools/gen_version.py 2>&1 | tail -1
  xcodegen generate --spec project.yml 2>&1 | tail -1
  /usr/bin/xcodebuild -project EffeTuneLive.xcodeproj -scheme EffeTuneLive \
    -configuration Debug -sdk iphonesimulator -arch arm64 \
    CONFIGURATION_BUILD_DIR="$ROOT/out-sim" build 2>&1 \
    | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -5
fi

APP="$ROOT/out-sim/EffeTune Live.app"
[ -d "$APP" ] || { echo "!! 成果物が無い"; exit 1; }
xcrun simctl uninstall "$DEV" "$APPID" >/dev/null 2>&1
xcrun simctl install "$DEV" "$APP"

if [ "$#" -gt 0 ]; then
  TYPES="$*"
else
  # カタログから型名を全部取る。
  TYPES=$(sed -n 's/^      type: "\([A-Za-z0-9_]*\)",$/\1/p' \
          Sources/EffeTuneLive/Generated/EffectCatalog.swift)
fi

mkdir -p "$OUT"
n=0
for t in $TYPES; do
  xcrun simctl terminate "$DEV" "$APPID" >/dev/null 2>&1
  xcrun simctl launch "$DEV" "$APPID" -ETSeed "$t" >/dev/null 2>&1
  sleep 4
  xcrun simctl io "$DEV" screenshot "$OUT/$t.png" >/dev/null 2>&1
  n=$((n + 1))
  echo "  $t"
done
echo "SHOTS: $OUT ($n)"
