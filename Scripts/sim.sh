#!/bin/bash
# シミュレータへ入れて画面を撮る。UI を見るためだけのもの。
#
# 音の経路は動かない。拡張の entitlement は実機でしか効かず、
# 拡張から届く音も無いので、鎖は空のまま画面だけが出る。
# 触って崩れていないかを見るのに使う。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
SIM="${SIM:-iPhone 17 Pro}"
SHOT="${SHOT:-$ROOT/shot.png}"

DEV=$(xcrun simctl list devices available 2>/dev/null \
  | awk -v n="$SIM" '$0 ~ n { match($0, /\(([0-9A-F-]{36})\)/, m); if (m[1] != "") { print m[1]; exit } }')
if [ -z "$DEV" ]; then
  DEV=$(xcrun simctl create "$SIM" "com.apple.CoreSimulator.SimDeviceType.$(echo "$SIM" | tr ' ' '-')" \
        com.apple.CoreSimulator.SimRuntime.iOS-27-0 2>/dev/null)
fi
[ -n "$DEV" ] || { echo "!! シミュレータを用意できない"; exit 1; }
echo "device: $DEV"

echo "--- プロジェクトを作り直す ---"
python3 Tools/gen_catalog.py 2>&1 | tail -2
NS="Vendor/effetune/dsp/plugins/analyzer/note_spectrogram"
rm -rf Generated/note-models && mkdir -p Generated/note-models
for m in learned_model fine_model octave_model; do
  python3 "$NS/embed_models.py" "$NS/$m.json" Generated/note-models --target macho >/dev/null 2>&1
done
xcodegen generate --spec project.yml 2>&1 | tail -2

xcrun simctl boot "$DEV" 2>/dev/null
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1

/usr/bin/xcodebuild -project EffeTuneLive.xcodeproj -scheme EffeTuneLive \
  -configuration Debug -sdk iphonesimulator -arch arm64 \
  CONFIGURATION_BUILD_DIR="$ROOT/out-sim" build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -10

APP="$ROOT/out-sim/EffeTune Live.app"
[ -d "$APP" ] || { echo "!! $APP が無い"; exit 1; }

xcrun simctl install "$DEV" "$APP"
xcrun simctl launch "$DEV" ai.nemut.effetune.player >/dev/null 2>&1
sleep 4
xcrun simctl io "$DEV" screenshot "$SHOT" 2>&1 | tail -1
echo "SHOT: $SHOT"
