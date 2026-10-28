#!/bin/bash
# MiniMeters の速さを Mac で測って、結果を Tools/MiniMetersBench/results/<label>.md/.tsv に持ち帰る。
#
#   bash Tools/MiniMetersBench/run.sh <label> [--runs 2] [--canvas plain|cv] [--rounds 22]
#
# 例: bash Tools/MiniMetersBench/run.sh baseline-cee1267
#
# やること（数分）:
#   1. 測るのに要るファイルだけ Mac の ~/work/minimeters-bench/src へ送る（改行を LF にそろえ、送った先の sha256 を突き合わせる）
#   2. Mac で swiftc -O を建てる（xcodebuild は使わない）
#   3. --runs 回、別プロセスで測る（全体の版 → 区画の版 の順）
#   4. Mac の python3 で md と tsv にまとめ、results/ へ取り戻す
#
# 環境変数: MAC（既定 satoumasahiro@100.77.178.77。Tailscale 側を先に）
# Mac の上で直接やるときは、build.sh <根> <出力先> と bench_total / bench_seam を手で叩く（README 参照）。
# 注意: 省電力モードと電池駆動は結果が変わる。冒頭の記録に出るので、前後を比べるときは条件をそろえる。
set -euo pipefail

LABEL="${1:?label（例: baseline-cee1267）}"
shift || true
RUNS=2; CANVAS=plain; ROUNDS=22
while [ $# -gt 0 ]; do
    case "$1" in
        --runs) RUNS="$2"; shift 2 ;;
        --canvas) CANVAS="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        *) echo "知らない引数: $1" >&2; exit 2 ;;
    esac
done
case "$LABEL" in *[!A-Za-z0-9._-]*) echo "label は英数字と ._- だけ" >&2; exit 2 ;; esac

MAC="${MAC:-satoumasahiro@100.77.178.77}"
SSH=(ssh -o BatchMode=yes -o IdentitiesOnly=yes "$MAC")
REMOTE='$HOME/work/minimeters-bench'

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# 測る対象（リポジトリのものをそのまま）と、道具。
TARGETS=(Sources/EffeTuneLive/Views/MiniMeters.swift Sources/Shared/ETMeterTap.c Sources/Shared/ETMeterTap.h)
TOOLS=(Tools/MiniMetersBench/main.swift Tools/MiniMetersBench/bridge.h Tools/MiniMetersBench/build.sh Tools/MiniMetersBench/report.py Tools/MiniMetersBench/snap.sh)

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
for f in "${TARGETS[@]}" "${TOOLS[@]}"; do
    mkdir -p "$STAGE/src/$(dirname "$f")"
    sed 's/\r$//' "$f" > "$STAGE/src/$f"      # Windows の CRLF を LF に（git の中身と同じ）
done

# --- 記録（どの版を測ったか）
{
    echo "label        $LABEL"
    echo "measured_at  $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "git_head     $(git rev-parse --short HEAD)  $(git log -1 --format=%s | cut -c1-60)"
    if git diff --quiet HEAD -- "${TARGETS[@]}"; then
        echo "targets      HEAD と同じ（未コミットの変更なし）"
    else
        echo "targets      **HEAD から変更あり**（未コミットの差分を測った）"
    fi
    for f in "${TARGETS[@]}"; do
        echo "sha256       $(sha256sum "$STAGE/src/$f" | cut -c1-16)  $f"
    done
    echo "settings     runs=$RUNS rounds=$ROUNDS block=30 discard=2 warm=180 canvas=$CANVAS"
} > "$STAGE/meta_local.txt"

# --- 送る
"${SSH[@]}" "rm -rf $REMOTE/src $REMOTE/raw $REMOTE/build && mkdir -p $REMOTE/src $REMOTE/raw"
tar -C "$STAGE/src" -cf - . | "${SSH[@]}" "tar -C $REMOTE/src -xf -"

# 送った先のハッシュが手元の LF 版と同じことを確かめる（違えば別の物を測ってしまう）。
for f in "${TARGETS[@]}"; do
    want="$(sha256sum "$STAGE/src/$f" | cut -d' ' -f1)"
    got="$("${SSH[@]}" "shasum -a 256 $REMOTE/src/$f" | cut -d' ' -f1)"
    [ "$want" = "$got" ] || { echo "ハッシュが合わない: $f" >&2; exit 1; }
done

# --- 建てる
"${SSH[@]}" "cd $REMOTE && bash src/Tools/MiniMetersBench/build.sh src build"

# --- Mac の状態の記録
"${SSH[@]}" "{
    echo \"machine      \$(sysctl -n machdep.cpu.brand_string) / \$(sysctl -n hw.model) / macOS \$(sw_vers -productVersion)\"
    echo \"swift        \$(swiftc --version 2>&1 | head -1)\"
} > $REMOTE/raw/meta_remote.txt"

# --- 測る（前後で Mac の条件を記録し、途中で電源・省電力モードが変わったら警告する）
SNAP="bash $REMOTE/src/Tools/MiniMetersBench/snap.sh"
{ echo "conditions   (電源・省電力モード・CPU の空き)"; } >> "$STAGE/meta_runs.txt"
FIRST_KEY=""; CHANGED=0
for i in $(seq 1 "$RUNS"); do
    echo "== run $i / $RUNS"
    before="$("${SSH[@]}" "$SNAP")"
    for build in total seam; do
        "${SSH[@]}" "cd $REMOTE && ./build/bench_$build raw/run${i}_$build.tsv --rounds $ROUNDS --canvas $CANVAS"
    done
    after="$("${SSH[@]}" "$SNAP")"
    echo "run$i before: $before  |  after: $after" | tee -a "$STAGE/meta_runs.txt"
    for snap in "$before" "$after"; do
        key="$(echo "$snap" | cut -d' ' -f1,2)"
        [ -n "$FIRST_KEY" ] || FIRST_KEY="$key"
        [ "$key" = "$FIRST_KEY" ] || CHANGED=1
    done
done
if [ "$CHANGED" = 1 ]; then
    echo "warning      **測定の途中で電源か省電力モードが変わった。run どうしの差を信用するな（やり直す）**" >> "$STAGE/meta_runs.txt"
    echo "!! 途中で電源か省電力モードが変わった" >&2
fi

# --- まとめて持ち帰る
cat "$STAGE/meta_local.txt" "$STAGE/meta_runs.txt" | "${SSH[@]}" "cat > $REMOTE/raw/meta_local.txt"
"${SSH[@]}" "cd $REMOTE && cat raw/meta_local.txt raw/meta_remote.txt > raw/meta.txt && rm -rf results && python3 src/Tools/MiniMetersBench/report.py --label '$LABEL' --meta raw/meta.txt --raw raw --out results"
mkdir -p "$ROOT/Tools/MiniMetersBench/results"
"${SSH[@]}" "cd $REMOTE/results && tar -cf - '$LABEL.md' '$LABEL.tsv'" | tar -C "$ROOT/Tools/MiniMetersBench/results" -xf -
echo "done: Tools/MiniMetersBench/results/$LABEL.md / .tsv"
