#!/bin/bash
# エフェクトのカード以外の画面を撮る。
# 使い方: bash Scripts/shoot_screens.sh
#
# 撮ったものは shots-screens/<名前>.png。画面の作りを見るためのもの
# （カードが長くて切れるのは shoot_all.sh の話）。
#
# 端末は既定で "iPad Pro 13-inch (M5)"（Scripts/lib/sim.sh。ほかに起きている端末は落とす）。
# 幅は WIDTH で決める。既定は iPad なら 440（出荷物の iPad が 1 列で止める幅）、
# iPhone なら 0（絞らない）。**iPhone で撮るなら絞ってはいけない。**絞ると端末の幅との差が
# 左右の余白に見えて、崩れと区別できなくなる。
#   SIM="iPhone 18 Pro" bash Scripts/shoot_screens.sh   iPhone の見え方
#   LAYOUT=wide                                        iPad の 2 列（-ETLayout wide を渡す）
#   SKIP_BUILD=1 / SKIP_SETUP=1 / WAIT=秒 / DRY_RUN=1  shoot_all.sh と同じ
# 建てるときの全出力は shoot-build.log。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=Scripts/lib/sim.sh
. Scripts/lib/sim.sh
OUT="$ROOT/shots-screens"
BUILD_LOG="$ROOT/shoot-build.log"

sim_select || exit 1
echo "device: $SIM_NAME ($SIM_UDID)"
if sim_is_ipad; then WIDTH="${WIDTH:-440}"; else WIDTH="${WIDTH:-0}"; fi
sim_only || exit 1
sim_show

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  [ "${DRY_RUN:-0}" = "1" ] || : > "$BUILD_LOG"
  sim_project "$BUILD_LOG" || exit 1
  sim_build_app "$BUILD_LOG" || exit 1
fi

APP="$ROOT/out-sim/EffectDeck.app"
if [ "${DRY_RUN:-0}" != "1" ] && [ ! -d "$APP" ]; then
  echo "!! 成果物が無い: $APP"
  exit 1
fi
sim_install_app "$APP" || exit 1

et_run mkdir -p "$OUT"

# 名前 / 鎖 / 出すシート
#   鎖が none だと空の画面、chain だと 4 本並んだ画面になる。
shoot() {
  local name="$1" seed="$2" sheet="${3:-}"
  local args=(-ETSeed "$seed" -ETWidth "$WIDTH" -ETMock 1)
  [ -z "$sheet" ] || args+=(-ETSheet "$sheet")
  [ -z "${LAYOUT:-}" ] || args+=(-ETLayout "$LAYOUT")
  sim_terminate_app
  et_quiet xcrun simctl launch "$SIM_UDID" "$ET_APPID" "${args[@]}"
  et_run sleep "${WAIT:-3}"
  et_quiet xcrun simctl io "$SIM_UDID" screenshot "$OUT/$name.png"
  echo "  $name"
}

shoot empty      none
shoot chain      chain
shoot picker     chain picker
shoot presets    chain presets
shoot settings   chain settings
shoot routing    chain routing
shoot ir         chain ir
# 撮り終わったら落とす。-ETMock で音が鳴っているので、
# 起きたままだと Mac のスピーカーから掃引が鳴り続ける。
sim_terminate_app
et_quiet xcrun simctl shutdown "$SIM_UDID"
echo "SHOTS: $OUT"
