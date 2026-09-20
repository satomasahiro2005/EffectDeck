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
