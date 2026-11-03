#!/usr/bin/env bash
# Tools/golden/extract_pin.sh
# 上流（Vendor/effetune）を、このリポジトリが指している版（HEADのgitlink）のまま一時置き場へ展開し、
# そのフォルダを1行で出す。見本（Tools/golden/*.mjs）はここを EFFETUNE_ROOT にして作る。
#
#   root=$(bash Tools/golden/extract_pin.sh [置き場])
#   EFFETUNE_ROOT="$root" node Tools/golden/<area>_golden.mjs
#
# **作業ツリーのVendor/effetuneは読まない。**setup.shのパッチや別の版のcheckoutが混ざっていても、
# git archiveはコミットの中身だけを出すので、見本は指している版と一致する。
# 置き場は第1引数、無ければ $EFFETUNE_PIN_DIR、それも無ければ ${TMPDIR:-/tmp}。
# 同じ版が展開済みならそのまま使う（.pin に版を書いておき、合わなければ作り直す）。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
rev=$(git -C "$repo" ls-tree HEAD Vendor/effetune | awk '$2 == "commit" { print $3 }')
[ -n "$rev" ] || { echo "extract_pin.sh: HEADにVendor/effetuneのgitlinkが無い" >&2; exit 2; }

if ! git -C "$repo/Vendor/effetune" cat-file -e "$rev^{commit}" 2>/dev/null; then
  echo "extract_pin.sh: Vendor/effetuneに $rev が無い（git -C Vendor/effetune fetch origin $rev）" >&2
  exit 2
fi

parent=${1:-${EFFETUNE_PIN_DIR:-${TMPDIR:-/tmp}}}
dest="$parent/effetune-${rev:0:12}"
if [ -f "$dest/.pin" ] && [ "$(cat "$dest/.pin")" = "$rev" ]; then
  echo "$dest"
  exit 0
fi

rm -rf "$dest.tmp"
mkdir -p "$dest.tmp"
git -C "$repo/Vendor/effetune" archive --format=tar "$rev" | tar -x -C "$dest.tmp"
echo "$rev" > "$dest.tmp/.pin"
rm -rf "$dest"
mv "$dest.tmp" "$dest"
echo "$dest"
