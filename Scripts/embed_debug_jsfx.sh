#!/bin/bash
# Embed untracked JSFX fixtures in local Debug builds only.  The source folder
# is deliberately gitignored: these effects are temporary host-compatibility
# probes and must never enter an archive or a Release application.
set -eu

[ "${CONFIGURATION:-}" = "Debug" ] || exit 0

DEST_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/DebugJSFXFactory"
mkdir -p "$DEST_DIR"

# Project-owned conformance probes are safe to keep in Git. Third-party
# real-world fixtures stay under the ignored Local directory and are copied
# over them only on the developer's machine.
TRACKED_DIR="$SRCROOT/Debug/JSFXFactory"
[ ! -d "$TRACKED_DIR" ] || ditto "$TRACKED_DIR" "$DEST_DIR"
LOCAL_DIR="$SRCROOT/Local/DebugJSFXFactory/Factory"
[ ! -d "$LOCAL_DIR" ] || ditto "$LOCAL_DIR" "$DEST_DIR"
