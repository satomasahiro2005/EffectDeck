#!/bin/bash
# 公証が通ったあと、ADP を落として置ける形にする。
#
#   bash adp_fetch.sh
#
# 手順（faq.altstore.io/developers/rest-api と /distribute-with-altstore-pal）:
#   1. App Store Connect から ADP の ID を読む（Apple が公証で生成する）
#   2. GET https://api.altstore.io/adps/<ADP ID> → downloadURL が返る
#   3. 落として **階層をそのまま** 置く。manifest.json は一切いじらない
#   4. source.json の downloadURL がその manifest.json を指す
#      size は variant フォルダのどれかの大きさでよい
set -u
V=51742091-f729-4a5a-8147-66077fa0164b
OUT=~/work/adp
mkdir -p "$OUT"
cd "$OUT" || exit 1

echo "=== 1. ADP を読む ==="
python3 ~/asc.py adp-show "$V" | tee adp-show.txt
ADP=$(grep -m1 "^adp " adp-show.txt | awk '{print $2}')
if [ -z "$ADP" ]; then
  echo "!! ADP がまだ無い。公証が通っているか確認する"
  exit 1
fi
echo "ADP ID = $ADP"

echo "=== 2. AltStore に聞く ==="
curl -s "https://api.altstore.io/adps/$ADP" -o altstore.json
cat altstore.json
URL=$(python3 -c "
import json
d = json.load(open('altstore.json'))
print(d.get('downloadURL') or d.get('data', {}).get('downloadURL') or '')
")
if [ -z "$URL" ]; then
  echo "!! downloadURL が取れない。上の返事を読むこと"
  exit 1
fi
echo "downloadURL = $URL"

echo "=== 3. 落とす ==="
rm -rf pkg && mkdir pkg
curl -L "$URL" -o pkg.zip
unzip -q -o pkg.zip -d pkg
find pkg -maxdepth 3 -type f | head -n 30
echo "--- manifest.json ---"
find pkg -name manifest.json | head

echo "=== 4. variant の大きさ ==="
find pkg -type f -name "*.ipa" -o -type f -path "*variant*" 2>/dev/null \
  | head -n 5 | while read -r f; do echo "$(stat -f%z "$f") $f"; done
du -sb pkg 2>/dev/null || du -sk pkg

echo "=== 置き場 ==="
echo "$OUT/pkg の中身を そのまま nemut.ai の public/effetune-live/adp/ へ写す"
