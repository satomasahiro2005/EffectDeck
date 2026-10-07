#!/usr/bin/env bash
# Tests/Fuzz/replay.sh
# libFuzzer の的を、入力 1 つずつ 1 度だけ通す（変異なし）。docs/jsfx-regvm-design.md §12.6 の
# 「corpus の再生」。arm64 の Linux（FMA 縮約・fcvtzs の飽和が端末と同じ）でも走るので、x86-64 では
# 出ない縮約の食い違いを、育った corpus 全部で確かめられる。
#
#   bash Tests/Fuzz/replay.sh [--out <落ちた入力の置き場>] [--time <秒>] <的の実行ファイル> <入力のファイルかフォルダ>...
#
#   的の実行ファイル  run.sh --build-only が建てたもの（~/.cache/effectdeck-fuzz/<名前>/native/jsfx_vmdiff か jsfx_exec）
#   --out             落ちた入力を写す先（既定 build/fuzz-replay）
#   --time            1 入力の持ち時間（秒、既定 10。run.sh の jsfxexec・jsfxvmdiff と同じ）。
#                     時間切れは落ちと数えない（数だけ出す。止まらないスクリプトが入りうる的）
# 終了値: 落ちた入力が 1 つでもあれば 1、無ければ 0。
# 1 入力 1 プロセスなので、落ちた入力がそのままファイル名で分かる。並列は REPLAY_JOBS（既定は nproc）。
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
out="$repo/build/fuzz-replay"
seconds=10
die() { echo "replay.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --out) [ $# -ge 2 ] || die "--out に値が無い"; out=$2; shift 2 ;;
    --time) [ $# -ge 2 ] || die "--time に値が無い"; seconds=$2; shift 2 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) die "知らない引数: $1" ;;
    *) break ;;
  esac
done
[[ $seconds =~ ^[0-9]+$ ]] || die "--time は秒の整数: $seconds"
[ $# -ge 2 ] || die "的の実行ファイルと入力が要る（--help）"
bin=$1; shift
[ -x "$bin" ] || die "的の実行ファイルが無い: $bin"

export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:allocator_may_return_null=1}"
supp=${FUZZ_UBSAN_SUPPRESSIONS-$here/Native/jsfx_exec.ubsan.supp}
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}${supp:+:suppressions=$supp}"
export SWIFT_BACKTRACE="${SWIFT_BACKTRACE:-enable=no}"
export REPLAY_BIN=$bin REPLAY_SECONDS=$seconds REPLAY_OUT=$out

mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
list="$work/inputs"
: > "$list"
for p in "$@"; do
  if [ -d "$p" ]; then find "$p" -type f -print0 >> "$list"
  elif [ -f "$p" ]; then printf '%s\0' "$p" >> "$list"
  else echo "replay.sh: 無いので飛ばす: $p" >&2
  fi
done
total=$(tr -cd '\0' < "$list" | wc -c)
echo "== replay $(basename "$bin"): ${total} 入力, ${seconds}s ずつ, 並列 ${REPLAY_JOBS:-$(nproc)}"
[ "$total" -gt 0 ] || { echo "== REPLAY $(basename "$bin"): inputs 0, ok 0, timeouts 0, failed 0"; exit 0; }

# 1 入力: 0 = 通った、70 = 時間切れ、それ以外 = 落ち。落ちた入力は out に写して理由の頭を出す。
one() {
  local f=$1 log status
  log=$(mktemp)
  set +e
  "$REPLAY_BIN" -max_len=16384 -timeout="$REPLAY_SECONDS" -rss_limit_mb=3072 "$f" > "$log" 2>&1
  status=$?
  set -e
  case $status in
    0) echo ok ;;
    70) echo timeout; echo "replay: timeout $f" >&2 ;;
    *)
      echo fail
      cp -- "$f" "$REPLAY_OUT/fail-$(sha1sum < "$f" | cut -c1-40)"
      { echo "replay: FAIL (exit $status) $f"
        grep -m 12 -E "fuzz oracle|ERROR: |SUMMARY|runtime error|Fatal error" "$log" || tail -n 8 "$log"
      } >&2 ;;
  esac
  rm -f "$log"
}
export -f one

results="$work/results"
set +e
xargs -0 -a "$list" -P "${REPLAY_JOBS:-$(nproc)}" -I{} bash -c 'one "$1"' _ {} > "$results"
set -e
ok=$(grep -c '^ok$' "$results" || true)
timeouts=$(grep -c '^timeout$' "$results" || true)
fails=$(grep -c '^fail$' "$results" || true)
echo "== REPLAY $(basename "$bin"): inputs ${total}, ok ${ok}, timeouts ${timeouts}, failed ${fails}"
if [ "$((ok + timeouts + fails))" != "$total" ]; then
  echo "== REPLAY: 数が合わない（${total} に対し $((ok + timeouts + fails))）。xargs が途中で止まった" >&2
  exit 1
fi
[ "$fails" = 0 ] || { echo "== REPLAY failed: inputs in ${out}"; exit 1; }
