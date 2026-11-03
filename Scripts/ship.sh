#!/bin/bash
# 書庫 → 書き出し → App Store Connect へ上げる → 処理が終わるのを待つ。
# **版に結ぶのと、審査・公証へ出すのは本人がやる。**最後に次の手を出すだけ。
#
#   bash Scripts/ship.sh                        紫（TestFlight 行き。archive.sh が -configuration Beta）
#   APPICON=EffeTuneLive bash Scripts/ship.sh   青（店へ出す版。-configuration Release）
#   （構成名は archive.sh の CONFIG=Beta|Release でも選べる。ふだんの配布は GitHub Actions
#    〈.github/workflows/release.yml。tf-* のタグ→承認→TestFlight〉で、これはローカルの非常用。
#    Actions はビルド番号を毎回 ASC の最大 + 1 から決める（Tools/asc.py next-build）ので、
#    ここで上げた番号を取り違えない。ここは project.yml の CURRENT_PROJECT_VERSION で出すので、
#    ASC の最大より大きいことを自分で確かめる）
#   SKIP_ARCHIVE=1 bash Scripts/ship.sh         書庫は作り直さず、今ある書庫を書き出す
#   NO_WAIT=1 bash Scripts/ship.sh              上げたら終わり（処理待ちを飛ばす）
#
# **Mac の GUI セッションの Terminal から走らせる。**ssh から codesign を叩くと
# errSecInternalComponent で落ちる。キーチェーンを開けるのと検索リストを login だけに
# 絞るのは、呼ぶ側（Mac の ~/gui_*.sh のような台本）の仕事。ここではやらない。
# 画面のロックも解いておく（ロック中に最後まで通るかはまだ確かめていない）。
#
# いまの Mac の ~/gui_ship.sh はこれを呼ばず、archive.sh → 書き出し → altool を自前で
# 書いている（2026-09-27 に読んだ。検索リストは絞っていない）。手順は同じなので、
# 呼ぶ側は unlock と検索リストの後に `bash Scripts/ship.sh` だけにできる。
#
# GitHub Actions の release.yml も書き出しは同じ手動署名（Scripts/ExportOptions-ci.plist は
# ~/signing/export.plist と同じ中身。証明書は p12 の secret、プロファイルは Tools/asc.py profile）。
#
# 署名の準備は API キー（Scripts/asc_auth.sh）。書き出しの設定は ~/signing/export.plist
# （/tmp は再起動で消えるので置かない）。**鍵を渡すと書き出しがビルド番号を上げる**
# （書庫の 26 が 27 で出た）。止めたいときは export.plist に
# manageAppVersionAndBuildNumber=false を足す。だから待つビルド番号は ipa から読む。
#
# 輸出コンプライアンスは Info.plist の ITSAppUsesNonExemptEncryption=false で答えてある
# ので、ここでは立てない（値が既にあると API は 409 を返す。docs/altstore/README.md）。
#
# 前の形は、消えた第三者の asc コマンドと、2.9.0 の版の ID を決め打ちで使っていた。
# 版は日付になったので、版の ID は毎回 python3 Tools/asc.py versions で引く。
#
# 全出力は ship.log。最後の行は "=== SHIP FINISHED (exit=N) ==="。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
. Scripts/asc_auth.sh || exit 1   # KEY_ID / ISSUER / KEY と PROVISIONING

SCHEME=EffeTuneLive
ARCHIVE="${ARCHIVE_DIR:-/tmp}/$SCHEME.xcarchive"
EXPORT_DIR="${EXPORT_DIR:-/tmp/live-ipa}"
EXPORT_PLIST="$HOME/signing/export.plist"
IPA="$EXPORT_DIR/EffectDeck.ipa"
LOG="$PWD/ship.log"
# 名指しの道具。ET_XCODEBUILD・ET_PLISTBUDDY は Tests/Scripts/sim_test.sh が偽物を渡すための口。
XCODEBUILD="${ET_XCODEBUILD:-/usr/bin/xcodebuild}"
PLISTBUDDY="${ET_PLISTBUDDY:-/usr/libexec/PlistBuddy}"

main() {
  echo "=== start $(date) === icon=${APPICON:-EffectDeckPublicBeta}"

  [ -f "$EXPORT_PLIST" ] || {
    echo "!! $EXPORT_PLIST が無い（method=app-store-connect・プロファイル名を書いたもの）"
    return 1
  }

  if [ "${SKIP_ARCHIVE:-0}" = "1" ]; then
    echo "-- SKIP_ARCHIVE=1 なので今ある書庫を使う: $ARCHIVE"
  else
    echo "=== 書庫 $(date) ==="
    bash Scripts/archive.sh "$SCHEME" "${APPICON:-EffectDeckPublicBeta}"
    local acode=$?
    tail -n 12 archive.log
    [ "$acode" -eq 0 ] || { echo "!! 書庫に失敗した (exit $acode)。archive.log を読む"; return 1; }
  fi
  [ -d "$ARCHIVE" ] || { echo "!! 書庫が無い: $ARCHIVE"; return 1; }

  echo "=== 書き出し $(date) ==="
  rm -rf "$EXPORT_DIR"
  "$XCODEBUILD" -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    "${PROVISIONING[@]}" 2>&1 | grep -E "EXPORT SUCCEEDED|EXPORT FAILED|error:|errSec" | tail -5
  local ecode="${PIPESTATUS[0]}"
  if [ "$ecode" -ne 0 ] || [ ! -f "$IPA" ]; then
    echo "!! 書き出せなかった (exit $ecode)。画面のロックと、キーチェーンの検索リストを確かめる"
    return 1
  fi
  ls -lh "$IPA"

  # 書き出しがビルド番号を上げることがあるので、書庫ではなく ipa の中を読む。
  local plist build_num
  plist=$(mktemp)
  unzip -p "$IPA" "Payload/EffectDeck.app/Info.plist" > "$plist" 2>/dev/null
  build_num=$("$PLISTBUDDY" -c "Print :CFBundleVersion" "$plist" 2>/dev/null)
  rm -f "$plist"
  echo "ビルド番号: ${build_num:-(読めない)}"

  echo "=== 上げる $(date) ==="
  xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$KEY_ID" --apiIssuer "$ISSUER" 2>&1 \
    | grep -E "UPLOAD SUCCEEDED|Delivery UUID|ERROR|error" | tail -5
  local ucode="${PIPESTATUS[0]}"
  [ "$ucode" -eq 0 ] || { echo "!! 上げられなかった (exit $ucode)"; return 1; }

  if [ "${NO_WAIT:-0}" = "1" ] || [ -z "$build_num" ]; then
    [ -n "$build_num" ] || echo "-- ビルド番号が読めないので処理は待たない"
    next_steps "${build_num:-<ビルド番号>}" "<build-id>"
    return 0
  fi

  echo "=== 処理を待つ（最大 20 分） $(date) ==="
  local line="" state="" build_id=""
  for _ in $(seq 1 60); do
    sleep 20
    line=$(python3 Tools/asc.py builds 2>/dev/null \
      | awk -v n="$build_num" '$2 == "build" && $3 == n { print $1, $4; exit }')
    state="${line#* }"
    build_id="${line%% *}"
    case "$state" in
      VALID) break ;;
      INVALID|FAILED) echo "!! build $build_num が $state になった"; return 1 ;;
    esac
  done
  [ "$state" = "VALID" ] || { echo "!! build $build_num の処理が 20 分で終わらない（いま: ${state:-見えない}）"; return 1; }
  echo "build $build_num = $build_id (VALID)"
  next_steps "$build_num" "$build_id"
  return 0
}

next_steps() {
  echo
  echo "=== 次の手（本人が撃つ） ==="
  echo "  版の ID を引く:          python3 Tools/asc.py versions"
  echo "  版に結ぶ:                python3 Tools/asc.py attach <version-id> $2"
  echo "  AltStore の公証へ出す:   bash Scripts/notarize.sh <版> $1"
}

main > "$LOG" 2>&1
CODE=$?
echo "=== SHIP FINISHED (exit=$CODE) ===" >> "$LOG"
tail -n 8 "$LOG"
exit "$CODE"
