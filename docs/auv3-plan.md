# AUv3 に対応する

GarageBand などから EffeTune の効果を使えるようにする。
枝は `feature/auv3`。本線ではないので並行で進める。

## 形

**1 つの AUv3 が鎖まるごとを持つ。**エフェクトごとに分けない。
上流の VST（`effetune-mixwright`）も同じ形で、あちらは 1 つのプラグインが
鎖を持ち、画面は WebView で EffeTune の web をそのまま出している。

真似るところ / 真似ないところ:

| | |
|---|---|
| 1 プラグイン = 鎖まるごと | **真似る** |
| 状態の形を EffeTune と揃える（共有リンクの base64 JSON） | **真似る**。web / アプリ / VST と行き来できる |
| A/B の切り替え | 真似る |
| 画面が WebView | **真似ない**。iOS では重いし、native の SwiftUI のカードが既にある |
| 5 バス / 最大 8ch | 真似ない。GarageBand はステレオ |
| 1×2×4×8× のオーバーサンプリング | 真似ない。`processingRate.factor` で既に持っている |

## 手順

1. **engine を singleton から外す**
   `EffeTuneDSP.shared` は **25 ファイル**から呼ばれている。ホストは AU を
   複数立てられるので、engine が 1 個しか作れないと 2 枚挿しで壊れる。
   ここが一番大きい。
   救いは `EffeTuneDSP` 自身が `AudioIO` に依存していないこと
   （触っているのは `PipelineStore` と `ETScreenshotSeed` だけ）。
   音の経路とは切り離されている。

2. **拡張ターゲットを足す**
   `NSExtensionPointIdentifier = com.apple.AudioUnit-UI`。
   Info.plist の `AudioComponents` に type `aufx` / subtype / manufacturer /
   `sandboxSafe = true`。`project.yml` に target を 1 つ。

3. **`AUAudioUnit` のサブクラス**
   - `allocateRenderResources` → `prepare(sampleRate:maxChannels:maxFrames:)`
   - `internalRenderBlock` → `ETPipeline_Process`
   - **バッファはプレーナなので詰め替えが要らない**（`AudioBufferList` の
     非インターリーブにそのまま乗る）
   - `maximumFramesToRender` を守る。`latency` は `et_pipeline_latency` から

4. **状態**
   `fullState` / `fullStateForDocument` に鎖を入れる。形は EffeTune と同じ。

5. **パラメータ**
   v1 は `AUParameterTree` を最小限（bypass 程度）にして、鎖は fullState で持つ。
   606 個を全部出すのはオートメーションを本気でやるときで、後回し。

6. **画面**
   `AUAudioUnitViewController` に既存の SwiftUI のカードを載せる。
   `PipelineView` は `AudioIO` を見ているので、そこを外す（1 と同じ作業）。

7. **IR**
   App Group 経由で本体が読み込んだ IR を共有できるか確認する。
   Media Device Extension と違って AUv3 は App Group を使えるはずだが未確認。

8. **検証**
   `auval` は macOS の道具なので iOS では使えない。GarageBand と AUM で実機確認。
   音が上流と一致するかは golden ベクタで見る。

## どのくらいかかるか

- **音が出るところまで（2〜3、singleton のまま）** … 1 晩
- **状態と画面（4〜6）** … 1〜2 晩
- **IR と検証（7〜8）** … 1 晩
- **複数枚挿しに耐える（1 の切り離し、25 ファイル）** … 1〜2 晩

合計 **4〜6 晩**。順番としては singleton を後回しにして、
まず 1 枚挿しで音を出すのが早い。

## 測っていないこと

- AUv3 の中で SwiftUI のカードがそのまま動くか
- 1 インスタンス = 1 プロセスになるか（ならないなら 1 を先にやる必要がある）
- GarageBand の実時間の枠に鎖が収まるか（本体より厳しい）
