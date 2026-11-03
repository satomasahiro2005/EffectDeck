# Virtual Room はここで止めた（2026-09-21）

`docs/virtual-room-design.md` の続き。§62 にあたる。

**実機まで通したが音が駄目で、一旦ここで止めた。**枝は `feature/brir`。
main へは入れていない。**原因は全部割れている**ので、拾い直すのは安い。

## 動いているもの

- 鎖に載って音は通る。実機ビルドとインストールまで通った
- UI（真上の図、掴んで動かす、Advanced、出荷時プリセット 5 本）
- BRIR 書き出し（4ch WAV、LL / LR / RL / RR）
- 保存・share link・型の印 `ed`・上流リンクからの除外・routing 制約
- 単体テスト 14 本（seed / §53 のクランプ / プリセットの範囲）
- 上流へ出せる置き場（§61）。`params.json` が正本

## 音が駄目な原因

**実時間の経路は壊れていない。**BRIR を畳んだ音と実時間出力が **−133 dB** で
一致する。ブロック長を 64 / 128 / 256 / 480 / 512 で振っても同じ。
`applyImmediate` と `publish` → `process` も −131 dB で一致。
**ずれているのは音響モデルの方。**

| | 場所 | 中身 |
|---|---|---|
| **A** | `virtual_room_model.h` の `lateGain` | **遅延線の総長 Σd が式から抜けている。**根拠にしている `‖b‖²/(1−g²)` は遅延 1 サンプルの帰還路の式で、遅延線が d_i サンプルあるとエネルギーは Σd_i 個のスロットへ散る。正しくは `‖b‖²·‖c‖²/(Σd_i·(1−p²))`。残響が **39 dB 足りない**（`10·log10(Σd) = 38.55` と実測の不足 39.1 が 1 dB 以内で揃う）|
| **B** | `virtual_room_model.h` の `mixingTime` | 平均自由行程の 6 倍＝38.9 ms、`preDelay` は 33.8 ms。一方 2 次の鏡像でも早期反射は **22.7 ms で終わる**（1 次なら 10.8 ms）。**間が完全な無音**（30 ms の窓が −213 dB）。元の JS は tail を 6 ms から始めている |
| **C** | `virtual_room_model.h` の `coherent` | 「25 個の像が低域で全部同相に積もる」前提が強すぎる。像は 0〜22.7 ms に散っているので 300 Hz 以下でも同相にはならない。`max` を取るので全体が **8.5 dB 小さい** |
| **D** | `virtual_room_engine.cpp` の `const RenderState &pinna = *active_;` | 最初の `publish` 直後、`active_` はまだゼロ初期化。耳介のゲインが全部 0 になり、**その間の入力が丸ごと消える**。長さは `transitionFrames_` ＝ 48kHz で最低 8 ms、`maxFrames` 4096 なら 85 ms。再生開始のたびに頭が欠ける |

**A を単独で直さないこと。**正規化側の `lateLow` も同じ抜けを持っているので、
`lateGain` だけ 84.6 倍すると `coherent` が 9.36 → 17.24 に跳ねて
**逆に 5.3 dB 下がる**。A と C は同時に直す。

DRR を late の入口（33.8 ms）で測った値:

```
元の JS の IRS          +12.3 dB   （tail の起点 6ms で切れば +4.1 dB）
Virtual Room の BRIR    +47.1 dB
設計が狙っている値        8 dB
```

BRIR の 10 ms ごとのエネルギー: 0 ms −45.2 dB、22.7 ms −61.4 dB、
**30 ms −213.0 dB（実質ゼロ）**、40 ms −96.9 dB。部屋が鳴っていない。

## 聴いた印象と数字

```
                         低      中      高
入力                  -12.14  -19.10  -21.14
元の JS の IRS        -12.68  -22.36  -24.82
Virtual Room (+8.5dB) -10.96  -25.19  -25.83
```

低域が 1.6 dB 高く中域が 2.9 dB 低い。**小さくて、こもっていて、部屋が鳴らない。**

## 道具（残してある）

| | |
|---|---|
| `Tools/brir_render.cpp` | 同じエンジンで BRIR を offline 書き出し |
| `Tools/brir_ab.cpp` | 同じ音を実時間経路と畳み込みの 2 通りに通して、峰・実効値・3 帯域・0dBFS 超えを出す |
| `Tools/brir_compare.py` | 4ch を 2 本並べて数字で出す |

Mac で建てる（Windows にコンパイラが無い）:

```
clang++ -std=c++20 -O2 -I EffectDeckLocalDSP/spatial/virtual_room -I Generated/dsp
  -I Vendor/effetune/dsp/include -I Vendor/effetune/dsp
  Tools/brir_render.cpp EffectDeckLocalDSP/spatial/virtual_room/virtual_room_engine.cpp
  -o /tmp/brir_render
```

元の JS は `M0Rf30/easyeffects-presets` の
`scripts/generate-synthetic-binaural-room.js`。node で回すと 4ch IRS が出る。

## 次に拾うなら

1. **A と C を同時に直す**（Σd を入れる。正規化側も揃える）
2. **B を直す**（`preDelay` を早期反射の終わりに合わせる。元の JS の 6 ms が手本）
3. **D を直す**（渡りの間は `incoming_` 側の耳介も使うか、`active_` が空なら渡りを挟まない）
4. 直したら `brir_ab` で測る。**耳より先に数字**

**比べるときの注意。**IR Reverb の既定は `wetLevel = -15 dB` /
`dryEnabled = true` / `dryLevel = 0 dB`。
**dry を切らずに BRIR を聴くと直接音が頭部モデルを通らない**ので、
それだけで Virtual Room とは別物に聞こえる。比べるときは dry を切ること。

---

## 直した（2026-11-03）

枝は `feature/virtual-room`（`feature/brir` に main を取り込んだもの）。
A〜D と、測っていて見つけた E を直した。**音の構造は目標に乗った。全体の高さと
低域の傾きは届いていない**（下の「残っている差」）。

| | 直したこと |
|---|---|
| **A** | `lateGain` に Σd を入れた。帯域ごとに RT60 が違うので、3 帯域の割り方の Gram 行列 G で `Σ_ij G_ij / (Σd (1 − p_i p_j))` として白で数え、direct も同じ G で数える。late の入力から `sourceNormalization` を外した |
| **B** | late の入口を **1 次の像の終わり**（既定で 10.75 ms）にした。`preDelay` はそこから**いちばん短い遅延線のぶんを引く** |
| **C** | 低域の同相和を、実際の遅れ・3 帯域の応答・耳介の FIR から複素数で足す（40〜300 Hz の 24 点）。late は低域の減衰で数えたエネルギーを足す。A と同じ変更で入れた |
| **D** | `hasState_`。prepare したての engine は最初の面を渡りを挟まずに取る。渡りの間は耳介も 2 面で掛けて混ぜる |
| **E** | 遅延線の下限が 8 ms で、既定の部屋では短い 8 本が 385, 387, … 399 と 0.5% おきに積み重なっていた（late の入口も +8 ms 遅れた）。下限 2.5 ms、揺らし ±4%、並べて隣を 3% 以上離す |

**決めたこと。**

- **DRR は音源ごとに両耳を足した比。**前は late を 1 耳、direct を両耳で数えていて 3 dB 曖昧だった
- **Room Amount 200% で late は +6 dB**（DRR は 8 − 6.02 ≈ 2 dB）。式は前から振幅の 2 乗で、
  コメントの「+3 dB」が間違っていた。像（early）も振幅で 2 倍なので、早期と late の釣り合いを崩さない方を取った
- **C の下限は 40 Hz。**測って決めた（下の表）。40 Hz より下では像は本当にほぼ同相に積もる
  （C の「300 Hz 以下でも同相にならない」は 40 Hz より上でしか成り立たなかった）

### 測り方

`Tools/brir_metrics.cpp`（同じエンジン。`applyState` に経路の帯域ゲインや late の入力を
0 にした面を渡して direct / early / late を別々に取り出す）。48 kHz、block 512、
params.json の既定（2 次・天井 Drywall）。WSL の g++ 13 と Mac の clang++ で同じ数字。

**この表の曲は stop.md の上の曲とは別物。**上で使った曲は残っていなかったので、
`brir_metrics signal` が決まった乱数で作る 12 秒（低音は左右同相のベースとキック、
中高域は左右で半分ほど相関した雑音、峰 −1 dBFS）を使った。3 帯域は −18.34 / −24.77 / −25.77 dB で、
上の曲（−12.14 / −19.10 / −21.14）と帯域の差の付き方が近い。

### 前といま

| | 前 | いま | 目標 |
|---|---|---|---|
| DRR_late（音源 0 / 1） | +41.9 / +42.1 dB | **+7.3 / +7.7 dB** | 8 ±1 |
| DRR_late、Room Amount 200% | — | +1.3 / +1.7 dB | 2 ±1 |
| late の立ち上がり（direct の峰から −80 dB） | 41.81 ms | **10.75 ms** | 1 次の終わり 10.75 ±1 |
| 80 ms までで最も静かな 5 ms 窓 | −247.3 dB | **−26.3 dB** | > −60 |
| 20-30 / 30-40 ms の窓と、10-20・40-50 を結んだ直線との差 | +4.3 / −131.7 dB | −4.0 / −4.0 dB | ±6 |
| 遅延線の隣の最小の差 | 0.45% | 3.65% | ≥ 3% |
| 0 フレーム目のインパルス（publish → process） | 全部消える | **BRIR と差 0** | −100 dB 以内 |
| 雑音を畳み込みと比べる、頭から（block 64〜512） | −4.8〜−5.5 dB | −129.5 dB | −120 以内 |
| 同じ、8192 サンプル以降 | −70〜−72 dB | −129.5 dB | |
| 同相の正弦 −1 dBFS、40〜120 Hz の峰 | −5.64 dB | **+0.17 dB** | ≤ +1 |
| 同じ、20〜35 Hz（参考） | — | +4.12 dB | |
| 曲の代わりの rms（入力に対して） | −12.23 dB | **−6.38 dB** | ±1（届かない） |
| 同、低 / 中 / 高 | −11.38 / −15.32 / −13.64 | −5.53 / −9.42 / −7.77 | |
| 0 dBFS 超え | 0 | 0 | 0 |

元の JS の IRS（IR Reverb と同じ形、**dry 無し**、0 dB）を同じ曲に通すと、rms +0.92、
低 / 中 / 高 +1.31 / +0.24 / −0.10 dB、峰 +0.53 dBFS で 0 dBFS 超えが 8 個。
元の JS に寄せた配置（`brir_ab` の既定。1 次・天井 Painted Wall）の Virtual Room は
rms −4.84、低 / 中 / 高 −4.02 / −7.49 / −6.41 dB。

BRIR の窓（5 ms ごと、直接音の窓に対して）:

```
              0     5    10    15    20    25    30    40    60    80 ms
元の JS     +0.0  -7.2  -8.4 -12.5 -13.6 -14.8 -16.0 -18.4 -23.1 -27.9
いま        +0.0  -1.3  -2.9 -10.9 -12.6 -19.4 -20.2 -21.8 -23.8 -27.0
```

`brir_compare.py`（元の JS の IRS と、元の JS に寄せた配置の BRIR）の帯域の形の差は
LL / RR で 0.7 dB 以内、LR / RL で 中 −1.8・高 +0.8 dB。RT は元の 0.22 s に対して 0.40〜0.46 s
（材質の表から Eyring で出したもの。元は 0.26 s の直打ち）。

### C の下限を決めた数字

同相の低音の上限をどこから測るかで、全体の高さと低音のはみ出しがこう替わる（既定の部屋）:

| 低域の同相和を測る下限 | rms（入力に対して） | 40〜120 Hz の峰 | 20〜35 Hz の峰 | 曲の 0 dBFS 超え |
|---|---|---|---|---|
| 20 Hz | −10.41 dB | −3.86 dB | +0.09 dB | 0 |
| **40 Hz（採用）** | −6.38 dB | +0.17 dB | +4.12 dB | 0 |
| 60 Hz | −2.81 dB | +3.74 dB | +7.68 dB | 0 |
| 見ない（無相関だけ） | +1.18 dB | +7.73 dB | +11.67 dB | 6 |

無相関の高さ（中高域）は +6.24 dB、20〜300 Hz の同相和は +17.82 dB、40〜300 Hz では +13.79 dB。
**40 Hz より下は既定の部屋のいちばん低い軸モード（41 Hz）より下で、2 次で打ち切った像の和が
密閉した箱の圧力のように効く所。**そこまで守ると全体がさらに 4 dB 小さくなるので、
目標の帯域（40〜120 Hz）を守る所で切った。**20〜35 Hz の同相の低音を −1 dBFS で入れると
+4 dB まで出る**のは承知の上。

### 残っている差

1. **全体の高さ（rms −6.4 dB、目標 ±1）。**同相の低音の周波数応答が、既定の部屋では 20 Hz で
   1 kHz より 15 dB、40 Hz で 11 dB 高い（`brir_metrics response app`）。元の JS は同じ所で
   +5 / +4 dB。1 本のスカラーではこの傾きを消せないので、「入力と同じ高さ」と
   「同相の低音でバイパスを超えない」は両立しない。**詰めるならモデルの低域**
   （2 次の像の低域の積もり方、材質の低域の吸音、既定の部屋の硬さ）で、A〜D の外の話
2. **3 帯域の形。**中域を元の JS に揃えると、低域が +2.9 dB、高域が +2.0 dB 多い
   （元の JS に寄せた配置では +2.4 / +1.4）。目標 ±1.5 に対して低域が外れる。
   高域の差の原因はまだ切り分けていない（耳介の FIR は元の JS と同じ表）
3. **88.2 / 96 kHz の DRR は +10.7 / +11.0 dB**（48 kHz は +7.3）。late を半分のレートで回して
   4 kHz の 1 次で均して戻すので（§25）、白で測ると late の 4 kHz より上が足りない。前からある形
4. 既定の部屋は early が direct より 3.6 dB 大きく、RT60 は中域 0.71 s（元の JS は 0.26 s）。
   硬い部屋として作ってある。耳で聴いて「こもる」「部屋が鳴りすぎる」なら材質と既定の話

### 道具と試験

| | |
|---|---|
| `Tools/brir_metrics.cpp` | 上の数字を全部出す。目標を外れたら FAIL で 1 を返す |
| `Tests/Native/virtual_room.cpp` | ci.yml の native（gcc / clang × ASan+UBSan）。DRR、late の入口、無音の窓、遅延線の間隔、同相の低音、最初の block、レートを変えた prepare、ブロック長、同じ面の出し直し |

Mac で建てる:

```
clang++ -std=c++20 -O2 -I EffectDeckLocalDSP/spatial/virtual_room -I Generated/dsp
  -I Vendor/effetune/dsp/include -I Vendor/effetune/dsp
  Tools/brir_metrics.cpp EffectDeckLocalDSP/spatial/virtual_room/virtual_room_engine.cpp
  -o /tmp/brir_metrics
/tmp/brir_metrics signal music.wav && /tmp/brir_metrics file music.wav app
```

**耳はまだ。**次は実機で、dry を切った元の IRS と並べて聴く。
