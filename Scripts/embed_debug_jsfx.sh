#!/bin/bash
# Embed the JSFX fixtures.
#
# Debug/JSFXFactoryは自前のもの（権利がこちらにある）。積むのは**DebugとET_BETA（TestFlight）だけ**。
# TestFlightで配る相手に、JSFXが動くことを試す手がかりが要る。
# 店の版には積まない。一覧に出さないだけでなく、書庫にも入れない
# （Tools/review_notes.txtの「ships no scripts」はこれで成り立つ）。
# 条件はアプリ側のETJSFXHost.showsBundledSamples（`#if DEBUG || ET_BETA`）と揃える。
# ET_BETAはproject.ymlのBeta構成（紫のアイコンと同じ所）がSWIFT_ACTIVE_COMPILATION_CONDITIONSへ足す。
# 構成名がBetaなだけではDebug扱いにならない（第三者のLocalは積まない）。
#
# Local/DebugJSFXFactoryは第三者の実物で、**再配布しない**。
# gitignoreしてあるうえ、ここでDebugのときしか写さない。
# **この条件を緩めないこと。**書庫にもReleaseにも入れてはいけない。
set -eu

DEST_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/DebugJSFXFactory"
# 毎回消してから写す。dittoは足すだけなので、紫の後に青を建てたときや
# Localから消したときに、前のビルドの写しが.appに残る。
rm -rf "$DEST_DIR"

IS_DEBUG=0
[ "${CONFIGURATION:-}" != "Debug" ] || IS_DEBUG=1
EMBED_SAMPLES=$IS_DEBUG
case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
  *" DEBUG "*|*" ET_BETA "*) EMBED_SAMPLES=1 ;;
esac

# 自前のもの。DebugとET_BETAだけ。
TRACKED_DIR="$SRCROOT/Debug/JSFXFactory"
if [ "$EMBED_SAMPLES" = 1 ] && [ -d "$TRACKED_DIR" ]; then
  mkdir -p "$DEST_DIR"
  ditto "$TRACKED_DIR" "$DEST_DIR"
fi

# 第三者の実物。**Debugだけ。**
if [ "$IS_DEBUG" = 1 ]; then
  LOCAL_DIR="$SRCROOT/Local/DebugJSFXFactory/Factory"
  if [ -d "$LOCAL_DIR" ]; then
    mkdir -p "$DEST_DIR"
    ditto "$LOCAL_DIR" "$DEST_DIR"
  fi
fi
