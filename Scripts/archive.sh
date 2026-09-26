#!/bin/bash
# 配布用の書庫を作る。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
SCHEME="${1:-EffeTuneLive}"
# アイコン。**既定は紫**（EffectDeckPublicBeta）。ここから出る書庫は TestFlight 行きで、
# 端末で青と紫を見分けられると、いまどちらを触っているか分かる。
#
# 店へ出すときだけ第 2 引数に EffeTuneLive を渡して青にする。
# 起動時に setAlternateIconName で差し替える形にしないのは、系が毎回
# 「アイコンを変えました」の確認を出すから。
APPICON="${2:-EffectDeckPublicBeta}"
# **アイコンと中身を 1 つの引数で決める。**別々にすると噛み合わなくなる
# （紫なのに JSFX が無い形を一度作った）。
# ベータ側だけ ET_BETA を立てる。いま ET_BETA で変わるのは同梱の JSFX の見本
# （ETJSFXHost.showsBundledSamples）だけ。JSFX 本体は店の版でも開いている
# （ETJSFXHost.isEnabled）。店に出さない機能を足すときはここで開ける。
if [ "$APPICON" = "EffectDeckPublicBeta" ]; then
  SWIFT_FLAGS='$(inherited) ET_BETA'
else
  SWIFT_FLAGS='$(inherited)'
fi
LOG="$PWD/archive.log"
{
  echo "=== start $(date) === icon=$APPICON"
  python3 Tools/gen_version.py 2>&1 | tail -1
  xcodegen generate --spec project.yml 2>&1 | tail -1
  /usr/bin/xcodebuild -project EffeTuneLive.xcodeproj -scheme "$SCHEME" \
    -configuration Release -sdk iphoneos -arch arm64 -allowProvisioningUpdates \
    ET_APPICON="$APPICON" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$SWIFT_FLAGS" \
    archive -archivePath "/tmp/$SCHEME.xcarchive" 2>&1 \
    | grep -E "error:|ARCHIVE SUCCEEDED|ARCHIVE FAILED|errSec" | tail -10
  echo "=== done $(date) ==="
} > "$LOG" 2>&1
