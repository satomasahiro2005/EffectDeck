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

これから足す実行系（vm）は `kVariants` に 1 行足す。最初の行（portable か wdl-jit）が照合の基準で、
vm は `Check::exact`（1 ビットも違ってはいけない）にする。cpp は差 `1e-6` まで許す（いまはどれも一致）。

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
