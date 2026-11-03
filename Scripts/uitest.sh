#!/bin/bash
# UI テスト（EffeTuneLiveUITests）をシミュレータ 1 台で走らせる。
#
#   bash Scripts/uitest.sh                          SmokeTests を全部
#   bash Scripts/uitest.sh MenuProbe                クラスで絞る（いくつでも並べられる）
#   bash Scripts/uitest.sh SmokeTests/test03AddEffect  1 本だけ
#
# 拡張を外したシミュレータ用のプロジェクト（Tools/gen_sim_spec.py → project-sim.yml →
# EffeTuneLiveSim.xcodeproj）で建てる。MediaDevice.framework はシミュレータの SDK に
# 無いので、project.yml のままだと拡張で必ず落ちる。
#
# 環境変数は Scripts/test.sh と同じ（SIM / SIM_OS / SKIP_SETUP / XCODEBUILD_EXTRA / DRY_RUN）。
# 並列テストと複数端末への同時実行は切る。入っていると Xcode が端末の複製を起こす。
# アプリは入れ直してから走らせ、終わったら落とす（-ETMock の掃引が鳴り続けるので）。
#
# 全出力は uitest.log、結果の束は build/UITest.xcresult。DerivedData は ./DerivedData。
# 判定は uitest.log の "** TEST SUCCEEDED **" と、このスクリプトの終了値。
# テストが 1 件も走らなかった回は、SUCCEEDED でも 1 で終わる（Tests/UI に SmokeTests が
# 入るまでは、引数なしの回がこれになる）。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=Scripts/lib/sim.sh
. Scripts/lib/sim.sh
LOG="$ROOT/uitest.log"
RESULT="$ROOT/build/UITest.xcresult"
DRY="${DRY_RUN:-0}"

say() {
  echo "$*"
  [ "$DRY" = "1" ] || echo "$*" >> "$LOG"
}

finish() {
  echo "=== UITEST SCRIPT FINISHED (exit=$1) ==="
  exit "$1"
}

EXTRA=()
[ -z "${XCODEBUILD_EXTRA:-}" ] || read -r -a EXTRA <<< "$XCODEBUILD_EXTRA"

ONLY=()
if [ $# -eq 0 ]; then
  ONLY=(-only-testing:EffeTuneLiveUITests/SmokeTests)
else
  for t in "$@"; do ONLY+=("-only-testing:EffeTuneLiveUITests/$t"); done
fi

if [ "$DRY" = "1" ]; then
  echo "=== DRY_RUN: 走らせるものを出すだけ ==="
else
  mkdir -p "$ROOT/build"
  echo "=== $(date) ===" > "$LOG"
fi

sim_select || finish 1
say "device: $SIM_NAME ($SIM_UDID)"

sim_project "$LOG" || finish 1
sim_only || finish 1
sim_show

sim_terminate_app
et_quiet xcrun simctl uninstall "$SIM_UDID" "$ET_APPID"

ARGS=(-project EffeTuneLiveSim.xcodeproj -scheme EffeTuneLive
      -destination "id=$SIM_UDID"
      -jobs "${BUILD_JOBS:-2}"
      -derivedDataPath "$ROOT/DerivedData"
      -parallel-testing-enabled NO
      -disable-concurrent-destination-testing
      -resultBundlePath "$RESULT")

# DRY_RUN で出すものと本当に走らせるものは、この 1 つの配列から作る（別々に書くと食い違う）。
# ET_XCODEBUILD は lib/sim.sh が決める（既定は名指しの /usr/bin/xcodebuild）。
CMD=("$ET_XCODEBUILD" "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} "${ONLY[@]}" test)

et_run rm -rf "$RESULT"
if [ "$DRY" = "1" ]; then
  et_run "${CMD[@]}"
  sim_terminate_app
  finish 0
fi

echo "--- 走らせる ---"
echo "--- xcodebuild test $(date) ---" >> "$LOG"
"${CMD[@]}" >> "$LOG" 2>&1
CODE=$?
sim_terminate_app

et_test_summary "$LOG" "$CODE" "$RESULT"
finish $?
