#!/bin/bash
# 配布用の書庫を作る。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
SCHEME="${1:-EffeTuneLive}"
LOG="$PWD/archive.log"
{
  echo "=== start $(date) ==="
  python3 Tools/gen_version.py 2>&1 | tail -1
  xcodegen generate --spec project.yml 2>&1 | tail -1
  /usr/bin/xcodebuild -project EffeTuneLive.xcodeproj -scheme "$SCHEME" \
    -configuration Release -sdk iphoneos -arch arm64 -allowProvisioningUpdates \
    archive -archivePath "/tmp/$SCHEME.xcarchive" 2>&1 \
    | grep -E "error:|ARCHIVE SUCCEEDED|ARCHIVE FAILED|errSec" | tail -10
  echo "=== done $(date) ==="
} > "$LOG" 2>&1
