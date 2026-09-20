# 電池が減る件の記録

issue #5「画面を消したまま放置すると電池が大きく減る」の台帳。

書く規則（connect-log と同じ）:
- 測っていないことを確定として書かない。推測には「推測」と書く
- ログの行は逐語で貼る。要約しない
- 外れたものも消さない。同じ道を二度歩かないため

**ここはまだ 1 度も実機で前後を測っていない。**減ったと言えるのは起床の回数だけで、
電池の減りが実際に何 % 変わったかは誰も見ていない。

---

## 疑いは 5 つ。読んで決まるものと、実機が要るものを混ぜない

| | 何を疑ったか | 読んで決まるか | 判定 | 打った手 |
|---|---|---|---|---|
| 1 | `followPeer` に `hasPeer` が無く、相手が居なくても engine が立つ | 決まる | **本当。ただし意図してそうしてある** | 触らない |
| 2 | 省電力が DSP を飛ばすだけで、render は回り続ける | 決まる | **半分は既に直っている**（cfadf7f） | 残りは触らない |
| 3 | ローカル橋のポンプが 1ms / 2ms で leeway 0 | 決まる | **本当** | 直した |
| 4 | `stopRealtimeSampleDelivery` が送り手を止めない | 決まる | **もう直っている**（cfadf7f） | 無し |
| 5 | 無音の `WriteMix` が流れ続けるか／`tick` がロック後も撃つか | **決まらない** | 未測定 | 下の「測り方」 |

---

## 読んで決まったこと

### 1 相手が居なくても engine は立つ。**それでいい**

`Sources/EffeTuneLive/Audio/AudioIO.swift:304` の `followPeer` は
`running && engine.isRunning` だけを見ていて、`hasPeer` は条件に入っていない。
issue の読みはここまで正しい。

ただしこれは取りこぼしではなく、実機のログで決めた形。同じ関数の上に理由が
逐語で貼ってある。`UIBackgroundModes` の `audio` が生かすのは**実際に鳴らしている
あいだだけ**で、鳴らすのをやめると背景で止められ、47101 が accept しなくなる:

```
et.log:49001 04:29:50.925840 EffeTuneLiveExtension[587] ET connect 失敗 errno=61
et.log:51268 04:29:51.934152 受信 frames=39936 接続=false 送信=0
```

拡張が `requiredNetworkEndpoints` として名乗るのもこの 47101 なので
（`Sources/Extension/EffeTuneLiveExtension.swift:105`）、止めると名乗った口が
実在しなくなる。**コントロールセンターから選ぶのがこの製品の導線で、そこで死ぬ。**

`else if false { stop(keepListening: true) }` という死んだ枝が残っていたのを外し、
代わりに「足すな」と理由を書いた。次に読む人が枝を生かすのを止めるため。

### 2 休んでいる間の render は、もう大半が消えている

`PowerGate` が休むと `ETPipeline_Process` を飛ばす、までは issue の書いたとおり。
ただし cfadf7f で早抜けが入っていて、**休んでいて入力が厳密に 0 なら
`AudioIO.swift:492` で memset して return する。**デインターリーブもトーンも
出力への 1 サンプルずつの書き込みも、もう走らない。

残っているのは 1 コールバックあたりこれだけ:

| | どこ |
|---|---|
| `readInterleaved`（相手が居なければ全域を 0 で埋める） | `AudioIO.swift:443` |
| ピーク走査 `n*2` サンプル | `AudioIO.swift:456-459` |
| `gate.update` | `AudioIO.swift:466` |
| `ETPipeline_ApplyPending`（溜まっていなければ atomic 1 回） | `AudioIO.swift:478` |
| 出力の memset | `AudioIO.swift:492-497` |

既定（48 kHz・DSP buffer 256）で 187.5 回/秒。**これ以上の削りは意味が薄い。**
engine が立っているあいだの本当の代価は、この算術ではなく
「オーディオのハードウェアが回っていること」と「アプリが中断されないこと」で、
どちらも回数を減らしても消えない。消すには engine ごと止めるしかなく、
それは下の「直さなかったもの」。

### 3 ポンプが 1ms / 2ms。**ここだけ直した**

直す前:

| | 周期 | leeway | 起床 |
|---|---|---|---|
| 受け手（本体） | 1ms | 0 | 1000 回/秒。相手が居ない間もずっと |
| 送り手（拡張） | 2ms | 0 | 500 回/秒。うち 495 回は `_idlePumps % 100` で素通り |

相手が居ないあいだにやっているのは、受け手が `accept` 1 回、送り手が
`connect` 1 回だけ。どちらも 1ms で撃つ理由が無い。

直したあと（`Sources/Shared/LocalLink.m:48-61` と `:277-294`）:

| | 相手待ち | 相手あり |
|---|---|---|
| 受け手 | 20ms / leeway 20ms（50 回/秒） | 1ms / leeway 1ms |
| 送り手 | 200ms / leeway 100ms（5 回/秒） | 2ms / leeway 0（**変えていない**） |

周期は `retimePump` が状態を見て入れ直す。同じなら何もしない。

**繋がるまでの時間は変えていない。**送り手の 200ms は、今までの間引き
（2ms の 100 回に 1 回）と同じ 5 回/秒。受け手の 20ms も音には出ない。
TCP の 3 way handshake はカーネルが backlog で受け切るので、
`accept` が遅れても相手の `connect` は即座に成功し、その間のサンプルは
ソケットの受信バッファに溜まる。読み始めが最大 20ms 遅れるだけで、
遅れは `readInterleaved` が書き位置から狙いのぶん下げて置き直す。

**遅延は増えない。**受け手の leeway 1ms はゆらぎであって遅れではない。
狙いの溜まりは 1024 フレーム＝21.3ms で、送り手自身が 2ms の塊で送っている。
1ms のゆらぎはその塊より細かい。

**それでも、ここがいちばん先に疑う所。**深くなったなら Diagnostics に出る:

- `Ran dry` が 0 でなくなる
- `Extension link` が 1024 から 2048 へ逃げている

どちらかが出たら、受け手の `RX_LIVE_LEEWAY_NS` を 0 に戻す。1 行。

### 4 `stopRealtimeSampleDelivery` が送り手を止めない — **もう直っている**

`Sources/Extension/EffeTuneLiveExtension.swift:368-388` が 2 秒の猶予を置いて
`ETLinkSender.shared.stop()` を撃つ。`startRealtimeSampleDelivery` 側
（`:353-354`）が予約を取り消すので、系が停止と再開を往復しても落ちない。
issue が書いている「配送は止まったが送り手は回り続けている」窓は、いま無い。

---

## 直さなかったもの

### 長い無音のあと engine ごと止める

**やらない。**止めた側から自分を起こす手が無い。

engine を止めるとアプリは鳴らしていないことになり、背景で中断される。
中断されたアプリでは `tick`（`AudioIO.swift:638`）が回らないので、
`followPeer` が engine を立て直すこともできない。外から起こせるのは
拡張の `connect` だけで、その `connect` が届く先の 47101 は
中断されたアプリでは accept しない（上の 1 の errno=61）。

つまり止めた瞬間に、**次にコントロールセンターで EffectDeck を選んでも
音が出ないアプリ**になる。前面に戻すまで直らない。connect-log の B と C で
一度ずつ払った代価と同じ形なので、ここは繋がる側へ倒す。

設定で切れる形にする案も置かない。既定を off にすれば誰も踏まないが、
on にした人だけが「たまに音が出ない」を踏むことになり、そちらのほうが悪い。

やるなら前提から変える。**アプリを中断させたまま起こせる口を先に見つけること。**
見つからないうちは engine を止める話に進まない。

### `tick` の 3.3Hz を背景で落とす

`Sources/EffeTuneLive/Views/PipelineView.swift:135` の `slow`
（`Timer.publish(every: 0.3)`）が `tick` を回し、`tick` は毎回
`refreshRoute` で `AVAudioSession.currentRoute` を引く。
画面を消しているあいだ誰も読まない値のために 3.3 回/秒引いていることになる。

**ただしこれは推測の段で止めてある。**ロック後も本当に撃っているかを測っていない。
下の「測り方」の 3 で決める。撃っていると分かってから触る。

（`ETDisplayPump` のほうは既に `scenePhase == .background` で止めてある。
`PipelineView.swift:290-293`。`slow` には同じ手当てが無い。）

---

## 測り方

**実機でしか測れない。**`MediaDevice.framework` は iPhoneOS SDK にしか無い。
順番に意味がある。1 を決めないと 2 と 3 のどちらを見るかが決まらない。

### 0 仕込み

Mac は要らない。アプリの中のログ（`ETLogTap`）が `tick` の行を持っていて、
上限 1 MB ＝ 約 8 時間ぶん。**一晩は保つ。**

朝に Settings → いちばん下の **Attach log** から書き出す。
`Diagnostics` の数字も一緒に控える（`Frames received` / `Ran dry` /
`Extension link` / `Output`）。

Mac が USB で見えているなら生ログも並行して録る:

```
idevicesyslog -u <udid> > battery-<日付>.log
```

`idevicesyslog` は usbmuxd 経由なので、USB で見えていないと動かない。
`devicectl` は `transportType: localNetwork` で通ってしまうので、
**インストールが成功することは USB が生きている証拠にならない**（connect-log と同じ罠）。

```
idevice_id -l                                      → UDID が出るか
ioreg -c IOUSBHostDevice -r -l -w 0 | grep -c "USB Product Name"
```

### 1 どの状態で夜を越したかを決める

**ここを決めないと残りが全部無意味になる。**2 つは別の状態で、効く手当ても違う。

| | 見分け方（`tick` の行） |
|---|---|
| 相手あり（経路が生きたまま） | `peer=true`。`recv=` が増え続ける |
| 相手なし（拡張が落ちている） | `peer=false`。`recv=` が据え置き |

書き出したログで `peer up` / `peer down` の行を拾えば、切れた時刻がそのまま出る。

### 2 無音の `WriteMix` は流れ続けるか

1 が「相手あり」だったときだけ意味がある。

器具は拡張が 1 秒ごとに出しているこの行
（`Sources/Extension/EffeTuneLiveExtension.swift:361-365`）:

```
受信 frames=39936 接続=false 送信=0
```

`framesDelivered` は `WriteMix` が来るたびに足される（`EffeTuneDriver.m:752`）。
ハンドラが刺さっているかどうかに関わらず数えるので、純粋な `WriteMix` の数。

**累計を読まない。増分を割る。**

```
(frames の増分) / (行の時刻差) / 48000
```

- 1 に近い → 何も鳴っていなくても無音の PCM が流れ続けている。
  そのときは経路そのものを畳む話になる（`deactivateDevice` が来ない理由を追う）
- 0 → `WriteMix` は止まっている。橋は起床しているだけで、運んではいない

本体側からも同じことが読める。`tick` の行の `recv=` の増分を
同じ式に入れる。両端で食い違ったら橋を疑う。

### 3 `tick` はロック後も撃つか

書き出したログの `tick` の行は 20 目盛りに 1 回＝約 6 秒おき。
**時刻の差だけ見ればいい。**

- 夜通し 6 秒おきに並んでいる → ロック中も 3.3Hz で回っている。
  上の「直さなかったもの」の 2 本目に着手してよい
- 途切れている → 中断されている。`tick` は犯人ではない。
  そのとき `peer` と `recv` がどうなっているかも同時に読む
  （中断されたなら 1 の errno=61 が拡張側に出ているはず）

### 4 ポンプの起床が効いたか

**前後で比べる。**この版より前を一晩、この版を一晩。

- 同じ端末・同じ充電量から始める・同じ時間だけ置く
- 1 晩に 1 条件だけ。2 つ変えると、どちらが効いたのか分からなくなる
- 朝に 設定 → バッテリー → EffectDeck の「バックグラウンド」の時間と %

対照を取れるなら、1 で分かった状態のほうに寄せる。相手なしで夜を越していたなら
「拡張を落として経路を切った夜」と「経路を張ったままの夜」を別々に測る。

### 5 それでも減るなら

橋でもポンプでもないということ。次に見るのはこの順:

1. `AVAudioEngine` が立っているだけでいくら食うか。
   鎖を空（Effect Pipeline を off）にして一晩置く
2. `slow` の 3.3Hz（3 の結果次第）
3. `NowPlaying` と `refreshRoute` が背景で撃っている回数

---

## 道具

| | |
|---|---|
| アプリの中のログ | Settings → Attach log（約 8 時間ぶん・1 MB） |
| 数字 | Settings → Diagnostics |
| 生ログ | `idevicesyslog -u <udid> > battery-<日付>.log` |
| 1 往復だけ測る | `bash Scripts/bridge_probe.sh 30`（Mac 上・実機が要る） |
