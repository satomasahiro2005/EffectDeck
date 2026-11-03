# shellcheck shell=bash
# シミュレータを 1 台だけ使うための共通部品。単体では走らせず、source して使う。
#
#   cd "$(dirname "$0")/.." || exit 1     # 呼ぶ側はリポジトリの根に居ること
#   ROOT="$PWD"
#   . Scripts/lib/sim.sh
#   sim_select || exit 1    SIM（名前か UDID）を引いて SIM_UDID と SIM_NAME に入れる
#   sim_only   || exit 1    ほかに起きている端末を全部落とし、SIM_UDID だけを起こして待つ
#
# **端末は 1 台だけ。**名前は完全一致で引き、見つからなければ止まる。
# 「最初に見つかった端末」へ逃げたり、作り足したりはしない。前の Scripts/sim.sh は
# gawk の 3 引数 match() が macOS の awk で落ちて毎回 simctl create に進み、
# 同じ名前の端末を積み上げていた。test.sh は名前が無いと手近な端末を拾い、
# 起きている別の端末も落とさなかった。
#
#   SIM=名前か UDID   既定は "iPad Pro 13-inch (M5)"
#   SIM_OS=27.0      同じ名前が複数の iOS に居るときに絞る。絞らなければ
#                    起きているものを、無ければ一覧の最後（新しい iOS）のものを使う
#   DRY_RUN=1        状態を変えるコマンドは走らせず「+ コマンド」と出すだけ。
#                    読むだけの simctl list は走らせる
#   SHOW=1           sim_show が DeviceHub.app を開く。**Xcode 27 に Simulator.app は無い**
#                    （/Applications/Xcode.app/Contents/Applications/DeviceHub.app）
#   ET_XCODEBUILD=   xcodebuild の置き場。既定は /usr/bin/xcodebuild（名指し）。
#                    Tests/Scripts/sim_test.sh が偽物を渡すための口
#
# Mac の /bin/bash は 3.2。連想配列・mapfile・${x,,} は使わない。set -u の下で空の
# "${a[@]}" は unbound variable で落ちるので、空になり得る配列は ${a[@]+"${a[@]}"} で渡す。
# awk も macOS の BWK awk で走るので、gawk の拡張（3 引数の match() など）と
# {n} の回数指定は使わない。

ET_SIM_DEFAULT="iPad Pro 13-inch (M5)"
ET_APPID="ai.nemut.effetune"
ET_XCODEBUILD="${ET_XCODEBUILD:-/usr/bin/xcodebuild}"

# 状態を変えるコマンドはここを通す。DRY_RUN=1 なら出すだけ。
et_run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# 出力を捨てて走らせる（落ちてもよいもの）。DRY_RUN=1 なら出すだけ。
et_quiet() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    et_run "$@"
    return 0
  fi
  "$@" >/dev/null 2>&1
}

# 1 手走らせ、出力は全部ログへ足す。落ちたら名前・終了値・ログの末尾を出して 1 を返す。
# **パイプに通さない。**`| tail` の終了値は tail のものなので、落ちても先へ進んでしまう
# （test.sh・archive.sh・shoot_*.sh の xcodegen がそうだった）。
#   et_step <ログ> <名前> <コマンド...>
et_step() {
  local log="$1" label="$2" code
  shift 2
  if [ "${DRY_RUN:-0}" = "1" ]; then
    et_run "$@"
    return 0
  fi
  echo "--- $label ---"
  echo "--- $label $(date) ---" >> "$log"
  "$@" >> "$log" 2>&1
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "!! $label が落ちた (exit $code)。$log の末尾:"
    tail -n 15 "$log" | sed 's/^/   /'
    return 1
  fi
  return 0
}

# xcodebuild test の後の要約（落ちたもの・数・判定）を出し、呼ぶ側が返す終了値を返す。
# **1 件も走っていなければ、xcodebuild が 0 で終わっても 1 を返す。**-only-testing に
# 無いクラスや綴り違いを渡すと、何も走らせずに ** TEST SUCCEEDED ** で終わることがある。
# 数えるのは "Test Case '...' passed (" と "... failed (" の行（-parallel-testing-enabled NO の形。
# 並列のときの "Test case '...' passed on '...'" も拾う）。
#   et_test_summary <ログ> <xcodebuild の終了値> <結果の束>
et_test_summary() {
  local log="$1" code="$2" result="$3" passed failed
  echo "--- 落ちたもの ---"
  grep -E "error:|XCTAssert.*failed|failed -|TEST FAILED|BUILD FAILED" "$log" | head -40
  echo "--- 数 ---"
  grep -E "Test Suite .* (passed|failed)" "$log" | tail -3
  passed=$(grep -cE "^Test [Cc]ase '.*' passed " "$log")
  failed=$(grep -cE "^Test [Cc]ase '.*' failed " "$log")
  echo "通った: $passed"
  echo "落ちた: $failed"
  grep -E "\*\* TEST (SUCCEEDED|FAILED) \*\*" "$log" | tail -1
  echo "結果の束: $result"
  if [ "$code" -eq 0 ] && [ "$((passed + failed))" -eq 0 ]; then
    echo "!! テストが 1 件も走っていない（-only-testing に渡した名前を確かめる）" | tee -a "$log"
    return 1
  fi
  return "$code"
}

sim_is_udid() {
  printf '%s\n' "$1" | grep -Eq '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$'
}

# `simctl list devices available` を「状態<TAB>UDID<TAB>名前<TAB>iOS 27.0」の行に直す。
# 名前にも括弧が入る（"iPad Pro 13-inch (M5)"）ので、行の後ろから (状態) と (UDID) を切る。
sim_table() {
  xcrun simctl list devices available 2>/dev/null | awk '
    /^== / { next }
    /^-- / { os = $0; sub(/^-- /, "", os); sub(/ --$/, "", os); next }
    {
      line = $0
      sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
      if (line !~ /\)$/) next
      st = line; sub(/.*\(/, "", st); sub(/\)$/, "", st)
      rest = substr(line, 1, length(line) - length(st) - 2); sub(/[ \t]+$/, "", rest)
      if (rest !~ /\)$/) next
      id = rest; sub(/.*\(/, "", id); sub(/\)$/, "", id)
      if (length(id) != 36 || id !~ /^[0-9A-F-]+$/) next
      name = substr(rest, 1, length(rest) - length(id) - 2); sub(/[ \t]+$/, "", name)
      printf "%s\t%s\t%s\t%s\n", st, id, name, os
    }'
}

# SIM を引く。成功すると SIM_UDID と SIM_NAME が入る。
sim_select() {
  local table
  SIM="${SIM:-$ET_SIM_DEFAULT}"
  SIM_UDID=""
  SIM_NAME=""
  table=$(sim_table)
  if [ -z "$table" ]; then
    echo "!! xcrun simctl list devices available が端末を 1 つも返さない（Xcode と iOS の runtime を確かめる）" >&2
    return 1
  fi
  if sim_is_udid "$SIM"; then
    SIM_NAME=$(printf '%s\n' "$table" | awk -F '\t' -v id="$SIM" '$2 == id { print $3; exit }')
    [ -n "$SIM_NAME" ] && SIM_UDID="$SIM"
  else
    SIM_UDID=$(printf '%s\n' "$table" | awk -F '\t' -v want="$SIM" -v os="${SIM_OS:-}" '
      $3 != want { next }
      os != "" && $4 != "iOS " os { next }
      { n++; last = $2; if ($1 == "Booted" && booted == "") booted = $2 }
      END {
        if (n == 0) exit
        pick = last
        why = "一覧の最後のものを使う"
        if (booted != "") { pick = booted; why = "起きているものを使う" }
        if (n > 1)
          printf("-- \"%s\" が %d 台ある。%s: %s（SIM_OS か UDID で選べる）\n", want, n, why, pick) > "/dev/stderr"
        print pick
      }')
    [ -n "$SIM_UDID" ] && SIM_NAME="$SIM"
  fi
  if [ -z "$SIM_UDID" ]; then
    echo "!! シミュレータが無い: $SIM${SIM_OS:+（iOS ${SIM_OS}）}" >&2
    echo "   名前は完全一致で引く。手近な端末へは逃げないし、作り足しもしない。" >&2
    echo "   使える端末（SIM=名前 か SIM=UDID で渡す）:" >&2
    printf '%s\n' "$table" | awk -F '\t' '{ printf "     %s  (%s, %s)\n", $3, $4, $2 }' >&2
    return 1
  fi
  return 0
}

# 起きている端末の UDID を全部（available に限らない）。
sim_booted() {
  xcrun simctl list devices 2>/dev/null | grep '(Booted)' \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
}

# ほかの端末を落とし、SIM_UDID だけを起こして起動し終わるまで待つ。
sim_only() {
  local other booted_self=0
  if [ -z "${SIM_UDID:-}" ]; then
    echo "!! sim_select を先に呼ぶこと" >&2
    return 1
  fi
  for other in $(sim_booted); do
    if [ "$other" = "$SIM_UDID" ]; then
      booted_self=1
      continue
    fi
    echo "-- ほかに起きている端末を落とす: $other"
    et_run xcrun simctl shutdown "$other" || echo "!! 落とせなかった: $other" >&2
  done
  if [ "$booted_self" = 0 ]; then
    et_run xcrun simctl boot "$SIM_UDID" || {
      echo "!! 起こせない: $SIM_NAME ($SIM_UDID)" >&2
      return 1
    }
  fi
  et_run xcrun simctl bootstatus "$SIM_UDID" -b || {
    echo "!! 起動し終わるのを待てない: $SIM_NAME ($SIM_UDID)" >&2
    return 1
  }
  return 0
}

sim_is_ipad() {
  case "${SIM_NAME:-}" in
    *iPad*) return 0 ;;
  esac
  return 1
}

# 画面で見たいときだけ。撮影にもテストにも要らない。
sim_show() {
  [ "${SHOW:-0}" = "1" ] || return 0
  et_run open "$(xcode-select -p)/../Applications/DeviceHub.app"
}

sim_terminate_app() {
  et_quiet xcrun simctl terminate "$SIM_UDID" "$ET_APPID"
  return 0
}

# 拡張を外したシミュレータ用のプロジェクト（EffeTuneLiveSim.xcodeproj）を作る。
# MediaDevice.framework はシミュレータの SDK に無いので、project.yml のままだと
# 拡張を含むスキームが Unable to resolve module dependency で必ず落ちる。
# setup.sh（パッチ・生成物・note-models）は SKIP_SETUP=1 で飛ばせる。
#   sim_project <ログ>
sim_project() {
  local log="$1"
  if [ "${SKIP_SETUP:-0}" = "1" ]; then
    echo "-- SKIP_SETUP=1 なので Scripts/setup.sh は飛ばす"
  else
    # SKIP_XCODEGEN=1: 実機用の project.yml はここでは組まない（この変数を読む版の setup.sh から効く）
    et_step "$log" "Scripts/setup.sh" env SKIP_XCODEGEN=1 bash Scripts/setup.sh || return 1
  fi
  et_step "$log" "gen_sim_spec.py" python3 Tools/gen_sim_spec.py || return 1
  et_step "$log" "xcodegen（project-sim.yml）" xcodegen generate --spec project-sim.yml || return 1
  return 0
}

# 撮るためのアプリを out-sim/ に建てる。前の成果物は先に消す（残っていると、建てそこねても
# 古いものが撮れてしまう。100 枚まるごと古いビルドの画面だった回がある）。
# 並列数は BUILD_JOBS（既定 2。Mac のメモリ圧迫の件は Scripts/build.sh を読む）。
#   sim_build_app <ログ>
sim_build_app() {
  local log="$1"
  et_run rm -rf "$ROOT/out-sim"
  et_step "$log" "xcodebuild（シミュレータ向け）" "$ET_XCODEBUILD" \
    -project EffeTuneLiveSim.xcodeproj -scheme EffeTuneLive \
    -configuration Debug -sdk iphonesimulator -arch arm64 -jobs "${BUILD_JOBS:-2}" \
    CONFIGURATION_BUILD_DIR="$ROOT/out-sim" build || return 1
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  grep -E "BUILD SUCCEEDED|BUILD FAILED" "$log" | tail -n 1
  if [ ! -d "$ROOT/out-sim/EffectDeck.app" ]; then
    echo "!! 成果物が無い: out-sim/EffectDeck.app"
    return 1
  fi
  return 0
}

# 入れ直す（前の回の設定を持ち越さない）。
#   sim_install_app <.app>
sim_install_app() {
  et_quiet xcrun simctl uninstall "$SIM_UDID" "$ET_APPID"
  et_run xcrun simctl install "$SIM_UDID" "$1" || {
    echo "!! 入れられない: $1" >&2
    return 1
  }
  return 0
}
