#!/bin/bash
# App Store 用のスクリーンショット。
# 使い方: bash Scripts/shoot_store.sh [Bridge|Live]
#
# Apple は 6.9 インチのぶんがあれば他のサイズへ自動で縮める。
# 念のため 6.9 インチで撮る。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
WHICH="${1:-Bridge}"
OUT="$ROOT/shots-store/$WHICH"

if [ "$WHICH" = "Bridge" ]; then
  SCHEME=EffeTuneLiveBridge
  APPID=ai.nemut.effetune.bridge
  APPNAME="EffeTune Live Bridge.app"
else
  SCHEME=EffeTuneLive
  APPID=ai.nemut.effetune
  APPNAME="EffeTune Live.app"
fi

DEV=$(xcrun simctl list devices available | grep -F "${SIM:-iPhone 18 Pro Max} (" | head -1 \
      | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p')
[ -n "$DEV" ] || { echo "!! シミュレータが無い"; exit 1; }

# 撮る端末以外は落とす。
xcrun simctl list devices | grep Booted | grep -oE "[0-9A-F-]{36}" | while read -r other; do
  if [ "$other" != "$DEV" ]; then xcrun simctl shutdown "$other" >/dev/null 2>&1; fi
done
xcrun simctl boot "$DEV" 2>/dev/null
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1

# 時計と電波を整える。App Store の審査で端末の状態がまちまちだと見栄えが悪い。
xcrun simctl status_bar "$DEV" override --time "9:41" \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 \
  --batteryState charged --batteryLevel 100 >/dev/null 2>&1

xcodegen generate --spec project.yml 2>&1 | tail -1
/usr/bin/xcodebuild -project EffeTuneLive.xcodeproj -scheme "$SCHEME" \
  -configuration Debug -sdk iphonesimulator -arch arm64 \
  CONFIGURATION_BUILD_DIR="$ROOT/out-sim" build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3

APP="$ROOT/out-sim/$APPNAME"
[ -d "$APP" ] || { echo "!! 成果物が無い"; exit 1; }
xcrun simctl uninstall "$DEV" "$APPID" >/dev/null 2>&1
xcrun simctl install "$DEV" "$APP"

mkdir -p "$OUT"
shift || true
if [ "$#" -gt 0 ]; then SEEDS="$*"; else SEEDS="none"; fi
n=0
for seed in $SEEDS; do
  xcrun simctl terminate "$DEV" "$APPID" >/dev/null 2>&1
  if [ "$WHICH" = "Bridge" ]; then
    xcrun simctl launch "$DEV" "$APPID" >/dev/null 2>&1
  else
    xcrun simctl launch "$DEV" "$APPID" -ETSeed "$seed" >/dev/null 2>&1
  fi
  sleep 5
  xcrun simctl io "$DEV" screenshot "$OUT/$seed.png" >/dev/null 2>&1
  n=$((n + 1))
  echo "  $seed"
done
echo "SHOTS: $OUT ($n)"
