#!/bin/bash
# EffeTune Live（本体）と EffeTune Live Bridge（拡張の入れ物）をビルドして実機に入れる。
#
# 使い方:
#   bash Scripts/build.sh              つないである実機を自動で探す
#   DEV_ID=<UDID> bash Scripts/build.sh 実機を指定する
#
# macOS の GUI セッションの Terminal から走らせること。
# SSH 越しだと codesign が login keychain に届かず errSecInternalComponent になる。
set -u
export PATH="/opt/homebrew/bin:$PATH"   # xcodegen と、3.10 以降の python3
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LOG="$ROOT/build.log"

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

build_one() {
  echo "================ build $1 ================"
  /usr/bin/xcodebuild -project EffeTuneLive.xcodeproj \
    -scheme "$1" -configuration Debug \
    -sdk iphoneos -arch arm64 -allowProvisioningUpdates \
    CONFIGURATION_BUILD_DIR="$ROOT/out" build 2>&1 \
    | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED|not found and could not|doesn't (support|include)" \
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
install_one() {
  [ -d "$1" ] || { echo "!! $1 が無い"; return 1; }
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

  echo "--- エフェクトのカタログを作る ---"
  python3 Tools/gen_catalog.py 2>&1 | tail -5
python3 Tools/gen_presets.py 2>&1 | tail -1
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
  xcodegen generate --spec project.yml 2>&1 | tail -5

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
  install_one "out/EffeTune Live.app"        ai.nemut.effetune

  echo "=== done $(date) ==="
} > "$LOG" 2>&1

echo "FINISHED: $LOG"
