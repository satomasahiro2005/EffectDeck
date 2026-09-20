#!/bin/bash
# 単体テストを走らせる。**実機は要らない。**
#
# Tests/Unit に入れてあるのは、SwiftUI にも AVFoundation にも et_* にも触らない
# 純粋関数だけ（project.yml の EffeTuneLiveUnitTests が 1 本ずつ列挙している）。
# だから iPhone を繋がずシミュレータだけで回る。
#
#   bash Scripts/test.sh                        全部
#   bash Scripts/test.sh PipelineAnalysisTests  名前で絞る
#
# scheme は Logic（project.yml:247）。実機なしで走るものだけが入っている。
#
# 結果は test.log に全部入る。画面には要点だけ出す。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LOG="$ROOT/test.log"
SIM="${SIM:-iPhone 17 Pro}"
FILTER="${1:-}"

echo "=== $(date) ===" > "$LOG"

echo "--- プロジェクトを作り直す ---"
xcodegen generate --spec project.yml 2>&1 | tail -2 | tee -a "$LOG"

# **awk の match(s, re, arr) は使わない。**あれは gawk の拡張で、macOS の awk では
# 「syntax error」で落ちる（Scripts/sim.sh も同じ書き方なので、そちらもいずれ直す）。
DEV=$(xcrun simctl list devices available 2>/dev/null \
  | grep -F "$SIM (" | head -1 | grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}')
# 名前で見つからなければ、使えるものを 1 つ拾う。
[ -n "$DEV" ] || DEV=$(xcrun simctl list devices available 2>/dev/null \
  | grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}' | head -1)
[ -n "$DEV" ] || { echo "!! シミュレータが無い（SIM=名前 で指定できる）"; exit 1; }
echo "device: $DEV" | tee -a "$LOG"

ARGS=(-project EffeTuneLive.xcodeproj -scheme Logic
      -destination "id=$DEV" -only-testing:EffeTuneLiveUnitTests)
[ -z "$FILTER" ] || ARGS=(-project EffeTuneLive.xcodeproj -scheme Logic
                          -destination "id=$DEV"
                          -only-testing:"EffeTuneLiveUnitTests/$FILTER")

echo "--- 走らせる ---"
xcodebuild "${ARGS[@]}" test >> "$LOG" 2>&1
CODE=$?

echo "--- 落ちたもの ---"
grep -E "error:|XCTAssert.*failed|failed -" "$LOG" | head -40
echo "--- 数 ---"
grep -E "Test Suite .* (passed|failed)" "$LOG" | tail -3
grep -cE "^Test Case .* passed" "$LOG" | sed 's/^/通った: /'
grep -cE "^Test Case .* failed" "$LOG" | sed 's/^/落ちた: /'
echo "=== TEST SCRIPT FINISHED (exit=$CODE) ==="
exit $CODE
