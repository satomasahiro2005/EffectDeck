# JSFX の速さを測る台

JSFX の実行系（いまは WDL の portable の解釈）を、同じ入力・同じ測り方で比べる。
中身は `Sources/Shared/ETJSFXBench.cpp`。机の上（Mac・Linux）とアプリ（Debug・Beta）の両方から同じものを呼ぶ。
測った生の JSON は `docs/bench/` に置く。

## 実行系

| 名前 | 中身 | どこで |
|---|---|---|
| `portable` | アプリと同じ道。`ETJSFX_Create` → `ETJSFX_Processor` の process（48 kHz・256 フレーム・2 ch の planar）。EEL は `EEL_TARGET_PORTABLE`（`glue_port.h` の switch の解釈） | Mac・iPhone |
| `cpp` | `Debug/JSFXBench` の各スクリプトを手で C++ に写したもの（`Sources/Shared/ETJSFXBenchPorts.cpp`）。double・式の順序・入力の `+1e-16`・メモリの添字・出力の拭きまで JSFX と同じにしてある。前もって機械語にしたときの上限の目安 | Mac・iPhone |
| `wdl-jit` | `EEL_TARGET_PORTABLE` を外して建てた WDL の JIT（`glue_aarch64.h`。頁を mprotect で RW から RX へ）。ホストの道は portable と同じ | Mac の CLI だけ（iOS は実行できる頁を作れない） |
| `vm-block` | 同じバイトコードを `glue_port_vm.h` の switch で解く（`GLUE_CALL_CODE` と同じ式）。@sample を 1 ブロック 1 回の入口で回す（`NSEEL_code_execute_frames`） | Mac・iPhone |
| `vm-goto` | vm-block の switch を computed goto に（ラベルの番地の表、各命令の終わりで次へ飛ぶ。実行時に機械語は作らない） | Mac・iPhone |
| `vm-goto-fpreg` | vm-goto + 浮動小数の積み場の先頭をローカル（レジスタ）に置く。**アプリの既定** | Mac・iPhone |
| `vm-goto-fpreg-mask` | vm-goto-fpreg + 表を 128 に取って番号の下 7 bit で引く（範囲の比較を省く） | Mac・iPhone |
| `vm-reg` | レジスタ型 VM（`Sources/JSFXVM`、`docs/jsfx-regvm-design.md`）。バイトコードを持ち上げた中間表現から並べた threaded code（段 S3: 中間表現を最適化してから並べ、loop・比べて跳ぶ・四則 2 つなどを 1 つのハンドラに。`[[clang::musttail]]` で次へ。オペランドは升・枠の絶対番地）。@sample は 1 ブロック 1 回の入口。**アプリの既定には入れない**（台だけ） | Mac・iPhone |

実行系は `kVariants` に 1 行足す。最初の行（portable か wdl-jit）が照合の基準で、
vm-* は `Check::exact`（1 ビットも違ってはいけない）。cpp は差 `1e-6` まで許す（いまはどれも一致）。
vm-* は WDL の字句・構文・compile・バイトコードには触らず、解き方だけを替える（`Patches/ysfx-effectdeck-ios.diff`。
`ns-eel.h` の `NSEEL_EXEC_*`）。同じ実体の上で実行時に選べる（`ysfx_set_eel_exec_mode`・`ETJSFX_SetEELExecutor`）。
ysfx は @slider・@block・@sample を選んだ実行系で回す（@init・@serialize・@gfx は今までの `NSEEL_code_execute`）。
アプリの既定は `NSEEL_EXEC_DEFAULT`（`ns-eel.h`）。portable の行もはっきり 0 を選ぶ。

## スクリプト（`Debug/JSFXBench`、全部自前）

| 名前 | 見るもの |
|---|---|
| `gain` | 最小（`Tests/Fixtures/JSFX/gain.jsfx` の写し）。1 サンプルの固定費 |
| `filter_drive` | 同梱の見本 Filter + Drive の写し。四則と abs |
| `stereo_delay` | 同梱の見本 Stereo Delay の写し。大きなメモリの読み書き |
| `slow` | `slow.jsfx` の写し（1 サンプルに `loop` 200 周） |
| `biquad` | 4 帯のピーキング EQ × 2 ch。ユーザー関数・`instance`・`this.` |
| `fir` | 64 タップの FIR。メモリ上の輪のバッファを `loop` で回す |
| `math` | sin・exp・log・pow と、値で回数の変わる `while` |

スクリプトを変えたら `ETJSFXBenchPorts.cpp` も直す（照合が落ちて気づく）。

## 測り方

- スクリプトごとに全部の実行系を作る → @init・@slider → 0.5 秒ぶん回して温める → 5 秒ぶん（938 ブロック）を 1 ブロックずつ測る
- 測る前に CPU を 0.5 秒空回しする（冷えたまま始めると最初のスクリプトだけ 2〜3 倍遅い）
- 実行系は 16 ブロックごとに入れ替え、頭も毎回ずらす（温度・周波数の揺れを片方に乗せない）
- 測るスレッドは音のスレッドと同じ時間制約の方針（`THREAD_TIME_CONSTRAINT_POLICY`、周期 = 1 ブロック）。取れたかを表と JSON に書く
- 入力は何番目のブロックかだけで決まる（正弦 2 本 + 揺れ + 雑音）。出力は全部の実行系で基準と照合し、指紋（FNV-1a）も残す

## 回し方

### A. 机の上（Mac・Linux）

```sh
bash Tools/jsfx-bench/run.sh                 # -Os と -O3、portable と JIT、7 本を 5 秒
bash Tools/jsfx-bench/run.sh --opt Os --no-jit --scripts fir,math --seconds 2
```

```sh
bash Tools/jsfx-bench/run.sh --diff            # 速さは測らず、実行系ごとの結果を portable と 1 ビットまで比べる
bash Tools/jsfx-bench/run.sh --profile         # 命令と続いた 2 つの組を数える（-DNSEEL_VM_PROFILE の版）
bash Tools/jsfx-bench/run.sh --vm-opgrid --no-jit   # レジスタ型 VM: 命令ごとに値の格子で portable と参照の解釈・threaded code を 1 ビットまで比べる
bash Tools/jsfx-bench/run.sh --vm-dump --no-jit     # レジスタ型 VM: handle ごとに持ち上がったか・理由・節ごとの割合
bash Tools/jsfx-bench/run.sh --vm-dump --vm-ir --opt Os --no-jit Debug/JSFXBench/biquad.jsfx   # 中間表現と threaded code も出す
# ETVM_DUMP_BC=1 を付けると、持ち上げで断った handle のバイトコードを頭から並べる
```

`--diff` は `Tests/Fixtures/JSFX`・`Tests/Fuzz/Corpus/jsfxexec`・`Debug/JSFXBench`・`Tools/jsfx-bench/diff`
（`opcodes.jsfx`: 命令をなるべく通す。`vm_lift.jsfx`: その @sample を vm-reg でも通す写し。`vm_edge.jsfx`: vm-reg の
畳み込み・行き先じか書き・まとめ・升の使い回しが portable の読み書きの順を崩さないかを突く形と、段 1 のコーパスで
通らなかった命令）を、ysfx をじかに使って
実行系ごとに回す（48 ブロック、フレーム数を変え、つまみ・trigger・再生位置・NaN／Inf／非正規化数・3 ブロックに 1 回の
MIDI を混ぜ、`ysfx_process_double`）。比べるのは毎ブロックの出力・出てきた MIDI・つまみの変化／自動化／見える印・
最後の変数の全部・EEL のメモリ全部・@serialize・ysfx の口から見えない升（定数・関数の局所・#字）とユーザーの
積み場の位置（`etvm::stateHash`）。vm-reg（threaded code）のほかに vm-reg-ref（同じ中間表現の参照の解釈、段 S1）も
比べる。vm-reg が違ったら節を 1 つずつ vm-reg にして回し直し、どの節かを出す。
回ごとに `NSEEL_rand_reset` で rand の列を最初からにする。
gmem はプロセスの中で共有されるので、書く前に読むスクリプトは portable どうしでも違う
（`ET_DIFF_MODES=0` で portable どうしを比べられる）。数える版は、vm-* が一度も通らなかった命令も出す。
`Tests/Fuzz/run.sh --target jsfxexec` も 1/4 の入力で既定の実行系・vm-reg と portable に同じものを渡して比べる
（gmem・`time` の字があるソースは外し、範囲の外の番地が指す 1 語 `nseel_ramalloc_onfail` は回ごとに 0 に戻す。
どちらもプロセスで共有され、前の回の残りで portable どうしでも違う）。

`-Os` は Xcode の YSFX と同じ段（Beta・Release は `GCC_OPTIMIZATION_LEVEL` を書いておらず、Xcode の既定の `-Os`。
アプリ側の `ETJSFXHost.cpp` と台も `dspSettings` で `-Os`）。`-O3` は比べるための別の段。
出力は `build/jsfx-bench/<機種>-<段>-<portable|wdl-jit>.{json,txt}`、最後に `Tools/jsfx-bench/summary.py` が 1 枚にまとめる。
JIT 版は arm64 だけ。OS が実行できる頁を断ったら、何が断られたかを出して止まる（数字は出さない）。

### B. iPhone（Beta）

```sh
CONFIG=Beta bash Scripts/build.sh            # Mac の GUI の Terminal から（ssh から署名しない）
xcrun devicectl device process launch --console --terminate-existing --device <UDID> \
  ai.nemut.effetune -- -ETBenchJSFX 1 -ETBenchGitSHA "$(git rev-parse --short=12 HEAD)"
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier ai.nemut.effetune --source Documents/jsfx-bench.json --destination jsfx-bench.json
```

`-ETBenchSeconds 5`・`-ETBenchScripts gain,fir`・`-ETBenchVariants portable,cpp` も渡せる。
測るあいだは音の経路を作らず、鎖・プリセット・設定に触らない。表を stdout に出し、`Documents/jsfx-bench.json` を書いて終わる。
**Debug の数字は使わない**（YSFX が `-O0`）。店の版（Release）にはこの口も台もスクリプトも入らない。

## 読み方

| 列 | 意味 |
|---|---|
| `med_us` `p90_us` `p99_us` `max_us` | 1 ブロック（256 フレーム）の時間 |
| `ns/smp` | 1 フレームあたりの平均 |
| `%bud` `%b_p99` | 1 ブロックの持ち時間（256 / 48000 秒 = 5333 us）に対する中央値・p99 の割合 |
| `host_pm` | ホストの `ETJSFX_DeadlineWorstPermille`（温めの分も入った最悪値。1000 で使い切り） |
| `vs_ref` | 基準（portable か wdl-jit）の中央値 ÷ この実行系の中央値。大きいほど速い |
| `x_cpp` | この実行系の中央値 ÷ cpp の中央値。cpp の何倍遅いか |
| `check` | 基準との照合。`bit-exact` か、最大の差と違ったサンプルの数。`bypassed` はホストが締切で外した回数 |

`summary.py` の `jit/cpp` は JIT の回の中の cpp との比、`port/jit` は回をまたいだ比（別のプロセスなので温度の差が乗りうる）、
`out==` は portable と wdl-jit の出力の指紋が同じか。

## 基準（2026-10-07、932dd13）

1 ブロック（256 フレーム）の中央値（us）。`x cpp` は cpp の何倍遅いか。JSON は `docs/bench/2026-10-07-*`。

| スクリプト | iPhone 16 Beta portable | x cpp | M1 -Os portable | x cpp | M1 -Os wdl-jit | x cpp |
|---|---:|---:|---:|---:|---:|---:|
| gain | 2.2 | 7.4 | 4.2 | 11.1 | 9.4 | 25.0 |
| filter_drive | 21.7 | 27.4 | 43.1 | 35.7 | 16.1 | 13.3 |
| stereo_delay | 18.4 | 18.4 | 38.2 | 27.8 | 15.4 | 11.2 |
| slow | 130.5 | 6.4 | 356.6 | 11.5 | 184.0 | 5.9 |
| biquad | 47.4 | 33.5 | 96.0 | 48.0 | 21.6 | 10.8 |
| fir | 374.7 | 13.1 | 954.3 | 20.9 | 124.8 | 2.7 |
| math | 57.2 | 5.5 | 104.0 | 6.7 | 36.5 | 2.3 |

cpp と portable・wdl-jit の出力は全部 1 ビットまで同じ。iPhone は 2 回回して差は 7% 以内（fir が最大。表は 2 回目）。

`x cpp` を読むときの注意:

- cpp はホストを通らない（`ysfx_process_float` の float と double の詰め替え・締切の計測・1 フレームごとの
  `NSEEL_code_execute` の出入りが無い）。portable・wdl-jit の数字にはこの分が乗っている。`gain` は中身が
  ほぼ無いので、`x cpp` はこの分の比に近い（式を解く遅さの比ではない）
- 時計（`mach_absolute_time`）の刻みは 41.7 ns（24 MHz）。cpp の `gain` は 0.1〜0.4 us = 3〜10 刻みしかないので、
  `gain` の `x cpp`（特に -O3 の 32 倍・73 倍）は刻みの粗さで大きく揺れる。ほかのスクリプトの cpp は 0.8 us 以上
- `slow` は音を素通しするので、照合では cpp の `loop` が本当に回ったかを確かめられない。M1 の -Os の CLI を
  逆アセンブルして、200 周の `fadd` の鎖が残っていることを見た（消されてはいない）

## 段 1: 実行系を替える（2026-10-07、13c8da9）

WDL の字句・構文・compile・バイトコードはそのまま、解き方だけを替えた（`glue_port_vm.h`）。
どの実行系も `--diff`（65 本、うち 61 本が建つ）・台の 7 本・jsfxexec のファズの差分で portable と 1 ビットまで同じ。
JSON は `docs/bench/2026-10-07-stage1-*`。表は 1 ブロックの中央値（us） / portable に対する速さ / cpp の何倍遅いか。

**iPhone 16 Beta（-Os）、2 回目**（1 回目も並びは同じ。差は 1 本あたり 15% 以内、多くは 5% 以内）

| スクリプト | portable | vm-block | vm-goto | vm-goto-fpreg | vm-goto-fpreg-mask | cpp |
|---|---:|---:|---:|---:|---:|---:|
| gain | 2.1 / 8.5 | 2.0 / 1.04x / 8.2 | 1.7 / 1.27x / 6.7 | 1.7 / 1.27x / 6.7 | 1.7 / 1.27x / 6.7 | 0.2 |
| filter_drive | 23.9 / 27.3 | 23.8 / 1.01x / 27.2 | 22.1 / 1.08x / 25.3 | 17.8 / 1.35x / 20.3 | 18.0 / 1.33x / 20.6 | 0.9 |
| stereo_delay | 21.2 / 19.5 | 20.0 / 1.06x / 18.5 | 15.2 / 1.39x / 14.0 | 14.7 / 1.44x / 13.6 | 13.2 / 1.61x / 12.2 | 1.1 |
| slow | 167.8 / 5.9 | 168.0 / 1.00x / 6.0 | 124.2 / 1.35x / 4.4 | 119.7 / 1.40x / 4.2 | 117.8 / 1.42x / 4.2 | 28.2 |
| biquad | 57.7 / 33.0 | 55.9 / 1.03x / 31.9 | 51.0 / 1.13x / 29.1 | 40.9 / 1.41x / 23.4 | 41.3 / 1.40x / 23.6 | 1.8 |
| fir | 476.9 / 13.1 | 492.5 / 0.97x / 13.5 | 360.1 / 1.32x / 9.9 | 345.6 / 1.38x / 9.5 | 351.2 / 1.36x / 9.6 | 36.5 |
| math | 67.9 / 5.3 | 67.5 / 1.01x / 5.3 | 56.2 / 1.21x / 4.4 | 51.3 / 1.32x / 4.0 | 50.9 / 1.33x / 4.0 | 12.8 |
| 7 本の合計 | 817.5 | 829.8 | 630.5 | 591.6 | 594.1 | |

この日の iPhone は基準の日より全体に 2〜3 割遅い（cpp も同じだけ遅い。slow の cpp 20 → 28 us）。
基準の数字とではなく、同じ回の portable・cpp と比べること。

**M1 CLI -Os**

| スクリプト | portable | vm-block | vm-goto | vm-goto-fpreg | vm-goto-fpreg-mask | cpp |
|---|---:|---:|---:|---:|---:|---:|
| gain | 4.2 / 11.1 | 4.2 / 0.98x / 11.3 | 2.4 / 1.72x / 6.4 | 2.3 / 1.79x / 6.2 | 2.3 / 1.79x / 6.2 | 0.4 |
| filter_drive | 43.1 / 35.7 | 43.1 / 1.00x / 35.7 | 30.1 / 1.43x / 24.9 | 28.3 / 1.52x / 23.4 | 28.2 / 1.53x / 23.4 | 1.2 |
| stereo_delay | 37.7 / 28.3 | 37.8 / 1.00x / 28.3 | 29.7 / 1.27x / 22.3 | 27.2 / 1.39x / 20.4 | 26.9 / 1.40x / 20.2 | 1.3 |
| slow | 363.4 / 11.9 | 363.5 / 1.00x / 11.9 | 177.5 / 2.05x / 5.8 | 177.2 / 2.05x / 5.8 | 177.4 / 2.05x / 5.8 | 30.7 |
| biquad | 97.8 / 47.9 | 97.9 / 1.00x / 48.0 | 71.4 / 1.37x / 35.0 | 69.1 / 1.42x / 33.9 | 68.8 / 1.42x / 33.7 | 2.0 |
| fir | 999.6 / 21.5 | 999.0 / 1.00x / 21.4 | 669.4 / 1.49x / 14.4 | 584.7 / 1.71x / 12.6 | 565.2 / 1.77x / 12.1 | 46.6 |
| math | 106.2 / 6.7 | 106.2 / 1.00x / 6.7 | 83.0 / 1.28x / 5.2 | 67.5 / 1.57x / 4.2 | 67.0 / 1.58x / 4.2 | 15.9 |
| 7 本の合計 | 1652.0 | 1651.8 | 1063.5 | 956.3 | 936.0 | |

M1 の -O3（`2026-10-07-stage1-mac-m1-cli-O3-portable.json`）は vm-goto-fpreg で -Os と 0〜5% しか違わない
（fir 585 → 560、ほかは 1 us 前後）。**YSFX の段は -Os のまま**（project.yml は変えない）。
wdl-jit（-Os）は filter_drive 16.0・slow 190・biquad 23.3・fir 134・math 37.3 us で、vm-goto-fpreg は
slow で JIT よりわずかに速く（177 us）、fir で JIT の 4.4 倍、biquad で 3 倍。

### 何が効いたか

- **vm-block（1 ブロック 1 回の入口）はほぼ効かない。**`GLUE_CALL_CODE` の入口は Darwin の arm64 で
  `___chkstk_darwin`（64 KiB の積み場を頁ごとに触る）と stack protector を通るが、M1 の -Os では ±1%、iPhone で −3〜+7%
  （slow の 1 回目の 12% は 2 回目に 0% で揺れ）。1 フレームの重さは命令を引いて飛ぶところにある
- **vm-goto（computed goto）** で M1 1.3〜2.1 倍、iPhone 1.1〜1.4 倍
- **vm-goto-fpreg（積み場の先頭をレジスタに）** で 1 命令ごとの読み書きが減り、さらに iPhone 1.0〜1.25 倍
  （biquad・filter_drive が大きい）。iPhone で 7 本の合計が一番少ない
- **vm-goto-fpreg-mask（範囲の比較を省く）** は M1 の fir で 3%、iPhone では並び（stereo_delay で 1 割速く、
  slow・fir で少し遅い）。番号が 128 以上・負なら別の命令に化けうる（compile は書かないが）ので既定にしない

**アプリの既定は vm-goto-fpreg**（`NSEEL_EXEC_DEFAULT`）。iPhone の 2 回とも 7 本の合計が一番少なく、
1 ビットも違わないことを `--diff` とファズの差分で見ている。portable はそのまま選べる（`ETJSFX_SetEELExecutor(h, 0)`）。

やらなかったこと: 回の前後の spl の読み書き（`pre` / `post` の関数呼び出し）を WDL の中へ入れる版。
gain（8 命令 / フレーム）でしか見えず（M1 で 9 ns / フレームのうち数 ns）、口が増えるので段 2 で要るか決める。

### 命令の数（段 2 のため）

`run.sh --profile`（vm-goto、台の 7 本を 1 本ずつ 1 秒）。全部の組は `docs/bench/2026-10-07-opcodes-stage1.json`。
並べ方はスクリプトを同じ重さで足したもの（7 本の中の割合の平均）。生は全部の数の割合（fir と slow で決まる）。
1 フレームの命令は gain 8・stereo_delay 97・filter_drive 109・biquad 240・math 247・slow 807・fir 2351。
1 つずつでは `MOV_FPTOP_DV` が 35%、`MOV_P2_DV` が 16%。右の 7 列は各スクリプトの中の割合（%）。

| # | 1 つめ | 2 つめ | 割合（等重） | 割合（生） | biquad | filter_drive | fir | gain | math | slow | stereo_delay |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | `MOV_P2_DV` | `MOV_FPTOP_DV` | 9.73% | 9.38% | 0.0 | 1.8 | 5.8 | 25.0 | 7.2 | 24.9 | 3.4 |
| 2 | `MOV_FPTOP_DV` | `MOV_FPTOP_DV` | 9.31% | 9.12% | 16.7 | 11.9 | 11.0 | 0.0 | 10.1 | 0.0 | 15.5 |
| 3 | `MOV_FPTOP_DV` | `MUL` | 7.74% | 5.55% | 16.7 | 12.8 | 5.4 | 0.0 | 8.9 | 0.0 | 10.3 |
| 4 | `MOV_FPTOP_DV` | `ADD_OP_FAST` | 4.54% | 7.10% | 0.0 | 0.0 | 2.8 | 0.0 | 3.2 | 24.8 | 1.0 |
| 5 | `MOV_FPTOP_DV` | `ADD` | 4.35% | 6.06% | 6.7 | 3.7 | 8.3 | 0.0 | 5.7 | 0.0 | 6.2 |
| 6 | `MOV_FPTOP_DV` | `MUL_OP` | 4.03% | 0.26% | 0.0 | 0.0 | 0.0 | 25.0 | 3.2 | 0.0 | 0.0 |
| 7 | `MUL` | `MOV_FPTOP_DV` | 3.65% | 1.24% | 10.0 | 3.7 | 0.0 | 0.0 | 5.7 | 0.0 | 6.2 |
| 8 | `ADD_OP_FAST` | `LOOP_END` | 3.54% | 5.18% | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 24.8 | 0.0 |
| 9 | `LOOP_END` | `MOV_P2_DV` | 3.53% | 5.18% | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 24.7 | 0.0 |
| 10 | `MOV_P2_DV` | `ASSIGN_FROMFP` | 3.50% | 1.17% | 10.0 | 7.3 | 0.0 | 0.0 | 4.1 | 0.0 | 3.1 |
| 11 | `ASSIGN_FROMFP` | `MOV_FPTOP_DV` | 3.31% | 1.11% | 10.0 | 6.4 | 0.0 | 0.0 | 3.6 | 0.0 | 3.1 |
| 12 | `MUL_OP` | `MOV_P2_DV` | 2.24% | 0.23% | 0.0 | 0.0 | 0.0 | 12.5 | 3.2 | 0.0 | 0.0 |
| 13 | `(start)` | `_RESET_WTP` | 2.21% | 0.18% | 0.4 | 0.9 | 0.0 | 12.5 | 0.4 | 0.1 | 1.0 |
| 14 | `MUL` | `MOV_P2_DV` | 2.00% | 3.60% | 0.0 | 7.3 | 5.4 | 0.0 | 1.2 | 0.0 | 0.0 |
| 15 | `_RESET_WTP` | `MOV_P2_DV` | 1.86% | 0.08% | 0.0 | 0.0 | 0.0 | 12.5 | 0.4 | 0.1 | 0.0 |
| 16 | `MUL_OP` | `RET` | 1.79% | 0.03% | 0.0 | 0.0 | 0.0 | 12.5 | 0.0 | 0.0 | 0.0 |
| 17 | `ADD` | `MEGABUF` | 1.77% | 5.13% | 0.0 | 0.0 | 8.3 | 0.0 | 0.0 | 0.0 | 4.1 |
| 18 | `SUB` | `MOV_FPTOP_DV` | 1.67% | 0.47% | 3.3 | 5.5 | 0.0 | 0.0 | 0.8 | 0.0 | 2.1 |
| 19 | `ADD` | `MOV_P2_DV` | 1.63% | 0.57% | 6.7 | 1.8 | 0.0 | 0.0 | 0.8 | 0.0 | 2.1 |
| 20 | `MOV_FPTOP_DV` | `SUB` | 1.48% | 0.31% | 0.0 | 6.4 | 0.0 | 0.0 | 0.8 | 0.0 | 3.1 |

## 段 2 の S1: 持ち上げと照合（2026-10-07）

レジスタ型 VM（`docs/jsfx-regvm-design.md` §15）の土台。バイトコードを SSA の中間表現に持ち上げ、参照の解釈で回す
（vm-reg）。速さはまだ見ない（portable の 0.2〜0.8 倍）。照合だけ:

| 層 | Linux x86-64 -Os・-O3 | M1 -Os・-O3 | iPhone 16 Beta |
|---|---|---|---|
| `--vm-opgrid`（命令ごとの値の格子） | 75,825 組 0 違い | 75,825 組 0 違い | — |
| `--diff`（62 本、vm-reg を含む全部の実行系） | 62/62 一致 | 62/62 一致 | 台の 7 本 vm-reg bit-exact |
| jsfxexec のファズ（vm-reg を差分の 3 つめに） | 300 秒・67,533 回・落ち無し | — | — |

NaN が 2 つ（ペイロードが違う）の `+` `*` は、どちらが残るかを portable の C コンパイラが決める（オペランドを入れ替える）
ので数えない（x86-64 で 40 組・arm64 で 24 組）。持ち上げは 145 handle 中 144（落としたのは `__dbg_getstackptr` を
わざと使う `opcodes.jsfx` の @sample だけ）。JSON は `docs/bench/2026-10-07-s1-*`。

## 段 2 の S2: threaded code（2026-10-07、d6b26a0）

vm-reg の中身を、持ち上げた中間表現から並べた threaded code にした（`docs/jsfx-regvm-design.md` §16）。中間表現の
命令 1 つにハンドラ 1 つ、`[[clang::musttail]]` で次へ。オペランドは升・枠の絶対番地で、LoadCell はオペランドへ畳み、
StoreCell の升へじかに書き、四則 + フィルタと megabuf の番地 + 読み書きは 1 つにする。@sample は 1 ブロック 1 回の入口。
**アプリの既定は vm-goto-fpreg のまま**（vm-reg は台だけ。台では名指ししなくても回す）。
段 S1 の参照の解釈は `ETVM_SetEngine(ETVM_ENGINE_REFERENCE)` で残してあり、`--diff` は vm-reg-ref として両方を比べる。

照合: `--vm-opgrid`（portable・参照の解釈・threaded の 3 つ）75,825 組・`--diff` 62/62 が Linux x86-64 と M1 の -Os・-O3 で
1 ビットまで一致。iPhone の台 7 本も 2 回とも bit-exact。
ファズ: 新しい的 `jsfxvmdiff`（`bash Tests/Fuzz/run.sh --target jsfxvmdiff`。portable と vm-reg を 1 歩ずつ並べ、
rand・onfail・_global.*・gmem を歩みごとに写して戻しながら比べる。EEL の文法から作った文を差し込む変異つき）。
ASan・UBSan で 7 回・約 1.6 時間（`-fork=6`、約 9.5 CPU 時間、約 63 万回）。実行系を最後に変えたあと（d6b26a0）の
2 回（1,806 秒・2,420 秒、約 7 CPU 時間、502,798 回）で vm-reg と portable の違いは 0。見つかったのは的の側と
portable 自身のもの（API の呼び方の型、ユーザーの積み場の初期値、portable が積み場の外を読む入力 2 つ、-fork の
親が子の落ちを数えないこと）で、どれも直した（設計 §16.2・§16.3）。調べるときは `JSFXVMDIFF_TRACE=1`（歩みごとの
時間・持ち上げの理由・断った handle のバイトコード）、`JSFXVMDIFF_SECTIONS=0x10`（vm-reg にする節を絞る）。
`FUZZ_FORK=6` で子を 6 つ回せる。

1 ブロック（256 フレーム）の中央値（us） / portable に対する速さ / vm-goto-fpreg に対する速さ / cpp の何倍遅いか。

**M1 CLI -Os**（wdl-jit は別の回。`vs jit` は wdl-jit ÷ vm-reg）

| スクリプト | portable | vm-goto-fpreg | vm-reg | vs portable | vs fpreg | x cpp | cpp | wdl-jit | vs jit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gain | 4.2 | 2.3 | 1.9 | 2.22x | 1.24x | 5.0 | 0.4 | 9.4 | 5.00x |
| filter_drive | 42.5 | 27.8 | 14.3 | 2.97x | 1.94x | 12.2 | 1.2 | 16.1 | 1.13x |
| stereo_delay | 37.3 | 26.5 | 10.6 | 3.52x | 2.50x | 7.9 | 1.3 | 15.3 | 1.44x |
| slow | 356.6 | 174.2 | 177.0 | 2.01x | 0.98x | 5.9 | 30.1 | 184.1 | 1.04x |
| biquad | 96.0 | 67.6 | 31.8 | 3.02x | 2.13x | 15.9 | 2.0 | 21.7 | 0.68x |
| fir | 938.8 | 573.0 | 230.9 | 4.07x | 2.48x | 5.1 | 45.7 | 125.0 | 0.54x |
| math | 104.2 | 66.3 | 50.4 | 2.07x | 1.31x | 3.2 | 15.6 | 36.7 | 0.73x |
| 7 本の合計 | 1579.6 | 937.7 | 516.8 | 3.06x | 1.81x | | 96.3 | | |

M1 の -O3 は vm-reg が -Os とほぼ同じ（合計 516.0。1 本ごとには −7〜+2%、−7% は 1.9 → 1.8 µs の gain、次が stereo_delay の −4%）。portable は -O3 で速くなる（合計 1466.7）ので vs portable は
1.66〜3.93x。

**iPhone 16 Beta（-Os）、2 回目**（vm-reg の括弧は 1 回目。2 回目は fir・math で全部の実行系が 2 割近く遅いが、比は
±0.1 で同じ）

| スクリプト | portable | vm-goto-fpreg | vm-reg | vs portable | vs fpreg | x cpp | cpp |
|---|---:|---:|---:|---:|---:|---:|---:|
| gain | 2.1 | 1.7 | 1.2 (1.2) | 1.70x | 1.33x | 4.3 | 0.3 |
| filter_drive | 22.5 | 16.1 | 8.2 (8.0) | 2.76x | 1.97x | 10.3 | 0.8 |
| stereo_delay | 19.3 | 13.2 | 6.6 (6.2) | 2.91x | 2.00x | 6.9 | 1.0 |
| slow | 158.2 | 114.8 | 140.4 (130.8) | 1.13x | **0.82x** | 5.7 | 24.7 |
| biquad | 58.7 | 40.5 | 19.8 (17.9) | 2.96x | 2.04x | 11.3 | 1.8 |
| fir | 479.8 | 340.3 | 210.4 (183.5) | 2.28x | 1.62x | 5.6 | 37.3 |
| math | 72.2 | 52.9 | 40.7 (34.6) | 1.77x | 1.30x | 3.1 | 13.3 |
| 7 本の合計 | 812.8 | 579.5 | 427.4 (382.2) | 1.90x | 1.36x | | 79.1 |

- **slow だけ vm-goto-fpreg より遅い**（iPhone で 0.82x、M1 で 0.98x）。`loop(n, i += 1)` が 1 周 4 ハンドラで、
  うち `IDec` → `IGt0` → `BrT` が枠の升を書いて次が読む鎖になる（vm-goto-fpreg は `LOOP_END` 1 つ）。
  段 S3 の loop-next・比べと分かれ道の 1 つ化で直す
- biquad・fir・math は M1 の wdl-jit がまだ 1.4〜1.9 倍速い（値ごとにメモリを往復し、命令ごとに 1 回飛ぶ）。
  段 S3・S4（畳み込み・木のカーネル）の的
- 持ち上げた 144 handle は全部 threaded code になる。@sample は中間表現 1 命令あたり 0.41 ハンドラ
  （`docs/bench/2026-10-07-s2-vm-coverage-mac-m1-Os.json`）
- Apple clang -Os の `objdump` で、四則・フィルタ付きの代入・写し・分かれ道・loop の数・megabuf の速い道の
  ハンドラは積み場の枠を作らない葉（`br x2` で次へ）。枠があるのは外を呼ぶもの（libm・API・gmem・megabuf の遅い道・`Ret`）だけ
- 測ったあいだ Mac では `ANECompilerService` が 1 コアを使っていた（実行系は 16 ブロックごとに入れ替えるので比は崩れない）

JSON は `docs/bench/2026-10-07-s2-*`。

## 段 2 の S3: 最適化と 1 つにまとめた命令（2026-10-07、5487bff）

vm-reg に段 S3 を足した（`docs/jsfx-regvm-design.md` §17）。中間表現の上でブロックの中だけ: どの handle も書かない升を
定数に（constcell）、定数だけの演算を畳む（fold。NaN・非正規化数・invsqrt・libm は畳まない）、同じ升の読み直しと
同じ演算を 1 つに（cse）、書いた値をそのまま使う（fwd）、外へ漏れない作業表の升の書き込みを消す（promote）。
並べる段で: loop の入口・次の周・while の次（条件の比べごと）を 1 つ、比べ + 分かれ道を 1 つ、定数のオペランドを
命令の中に・行き先 = 左（`cell OP= 定数／cell`）、megabuf の頭 + 添字、続いた四則 2 つ（+ フィルタ）、中身が
`cell OP= 定数／cell` 1 つの loop を 1 つのハンドラで回し切る（loop kernel。値はレジスタに置いて最後に 1 回書く）。
loop の数の升は phi と生きている範囲で合わせ、写しが消える。
1 つずつ `ETVM_PASSES` で切れる（`ETVM_PASSES=-cse,-lkern`、`none,+loop`、`all`。中身は `Sources/JSFXVM/ETVM.h`）。
`--vm-dump` は段 S3 の数え（畳んだ升・まとめた数）も出し、`--vm-opgrid` は「書かない升を Const として最適化した
threaded code」も 3 つめに比べる。**アプリの既定は vm-goto-fpreg のまま。**

照合: `--vm-opgrid` 75,825 組・`--diff` 65/65 が Linux x86-64 と M1 の -Os・-O3 で 1 ビットまで一致（Linux -Os では
最適化を 1 つずつ外した版・全部外した版も 65/65）。iPhone の台 7 本も 2 回とも bit-exact。
ファズ: `jsfxvmdiff` を最後に実行系を変えたあと（5487bff）、S2 の corpus から ASan・UBSan・`-fork=6` で 2,741 秒
（うち親が corpus を読み直す 795 秒、6 本で 1,946 秒 ≈ 3.5 CPU 時間、113,105 回）。vm-reg と portable の違い・落ちは 0
（時間切れ 56 は ASan の下で上限まで回る入れ子の loop）。設計 §12.9 の 24 CPU 時間にはまだ足りない。

**iPhone 16 Beta（-Os）、2 回目**（vm-reg の括弧は 1 回目。1 ブロックの中央値 us / portable に対する速さ /
vm-goto-fpreg に対する速さ / cpp の何倍遅いか）

| スクリプト | portable | vm-goto-fpreg | vm-reg | vs portable | vs fpreg | x cpp | cpp |
|---|---:|---:|---:|---:|---:|---:|---:|
| gain | 2.3 | 1.7 | 1.2 (1.2) | 1.90x | 1.41x | 4.1 | 0.3 |
| filter_drive | 22.1 | 15.8 | 5.9 (5.9) | 3.73x | 2.66x | 7.9 | 0.8 |
| stereo_delay | 18.5 | 12.2 | 4.3 (4.3) | 4.32x | 2.85x | 4.7 | 0.9 |
| slow | 130.3 | 92.7 | 21.8 (21.7) | 5.99x | 4.26x | 1.1 | 20.5 |
| biquad | 49.1 | 32.2 | 10.2 (10.8) | 4.79x | 3.14x | 7.2 | 1.4 |
| fir | 391.5 | 283.9 | 111.5 (104.9) | 3.51x | 2.55x | 3.5 | 31.5 |
| math | 58.2 | 44.2 | 25.0 (24.9) | 2.33x | 1.77x | 2.4 | 10.5 |
| 7 本の合計 | 672.1 | 482.8 | 180.0 (173.6) | 3.73x | 2.68x | | 65.8 |

**M1 CLI -Os**（`vs jit` は wdl-jit ÷ vm-reg）

| スクリプト | portable | vm-goto-fpreg | vm-reg | vs portable | vs fpreg | x cpp | cpp | wdl-jit | vs jit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| gain | 4.2 | 2.3 | 1.8 | 2.27x | 1.27x | 4.9 | 0.4 | 9.4 | 5.11x |
| filter_drive | 43.2 | 28.2 | 10.2 | 4.22x | 2.75x | 8.5 | 1.2 | 16.2 | 1.58x |
| stereo_delay | 37.7 | 27.2 | 7.7 | 4.92x | 3.55x | 5.8 | 1.3 | 15.1 | 1.97x |
| slow | 363.4 | 177.2 | 33.7 | 10.79x | 5.26x | 1.1 | 30.7 | 183.9 | 5.46x |
| biquad | 96.2 | 68.3 | 21.2 | 4.53x | 3.22x | 10.4 | 2.0 | 21.5 | 1.01x |
| fir | 973.8 | 583.7 | 164.9 | 5.91x | 3.54x | 3.5 | 46.6 | 127.1 | 0.77x |
| math | 106.1 | 67.5 | 43.7 | 2.43x | 1.54x | 2.7 | 15.9 | 37.4 | 0.86x |
| 7 本の合計 | 1624.5 | 954.5 | 283.2 | 5.74x | 3.37x | | 98.2 | 410.6 | |

M1 の -O3 は vm-reg が -Os と ±2% 以内（slow だけ 22.3 と速い。loop kernel の回し方が締まる）。

- **全部のスクリプトで vm-goto-fpreg より速い**（iPhone 1.41〜4.27x、M1 1.27〜5.26x）。設計 §12.9 の「段 1 の既定より
  5% を超えて遅いものが無い」を満たす。S2 で 18% 遅かった slow は loop kernel で cpp とほぼ同じ
- loop の次の周 1 つ化だけでは slow は M1 で速くならない（`i` を升に書いて次の周で読む鎖が 1 周の時間を決める。
  vm-goto-fpreg も同じ）。iPhone では 140 → 124 us、loop kernel で 22 us
- M1 の wdl-jit はまだ fir（0.77x）と math（0.86x）で速い。biquad は並んだ。fir の内側は 1 周 9 ハンドラ
  （megabuf の読み 3・積和 2・`k += 1`・`j -= 1`・比べて跳ぶ・次の周）
- 1 つずつ足したときの効き（M1 -Os、7 本の合計 us）: S2 の組 528.7 → loop 508.0 → cmpbr 492.1 →
  constcell・opimm・opto 486.1 → membi 455.2 → fuse2 425.0 → lkern 282.6 → 中間表現の fold・cse・fwd・promote 281.0
  （`docs/bench/2026-10-07-s3-passes-mac-m1-Os.json`）

JSON は `docs/bench/2026-10-07-s3-*`。
