#!/bin/bash
# TestFlight のパブリックリンクが開くまで見張る。**Mac を経由しない。**
#
# 判定は「閉じている文が消えたら」ではやらない。**文面が変わっただけで
# 開いたことになり、死んだリンクを投稿する。**開いた側にしか出ない印で見る。
#
#   閉じているページ   EffectDeck 0 回 / "accepting any new testers" 1 回
#   開いているページ   EffectDeck 6 回 / 同 0 回
#   ("View in TestFlight" は両方に出るので使えない)
#
# さらに、
#   - HTTP 200 で 10KB 以上あること（切れた応答に騙されない）
#   - 開いたと見えたら 30 秒後にもう一度見て、2 回続いたときだけ確定
# を足してある。
#
#   bash Tools/watch_testflight.sh [参加リンク]

set -u
URL="${1:-https://testflight.apple.com/join/QtEVGZxn}"
NAME="${2:-EffectDeck}"
CLOSED="accepting any new testers"
LOG=/tmp/watch_tf.log
INTERVAL=300
ROUNDS=288          # 5 分 x 288 = 24 時間

: > "$LOG"
say() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

# 開いていれば 0、閉じていれば 1、判定できなければ 2。
probe() {
  local body code size
  body=$(curl -s -A "Mozilla/5.0" -w $'\n%{http_code}' "$URL" 2>/dev/null)
  code=$(printf '%s' "$body" | tail -1)
  body=$(printf '%s' "$body" | sed '$d')
  size=${#body}
  [ "$code" = "200" ] || { say "HTTP $code"; return 2; }
  [ "$size" -ge 10000 ] || { say "短すぎる ($size bytes)"; return 2; }
  if printf '%s' "$body" | grep -q "$CLOSED"; then return 1; fi
  if printf '%s' "$body" | grep -q "$NAME"; then return 0; fi
  # どちらの印も無い ＝ 知らない形。**開いたことにしない。**
  say "印がどちらも無い ($size bytes)"
  return 2
}

say "見張り開始 $URL"
for i in $(seq 1 "$ROUNDS"); do
  if probe; then
    say "開いたように見える。30 秒後に確かめる"
    sleep 30
    if probe; then
      say "OPEN 確定"
      exit 0
    fi
    say "2 回目で否定された。続ける"
  fi
  say "まだ閉じている ($i/$ROUNDS)"
  sleep "$INTERVAL"
done
say "TIMEOUT"
exit 1
