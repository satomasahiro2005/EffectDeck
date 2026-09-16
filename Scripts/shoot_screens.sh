#!/bin/bash
# エフェクトのカード以外の画面を撮る。
# 使い方: bash Scripts/shoot_screens.sh
#
# 撮ったものは shots-screens/<名前>.png。
# **iPhone で撮り、幅は絞らない。** 絞ると端末の幅との差が左右の余白に見えて
# 崩れと区別できなくなる。カードが長くて切れるのは shoot_all.sh の話で、
# こちらは画面の作りを見るためのもの。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
OUT="$ROOT/shots-screens"
APPID=ai.nemut.effetune

DEV=$(xcrun simctl list devices available | grep -F "${SIM:-iPhone 18 Pro} (" | head -1 \
      | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p')
[ -n "$DEV" ] || { echo "!! シミュレータが無い"; exit 1; }
xcrun simctl list devices | grep Booted | grep -oE "[0-9A-F-]{36}" | while read -r other; do
  if [ "$other" != "$DEV" ]; then xcrun simctl shutdown "$other" >/dev/null 2>&1; fi
done
xcrun simctl boot "$DEV" 2>/dev/null
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  bash Scripts/setup.sh 2>&1 | tail -1
  # 拡張を外した仕様で建てる。MediaDevice.framework はシミュレータに無いので、
  # 拡張を含むスキームは Unable to resolve module dependency で必ず落ちる。
  # 画面を撮るのに拡張は要らない（音が来ないだけで画面は同じものが出る）。
  python3 Tools/gen_sim_spec.py 2>&1 | tail -1
  xcodegen generate --spec project-sim.yml 2>&1 | tail -1
  /usr/bin/xcodebuild -project EffeTuneLiveSim.xcodeproj -scheme EffeTuneLive \
    -configuration Debug -sdk iphonesimulator -arch arm64 \
    CONFIGURATION_BUILD_DIR="$ROOT/out-sim" build 2>&1 \
    | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -5
fi

APP="$ROOT/out-sim/EffeTune Live.app"
[ -d "$APP" ] || { echo "!! 成果物が無い"; exit 1; }
xcrun simctl uninstall "$DEV" "$APPID" >/dev/null 2>&1
xcrun simctl install "$DEV" "$APP"

mkdir -p "$OUT"

# 名前 / 鎖 / 出すシート
#   鎖が none だと空の画面、chain だと 4 本並んだ画面になる。
shoot() {
  local name="$1" seed="$2" sheet="${3:-}"
  xcrun simctl terminate "$DEV" "$APPID" >/dev/null 2>&1
  # -ETWidth 0 で幅の絞りを外す。iPhone で撮るので端末そのままが正しい。
  if [ -n "$sheet" ]; then
    xcrun simctl launch "$DEV" "$APPID" -ETSeed "$seed" -ETSheet "$sheet" -ETWidth 0 -ETMock 1 >/dev/null 2>&1
  else
    xcrun simctl launch "$DEV" "$APPID" -ETSeed "$seed" -ETWidth 0 -ETMock 1 >/dev/null 2>&1
  fi
  sleep "${WAIT:-3}"
  xcrun simctl io "$DEV" screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "  $name"
}

shoot empty      none
shoot chain      chain
shoot welcome    chain welcome
shoot picker     chain picker
shoot presets    chain presets
shoot settings   chain settings
shoot routing    chain routing
shoot ir         chain ir
# 撮り終わったら落とす。-ETMock で音が鳴っているので、
# 起きたままだと Mac のスピーカーから掃引が鳴り続ける。
xcrun simctl terminate "$DEV" "$APPID" >/dev/null 2>&1
xcrun simctl shutdown "$DEV" >/dev/null 2>&1
echo "SHOTS: $OUT"
