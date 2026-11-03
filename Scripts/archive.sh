#!/bin/bash
# 配布用の書庫を作る。
#
#   bash Scripts/archive.sh                            紫（-configuration Beta。TestFlight 行き。ET_BETA）
#   bash Scripts/archive.sh EffeTuneLive EffeTuneLive  青（-configuration Release。店へ出す版）
#   CONFIG=Release bash Scripts/archive.sh             同上（構成名で直接選ぶ）
#
# ふだんの配布は GitHub Actions（.github/workflows/release.yml。tf-* のタグで Beta、
# 手動で store）で、そこもこのスクリプトを呼ぶ（ad-hoc 署名で）。ローカルの非常用は Scripts/ship.sh。
# どちらも project.yml の同じ構成（Beta / Release）を読む。
#
# 環境変数（どれも省略できる）:
#   ET_BUILD_NUMBER=N      ビルド番号（CURRENT_PROJECT_VERSION）をコマンドラインで上書きする。
#                          release.yml が ASC の最大 + 1 を渡す（コミットはしない）。数字だけ。
#   ET_XCODEBUILD_LOG=path xcodebuild の出力を丸ごとそこへも残す（archive.log は絞った行だけ）。
#   ET_ARCHIVE_ADHOC=1     書庫を ad-hoc 署名（-）で作る。release.yml はいつもこれ。GitHub の runner には
#                          開発用証明書の秘密鍵が無く、自動署名だと毎回 "Created via API" の証明書が
#                          増えるため。権限（entitlements）は ad-hoc 署名にも埋まり、書き出し
#                          （Scripts/ExportOptions-ci.plist の手動署名。配布用証明書とプロファイルは
#                          release.yml が用意する）が配布用に署名し直す。
#                          このときは -allowProvisioningUpdates と API キーを xcodebuild に渡さない。
#                          署名なし（CODE_SIGNING_ALLOWED=NO）にしない。書き出しが権限をプロファイルから
#                          取り、本体の media-device-extension の空配列が消える。
#
# 先に Scripts/setup.sh を通す（パッチ・カタログ・プリセット・note-models・版・プロジェクト）。
# 前は gen_version と xcodegen しか走らせず、書庫が正しいかは、前のビルドが木を
# 整えていたかどうか次第だった。
#
# 書庫は $ARCHIVE_DIR/<scheme>.xcarchive（既定 /tmp。Scripts/ship.sh と archive_install.sh、
# Mac の ~/gui_ship.sh がそこを読む）。前の書庫は**真っ先に**消す（setup.sh より前）。
# 残っていると、setup.sh や書庫で落ちても古い書庫が書き出されたり実機に入ったりする。
#
# 全部 archive.log へ。判定は "ARCHIVE SUCCEEDED" の行と、このスクリプトの終了値。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
. Scripts/asc_auth.sh || exit 1   # PROVISIONING（API キー）。画面ロック中の "No Accounts" よけ
SCHEME="${1:-EffeTuneLive}"
# ビルド構成で決める。**アイコンと ET_BETA は project.yml の構成（Beta / Release）が持つ**
# ので、ここでは構成名を選ぶだけ。GitHub Actions もローカルも同じ定義を読む。
#   Beta     紫（EffectDeckPublicBeta）＋ ET_BETA。TestFlight 行き。**既定**。
#            端末で青と紫を見分けられると、いまどちらを触っているか分かる。
#   Release  青（EffeTuneLive）。店へ出す版。
# 選び方は環境変数 CONFIG=Beta|Release、または第 2 引数（従来のアイコン名）。
#   EffectDeckPublicBeta -> Beta、EffeTuneLive -> Release。それ以外は xcodebuild を呼ばずに落とす。
# 起動時に setAlternateIconName で差し替える形にしないのは、系が毎回
# 「アイコンを変えました」の確認を出すから。
# いま ET_BETA で変わるのは同梱の JSFX の見本（ETJSFXHost.showsBundledSamples）だけ。
# 見本を .app に積むかも同じ構成で決まる（Scripts/embed_debug_jsfx.sh が
# SWIFT_ACTIVE_COMPILATION_CONDITIONS を読む）。JSFX 本体は店の版でも開いている
# （ETJSFXHost.isEnabled）。店に出さない機能を足すときは Beta 構成の側で開ける。
APPICON="${2:-EffectDeckPublicBeta}"
if [ -n "${CONFIG:-}" ]; then
  case "$CONFIG" in
    Beta|Release) ;;
    *) echo "FINISHED: CONFIG は Beta か Release（受け取った値: ${CONFIG}）。書庫は作らない (exit=2)"; exit 2 ;;
  esac
else
  case "$APPICON" in
    EffectDeckPublicBeta) CONFIG=Beta ;;
    EffeTuneLive)         CONFIG=Release ;;
    *) echo "FINISHED: 第 2 引数は EffectDeckPublicBeta か EffeTuneLive（受け取った値: ${APPICON}）。書庫は作らない (exit=2)"; exit 2 ;;
  esac
fi
# ビルド番号の上書き。数字以外は xcodebuild を呼ばずに落とす。
BUILD_ARGS=()
if [ -n "${ET_BUILD_NUMBER:-}" ]; then
  case "$ET_BUILD_NUMBER" in
    *[!0-9]*) echo "FINISHED: ET_BUILD_NUMBER は数字だけ（受け取った値: ${ET_BUILD_NUMBER}）。書庫は作らない (exit=2)"; exit 2 ;;
  esac
  BUILD_ARGS=("CURRENT_PROJECT_VERSION=$ET_BUILD_NUMBER")
fi
if [ "${ET_ARCHIVE_ADHOC:-0}" = "1" ]; then
  BUILD_ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES
               PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM=C82ST8T9MN)
  # ad-hoc は開発者サイトに用が無い。-allowProvisioningUpdates も API キーも渡さず、
  # Apple 側に証明書やプロファイルを作らせる道を残さない。
  PROVISIONING=()
fi
LOG="$PWD/archive.log"
ARCHIVE="${ARCHIVE_DIR:-/tmp}/$SCHEME.xcarchive"
# xcodebuild は名指し。ET_XCODEBUILD は Tests/Scripts/sim_test.sh が偽物を渡すための口。
XCODEBUILD="${ET_XCODEBUILD:-/usr/bin/xcodebuild}"

main() {
  echo "=== start $(date) === config=$CONFIG"
  rm -rf "$ARCHIVE"
  # setup.sh が gen_version と xcodegen（project.yml）まで走らせる。
  bash Scripts/setup.sh || { echo "!! Scripts/setup.sh が落ちた。書庫は作らない"; return 1; }
  "$XCODEBUILD" -project EffeTuneLive.xcodeproj -scheme "$SCHEME" \
    -configuration "$CONFIG" -sdk iphoneos -arch arm64 ${PROVISIONING[@]+"${PROVISIONING[@]}"} \
    archive -archivePath "$ARCHIVE" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} 2>&1 \
    | tee "${ET_XCODEBUILD_LOG:-/dev/null}" \
    | grep -E "error:|ARCHIVE SUCCEEDED|ARCHIVE FAILED|errSec" | tail -10
  local code="${PIPESTATUS[0]}"
  [ "$code" -eq 0 ] || { echo "!! xcodebuild archive が落ちた (exit $code)"; return 1; }
  echo "書庫: $ARCHIVE"
  echo "=== done $(date) ==="
  return 0
}

main > "$LOG" 2>&1
CODE=$?
echo "FINISHED: $LOG (exit=$CODE)"
exit "$CODE"
