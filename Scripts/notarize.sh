#!/bin/bash
# 上げ終わったビルドを AltStore PAL 用の公証（iOS の Notarization）へ出す。
# macOS の公証（notarytool）とは別物。
#
#   bash Scripts/notarize.sh 2026.09.27 31     版の文字列とビルド番号
#
# 先に書庫 → 書き出し → 上げるを済ませておくこと（Scripts/ship.sh か、Mac の ~/gui_ship.sh）。
# ここは App Store Connect を叩くだけなので ssh から走らせてよい（鍵は Mac にしか無い）。
# 手順の出どころは docs/altstore/README.md。
#
# **版は使い回せない。** READY_FOR_DISTRIBUTION になった版へ別のビルドを
# 結びつけようとすると 409 ENTITY_ERROR.RELATIONSHIP.INVALID.INVALID_STATE。
# だから毎回新しい版を作る（Tools/asc.py new-version が reviewType=NOTARIZATION で作る）。
# 版は日付（MARKETING_VERSION と同じ形）。
set -u
cd "$(dirname "$0")/.." || exit 1

VERSION="${1:?版の文字列（2026.09.27 など）}"
BUILD_NUMBER="${2:?ビルド番号（31 など）}"
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
# Info.plist で ITSAppUsesNonExemptEncryption=false を答えてある。値が既にあると
# 409（You cannot update when the value is already set.）が返るので、失敗しても先へ進む。
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
echo "承認されたら: bash Scripts/adp_fetch.sh $VERSION_ID"
