#!/bin/bash
# 上げ終わったビルドを公証へ出す。
#
#   bash Scripts/notarize.sh 2.9.1 11
#
# 先に書庫→書き出し→上げるを済ませておくこと（~/gui_ship.sh）。
# ここは App Store Connect を叩くだけなので ssh から走らせてよい。
#
# **版は使い回せない。** READY_FOR_DISTRIBUTION になった版へ別のビルドを
# 結びつけようとすると 409 ENTITY_ERROR.RELATIONSHIP.INVALID.INVALID_STATE。
# だから毎回 versionString を上げて、新しい版を作る（Tools/gen_version.py の頭）。
set -u
cd "$(dirname "$0")/.." || exit 1

VERSION="${1:?版の文字列（2.9.1 など）}"
BUILD_NUMBER="${2:?ビルド番号（11 など）}"
ASC="python3 Tools/asc.py"

echo "=== 上げたビルドを待つ ==="
BUILD_ID=""
for _ in $(seq 1 60); do
  BUILD_ID=$($ASC builds 2>/dev/null \
    | awk -v n="$BUILD_NUMBER" '$3 == n && $4 == "VALID" { print $1; exit }')
  [ -n "$BUILD_ID" ] && break
  sleep 20
done
[ -n "$BUILD_ID" ] || { echo "!! build $BUILD_NUMBER が VALID にならない"; exit 1; }
echo "build $BUILD_NUMBER = $BUILD_ID"

echo "=== 輸出コンプライアンス ==="
# 一度立てると二度目は 409（You cannot update when the value is already set.）。
# 失敗しても先へ進む。
$ASC encryption "$BUILD_ID" 2>&1 | tail -1

echo "=== 版 ==="
VERSION_ID=$($ASC versions 2>/dev/null | awk -v v="$VERSION" '$2 == v { print $1; exit }')
if [ -z "$VERSION_ID" ]; then
  VERSION_ID=$($ASC new-version "$VERSION") || exit 1
  echo "作った $VERSION = $VERSION_ID"
else
  echo "既にある $VERSION = $VERSION_ID"
fi

echo "=== 結びつける ==="
$ASC attach "$VERSION_ID" "$BUILD_ID" || exit 1

echo "=== 公証へ出す ==="
$ASC submit "$VERSION_ID" || exit 1

echo "=== いま ==="
$ASC version "$VERSION_ID"
echo
echo "承認されたら: python3 Tools/asc.py adp-url $VERSION_ID"
