#!/usr/bin/env bash
# Tools/jsfx-bench/run.sh
# JSFX の実行系を机の上で比べる（Mac・Linux。docs/jsfx-bench.md）。
#
#   bash Tools/jsfx-bench/run.sh [--seconds <秒>] [--scripts a,b] [--opt Os|O3|both] [--no-jit]
#                                [--label <名前>] [--build-only] [--clean] [--diff] [--profile]
#                                [--vm-dump [--vm-ir] [<file|dir> ...]] [--vm-opgrid]
#
#   --seconds    測る長さ（音の秒）。既定 5
#   --scripts    Debug/JSFXBench のうち回すもの（拡張子なし）。既定は全部
#   --opt        最適化の段。Os は Xcode の YSFX と同じ（Release / Beta の GCC_OPTIMIZATION_LEVEL の
#                既定。project.yml は YSFX に書いていない）。O3 は比べるための別の段。既定 both
#   --no-jit     JIT 版を建てない・回さない
#   --label      出力の名前の頭（build/jsfx-bench/<label>-<opt>-<eel>.json）。既定は機種名
#   --diff       速さを測らず、portable の版（--opt の段と、命令を数える版）で Tests/Fixtures/JSFX・
#                Tests/Fuzz/Corpus/jsfxexec・Debug/JSFXBench・Tools/jsfx-bench/diff を EEL の実行系ごとに回し、
#                portable と 1 ビットまで比べる（diff.cpp）。数える版は通らなかった命令も出す
#   --profile    速さを測らず、-DNSEEL_VM_PROFILE の版（-Os）で Debug/JSFXBench を 1 本ずつ vm-goto で回し、
#                命令の数と続いた 2 つの組を数える（build/jsfx-bench/opcodes/*.json → opcodes.py）
#   --vm-dump    速さを測らず、portable の版（--opt の段）でレジスタ型 VM の持ち上げを見る（Sources/JSFXVM、
#                docs/jsfx-regvm-design.md）。入力の既定は --diff と同じ 4 か所。handle ごとの結果と節ごとの
#                割合・理由の表（build/jsfx-bench/<label>-vm-coverage-<opt>.json）。--vm-ir で中間表現も出す
#   --vm-opgrid  設計 §12.1: 命令ごとに値の格子で portable と中間表現の参照の解釈を 1 ビットまで比べる
#
# 建てるもの（どれも Sources/Shared/ETJSFXBench.cpp + ETJSFXHost.cpp + ysfx/WDL）:
#   jsfx-bench-portable-<opt>  EEL_TARGET_PORTABLE（iOS と同じ解釈）。実行系 portable・vm-*・cpp
#   jsfx-bench-jit-<opt>       EEL_TARGET_PORTABLE なし（WDL の glue_aarch64.h の JIT）。実行系 wdl-jit と cpp。
#                              arm64 だけ。OS が実行できる頁を断ったら、何が断られたかを出して止まる
# ysfx は Vendor/ysfx の写しにアプリと同じパッチを当てて、project.yml の YSFX と同じ組・同じ定義で建てる
# （組の一覧と定義は Tests/Fuzz/run.sh の jsfxexec と同じ。**あちらを変えたらここも。**）。
# ETLICEFont.mm（CoreText）の代わりに Tests/Fuzz/Native/et_lice_font_linux.cpp を使う（@gfx は回さない）。
# Mac の /bin/bash（3.2）で動くように書く（wait -n・連想配列・mapfile を使わない）。
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
seconds=5
scripts=
opts=(Os O3)
jit=1
label=
build_only=0
clean=0
mode=bench
vm_ir=0
vm_paths=()

die() { echo "run.sh: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --seconds) [ $# -ge 2 ] || die "--seconds に値が無い"; seconds=$2; shift 2 ;;
    --scripts) [ $# -ge 2 ] || die "--scripts に値が無い"; scripts=$2; shift 2 ;;
    --opt) [ $# -ge 2 ] || die "--opt に値が無い"
           case $2 in Os|O3) opts=("$2") ;; both) opts=(Os O3) ;; *) die "--opt は Os・O3・both" ;; esac
           shift 2 ;;
    --no-jit) jit=0; shift ;;
    --label) [ $# -ge 2 ] || die "--label に値が無い"; label=$2; shift 2 ;;
    --build-only) build_only=1; shift ;;
    --clean) clean=1; shift ;;
    --diff) mode=diff; shift ;;
    --profile) mode=profile; shift ;;
    --vm-dump) mode=vmdump; shift ;;
    --vm-ir) vm_ir=1; shift ;;
    --vm-opgrid) mode=vmopgrid; shift ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "知らない引数: $1（--help）" ;;
    *) [ "$mode" = vmdump ] || die "知らない引数: $1（--help）"; vm_paths+=("$1"); shift ;;
  esac
done

cc=$(command -v clang || true)
cxx=$(command -v clang++ || true)
if [ -z "$cc" ] || [ -z "$cxx" ]; then die "clang / clang++ が無い"; fi
[ -f "$repo/Vendor/ysfx/include/ysfx.h" ] || die "Vendor/ysfx が無い（git submodule update --init Vendor/ysfx）"
arch=$(uname -m)
os=$(uname -s)
if [ "$jit" = 1 ] && [ "$arch" != arm64 ] && [ "$arch" != aarch64 ]; then
  echo "== JIT 版は arm64 だけ（ここは $arch）。--no-jit と同じにする"
  jit=0
fi
if [ -z "$label" ]; then
  if [ "$os" = Darwin ]; then label=$(sysctl -n hw.model 2>/dev/null || echo mac); else label=$(uname -n); fi
fi
label=$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')
jobs=$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) | head -1)
if command -v shasum >/dev/null 2>&1; then hash_cmd=(shasum); else hash_cmd=(sha1sum); fi
sha=$(git -C "$repo" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$repo" status --porcelain -- Sources/Shared Sources/JSFXVM Tools/jsfx-bench Debug/JSFXBench Patches 2>/dev/null)" ]; then
  sha="$sha-dirty"
fi

work="$repo/build/jsfx-bench"
mkdir -p "$work"
if [ "$clean" = 1 ]; then rm -rf "$work"/obj-* "$work"/ysfx "$work"/bin; fi
log="$work/build.log"
echo "== jsfx-bench run.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) HEAD $sha $("$cxx" --version | head -1)" > "$log"

# **Vendor/ysfx には手を入れない。**写しを作ってアプリと同じパッチを当てる（Tests/Fuzz/run.sh と同じ）。
ysfx="$work/ysfx"
rm -rf "$ysfx.new"
mkdir -p "$ysfx.new/thirdparty/WDL/source"
cp -R "$repo/Vendor/ysfx/include" "$repo/Vendor/ysfx/sources" "$ysfx.new/"
cp -R "$repo/Vendor/ysfx/thirdparty/WDL/source/WDL" "$ysfx.new/thirdparty/WDL/source/"
# Windows の写し（core.autocrlf）からでも LF にそろえる。BSD の sed -i は形が違うので perl で。
find "$ysfx.new" -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -exec perl -pi -e 's/\r$//' {} +
if ! grep -q effectdeck_nan_order "$ysfx.new/thirdparty/WDL/source/WDL/eel2/glue_port.h"; then
  perl -pe 's/\r$//' "$repo/Patches/ysfx-effectdeck-ios.diff" \
    | (cd "$ysfx.new" && GIT_CEILING_DIRECTORIES="$(dirname "$ysfx.new")" git apply -p1 -) >> "$log" 2>&1 \
    || die "ysfx-effectdeck-ios.diff が写しに当たらない（Vendor/ysfx の版。Scripts/setup.sh を読むこと）"
fi
rm -rf "$ysfx"; mv "$ysfx.new" "$ysfx"

# project.yml の YSFX と同じ定義（EEL_TARGET_PORTABLE は portable の版だけ）。
common_defs=(-DYSFX_NO_FTS -DYSFX_EFFECTDECK_SANDBOX -DEEL_MISC_NO_SLEEP -D_LICE_NO_SYSBITMAPS_
             -D_FILE_OFFSET_BITS=64 -DWDL_FFT_REALSIZE=8 -DWDL_LINEPARSE_ATOF=ysfx_wdl_atof
             -DNSEEL_ATOF=ysfx_wdl_atof)
inc=(-I "$ysfx/include" -I "$ysfx/sources" -I "$ysfx/thirdparty/WDL/source")
ysfx_srcs=()
while IFS= read -r f; do ysfx_srcs+=("$f"); done < <(
  cd "$ysfx" && find sources -name '*.cpp' -not -path 'sources/lice_stb/*' \
    -not -path 'sources/eel2-gas/*' -not -name ysfx_audio_flac.cpp -not -name ysfx_audio_wav.cpp \
    -not -name ysfx_utils_fts.cpp | sort)
for f in nseel-caltab.c nseel-cfunc.c nseel-compiler.c nseel-eval.c nseel-lextab.c nseel-ram.c \
         nseel-yylex.c; do ysfx_srcs+=("thirdparty/WDL/source/WDL/eel2/$f"); done
ysfx_srcs+=(thirdparty/WDL/source/WDL/fft.c)
for f in lice.cpp lice_arc.cpp lice_colorspace.cpp lice_image.cpp lice_line.cpp lice_palette.cpp \
         lice_texgen.cpp lice_text.cpp; do ysfx_srcs+=("thirdparty/WDL/source/WDL/lice/$f"); done

# 1 本ずつ建てる（xargs -P から呼ぶ）。$1=写しの中の源、$2=置き場、残りは旗。
compile_one() {
  local src=$1 objs=$2; shift 2
  local obj log std=c++20
  obj="$objs/$(basename "$src").o"; log="$objs/$(basename "$src").log"
  case $src in */lice_texgen.cpp) std=c++17 ;; esac   # Tests/Fuzz/run.sh と同じ（std::lerp とぶつかる）
  case $src in
    *.c) "$ET_CC" "$@" -c "$ET_YSFX/$src" -o "$obj" > "$log" 2>&1 ;;
    *) "$ET_CXX" -std="$std" "$@" -c "$ET_YSFX/$src" -o "$obj" > "$log" 2>&1 ;;
  esac
}
export -f compile_one
export ET_CC="$cc" ET_CXX="$cxx" ET_YSFX="$ysfx"

# $1=portable|jit|profile $2=Os|O3。建てた実行ファイルのパスを出す。
build_bin() {
  local eel=$1 opt=$2 defs flags objs key bin eel_name
  # -fno-strict-float-cast-overflow: 範囲の外・NaN の double → int を arm64 の fcvtzs と同じ飽和にする
  # （Tests/Fuzz/run.sh と同じ。arm64 では機械語は変わらない。x86_64 の照合を arm64 とそろえる）。
  flags=(-"$opt" -fsigned-char -g -fno-strict-float-cast-overflow)
  defs=("${common_defs[@]}")
  case $eel in
    portable) defs+=(-DEEL_TARGET_PORTABLE); eel_name=portable ;;
    profile) defs+=(-DEEL_TARGET_PORTABLE -DNSEEL_VM_PROFILE); eel_name=portable ;;
    *) eel_name=wdl-jit ;;
  esac
  objs="$work/obj-$eel-$opt"
  key=$({ "$cxx" --version | head -1; "${hash_cmd[@]}" < "${BASH_SOURCE[0]}"
          echo "${defs[*]} ${flags[*]} ${ysfx_srcs[*]}"
          (cd "$ysfx" && find . -type f | LC_ALL=C sort | tr '\n' '\0' | xargs -0 "${hash_cmd[@]}"); } \
        | "${hash_cmd[@]}" | cut -c1-40)
  if [ "$(cat "$objs/key" 2>/dev/null || true)" != "$key" ]; then
    echo "== build ysfx $eel -$opt (${#ysfx_srcs[@]} files, $jobs jobs)" | tee -a "$log" >&2
    rm -rf "$objs"; mkdir -p "$objs"
    if ! printf '%s\n' "${ysfx_srcs[@]}" \
        | xargs -P "$jobs" -I{} bash -c 'compile_one "$@"' _ {} "$objs" "${flags[@]}" "${defs[@]}" "${inc[@]}"; then
      cat "$objs"/*.log >> "$log" 2>/dev/null || true
      grep -h -m 5 "error" "$objs"/*.log >&2 || true
      die "ysfx の $eel -$opt が建たない（$log）"
    fi
    cat "$objs"/*.log >> "$log" 2>/dev/null || true
    echo "$key" > "$objs/key"
  fi
  mkdir -p "$work/bin"
  bin="$work/bin/jsfx-bench-$eel-$opt"
  local extra=(-DET_JSFX_BENCH=1 "-DET_JSFX_BENCH_EEL=\"$eel_name\"")
  [ "$eel" = jit ] && extra+=(-DET_JSFX_BENCH_JIT_PROBE)
  # ETJSFXHost.cpp と台はアプリの側（project.yml の dspSettings も -Os）。同じ段で建てる。
  # Sources/JSFXVM はアプリでは YSFX の中（project.yml）。YSFX と同じ定義・同じ段で建てる。
  local vm_srcs=("$repo"/Sources/JSFXVM/*.cpp)
  if ! { "$cc" "${flags[@]}" -I "$repo/Sources/Shared" -c "$repo/Sources/Shared/ETExternalProcessor.c" \
           -o "$objs/ETExternalProcessor.o" &&
         "$cc" "${flags[@]}" "${defs[@]}" "${inc[@]}" -I "$repo/Sources/JSFXVM" \
           -c "$repo/Sources/JSFXVM/ETVMGlueCheck.c" -o "$objs/ETVMGlueCheck.o" &&
         "$cxx" -std=c++20 "${flags[@]}" "${defs[@]}" "${extra[@]}" "${inc[@]}" -I "$repo/Sources/Shared" \
           -I "$repo/Sources/JSFXVM" "$here/main.cpp" "$here/diff.cpp" "$here/vm.cpp" "${vm_srcs[@]}" \
           "$repo/Sources/Shared/ETJSFXBench.cpp" "$repo/Sources/Shared/ETJSFXBenchPorts.cpp" \
           "$repo/Sources/Shared/ETJSFXHost.cpp" "$repo/Tests/Fuzz/Native/et_lice_font_linux.cpp" \
           "$objs/ETExternalProcessor.o" "$objs/ETVMGlueCheck.o" "$objs"/*.c.o "$objs"/*.cpp.o -pthread \
           -o "$bin"; } >> "$log" 2>&1; then
    tail -30 "$log" >&2
    die "jsfx-bench-$eel-$opt が建たない（$log）"
  fi
  echo "$bin"
}

if [ "$mode" = vmdump ] || [ "$mode" = vmopgrid ]; then
  status=0
  for opt in "${opts[@]}"; do
    b=$(build_bin portable "$opt") || exit 1
    echo "== built: $b"
    [ "$build_only" = 1 ] && continue
    set +e
    if [ "$mode" = vmopgrid ]; then
      echo "== vm-opgrid -$opt"
      "$b" --vm-opgrid | tee "$work/$label-vm-opgrid-$opt.txt"
    else
      if [ ${#vm_paths[@]} -eq 0 ]; then
        vm_paths=("$repo/Tests/Fixtures/JSFX" "$repo/Tests/Fuzz/Corpus/jsfxexec" "$repo/Debug/JSFXBench" "$here/diff")
      fi
      args=(--vm-dump --vm-json "$work/$label-vm-coverage-$opt.json")
      [ "$vm_ir" = 1 ] && args+=(--vm-ir)
      echo "== vm-dump -$opt"
      "$b" "${args[@]}" "${vm_paths[@]}" | tee "$work/$label-vm-dump-$opt.txt"
    fi
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    set -e
  done
  exit "$status"
fi

if [ "$mode" = profile ]; then
  b=$(build_bin profile Os) || exit 1
  echo "== built: $b"
  [ "$build_only" = 1 ] && exit 0
  mkdir -p "$work/opcodes"
  rm -f "$work"/opcodes/*.json
  list=${scripts:-gain,filter_drive,stereo_delay,slow,biquad,fir,math}
  for s in $(printf '%s' "$list" | tr ',' ' '); do
    echo "== profile $s"
    "$b" --dir "$repo/Debug/JSFXBench" --seconds 1 --warmup 0 --scripts "$s" --variants vm-goto --no-rt --spin 0 \
      --profile-out "$work/opcodes/$s.json" > "$work/opcodes/$s.txt" 2>&1 || { cat "$work/opcodes/$s.txt"; exit 1; }
  done
  python3 "$here/opcodes.py" "$work"/opcodes/*.json
  exit 0
fi

bins=()
for opt in "${opts[@]}"; do
  b=$(build_bin portable "$opt") || exit 1
  bins+=("$b")
  if [ "$jit" = 1 ] && [ "$mode" = bench ]; then
    b=$(build_bin jit "$opt") || exit 1
    bins+=("$b")
  fi
done
echo "== built: ${bins[*]}"
[ "$build_only" = 1 ] && exit 0

if [ "$mode" = diff ]; then
  # 命令の数を取る版も足す（同じ比べ合わせをして、通らなかった命令を出す）。
  b=$(build_bin profile Os) || exit 1
  bins+=("$b")
  status=0
  for bin in "${bins[@]}"; do
    echo "== diff $(basename "$bin")"
    set +e
    "$bin" --diff "$repo/Tests/Fixtures/JSFX" "$repo/Tests/Fuzz/Corpus/jsfxexec" "$repo/Debug/JSFXBench" "$here/diff" \
      | tee "$work/$label-$(basename "$bin")-diff.txt"
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    set -e
  done
  exit "$status"
fi

jsons=()
status=0
for bin in "${bins[@]}"; do
  name=$(basename "$bin")            # jsfx-bench-<eel>-<opt>
  eel=${name#jsfx-bench-}; opt=${eel##*-}; eel=${eel%-*}
  # portable の版は全部（portable・vm-*・cpp）。JIT の版は wdl-jit と cpp だけ（vm-* は作れない）。
  if [ "$eel" = portable ]; then variants=; else variants=wdl-jit,cpp; fi
  out="$work/$label-$opt-$eel.json"
  args=(--dir "$repo/Debug/JSFXBench" --seconds "$seconds" --json "$out"
        --config "cli-$opt" --sha "$sha" --flags "clang -$opt -fsigned-char -fno-strict-float-cast-overflow ($eel; ysfx, host and harness)")
  [ -n "$variants" ] && args+=(--variants "$variants")
  [ -n "$scripts" ] && args+=(--scripts "$scripts")
  echo "== run $name"
  set +e
  "$bin" "${args[@]}" 2>&1 | tee "$work/$label-$opt-$eel.txt"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" != 0 ]; then echo "== $name: exit $rc"; status=1; fi
  [ -f "$out" ] && jsons+=("$out")
done

if [ ${#jsons[@]} -gt 0 ] && command -v python3 >/dev/null 2>&1; then
  python3 "$here/summary.py" "${jsons[@]}"
fi
exit "$status"
