#!/bin/bash
# 出荷する形（Release の書庫・ipa）を、実機へ入れる前・アップロードの前に確かめる。
#
#   bash Scripts/archive.sh && bash Scripts/check_release_binary.sh     紫の書庫（${ARCHIVE_DIR:-/tmp}/EffeTuneLive.xcarchive）
#   bash Scripts/check_release_binary.sh path/to/EffectDeck.ipa        書き出した ipa（get-task-allow も見る）
#   bash Scripts/check_release_binary.sh --flavor store build/Release.xcarchive   CI（署名なし）
#
# 中身は Tools/check_release_binary.py（stdlib だけ）。何を見るかはその頭に書いてある。
# 364f940（dlsym で引いていた自分の口が strip で消え、資産を使う 7 種が出荷版で全部動かなかった）の再発よけ。
# **strip されていない .app（plain build・Debug）を渡すと落ちる。**それを見て通っても何も言えないから。
#
# 読むだけなので ssh からでも走る（codesign -d は鍵を使わない）。Mac では xcrun の nm と codesign で
# 自前の読み取りを突き合わせる。結果は release-check.log にも残す（RELEASE_CHECK_LOG で変えられる）。
# 終了値: 0 = 全部通った、1 = FAIL がある、2 = 渡したものが読めない。
set -u
export PATH="/opt/homebrew/bin:$PATH"   # Homebrew の python3 があれば先に使う。3.7 以上なら /usr/bin/python3 でよい
# cd はしない。渡したパスは走らせた場所から読む。
ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 2
LOG="${RELEASE_CHECK_LOG:-$ROOT/release-check.log}"
if ! command -v python3 > /dev/null 2>&1; then
  echo "!! python3 が無い" >&2
  exit 2
fi
# subprocess.run(capture_output=…) が 3.7 から。
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 7))'; then
  echo "!! python3 が $(python3 -V 2>&1)。3.7 以上が要る" >&2
  exit 2
fi
python3 "$ROOT/Tools/check_release_binary.py" "$@" 2>&1 | tee "$LOG"
exit "${PIPESTATUS[0]}"
