#!/usr/bin/env bash
# Tests/Fuzz/tsan.sh
# JSFX の実行（ETJSFXHost・ysfx・WDL・Sources/JSFXVM）を ThreadSanitizer で建て、音・つまみ・保守・画の
# スレッドを同時に回す（Tests/Fuzz/Native/jsfx_threads.cpp）。vm-reg を切り替えながらの回と、
# アプリの既定の実行系だけの回の 2 つ。どちらも TSan が何も言わず、出力が正解と 1 ビットまで同じこと。
#
#   wsl bash Tests/Fuzz/tsan.sh [--seconds <秒>] [--seed <数>] [--mode reg|default|multi|both|all]
#
# ysfx の写しとパッチの当て方は run.sh の jsfxexec と同じ（写し先 ~/.cache/effectdeck-fuzz/tsan/native/）。
# swiftly の clang の TSan の実行時は libdispatch を引くので、ツールチェーンの libdispatch をつなぐ。
# 落ちたら終了値 1（TSan の報告は 66）。ログは build/tsan-<mode>.log。
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
seconds=20
seed=1
modes=(reg default multi)
while [ $# -gt 0 ]; do
  case $1 in
    --seconds) seconds=$2; shift 2 ;;
    --seed) seed=$2; shift 2 ;;
    --mode) case $2 in both) modes=(reg default) ;; all) modes=(reg default multi) ;; *) modes=("$2") ;; esac; shift 2 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "tsan.sh: 知らない引数: $1" >&2; exit 2 ;;
  esac
done

if ! command -v clang >/dev/null 2>&1; then
  for env in "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" "$HOME/.swiftly/env.sh"; do
    # shellcheck disable=SC1090
    if [ -f "$env" ]; then . "$env"; break; fi
  done
fi
cc=$(command -v clang) || { echo "tsan.sh: clang が無い" >&2; exit 2; }
cxx=$(command -v clang++) || { echo "tsan.sh: clang++ が無い" >&2; exit 2; }

work="${EFFECTDECK_FUZZ_CACHE:-$HOME/.cache/effectdeck-fuzz}/tsan/native"
ysfx="$work/ysfx"
mkdir -p "$work" "$repo/build"
rm -rf "$ysfx.new"
mkdir -p "$ysfx.new/thirdparty/WDL/source"
cp -R "$repo/Vendor/ysfx/include" "$repo/Vendor/ysfx/sources" "$ysfx.new/"
cp -R "$repo/Vendor/ysfx/thirdparty/WDL/source/WDL" "$ysfx.new/thirdparty/WDL/source/"
find "$ysfx.new" -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -exec sed -i 's/\r$//' {} +
if ! grep -q GLUE_MEGABUF_NO_IMMEDIATE "$ysfx.new/thirdparty/WDL/source/WDL/eel2/glue_port.h"; then
  sed 's/\r$//' "$repo/Patches/ysfx-effectdeck-ios.diff" \
    | (cd "$ysfx.new" && GIT_CEILING_DIRECTORIES="$(dirname "$ysfx.new")" git apply -p1 -) \
    || { echo "tsan.sh: ysfx-effectdeck-ios.diff が写しに当たらない" >&2; exit 1; }
fi

# project.yml の YSFX と同じ定義（run.sh と同じ）。
ysfx_defs=(-DEEL_TARGET_PORTABLE -DYSFX_NO_FTS -DYSFX_EFFECTDECK_SANDBOX -DEEL_MISC_NO_SLEEP
           -D_LICE_NO_SYSBITMAPS_ -D_FILE_OFFSET_BITS=64 -DWDL_FFT_REALSIZE=8
           -DWDL_LINEPARSE_ATOF=ysfx_wdl_atof -DNSEEL_ATOF=ysfx_wdl_atof)
san=(-g -O1 -fsigned-char -fsanitize=thread -fno-strict-float-cast-overflow)
inc=(-I "$ysfx/include" -I "$ysfx/sources" -I "$ysfx/thirdparty/WDL/source")
ysfx_srcs=()
while IFS= read -r f; do ysfx_srcs+=("$f"); done < <(
  cd "$ysfx.new" && find sources -name '*.cpp' -not -path 'sources/lice_stb/*' \
    -not -path 'sources/eel2-gas/*' -not -name ysfx_audio_flac.cpp -not -name ysfx_audio_wav.cpp \
    -not -name ysfx_utils_fts.cpp | sort)
for f in nseel-caltab.c nseel-cfunc.c nseel-compiler.c nseel-eval.c nseel-lextab.c nseel-ram.c \
         nseel-yylex.c; do ysfx_srcs+=("thirdparty/WDL/source/WDL/eel2/$f"); done
ysfx_srcs+=(thirdparty/WDL/source/WDL/fft.c)
for f in lice.cpp lice_arc.cpp lice_colorspace.cpp lice_image.cpp lice_line.cpp lice_palette.cpp \
         lice_texgen.cpp lice_text.cpp; do ysfx_srcs+=("thirdparty/WDL/source/WDL/lice/$f"); done
key=$({ "$cxx" --version | head -1; sha1sum < "${BASH_SOURCE[0]}"
        echo "${ysfx_defs[*]} ${san[*]} ${ysfx_srcs[*]}"
        (cd "$ysfx.new" && find . -type f -print0 | sort -z | xargs -0 sha1sum); } | sha1sum | cut -c1-40)
objs="$work/ysfx-obj"
rm -rf "$ysfx"; mv "$ysfx.new" "$ysfx"
if [ "$(cat "$objs/key" 2>/dev/null || true)" != "$key" ]; then
  echo "== tsan: build ysfx (${#ysfx_srcs[@]} files)"
  rm -rf "$objs"; mkdir -p "$objs"
  pids=()
  for src in "${ysfx_srcs[@]}"; do
    obj="$objs/$(basename "$src").o"; std=c++20
    case $src in */lice_texgen.cpp) std=c++17 ;; esac
    case $src in
      *.c) "$cc" "${san[@]}" "${ysfx_defs[@]}" "${inc[@]}" -c "$ysfx/$src" -o "$obj" > "$obj.log" 2>&1 & ;;
      *) "$cxx" -std=$std "${san[@]}" "${ysfx_defs[@]}" "${inc[@]}" -c "$ysfx/$src" -o "$obj" > "$obj.log" 2>&1 & ;;
    esac
    pids+=($!)
  done
  failed=0
  for p in "${pids[@]}"; do wait "$p" || failed=1; done
  if [ "$failed" != 0 ]; then grep -h -m 5 error "$objs"/*.log || true; echo "== tsan: ysfx build failed"; exit 1; fi
  echo "$key" > "$objs/key"
fi

bin="$work/jsfx_threads"
vm_objs=()
for f in "$repo"/Sources/JSFXVM/*.cpp; do
  o="$work/$(basename "$f").o"; vm_objs+=("$o")
  "$cxx" -std=c++20 "${san[@]}" "${ysfx_defs[@]}" "${inc[@]}" -I "$repo/Sources/JSFXVM" -c "$f" -o "$o" &
done
"$cc" "${san[@]}" "${ysfx_defs[@]}" "${inc[@]}" -I "$repo/Sources/JSFXVM" \
  -c "$repo/Sources/JSFXVM/ETVMGlueCheck.c" -o "$work/ETVMGlueCheck.o" &
"$cc" "${san[@]}" -I "$repo/Sources/Shared" -c "$repo/Sources/Shared/ETExternalProcessor.c" \
  -o "$work/ETExternalProcessor.o" &
wait
# swiftly の clang の TSan の実行時は libdispatch の口を持つ（Linux でも）。ツールチェーンのものをつなぐ。
dispatch=()
swiftlib="$("$cc" -print-resource-dir)/../../swift/linux"
if [ -f "$swiftlib/libdispatch.so" ]; then
  dispatch=(-L "$swiftlib" -ldispatch -lBlocksRuntime -Wl,-rpath,"$swiftlib")
fi
"$cxx" -std=c++20 "${san[@]}" "${ysfx_defs[@]}" "${inc[@]}" -I "$repo/Sources/Shared" -I "$repo/Sources/JSFXVM" \
  "$here/Native/jsfx_threads.cpp" "$repo/Sources/Shared/ETJSFXHost.cpp" "$here/Native/et_lice_font_linux.cpp" \
  "$work/ETExternalProcessor.o" "$work/ETVMGlueCheck.o" "${vm_objs[@]}" "$objs"/*.o \
  -pthread "${dispatch[@]}" -o "$bin"

status=0
for m in "${modes[@]}"; do
  log="$repo/build/tsan-$m.log"
  set +e
  # 直していない競合の表は Native/jsfx_threads.tsan.supp（理由はその頭）。
  TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1:exitcode=66:second_deadlock_stack=1:history_size=4}:suppressions=$here/Native/jsfx_threads.tsan.supp" \
    "$bin" --mode "$m" --seconds "$seconds" --seed "$seed" 2>&1 | tee "$log"
  s=${PIPESTATUS[0]}
  set -e
  echo "== tsan $m: exit $s (log $log)"
  [ "$s" = 0 ] || status=1
done
exit $status
