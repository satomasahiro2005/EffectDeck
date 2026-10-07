#!/usr/bin/env bash
# Tests/Fuzz/run.sh
# 外から来る字を読むコードを libFuzzer で叩く（Linux・WSL・CI）。Mac は要らない。
#
#   wsl bash Tests/Fuzz/run.sh [--name <名前>] [--target <的>[,<的>...]|all] [--time <秒>]
#                              [--clean] [--build-only] [--repro <入力のファイル>] [-- <libFuzzerへ>]
#
#   --name      写し先 ~/.cache/effectdeck-fuzz/<名前>/、ログ build/fuzz-<名前>-<的>.log、
#               落ちた入力 build/fuzz/<名前>/<的>/crash-*。並べて走らせるときは別の名前にする
#   --target    的（下の一覧）。既定は all
#   --time      的 1 つあたりの秒数（-max_total_time）。既定 60。CI は 20〜30 で足りる
#   --clean     写し先の .build と育てた corpus を消してから
#   --build-only 建てて種を書くところまで
#   --repro     1 つの入力を的に 1 度だけ通す（落ちた入力の再現。--target は 1 つだけ）
#
# 的（Swift は 1 本の実行ファイル EffectDeckFuzz で、ET_FUZZ_TARGET が選ぶ）:
#   chaintext    貼られた字から鎖を探して直す（ETChainText.json(from:) → prepare）
#   sharelink    鎖のリンク・貼られた字を読んで書き戻す（ETShareLink.parseChecked）
#   fxdlink      開かれた URL の振り分けと /j#… の JSFX（ETFXDLink）
#   pipelineform prepare を通らずに読む口（PipelineStore.parse、ETBackup.read）
#   peqtext      15Band PEQ の Import（ETPEQTextImport）
#   remotefile   貼られたリンクの読み替えと gist の名前選び（ETRemoteFile）
#   jsfxtext     JSFX の囲い・desc:/author:・付け替えの表（ETCodeBlock、JSFXReplace、ETJSFXLoader）
#   irprep       IR Reverb の下ごしらえ（ETIRPreparation）
#   jsfxgate     C++ の JSFX ソースの門（ETJSFXHost.cpp。Tests/Fuzz/Native）
#   jsfxexec     任意の JSFX をアプリと同じ C API で最後まで回す（作る・@init・つまみ・
#                ブロック・状態の保存と復元・@gfx・消す。Tests/Fuzz/Native/jsfx_exec.cpp）。
#                ysfx は Vendor/ysfx の写しに Patches/ysfx-effectdeck-ios.diff を当てて、
#                project.yml の YSFX と同じ組・同じ定義で建てる（写し先の native/ に置き、中身が
#                同じなら建て直さない）。止まらないスクリプトは -fork で回して時間切れを落ちと
#                数えない（入力は timeout-* に残る。落ち・ASan・メモリの上限は今までどおり止まる）
#   jsfxvmdiff   レジスタ型 VM（vm-reg、Sources/JSFXVM）と portable を同じ JSFX で 1 歩ずつ並べて回し、
#                プロセスで共有される状態（rand・onfail・_global.*・gmem）を歩みごとに写して戻しながら
#                1 ビットまで比べる（Tests/Fuzz/Native/jsfx_vmdiff.cpp、docs/jsfx-regvm-design.md §12.7）。
#                ysfx の写しと建て方は jsfxexec と同じ。種は jsfxexec の corpus と台・照合のスクリプト。
#                EEL の文法から作った文を差し込む変異を混ぜる
#
# 何を建てるかは Linux の単体テストと同じ（project.yml、Tests/Fuzz/make_package.py）。
# 種は 3 か所から: Tests/Fuzz/Corpus/<的>（手で書いたもの）、リポジトリの見本（下の seed_files）、
# カタログから作るもの（Harness/Seeds.swift）。育った corpus は写し先に残り、次の回が続きから回る。
# 落ちたら終了値 1。ログの "fuzz oracle:" か ASan / Swift の止めの行が理由。
# 要るもの: swift（swiftly でもよい。-sanitize=fuzzer は Linux のツールチェーンに入っている）、python3。
# Windows の Git Bash から呼ぶときは MSYS_NO_PATHCONV=1 を付ける。
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)

all_targets=(chaintext sharelink fxdlink pipelineform peqtext remotefile jsfxtext irprep jsfxgate jsfxexec jsfxvmdiff)
name=default
targets=all
seconds=60
clean=0
build_only=0
repro=
passthrough=()

usage() { sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "run.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --name) [ $# -ge 2 ] || die "--name に値が無い"; name=$2; shift 2 ;;
    --name=*) name=${1#*=}; shift ;;
    --target) [ $# -ge 2 ] || die "--target に値が無い"; targets=$2; shift 2 ;;
    --target=*) targets=${1#*=}; shift ;;
    --time) [ $# -ge 2 ] || die "--time に値が無い"; seconds=$2; shift 2 ;;
    --time=*) seconds=${1#*=}; shift ;;
    --clean) clean=1; shift ;;
    --build-only) build_only=1; shift ;;
    --repro) [ $# -ge 2 ] || die "--repro に値が無い"; repro=$2; shift 2 ;;
    --repro=*) repro=${1#*=}; shift ;;
    --) shift; passthrough=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) die "知らない引数: $1（--help）" ;;
  esac
done
[[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "--name は英数字と . _ - だけ: $name"
[[ $seconds =~ ^[0-9]+$ ]] || die "--time は秒の整数: $seconds"
if [ "$targets" = all ]; then
  selected=("${all_targets[@]}")
else
  IFS=, read -r -a selected <<< "$targets"
  for t in "${selected[@]}"; do
    [[ " ${all_targets[*]} " == *" $t "* ]] || die "知らない的: $t（${all_targets[*]}）"
  done
fi
if [ -n "$repro" ]; then
  [ ${#selected[@]} -eq 1 ] || die "--repro は --target を 1 つだけ"
  [ -f "$repro" ] || die "--repro のファイルが無い: $repro"
  repro=$(cd "$(dirname "$repro")" && pwd)/$(basename "$repro")
fi

if ! command -v swift >/dev/null 2>&1; then
  for env in "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" "$HOME/.swiftly/env.sh"; do
    # shellcheck disable=SC1090
    if [ -f "$env" ]; then . "$env"; break; fi
  done
fi
command -v swift >/dev/null 2>&1 || die "swift が無い"
command -v python3 >/dev/null 2>&1 || die "python3 が無い"

work="${EFFECTDECK_FUZZ_CACHE:-$HOME/.cache/effectdeck-fuzz}/$name"
out="$repo/build/fuzz/$name"
mkdir -p "$work" "$out"
if [ "$clean" = 1 ]; then rm -rf "$work/.build" "$work/corpus" "$work/seeds" "$work/native"; fi

# LinuxのFoundationは自前で漏らす（NSRegularExpression・Bundle）。漏れで毎回止まらないよう切る。
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:allocator_may_return_null=1}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}"
# Swift の止め（fatalError・範囲の外）のあとに走る backtracer は、ASan の下では自分の読み出しで
# "unknown-crash" を重ねて出し、1 回に数分かかる。止めの行（Fatal error: …）は先に出るので切る。
# libFuzzer は落ちた入力をそのまま残す。
export SWIFT_BACKTRACE="${SWIFT_BACKTRACE:-enable=no}"

build_log="$repo/build/fuzz-$name-build.log"
swift_needed=0
native_needed=0
exec_needed=0
vmdiff_needed=0
for t in "${selected[@]}"; do
  case $t in
    jsfxgate) native_needed=1 ;;
    jsfxexec) exec_needed=1 ;;
    jsfxvmdiff) exec_needed=1; vmdiff_needed=1 ;;
    *) swift_needed=1 ;;
  esac
done

{
  echo "== fuzz run.sh --name $name  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "== repo $repo  HEAD $(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "== $(swift --version 2>&1 | head -1)"
  echo "== work $work  targets ${selected[*]}  time ${seconds}s"
} > "$build_log"

bin=
if [ "$swift_needed" = 1 ]; then
  # 失敗の行を出してから止めるため、パイプの間だけ -e を外す（-e のままだと tee の行で黙って抜ける）。
  set +e
  python3 "$here/make_package.py" --repo "$repo" --out "$work" 2>&1 | tee -a "$build_log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" = 0 ] || { echo "== make_package failed ($status). log $build_log"; exit "$status"; }
  # -parse-as-library: main は libFuzzer が持つ。-sanitize=fuzzer は計測（edge・比較の値）と
  # libFuzzer のリンクの両方。address で配列の外・解放済みを拾う。
  # **release（-O、WMO）で建てる。**debug の 10〜50 倍回る。WSL で約 5 分・約 700 MB。
  # Swift の範囲・溢れの止めは -O でも残る（-Ounchecked ではない）。
  set +e
  swift build --package-path "$work" -c release -j "${FUZZ_JOBS:-2}" \
    -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library 2>&1 | tee -a "$build_log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" = 0 ] || { echo "== build failed ($status). log $build_log"; exit "$status"; }
  bin="$(swift build --package-path "$work" -c release --show-bin-path)/EffectDeckFuzz"
  [ -x "$bin" ] || die "実行ファイルが無い: $bin"
fi

gate=
if [ "$native_needed" = 1 ]; then
  cxx=$(command -v clang++ || true)
  [ -n "$cxx" ] || die "clang++ が無い（swiftly のツールチェーンに入っている）"
  mkdir -p "$work/native"
  gate="$work/native/jsfx_source_gate"
  # ysfx は宣言だけ使う（門は呼ばない）。未定義の参照はリンクで無視させる（jsfx_source_gate.cpp の頭）。
  set +e
  "$cxx" -std=c++20 -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all \
    -I "$repo/Sources/Shared" -I "$repo/Vendor/ysfx/include" \
    -I "$repo/Vendor/ysfx/thirdparty/WDL/source" \
    "$here/Native/jsfx_source_gate.cpp" -o "$gate" \
    -Wl,--unresolved-symbols=ignore-all 2>&1 | tee -a "$build_log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" = 0 ] || { echo "== native build failed ($status). log $build_log"; exit "$status"; }
fi

exec_bin=
vmdiff_bin=
if [ "$exec_needed" = 1 ]; then
  cc=$(command -v clang || true)
  cxx=$(command -v clang++ || true)
  if [ -z "$cc" ] || [ -z "$cxx" ]; then die "clang / clang++ が無い（swiftly のツールチェーンに入っている）"; fi
  command -v git >/dev/null 2>&1 || die "git が無い"
  [ -f "$repo/Vendor/ysfx/include/ysfx.h" ] || die "Vendor/ysfx が無い（git submodule update --init Vendor/ysfx）"
  native="$work/native"
  ysfx="$native/ysfx"
  mkdir -p "$native"
  # **Vendor/ysfx には手を入れない。**写しを作ってアプリと同じパッチを当てる。
  # setup.sh が Vendor/ysfx に当て済みなら写しにも入っているので当てない。
  rm -rf "$ysfx.new"
  mkdir -p "$ysfx.new/thirdparty/WDL/source"
  cp -R "$repo/Vendor/ysfx/include" "$repo/Vendor/ysfx/sources" "$ysfx.new/"
  cp -R "$repo/Vendor/ysfx/thirdparty/WDL/source/WDL" "$ysfx.new/thirdparty/WDL/source/"
  # Windows の写し（core.autocrlf）から WSL で建てると源もパッチも CRLF になる。写しとパッチを
  # LF にそろえる（Linux の checkout では何もしない）。
  find "$ysfx.new" -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) \
    -exec sed -i 's/\r$//' {} +
  # 当たっているかの目印は Scripts/setup.sh と同じ（パッチの今の版が初めて足したもの）。
  if ! grep -q NSEEL_exec_backend "$ysfx.new/thirdparty/WDL/source/WDL/eel2/ns-eel.h"; then
    # patch(1) は CI の swift の image に無いことがあるので git apply で当てる。写しの上の
    # ディレクトリにリポジトリを探しに行かせない（GIT_CEILING_DIRECTORIES）。
    sed 's/\r$//' "$repo/Patches/ysfx-effectdeck-ios.diff" \
      | (cd "$ysfx.new" && GIT_CEILING_DIRECTORIES="$(dirname "$ysfx.new")" git apply -p1 -) \
        >> "$build_log" 2>&1 \
      || die "ysfx-effectdeck-ios.diff が写しに当たらない（Vendor/ysfx の版。Scripts/setup.sh を読むこと）"
  fi
  # project.yml の YSFX と同じ組・同じ定義。**あちらを変えたらここも。**
  # EEL_TARGET_PORTABLE: JIT ではなく iOS と同じバイトコードの解釈で回す。
  # NSEEL_LOOPFUNC_SUPPORT_MAXLEN は触らない（アプリと同じ 1048576 周で打ち切る）。
  ysfx_defs=(-DEEL_TARGET_PORTABLE -DYSFX_NO_FTS -DYSFX_EFFECTDECK_SANDBOX -DEEL_MISC_NO_SLEEP
             -D_LICE_NO_SYSBITMAPS_ -D_FILE_OFFSET_BITS=64 -DWDL_FFT_REALSIZE=8
             -DWDL_LINEPARSE_ATOF=ysfx_wdl_atof -DNSEEL_ATOF=ysfx_wdl_atof)
  san=(-g -O1 -fsigned-char -fno-sanitize-recover=all)
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
  # 中身・組・旗・コンパイラ・この run.sh が同じなら前の .o を使う（sanitizer 付きで 30 本ほど）。
  key=$({ "$cxx" --version | head -1; sha1sum < "${BASH_SOURCE[0]}"
          echo "${ysfx_defs[*]} ${san[*]} ${ysfx_srcs[*]}"
          (cd "$ysfx.new" && find . -type f -print0 | sort -z | xargs -0 sha1sum); } | sha1sum | cut -c1-40)
  objs="$native/ysfx-obj"
  rm -rf "$ysfx"; mv "$ysfx.new" "$ysfx"
  if [ "$(cat "$objs/key" 2>/dev/null || true)" != "$key" ]; then
    echo "== jsfxexec: build ysfx (${#ysfx_srcs[@]} files)" | tee -a "$build_log"
    rm -rf "$objs"; mkdir -p "$objs"
    compile_one() {   # $1 = 写しの中の源
      # ysfx・EEL2・LICE はスクリプトの double をそのまま int にする（ysfx_eel_round<int32_t>、
      # (int) の添字・座標）。範囲の外は UB で、どこにでもあって 1 回目で止まるので、写しの側だけ
      # float-cast-overflow を外す（ETJSFXHost.cpp とこの的の側は外さない）。
      # **-fno-strict-float-cast-overflow で arm64 と同じ飽和にする。**x86_64 の cvttsd2si は範囲の
      # 外を全部 INT_MIN にするので、正の大きな値が負になり、端末では起きない int の溢れ
      # （LICE_FillRect の w += x など）を拾っていた。この旗で clang は fptosi.sat を出す
      # （範囲の外は最小・最大、NaN は 0 = arm64 の fcvtzs と同じ）。
      # その先の int の溢れとシフトは見る。見つけて直していないものを 1 つずつ黙らせられるよう
      # recover にしておく（止めるかどうかは UBSAN_OPTIONS の halt_on_error=1 と
      # Native/jsfx_exec.ubsan.supp が決める。表に無いものは止まる）。
      local src=$1 obj log std=c++20
      local extra=(-fno-sanitize=float-cast-overflow -fno-strict-float-cast-overflow
                   -fsanitize-recover=signed-integer-overflow -fsanitize-recover=shift)
      obj="$objs/$(basename "$src").o"; log="$objs/$(basename "$src").log"
      # lice_texgen.cpp の lerp は、Linux の libstdc++ が C++20 で大域へ出す std::lerp とぶつかる
      # （アプリの libc++ では出ない）。この 1 本だけ ysfx の上流と同じ C++17 で建てる。
      case $src in */lice_texgen.cpp) std=c++17 ;; esac
      # EEL2 の portable の作りそのものが、ふつうのスクリプトでも UBSan を 1 回目で止める:
      #   alignment        バイトコードは命令の直後にポインタを詰めて置く（glue_port.h の
      #                    GLUE_MOV_PX_DIRECTVALUE_GEN など。x86_64 / arm64 の普通の読み書きは
      #                    揃っていなくても動く）
      #   bounds           解釈の浮動小数の積み場を fpstack - 1 から始める（GLUE_CALL_CODE。-1 は読まない）
      #   pointer-overflow compile は 1 周目で大きさだけ量る。そのとき bufOut は NULL のまま
      #                    bufOut + parm_size を作る（compileOpcodesInternal の loop など）
      #   function         引数の数が変わる関数（printf など varparm）を、数を EEL_F* に入れて
      #                    2 引数の形で呼ぶ（GLUE_CALL_CODE の EEL_BC_GENERIC2PARM_RETD）
      #   nonnull-attribute 中身の無い関数の片を memcpy(p, NULL, 0) で写す（compileNativeFunctionCall）
      # **nseel-*.c のこの 5 つだけ外す。**本当に外を読み書きすれば ASan が拾う。
      case $src in
        */eel2/nseel-*.c)
          extra+=(-fno-sanitize=alignment -fno-sanitize=bounds -fno-sanitize=pointer-overflow
                  -fno-sanitize=function -fno-sanitize=nonnull-attribute) ;;
      esac
      case $src in
        *.c) "$cc" "${san[@]}" -fsanitize=fuzzer-no-link,address,undefined "${extra[@]}" "${ysfx_defs[@]}" \
               "${inc[@]}" -c "$ysfx/$src" -o "$obj" > "$log" 2>&1 ;;
        *) "$cxx" -std="$std" "${san[@]}" -fsanitize=fuzzer-no-link,address,undefined "${extra[@]}" \
             "${ysfx_defs[@]}" "${inc[@]}" -c "$ysfx/$src" -o "$obj" > "$log" 2>&1 ;;
      esac
    }
    jobs_max=$(nproc 2>/dev/null || echo 2)
    running=0
    failed_build=0
    for src in "${ysfx_srcs[@]}"; do
      compile_one "$src" &
      running=$((running + 1))
      if [ "$running" -ge "$jobs_max" ]; then wait -n || failed_build=1; running=$((running - 1)); fi
    done
    while [ "$running" -gt 0 ]; do wait -n || failed_build=1; running=$((running - 1)); done
    cat "$objs"/*.log >> "$build_log" 2>/dev/null || true
    if [ "$failed_build" != 0 ]; then
      grep -h -m 5 "error" "$objs"/*.log || true
      echo "== jsfxexec: ysfx build failed. log $build_log"; exit 1
    fi
    echo "$key" > "$objs/key"
  fi
  # ETJSFXHost.cpp とその周りは毎回建てる（アプリの側。短い）。
  # ETLICEFont.mm（CoreText）の代わりは et_lice_font_linux.cpp（寸法だけ返す）。
  # Sources/JSFXVM（差分の 3 つめ vm-reg）はアプリでは YSFX の中。ysfx と同じ定義・同じ飽和の旗で建てる。
  exec_bin="$native/jsfx_exec"
  vm_flags=(-fno-sanitize=float-cast-overflow -fno-strict-float-cast-overflow -I "$repo/Sources/JSFXVM")
  vm_objs=()
  set +e
  {
    "$cc" "${san[@]}" -fsanitize=fuzzer-no-link,address,undefined -I "$repo/Sources/Shared" \
      -c "$repo/Sources/Shared/ETExternalProcessor.c" -o "$native/ETExternalProcessor.o" &&
    "$cc" "${san[@]}" -fsanitize=fuzzer-no-link,address,undefined "${vm_flags[@]}" "${ysfx_defs[@]}" "${inc[@]}" \
      -c "$repo/Sources/JSFXVM/ETVMGlueCheck.c" -o "$native/ETVMGlueCheck.o" &&
    for f in "$repo"/Sources/JSFXVM/*.cpp; do
      o="$native/$(basename "$f").o"; vm_objs+=("$o")
      "$cxx" -std=c++20 "${san[@]}" -fsanitize=fuzzer-no-link,address,undefined "${vm_flags[@]}" \
        "${ysfx_defs[@]}" "${inc[@]}" -c "$f" -o "$o" || exit 1
    done &&
    "$cxx" -std=c++20 "${san[@]}" -fsanitize=fuzzer,address,undefined "${ysfx_defs[@]}" "${inc[@]}" \
      -I "$repo/Sources/Shared" -I "$repo/Sources/JSFXVM" \
      "$here/Native/jsfx_exec.cpp" "$repo/Sources/Shared/ETJSFXHost.cpp" \
      "$here/Native/et_lice_font_linux.cpp" "$native/ETExternalProcessor.o" "$native/ETVMGlueCheck.o" \
      "${vm_objs[@]}" "$objs"/*.o \
      -pthread -o "$exec_bin"
  } 2>&1 | tee -a "$build_log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" = 0 ] || { echo "== jsfxexec build failed ($status). log $build_log"; exit "$status"; }
  # jsfxvmdiff: 同じ ysfx と Sources/JSFXVM の .o に、的の 1 本を足す（ETJSFXHost は通らない）。
  if [ "$vmdiff_needed" = 1 ]; then
    vmdiff_bin="$native/jsfx_vmdiff"
    # 上の { … } | tee は別のシェルで回るので、.o の並びはここで作り直す。
    vm_objs=()
    for f in "$repo"/Sources/JSFXVM/*.cpp; do vm_objs+=("$native/$(basename "$f").o"); done
    set +e
    "$cxx" -std=c++20 "${san[@]}" -fsanitize=fuzzer,address,undefined "${ysfx_defs[@]}" "${inc[@]}" \
      -I "$repo/Sources/Shared" -I "$repo/Sources/JSFXVM" \
      "$here/Native/jsfx_vmdiff.cpp" "$repo/Sources/Shared/ETJSFXHost.cpp" \
      "$here/Native/et_lice_font_linux.cpp" "$native/ETExternalProcessor.o" "$native/ETVMGlueCheck.o" \
      "${vm_objs[@]}" "$objs"/*.o -pthread -o "$vmdiff_bin" 2>&1 | tee -a "$build_log"
    status=${PIPESTATUS[0]}
    set -e
    [ "$status" = 0 ] || { echo "== jsfxvmdiff build failed ($status). log $build_log"; exit "$status"; }
  fi
fi

# 的ごとの見本（リポジトリにあるもの）。ファイルでもフォルダでもよい。
seed_files() {
  case $1 in
    chaintext|sharelink) echo "$repo/CHAIN.md"; ls "$repo"/chain/v*/*.md 2>/dev/null || true ;;
    fxdlink) echo "$repo/site/test-vector.json" ;;
    jsfxtext|jsfxgate) ls "$repo"/Tests/Fixtures/JSFX/*.jsfx ;;
    jsfxvmdiff) ls "$here"/Corpus/jsfxexec/* "$repo"/Tests/Fixtures/JSFX/*.jsfx "$repo"/Debug/JSFXBench/*.jsfx \
                   "$repo"/Tools/jsfx-bench/diff/*.jsfx 2>/dev/null || true ;;
    *) ;;
  esac
}
dict_for() {
  case $1 in
    chaintext|sharelink|pipelineform) echo "$here/Dict/json.dict" ;;
    fxdlink) echo "$here/Dict/fxd.dict" ;;
    peqtext) echo "$here/Dict/peq.dict" ;;
    remotefile) echo "$here/Dict/remote.dict" ;;
    jsfxtext|jsfxgate) echo "$here/Dict/jsfx.dict" ;;
    jsfxexec|jsfxvmdiff) echo "$here/Dict/jsfxexec.dict" ;;
    *) ;;
  esac
}
max_len() {
  case $1 in
    irprep) echo 20000 ;;
    chaintext|sharelink|jsfxgate|jsfxexec|jsfxvmdiff) echo 16384 ;;
    *) echo 8192 ;;
  esac
}
# 1 入力の持ち時間（秒）。jsfxexec は止まらないスクリプト（入れ子の loop・@sample の while）を
# ここで切る。普通の入力は数ミリ秒なので短くして、時間切れで溶かす時間を減らす。
timeout_for() {
  case $1 in
    jsfxexec|jsfxvmdiff) echo 10 ;;
    *) echo 20 ;;
  esac
}

failed=()
summary=()
for t in "${selected[@]}"; do
  log="$repo/build/fuzz-$name-$t.log"
  corpus="$work/corpus/$t"
  seeds="$work/seeds/$t"
  artifacts="$out/$t/"
  mkdir -p "$corpus" "$artifacts"
  rm -rf "$seeds"; mkdir -p "$seeds"
  if [ -d "$here/Corpus/$t" ]; then cp -R "$here/Corpus/$t/." "$seeds/"; fi
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && cp "$f" "$seeds/seed-$(basename "$f")"
  done < <(seed_files "$t")

  if [ "$t" = jsfxgate ]; then
    cmd=("$gate")
  elif [ "$t" = jsfxexec ] || [ "$t" = jsfxvmdiff ]; then
    # 見つけて直していない UB の表（中身は Native/jsfx_exec.ubsan.supp の頭）。
    # FUZZ_UBSAN_SUPPRESSIONS= （空）で外すと、表の分も止まる（直ったかを見るとき）。
    supp=${FUZZ_UBSAN_SUPPRESSIONS-$here/Native/jsfx_exec.ubsan.supp}
    tbin=$exec_bin
    [ "$t" = jsfxvmdiff ] && tbin=$vmdiff_bin
    if [ -n "$supp" ]; then cmd=(env "UBSAN_OPTIONS=$UBSAN_OPTIONS:suppressions=$supp" "$tbin")
    else cmd=("$tbin"); fi
  else
    cmd=("$bin")
    export ET_FUZZ_TARGET=$t
    ET_FUZZ_SEEDS_OUT="$seeds/gen" "$bin" >/dev/null
  fi
  dict=$(dict_for "$t")
  args=(-max_len="$(max_len "$t")" -timeout="$(timeout_for "$t")" -rss_limit_mb=3072
        -print_final_stats=1 -artifact_prefix="$artifacts")
  if [ -n "$dict" ] && [ -f "$dict" ]; then args+=(-dict="$dict"); fi
  # jsfxexec は子プロセスで回す（-fork）。時間切れの入力は timeout-* に残して先へ進む
  # （EEL2 は loop を 1048576 周で切るが、入れ子は切れない。アプリでは締切と見張りが受け持つ）。
  # 落ち・ASan / UBSan・メモリの上限（-rss_limit_mb、1 回の確保は -malloc_limit_mb の既定＝同じ値）は止まる。
  fuzz_only=()
  if [ "$t" = jsfxexec ] || [ "$t" = jsfxvmdiff ]; then
    fuzz_only=(-fork="${FUZZ_FORK:-1}" -ignore_timeouts=1 -ignore_ooms=0 -ignore_crashes=0)
  fi

  echo "== $t" | tee "$log"
  # -fork の子が UBSan・ASan で止まると、子は crash-* を書くが終了値が -error_exitcode と違い、親は落ちと
  # 数えずに先へ進むことがある（jsfxvmdiff で見た）。回す前後の crash-* を比べ、増えていたら落ちとする。
  crashes_before=$(find "$artifacts" -maxdepth 1 -name 'crash-*' 2>/dev/null | sort || true)
  set +e
  if [ -n "$repro" ]; then
    "${cmd[@]}" "${args[@]}" "${passthrough[@]}" "$repro" 2>&1 | tee -a "$log"
  elif [ "$build_only" = 1 ]; then
    echo "== build-only: seeds $(find "$seeds" -type f | wc -l)" | tee -a "$log"
    (exit 0)
  else
    "${cmd[@]}" "${args[@]}" "${fuzz_only[@]}" -max_total_time="$seconds" "${passthrough[@]}" \
      "$corpus" "$seeds" 2>&1 | tee -a "$log"
  fi
  status=${PIPESTATUS[0]}
  set -e
  if [ -z "$repro" ] && [ "$build_only" != 1 ]; then
    new_crashes=$(comm -13 <(printf '%s\n' "$crashes_before") \
      <(find "$artifacts" -maxdepth 1 -name 'crash-*' 2>/dev/null | sort) | grep -v '^$' || true)
    if [ -n "$new_crashes" ]; then
      echo "== $t: new crash inputs (the fork parent did not stop):" | tee -a "$log"
      printf '%s\n' "$new_crashes" | tee -a "$log"
      [ "$status" != 0 ] || status=1
    fi
  fi
  execs=$(grep -Eo "stat::number_of_executed_units: *[0-9]+" "$log" | grep -Eo "[0-9]+$" | tail -1 || true)
  cov=$(grep -Eo "cov: [0-9]+" "$log" | tail -1 || true)
  # -fork の親は stat:: を出さず、"#<回数>: cov: … job: …" の行で合計を出す（落ちたときに
  # 貼る子のログの stat:: は子の 1 本分）。親の行が在ればそちらを読む。
  if grep -Eq "^#[0-9]+: cov: [0-9]+ .* job: " "$log"; then
    execs=$(grep -E "^#[0-9]+: cov: [0-9]+ .* job: " "$log" | tail -1 | grep -Eo "^#[0-9]+" | tr -d '#')
    cov=$(grep -E "^#[0-9]+: cov: [0-9]+ .* job: " "$log" | tail -1 | grep -Eo "cov: [0-9]+")
  fi
  line="$t: exit $status, runs ${execs:-?}, ${cov:-cov ?}, corpus $(find "$corpus" -type f | wc -l)"
  timeouts=$(grep -Eo "oom/timeout/crash: [0-9]+/[0-9]+/[0-9]+" "$log" | tail -1 \
    | grep -Eo "[0-9]+/[0-9]+/[0-9]+" | cut -d/ -f2 || true)
  if [ -n "$timeouts" ] && [ "$timeouts" != 0 ]; then line+=", timeouts $timeouts ($artifacts)"; fi
  summary+=("$line")
  if [ "$status" != 0 ]; then failed+=("$t"); fi
done

for s in "${summary[@]}"; do echo "== FUZZ $s" | tee -a "$build_log"; done
if [ ${#failed[@]} -gt 0 ]; then
  echo "== FUZZ failed: ${failed[*]}  (inputs in $out/<target>/, logs build/fuzz-$name-<target>.log)" \
    | tee -a "$build_log"
  exit 1
fi
echo "== FUZZ ok: ${selected[*]}" | tee -a "$build_log"
