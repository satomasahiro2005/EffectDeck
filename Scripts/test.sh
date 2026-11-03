#!/bin/bash
# 単体テスト（scheme Logic）をシミュレータ 1 台で走らせる。**実機は要らない。**
#
# Tests/Unit に入れてあるのは、SwiftUI にも AVFoundation にも et_* にも触らないもの
# （project.yml の EffeTuneLiveUnitTests が列挙している）。だから iPhone を繋がず
# シミュレータだけで回る。scheme は project.yml の末尾の schemes: にある Logic。
#
#   bash Scripts/test.sh                          全部
#   bash Scripts/test.sh PipelineAnalysisTests    クラスで絞る（いくつでも並べられる）
#   bash Scripts/test.sh ChainTextTests/testFoo   1 本だけ
#
# 環境変数:
#   SIM=名前か UDID     既定 "iPad Pro 13-inch (M5)"。名前は完全一致。無ければ止まる
#   SIM_OS=27.0        同じ名前が複数の iOS に居るときに絞る
#   SKIP_SETUP=1       Scripts/setup.sh（パッチ・生成物・note-models）を飛ばす。
#                      xcodegen だけは毎回走らせる
#   SAN=address        サニタイザ。address / thread / undefined。address,undefined のように
#                      並べられる。address と thread は一緒にできない
#   XCODEBUILD_EXTRA=  xcodebuild にそのまま足す引数（空白で割る）。例 "CODE_SIGNING_ALLOWED=NO"
#   DRY_RUN=1          何を走らせるかを出すだけ。端末も落とさず、test.log も書かない
#
# **ほかに起きているシミュレータは落とす。**2 台目は起こさない。並列テストも切る
# （-parallel-testing-enabled NO）。入っていると Xcode が端末の複製を起こす。
#
# 全出力は test.log、結果の束は build/Logic.xcresult。
# 判定は test.log の "** TEST SUCCEEDED **"（落ちたら "** TEST FAILED **"）と、このスクリプトの終了値。
# テストが 1 件も走らなかった回（絞りの名前の綴り違いなど）は、SUCCEEDED でも 1 で終わる。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=Scripts/lib/sim.sh
. Scripts/lib/sim.sh
LOG="$ROOT/test.log"
RESULT="$ROOT/build/Logic.xcresult"
DRY="${DRY_RUN:-0}"

say() {
  echo "$*"
  [ "$DRY" = "1" ] || echo "$*" >> "$LOG"
}

finish() {
  echo "=== TEST SCRIPT FINISHED (exit=$1) ==="
  exit "$1"
}

# サニタイザ。ASan と TSan は同じ実行に載らない。
SAN_ARGS=()
if [ -n "${SAN:-}" ]; then
  case ",$SAN," in
    *,address,*)
      case ",$SAN," in
        *,thread,*)
          echo "!! SAN: address と thread は一緒にできない（別々に走らせる）"
          exit 2 ;;
      esac ;;
  esac
  for s in $(printf '%s' "$SAN" | tr ',' ' '); do
    case "$s" in
      address)   SAN_ARGS+=(-enableAddressSanitizer YES) ;;
      thread)    SAN_ARGS+=(-enableThreadSanitizer YES) ;;
      undefined) SAN_ARGS+=(-enableUndefinedBehaviorSanitizer YES) ;;
      *) echo "!! SAN に知らない値: ${s}（address / thread / undefined）"
         exit 2 ;;
    esac
  done
fi

EXTRA=()
[ -z "${XCODEBUILD_EXTRA:-}" ] || read -r -a EXTRA <<< "$XCODEBUILD_EXTRA"

ONLY=()
if [ $# -eq 0 ]; then
  ONLY=(-only-testing:EffeTuneLiveUnitTests)
else
  for t in "$@"; do ONLY+=("-only-testing:EffeTuneLiveUnitTests/$t"); done
fi

if [ "$DRY" = "1" ]; then
  echo "=== DRY_RUN: 走らせるものを出すだけ ==="
else
  mkdir -p "$ROOT/build"
  echo "=== $(date) ===" > "$LOG"
fi

# 端末は先に引く。無ければ setup を待たずに止まる。
sim_select || finish 1
say "device: $SIM_NAME ($SIM_UDID)"

if [ "${SKIP_SETUP:-0}" = "1" ]; then
  say "-- SKIP_SETUP=1 なので Scripts/setup.sh は飛ばす"
else
  # 新しい clone では note-models も無く、Vendor/ysfx にもパッチが当たっていない。
  # その木で走らせると、サンドボックスのテストが違うコードに当たる。
  et_step "$LOG" "Scripts/setup.sh" env SKIP_XCODEGEN=1 bash Scripts/setup.sh || finish 1
fi
et_step "$LOG" "xcodegen（project.yml）" xcodegen generate --spec project.yml || finish 1

sim_only || finish 1

ARGS=(-project EffeTuneLive.xcodeproj -scheme Logic
      -destination "id=$SIM_UDID"
      -parallel-testing-enabled NO
      -resultBundlePath "$RESULT")

# DRY_RUN で出すものと本当に走らせるものは、この 1 つの配列から作る（別々に書くと食い違う）。
CMD=(xcodebuild "${ARGS[@]}" ${SAN_ARGS[@]+"${SAN_ARGS[@]}"}
     ${EXTRA[@]+"${EXTRA[@]}"} "${ONLY[@]}" test)

# -resultBundlePath は既にあると落ちる。
et_run rm -rf "$RESULT"
if [ "$DRY" = "1" ]; then
  et_run "${CMD[@]}"
  finish 0
fi

echo "--- 走らせる ---"
echo "--- xcodebuild test $(date) ---" >> "$LOG"
"${CMD[@]}" >> "$LOG" 2>&1
CODE=$?

et_test_summary "$LOG" "$CODE" "$RESULT"
finish $?
