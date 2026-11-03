#!/bin/bash
# Scripts/lib/sim.sh と、それを使う Scripts/*.sh を Mac なしで確かめる。
#
#   bash Tests/Scripts/sim_test.sh
#   SCRIPTS_UNDER_TEST=<dir> bash Tests/Scripts/sim_test.sh   別の版の Scripts/（直す前の赤を見るとき）
#
# xcrun・xcodegen・xcodebuild・python3・security・sleep・curl・unzip・shasum・PlistBuddy を
# 偽物に差し替える。偽物の simctl list は決めた一覧を返し、どの偽物も呼ばれた引数を calls.log に書く。
# Scripts/setup.sh も偽物にする。Tools/asc.py は本物を、App Store Connect の返事だけ決めて走らせる
# （Tests/Scripts/asc_fake_api.py）。
#
# 偽物は PATH の先頭に置くだけでなく、同じ名前の関数にして export -f で渡す。台本は頭で
# `export PATH="/opt/homebrew/bin:$PATH"` を足すので、Mac では PATH だけだと Homebrew の本物の
# xcodegen と python3 が偽物より先に拾われる。関数は PATH より先に引かれ、bash 3.2 でも効く。
# 名指しの /usr/bin/xcodebuild と /usr/libexec/PlistBuddy は ET_XCODEBUILD・ET_PLISTBUDDY で
# 偽物に向ける（台本側の既定は名指しのまま）。HOME も一時ディレクトリにするので、Mac で走らせても
# 鍵・キーチェーンの合言葉・書き出しの設定には触らない。
#
# Scripts/ は一時ディレクトリへ写して走らせるので、test.log などはそちらに書かれ、
# 作業ツリーは汚れない。Linux の bash でも Mac の /bin/bash 3.2 でも走る形で書く。
set -u
# 台本が読む環境変数は持ち込まない（CI の SIM_OS が漏れて端末の選び方の試験が 1 件落ちたことがある）。
unset APPICON ARCHIVE_DIR BUILD_JOBS CLEAN COLLAPSED CONFIG DEV_ID DRY_RUN EXPORT_DIR LAYOUT NO_WAIT \
  SAN SHEET SHOW SIM SIM_NAME SIM_OS SIM_UDID SKIP_ARCHIVE SKIP_BUILD SKIP_INSTALL SKIP_SETUP \
  SKIP_XCODEGEN SLEEP WAIT WIDTH XCODEBUILD_EXTRA ET_XCODEBUILD ET_PLISTBUDDY
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SRC="${SCRIPTS_UNDER_TEST:-$REPO/Scripts}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/et-scripts-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# 台本の $PWD と突き合わせるので、// や symlink（Mac の /var → /private/var）を先に解いておく。
WORK=$(cd "$WORK" && pwd -P)

ROOT="$WORK/root"
STUB_DIR="$WORK/stub"
OUTF="$WORK/out.txt"
CALLS="$STUB_DIR/calls.log"
# 本物の python3（asc.py を走らせるため）。無ければ asc.py を読む試験は飛ばす。
REAL_PY=$(command -v python3 2>/dev/null || true)
ASC_FAKE="$HERE/asc_fake_api.py"
export STUB_DIR REAL_PY ASC_FAKE

IPAD13=0DCB706C-8169-4EE7-87B1-C2C12C074245
IPAD11=D78EFBC3-8635-4B51-BA79-648FEC435088
OLDIPAD=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
CLONE=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
WATCH=CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC
UNAVAIL=DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD
P18=4102BEEF-6704-4570-90FC-B9BDEE577469
P17_26=11111111-1111-4111-8111-111111111111
P17_27=9B054D93-0516-4F6E-9B66-8716209F4132
PHONE=00008140-000C094A2E32801C
KEY_ID=JYMYS92KUB
ISSUER=175cb308-6a31-42f0-970a-e72757f60bde

PASS=0
FAIL=0
SKIP=0
FAILED=""
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
ng() { FAIL=$((FAIL + 1)); FAILED="$FAILED $1"; echo "FAIL $1${2:+ -- $2}"; }
skip() { SKIP=$((SKIP + 1)); echo "skip $1${2:+ -- $2}"; }
has()     { grep -qF -- "$2" "$1"; }
hasnt()   { ! grep -qF -- "$2" "$1"; }
hasline() { grep -qxF -- "$2" "$1"; }
count()   { grep -cF -- "$2" "$1"; }
# calls.log に simctl list 以外（状態を変えるもの）が 1 行も無いか。
only_reads() { ! grep -v '^xcrun simctl list' "$CALLS" | grep -q .; }
sha256() { "$REAL_PY" -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }

# ---- 偽物 -------------------------------------------------------------------
mkdir -p "$STUB_DIR/bin" "$ROOT/Scripts" "$ROOT/Tools" "$ROOT/Vendor/effetune/dsp" "$WORK/home/signing"
cp "$REPO/Tools/asc.py" "$ROOT/Tools/asc.py"
echo "not-the-real-password" > "$WORK/home/signing/kc.pw"
echo "<plist/>" > "$WORK/home/signing/export.plist"

cat > "$STUB_DIR/bin/xcrun" <<'EOF'
#!/bin/bash
echo "xcrun $*" >> "$STUB_DIR/calls.log"
case "$*" in
  "simctl list devices available") cat "$STUB_DIR/available.txt" ;;
  "simctl list devices") cat "$STUB_DIR/all.txt" ;;
  "devicectl list devices") cat "$STUB_DIR/devices.txt" 2>/dev/null ;;
  "devicectl device install app "*)
    code="${STUB_INSTALL_EXIT:-0}"
    if [ "$code" = 0 ]; then echo "App installed:"; else echo "ERROR: install failed"; fi
    exit "$code" ;;
  "simctl bootstatus "*) exit "${STUB_BOOTSTATUS_EXIT:-0}" ;;
  "altool "*)
    code="${STUB_ALTOOL_EXIT:-0}"
    if [ "$code" = 0 ]; then echo "UPLOAD SUCCEEDED"; else echo "ERROR: upload failed"; fi
    exit "$code" ;;
esac
exit 0
EOF
# archive_install.sh がキーチェーンを開ける。Mac で走らせても本物に触らない。
cat > "$STUB_DIR/bin/security" <<'EOF'
#!/bin/bash
echo "security $1" >> "$STUB_DIR/calls.log"
exit 0
EOF
cat > "$STUB_DIR/bin/xcodegen" <<'EOF'
#!/bin/bash
echo "xcodegen $*" >> "$STUB_DIR/calls.log"
exit "${STUB_XCODEGEN_EXIT:-0}"
EOF
# 通ったときは成果物を置く: -exportPath に EffectDeck.ipa、archive の -archivePath に書庫、
# CONFIGURATION_BUILD_DIR に EffectDeck.app（STUB_XCODEBUILD_NO_APP=1 なら置かない）。
# 最後の引数が test なら、通ったテスト 1 件の行を出す（STUB_XCODEBUILD_NO_TESTS=1 なら出さない。
# -only-testing の名前が外れて何も走らなかった回の形）。
cat > "$STUB_DIR/bin/xcodebuild" <<'EOF'
#!/bin/bash
echo "xcodebuild $*" >> "$STUB_DIR/calls.log"
if [ "${1:-}" = "-version" ]; then echo "Xcode 27.0"; exit 0; fi
code="${STUB_XCODEBUILD_EXIT:-0}"
prev="" ipa="" arch="" app="" archive=0
for a in "$@"; do
  case "$prev" in
    -exportPath) ipa="$a" ;;
    -archivePath) arch="$a" ;;
  esac
  case "$a" in
    CONFIGURATION_BUILD_DIR=*) app="${a#CONFIGURATION_BUILD_DIR=}" ;;
    archive) archive=1 ;;
  esac
  prev="$a"
done
if [ "$code" != 0 ]; then echo "** TEST FAILED **"; exit "$code"; fi
[ -z "$ipa" ] || { mkdir -p "$ipa" && : > "$ipa/EffectDeck.ipa"; }
[ "$archive" = 0 ] || [ -z "$arch" ] || mkdir -p "$arch/Products/Applications/EffectDeck.app"
[ "$archive" = 0 ] || echo "** ARCHIVE SUCCEEDED **"
[ -z "$app" ] || [ "${STUB_XCODEBUILD_NO_APP:-0}" = 1 ] || mkdir -p "$app/EffectDeck.app"
if [ "$prev" = test ] && [ "${STUB_XCODEBUILD_NO_TESTS:-0}" != 1 ]; then
  echo "Test Case '-[EffeTuneLiveUnitTests.StubTests testStub]' started."
  echo "Test Case '-[EffeTuneLiveUnitTests.StubTests testStub]' passed (0.001 seconds)."
fi
echo "** TEST SUCCEEDED **"
exit 0
EOF
# Tools/asc.py だけは本物を走らせる（asc_api.json があるとき）。ほかは呼ばれたことを書くだけ。
cat > "$STUB_DIR/bin/python3" <<'EOF'
#!/bin/bash
echo "python3 $*" >> "$STUB_DIR/calls.log"
case "${1:-}" in
  Tools/asc.py|*/Tools/asc.py)
    if [ -f "$STUB_DIR/asc_api.json" ] && [ -n "$REAL_PY" ]; then
      exec "$REAL_PY" "$ASC_FAKE" "$@"
    fi ;;
esac
exit "${STUB_PY_EXIT:-0}"
EOF
cat > "$STUB_DIR/bin/sleep" <<'EOF'
#!/bin/bash
echo "sleep $*" >> "$STUB_DIR/calls.log"
exit 0
EOF
# URL の最後の区切り（? より前）の名前で $STUB_DIR/net/ から写す。無ければ curl -f と同じく 22。
cat > "$STUB_DIR/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$STUB_DIR/calls.log"
prev="" out="" url=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
name="${url%%[?]*}"
name="${name##*/}"
[ -n "$name" ] && [ -f "$STUB_DIR/net/$name" ] || exit 22
cp "$STUB_DIR/net/$name" "$out"
EOF
# -d <先> なら $STUB_DIR/pkgtree/ を写す（ADP の zip）。-p なら Info.plist の代わりを出す。
cat > "$STUB_DIR/bin/unzip" <<'EOF'
#!/bin/bash
echo "unzip $*" >> "$STUB_DIR/calls.log"
prev="" dest="" p=0
for a in "$@"; do
  [ "$prev" = "-d" ] && dest="$a"
  [ "$a" = "-p" ] && p=1
  prev="$a"
done
if [ "$p" = 1 ]; then echo "<plist/>"; exit 0; fi
[ -n "$dest" ] || exit 9
mkdir -p "$dest" && cp -R "$STUB_DIR/pkgtree/." "$dest/"
EOF
# shasum の無い Linux もあるので、あれば sha256sum で同じ形に出す。
cat > "$STUB_DIR/bin/shasum" <<'EOF'
#!/bin/bash
f="${!#}"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f"; else /usr/bin/shasum -a 256 "$f"; fi
EOF
cat > "$STUB_DIR/bin/PlistBuddy" <<'EOF'
#!/bin/bash
echo "PlistBuddy $*" >> "$STUB_DIR/calls.log"
[ -n "${STUB_BUILD_NUM:-}" ] || exit 1
echo "$STUB_BUILD_NUM"
EOF
chmod +x "$STUB_DIR/bin/"*

# 偽物を効かせる（subshell の中で呼ぶ）。STUB_DEFAULT_TOOLS=1 なら ET_XCODEBUILD と
# ET_PLISTBUDDY を渡さず、台本の既定（名指し）を出させる。DRY_RUN の試験でだけ使う。
use_stubs() {
  local f n
  PATH="$STUB_DIR/bin:$PATH"
  HOME="$WORK/home"
  export PATH HOME
  if [ "${STUB_DEFAULT_TOOLS:-0}" = 1 ]; then
    unset ET_XCODEBUILD ET_PLISTBUDDY
  else
    ET_XCODEBUILD=xcodebuild
    ET_PLISTBUDDY=PlistBuddy
    export ET_XCODEBUILD ET_PLISTBUDDY
  fi
  for f in "$STUB_DIR"/bin/*; do
    n="${f##*/}"
    eval "$n() { \"\$STUB_DIR/bin/$n\" \"\$@\"; }"
    export -f "${n?}"
  done
}

# 端末の一覧。状態は S_* で変える。名前の似た囮（前に何か付く・後ろに何か付く・11 インチ）と、
# 使えない runtime に居る同じ名前の端末を混ぜてある。後ろに何か付く囮は本物より後に置く
# （部分一致で引くと、同じ名前が複数あるときの「一覧の最後」にそれが選ばれて落ちるように）。
write_lists() {
  {
    echo "== Devices =="
    echo "-- iOS 26.4 --"
    echo "    iPhone 17 Pro ($P17_26) (${S_P17_26:-Shutdown}) "
    echo "-- iOS 27.0 --"
    echo "    iPhone 18 Pro ($P18) (${S_P18:-Booted}) "
    echo "    iPhone 17 Pro ($P17_27) (${S_P17_27:-Shutdown}) "
    echo "    Old iPad Pro 13-inch (M5) ($OLDIPAD) (Shutdown) "
    echo "    iPad Pro 13-inch (M5) ($IPAD13) (${S_IPAD13:-Shutdown}) "
    echo "    iPad Pro 13-inch (M5) Clone ($CLONE) (Shutdown) "
    echo "    iPad Pro 11-inch (M5) ($IPAD11) (Shutdown) "
    echo "-- watchOS 27.0 --"
    echo "    Apple Watch Series 11 (46mm) ($WATCH) (${S_WATCH:-Booted}) "
  } > "$STUB_DIR/available.txt"
  {
    cat "$STUB_DIR/available.txt"
    echo "-- Unavailable: com.apple.CoreSimulator.SimRuntime.iOS-26-0 --"
    echo "    iPad Air 13-inch (M3) ($UNAVAIL) (Shutdown) (unavailable, runtime profile not found)"
  } > "$STUB_DIR/all.txt"
}

# テストごとに作り直す。
fresh() {
  unset S_P17_26 S_P18 S_P17_27 S_IPAD13 S_WATCH
  write_lists
  : > "$CALLS"
  rm -rf "$STUB_DIR/devices.txt" "$STUB_DIR/asc_api.json" "$STUB_DIR/asc_count.json" \
    "$STUB_DIR/net" "$STUB_DIR/pkgtree"
  rm -rf "$ROOT/Scripts" "$ROOT/build" "$ROOT/out" "$ROOT/out-sim" "$ROOT"/*.log \
    "$WORK/arch" "$WORK/ipa" "$WORK/adp"
  mkdir -p "$ROOT/Scripts" "$STUB_DIR/net" "$STUB_DIR/pkgtree"
  cp -R "$SRC/." "$ROOT/Scripts/"
  cat > "$ROOT/Scripts/setup.sh" <<'EOF'
#!/bin/bash
echo "setup SKIP_XCODEGEN=${SKIP_XCODEGEN:-}" >> "$STUB_DIR/calls.log"
exit "${STUB_SETUP_EXIT:-0}"
EOF
}

# リポジトリの根から Scripts/<名前> を走らせる。出力は OUTF、終了値は RC。
run_script() {
  local name="$1"
  shift
  (cd "$ROOT" && use_stubs && bash "Scripts/$name" "$@") > "$OUTF" 2>&1
  RC=$?
}

# lib/sim.sh を読み込んだ subshell で 1 行走らせる。
run_lib() {
  if [ ! -f "$ROOT/Scripts/lib/sim.sh" ]; then
    echo "(Scripts/lib/sim.sh が無い)" > "$OUTF"
    RC=99
    return
  fi
  (cd "$ROOT" && use_stubs && ROOT="$ROOT" bash -c '. Scripts/lib/sim.sh; '"$1") > "$OUTF" 2>&1
  RC=$?
}

# 実機が 1 台つながっている形（devicectl list devices）。
one_phone() {
  echo "iPhone 16   iPhone-16.coredevice.local   $PHONE   available (paired)   iPhone 16 (iPhone17,3)   physical" \
    > "$STUB_DIR/devices.txt"
}

# ---- Scripts/lib/sim.sh ------------------------------------------------------
fresh
run_lib 'sim_select && echo "UDID=$SIM_UDID NAME=$SIM_NAME"'
if [ "$RC" = 0 ] && has "$OUTF" "UDID=$IPAD13 NAME=iPad Pro 13-inch (M5)" && hasnt "$OUTF" "台ある"; then
  ok lib_default_is_ipad_pro_13_exact_name
else ng lib_default_is_ipad_pro_13_exact_name "$(head -3 "$OUTF")"; fi

fresh
run_lib 'SIM="iPhone 99" sim_select; echo "rc=$? UDID=[$SIM_UDID]"'
if has "$OUTF" "rc=1 UDID=[]" && hasnt "$CALLS" "create" && hasnt "$CALLS" "boot"; then
  ok lib_missing_name_stops_without_fallback
else ng lib_missing_name_stops_without_fallback "$(tail -2 "$OUTF")"; fi

fresh
run_lib "SIM=$P18 sim_select && echo \"NAME=\$SIM_NAME\""
if [ "$RC" = 0 ] && has "$OUTF" "NAME=iPhone 18 Pro"; then ok lib_udid_accepted
else ng lib_udid_accepted "$(head -3 "$OUTF")"; fi

fresh
run_lib 'SIM=EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE sim_select'
if [ "$RC" != 0 ]; then ok lib_unknown_udid_rejected; else ng lib_unknown_udid_rejected; fi

fresh
run_lib 'SIM="iPad Air 13-inch (M3)" sim_select'
if [ "$RC" != 0 ]; then ok lib_unavailable_device_not_picked; else ng lib_unavailable_device_not_picked; fi

fresh
run_lib 'SIM="iPhone 17 Pro" sim_select && echo "UDID=$SIM_UDID"'
a_ok=0; has "$OUTF" "UDID=$P17_27" && a_ok=1
S_P17_26=Booted write_lists
run_lib 'SIM="iPhone 17 Pro" sim_select && echo "UDID=$SIM_UDID"'
b_ok=0; has "$OUTF" "UDID=$P17_26" && b_ok=1
write_lists
run_lib 'SIM="iPhone 17 Pro" SIM_OS=26.4 sim_select && echo "UDID=$SIM_UDID"'
c_ok=0; has "$OUTF" "UDID=$P17_26" && c_ok=1
if [ "$a_ok$b_ok$c_ok" = 111 ]; then ok lib_duplicate_name_booted_then_newest_then_sim_os
else ng lib_duplicate_name_booted_then_newest_then_sim_os "last=$a_ok booted=$b_ok os=$c_ok"; fi

fresh
run_lib 'sim_select && sim_only'
if [ "$RC" = 0 ] && has "$CALLS" "xcrun simctl shutdown $P18" && has "$CALLS" "xcrun simctl shutdown $WATCH" \
   && hasnt "$CALLS" "xcrun simctl shutdown $IPAD13" && has "$CALLS" "xcrun simctl boot $IPAD13" \
   && has "$CALLS" "xcrun simctl bootstatus $IPAD13 -b"; then
  ok lib_sim_only_shuts_every_other_booted_device
else ng lib_sim_only_shuts_every_other_booted_device "$(grep -v 'simctl list' "$CALLS" | tr '\n' ';')"; fi

fresh
S_IPAD13=Booted S_P18=Shutdown S_WATCH=Shutdown write_lists
run_lib 'sim_select && sim_only'
if [ "$RC" = 0 ] && hasnt "$CALLS" "simctl boot " && hasnt "$CALLS" "simctl shutdown" \
   && has "$CALLS" "xcrun simctl bootstatus $IPAD13 -b"; then
  ok lib_sim_only_no_second_boot_when_already_up
else ng lib_sim_only_no_second_boot_when_already_up "$(grep -v 'simctl list' "$CALLS" | tr '\n' ';')"; fi

fresh
run_lib 'DRY_RUN=1; sim_select && sim_only'
if [ "$RC" = 0 ] && only_reads && has "$OUTF" "+ xcrun simctl shutdown $P18"; then
  ok lib_dry_run_changes_nothing
else ng lib_dry_run_changes_nothing "$(grep -v 'simctl list' "$CALLS" | tr '\n' ';')"; fi

# 起こしても起動し終わらなければ止まる（テストも撮影も、起ききっていない端末で始めない）。
fresh
STUB_BOOTSTATUS_EXIT=1 run_lib 'sim_select && sim_only; echo "rc=$?"'
if has "$OUTF" "rc=1" && has "$OUTF" "!! 起動し終わるのを待てない: iPad Pro 13-inch (M5) ($IPAD13)"; then
  ok lib_sim_only_bootstatus_failure_stops
else ng lib_sim_only_bootstatus_failure_stops "$(tail -2 "$OUTF" | tr '\n' ';')"; fi

# 撮るためのアプリ。建てられても out-sim/EffectDeck.app が無ければ止まる（古いものを撮らない）。
line="xcodebuild -project EffeTuneLiveSim.xcodeproj -scheme EffeTuneLive -configuration Debug -sdk iphonesimulator -arch arm64 -jobs 2 CONFIGURATION_BUILD_DIR=$ROOT/out-sim build"
fresh
run_lib 'sim_build_app "$ROOT/b.log"; echo "rc=$?"'
a_ok=0; has "$OUTF" "rc=0" && hasline "$CALLS" "$line" && a_ok=1
fresh
mkdir -p "$ROOT/out-sim/EffectDeck.app"
STUB_XCODEBUILD_NO_APP=1 run_lib 'sim_build_app "$ROOT/b.log"; echo "rc=$?"'
b_ok=0; has "$OUTF" "rc=1" && has "$OUTF" "!! 成果物が無い: out-sim/EffectDeck.app" && b_ok=1
fresh
STUB_XCODEBUILD_EXIT=65 run_lib 'sim_build_app "$ROOT/b.log"; echo "rc=$?"'
c_ok=0; has "$OUTF" "rc=1" && has "$OUTF" "(exit 65)" && c_ok=1
if [ "$a_ok$b_ok$c_ok" = 111 ]; then ok lib_sim_build_app_stops_without_fresh_app
else ng lib_sim_build_app_stops_without_fresh_app "built=$a_ok no_app=$b_ok failed=$c_ok"; fi

# ---- Scripts/test.sh ---------------------------------------------------------
fresh
DRY_RUN=1 run_script test.sh
line="+ xcodebuild -project EffeTuneLive.xcodeproj -scheme Logic -destination id=$IPAD13 -parallel-testing-enabled NO -resultBundlePath $ROOT/build/Logic.xcresult -only-testing:EffeTuneLiveUnitTests test"
if [ "$RC" = 0 ] && has "$OUTF" "$line" && only_reads && [ ! -e "$ROOT/test.log" ]; then
  ok test_dry_run_one_ipad_no_parallel_result_bundle
else ng test_dry_run_one_ipad_no_parallel_result_bundle "rc=$RC $(grep xcodebuild "$OUTF" | head -1)"; fi

# DRY_RUN が出す行と、本当に走る xcodebuild の引数が同じか（SAN・XCODEBUILD_EXTRA・絞りまで）。
line="xcodebuild -project EffeTuneLive.xcodeproj -scheme Logic -destination id=$IPAD13 -parallel-testing-enabled NO -resultBundlePath $ROOT/build/Logic.xcresult -enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES CODE_SIGNING_ALLOWED=NO -quiet -only-testing:EffeTuneLiveUnitTests/ChainTextTests -only-testing:EffeTuneLiveUnitTests/FXDLinkTests/testRoute test"
fresh
SAN=address,undefined XCODEBUILD_EXTRA="CODE_SIGNING_ALLOWED=NO -quiet" DRY_RUN=1 \
  run_script test.sh ChainTextTests FXDLinkTests/testRoute
dry=$(grep '^+ xcodebuild ' "$OUTF" | sed 's/^+ //')
SAN=address,undefined XCODEBUILD_EXTRA="CODE_SIGNING_ALLOWED=NO -quiet" \
  run_script test.sh ChainTextTests FXDLinkTests/testRoute
real=$(grep '^xcodebuild ' "$CALLS")
if [ "$RC" = 0 ] && [ "$dry" = "$line" ] && [ "$real" = "$line" ]; then
  ok test_san_extra_and_filters_reach_the_xcodebuild_that_runs
else ng test_san_extra_and_filters_reach_the_xcodebuild_that_runs "rc=$RC real=[$real] dry=[$dry]"; fi

fresh
SAN=address,thread DRY_RUN=1 run_script test.sh
rc1=$RC; x1=0; has "$OUTF" "xcodebuild" && x1=1
SAN=memory DRY_RUN=1 run_script test.sh
rc2=$RC; x2=0; has "$OUTF" "xcodebuild" && x2=1
if [ "$rc1" = 2 ] && [ "$rc2" = 2 ] && [ "$x1$x2" = 00 ]; then ok test_san_conflict_and_unknown_rejected
else ng test_san_conflict_and_unknown_rejected "rc=$rc1/$rc2"; fi

fresh
SIM="iPhone 99" run_script test.sh
if [ "$RC" != 0 ] && hasnt "$CALLS" "setup" && hasnt "$CALLS" "xcodegen" && hasnt "$CALLS" "xcodebuild" \
   && hasnt "$CALLS" "create"; then
  ok test_missing_simulator_stops_before_anything
else ng test_missing_simulator_stops_before_anything "rc=$RC $(grep -v 'simctl list' "$CALLS" | tr '\n' ';')"; fi

fresh
run_script test.sh
order=$(grep -v 'simctl list' "$CALLS" | sed 's/ .*//' | uniq | tr '\n' ' ')
line="xcodebuild -project EffeTuneLive.xcodeproj -scheme Logic -destination id=$IPAD13 -parallel-testing-enabled NO -resultBundlePath $ROOT/build/Logic.xcresult -only-testing:EffeTuneLiveUnitTests test"
if [ "$RC" = 0 ] && has "$CALLS" "setup SKIP_XCODEGEN=1" && has "$CALLS" "xcodegen generate --spec project.yml" \
   && has "$CALLS" "xcrun simctl shutdown $P18" && [ "$order" = "setup xcodegen xcrun xcodebuild " ] \
   && hasline "$CALLS" "$line" && has "$ROOT/test.log" "** TEST SUCCEEDED **"; then
  ok test_runs_setup_xcodegen_one_sim_then_xcodebuild
else ng test_runs_setup_xcodegen_one_sim_then_xcodebuild "rc=$RC order=$order"; fi

fresh
STUB_XCODEGEN_EXIT=1 run_script test.sh
if [ "$RC" != 0 ] && has "$CALLS" "xcodegen generate" && hasnt "$CALLS" "xcodebuild"; then
  ok test_xcodegen_failure_stops
else ng test_xcodegen_failure_stops "rc=$RC"; fi

fresh
STUB_SETUP_EXIT=1 run_script test.sh
if [ "$RC" != 0 ] && has "$CALLS" "setup" && hasnt "$CALLS" "xcodegen" && hasnt "$CALLS" "xcodebuild"; then
  ok test_setup_failure_stops
else ng test_setup_failure_stops "rc=$RC"; fi

fresh
SKIP_SETUP=1 run_script test.sh
if [ "$RC" = 0 ] && hasnt "$CALLS" "setup" && has "$CALLS" "xcodegen generate --spec project.yml"; then
  ok test_skip_setup_still_regenerates_project
else ng test_skip_setup_still_regenerates_project "rc=$RC"; fi

fresh
STUB_XCODEBUILD_EXIT=65 run_script test.sh
if [ "$RC" = 65 ] && has "$OUTF" "(exit=65)"; then ok test_xcodebuild_exit_code_propagates
else ng test_xcodebuild_exit_code_propagates "rc=$RC"; fi

# 1 件も走らなかった回は、xcodebuild が SUCCEEDED・0 で終わっても落ちにする。
fresh
run_script test.sh ChainTextTests
a_ok=0; [ "$RC" = 0 ] && has "$OUTF" "通った: 1" && hasnt "$OUTF" "1 件も走っていない" && a_ok=1
fresh
STUB_XCODEBUILD_NO_TESTS=1 run_script test.sh ChainTextTsets
b_ok=0; [ "$RC" = 1 ] && has "$OUTF" "(exit=1)" && has "$OUTF" "!! テストが 1 件も走っていない" \
  && has "$ROOT/test.log" "** TEST SUCCEEDED **" && has "$ROOT/test.log" "!! テストが 1 件も走っていない" && b_ok=1
if [ "$a_ok$b_ok" = 11 ]; then ok test_zero_tests_run_is_failure
else ng test_zero_tests_run_is_failure "ran=$a_ok none=$b_ok rc=$RC"; fi

# ---- Scripts/uitest.sh -------------------------------------------------------
# DRY_RUN は台本の既定（名指しの /usr/bin/xcodebuild）のまま出させる。
fresh
STUB_DEFAULT_TOOLS=1 DRY_RUN=1 run_script uitest.sh
line="+ /usr/bin/xcodebuild -project EffeTuneLiveSim.xcodeproj -scheme EffeTuneLive -destination id=$IPAD13 -jobs 2 -derivedDataPath $ROOT/DerivedData -parallel-testing-enabled NO -disable-concurrent-destination-testing -resultBundlePath $ROOT/build/UITest.xcresult -only-testing:EffeTuneLiveUITests/SmokeTests test"
if [ "$RC" = 0 ] && has "$OUTF" "+ python3 Tools/gen_sim_spec.py" \
   && has "$OUTF" "+ xcodegen generate --spec project-sim.yml" && has "$OUTF" "$line" \
   && has "$OUTF" "+ xcrun simctl terminate $IPAD13 ai.nemut.effetune" && only_reads; then
  ok uitest_dry_run_sim_project_one_device_smoke_tests
else ng uitest_dry_run_sim_project_one_device_smoke_tests "rc=$RC $(grep xcodebuild "$OUTF" | head -1)"; fi

# 本当に走らせる形。xcodebuild の終了値を返し、落ちてもアプリは落とす。
fresh
STUB_XCODEBUILD_EXIT=65 XCODEBUILD_EXTRA="CODE_SIGNING_ALLOWED=NO" run_script uitest.sh SmokeTests/test03AddEffect
line="xcodebuild -project EffeTuneLiveSim.xcodeproj -scheme EffeTuneLive -destination id=$IPAD13 -jobs 2 -derivedDataPath $ROOT/DerivedData -parallel-testing-enabled NO -disable-concurrent-destination-testing -resultBundlePath $ROOT/build/UITest.xcresult CODE_SIGNING_ALLOWED=NO -only-testing:EffeTuneLiveUITests/SmokeTests/test03AddEffect test"
order=$(grep -v 'simctl list' "$CALLS" | sed 's/ .*//' | uniq | tr '\n' ' ')
last=$(grep -v 'simctl list' "$CALLS" | tail -1)
if [ "$RC" = 65 ] && has "$OUTF" "(exit=65)" && hasline "$CALLS" "$line" \
   && [ "$order" = "setup python3 xcodegen xcrun xcodebuild xcrun " ] \
   && [ "$last" = "xcrun simctl terminate $IPAD13 ai.nemut.effetune" ]; then
  ok uitest_runs_the_same_command_and_returns_its_exit_code
else ng uitest_runs_the_same_command_and_returns_its_exit_code "rc=$RC order=$order last=$last"; fi

# 引数なしの SmokeTests がまだ無い回。何も走らなければ落ちにし、アプリは落とす。
fresh
STUB_XCODEBUILD_NO_TESTS=1 run_script uitest.sh
last=$(grep -v 'simctl list' "$CALLS" | tail -1)
if [ "$RC" = 1 ] && has "$OUTF" "(exit=1)" && has "$OUTF" "!! テストが 1 件も走っていない" \
   && has "$CALLS" "-only-testing:EffeTuneLiveUITests/SmokeTests test" \
   && [ "$last" = "xcrun simctl terminate $IPAD13 ai.nemut.effetune" ]; then
  ok uitest_zero_tests_run_is_failure
else ng uitest_zero_tests_run_is_failure "rc=$RC last=$last"; fi

fresh
STUB_PY_EXIT=1 run_script uitest.sh
if [ "$RC" != 0 ] && has "$CALLS" "python3 Tools/gen_sim_spec.py" && hasnt "$CALLS" "xcodegen"; then
  ok uitest_gen_sim_spec_failure_stops
else ng uitest_gen_sim_spec_failure_stops "rc=$RC"; fi

# ---- Scripts/shoot_*.sh ------------------------------------------------------
fresh
DRY_RUN=1 run_script shoot_all.sh VolumePlugin
if [ "$RC" = 0 ] && has "$OUTF" "+ xcrun simctl launch $IPAD13 ai.nemut.effetune -ETSeed VolumePlugin -ETMock 1" \
   && has "$OUTF" "+ env SKIP_XCODEGEN=1 bash Scripts/setup.sh" && has "$OUTF" "+ xcrun simctl shutdown $P18" \
   && only_reads; then
  ok shoot_all_uses_setup_and_one_ipad
else ng shoot_all_uses_setup_and_one_ipad "rc=$RC"; fi

fresh
DRY_RUN=1 SKIP_BUILD=1 run_script shoot_screens.sh
a_ok=0; has "$OUTF" "+ xcrun simctl launch $IPAD13 ai.nemut.effetune -ETSeed none -ETWidth 440 -ETMock 1" && a_ok=1
SIM="iPhone 18 Pro" DRY_RUN=1 SKIP_BUILD=1 run_script shoot_screens.sh
b_ok=0; has "$OUTF" "+ xcrun simctl launch $P18 ai.nemut.effetune -ETSeed none -ETWidth 0 -ETMock 1" && b_ok=1
LAYOUT=wide DRY_RUN=1 SKIP_BUILD=1 run_script shoot_screens.sh
c_ok=0; has "$OUTF" "-ETSheet picker -ETLayout wide" && c_ok=1
if [ "$a_ok$b_ok$c_ok" = 111 ] && only_reads; then ok shoot_screens_ipad_default_width_by_device
else ng shoot_screens_ipad_default_width_by_device "ipad=$a_ok iphone=$b_ok layout=$c_ok"; fi

fresh
DRY_RUN=1 run_script shoot_store.sh chain:routing
if [ "$RC" = 0 ] && has "$OUTF" "+ xcrun simctl launch $IPAD13 ai.nemut.effetune -ETSeed chain -ETWidth 440 -ETCollapsed 0 -ETMock 1 -ETSheet routing" \
   && has "$OUTF" "+ xcrun simctl install $IPAD13 $ROOT/out-sim/EffectDeck.app" && only_reads; then
  ok shoot_store_default_ipad_sheet_spec
else ng shoot_store_default_ipad_sheet_spec "rc=$RC $(grep 'simctl launch' "$OUTF" | head -1)"; fi

# ---- Scripts/build.sh --------------------------------------------------------
fresh
STUB_SETUP_EXIT=1 run_script build.sh
if [ "$RC" != 0 ] && has "$OUTF" "(exit=1)" && has "$ROOT/build.log" "!! Scripts/setup.sh" \
   && hasnt "$ROOT/build.log" "================ build"; then
  ok build_setup_failure_stops_and_exits_nonzero
else ng build_setup_failure_stops_and_exits_nonzero "rc=$RC $(tail -1 "$OUTF")"; fi

fresh
one_phone
run_script build.sh
line="xcodebuild -project EffeTuneLive.xcodeproj -scheme EffeTuneLive -configuration Debug -jobs 2 -sdk iphoneos -arch arm64 -allowProvisioningUpdates CONFIGURATION_BUILD_DIR=$ROOT/out build"
if [ "$RC" = 0 ] && has "$OUTF" "(exit=0)" && hasline "$CALLS" "$line" \
   && hasline "$CALLS" "xcrun devicectl device install app --device $PHONE out/EffectDeck.app" \
   && has "$ROOT/build.log" "=== done"; then
  ok build_builds_then_installs_on_the_phone
else ng build_builds_then_installs_on_the_phone "rc=$RC $(tail -1 "$OUTF")"; fi

# xcodebuild が落ちたら入れずに止まる（grep と tail の終了値で先へ進まない）。
fresh
one_phone
STUB_XCODEBUILD_EXIT=65 run_script build.sh
if [ "$RC" != 0 ] && has "$OUTF" "(exit=1)" && has "$ROOT/build.log" "!! xcodebuild が落ちた (exit 65)" \
   && hasnt "$CALLS" "device install"; then
  ok build_xcodebuild_failure_stops_before_install
else ng build_xcodebuild_failure_stops_before_install "rc=$RC $(grep '^!!' "$ROOT/build.log" | head -2 | tr '\n' ';')"; fi

fresh
one_phone
STUB_INSTALL_EXIT=1 run_script build.sh
if [ "$RC" != 0 ] && has "$OUTF" "(exit=1)" && has "$CALLS" "device install" \
   && has "$ROOT/build.log" "!! 入れられなかった" && hasnt "$ROOT/build.log" "=== done"; then
  ok build_install_failure_exits_nonzero
else ng build_install_failure_exits_nonzero "rc=$RC $(tail -1 "$OUTF")"; fi

# ---- Scripts/archive.sh ------------------------------------------------------
fresh
STUB_SETUP_EXIT=1 ARCHIVE_DIR="$WORK/arch" run_script archive.sh
if [ "$RC" != 0 ] && has "$CALLS" "setup" && has "$ROOT/archive.log" "!! Scripts/setup.sh" \
   && hasnt "$CALLS" "xcodebuild"; then
  ok archive_runs_setup_and_stops_on_failure
else ng archive_runs_setup_and_stops_on_failure "rc=$RC"; fi

# 紫（既定）は -configuration Beta、青は Release。アイコンと ET_BETA は project.yml の構成が決める
# ので、コマンドラインには ET_APPICON も SWIFT_ACTIVE_COMPILATION_CONDITIONS も載せない。
pre="xcodebuild -project EffeTuneLive.xcodeproj -scheme EffeTuneLive -configuration"
mid="-sdk iphoneos -arch arm64 -allowProvisioningUpdates"
post="archive -archivePath $WORK/arch/EffeTuneLive.xcarchive"
fresh
ARCHIVE_DIR="$WORK/arch" run_script archive.sh
a_ok=0; [ "$RC" = 0 ] && hasline "$CALLS" "$pre Beta $mid $post"   && [ -d "$WORK/arch/EffeTuneLive.xcarchive" ] && has "$ROOT/archive.log" "書庫: "   && has "$ROOT/archive.log" "config=Beta" && a_ok=1
fresh
ARCHIVE_DIR="$WORK/arch" run_script archive.sh EffeTuneLive EffeTuneLive
b_ok=0; [ "$RC" = 0 ] && hasline "$CALLS" "$pre Release $mid $post" && b_ok=1
fresh
ARCHIVE_DIR="$WORK/arch" CONFIG=Release run_script archive.sh
c_ok=0; [ "$RC" = 0 ] && hasline "$CALLS" "$pre Release $mid $post" && c_ok=1
if [ "$a_ok$b_ok$c_ok" = 111 ]; then ok archive_config_decides_icon_and_et_beta
else ng archive_config_decides_icon_and_et_beta "beta=$a_ok store=$b_ok env=$c_ok $(grep '^xcodebuild' "$CALLS" | head -1)"; fi

# 構成で決める。コマンドラインで上書きしない（上書きすると release.yml と手元の書庫がずれる）。
fresh
ARCHIVE_DIR="$WORK/arch" run_script archive.sh
if [ "$RC" = 0 ] && hasnt "$CALLS" "ET_APPICON=" && hasnt "$CALLS" "SWIFT_ACTIVE_COMPILATION_CONDITIONS="; then
  ok archive_does_not_override_icon_or_flags_on_command_line
else ng archive_does_not_override_icon_or_flags_on_command_line "$(grep '^xcodebuild' "$CALLS" | head -1)"; fi

# release.yml が渡す口。ET_BUILD_NUMBER はビルド番号だけをコマンドラインで上書きし、
# ET_XCODEBUILD_LOG は xcodebuild の出力を丸ごと残し、ET_ARCHIVE_ADHOC は ad-hoc 署名にする。
fresh
ET_BUILD_NUMBER=32 ARCHIVE_DIR="$WORK/arch" run_script archive.sh
n_ok=0; [ "$RC" = 0 ] && hasline "$CALLS" "$pre Beta $mid $post CURRENT_PROJECT_VERSION=32" && n_ok=1
fresh
ET_BUILD_NUMBER=x ARCHIVE_DIR="$WORK/arch" run_script archive.sh
n_bad=0; [ "$RC" = 2 ] && hasnt "$CALLS" "xcodebuild" && n_bad=1
fresh
ET_BUILD_NUMBER=3x2 ARCHIVE_DIR="$WORK/arch" run_script archive.sh
n_bad2=0; [ "$RC" = 2 ] && hasnt "$CALLS" "xcodebuild" && n_bad2=1
if [ "$n_ok$n_bad$n_bad2" = 111 ]; then ok archive_build_number_override_is_numeric_only
else ng archive_build_number_override_is_numeric_only "ok=$n_ok x=$n_bad 3x2=$n_bad2 rc=$RC"; fi

fresh
ET_XCODEBUILD_LOG="$WORK/xcodebuild-full.log" ARCHIVE_DIR="$WORK/arch" run_script archive.sh
if [ "$RC" = 0 ] && has "$WORK/xcodebuild-full.log" "ARCHIVE SUCCEEDED" 2>/dev/null; then
  ok archive_keeps_full_xcodebuild_log_when_asked
else ng archive_keeps_full_xcodebuild_log_when_asked "rc=$RC"; fi

fresh
ET_ARCHIVE_ADHOC=1 ARCHIVE_DIR="$WORK/arch" run_script archive.sh
if [ "$RC" = 0 ] && has "$CALLS" "CODE_SIGN_IDENTITY=-" && has "$CALLS" "CODE_SIGN_STYLE=Manual"    && hasnt "$CALLS" "CODE_SIGNING_ALLOWED=NO" \
   && hasnt "$CALLS" "allowProvisioningUpdates" && hasnt "$CALLS" "authenticationKey"; then
  ok archive_adhoc_signs_with_dash_and_never_unsigned
else ng archive_adhoc_signs_with_dash_and_never_unsigned "$(grep '^xcodebuild' "$CALLS" | head -1)"; fi

# 知らないアイコン名・構成名は xcodebuild を呼ばずに落とす。
fresh
ARCHIVE_DIR="$WORK/arch" run_script archive.sh EffeTuneLive NoSuchIcon
r1=$RC; r1x=0; hasnt "$CALLS" "xcodebuild" && r1x=1
fresh
ARCHIVE_DIR="$WORK/arch" CONFIG=Debug run_script archive.sh
r2=$RC; r2x=0; hasnt "$CALLS" "xcodebuild" && r2x=1
if [ "$r1" != 0 ] && [ "$r2" != 0 ] && [ "$r1x$r2x" = 11 ]; then ok archive_unknown_icon_or_config_stops_before_xcodebuild
else ng archive_unknown_icon_or_config_stops_before_xcodebuild "icon rc=$r1 cfg rc=$r2"; fi

fresh
mkdir -p "$WORK/arch/EffeTuneLive.xcarchive"
STUB_XCODEBUILD_EXIT=65 ARCHIVE_DIR="$WORK/arch" run_script archive.sh
if [ "$RC" != 0 ] && [ ! -e "$WORK/arch/EffeTuneLive.xcarchive" ] \
   && has "$ROOT/archive.log" "!! xcodebuild archive が落ちた (exit 65)"; then
  ok archive_failure_exits_nonzero_and_removes_previous_archive
else ng archive_failure_exits_nonzero_and_removes_previous_archive "rc=$RC"; fi

# setup.sh で落ちても前の書庫を残さない。残ると archive_install.sh がそれを実機に入れ、
# ~/gui_ship.sh の書き出しもそれを読む。
fresh
mkdir -p "$WORK/arch/EffeTuneLive.xcarchive/Products/Applications/EffectDeck.app"
STUB_SETUP_EXIT=1 ARCHIVE_DIR="$WORK/arch" run_script archive.sh
if [ "$RC" != 0 ] && [ ! -e "$WORK/arch/EffeTuneLive.xcarchive" ]; then
  ok archive_setup_failure_leaves_no_stale_archive
else ng archive_setup_failure_leaves_no_stale_archive "rc=$RC"; fi

# ---- Scripts/archive_install.sh / ship.sh の書庫 ------------------------------
# archive.sh は偽物に差し替える。偽物は書庫の .app を $ARCHIVE_DIR に置き、STUB_ARCHIVE_EXIT で終わる。
fake_archive() {
  cat > "$ROOT/Scripts/archive.sh" <<'EOF'
#!/bin/bash
echo "archive.sh $*" >> "$STUB_DIR/calls.log"
mkdir -p "$ARCHIVE_DIR/EffeTuneLive.xcarchive/Products/Applications/EffectDeck.app"
echo "** ARCHIVE SUCCEEDED **" > archive.log
exit "${STUB_ARCHIVE_EXIT:-0}"
EOF
  one_phone
}

fresh
fake_archive
ARCHIVE_DIR="$WORK/arch" run_script archive_install.sh
if [ "$RC" = 0 ] && has "$CALLS" "security unlock-keychain" \
   && hasline "$CALLS" "xcrun devicectl device install app --device $PHONE $WORK/arch/EffeTuneLive.xcarchive/Products/Applications/EffectDeck.app" \
   && has "$ROOT/archive-install.log" "ARCHIVE INSTALL FINISHED (exit=0)"; then
  ok archive_install_reads_archive_dir
else ng archive_install_reads_archive_dir "rc=$RC $(grep 'device install' "$CALLS" | head -1)"; fi

fresh
fake_archive
STUB_ARCHIVE_EXIT=1 ARCHIVE_DIR="$WORK/arch" run_script archive_install.sh
if [ "$RC" != 0 ] && has "$CALLS" "archive.sh EffeTuneLive" && hasnt "$CALLS" "device install" \
   && has "$ROOT/archive-install.log" "!! 書庫に失敗した"; then
  ok archive_install_stops_when_archive_fails
else ng archive_install_stops_when_archive_fails "rc=$RC $(grep 'device install' "$CALLS" | head -1)"; fi

fresh
fake_archive
STUB_INSTALL_EXIT=3 ARCHIVE_DIR="$WORK/arch" run_script archive_install.sh
if [ "$RC" = 3 ] && has "$ROOT/archive-install.log" "!! 入れられなかった (exit 3)" \
   && has "$ROOT/archive-install.log" "ARCHIVE INSTALL FINISHED (exit=3)"; then
  ok archive_install_returns_the_install_exit_code
else ng archive_install_returns_the_install_exit_code "rc=$RC"; fi

fresh
fake_archive
STUB_ARCHIVE_EXIT=1 ARCHIVE_DIR="$WORK/arch" EXPORT_DIR="$WORK/ipa" run_script ship.sh
if [ "$RC" != 0 ] && has "$CALLS" "archive.sh EffeTuneLive EffectDeckPublicBeta" \
   && has "$ROOT/ship.log" "!! 書庫に失敗した (exit 1)" && hasnt "$CALLS" "-exportArchive" \
   && hasnt "$CALLS" "altool" && has "$ROOT/ship.log" "=== SHIP FINISHED (exit=1) ==="; then
  ok ship_stops_when_archive_fails
else ng ship_stops_when_archive_fails "rc=$RC"; fi

# 上げるのに失敗したら、処理を待たず次の手も出さずに止まる（grep | tail の終了値で先へ進まない）。
fresh
mkdir -p "$WORK/arch/EffeTuneLive.xcarchive"
STUB_ALTOOL_EXIT=1 SKIP_ARCHIVE=1 ARCHIVE_DIR="$WORK/arch" EXPORT_DIR="$WORK/ipa" STUB_BUILD_NUM=27 run_script ship.sh
if [ "$RC" != 0 ] && has "$CALLS" "xcrun altool --upload-app" && has "$ROOT/ship.log" "!! 上げられなかった (exit 1)" \
   && hasnt "$CALLS" "Tools/asc.py" && hasnt "$ROOT/ship.log" "次の手" \
   && has "$ROOT/ship.log" "=== SHIP FINISHED (exit=1) ==="; then
  ok ship_stops_when_upload_fails
else ng ship_stops_when_upload_fails "rc=$RC $(grep '^!!' "$ROOT/ship.log" | head -1)"; fi

# ---- Tools/asc.py の出力を読む台本（ship.sh / notarize.sh / adp_fetch.sh） ------------
# asc.py は本物を走らせ、App Store Connect の返事だけ asc_api.json で決める。
build_row() {  # <id> <ビルド番号> <処理の状態>
  printf '{"id": "%s", "attributes": {"version": "%s", "processingState": "%s", "uploadedDate": "2026-09-27T00:00:00Z", "expired": false}}' "$1" "$2" "$3"
}

if [ -z "$REAL_PY" ]; then
  for t in ship_waits_for_its_build_then_prints_next_steps ship_stops_when_build_invalid \
           notarize_attaches_the_valid_build_to_the_existing_version notarize_creates_the_version_when_missing \
           adp_fetch_names_variants_by_manifest_and_checks_sha256 adp_fetch_checksum_mismatch_stops \
           adp_fetch_variant_not_in_manifest_stops; do
    skip "$t" "python3 が無い（Tools/asc.py を走らせられない）"
  done
else

# 同じ番号の 270 と、前の 26 を混ぜる。1 回目は処理中、2 回目で VALID。
fresh
mkdir -p "$WORK/arch/EffeTuneLive.xcarchive"
cat > "$STUB_DIR/asc_api.json" <<EOF
{"GET /v1/builds": [
  {"data": [$(build_row B270 270 VALID), $(build_row B27 27 PROCESSING), $(build_row B26 26 VALID)]},
  {"data": [$(build_row B270 270 VALID), $(build_row B27 27 VALID), $(build_row B26 26 VALID)]}]}
EOF
SKIP_ARCHIVE=1 ARCHIVE_DIR="$WORK/arch" EXPORT_DIR="$WORK/ipa" STUB_BUILD_NUM=27 run_script ship.sh
if [ "$RC" = 0 ] && has "$ROOT/ship.log" "build 27 = B27 (VALID)" \
   && has "$ROOT/ship.log" "python3 Tools/asc.py attach <version-id> B27" \
   && has "$ROOT/ship.log" "bash Scripts/notarize.sh <版> 27" \
   && [ "$(count "$CALLS" "asc GET /v1/builds")" = 2 ] && hasnt "$CALLS" "archive.sh" \
   && hasline "$CALLS" "xcodebuild -exportArchive -archivePath $WORK/arch/EffeTuneLive.xcarchive -exportPath $WORK/ipa -exportOptionsPlist $WORK/home/signing/export.plist -allowProvisioningUpdates" \
   && hasline "$CALLS" "xcrun altool --upload-app -f $WORK/ipa/EffectDeck.ipa -t ios --apiKey $KEY_ID --apiIssuer $ISSUER" \
   && has "$ROOT/ship.log" "=== SHIP FINISHED (exit=0) ==="; then
  ok ship_waits_for_its_build_then_prints_next_steps
else ng ship_waits_for_its_build_then_prints_next_steps "rc=$RC $(grep -E '^(build|!!)' "$ROOT/ship.log" | head -2 | tr '\n' ';')"; fi

fresh
mkdir -p "$WORK/arch/EffeTuneLive.xcarchive"
cat > "$STUB_DIR/asc_api.json" <<EOF
{"GET /v1/builds": [{"data": [$(build_row B270 270 VALID), $(build_row B27 27 INVALID)]}]}
EOF
SKIP_ARCHIVE=1 ARCHIVE_DIR="$WORK/arch" EXPORT_DIR="$WORK/ipa" STUB_BUILD_NUM=27 run_script ship.sh
if [ "$RC" != 0 ] && has "$ROOT/ship.log" "!! build 27 が INVALID になった" \
   && hasnt "$ROOT/ship.log" "asc.py attach"; then
  ok ship_stops_when_build_invalid
else ng ship_stops_when_build_invalid "rc=$RC"; fi

# notarize.sh: VALID になったビルドを、同じ文字列の版（無ければ作った版）に結んで出す。
notarize_api() {  # <versions の data の中身>
  cat > "$STUB_DIR/asc_api.json" <<EOF
{"GET /v1/builds": [
   {"data": [$(build_row B310 310 VALID), $(build_row B31 31 PROCESSING)]},
   {"data": [$(build_row B310 310 VALID), $(build_row B31 31 VALID)]}],
 "PATCH /v1/builds/B31": [{}],
 "GET /v1/apps/6812467517/appStoreVersions": [{"data": [$1]}],
 "POST /v1/appStoreVersions": [{"data": {"id": "VNEW"}}],
 "PATCH /v1/appStoreVersions/V1/relationships/build": [{}],
 "PATCH /v1/appStoreVersions/VNEW/relationships/build": [{}],
 "POST /v1/reviewSubmissions": [{"data": {"id": "S1"}}],
 "POST /v1/reviewSubmissionItems": [{}],
 "PATCH /v1/reviewSubmissions/S1": [{}],
 "GET /v1/appStoreVersions/V1": [{"data": {"attributes": {"appVersionState": "WAITING_FOR_REVIEW"}}}],
 "GET /v1/appStoreVersions/VNEW": [{"data": {"attributes": {"appVersionState": "WAITING_FOR_REVIEW"}}}]}
EOF
}
version_row() {  # <id> <版>
  printf '{"id": "%s", "attributes": {"versionString": "%s", "appVersionState": "PREPARE_FOR_SUBMISSION", "createdDate": "2026-09-27T00:00:00Z"}}' "$1" "$2"
}

fresh
notarize_api "$(version_row V2 2026.09.28), $(version_row V1 2026.09.27)"
run_script notarize.sh 2026.09.27 31
if [ "$RC" = 0 ] && [ "$(count "$CALLS" "asc GET /v1/builds")" = 2 ] \
   && has "$CALLS" "asc PATCH /v1/builds/B31 " \
   && hasline "$CALLS" 'asc PATCH /v1/appStoreVersions/V1/relationships/build {"data": {"id": "B31", "type": "builds"}}' \
   && has "$CALLS" 'asc PATCH /v1/reviewSubmissions/S1 {"data": {"attributes": {"submitted": true}' \
   && hasnt "$CALLS" "asc POST /v1/appStoreVersions " \
   && has "$OUTF" "既にある 2026.09.27 = V1" && has "$OUTF" "承認されたら: bash Scripts/adp_fetch.sh V1"; then
  ok notarize_attaches_the_valid_build_to_the_existing_version
else ng notarize_attaches_the_valid_build_to_the_existing_version "rc=$RC $(grep -E '^(!!|build)' "$OUTF" | head -2 | tr '\n' ';')"; fi

fresh
notarize_api "$(version_row V2 2026.09.28)"
run_script notarize.sh 2026.09.27 31
if [ "$RC" = 0 ] && has "$CALLS" "asc POST /v1/appStoreVersions " && has "$CALLS" '"versionString": "2026.09.27"' \
   && hasline "$CALLS" 'asc PATCH /v1/appStoreVersions/VNEW/relationships/build {"data": {"id": "B31", "type": "builds"}}' \
   && has "$OUTF" "作った 2026.09.27 = VNEW"; then
  ok notarize_creates_the_version_when_missing
else ng notarize_creates_the_version_when_missing "rc=$RC"; fi

# adp_fetch.sh: 変種を manifest.json が指す名前で置き、sha256 を ASC の fileChecksum と照らす。
# 名前が前方で重なる 2 本（VA と VAB）。VAB の fileChecksum は大文字で来る形にする。
adp_setup() {  # <VA の checksum> <VAB の checksum> <manifest に書く変種...>
  local a="$1" b="$2" v list=""
  shift 2
  printf 'variant A\n' > "$STUB_DIR/net/VA.ipa"
  printf 'variant AB\n' > "$STUB_DIR/net/VAB.ipa"
  printf 'zip\n' > "$STUB_DIR/net/pkg.zip"
  for v in "$@"; do list="$list${list:+, }{\"assetPath\": \"variant/$v.ipa\"}"; done
  echo "{\"assets\": [$list]}" > "$STUB_DIR/pkgtree/manifest.json"
  echo "sig" > "$STUB_DIR/pkgtree/signature"
  cat > "$STUB_DIR/asc_api.json" <<EOF
{"GET /v1/appStoreVersions/V1/alternativeDistributionPackage": [{"data": {"id": "ADP1"}}],
 "GET /v1/alternativeDistributionPackages/ADP1/versions": [{"data": [
   {"id": "PV0", "attributes": {"state": "REPLACED", "url": "https://adp.invalid/old.zip?accessKey=OLD"}},
   {"id": "PV1", "attributes": {"state": "COMPLETED", "url": "https://adp.invalid/pkg.zip?accessKey=SECRET"}}]}],
 "GET /v1/alternativeDistributionPackageVersions/PV0/variants": [{"data": []}],
 "GET /v1/alternativeDistributionPackageVersions/PV1/variants": [{"data": [
   {"id": "VA", "attributes": {"url": "https://adp.invalid/VA.ipa?accessKey=K1", "fileChecksum": "$a"}},
   {"id": "VAB", "attributes": {"url": "https://adp.invalid/VAB.ipa?accessKey=K2", "fileChecksum": "$b"}}]}]}
EOF
}

fresh
adp_setup x x VA VAB
SA=$(sha256 "$STUB_DIR/net/VA.ipa")
SB=$(sha256 "$STUB_DIR/net/VAB.ipa")
adp_setup "$SA" "$(printf '%s' "$SB" | tr 'a-f' 'A-F')" VA VAB
run_script adp_fetch.sh V1 "$WORK/adp"
if [ "$RC" = 0 ] && has "$OUTF" "一致 $SA  VA.ipa" && has "$OUTF" "一致 $SB  VAB.ipa" \
   && cmp -s "$STUB_DIR/net/VA.ipa" "$WORK/adp/pkg/variant/VA.ipa" \
   && cmp -s "$STUB_DIR/net/VAB.ipa" "$WORK/adp/pkg/variant/VAB.ipa" \
   && has "$OUTF" "accessKey=..." && hasnt "$OUTF" "SECRET" && has "$OUTF" "変種 2 本"; then
  ok adp_fetch_names_variants_by_manifest_and_checks_sha256
else ng adp_fetch_names_variants_by_manifest_and_checks_sha256 "rc=$RC $(grep -E '^ *(!!|一致)' "$OUTF" | head -3 | tr '\n' ';')"; fi

fresh
adp_setup "$SA" "$SA" VA VAB
run_script adp_fetch.sh V1 "$WORK/adp"
if [ "$RC" != 0 ] && has "$OUTF" "!! sha256 が違う: VAB" && has "$OUTF" "置かないこと" \
   && hasnt "$OUTF" "=== 4."; then
  ok adp_fetch_checksum_mismatch_stops
else ng adp_fetch_checksum_mismatch_stops "rc=$RC"; fi

# manifest.json が指していない名前で置くと、置いた ADP は使えない。一致しても止まる。
fresh
adp_setup "$SA" "$SB" VA
run_script adp_fetch.sh V1 "$WORK/adp"
if [ "$RC" != 0 ] && has "$OUTF" "!! manifest.json に variant/VAB.ipa が見えない" \
   && has "$OUTF" "置かないこと" && hasnt "$OUTF" "=== 4."; then
  ok adp_fetch_variant_not_in_manifest_stops
else ng adp_fetch_variant_not_in_manifest_stops "rc=$RC $(tail -1 "$OUTF")"; fi

fi

# ---- 全体 --------------------------------------------------------------------
if [ ! -e "$SRC/sim.sh" ] && [ ! -e "$SRC/shots.sh" ]; then ok dead_sim_and_shots_scripts_removed
else ng dead_sim_and_shots_scripts_removed; fi

hits=$(grep -nE '^[^#]*(simctl create|open -a Simulator)' "$SRC"/*.sh "$SRC"/lib/*.sh 2>/dev/null)
if [ -z "$hits" ]; then ok no_script_creates_devices_or_opens_simulator_app
else ng no_script_creates_devices_or_opens_simulator_app "$hits"; fi

hits=$(grep -nE 'SIM:-|simctl list devices available' "$SRC"/*.sh 2>/dev/null)
if [ -z "$hits" ]; then ok device_choice_only_in_lib
else ng device_choice_only_in_lib "$(echo "$hits" | head -3 | tr '\n' ';')"; fi

# 名指しの xcodebuild と PlistBuddy は ET_XCODEBUILD / ET_PLISTBUDDY の既定としてだけ書く。
# ほかに書くと、この試験を Mac で走らせたとき本物に届く。
hits=$(cd "$SRC" && grep -nE '/usr/bin/xcodebuild|/usr/libexec/PlistBuddy' \
         test.sh uitest.sh build.sh archive.sh archive_install.sh ship.sh notarize.sh adp_fetch.sh \
         shoot_all.sh shoot_screens.sh shoot_store.sh bridge_probe.sh lib/sim.sh 2>/dev/null \
       | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
       | grep -vF 'ET_XCODEBUILD:-/usr/bin/xcodebuild}' | grep -vF 'ET_PLISTBUDDY:-/usr/libexec/PlistBuddy}')
if [ -z "$hits" ]; then ok mac_tools_by_full_path_only_as_overridable_defaults
else ng mac_tools_by_full_path_only_as_overridable_defaults "$(echo "$hits" | head -3 | tr '\n' ';')"; fi

echo
echo "PASS $PASS  FAIL $FAIL  SKIP $SKIP${FAILED:+  (${FAILED# })}"
[ "$FAIL" = 0 ]
