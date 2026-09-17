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
OUT="$ROOT/shots-store"
APPID=ai.nemut.effetune
APPNAME="EffeTune Live.app"

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

bash Scripts/setup.sh 2>&1 | tail -1
# 拡張を外した仕様で建てる。MediaDevice.framework はシミュレータに無い。
python3 Tools/gen_sim_spec.py 2>&1 | tail -1
xcodegen generate --spec project-sim.yml 2>&1 | tail -1
rm -rf "$ROOT/out-sim"
/usr/bin/xcodebuild -project EffeTuneLiveSim.xcodeproj -scheme EffeTuneLive \
  -configuration Debug -sdk iphonesimulator -arch arm64 \
  CONFIGURATION_BUILD_DIR="$ROOT/out-sim" build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -3

APP="$ROOT/out-sim/$APPNAME"
[ -d "$APP" ] || { echo "!! 成果物が無い"; exit 1; }
xcrun simctl uninstall "$DEV" "$APPID" >/dev/null 2>&1
xcrun simctl install "$DEV" "$APP"

mkdir -p "$OUT"
if [ "$#" -gt 0 ]; then SEEDS="$*"; else SEEDS="none"; fi
n=0
for spec in $SEEDS; do
  # `鎖:シート` と書くと、その 1 枚だけシートを出して撮る。
  # 建て直しは 1 度で済ませたいので、SHEET を環境から渡す形と併用できる。
  seed="${spec%%:*}"
  sheet="${spec#*:}"
  [ "$sheet" = "$spec" ] && sheet="${SHEET:-}"
  name=$(printf '%s' "$spec" | tr ':' '-')
  xcrun simctl terminate "$DEV" "$APPID" >/dev/null 2>&1
  # COLLAPSED=1 で畳んだ状態。図だけ残ってつまみが消えるので、Analyzer の鎖はこちら。
  # 作り物の音を流す。メーターも図も止まったままだと店頭で意味が無い。
  # 幅。既定の 0 は絞らない。**iPad で撮るときは WIDTH=440 を渡すこと。**
  # 実機の iPad は ETLayout が 440pt で止めるので、絞らずに撮ると出荷物と違う絵になる。
  if [ -n "$sheet" ]; then
    xcrun simctl launch "$DEV" "$APPID" -ETSeed "$seed" -ETSheet "$sheet" \
                        -ETWidth "${WIDTH:-0}" -ETCollapsed "${COLLAPSED:-0}" -ETMock 1 >/dev/null 2>&1
  else
    xcrun simctl launch "$DEV" "$APPID" -ETSeed "$seed" -ETWidth "${WIDTH:-0}" -ETCollapsed "${COLLAPSED:-0}" -ETMock 1 >/dev/null 2>&1
  fi
  sleep "${SLEEP:-5}"
  xcrun simctl io "$DEV" screenshot "$OUT/$name.png" >/dev/null 2>&1
  n=$((n + 1))
  echo "  $name"
done
# 撮り終わったら落とす。モックの音が鳴り続けるので。
xcrun simctl terminate "$DEV" "$APPID" >/dev/null 2>&1
xcrun simctl shutdown "$DEV" >/dev/null 2>&1
echo "SHOTS: $OUT ($n)"
