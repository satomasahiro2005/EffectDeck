# EffectDeck JSFX Host Test Design

**Status:** Proposed  
**Scope:** `codex/jsfx-host` で追加された JSFX Host 全体  
**Target:** EffectDeck  
**Primary goal:** JSFX Host を「手動で一通り触る」状態から、互換性・安全性・リアルタイム性・ライフサイクルを自動テストで継続的に保証できる状態へ移す。

---

## 1. 背景

現状の EffectDeck には JSFX 向けの実機チェック項目は存在するが、JSFX runtime / host そのものを直接検証する自動テストは十分ではない。

既存の自動テストでは、少なくとも以下は確認されている。

- `Tests/Native/external_processor.c`
  - generic `ETExternalProcessor` の process
  - `maxFrames`
  - clear
  - processor の実行順
- `Tests/Unit`
  - Effect preset
  - parameter coding
  - route escape
  - spectrum smoothing

一方、JSFX 固有の以下は専用テストが必要である。

- EEL2/ysfx runtime
- JSFX source validation
- slider / curve / enum / visibility
- trigger
- `@serialize`
- PDC
- deadline overrun / automatic bypass
- GFX / LICE resource limits
- `gfx_showmenu`
- state snapshot
- async build / remove / ID reuse
- bridge slot
- pipeline routing
- Section gate
- preset duplication
- share link
- suspend / resume
- realtime race

---

## 2. テスト戦略

JSFX のテストは 4 層に分割する。

| Layer | 対象 | 主な実行環境 | 目的 |
|---|---|---|---|
| **L1: JSFX Core** | `ETJSFXHost.cpp` + ysfx | Native / CI | runtime と C API の正当性 |
| **L2: JSFX Swift Host** | `ETJSFXHost.swift` | Simulator / CI | 非同期 lifecycle / storage / state |
| **L3: Pipeline Integration** | `EffeTuneDSP` / `ETPipeline` / external bridge | Native + Simulator / CI | EffectDeck 本体との統合 |
| **L4: Device / Realtime** | AudioIO + UI + 実音声 | 実機 | 実時間制約・OS統合・長時間安定性 |

原則:

> 実機でなくても検証できるものを実機テストへ残さない。

実機テストは、CPU deadline、Audio route、background/foreground、実デバイスの GFX 負荷などに限定する。

---

# 3. テスト用 fixture

既存の `Debug/JSFXFactory` は人間が確認するための総合 fixture として残す。

自動テストでは原因を局所化するため、`Tests/Fixtures/JSFX/` に単機能 fixture を置く。

```text
Tests/Fixtures/JSFX/
├── passthrough.jsfx
├── gain.jsfx
├── generator.jsfx
├── analyzer.jsfx
├── channels.jsfx
├── sliders.jsfx
├── trigger.jsfx
├── state.jsfx
├── pdc.jsfx
├── host_time.jsfx
├── gfx_solid.jsfx
├── gfx_input.jsfx
├── gfx_images.jsfx
├── menu.jsfx
├── slow.jsfx
├── bad_syntax.jsfx
├── forbidden_import.jsfx
├── forbidden_include.jsfx
└── file_slider.jsfx
```

fixture はなるべく 1 つの仕様だけを検証する。

---

# 4. L1 — JSFX Core Tests

当初の推奨配置は `Tests/Native/jsfx_host.cpp` だったが、**実際は Xcode の
`EffeTuneLiveUnitTests`（scheme `Logic`）へ入れた。**

```text
Tests/Unit/JSFXHostSupport.swift   足場（fixture の在り処・host の持ち主）
Tests/Unit/JSFXSourceTests.swift   §4.1 / §22
Tests/Unit/JSFXAudioTests.swift    §5 / §6
Tests/Unit/JSFXSliderTests.swift   §8
Tests/Unit/JSFXTriggerTests.swift  §9
Tests/Unit/JSFXStateTests.swift    §10 / §14
Tests/Unit/JSFXLatencyTests.swift  §11
Tests/Unit/JSFXDeadlineTests.swift §13
Tests/Unit/JSFXRaceTests.swift     §15
Tests/Fixtures/JSFX/               fixture（テストバンドルの resources）
```

`Tests/Native/CMakeLists.txt` は ysfx を知らず、`Vendor/ysfx` は submodule
なので、あちらへ足すとビルド系の持ち主が 2 つになる。代わりに `project.yml` の
`EffeTuneLiveUnitTests` へ `YSFX` 依存と `Sources/Shared/ETJSFXHost.cpp`
（＋ LICE の字を外へ出している `ETLICEFont.mm`）を足し、Swift から
`ETJSFXHost.h` の public C API を直接叩く。`bash Scripts/test.sh` がそのまま回る。

---

## 4.1 Create / source validation

### 正常系

| ID | Case | Expected |
|---|---|---|
| C01 | 最小 valid JSFX | `ETJSFX_Create` 成功 |
| C02 | `desc:` のみ + valid section | 成功 |
| C03 | `@init` のみ | 成功 |
| C04 | `@sample` のみ | 成功 |
| C05 | UTF-8 BOM 付き | 成功 |
| C06 | Latin-1 source | import layer で受理可能 |
| C07 | source size = 1 MiB | 上限内として扱う |

### 異常系

| ID | Case | Expected |
|---|---|---|
| C10 | null path | fail |
| C11 | empty path | fail |
| C12 | missing file | fail |
| C13 | `maxFrames = 0` | fail |
| C14 | source > 1 MiB | fail |
| C15 | syntax error | fail + diagnostic |
| C16 | file slider | fail |
| C17 | `import foo` | fail |
| C18 | `include(foo)` | fail |
| C19 | `filename:` | fail |
| C20 | `data:` | fail |
| C21 | nesting > 256 | fail |
| C22 | inline EEL block > 1024 | fail |
| C23 | string literal > 64 KiB | fail |
| C24 | unterminated string | fail |

### 誤検知防止

以下は security filter の false positive を防ぐため必須。

```text
// include(foo)

#text = "include(foo)";
#text = "import foo";
```

コメントや文字列中の禁止語が、実行構文として誤判定されないこと。

> **要確認:** 現在の `forbiddenSource()` は `include(` を行内検索しているため、
> 文字列中の `include(` が誤検知される可能性がある。テストで現仕様を可視化し、
> 必要なら parser を修正する。

---

# 5. Audio DSP correctness

`ETJSFX_Processor(host).process` を直接呼ぶ。

## 5.1 Basic DSP

```text
A01 passthrough
input == output
```

可能なら bit-exact。

```text
A02 gain
slider = 0.5
output == input * 0.5
```

```text
A03 stereo swap
L/R が完全に交換される
```

```text
A04 mono fold
L/R = (L + R) / 2
```

---

## 5.2 Generator / analyzer

Compatibility 上で明示的にサポートしているため個別テストを持つ。

```text
A05 generator
zero input
→ non-zero output
```

```text
A06 analyzer
任意input
→ outputはbit-exact passthrough
```

---

## 5.3 Channel / frame boundary

```text
A10 channels = 1
A11 channels = 2
A12 channels = 16
A13 channels = 64
```

境界:

```text
frames == maxFrames      → success
frames == maxFrames + 1  → error
channels == maxChannels  → success
channels > maxChannels   → error
frames == 0              → error
channels == 0            → error
planar == NULL           → error
```

---

# 6. Processor descriptor contract

`ETJSFX_Processor()` が返す descriptor 自体を検査する。

```text
context != nil
process != nil
reset != nil
latency != nil
tailTime != nil
maxFrames == Create時の値
maxChannels == ysfx_max_channels
tailTime == infinity
```

`ETJSFX_Reconfigure()` 後:

```text
sample rate 更新
maxFrames 更新
processedFrames reset
processor.maxFrames も新値
```

---

# 7. Host time / reset

`process()` が JSFX へ渡す host time を fixture で観測する。

対象:

```text
srate
samplesblock
play_state
play_position
beat_position
tempo
ts_num
ts_denom
```

例:

```text
rate = 48000
frames = 480

block #0:
  play_position = 0.000

block #1:
  play_position = 0.010
```

期待:

```text
play_state = playing
tempo = 120
time signature = 4/4
beat_position = play_position * 2
```

`descriptor.reset()` 後は `play_position` が 0 へ戻る。

---

# 8. Slider tests

## 8.1 Metadata

`sliders.jsfx` に以下を含める。

```text
linear
log
sqr
log!
sqr!
enum
hidden
non-contiguous slider index
```

確認:

```text
slider count
slider index
name
minimum
maximum
step
shape
visible
enum names
initial value
```

---

## 8.2 Normalized conversion

各 curve について:

```swift
for n in 0.0 ... 1.0 {
    value = FromNormalized(n)
    roundTrip = ToNormalized(value)
    assertAlmostEqual(roundTrip, n)
}
```

最低 101 点程度。

境界:

```text
normalized < 0 → clamp 0
normalized > 1 → clamp 1
```

`log!` / `sqr!` は特に端点と中央を個別確認する。

---

## 8.3 Parameter update

```text
S01 SetSlider
→ GetSlider の cache は即時更新

S02 次の process
→ @slider が実行
→ DSP出力へ反映

S03 min未満
→ Swift host側でmin clamp

S04 max超過
→ max clamp
```

---

## 8.4 sliderchange / slider_automate

JSFX 側から slider value / visibility を変える fixture を用意。

```text
ConsumeSliderChange() == true
2回目 == false
```

visibility の runtime 変更も `readParameters()` に反映されること。

---

# 9. Trigger tests

```text
T01 valid trigger 0...(max-1) → true
T02 out-of-range trigger → false
```

```text
T03 trigger送信
→ 次の1 blockで1回だけ発火
```

同じ trigger を process 前に複数回送る場合:

```text
T04
send trigger 1 × 10
→ bitset semantics により1回
```

複数種類:

```text
T05
trigger 1 + trigger 2
→ 同一blockで両方発火
```

### 非 running 状態

```text
T06 maintenance中
→ sendTrigger == false

T07 automatic bypass中
→ sendTrigger == false
```

再開後に、過去に捨てられた trigger が遅延発火しないこと。

---

# 10. State serialization

対象:

```text
slider
file_var
file_mem
file_string
```

## 10.1 Roundtrip

```text
state変更
↓
SaveState
↓
新規host
↓
LoadState
```

意味が一致すること。

さらに:

```text
Save
→ Load
→ Save
```

を行い、意味上同一であることを確認する。

---

## 10.2 Corrupt state

以下はすべて安全に `false`。

```text
wrong magic
size < 12
size > 16 MiB
slider_count > max
payload size mismatch
truncated slider entry
truncated payload
random bytes
```

失敗後も host が利用可能であること。

---

## 10.3 Serializer string boundary

ysfx patch で追加した `file_string()` を個別にテスト。

```text
0 bytes
1 byte
1 MiB
> 1 MiB
```

破損した length field も検査する。

---

# 11. PDC / latency

`pdc.jsfx` を使用。

```text
P01 pdc=0
→ latency=0
```

```text
P02 0 → 128
process
→ latency=128
→ ConsumeLatencyChange=true
→ 再度Consume=false
```

```text
P03 128 → 2048
→ latency=2048
```

```text
P04 negative
→ 0
```

```text
P05 fractional 127.1
→ ceil = 128
```

---

# 12. Pipeline PDC integration

C API だけで終わらせない。

```text
JSFX latency = 128
↓
pollRuntimeChanges()
↓
EffeTuneDSP.republish()
↓
ETPipeline_Latency()
```

が最終的な native + external latency と一致すること。

runtime で:

```text
128 → 512
```

と変えた場合も pipeline latency が追従すること。

---

# 13. Deadline / automatic bypass

`slow.jsfx` を用意する。

テストは極端に小さな block budget を使い、CIマシン性能に依存しにくくする。

## 13.1 初期 slider block

Create / Load / Reconfigure 直後の `@slider` block は deadline 判定対象外。

```text
D01
初回処理が遅くても
→ deadlineOverrunsには加算しない
```

---

## 13.2 Consecutive overrun

```text
D02
overrun
overrun
overrun
→ automatic bypass
→ IsRunning=false
→ diagnostic != empty
```

```text
D03
overrun
normal
overrun
overrun
→ bypassしない
```

連続性を保証する。

---

## 13.3 Slider interaction regression

```text
overrun
slider-update block
overrun
overrun
```

slider block 自体は deadline 判定から除外するが、
**既存の consecutive overrun count を 0 にしてはいけない**。

---

## 13.4 Re-enable

```text
automatic bypass
↓
ClearDiagnostic
↓
running
```

期待:

```text
diagnostic cleared
consecutive overrun reset
```

Re-enable直後の1回のoverrunだけでは再bypassしない。

---

# 14. Maintenance state correctness

automatic bypass 中に maintenance operation を行っても、
勝手に running へ戻してはいけない。

```text
bypassed
→ SaveState
→ still bypassed
```

```text
bypassed
→ LoadState
→ still bypassed
```

```text
bypassed
→ Reconfigure
→ still bypassed
```

running へ戻す public path は `ClearDiagnostic()` のみ。

---

# 15. Concurrency / race

ここは dedicated stress test を作る。

## 15.1 C++ runtime concurrency

同時実行:

```text
process ↔ SaveState
process ↔ LoadState
process ↔ Reconfigure
process ↔ RunGFX
RunGFX ↔ SaveState
```

期待:

```text
deadlockなし
crashなし
UAFなし
state corruptionなし
```

---

## 15.2 Concurrent process

2スレッドから同一 host に process を同時実行。

期待:

```text
同時にVMを走らせない
片方は安全にearly return
```

---

## 15.3 Stress

Thread Sanitizer が使える Native / Simulator 構成を別途用意する。

可能なら:

```text
1000〜10000 iterations
```

で race を繰り返す。

---

# 16. GFX Core

## 16.1 Basic capabilities

```text
G01 HasGFX
G02 preferred size
G03 requested frame rate
G04 Retina flag
```

no-GFX fixture では `HasGFX=false`。

---

## 16.2 Framebuffer boundary

```text
1 × 1
640 × 360
2048 × 2048
2049 × N → fail
N × 2049 → fail
> 16 MiB framebuffer → fail
```

`CopyGFX`:

```text
capacity exactly enough → success
1 byte short → fail
```

solid-color fixture の中央 pixel を検査し、
pixel format が壊れていないことを確認する。

---

# 17. GFX global framebuffer budget

presentation framebuffer:

```text
16 MiB / instance
64 MiB / process
```

境界を検査する。

例:

```text
4 instances × 16 MiB → success
5th allocation → fail
1 instance destroy
→ 新しいallocationが成功
```

destroy 後に global accounting が戻ることが重要。

---

# 18. LICE offscreen image budget

presentation framebuffer とは別にテストする。

現在の ysfx patch は:

```text
image slots: 0...127
max dimension: 2048 × 2048
offscreen image:
  16 MiB / instance
  64 MiB / process
```

を持つ。

テスト:

```text
LI01 slot 127 → usable
LI02 slot 128 → rejected / unavailable
LI03 per-instance 16 MiB boundary
LI04 process-wide 64 MiB boundary
LI05 destroy後にglobal budget回収
```

---

# 19. GFX input

fixture内部状態を pixel または serialized state へ反映する。

```text
mouse x/y
buttons
wheel
horizontal wheel
key down
key up
focused
visible
mouseOver
```

を検査。

---

# 20. Swift GFX owner aggregation

`ETJSFXHost.updateGFXWindow()` の owner 集約をテスト。

```text
owner A: visible=true
owner B: visible=true
owner A: visible=false
```

この時:

```text
anyVisible == true
```

でなければならない。

同様に focused も確認。

目的:

> fullscreen transition 時に古い presentation の遅い `visible=false` が、
> 新しい presentation まで消す回帰を防ぐ。

---

# 21. gfx_showmenu

## 21.1 Parser

UI 表示処理と menu parsing を可能なら分離し、unit test を置く。

入力例:

```text
Normal|!Checked|#Disabled|>Submenu|First|Second|<
```

確認:

```text
identifier
disabled
checked
submenu nesting
Cancel == 0
```

---

## 21.2 Limits

```text
menu payload <= 64 KiB
menu payload > 64 KiB → 0
```

callback 不在:

```text
→ 0
```

UIAlert の実表示だけ UI test に残す。

---

# 22. Security / unsupported APIs

非対応機能も回帰テスト対象とする。

## 必須

```text
file_open() → filesystemを開けない
gfx_loadimg() → filesystem imageを読めない
import → Create拒否
include() → Create拒否
file slider → Create拒否
external resource header → Create拒否
```

MIDI:

```text
midi send functions
→ crashしない
→ 外部 routing は発生しない
```

以下は「動作を固定しない」。

```text
cross-instance gmem
_global.*
regXX
```

Compatibility 文書上、保証対象外だからである。

---

# 23. EEL RAM limit — 要仕様確定

現在、ドキュメントと実装に不一致がある。

`JSFX.md`:

```text
EEL RAM:
16 MiB per instance
64 MiB process-wide
```

一方、現在の ysfx patch:

```cpp
if (maxmem == 0)
    maxmem = 2 * 1024 * 1024;

if (maxmem > 2 * 1024 * 1024)
    maxmem = 2 * 1024 * 1024;
```

さらに `ETJSFXHost.cpp`:

```cpp
NSEEL_RAM_limitmem = 64 MiB;
```

したがって先に仕様を決める。

テストは確定値に対して:

```text
options:maxmem
options:prealloc
default
exact max
max + 1
negative prealloc
huge prealloc
```

を検査する。

**この不一致を解消するまで RAM limit の release claim を固定しない。**

---

# 24. L2 — Swift Host Tests

現状の singleton 構造のままだとテストしにくいため、テスト可能性のためだけに依存注入可能な initializer を推奨する。

概念:

```swift
ETJSFXHost(
    storageRoot: URL,
    bridge: ExternalProcessorRegistry,
    stateChanged: ...,
    republish: ...
)
```

production の `shared` は通常 dependency を渡す。

---

# 25. Swift lifecycle

| ID | Scenario | Expected |
|---|---|---|
| H01 | audio config 前に prepare | `audioNotReady` |
| H02 | resume → prepare | build → install |
| H03 | compile failure | slot release / instance removal |
| H04 | state restore failure | readyにしない |
| H05 | build中 remove | completionが復活させない |
| H06 | remove後 same ID reuse | stale buildが新instanceを汚さない |
| H07 | suspend → resume | reconfigure / reinstall |
| H08 | remove | slot release |
| H09 | removeAll | 全slot release |
| H10 | host 0個 | latency timer停止 |

---

# 26. Additional async races

追加で:

```text
build中 suspend
build中 resume
state snapshot中 remove
state load中 remove
GFX render中 remove
remove → same ID reuse → 古いGFX completion
```

を検証。

production code に存在する identity guard を直接回帰テスト化する。

---

# 27. State snapshot debounce

sliderを高速変更:

```text
100 changes / < 250 ms
```

期待:

```text
最後の値だけが最終stateへ入る
stale snapshotが後から古い値で上書きしない
stateChanged callbackは死んだinstanceへ適用されない
```

---

# 28. Import / library

## Accepted

```text
.jsfx
.txt
extensionなし
UTF-8 BOM
zero-width prefix
Latin-1
```

## Rejected

```text
plain text
binary
> 1 MiB
```

最重要:

```text
rejectしたfileは JSFX/Sources に残らない
```

---

# 29. `looksLikeJSFX()` boundary

現在「先頭80行」を見る仕様なので固定テストを作る。

```text
marker at line 80 → accepted
marker at line 81 → rejected
```

以下も確認:

```text
leading whitespace
BOM
zero-width character
desc:
@init
@sample
```

---

# 30. Source identity

user import:

```text
same bytes + different filename → same source identity
1-byte difference → different source identity
same display name + different bytes → different identity
```

debug fixture:

```text
source content changed
→ debug component ID は filename-based で維持
```

historical alias も解決できること。

---

# 31. Metadata parsing

対象:

```text
desc:
author:
```

ケース:

```text
UTF-8
Latin-1
missing
empty
duplicate
BOM
leading whitespace
```

C API の:

```text
ETJSFX_Name
ETJSFX_Author
```

も確認。

---

# 32. External processor slot registry

AU と JSFX は同じ slot namespace を共有する。

```text
8 JSFX → success
9th → noSlot
```

混在:

```text
4 AU + 4 JSFX → success
9th → fail
```

slot reuse:

```text
slot 3 remove
→ next reserve uses free slot safely
```

以下の失敗経路で leak がないこと:

```text
compile failure
state restore failure
cancelled build
remove during build
```

---

# 33. L3 — Pipeline Integration Tests

ここでは JSFX runtime 単体ではなく、本番 `ETPipeline` 経路を通す。

---

# 34. Channel routing

16ch test signal を使用する。

```text
各chへ異なる定数またはimpulse
```

ケース:

```text
channel = All
channel = L
channel = R
channel = mono channel N
channel = stereo pair N
```

期待:

```text
選択されたchannelだけJSFX処理
非対象channelはbit-exact
```

out-of-range channelSpec:

```text
→ ET_ERR_ARGS
```

---

# 35. Bus routing

```text
Bus0 → JSFX → Bus1
```

について:

```text
Bus0の予期しない破壊なし
Bus1へ正しく結果が出る
```

複数 bus chain も最低1ケース入れる。

---

# 36. Enabled / Section gate

JSFX process counter fixture を使う。

```text
enabled=false
→ process counter増えない
```

```text
sectionGate=false
→ process counter増えない
```

音が bypass になるだけではなく、
**重いJSFXそのものが実行されていないこと**を保証する。

---

# 37. Async processor not ready

node は pipeline に存在するが compile 未完了。

期待:

```text
safe bypass
pipeline全体はerrorにならない
audioはbit-exact
```

install 完了後:

```text
次の処理からJSFXが有効
```

---

# 38. External diagnostics

```text
ETPipeline_ExternalProcessCount
ETPipeline_ExternalLastStatus
```

を検査。

正常処理:

```text
count + 1
status = 0
```

processor error:

```text
lastStatus = processor error
```

未準備 processor の count semantics もテストで固定する。

---

# 39. Pipeline descriptor / external index

JSFX node が:

```text
kind = EXTERNAL
externalIndex = reserved slot
```

で descriptor に載ること。

external slot の追加・削除で、
既存 node の externalIndex が誤って変わらないこと。

---

# 40. Preset / persistence

JSFX node について以下を roundtrip:

```text
externalID
externalInstanceID
externalState
enabled
inputBus
outputBus
channelSpec
```

short form / long form 両方。

---

# 41. Duplicate instance identity

同じ JSFX preset を複数回追加。

期待:

```text
component ID = same
instance ID = all unique
state = copied
```

一方の slider を変更して:

```text
他instanceのstate/audioが変わらない
```

保存データに instance ID 重複がある場合も、
restore 時に runtime identity が衝突しないこと。

---

# 42. Share link

## EffectDeck link

保持:

```text
externalID
externalInstanceID
externalState
routing
enabled
```

source 本体を埋め込まないこと。

受信側に source がある場合:

```text
restore可能
```

source がない場合:

```text
chain全体が壊れない
安全に解決不能として扱う
```

---

## Official EffeTune link

same-bus JSFX:

```text
external processor nodeを落とす
```

cross-bus JSFX:

```text
0 dB Volumeへ置換
routing維持
enabled維持
```

---

# 43. JSFX × Section

新しい Section / rootReset モデルとの統合テスト。

```text
Section OFF
  JSFX
```

→ JSFX process は呼ばれない。

```text
Section ON
  JSFX
rootReset
native effect
```

→ JSFX の owner / gate が期待通り。

移動:

```text
Section内 → root
root → Section内
```

を100回程度往復。

期待:

```text
instanceID不変
state不変
host再生成なし
rootReset増殖なし
```

---

# 44. JSFX × FoldRegion

Preset Fold の collapse / expand は audio semantics に一切影響しない。

```text
before wire == after wire
before state == after state
before process mapping == after process mapping
```

---

# 45. Stateful fuzz

JSFXを含む document editor fuzz を用意。

状態:

```text
native effect
Section
rootReset
JSFX A
JSFX B
AU
```

操作:

```text
add
remove
move
toggle
leaveSection
insertPreset
duplicate preset
routing change
save
restore
suspend
resume
```

各操作後 invariant:

```text
externalInstanceID unique
bridge slot unique
slot count <= 8
JSFX node ↔ host mapping consistent
state belongs to correct instance
pipeline canonical
Section/rootReset canonical
no orphan bridge slot
```

目安:

```text
100 seeds × 500 operations
```

から開始。

---

# 46. Core random / property tests

slider:

```text
normalized roundtrip
```

state:

```text
valid state roundtrip
corrupt state never crashes
```

document:

```text
save/restore semantic equivalence
```

bridge:

```text
reserve/remove sequence never duplicates live slot
```

---

# 47. L4 — Physical Device Tests

自動テストへ移せないものだけ残す。

## Realtime

```text
30分以上連続再生
複数JSFX同時
AU + JSFX混在
slider連打
GFX同時表示
trigger連打
```

確認:

```text
dropoutなし
unexpected bypassなし
memory runawayなし
```

---

## Route / lifecycle

```text
background → foreground
screen off → on
route picker
wired ↔ Bluetooth
sample rate変更
2ch / 4ch / 16ch
```

---

## GFX

```text
30 fps
60 fps相当
Retina
fullscreen transition
inline ↔ fullscreen
reorder中 snapshot
```

CPU / thermal / memory を確認。

---

# 48. Performance baseline

JSFX は「動く」だけでなく realtime deadline が重要。

基準値は release test で保存する。

例:

```text
device
iOS version
sample rate
block size
channels
fixture
median CPU/block
p95
p99
worst
deadlineTrips
```

ただし threshold は実測を取ってから固定する。

---

# 49. Public API coverage matrix

最終的に `ETJSFXHost.h` の全 public API が少なくとも1テストへ紐づく表を作る。

例:

| API | Test |
|---|---|
| `ETJSFX_Create` | C01–C24 |
| `ETJSFX_Destroy` | resource / stress |
| `ETJSFX_Processor` | descriptor / DSP |
| `ETJSFX_Reconfigure` | descriptor / lifecycle |
| `ETJSFX_SaveState` | state |
| `ETJSFX_LoadState` | state |
| `ETJSFX_SliderInfo` | slider metadata |
| `ETJSFX_SliderToNormalized` | normalized roundtrip |
| `ETJSFX_SliderFromNormalized` | normalized roundtrip |
| `ETJSFX_SetSlider` | parameter update |
| `ETJSFX_GetSlider` | parameter update |
| `ETJSFX_SendTrigger` | trigger |
| `ETJSFX_ClearDiagnostic` | deadline |
| `ETJSFX_ConsumeLatencyChange` | PDC |
| `ETJSFX_ConsumeSliderChange` | slider notification |
| `ETJSFX_RunGFX` | GFX |
| `ETJSFX_CopyGFX` | GFX |
| `ETJSFX_GFXMouse` | GFX input |
| `ETJSFX_GFXKey` | GFX input |
| `ETJSFX_GFXWindowState` | GFX input |

**APIを追加したのにこの表へ追加されない PR は不完全**、という運用にする。

---

# 50. CI 構成

推奨:

```text
CI
├── native-core
│   ├── external_processor
│   └── jsfx_host
│
├── ios-logic
│   ├── existing Tests/Unit
│   ├── JSFXHostTests
│   └── JSFXPipelineTests
│
├── sanitizer
│   ├── ASan
│   └── TSan（可能な構成のみ）
│
└── device-release-gate
    └── 手動 / release候補
```

PR ごと:

```text
native-core
ios-logic
```

nightly:

```text
fuzz
sanitizer
longer stress
```

release 前:

```text
physical device
```

---

# 51. テストの優先順位

## P0 — 先に必ず入れる

- source validation / sandbox
- core audio processing
- slider metadata / curves
- trigger
- state serialization / corrupt state
- PDC
- automatic bypass / Re-enable
- process / state / reconfigure race
- import rejection cleanup
- external slot leak
- async build/remove/reuse
- pipeline channel routing
- bus routing
- enabled / Section gate
- preset instance identity
- save/restore

## P1

- GFX framebuffer
- LICE offscreen resource limit
- GFX input
- menu
- Swift GFX owner aggregation
- share link
- host time
- timer lifecycle
- source identity / aliases

## P2

- screenshot appearance
- long-running visual correctness
- performance threshold tuning
- UI polish

---

# 52. Release gate

JSFX Host を「テスト済み」と扱う最低条件:

```text
L1 Core tests PASS
L2 Swift lifecycle PASS
L3 Pipeline integration PASS
state corrupt fuzz PASS
bridge slot stress PASS
Section/rootReset + JSFX stateful fuzz PASS
no sanitizer findings
```

さらに release 前:

```text
実機30分以上
複数JSFX
AU+JSFX
GFX
slider連打
route変更
background/foreground
```

で重大異常なし。

---

# 53. 特に守るべき invariants

JSFX 周辺では、個別ケースより以下を強い invariant として持つ。

```text
1. live externalInstanceID は一意

2. live bridge slot は一意

3. bridge slot は最大8

4. nodeが削除されたら最終的にorphan slotは残らない

5. stale async completion は replacement instance を変更しない

6. rejected import は persistent storage を変更しない

7. state は別instanceへ混入しない

8. Fold/UI操作はaudio semanticsを変えない

9. disabled / gated JSFX はprocessされない

10. maintenanceはautomatic bypassを勝手に解除しない

11. triggerはnon-running中にqueueされない

12. dynamic PDC は最終pipeline latencyまで反映される

13. resource budgetはdestroy後に必ず回収される

14. unsupported filesystem access は常に拒否される
```

---

# 54. 既存手動チェックから自動化できる項目

`docs/test-2026-09-20.md` の JSFX 手動チェックのうち、以下は自動化へ移す。

```text
値が指数表記にならない
値を打ち込める
trigger
trigger non-running
automatic bypass
Re-enable
.txt import
invalid text reject
rejected file cleanup
imported JSFX delete
debug fixture delete禁止
state persistence
```

UI の見た目だけ残す場合でも、
ロジック自体はunit testで保証する。

---

# 55. 未確定事項

## 55.1 EEL RAM

現時点で:

```text
Documentation: 16 MiB / instance
ysfx patch:    2 MiB / VM clamp
global:        64 MiB
```

に不一致がある。

実装か文書のどちらを正とするか決めてからテスト値を固定する。

---

## 55.2 Cross-instance globals

```text
gmem
_global.*
regXX
```

は Compatibility 上「保証しない」。

そのため互換挙動を固定するテストは作らない。

ただし:

```text
crashしない
memory safetyを壊さない
```

ことは stress / sanitizer で確認する。

---

# 56. 実装順

推奨順:

```text
Phase 1
  JSFX native test target
  fixtures
  Create / audio / slider / state

Phase 2
  trigger / PDC / deadline / maintenance

Phase 3
  GFX / resource limits / menu

Phase 4
  Swift host dependency injection
  async lifecycle / storage / debounce

Phase 5
  Pipeline integration
  channel / bus / Section / preset / share

Phase 6
  fuzz / sanitizer / device release gate
```

各 Phase で production behavior を変える場合は、
先に regression test を置いてから修正する。

---

# 57. Done の定義

このテスト設計の目的は「項目数を増やすこと」ではない。

最終的には、JSFX Host について次が成立すれば完成とする。

> source を読み込むところから、VM生成、DSP、parameter、state、GFX、PDC、
> pipeline、保存、複製、削除、再起動、実機 realtime まで、
> 壊れた場所をテスト層から特定できる。

また、新しい JSFX Host 機能を追加した場合は必ず:

```text
public API coverage matrix
fixture
unit/integration test
必要ならdevice test
```

のいずれかを同時に更新する。

これを JSFX Host の継続的なテスト契約とする。

---

## Source audit references

設計時に確認した主な実装:

```text
Sources/Shared/ETJSFXHost.h
Sources/Shared/ETJSFXHost.cpp
Sources/EffeTuneLive/Audio/ETJSFXHost.swift
Sources/EffeTuneLive/Audio/ETAUExternalBridge.swift
Sources/Shared/ETExternalProcessor.h
Sources/Shared/ETExternalProcessor.c
Sources/Shared/ETPipeline.h
Sources/Shared/ETPipeline.c
Sources/EffeTuneLive/DSP/EffeTuneDSP.swift
Sources/EffeTuneLive/DSP/PipelineStore.swift
Sources/EffeTuneLive/DSP/ETShareLink.swift
JSFX.md
Patches/ysfx-effectdeck-ios.diff
Debug/JSFXFactory/EffectDeck JSFX Conformance.jsfx
Tests/Native/external_processor.c
docs/test-2026-09-20.md
```
