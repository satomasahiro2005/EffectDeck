#!/bin/bash
# Embed untracked JSFX fixtures in local Debug builds only.  The source folder
# is deliberately gitignored: these effects are temporary host-compatibility
# probes and must never enter an archive or a Release application.
set -eu

[ "${CONFIGURATION:-}" = "Debug" ] || exit 0

SOURCE_DIR="$SRCROOT/Local/DebugJSFXFactory/Factory"
[ -d "$SOURCE_DIR" ] || exit 0

DEST_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/DebugJSFXFactory"
mkdir -p "$DEST_DIR"
ditto "$SOURCE_DIR" "$DEST_DIR"

