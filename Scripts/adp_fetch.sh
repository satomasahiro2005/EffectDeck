#!/bin/bash
# 公証が通った版の ADP（Alternative Distribution Package）を落とし、置ける形にする。
#
#   bash Scripts/adp_fetch.sh <version-id> [置き場]     置き場の既定は ~/work/adp
#
# 版の ID は python3 Tools/asc.py versions の 1 列目（Scripts/notarize.sh も最後に出す）。
# 手順は docs/altstore/README.md の「ADP」節のとおり:
#   1. asc.py adp-url で zip の URL を取る。ASC が直接くれる（accessKey 付きで 2 日で切れる）。
#      **api.altstore.io/adps/<ADP ID> は使わない。**ASC の ID を渡すと 404 が返る。
#      前の形はそこを叩いていたうえ、版の ID を 2.9.0 のものに決め打ちしていた
#   2. 落として展開する。中身は manifest.json と signature の 2 つだけ
#   3. manifest.json が相対で指す variant/<publicId>.ipa を asc.py adp-variants の URL から
#      落とし、sha256 が ASC の fileChecksum と一致するか見る
#   4. 置くのは Windows 側の Tools/adp_place.py。**manifest.json は一切いじらない**
#      （各ファイルのハッシュが書いてあるので、1 バイト変えると使えなくなる）
#
# App Store Connect を叩くだけなので ssh から走らせてよい（鍵は Mac にしか無い）。
set -u
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"
V="${1:?版の ID（python3 Tools/asc.py versions の 1 列目）}"
OUT="${2:-$HOME/work/adp}"

asc() { python3 "$REPO/Tools/asc.py" "$@"; }

mkdir -p "$OUT" || exit 1
cd "$OUT" || exit 1

echo "=== 1. ADP の zip の URL ==="
URL=$(asc adp-url "$V") || {
  echo "!! ADP がまだ無いか、COMPLETED の版が無い。公証が通っているか確かめる"
  exit 1
}
echo "$URL" | sed 's/accessKey=[^&]*/accessKey=.../'

echo "=== 2. 落として展開する ==="
rm -rf pkg pkg.zip
mkdir pkg
curl -fsSL "$URL" -o pkg.zip || { echo "!! 落とせない（URL は 2 日で切れる）"; exit 1; }
unzip -q -o pkg.zip -d pkg || { echo "!! 展開できない"; exit 1; }
MANIFEST=$(find pkg -name manifest.json | head -1)
[ -n "$MANIFEST" ] || { echo "!! manifest.json が無い"; exit 1; }
ROOT=$(dirname "$MANIFEST")
find pkg -type f | sed 's/^/  /'

echo "=== 3. 変種を落として sha256 を見る ==="
asc adp-show "$V" > adp-show.txt || { echo "!! asc.py adp-show が落ちた"; exit 1; }
asc adp-variants "$V" > variants.tsv || { echo "!! asc.py adp-variants が落ちた"; exit 1; }
[ -s variants.tsv ] || { echo "!! 変種が 1 つも無い"; exit 1; }
mkdir -p "$ROOT/variant"
bad=0
n=0
while IFS=$'\t' read -r id vurl; do
  [ -n "$id" ] || continue
  n=$((n + 1))
  f="$ROOT/variant/$id.ipa"
  # manifest.json が指していない名前で置くと、その ADP は入れられない（sha256 が合っていても）。
  if ! grep -qF "variant/$id.ipa" "$MANIFEST"; then
    echo "!! manifest.json に variant/$id.ipa が見えない（asc.py adp-variants の 1 列目が manifest の名前と違う）"
    bad=1
  fi
  if ! curl -fsSL "$vurl" -o "$f"; then
    echo "!! 落とせない: $id"
    bad=1
    continue
  fi
  got=$(shasum -a 256 "$f" | awk '{ print tolower($1) }')
  want=$(grep "variant $id " adp-show.txt \
    | sed -n 's/.*"fileChecksum": "\([0-9a-fA-F]*\)".*/\1/p' | head -1 | tr 'A-F' 'a-f')
  if [ -z "$want" ]; then
    echo "!! $id の fileChecksum が adp-show.txt から読めない"
    bad=1
  elif [ "$got" != "$want" ]; then
    echo "!! sha256 が違う: $id"
    echo "   落としたもの $got"
    echo "   ASC          $want"
    bad=1
  else
    echo "  一致 $got  $id.ipa ($(wc -c < "$f" | tr -d ' ') bytes)"
  fi
done < variants.tsv
[ "$bad" = 0 ] || { echo "!! 変種を揃えられなかった。置かないこと"; exit 1; }

echo "=== 4. 置く（Windows 側） ==="
echo "  $OUT/pkg を階層のまま Windows へ写してから:"
echo "  python Tools/adp_place.py <写した pkg> <版> <ビルド番号> <日付>"
echo "  （変種 $n 本。new-nemutai を commit して push すると Cloudflare へ出る）"
