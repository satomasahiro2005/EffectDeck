# EffectDeck Virtual Room 最終設計

## 1. 概要

EffectDeckに独自ネイティブDSPエフェクト **Virtual Room** を追加する。

これはIRファイルを読み込むIR Reverbではない。

入力ステレオを2本の仮想スピーカーとして扱い、

\[
\text{Virtual Speakers}
\rightarrow
\text{Room}
\rightarrow
\text{Head / Ears}
\]

をリアルタイムでシミュレーションし、ヘッドホン向けbinaural stereoを生成する。

ユーザーは再生中に、

- 部屋の幅・奥行き・高さ
- スピーカー角度・距離
- リスナー位置
- 壁・床・天井の材質
- 残響時間
- early reflectionの密度
- 頭部・耳介モデル

を操作できる。

部屋寸法をスライダーで動かすと、音を止めたりIRを再生成したりせず、その場で反射時間と残響場が変化する。

さらに現在の状態から4ch True Stereo BRIRをexportできる。

---

## 2. Effectとしての位置付け

名称:

**Virtual Room**

DSP type:

```text
VirtualRoomPlugin
```

category:

```text
spatial
```

説明:

```text
Binaural virtual loudspeakers and room simulation with realtime geometry
```

これはEffectDeck独自のnative effectとする。

EffeTuneのIR Reverb、FDN Reverb等を内部で組み合わせて実現するのではなく、EffectDeck側に独立したC++ kernelを持つ。

既存EffeTune DSP engine、pipeline、parameter ABI、routingはそのまま利用する。

---

## 3. アプリ上の置き場所

新しいトップレベル画面は作らない。

現在のEffectDeckの導線をそのまま使う。

```text
EffectDeck
   ↓
Pipeline
   ↓
Add Effect (+)
   ↓
Effects
   ↓
Spatial
   ↓
Virtual Room
```

リリース直後の1バージョンだけ、

```text
Effects
 ├ New
 │   └ Virtual Room
 │
 └ Spatial
     └ Virtual Room
```

の両方に表示する。

これは現在の `EffectPickerView.newTypes` に

```text
VirtualRoomPlugin
```

を追加することで実現する。

次のリリースではNewから外し、Spatialだけに残す。

検索では、

```text
virtual
room
binaural
speaker
spatial
```

などでヒットする。

Pluginsタブには置かない。

これはAUv3/JSFXではなくEffectDeck内蔵effectだからである。

---

## 4. Pipeline上の表示

追加すると通常のEffectDeckカードとして配置される。

```text
┌─────────────────────────────────┐
│ ●  Virtual Room             ⋯  │
│    Spatial                      │
├─────────────────────────────────┤
│                                 │
│       top-down room view        │
│                                 │
├─────────────────────────────────┤
│ Room                            │
│ Width       4.2 m ─────●────    │
│ Depth       3.6 m ───●──────    │
│ Height      2.6 m ──●───────    │
│                                 │
│ Speakers                        │
│ Angle        30° ───●────────   │
│ Distance    1.8 m ───●───────   │
│                                 │
│ Acoustics                       │
│ Room Amount 100% ─────●─────    │
│ Decay       1.00× ────●─────    │
│                                 │
│ ▸ Advanced                      │
│                                 │
│ [ Export 4-channel BRIR… ]      │
└─────────────────────────────────┘
```

カード頭のON/OFF、Routing、Effect Presets、Reset Parameters、移動、削除は既存の `EffectCardView` をそのまま使う。

Virtual Room専用の独自カードシェルは作らない。

---

## 5. 畳んだ状態

Virtual Roomは「図を持つeffect」とする。

したがって、

```swift
ETEffectViews.hasGraph("VirtualRoomPlugin") == true
```

とする。

`withoutGraph` には入れない。

通常のcollapsed状態では現在のEffectDeckの仕組みに従って、132 pt以内のtop-down room viewだけを表示する。

```text
┌───────────────────────────────┐
│ ● Virtual Room             ⋯ │
│   Spatial                     │
│                               │
│     L ●             ● R       │
│        ╲           ╱          │
│           🙂                  │
│                               │
└───────────────────────────────┘
```

完全に畳んだ状態では図も消す。

その場合 `EffectCardView.summary` が最初の数パラメータを表示するため、**パラメータABIの先頭は Width / Depth / Height とする。**

例えば変更後は、

```text
Virtual Room
Width 7.0 m · Depth 5.0 m
```

のように既存カードだけで意味が分かる。

---

## 6. Room View

`VirtualRoomView.swift` を専用Viewとして追加する。

```text
ETEffectViews
   case "VirtualRoomPlugin":
       VirtualRoomView(...)
```

Viewは環境値

```text
etGraphOnly
```

を見る。

### graphOnly = true

top-down visualizationだけ表示する。

操作不能。

### graphOnly = false

visualization + 全操作UIを表示する。

---

## 7. Top-down visualization

部屋を真上から表示する。

表示対象:

```text
Room boundary
Left virtual speaker
Right virtual speaker
Listener / head
Speaker → listener direction
First-order reflection positions/rays
```

例:

```text
┌──────────────────────────────┐
│                              │
│      L ●            ● R      │
│        ╲            ╱        │
│         ╲          ╱         │
│          ╲        ╱          │
│             🙂               │
│                              │
└──────────────────────────────┘
```

寸法変更は即座に図へ反映する。

Expanded時のみ、

- listenerをドラッグ → Listener X/Y変更
- speakerをドラッグ → Speaker Angle/Distance変更

を許す。

片方のspeakerを動かすと反対側も左右対称に動く。

Virtual Roomは通常のステレオスピーカー配置をモデル化するためである。

部屋の壁自体はドラッグしない。

Width / Depth / Heightは下のsliderで操作する。

---

## 8. 基本UI

### Room

常時表示する。

```text
Width
Depth
Height
```

範囲:

| Parameter | Range | Default |
|---|---:|---:|
| Width | 2–20 m | 4.2 m |
| Depth | 2–30 m | 3.6 m |
| Height | 2–10 m | 2.6 m |

sliderをドラッグしている最中もDSPへ連続送信する。

指を離すまで待たない。

---

## 9. Speakers

常時表示:

```text
Angle
Distance
```

Angleは左右対称なので、

```text
30°
```

は、

```text
Left  = -30°
Right = +30°
```

を意味する。

範囲:

| Parameter | Range | Default |
|---|---:|---:|
| Angle | 5–90° | 30° |
| Distance | 0.5–6 m | 1.8 m |

Speaker ElevationはAdvancedへ入れる。

---

## 10. Acoustics

常時表示:

### Room Amount

```text
0–200%
```

0%:

```text
Direct binaural virtual speakers only
```

100%:

```text
physical reflection level
```

200%:

```text
reflections emphasized
```

Direct pathには掛けない。

したがって0%でもeffect全体がdry stereoへ戻るわけではなく、

**無響室内の仮想スピーカー**

になる。

これは通常のWet/Dryとは異なる。

Virtual RoomにはWet/Dry controlを置かない。

BRIRのdirect pathにさらにdry signalを足すのは物理的に別の経路を追加するためである。

### Decay

```text
0.25× – 4.00×
```

材質と部屋寸法から求めた物理的RT60へ倍率を掛ける。

1.00×が物理モデル。

Creative用途では4×まで伸ばせる。

---

## 11. Advanced

Disclosure Groupとしてカード内に置く。

```text
▸ Advanced
```

開くと以下を表示する。

### Listener

```text
Horizontal Position
Depth Position
Ear Height
```

X/Yは部屋寸法に対する割合として保存する。

これによりroom size変更時にlistenerが突然壁の外へ出ない。

Default:

```text
X = 50%
Y ≈ 36%
Z = 1.2 m
```

### Speakers

追加項目:

```text
Elevation
```

Range:

```text
-30° … +30°
```

### Surfaces

```text
Side Walls
Front Wall
Rear Wall
Floor
Ceiling
```

各行はMenu。

built-in material:

```text
Concrete
Painted Wall
Drywall
Wood
Glass
Heavy Curtain
Carpet
Acoustic Panel
```

外部ファイルは使用しない。

各materialは内部に低・中・高域の吸音率を持つ。

### Binaural

```text
Head Size
Pinna
Head Shadow
```

Head Size:

```text
7.0–11.0 cm radius
default 8.75 cm
```

Pinna:

```text
0–150%
default 100%
```

Head Shadow:

```text
0–150%
default 100%
```

0%にすれば各要素を無効化して比較できる。

### Rendering

```text
Early Reflections
[ First Order | Second Order ]
```

Default:

```text
Second Order
```

最大Second Orderとする。

Third Order以降はlate reverberationへ任せる。

mobileの常時DSPとして経路数を無制限に増やさない。

### Randomization

```text
Diffusion Seed   A39F7C21
[ Randomize ]
```

Seedはlate fieldの、

- delay distribution
- input/output mixing
- decorrelation

だけを変える。

room geometryは変えない。

同じseedなら完全に同じroomを再生成できる。

### Output

```text
Output Gain
-24 … +12 dB
```

Default:

```text
0 dB
```

内部ではhard clippingしない。

EffectDeck pipelineのfloat headroomを維持する。

---

## 12. Parameter ABI

すべて音に必要な状態を通常のEffeTune float parameterとして持つ。

別のIR asset、Swift Store、Documentsファイル等に音響状態を逃がさない。

順序を固定する。

| Offset | Key | Parameter |
|---:|---|---|
| 0 | `rw` | Room Width |
| 1 | `rd` | Room Depth |
| 2 | `rh` | Room Height |
| 3 | `lx` | Listener X % |
| 4 | `ly` | Listener Y % |
| 5 | `lz` | Listener Height |
| 6 | `sa` | Speaker Angle |
| 7 | `sd` | Speaker Distance |
| 8 | `se` | Speaker Elevation |
| 9 | `rm` | Room Amount |
| 10 | `ds` | Decay Scale |
| 11 | `sm` | Side Material |
| 12 | `fm` | Front Material |
| 13 | `bm` | Rear Material |
| 14 | `fl` | Floor Material |
| 15 | `ce` | Ceiling Material |
| 16 | `eo` | Early Reflection Order |
| 17 | `hr` | Head Radius |
| 18 | `pa` | Pinna Amount |
| 19 | `hs` | Head Shadow Amount |
| 20 | `og` | Output Gain |
| 21 | `mv` | Model Version |
| 22 | `s0` | Seed low 16 bit |
| 23 | `s1` | Seed high 16 bit |

`floatCount = 24`。

SeedをFloat一個でUInt32として保存しない。

Float32では32bit整数を完全には表現できないため、

```text
low16
high16
```

に分割する。

---

## 13. modelVersion

`mv` はUIには出さない。

Preset / backup / EffectDeck share linkには必ず保存する。

初期:

```text
modelVersion = 1
```

将来DSPアルゴリズムを変更しても、既存presetが無断で別の音にならないようにする。

将来のkernelは、

```text
mv == 1
mv == 2
...
```

を見て互換動作または明示的migrationを行う。

---

## 14. DSP全体構造

```text
                 Stereo Input
                 L          R
                 │          │
                 ▼          ▼
          Source History Rings
                 │
        ┌────────┴────────┐
        │                 │
        ▼                 ▼
 Direct + Early        Late Field
 Image Sources            FDN
        │                 │
        │                 │
 fractional delay      diffusion
 material filters      damping
 HRTF                  RT60
 pinna                  decorrelation
        │                 │
        └────────┬────────┘
                 ▼
          Binaural L / R
                 │
                 ▼
            Output Gain
                 │
                 ▼
             Stereo Out
```

---

## 15. Direct path

入力L/Rを、

```text
L input = Left virtual speaker
R input = Right virtual speaker
```

として扱う。

各virtual speakerから左右の耳への4経路を計算する。

\[
L\rightarrow L_e
\]

\[
L\rightarrow R_e
\]

\[
R\rightarrow L_e
\]

\[
R\rightarrow R_e
\]

距離:

\[
r=\sqrt{dx^2+dy^2+dz^2}
\]

伝播時間:

\[
t=\frac{r}{c}
\]

sample delay:

\[
D=t f_s
\]

整数へ丸めない。

4-point fractional-delay interpolationを使用する。

これによってITDをsub-sample精度で表現する。

---

## 16. Direct level normalization

単純な \(1/r\) だけにするとSpeaker Distance sliderを動かすたびに全体音量まで大きく変化して操作しにくい。

そこで、各virtual speakerについて左右耳のdirect energyを基準化する。

左右間のILDは保持する。

同じnormalizationをそのspeaker由来のreflectionsにも適用する。

これによって、

```text
Speaker Distance
```

は主として、

- ITD
- HRTF
- reflection timing
- direct/reverberant relationship

を変え、単純なmaster volume knobにはならない。

---

## 17. HRTF

外部SOFA等は使用しない。

built-in structural HRTFとする。

理由:

- asset不要
- share linkだけで完全再現可能
- realtime parameterization可能
- licensingが単純
- room geometryとの統合が容易

構成:

```text
Geometric ITD
+
Brown & Duda style head-shadow shelf
+
Structural pinna reflection bank
```

Head Shadowはsource directionごとに変化するfirst-order filter。

Pinnaは複数の短いfractional-delay reflection tapとして処理する。

元のSynthetic Binaural Roomの思想を残すが、integer sample tapにはしない。

---

## 18. Early Reflections

shoebox roomのimage-source methodを使用する。

Default:

```text
Direct + 1st + 2nd order
```

2nd orderまでのimage source数は有限で固定可能なので、最大数をcompile-timeで確保する。

room sizeを変更してもallocationしない。

各pathは、

```text
source history
     ↓
fractional delay
     ↓
distance attenuation
     ↓
material response
     ↓
directional HRTF
     ↓
ear
```

として処理する。

---

## 19. Surface response

materialは単一gainではなく、

```text
Low
Mid
High
```

の吸音率

\[
\alpha_L,\alpha_M,\alpha_H
\]

を持つ。

反射振幅はおおむね、

\[
\rho(f)=\sqrt{1-\alpha(f)}
\]

から求める。

複数壁を通る2nd order pathでは各surface responseを乗算する。

実装上は各pathについて最終的な周波数応答を2つのshelving filter程度へ縮約する。

100本近いreflection pathに多数のbiquadを直列接続しない。

---

## 20. Late Reverberation

late fieldには **16-line FDN** を使用する。

```text
Stereo input
     ↓
input diffusion matrix
     ↓
16 delay lines
     ↓
frequency-dependent feedback gains
     ↓
orthogonal Hadamard mixing
     ↓
binaural output matrix
     ↓
Stereo output
```

feedback matrixはenergy-preservingなnormalized Hadamardを基本とする。

乱数は毎sample生成しない。

seedによって**固定されたroom構造**を作る。

したがってparameterが静止している間はシステムはLTIである。

これはBRIR exportに重要である。

---

## 21. Physical RT60

room geometryとmaterialからRT60を求める。

Room volume:

\[
V=W D H
\]

Total surface area:

\[
S=2(WD+WH+DH)
\]

各frequency bandについて面積加重平均吸音率

\[
\bar{\alpha}(f)
=
\frac{\sum_iS_i\alpha_i(f)}
     {\sum_iS_i}
\]

を求める。

Eyring式:

\[
RT60(f)
=
\frac{0.161V}
{-S\ln(1-\bar{\alpha}(f))}
\]

を基本とする。

最終値:

\[
RT60'(f)
=
RT60(f)\times\text{DecayScale}
\]

とする。

これによりRoom Size sliderを変更すると、

**early reflectionだけでなくlate decayも自然に連動する。**

---

## 22. FDN feedback gain

各delay lineのdelay時間を \(T_i\) とすると、各帯域のfeedback gainは、

\[
g_i(f)
=
10^{-3T_i/RT60(f)}
\]

を基準とする。

したがって、

```text
room dimensions
materials
decay scale
```

からlate fieldの減衰が一貫して導出される。

---

## 23. Mixing time

late fieldを時刻0から鳴らさない。

平均自由行程:

\[
\ell=\frac{4V}{S}
\]

平均反射間隔:

\[
t_r=\frac{\ell}{c}
\]

から、

\[
t_\mathrm{mix}\approx6t_r
\]

程度を初期値とし、

```text
15 ms … 100 ms
```

程度にclampする。

```text
Direct
 │
 ●

Early
   ●   ●  ● ●

Late
             ░▒▓████████████
             ↑
          mixing time
```

とする。

元Synthetic BRIRの固定6 ms onsetは使用しない。

---

## 24. Binaural late field

late reverberationは左右完全独立noiseにはしない。

16-line FDNから異なるorthogonal output vectorを使って左右耳へ出す。

低域ではある程度相関を残し、高域ではdecorrelationを強くする。

これにより、

```text
low frequency:
room pressure fieldとして比較的coherent

high frequency:
diffuse / spacious
```

というbinaural late fieldを作る。

---

## 25. 高sample rate

DirectとEarlyはengine sample rateで処理する。

ITD・pinna cueを保持するためである。

Late FDNは必要に応じて内部rateを下げる。

例えば、

```text
44.1 / 48 kHz → full rate
88.2 / 96 kHz → half rate
176.4 / 192 kHz → quarter rate
```

とする。

EffeTuneの既存 `Halfband2x` の考え方を流用できる。

late fieldで192 kHzまで演算する意味は小さい。

---

## 26. Real-time parameter update

ここではIRを再生成しない。

`AssetUpload`も使用しない。

slider:

```text
SwiftUI
 ↓
EffeTuneDSP.setValue()
 ↓
et_instance_set_params()
 ↓
VirtualRoomKernel::stageParameters()
```

となる。

重要なのは、EffeTuneの現在のABIでは `stageParameters()` が `et_instance_set_params()` を呼んだcontrol thread上で実行される点である。

したがって、

```text
room geometry calculation
image-source positions
delay targets
material filter coefficients
FDN target parameters
```

は **stageParametersで計算する。**

audio callbackでは計算しない。

---

## 27. RenderState

`stageParameters()` は完成済みの

```cpp
RenderState
```

を作る。

概念:

```text
RenderState
 ├ direct/early path count
 ├ path delays
 ├ path gains
 ├ HRTF coefficients
 ├ material filter coefficients
 ├ FDN delay targets
 ├ FDN decay coefficients
 ├ mixing time
 ├ output gain
 └ seed-derived matrices
```

Audio threadはRenderStateだけを見る。

---

## 28. Control→Audio thread

mutexをaudio threadで使用しない。

RenderStateはtriple bufferとする。

```text
slot A
slot B
slot C
```

Control threadは、

```text
activeでもpendingでもないslot
```

へ次のstateを完成させてからatomic publishする。

Audio threadはblock境界でpublished slotを取得してactiveへ切り替える。

これにより、

- allocationなし
- lockなし
- partial stateをaudio threadが読むことなし
- sliderが高速に動いてもlatest stateへ追従

を保証する。

---

## 29. Delay変更時のclick防止

delay targetを瞬間的に変更しない。

Early pathは、

```text
old tap ───┐
           ├→ equal-power crossfade
new tap ───┘
```

として約20 msで移行する。

したがってRoom Widthを、

```text
4 m → 10 m
```

へ動かしてもdelay lineのread headを直接滑らせない。

直接滑らせるとDoppler/pitch bendになるためである。

Default Virtual Roomでは、

**壁が実際に移動している音ではなく、旧roomから新roomへの滑らかな遷移**

を採用する。

---

## 30. FDN delay変更

FDNについてもdelay lengthを突然変更しない。

各delay lineに、

```text
old delay tap
new delay tap
```

を持ち、feedback outputをcrossfadeする。

新しいslider updateがcrossfade中に来た場合、

- queueを積まない
- 最新targetだけ保持
- 現在のtransition終了後に最新値へ移行

とする。

最大数十ms程度late fieldだけがgeometry操作に遅れても問題ない。

Direct / Earlyは即追従する。

---

## 31. Material / Decay変更

feedback gainやfilter coefficientはdelay変更と違い連続補間できる。

約30–50 msでparameter smoothingする。

FDNをresetしない。

したがってDecay sliderを操作しても残響tailが突然切れない。

---

## 32. Seed変更

Seed変更だけはroom topologyそのものが変わる。

そのためlate fieldのみ、

```text
30 ms fade out
↓
FDN reset / seed apply
↓
30 ms fade in
```

とする。

DirectとEarlyは途切れない。

---

## 33. Memory

`prepare()` で最大量を確保する。

audio threadでは、

```text
malloc
new
vector resize
Swift allocation
lock
```

を一切行わない。

Direct/Early用にはL/R入力それぞれ1本のsource history ringを持つ。

reflection pathごとに長大なdelay bufferは持たない。

すべてのreflectionは同じsource historyから異なるdelay tapを読む。

これは非常に重要である。

---

## 34. Stereo requirement

Virtual Roomは本質的に、

```text
2 input virtual speakers
→
2 ears
```

なので2ch専用とする。

対応routing:

```text
Stereo
1+2
3+4
5+6
...
```

非対応:

```text
Left only
Right only
All（3ch以上）
```

Routing UIではVirtualRoomPluginについて非対応choiceをdisabledにする。

古いpreset等から不正なroutingが入った場合はkernel側でpassthroughする。

カードには、

```text
Virtual Room requires a stereo channel pair.
```

を表示する。

silent failureにはしない。

---

## 35. Latency

Virtual Roomの、

- speaker propagation delay
- room reflections
- reverberation delay

はeffectの音響モデルそのものである。

pipeline compensation対象のalgorithmic latencyではない。

したがって、

```cpp
latencySamples() = 0
```

とする。

---

## 36. Batch parameter update

Room presetやroom mapのdragでは複数parameterを同時に変更する。

現在の `setValue()` を何度も呼ぶと、

```text
Speaker Angle変更
↓
一度room生成
↓
Speaker Distance変更
↓
もう一度room生成
```

となる。

そこで `EffeTuneDSP` に、

```swift
setValues(...)
```

というbatch更新口を追加する。

Node.valuesを全部変更した後、

```text
et_instance_set_params
```

を1回だけ呼ぶ。

単一 `setValue()` も内部では同じ口へ寄せる。

これにより、

- speaker drag
- listener drag
- effect preset
- reset
- material preset

で中間の壊れたgeometryを生成しない。

---

## 37. 保存

Virtual Roomはassetを持たない。

したがって、

```text
irId
AssetUpload
IRLibrary
VirtualRoomStore
```

は不要。

すべて `Node.values` に収まる。

既存の、

```text
PipelineStore
UserDefaults
iCloud mirror
Backup
User Preset
```

でそのまま保存する。

Engineが作り直された場合も、現在のNode.valuesを `et_instance_set_params()` へ渡すだけで完全にroomが復元される。

Asset reattach処理は不要。

---

## 38. EffectDeck share link

EffectDeck linkではVirtual Roomを完全に共有できる。

例:

```json
{
  "nm": "Virtual Room",
  "rw": 4.2,
  "rd": 3.6,
  "rh": 2.6,
  "sa": 30,
  "sd": 1.8,
  "rm": 100,
  "ds": 100,
  "mv": 1,
  "s0": 31777,
  "s1": 41855
}
```

IR waveformは含まれない。

受信側が同じparameterから同じroomを生成する。

これがIR Reverbに対する最大の利点の一つである。

---

## 39. EffectDeck独自effect識別

今後EffectDeck独自effectが増えることも考え、保存形式に任意のtype markerを追加する。

例:

```json
"ed": "VirtualRoomPlugin"
```

EffectDeck linkでは、

```text
ed
```

があればtypeを優先して解決する。

無ければ従来どおりnameから解決する。

これにより将来EffeTune側に偶然同名の「Virtual Room」が追加されても衝突しない。

---

## 40. EffeTune互換share link

公式EffeTuneはVirtualRoomPluginを知らない。

したがって、

```text
Share → EffeTune-compatible link
```

ではVirtual Roomを送らない。

現在AU/JSFXで行っているprojectionと同じ扱いにする。

同じbus内:

```text
Virtual Room
↓
remove
```

busを跨いでいる場合:

```text
Virtual Room
↓
0 dB Volume passthrough
```

へ置換し、graph topologyだけ保持する。

EffectDeck linkではもちろん削除しない。

---

## 41. Effect Presets

既存の、

```text
⋯
→ Effect Presets
```

をそのまま使用する。

カード内に別のPreset pickerは置かない。

Factory presetsとして最低限、

```text
Nearfield Studio
Living Room
Dry Room
Large Room
Anechoic Speakers
```

を用意する。

Anechoic Speakersは、

```text
Room Amount = 0%
```

で、structural binaural virtual speakerのみを聴けるpresetとする。

PresetはIRではなくparametersを保存する。

---

## 42. BRIR Export

Expanded Virtual Roomカード最下部に、

```text
Export 4-channel BRIR…
```

を置く。

IR Libraryには自動登録しない。

押したときだけ現在のVirtual RoomからBRIRを生成する。

Static parameter状態ではVirtual RoomはLTIなので、同じrendererへimpulseを入れれば正確なBRIRを得られる。

---

## 43. BRIR channel order

出力順はEffeTune IR Reverbと同じに固定する。

```text
Channel 0 = LL = Left speaker  → Left ear
Channel 1 = LR = Left speaker  → Right ear
Channel 2 = RL = Right speaker → Left ear
Channel 3 = RR = Right speaker → Right ear
```

これ以外の順序は使用しない。

---

## 44. BRIR生成

同じ `VirtualRoomEngine` をofflineでも使用する。

Left input:

```text
L = impulse
R = zero
```

を処理して、

```text
Output L = LL
Output R = LR
```

を得る。

reset後、

```text
L = zero
R = impulse
```

を処理して、

```text
Output L = RL
Output R = RR
```

を得る。

Realtime rendererと別のBRIRアルゴリズムを実装してはいけない。

**Realtimeで聴くroomとexportされたBRIRを必ず同じエンジンから作る。**

---

## 45. BRIR length

最大RT60を使って、

\[
T_\mathrm{IR}
=
t_\mathrm{mix}
+
\frac{80}{60}
\max(RT60_L,RT60_M,RT60_H)
+
margin
\]

程度までrenderする。

末尾は-80 dB程度まで落ちたことを確認してtrimする。

最大10秒程度に制限する。

出力:

```text
4ch
Float32
WAV
current processing sample rate
```

とする。

---

## 46. C++構造

> **この節の置き場は §61 で差し替えた。**

```text
Sources/EffeTuneLive/DSP/VirtualRoom/

    VirtualRoomKernel.cpp
    VirtualRoomEngine.cpp
    VirtualRoomEngine.h
    VirtualRoomModel.h
    VirtualRoomPluginParams.h
    VirtualRoomExport.cpp
    VirtualRoomExport.h
```

役割:

```text
VirtualRoomKernel
    EffeTune PluginKernel adapter

VirtualRoomEngine
    actual DSP

VirtualRoomModel
    geometry / material / path generation

VirtualRoomExport
    offline BRIR rendering
```

`VirtualRoomEngine` はRealtimeとExportで共有する。

---

## 47. Swift構造

```text
Sources/EffeTuneLive/Views/Effects/
    VirtualRoomView.swift

Sources/EffeTuneLive/Views/Graphs/
    VirtualRoomSceneView.swift
```

必要ならmaterial表示等の純粋モデルだけ、

```text
Sources/EffeTuneLive/DSP/VirtualRoom/
    VirtualRoomUIModel.swift
```

へ置く。

音響状態を持つStore/Designer objectは作らない。

音の正は常にNode.values + C++ kernelである。

---

## 48. EffeTune kernel registryへの統合

現在のEffeTune registryは `registry.inc` の静的列挙である。

したがってC++ファイルを追加するだけでは、

```text
et_kernel_count
et_instance_create
```

からVirtualRoomPluginが見えない。

VendorディレクトリへEffectDeck本体コードを直接追加しない。

既存のvendor patch運用と同じように、薄いpatchで、

```cpp
et_kernel_descriptor_VirtualRoomPlugin
```

をregistryへ追加する。

`project.yml` ではEffectDeck build時のみ、

```text
ET_EFFECTDECK_EXTENSIONS
```

を有効にする。

上流EffeTuneのregistry変更との差分を最小化する。

---

## 49. Catalog

現在の `EffectCatalog.swift` は `Tools/gen_catalog.py` の生成物なので手で編集しない。

`gen_catalog.py` を拡張し、

```text
Vendor EffeTune effects
+
EffectDeck local effects
```

から一つの

```swift
ETCatalog
```

を生成する。

これにより現在 `ETCatalog` を直接使用している、

- Pipeline restore
- PresetStore
- Share link
- Backup
- Clipboard import
- EffectPicker
- Screenshot seed
- Unit tests

を全部そのまま動かせる。

各利用箇所へVirtual Roomだけのspecial caseを追加しない。

---

## 50. Local effect manifest

> **`effect.json` は §61 で撤回した。正本は上流と同じ `params.json`。**

Virtual RoomにはEffectDeck側のmanifestを置く。

```text
Sources/EffeTuneLive/DSP/VirtualRoom/effect.json
```

ここを、

- type
- name
- category
- about
- parameter names
- keys
- ranges
- defaults
- enum values

のsingle source of truthとする。

generatorから、

```text
Swift ETEffect entry
C++ VirtualRoomPluginParams.h
```

を生成する。

SwiftとC++で手作業でoffset/hashを二重管理しない。

---

## 51. UI wiring

`EffectViews.swift`:

```text
types
    + VirtualRoomPlugin
```

`withoutGraph`:

```text
追加しない
```

`view(...)`:

```text
case VirtualRoomPlugin
    → VirtualRoomView
```

`EffectPickerView.newTypes`:

```text
VirtualRoomPlugin
```

を初回リリースのみ追加する。

categoryは`spatial`なので既存のSpatial sectionへ自動的に入る。

---

## 52. Routing wiring

generic Routing UIへeffect capabilityを一つ追加する。

概念:

```text
ETRoutingConstraint
```

VirtualRoomPlugin:

```text
channel width = exactly 2
allowed:
  Stereo
  stereo pairs
```

generic Routing sheet側がこのconstraintを見る。

DSP側でも必ずvalidationする。

UIだけを信用しない。

---

## 53. Room geometry validation

parameter自体はshare可能な値として保持する。

ただしroom変更によってvirtual speakerが壁の外へ出る場合がある。

Kernelは、

```text
listener position
speaker angle
speaker elevation
room bounds
```

から有効な最大speaker distanceを計算する。

requested distanceがそれを超えた場合、

```text
effective distance = valid maximum
```

とする。

保存値そのものは書き換えない。

後からroomを広げれば、元のspeaker distanceが自動的に復活する。

Listenerも壁から最低限のmarginを確保してeffective positionをclampする。

---

## 54. Default configuration

Default:

```text
Room
4.2 × 3.6 × 2.6 m

Listener
X = 50%
Y ≈ 36%
Z = 1.2 m

Speakers
±30°
1.8 m
0° elevation

Room Amount
100%

Decay
1.0×

Early
Second Order

Head radius
8.75 cm

Pinna
100%

Head Shadow
100%

Output
0 dB
```

これは元Synthetic Binaural Roomの配置を基礎にするが、残響モデル自体は新しいphysical/FDN modelを使用する。

---

## 55. 明示的に実装しないもの

現時点のVirtual Roomには以下を入れない。

```text
Head tracking
SOFA import
Personal HRTF file
arbitrary polygon room
moving objects
nonlinear loudspeaker model
microphone model
```

特にhead trackingはEffectDeckの主用途である任意のワイヤレスイヤホンでは姿勢取得を保証できないため、通常機能には含めない。

ただし内部geometryはlistener orientationを将来追加できる座標系で設計する。

---

## 56. テスト要件

### DSP

- static parameterではLTIであること
- 同じseed/paramsでbit-stableな構造になること
- block sizeによって結果が変わらないこと
- LL/RR、LR/RLの左右対称性
- fractional delayの精度
- image-source arrival time
- material reflection response
- Eyring RT60 calculation
- FDN decay time
- NaN/Infを生成しないこと
- parameter transitionでclickを発生させないこと
- process中allocationゼロ
- process中mutexゼロ

### Realtime

Room Widthを連続操作しながら再生し、

```text
2 m → 20 m → 2 m
```

を繰り返しても、

- dropoutなし
- DSP bypassなし
- heap allocationなし
- stale stateなし
- crashなし

であること。

### App

- Add Effect → New → Virtual Room
- Add Effect → Spatial → Virtual Room
- Searchから追加
- collapsed graph
- fully collapsed summary
- slider continuous update
- listener drag
- speaker drag
- reset parameters
- effect preset
- chain preset
- app restart
- iCloud restore
- backup/restore
- EffectDeck share roundtrip
- EffeTune-compatible shareからの除外
- routing pair変更
- invalid mono routing refusal
- BRIR export

をテストする。

---

## 57. Performance条件

主用途は48 kHz / stereo / ワイヤレス出力なので、ここを第一基準とする。

Default:

```text
48 kHz
2ch
Second-order early
16-line FDN
```

で常時動作させる。

Realtime callbackについて、

```text
p99 processing time
<
audio block durationの25%
```

を目標とする。

Second-orderが古い対応端末でこのbudgetを超える場合だけ、DefaultをFirst-orderへ落とす。

設計段階から品質を落としてはいけない。

まず実測で決める。

---

## 58. 最終データフロー

```text
                    EffectPicker
                        │
                        ▼
                 Virtual Room card
                        │
                 user parameters
                        │
                        ▼
              EffeTuneDSP.setValues
                        │
                        ▼
             et_instance_set_params
                        │
              CONTROL THREAD
                        │
                        ▼
        VirtualRoomKernel::stageParameters
                        │
              geometry / acoustics
                        │
                 RenderState
                        │
               atomic publication
                        │
                        ▼
                 AUDIO THREAD
                        │
         ┌──────────────┴──────────────┐
         ▼                             ▼
 Direct + Early                     16 FDN
         │                             │
 ITD / HRTF                     late diffuse field
         │                             │
         └──────────────┬──────────────┘
                        ▼
                    Binaural
                       L/R
                        │
                        ▼
                EffectDeck pipeline
```

BRIR Export時だけ分岐する。

```text
same parameters
      │
      ▼
VirtualRoomEngine
      │
   impulse
      │
      ▼
LL / LR / RL / RR
      │
      ▼
4ch Float32 WAV
```

---

## 59. 設計上の最重要原則

Virtual Roomでは、

**「IRをリアルタイムに作り直す」のではなく、「IRを生み出すroomそのものをリアルタイムDSPとして動かす」。**

IRはexport結果にすぎない。

また、

**音響状態はすべてparameterとして保存し、external assetを必要としない。**

これによってEffectDeck share linkだけで、

```text
room geometry
speaker placement
materials
binaural model
late field
seed
```

まで完全再現できる。

これをVirtual Roomの基本アーキテクチャとする。

---

## 60. ライセンス・由来・帰属

### 60.1 EffectDeck本体

EffectDeck本体はMIT Licenseで配布する。

Virtual RoomのEffectDeck独自実装部分も、原則としてEffectDeck本体と同じMIT Licenseとする。

### 60.2 Synthetic Binaural Room由来コード

Virtual Roomの初期音響モデルは、

```text
M0Rf30/easyeffects-presets
scripts/generate-synthetic-binaural-room.js
```

を技術的な出発点とする。

同repositoryはMIT Licenseで公開されている。

したがって、当該JavaScriptのコードをC++/Swiftへ直接移植、トランスパイル、または実質的に同じコード構造で翻案する部分は、MIT Licenseに基づく派生コードとして扱う。

MIT Licenseは改変・再配布・商用利用を許可するが、Softwareのcopyまたはsubstantial portionを配布する場合、元のcopyright noticeとlicense noticeを保持する必要がある。

元repositoryのLICENSEには、現時点で以下のcopyright noticeが置かれている。

```text
Copyright (c) 2018 Matteo Iervasi
```

したがって、Virtual Roomに元JS由来の実装を含める場合、EffectDeckの配布物からこのMIT noticeを落とさない。

### 60.3 EffectDeckでの表示・収録

EffectDeckにはすでに第三者ライセンスを

```text
NOTICE.md
Tools/gen_licenses.py
Sources/EffeTuneLive/Generated/Licenses.swift
Settings → Licenses
```

へ集約する仕組みがある。

Virtual Room実装時には `Tools/gen_licenses.py` へ少なくとも以下を追加する。

```text
Synthetic Binaural Room / easyeffects-presets
MIT
M0Rf30/easyeffects-presets
```

license textには、使用時点での `M0Rf30/easyeffects-presets/LICENSE` をそのまま収録する。

`NOTICE.md` にも、Virtual Roomの一部が同repositoryのMIT-licensed implementationを基にしていることを明記する。

アプリ内のSettings → Licensesから当該license全文を確認できる状態にする。

### 60.4 ソースファイル上の帰属

元JSを直接移植したコードが残るファイルには、ファイル冒頭で由来を明示する。

```cpp
// Virtual Room binaural room model.
//
// Portions derived from:
//   M0Rf30/easyeffects-presets
//   scripts/generate-synthetic-binaural-room.js
//
// Licensed under the MIT License.
// See NOTICE.md and the bundled third-party license notices.
```

配布物にlicense noticeを確実に保持し、ソースファイルからその所在を追えるようにする。

### 60.5 新規実装部分との区別

以下は元JSの単純移植ではなく、EffectDeck側で新規設計・実装する。

```text
Realtime RenderState architecture
triple-buffered control → audio state transfer
fractional-delay morphing
second-order image-source renderer
frequency-dependent material model
16-line FDN
Eyring-based RT60 calculation
realtime room resizing
BRIR export path
EffectDeck UI / preset / share integration
```

これらについて、M0Rf30側のコードをコピーせずEffectDeckで独自実装した部分はEffectDeck自身のMIT-licensed codeとして扱う。

一方、元JSからコード表現・定数表・処理構造を直接引き継いだ部分については、書き直し後も由来を消さない。

「最終的にコードが大きく変わったから帰属を外す」という運用にはしない。

### 60.6 論文・アルゴリズムの扱い

以下のような一般的な音響/DSP手法そのものについては、特定repositoryのコードをコピーせず、論文・数式・公開仕様を基に独自実装する。

```text
Brown & Duda系 structural HRTF
image-source method
Eyring reverberation equation
feedback delay network
Hadamard feedback matrix
fractional delay interpolation
```

設計書・コードコメントでは、必要に応じて原論文や技術資料を参考文献として示す。

参考文献へのcitationと、ソースコードのcopyright/license attributionは別のものとして管理する。

### 60.7 外部HRTF / IRデータ

初期Virtual Roomは、

```text
SOFA HRTF
measured BRIR
third-party IR
external material dataset
```

を同梱しない。

built-in structural modelだけで生成する。

これにより、Virtual Room本体についてIR/HRTFデータセット固有の `CC BY`、`CC BY-NC`、`CC BY-SA`、研究用途限定、再配布禁止等の追加条件を持ち込まない。

将来外部データを追加する場合は、コードとは別に各データセットのlicenseを個別審査し、App Store配布・商用配布・改変・再配布が許可されるものだけを採用する。

### 60.8 EffeTuneとの関係

Virtual RoomはEffeTuneのDSP engine / PluginKernel ABI上で動作するが、Virtual RoomそのものはEffectDeck独自effectである。

EffeTuneはMIT Licenseであり、EffectDeckは既にそのlicense noticeを配布物へ収録している。

Virtual Room追加後も、

```text
EffectDeck
EffeTune
Synthetic Binaural Room / easyeffects-presets
```

の帰属を混同しない。

アプリ上でも、Virtual RoomをEffeTune公式effectであるかのように表示しない。

### 60.9 ライセンス上の実装原則

Virtual Roomについては、次を必須とする。

1. 元JSを利用するなら、MIT noticeを保持する。
2. 元JS由来コードのprovenanceをソースから追跡可能にする。
3. 新規DSP部分は論文・数式を基に独自実装し、不必要な第三者コードコピーを増やさない。
4. 外部IR/HRTFデータは初期版に同梱しない。
5. `NOTICE.md` とアプリ内Licensesをリリース前テスト対象にする。
6. dependency/license追加時は `Tools/gen_licenses.py` をsingle source of truthとして更新する。

## 61. 上流へ出せる形にする（§46 / §50 の差し替え）

Virtual Room は EffectDeck 独自 effect だが、**いずれ EffeTune へ PR できる形**で作る。
C++ の DSP 本体と ABI は上流とまったく同じ規約にし、EffectDeck 側は Swift の
前面を被せるだけにする。

```text
                    Virtual Room
                         |
            +------------+------------+
            |                         |
       Portable Core             Host-specific
            |                         |
 params.json                    Swift UI
 kernel.cpp                     share projection
 room model / image source      routing 制約
 HRTF / FDN                     出荷時プリセット
            |
            +---------> EffeTune PR（+ JS UI と parity）
```

### 置き場

```text
EffectDeckLocalDSP/spatial/virtual_room/
    params.json            ABI の正本。**上流とまったく同じ形**
    catalog.json           EffectDeck の画面に出る文字だけ
    kernel.cpp
    virtual_room_engine.h / .cpp
    virtual_room_model.h
EffectDeckLocalDSP/effectdeck_registry.inc
Generated/dsp/VirtualRoomPluginParams.h   生成物
```

上流へ出すときは `EffectDeckLocalDSP/spatial/virtual_room/` を
`effetune/dsp/plugins/spatial/virtual_room/` へ写し、`catalog.json` を捨てて
`plugins/spatial/virtual_room.js` を書く。`registry.inc` へ 1 行足す。

### 変えたこと

| | 前（§46 / §50） | いま |
|---|---|---|
| 正本 | `effect.json`（EffectDeck 独自） | `params.json`（上流と同形）|
| 置き場 | `Sources/EffeTuneLive/DSP/VirtualRoom/` | `EffectDeckLocalDSP/<分類>/<名前>/` |
| 名前空間 | `effectdeck::virtualroom` | `effetune::plugins::spatial` |
| 生成ヘッダ | `effectdeck::generated` | `effetune::generated` |
| ファイル名 | `VirtualRoomKernel.cpp` など | `kernel.cpp` / `virtual_room_*.{h,cpp}` |

画面に出る文字を `params.json` に入れない。上流はそれを `.js` の `createUI` が
持っていて、`params.json` は DSP の都合だけを書く決まりになっている。
EffectDeck には `.js` が無いので、その一枚だけ `catalog.json` として隣に置く。

`Range`（`kRoomWidthMin` など）は上流の生成物には無い。こちらの kernel が
clamp と確保に使っている。**上流へ出すときはここだけ kernel の中へ畳む。**

### registry

Vendor の中へ EffectDeck のコードを置かない。`Patches/effetune-local-kernels.diff` が
`ET_EFFECTDECK_EXTENSIONS` を立てたときだけ `effectdeck_registry.inc` を読む口を開ける。
上流との差分は registry.cpp の 13 行だけで、上流へ入ったら丸ごと外せる。

### 残っている上流化の宿題

- `plugins/spatial/virtual_room.js`（UI と JS reference DSP）
- `cases.json` / `golden/` / `native_test.cpp`（上流は JS と C++ の parity を厳密に取る）
- `executionCapabilities`（`supportedChannelModes: ["stereo-pair"]`。§52 の制約がそのまま乗る）

**いちばん重いのは C++ ではなく、同じ結果を出す JavaScript reference を書くこと。**
Swift の `VirtualRoomView` / `VirtualRoomSceneView` は移植できない。書き直しになる。
