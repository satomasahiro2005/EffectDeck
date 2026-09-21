#!/bin/bash
# Embed the JSFX fixtures.
#
# Debug/JSFXFactory は自前のもの（権利がこちらにある）なので**どの構成でも積む**。
# TestFlight で配る相手に、JSFX が動くことを試す手がかりが要る。
#
# Local/DebugJSFXFactory は第三者の実物で、**再配布しない**。
# gitignore してあるうえ、ここで Debug のときしか写さない。
# **この条件を緩めないこと。**書庫にも Release にも入れてはいけない。
set -eu

DEST_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/DebugJSFXFactory"
mkdir -p "$DEST_DIR"

# 自前のもの。どの構成でも積む。
TRACKED_DIR="$SRCROOT/Debug/JSFXFactory"
[ ! -d "$TRACKED_DIR" ] || ditto "$TRACKED_DIR" "$DEST_DIR"

# 第三者の実物。**Debug だけ。**
if [ "${CONFIGURATION:-}" = "Debug" ]; then
  LOCAL_DIR="$SRCROOT/Local/DebugJSFXFactory/Factory"
  [ ! -d "$LOCAL_DIR" ] || ditto "$LOCAL_DIR" "$DEST_DIR"
fi
