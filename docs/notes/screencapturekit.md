# ScreenCaptureKit では他アプリの音を差し替えられない

iOS 27 で ScreenCaptureKit（SCK）が iPhone / iPad に来た。システムの音を取り込めるので、
Media Device 拡張の代わりに使えないかを試した。**結論は「使えない」。**
理由は 2 つある。本体では起動の時点で拒否される。別アプリにすれば取り込めるが、元の音が止まらない。

実装は `feature/screencapturekit`（main には入れない）。
設定の Source で Media Device と Screen Capture を切り替え、
`SCContentSharingPicker` で選ばれた中身から `SCStream` の `.audio` を受けて鎖へ流す形。

**測った環境**: iPad Air (iPad13,16) / iOS 27.2 beta 2、Xcode 27.0 (27A266a) / iOS 27.0 SDK、2026-09-30。
生ログは Mac の `~/work/logs/sck/ipad-full-0930*.log`（idevicesyslog）。

---

## 1. 本体の中では SCK が起動しない（-3801）

ピッカーで画面を選ぶところまでは進むが、`startCapture` が
`SCStreamErrorDomain -3801`（userDeclined）で返る。replayd のログ:

```
replayd: SCCastingExtensionHasEntitlement:68 Casting extension entitlement check: present
replayd: -[RPClient isCurrentProcessShareableContentFilter:]:2382 Rejecting current process shareable content filter with shareAll=YES
replayd: -[RPClient hasScreenCaptureAccessWithAuditToken:...]:2468 Casting extension not authorized to screen cast
EffectDeck: sck 失敗 com.apple.ScreenCaptureKit.SCStreamErrorDomain -3801
```

replayd は、アプリの署名に `com.apple.developer.media-device-extension` が**有るかどうか**だけを見て、
そのアプリを casting（Media Device）アプリとして扱う。値の中身は見ない。
EffectDeck の本体は、このキーを空の配列で持っている（`Sources/EffeTuneLive/EffeTuneLive.entitlements`）。

- 空にしてあるのは、MediaExperience が要素数 1 以上のときだけ AVAudioSession を `'!pla'` で拒否するから
- キーそのものを消せないのは、配信時のチェック（ITMS-91183）が拡張を同梱する本体にこのキーを求めるから

casting アプリに SCK を許すのは、映像のキャスト（`MediaOutputDevice.Capabilities.realtimeVideoStreaming`）で
使う場合に限られる。MediaDevice.framework の説明も、SCK を使うのは拡張の側で、用途は映像になっている。

次の 2 つでは結果が変わらなかった。

| 試したこと | 結果 |
|---|---|
| 拡張を同梱しない版（キーは空で残る） | 同じく -3801。拡張の有無ではなくキーで決まる |
| 先に出力先を EffectDeck にしてから取り込む | 同じく -3801。音のキャストでは許可が下りない |

## 2. 別アプリにすれば取り込めるが、元の音が止まらない

キーを持たない別アプリ（bundle ID `ai.nemut.effetune.sck`、拡張なし）を作ると、SCK は通った。

```
sck frames=480000 rate=48000.0 ch=2 interleaved=false peak=1.0165   ← 10 秒ぶん。48kHz で届いている
```

- 48 kHz / 2ch / 非インターリーブの float32 で届く
- `excludesCurrentProcessAudio = true` は 27.2 beta 2 では働いている。自分の出力を取り込み直さず、音量が上がり続けることもない（27.0 では働いていなかった）

ただし、**元のアプリの音はそのまま鳴る**。SCK は出ていく音を写すだけで、出力先を奪わない。
そのため原音と加工した音が二重に聞こえる。EQ で補正する用途には使えない。

## 3. 元の音を Media Device へ逃がすと、SCK には何も届かない

原音を止める方法として、コントロールセンターで出力先を EffectDeck（Media Device）にして元の音を止め、
その音を別アプリの SCK で拾う組み合わせを試した。

```
sck frames=480960 rate=48000.0 ch=2 interleaved=false peak=1.0097   ← スピーカーへ出ている間
sck frames=480000 rate=48000.0 ch=2 interleaved=false peak=0.0000   ← 出力先を EffectDeck にした後
```

**SCK が拾うのは、実際のハードウェアへ出ていく音だけ。**仮想デバイスへ回した音は入らない。
「元の音を消す」と「その音を取り込む」を同時には満たせない。

## 4. ほかの手

- **`.duckOthers`**: 他のアプリの音量を下げるだけで、消えはしない（試験用のビルドは作ったが、実機では試していない）
- **逆位相で打ち消す**: 取り込んだ音が届くのは原音が鳴った後なので、間に合わない
- **出力を分ける**: 原音を誰も聞かない出力（使っていない Bluetooth / USB 機器）へ出し、
  自分だけ `overrideOutputAudioPort(.speaker)` で内蔵スピーカーへ出す形。理屈では成り立つが、加工した音が内蔵スピーカーからしか出ない
- **元の再生を止められる Core Audio のタップ**（`AUAudioTapIO` の mute local playback）: iOS では非公開。使わない

## まとめ

他のアプリの音を「止めて、受けて、差し替える」のを公開 API でできるのは、
出力先そのものになる Media Device 拡張だけ。EffectDeck は今の形のままにする。

SCK が使えるのは、二重に鳴ってもかまわない用途（見るだけのアナライザなど）に限られる。
その場合も、`media-device-extension` のキーを持たない別アプリとして出す必要がある。
