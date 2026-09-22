#!/bin/bash
# 書庫（Release + strip）を建てて、そのまま実機へ入れる。
#
# **出荷する形そのもので触るため。**Scripts/build.sh は plain build なので
# strip されず、Release でしか出ない不具合をすり抜ける。一度それで
# 「資産を使う 7 種が出荷版で全部動かない」を 5 日間見逃している。
#
# GUI の Terminal から走らせること（ssh からだと codesign が鍵に届かない）。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
OUT="$PWD/archive-install.log"
: > "$OUT"

security unlock-keychain -p "$(cat ~/signing/kc.pw)" >> "$OUT" 2>&1

bash Scripts/archive.sh EffeTuneLive >> "$OUT" 2>&1
tail -5 archive.log >> "$OUT" 2>&1

APP=/tmp/EffeTuneLive.xcarchive/Products/Applications/EffectDeck.app
if [ ! -d "$APP" ]; then
  echo "!! app が無い。画面のロックを解いたか確認する" >> "$OUT"
  echo "=== ARCHIVE INSTALL FINISHED ===" >> "$OUT"
  exit 1
fi

# strip されていることの確認。**0 件が正しい。**
# 直したあとは dlsym を使っていないので、シンボルが消えていても動く。
printf 'asset_begin のシンボル数: ' >> "$OUT"
nm "$APP/EffectDeck" 2>/dev/null | grep -ci asset_begin >> "$OUT"

# UDID を名指しで拾う。列の位置で取ると端末名に空白が入っただけでずれる
# （一度それで device=16 を掴んだ）。simulated の行は落とす。
DEV=$(xcrun devicectl list devices 2>/dev/null \
  | grep -v simulated | grep -E "connected|available" \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
echo "device=$DEV" >> "$OUT"
[ -n "$DEV" ] || { echo "!! 実機が見つからない" >> "$OUT"; echo "=== ARCHIVE INSTALL FINISHED ===" >> "$OUT"; exit 1; }

xcrun devicectl device install app --device "$DEV" "$APP" 2>&1 \
  | grep -E "App installed|error" | head -3 >> "$OUT"
echo "=== ARCHIVE INSTALL FINISHED ===" >> "$OUT"
