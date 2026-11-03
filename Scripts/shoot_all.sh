#!/bin/bash
# 全エフェクトを 1 つずつシミュレータで撮る。
# 使い方: bash Scripts/shoot_all.sh [型名...]（省略すると全部）
#
# 撮ったものは shots-all/<型名>.png。
# **iPad で撮るが、アプリ側が iPhone の幅に絞る。**
# 高さは iPad が要る（長いカードが iPhone だと切れる）が、
# 幅まで iPad になると実機の見え方にならない。
# 音は来ないが画面は同じものが出る。図は無音ぶんが出る。
#
#   SIM=名前か UDID  既定 "iPad Pro 13-inch (M5)"（Scripts/lib/sim.sh）。ほかに起きている端末は落とす
#   SKIP_BUILD=1    建て直さず out-sim/EffectDeck.app をそのまま入れる
#   SKIP_SETUP=1    建てるが Scripts/setup.sh は飛ばす
#   WAIT=秒         起動から撮るまで（既定 2）
#   DRY_RUN=1       走らせるものを出すだけ
# 建てるときの全出力は shoot-build.log。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=Scripts/lib/sim.sh
. Scripts/lib/sim.sh
OUT="$ROOT/shots-all"
BUILD_LOG="$ROOT/shoot-build.log"

sim_select || exit 1
echo "device: $SIM_NAME ($SIM_UDID)"
sim_only || exit 1
sim_show

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  [ "${DRY_RUN:-0}" = "1" ] || : > "$BUILD_LOG"
  # setup.sh を通す。前はその一部（カタログ・プリセット・ライセンス・note-models・版）を
  # 写していて、パッチと gen_effect_presets が抜けていた。
  sim_project "$BUILD_LOG" || exit 1
  sim_build_app "$BUILD_LOG" || exit 1
fi

APP="$ROOT/out-sim/EffectDeck.app"
if [ "${DRY_RUN:-0}" != "1" ] && [ ! -d "$APP" ]; then
  echo "!! 成果物が無い: $APP"
  exit 1
fi
sim_install_app "$APP" || exit 1

if [ "$#" -gt 0 ]; then
  TYPES="$*"
else
  # カタログから型名を全部取る。
  TYPES=$(sed -n 's/^      type: "\([A-Za-z0-9_]*\)",$/\1/p' \
          Sources/EffeTuneLive/Generated/EffectCatalog.swift)
fi

et_run mkdir -p "$OUT"
n=0
for t in $TYPES; do
  sim_terminate_app
  # -ETMock 1 で作り物の音を流す。無いとメーターも図も
  # 「Waiting for audio」のままで、カードの半分が見られない。
  et_quiet xcrun simctl launch "$SIM_UDID" "$ET_APPID" -ETSeed "$t" -ETMock 1
  et_run sleep "${WAIT:-2}"
  et_quiet xcrun simctl io "$SIM_UDID" screenshot "$OUT/$t.png"
  n=$((n + 1))
  echo "  $t"
done
# 撮り終わったら落とす。-ETMock で音が鳴っているので、
# 起きたままだと Mac のスピーカーから掃引が鳴り続ける。
sim_terminate_app
et_quiet xcrun simctl shutdown "$SIM_UDID"
echo "SHOTS: $OUT ($n)"
