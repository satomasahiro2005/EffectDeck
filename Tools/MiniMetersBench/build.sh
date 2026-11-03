#!/bin/bash
# MiniMeters の速さ測定機を建てる。macOS で動く（swiftc と clang だけ。xcodebuild は使わない）。
#
#   bash build.sh <リポジトリの根> <出力先>
#
# 建てるもの:
#   <出力先>/bench_total  リポジトリの MiniMeters.swift をそのまま -O で建てた版（本番と同じコード）。
#   <出力先>/bench_seam   同じファイルから「private を外しただけ」の写しを毎回作って建てた版。
#                         区画ごとの時間を直に計るための覗き窓。**元のファイルは書き換えない。**
#                         写しは建てるたびに元から作り直すので古びない。
#
# 建て方は project.yml に揃える: Swift 5 モード・-O・全体最適化、C は -Os（GCC_OPTIMIZATION_LEVEL s）。
set -euo pipefail

ROOT="$(cd "${1:?リポジトリの根}" && pwd)"
OUT="${2:?出力先}"
HERE="$ROOT/Tools/MiniMetersBench"
MM="$ROOT/Sources/EffeTuneLive/Views/MiniMeters.swift"
TAP="$ROOT/Sources/Shared/ETMeterTap.c"
mkdir -p "$OUT"

clang -Os -std=gnu11 -c "$TAP" -I"$ROOT/Sources/Shared" -o "$OUT/ETMeterTap.o"

SWIFT_COMMON=(-O -wmo -swift-version 5 -import-objc-header "$HERE/bridge.h" -Xcc -I"$ROOT/Sources/Shared")

swiftc "${SWIFT_COMMON[@]}" "$HERE/main.swift" "$MM" "$OUT/ETMeterTap.o" -o "$OUT/bench_total"

# 覗き窓: 区画ごとの描き関数と、写し元の持ち物の private だけを外す。中身は 1 字も変えない。
SEAM_SWIFT="$OUT/MiniMeters_seam.swift"
sed -E \
    -e 's/private func (copyBackdrop|drawWaveform|drawSpectrum|drawStereo|drawLevels|advanceSpectrogram)\(/func \1(/' \
    -e 's/private var (backdrop|spectrogram): /var \1: /' \
    -e 's/private let (spectrogramWidth|spectrogramHeight): /let \1: /' \
    "$MM" > "$SEAM_SWIFT"
changed="$(diff "$MM" "$SEAM_SWIFT" | grep -c '^<' || true)"
if [ "$changed" != "10" ]; then
    echo "覗き窓の書き換えが 10 行でなく ${changed} 行。MiniMeters.swift の名前が変わった（build.sh の sed を直す）" >&2
    exit 1
fi
swiftc "${SWIFT_COMMON[@]}" -DSEAM "$HERE/main.swift" "$SEAM_SWIFT" "$OUT/ETMeterTap.o" -o "$OUT/bench_seam"
echo "built: $OUT/bench_total $OUT/bench_seam (seam: ${changed} 行の private を外した)"
