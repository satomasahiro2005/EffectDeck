#!/bin/bash
# EffectDeck をビルドして実機に入れる。
#
# 使い方:
#   bash Scripts/build.sh              つないである実機を自動で探す
#   DEV_ID=<UDID> bash Scripts/build.sh 実機を指定する
set -u
export PATH="/opt/homebrew/bin:$PATH"   # xcodegen と、3.10 以降の python3
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LOG="$ROOT/build.log"
# EffeTune + ysfx/WDL are C/C++ heavy. Xcode's automatic parallelism can
# exceed the build Mac's memory on a cold build. Override when the machine has
# headroom (BUILD_JOBS=4, etc.); keep the safe default for remote builds.
BUILD_JOBS="${BUILD_JOBS:-2}"

# 実機だけを探す。シミュレータが起きていると devicectl はそれも connected として
# 並べるので、最後の列（Reality）が physical のものに絞る。
find_device() {
  # 状態は connected だけではない。USB で繋いでいても
  # "available (paired)" と出ることがあり、それでも install は通る。
  # connected だけを見ていたせいで「実機が見つからない」を出していた。
  xcrun devicectl list devices 2>/dev/null     | awk '$NF == "physical" && (/connected/ || /available/) {
             for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}/) { print $i; exit }
           }'
}

# **このスクリプトは Mac の GUI セッションの Terminal から走らせる。**
# SSH から叩くと codesign が鍵に届かず、拡張の署名だけが
#   .../EffeTuneLiveExtension.debug.dylib: errSecInternalComponent
# で落ちる。コンパイルは通るので out/*.app は出来るが、中身が署名されておらず
# install が「not a valid bundle」になる。README にも同じことを書いてある。
#
# 下の grep に errSec と CodeSign failed を足したのは、一度これを取りこぼして
# 「BUILD FAILED」としか出ず、原因を見失ったため
# （codesign の失敗行は "error:" の形を取らない）。
build_one() {
  echo "================ build $1 ================"
  /usr/bin/xcodebuild -project EffeTuneLive.xcodeproj \
    -scheme "$1" -configuration Debug \
    -jobs "$BUILD_JOBS" \
    -sdk iphoneos -arch arm64 -allowProvisioningUpdates \
    CONFIGURATION_BUILD_DIR="$ROOT/out" build 2>&1 \
    | grep -E "error:|errSec|CodeSign failed|Undefined symbols|referenced from:|ld: |symbol\(s\) not found|BUILD SUCCEEDED|BUILD FAILED|not found and could not|doesn't (support|include)" \
    | tail -25
}

# 入れ替えは上書きで行う。
#
# 消してから入れ直すと、拡張が audiomxd に登録した VA port が古いまま残る。
# AudioServerPlugInRegisterMediaDeviceExtension に対になる解除が無く、
# デバイスの UID を固定にしてある（MediaOutputDevice.id と一致させる必要がある）ため、
# 入れ替えのたびに同じ UID の死んだ port が積み上がる。
# そうなると新しい activate が「もう繋がっている」と判断されて素通りし、
# 誰も IO を出さないまま "Unable to Connect" になる。端末の再起動でしか消えない。
#
# 拡張の中身を変えて反映されないときだけ CLEAN=1 を付ける。
# そのときは入れ直したあと端末を再起動すること。
# SKIP_INSTALL=1 で建てるだけにする。
# 直したものが通るかだけ見たいときに使う。実機で試している最中に入れ替えると、
# 向こうでやっていることが途中で止まるので。
install_one() {
  [ -d "$1" ] || { echo "!! $1 が無い"; return 1; }
  [ "${SKIP_INSTALL:-0}" = "1" ] && { echo "-- SKIP_INSTALL=1 なので $2 は入れない"; return 0; }
  [ -n "${DEV_ID:-}" ] || { echo "-- 実機が見つからないので $2 は入れない"; return 0; }
  if [ "${CLEAN:-0}" = "1" ]; then
    echo "--- uninstall $2（このあと端末を再起動すること） ---"
    xcrun devicectl device uninstall app --device "$DEV_ID" "$2" >/dev/null 2>&1
    sleep 1
  fi
  echo "--- install $2 ---"
  xcrun devicectl device install app --device "$DEV_ID" "$1" 2>&1     | grep -E "App installed|bundleID|error" | head -5
}

{
  echo "=== start $(date) ==="
  /usr/bin/xcodebuild -version | head -1

  if [ ! -d Vendor/effetune/dsp ]; then
    echo "!! Vendor/effetune が無い。git submodule update --init --depth 1 を先に。"
    exit 1
  fi

  DEV_ID="${DEV_ID:-$(find_device)}"
  echo "device: ${DEV_ID:-(見つからない)}"

  echo "--- 掃除 ---"
  rm -rf out build EffeTuneLive.xcodeproj

  bash Scripts/setup.sh

  build_one EffeTuneLive

  echo "--- 成果物 ---"
  ls -d out/*.app 2>&1

  # 旧 ID の残骸を先に消す。両方が居ると同じ media-device-protocol を
  # 名乗るものが 2 つになり、ルートピッカーに二重に出る。
  if [ -n "${DEV_ID:-}" ]; then
    for old in ai.nemut.effetune.player ai.nemut.effetune.bridge ai.nemut.effetune.bridge.extension; do
      xcrun devicectl device uninstall app --device "$DEV_ID" "$old" >/dev/null 2>&1
    done
  fi
  install_one "out/EffectDeck.app"        ai.nemut.effetune

  echo "=== done $(date) ==="
} > "$LOG" 2>&1

echo "FINISHED: $LOG"
