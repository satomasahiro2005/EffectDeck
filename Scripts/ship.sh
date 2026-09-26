#!/bin/bash
# 書庫から書き出して App Store Connect へ上げ、版に結びつける。
#
#   bash Scripts/ship.sh
#
# **macOS の画面のロックを解いてから走らせること。**
# ロックされているとログインキーチェーンが開かず、Xcode が Apple ID を
# 読めない（"No Accounts" / "Cloud signing permission error"）。
# 署名はクラウド管理なので、そこが開いていないと書き出せない。
# Mac に API キーがあれば Accounts の代わりにそれを渡す（Scripts/asc_auth.sh）。
# ロック中に最後まで通るかはまだ確かめていない。
#
# 先に Scripts/archive.sh を済ませておく（/tmp/EffeTuneLive.xcarchive）。
# 書き出しの設定は ~/signing/export.plist（/tmp は再起動で消えるので置かない）。
# **鍵を渡すと書き出しがビルド番号を上げる**（書庫の 26 が 27 で出た）。
# 止めたいときは export.plist に manageAppVersionAndBuildNumber=false を足す。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
. Scripts/asc_auth.sh || exit 1   # KEY_ID / ISSUER / KEY と PROVISIONING

APP=6812467517
VERSION_ID=51742091-f729-4a5a-8147-66077fa0164b
EXPORT_PLIST="$HOME/signing/export.plist"

export ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" ASC_PRIVATE_KEY_PATH="$KEY"

[ -f "$EXPORT_PLIST" ] || {
  echo "!! $EXPORT_PLIST が無い（method=app-store-connect・手動署名・プロファイル名を書いたもの）"
  exit 1
}

echo "=== 書き出し ==="
rm -rf /tmp/live-ipa
/usr/bin/xcodebuild -exportArchive \
  -archivePath /tmp/EffeTuneLive.xcarchive \
  -exportPath /tmp/live-ipa \
  -exportOptionsPlist "$EXPORT_PLIST" \
  "${PROVISIONING[@]}" 2>&1 | grep -E "EXPORT SUCCEEDED|EXPORT FAILED|error:" | tail -5

IPA="/tmp/live-ipa/EffectDeck.ipa"
[ -f "$IPA" ] || { echo "!! ipa が無い。画面のロックを解いたか確認する"; exit 1; }

echo "=== 上げる ==="
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER" 2>&1 | grep -E "UPLOAD SUCCEEDED|Delivery UUID|ERROR" | tail -3

echo "=== 処理を待つ ==="
BUILD=""
for _ in $(seq 1 60); do
  sleep 20
  BUILD=$(asc builds list --app "$APP" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for b in d.get('data', []):
    a=b['attributes']
    if a.get('processingState')=='VALID':
        print(b['id'], a.get('version')); break
" | head -1)
  [ -n "$BUILD" ] && break
done
[ -n "$BUILD" ] || { echo "!! 処理が終わらない"; exit 1; }
set -- $BUILD
BUILD_ID=$1; BUILD_NUM=$2
echo "build $BUILD_NUM ($BUILD_ID)"

echo "=== 輸出コンプライアンス ==="
asc builds update --build-id "$BUILD_ID" --uses-non-exempt-encryption false 2>&1 | head -1

echo "=== 版に結びつける ==="
asc versions attach-build --version-id "$VERSION_ID" --build-id "$BUILD_ID" 2>&1 | head -c 200
echo

echo "=== 残りを数える ==="
asc validate --app "$APP" --version-id "$VERSION_ID" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['summary'])
for s in d['remediation']['steps']:
    print(' ', s['severity'][:3], s['checkId'], '|', s['message'])
"
echo "=== done ==="
echo "審査へ出すには: asc review submit --app $APP --version 2.9.0 --build-id $BUILD_ID --confirm"
