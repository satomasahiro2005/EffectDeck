#!/bin/bash
# bridge を 1 往復ぶん測る。
#
#   bash Scripts/bridge_probe.sh [録る秒数]        既定 30
#
# MediaDevice.framework は iPhoneOS SDK にしか無く（iPhoneSimulator27.0.sdk に
# 無いことを確認済み）、拡張はシミュレータにリンクできない。bridge は実機でしか
# 測れないので、せめて 1 往復を 1 コマンドにして、毎回同じ行を同じ順で出す。
#
# 出るのは「どこで切れたか」を決める表だけ。生ログは bridge-<時刻>.log に残す。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1

SECS="${1:-30}"
UDID="${DEV_ID:-$(idevice_id -l 2>/dev/null | head -1)}"
[ -n "$UDID" ] || { echo "実機が見つからない"; exit 1; }

LOG="bridge-$(date +%H%M%S).log"
rm -f "$LOG"

echo "録る: ${SECS}秒 -> $LOG  (udid=$UDID)"
echo
echo "  いまコントロールセンターを開いて出力先に EffeTune を選ぶこと。"
echo "  音が鳴っているアプリ（音楽など）も一緒に動かしておく。"
echo
# **絞らずに録る。**
# `-m "EffeTune"` を付けていたが、**一番要る行がそれで落ちる。**
# 経路を決めている audiomxd の行に大文字の EffeTune は入っていない:
#   Session with bundleID: com.spotify.client doesn't support currently selected
#   protocolID media-device-protocol.ai.nemut.effetune. isPlayingVideoOutput: NO.
#   Allow session with bundleID: com.spotify.client to play using
#   protocolID media-device-protocol.ai.nemut.effetune because there is a MusicVAD.
# （docs/connect-log.md:545, :587-589 逐語。effetune は小文字）
# 絞るのは録ったあと。下の grep がやる。
idevicesyslog -u "$UDID" > "$LOG" 2>&1 &
CAP=$!
for i in $(seq "$SECS" -1 1); do printf "\r  残り %2ds " "$i"; sleep 1; done
printf "\r              \r"
kill "$CAP" 2>/dev/null; wait "$CAP" 2>/dev/null

n() { grep -c "$1" "$LOG" 2>/dev/null | tr -d ' '; }

echo "== 行数 $(wc -l < "$LOG" | tr -d ' ')"
echo
echo "-- 1. 拡張はシステムから音を貰えたか / 47101 へ送れたか"
grep "受信 frames=" "$LOG" | tail -6
[ "$(n '受信 frames=')" = 0 ] && echo "   (0 行) startRealtimeSampleDelivery が走っていない"
echo
echo "-- 2. 本体は受け取って、どこへ出しているか"
grep "tick out=" "$LOG" | tail -6
echo "   out= が EffeTune なら自分の音が仮想デバイスへ戻っている（ループバック側の話）"
echo
echo "-- 3. 繋ぎ"
grep "ET connect\|ET receiver\|ET 接続を受けた\|相手が切断した\|ET connect 失敗" "$LOG" | tail -8
echo
echo "-- 4. 活かして切られるまで"
grep "Recieved activation request\|Device activation completed\|Starting realtime sample delivery\|Recieved deactivation request\|Stopping realtime sample delivery" "$LOG" \
  | awk '{ printf "%s %s\n", $3, substr($0, index($0,"<")) }' | tail -12
grep "Device activation completed\|Recieved deactivation request" "$LOG" | awk '
  function secs(t,  a) { split(t, a, ":"); return a[1]*3600 + a[2]*60 + a[3] }
  /activation completed/ { a = secs($3); next }
  /deactivation request/ { if (a > 0) printf "   活かしてから %.3f 秒で切られた\n", secs($3) - a; a = 0 }'
echo
echo "-- 5. 経路を渡すかどうかの判定（audiomxd。ここが本体）"
grep -nE "doesn't support currently selected protocolID|Allow session with bundleID|universal URL playback support|allowsExternalPlayback == NO|because we're currently mirroring|Will attempt to switch to AirPlay" "$LOG" | tail -10
[ "$(n "doesn't support currently selected protocolID")" = 0 ]   && echo "   (0 行) 判定そのものが走っていない。通る / 通らない以前の話"
echo
echo "-- 6. 切った側の手掛かり（0 件なら別の理由）"
for k in "a different endpoint got picked" "MDERouteRevertedToLocal" "already connected" "Unable to Connect" "deny(1) network-bind"; do
  printf "   %-34s %s\n" "$k" "$(n "$k")"
done
echo
echo "-- 6. 雑音として既に切り分けたもの（数えるだけ・追わない）"
printf "   %-34s %s\n" "Invalid plist / WAN URLs" "$(n 'Invalid plist')"
echo
echo "生ログ: $LOG"
