#!/bin/bash
# 配布用の書庫を作る。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
SCHEME="${1:-EffeTuneLive}"
# アイコン。**既定は紫**（EffeTuneLiveBeta）。ここから出る書庫は TestFlight 行きで、
# 端末に青と紫が並ぶと、いまどちらを触っているか分かる。
#
# 店へ出すときだけ第 2 引数に EffeTuneLive を渡して青にする。
# 起動時に setAlternateIconName で差し替える形にしないのは、系が毎回
# 「アイコンを変えました」の確認を出すから。
APPICON="${2:-EffeTuneLiveBeta}"
LOG="$PWD/archive.log"
{
  echo "=== start $(date) === icon=$APPICON"
  python3 Tools/gen_version.py 2>&1 | tail -1
  xcodegen generate --spec project.yml 2>&1 | tail -1
  /usr/bin/xcodebuild -project EffeTuneLive.xcodeproj -scheme "$SCHEME" \
    -configuration Release -sdk iphoneos -arch arm64 -allowProvisioningUpdates \
    ET_APPICON="$APPICON" \
    archive -archivePath "/tmp/$SCHEME.xcarchive" 2>&1 \
    | grep -E "error:|ARCHIVE SUCCEEDED|ARCHIVE FAILED|errSec" | tail -10
  echo "=== done $(date) ==="
} > "$LOG" 2>&1
