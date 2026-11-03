#!/usr/bin/env bash
# Tests/Linux/run.sh
# Logicバンドル（project.ymlのEffeTuneLiveUnitTests）のうちFoundationだけのものを、
# Macを使わずLinux（WSL・CI）のswift testで走らせる。JSFX*TestsはysfxとMacが要るので入らない。
#
#   wsl bash Tests/Linux/run.sh --name <名前> [--add <path>...] [--filter <regex>]
#                               [--sanitize=address] [--clean] [-- <swift testへ渡すもの>]
#
#   --name      写し先 ~/.cache/effectdeck-linux/<名前>/ と、ログ build/linux-unit-<名前>.log。
#               並べて走らせるエージェントは別の名前にする（同じ.buildを取り合わない）
#   --add       project.ymlにまだ登録していないファイルやフォルダ（.swiftはソース、他は資源）。
#               wave 1ではproject.ymlを触れないので、足したものはここで渡す
#   --filter    swift test --filter
#   --sanitize  swift test --sanitize（address / thread / undefined）。addressのときLeakSanitizerは
#               切る（ASAN_OPTIONS=detect_leaks=0）。LinuxのFoundation・XCTestが自前で漏らす分
#               （Bundle(for:)、NSRegularExpression、expectation）で毎回落ちるため。
#               漏れも見たいときは ASAN_OPTIONS=detect_leaks=1 を付けて走らせる
#   --clean     写し先の.buildを消してから建てる
#
# 飛ばすテストはTests/Linux/skip.txt（LinuxのFoundationが違うものだけ、理由つき）。
# 要るもの: swift（swiftlyでもよい）、python3、zlibのヘッダ（Compressionの代役が使う）。
# WindowsのGit Bashから呼ぶときは MSYS_NO_PATHCONV=1 を付ける（/mnt/c/... を書き換えられる）。
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)

name=default
filter=
sanitize=
clean=0
adds=()
passthrough=()

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "run.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --name) [ $# -ge 2 ] || die "--name に値が無い"; name=$2; shift 2 ;;
    --name=*) name=${1#*=}; shift ;;
    --filter) [ $# -ge 2 ] || die "--filter に値が無い"; filter=$2; shift 2 ;;
    --filter=*) filter=${1#*=}; shift ;;
    --sanitize) [ $# -ge 2 ] || die "--sanitize に値が無い"; sanitize=$2; shift 2 ;;
    --sanitize=*) sanitize=${1#*=}; shift ;;
    --clean) clean=1; shift ;;
    --add)
      shift
      while [ $# -gt 0 ] && [[ $1 != -* ]]; do adds+=("$1"); shift; done ;;
    --) shift; passthrough=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) die "知らない引数: $1（--help）" ;;
  esac
done
[[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "--name は英数字と . _ - だけ: $name"

# swiftlyはログインシェルでないとPATHに入らない（wsl bash run.sh はログインシェルでない）。
if ! command -v swift >/dev/null 2>&1; then
  for env in "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" "$HOME/.swiftly/env.sh"; do
    # shellcheck disable=SC1090
    if [ -f "$env" ]; then . "$env"; break; fi
  done
fi
command -v swift >/dev/null 2>&1 || die "swift が無い"
command -v python3 >/dev/null 2>&1 || die "python3 が無い"

work="${EFFECTDECK_LINUX_CACHE:-$HOME/.cache/effectdeck-linux}/$name"
log="$repo/build/linux-unit-$name.log"
mkdir -p "$work" "$repo/build"
if [ "$clean" = 1 ]; then rm -rf "$work/.build"; fi

# --add は相対パスならリポジトリの根から。
add_args=()
if [ ${#adds[@]} -gt 0 ]; then add_args=(--add "${adds[@]}"); fi

args=(test --package-path "$work")
if [ -n "$filter" ]; then args+=(--filter "$filter"); fi
if [ -n "$sanitize" ]; then args+=("--sanitize=$sanitize"); fi
if [ "$sanitize" = address ]; then export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"; fi

{
  echo "== run.sh --name $name  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "== repo $repo  HEAD $(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "== $(swift --version 2>&1 | head -1)"
  echo "== work $work"
  if [ ${#adds[@]} -gt 0 ]; then echo "== add ${adds[*]}"; fi
} > "$log"

python3 "$here/make_package.py" --repo "$repo" --out "$work" "${add_args[@]}" 2>&1 | tee -a "$log"

skipped=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  skipped=$((skipped + 1))
  # swift test の識別子は Module.Class/method。
  if [[ $s == */* ]]; then args+=(--skip "\\.${s}\$"); else args+=(--skip "\\.${s}/"); fi
done < "$work/skip.txt"

echo "== swift ${args[*]} ${passthrough[*]:-}" | tee -a "$log"
set +e
swift "${args[@]}" "${passthrough[@]}" 2>&1 | tee -a "$log"
status=${PIPESTATUS[0]}
set -e

# 最後の行が全体の数（組ごとの行が先に出る）。飛ばしたものがあると "with 1 test skipped and 0 failures"
# になるので、そこも拾う。拾わないと飛ばした回は最後の組の数（2件など）を全体として出していた。
executed=$(grep -Eo "Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?" "$log" | tail -1 || true)
echo "== LINUX: ${executed:-no XCTest summary}; skip.txt ${skipped}; exit ${status}" | tee -a "$log"
echo "== log $log"
exit "$status"
