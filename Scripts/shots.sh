#!/bin/bash
# シミュレータで画面を何枚か撮る。UI を見るためだけのもの。
#
# 音の経路は動かない（拡張の entitlement は実機でしか効かない）。
# 鎖は ETScreenshotSeed が仕込むので、エフェクトの画面は見られる。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
SIM="${SIM:-iPhone 17 Pro}"
OUT="$ROOT/shots"

DEV=$(xcrun simctl list devices available 2>/dev/null \
  | grep -F "$SIM (" | head -1 | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p')
[ -n "$DEV" ] || { echo "!! シミュレータが無い"; exit 1; }
echo "device: $DEV"

xcrun simctl boot "$DEV" 2>/dev/null
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1

# 画面でも見たいときは SHOW=1。Simulator.app を開くだけで、撮影とは別。
[ "${SHOW:-0}" = "1" ] && open -a Simulator --args -CurrentDeviceUDID "$DEV" 2>/dev/null

python3 Tools/gen_catalog.py 2>&1 | tail -1
python3 Tools/gen_presets.py 2>&1 | tail -1
python3 Tools/gen_licenses.py 2>&1 | tail -1
NS="Vendor/effetune/dsp/plugins/analyzer/note_spectrogram"
rm -rf Generated/note-models && mkdir -p Generated/note-models
for m in learned_model fine_model octave_model; do
  python3 "$NS/embed_models.py" "$NS/$m.json" Generated/note-models --target macho >/dev/null 2>&1
done
xcodegen generate --spec project.yml 2>&1 | tail -1

/usr/bin/xcodebuild -project EffeTuneLive.xcodeproj -scheme EffeTuneLive \
  -configuration Debug -sdk iphonesimulator -arch arm64 \
  CONFIGURATION_BUILD_DIR="$ROOT/out-sim" build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -8

APP="$ROOT/out-sim/EffeTune Live.app"
[ -d "$APP" ] || { echo "!! 成果物が無い"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
xcrun simctl uninstall "$DEV" ai.nemut.effetune >/dev/null 2>&1
xcrun simctl install "$DEV" "$APP"

# ETScreenshotSeed に何を仕込むかを渡す。
shoot() {
  local name="$1"; shift
  xcrun simctl terminate "$DEV" ai.nemut.effetune >/dev/null 2>&1
  xcrun simctl launch "$DEV" ai.nemut.effetune "$@" >/dev/null 2>&1
  sleep 10
  xcrun simctl io "$DEV" screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "  $name"
}

echo "--- 撮る ---"
shoot 01-empty      -ETSeed none
shoot 02-peq        -ETSeed peq
shoot 03-compressor -ETSeed compressor
shoot 04-saturation -ETSeed saturation
shoot 05-meter      -ETSeed meter
shoot 06-spectrum   -ETSeed spectrum
shoot 07-chain      -ETSeed chain
echo "SHOTS: $OUT"
