#!/bin/bash
# App Store 用のスクリーンショット。
# 使い方: bash Scripts/shoot_store.sh [鎖[:シート]...]（省略すると none の 1 枚）
#   例: bash Scripts/shoot_store.sh chain chain:routing analyzers4
#
# 端末は既定で "iPad Pro 13-inch (M5)"（13 インチの iPad のぶん。Scripts/lib/sim.sh。
# ほかに起きている端末は落とす）。iPhone のぶんは 6.9 インチで撮る
# （Apple はそれを他のサイズへ自動で縮める）:
#   SIM="iPhone 18 Pro Max" bash Scripts/shoot_store.sh ...
#
# 幅は WIDTH。既定は iPad なら 440、iPhone なら 0（絞らない）。
# 実機の iPad は 1 列のとき ETLayout が 440pt で止めるので、絞らずに撮ると出荷物と違う絵になる。
#   LAYOUT=wide      iPad の 2 列（-ETLayout wide を渡す）
#   COLLAPSED=1      畳んだ状態。図だけ残ってつまみが消えるので、Analyzer の鎖はこちら
#   SHEET=名前       鎖ごとに :シート を書かないときのシート
#   SLEEP=秒         起動から撮るまで（既定 5）
#   SKIP_SETUP=1 / DRY_RUN=1  shoot_all.sh と同じ
# 建てるときの全出力は shoot-build.log。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=Scripts/lib/sim.sh
. Scripts/lib/sim.sh
OUT="$ROOT/shots-store"
BUILD_LOG="$ROOT/shoot-build.log"

sim_select || exit 1
echo "device: $SIM_NAME ($SIM_UDID)"
if sim_is_ipad; then WIDTH="${WIDTH:-440}"; else WIDTH="${WIDTH:-0}"; fi
sim_only || exit 1
sim_show

# 時計と電波を整える。App Store の審査で端末の状態がまちまちだと見栄えが悪い。
et_quiet xcrun simctl status_bar "$SIM_UDID" override --time "9:41" \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 \
  --batteryState charged --batteryLevel 100

[ "${DRY_RUN:-0}" = "1" ] || : > "$BUILD_LOG"
sim_project "$BUILD_LOG" || exit 1
sim_build_app "$BUILD_LOG" || exit 1

APP="$ROOT/out-sim/EffectDeck.app"
sim_install_app "$APP" || exit 1

et_run mkdir -p "$OUT"
if [ "$#" -gt 0 ]; then SEEDS="$*"; else SEEDS="none"; fi
n=0
for spec in $SEEDS; do
  # `鎖:シート` と書くと、その 1 枚だけシートを出して撮る。
  # 建て直しは 1 度で済ませたいので、SHEET を環境から渡す形と併用できる。
  seed="${spec%%:*}"
  sheet="${spec#*:}"
  [ "$sheet" = "$spec" ] && sheet="${SHEET:-}"
  name=$(printf '%s' "$spec" | tr ':' '-')
  # 作り物の音を流す。メーターも図も止まったままだと店頭で意味が無い。
  args=(-ETSeed "$seed" -ETWidth "$WIDTH" -ETCollapsed "${COLLAPSED:-0}" -ETMock 1)
  [ -z "$sheet" ] || args+=(-ETSheet "$sheet")
  [ -z "${LAYOUT:-}" ] || args+=(-ETLayout "$LAYOUT")
  sim_terminate_app
  et_quiet xcrun simctl launch "$SIM_UDID" "$ET_APPID" "${args[@]}"
  et_run sleep "${SLEEP:-5}"
  et_quiet xcrun simctl io "$SIM_UDID" screenshot "$OUT/$name.png"
  n=$((n + 1))
  echo "  $name"
done
# 撮り終わったら落とす。モックの音が鳴り続けるので。
sim_terminate_app
et_quiet xcrun simctl shutdown "$SIM_UDID"
echo "SHOTS: $OUT ($n)"
