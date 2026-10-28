# MiniMetersBench

PiP の Mini Meters（`ETMiniMeters`）の 1 コマの重さを Mac で測り、前後で比べる道具。
**リポジトリの `MiniMeters.swift` と `ETMeterTap.c/.h` をそのまま建てる**（写しを持たないので古びない）。
測定機の本体は `main.swift` だけ。

## 使い方

```
bash Tools/MiniMetersBench/run.sh <label>
# 例: bash Tools/MiniMetersBench/run.sh baseline-cee1267
```

2 分ちょっとで終わる（電池を食う長い測定はしない）。やること:

1. 測る 3 ファイルと道具を Mac の `~/work/minimeters-bench/src` へ送る。改行は LF にそろえ、送った先の sha256 を突き合わせる
2. Mac で `swiftc -O` を建てる（`xcodebuild`・Xcode のアカウント・シミュレータは使わない）
3. 別プロセスで 2 回測る
4. `results/<label>.md` と `results/<label>.tsv` を持ち帰る

| 引数・環境変数 | 既定 | 意味 |
|---|---|---|
| `--runs N` | 2 | 測る回数（別プロセス）。安定しているかはこれで見る |
| `--rounds N` | 22 | 1 信号あたり 22 x 28 = 616 コマ |
| `--canvas plain\|cv` | plain | 器。plain は CGContext の自前メモリ、cv は本番と同じ IOSurface 付き CVPixelBuffer（今の版では差は 2% 以内） |
| `MAC` | `satoumasahiro@100.77.178.77` | 繋ぎ先。Tailscale 側を先に |

結果の `.md` は人が読む表（全体・区画別・pull・安定度・測り方）、`.tsv` は run x build x 信号 x 指標の全要約（ms）。
どちらも**コミットはしても勝手にしない**（label を決めてから）。

## 前後を比べるとき

- 同じ Mac の**同じ条件**で測る。**電源につないでいるか・省電力モードか**で 1 コマの重さが 4 割変わった
  （baseline の前に試した回は、測定の途中で電池から電源に変わり、run 1 と run 2 が 39% 違った）。
  冒頭の `conditions` に測定の前後の状態が出る。途中で変わると `warning` が出るのでやり直す
- 他の重い仕事（Xcode のビルドなど）が走っていない時に測る。`idle=` が 90% 台であること
- `.tsv` どうしを突き合わせる。`draw_total` の `median_ms` が主、`p95_ms` は引っかかり
- 同じ `label` で 2 回走らせると上書きされる。版の短い hash を label に入れる（`baseline-cee1267`、`after-xxxxxxx`）

## 測るもの

1 コマは本番の `tick` と同じ順（`ETMeterTap_Write` で 1/30 秒ぶん → `pull(rate:now:)` → `draw(in:)`）で、
器は 1280x256 の BGRA（premultipliedFirst・little endian・DeviceRGB）を `PiPVisualizer.pixelBuffer` と同じに反転したもの。
`draw` が「写す道」を通らないと止まる（黙って遅くならない）。

- 全体: `draw` の中央値・p95・平均と、`pull` と、その和（`frame`）
- 区画別: 背景+スペクトログラムの写し・波形・スペアナ（線込み）・ステレオの点・レベル。
  `private` を外しただけの写しを**建てるたびに元から機械的に作り**（`build.sh` の sed。10 行でなければ止まる）、
  `draw` の中身を同じ順で 1 つずつ時計で挟む。区画の和と全体が合うこと（`和/全体` が 1 に近い）を表 5 で見る
- `pull` のうち FFT 側（`advanceSpectrogram`）の単独の重さ

信号は決まった作り方で毎回同じ（合成 6 種: 対数スイープ・ピンクノイズ・回るステレオ・クリック・近い無音・広いステレオ）。
曲は `~/work/mmpreview/demo.mp3` と `vibe.mp3` の 3 か所ずつ（無ければ飛ばす。場所は `main.swift` の `--songs`）。
曲は測る前に必要なぶんを読み込んでおく。信号は 180 コマ温めたあと 30 コマずつ順に回して時間のずれを均す。

## 限界

- 連続して回すので、30fps で休みが入る本番よりは CPU が高い周波数に乗りやすく、キャッシュも温かい。
  絶対値でなく**同じ道具での前後比較**に使う
- ブロックの頭 2 コマは信号の切り替えで冷えているので捨てる
- スペアナの塗りと線は同じ関数なので分けられない

## 手で動かす（Mac の上で）

```
bash Tools/MiniMetersBench/build.sh . /tmp/mmbench        # リポジトリの根で。bench_total と bench_seam ができる
/tmp/mmbench/bench_total out.tsv --rounds 22 --canvas plain
```

## 部品

| ファイル | 役割 |
|---|---|
| `run.sh` | 送る → 建てる → 測る → 持ち帰る |
| `build.sh` | `swiftc`・`clang` で `bench_total`（元のコード）と `bench_seam`（区画別用）を作る |
| `main.swift` | 信号の生成・器・時計・集計 |
| `bridge.h` | `ETMeterTap.h` を Swift へ見せる |
| `snap.sh` | Mac の電源・省電力モード・CPU の空きを 1 行で出す |
| `report.py` | 生の tsv を md と tsv にまとめる（Mac の標準 python3 で動く） |
| `results/` | 測った結果（`<label>.md` / `.tsv`） |

## 注意（mmpreview-ab の雑音）

`~/work/mmpreview-ab/main.swift` の `Rng.next()` は `s >> 33` を `Int32` にするため **0...1 しか出さない**（コメントは -1...1）。
そこから作った `silence`・`wide` の雑音には直流が乗っている。この道具では `s >> 32` に直してあるので、
過去の mmpreview-ab の数字と区画の重さを直接比べない。
