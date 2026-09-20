# `modifyCurrentSelectionIfNecessary:isPlayingVideoOutput:` の判定木

issue #3 / #4 の答え。課題文は `docs/mde-routing-question.md`。

**対象**: iOS 27.0 RC (24A435) / iPhone17,3 の `MediaExperience`、
`-[MXCustomRoutingController modifyCurrentSelectionIfNecessary:isPlayingVideoOutput:]`
（`0x1ae8bdaac`、951 命令）。

読んだもの: 実機の dyld_shared_cache から抜いた dylib の逆アセンブル
（`H:\ios-audio\results\sandbox\work\MediaExperience.asm`、前の調査が作ったもの）。
切り出しと注記の台本は `H:\ios-audio\scripts\mde-routing_*.sh` / `mde_*.py`。
**シミュレータ版は使えない** ——`isPlayingVideoOutput` も `MusicVAD` も
`MDESupportedProtocols` も文字列が 1 つも入っていない（殻だけ）。

---

## 答え

**映像の判定が MusicVAD より先。**`isPlayingVideoOutput == YES` のとき
`_vaemMusicVADExists` は**呼ばれもしない**。

決め手は 2 命令。

```asm
1ae8bdc90:  bl   <objc:routeSharingPolicy>    ; policy = [session routeSharingPolicy]
1ae8bdc94:  mov  x23, x0
1ae8bdc98:  cmp  w0, #0x3                     ; 3 = AVAudioSession.RouteSharingPolicy.longFormVideo
1ae8bdc9c:  csinc w26, w22, wzr, ne           ; w26 = (policy != 3) ? isPlayingVideoOutput : 1
            ;                                 ; ⇒ w26 = isPlayingVideoOutput || (policy == longFormVideo)
...
1ae8bddc0:  tbz  w26, #0x0, 0x1ae8bdec0       ; w26 が 0 のときだけ MusicVAD 判定へ
1ae8bdec0:  bl   <_vaemMusicVADExists>        ; ← 入口はこの 1 本だけ
```

`w22` は頭の `mov x22, x3`（第 4 引数 = `isPlayingVideoOutput`）。
`1ae8bdbc4: cbz w0, 0x1ae8bdc80` でこの塊へ飛ぶ経路では w22 は上書きされていない。

`0x1ae8bdec0` へ飛ぶ分岐は**関数内にこれ 1 つだけ**（全 41 分岐を数えた）。
つまり `w26 & 1 == 1` なら MusicVAD の枝は到達不能。

---

## 判定木

```
policy = [session routeSharingPolicy]
videoish = isPlayingVideoOutput || (policy == longFormVideo)

if [session declares MDESupportsUniversalURLPlayback]:
    → "Current session with bundleID: … declares universal URL playback support,
       do not modify current route"                                          【許可】

if !videoish:
    if vaemMusicVADExists():
        → "Allow … because there is a MusicVAD."                             【許可】
    else if currentSystemMusicRoutes ∩ currentSystemMirroringRoutes:
        → "Allow … because we're currently mirroring."                       【許可】
    else:
        → "… not playing video or a long-form-video app.
           Will attempt to switch to AirPlay."                               【拒否】
else:
    if policy == longFormVideo && ![session isAirPlayVideoAllowedByClient]:
        → "Allow … because it is a long-form-video app that disallows
           external video playback (allowsExternalPlayback == NO)."          【許可】
    else:
        → "… playing video or a long-form-video app.
           Will attempt to switch to AirPlay"                                【拒否】
```

対応する番地:

| 枝 | 番地 | 文字列 |
|---|---|---|
| universal URL | `1ae8bdc58` | `0x1aeab5908` |
| MusicVAD | `1ae8bdf68` | `0x1aeab5a49` |
| mirroring | `1ae8be054` | `0x1aeab5ad2` |
| allowsExternalPlayback == NO | `1ae8be14c` | `0x1aeab5bf2` |
| 拒否（非映像） | `1ae8be228` | `0x1aeab5b61` |
| 拒否（映像） | `1ae8bde68` | `0x1aeab5cc9` |
| AirPlay 先が無い | `1ae8be3ac` | `0x1aeab5d55` |
| local へ戻す | `1ae8be81c` | `0x1aeab5ddb` |

---

## 課題文への回答

**2. MusicVAD は `isPlayingVideoOutput == YES` を覆せるか** ——できない。
映像の判定が先で、MusicVAD の枝へ行く分岐が塞がれる。`_vaemMusicVADExists` が
呼ばれもしないので、MusicVAD をどう作っても効かない。

これで「Spotify の interrupt と同時に MusicVAD が消える」説と
「映像のときは MusicVAD の枝を使わない」説のうち、**後者が正しい**と確定した。
実機ログに `because there is a MusicVAD` が 1 行も出ていなかったのはこのため。

**3 / 4. MusicVAD の条件が見ているもの** ——`_vaemMusicVADExists()` は引数なし。
セッションもバンドル ID も渡していないので、**端末に 1 つある状態**を見ている。
`CMSMUtility_ReassignHWControlFlagsAfterMusicVADDestruction` という名前が
同じ dylib に在るので、作られたり壊されたりする対象ではある。
ただし上のとおり映像時には参照されないので、これ以上追う意味は薄い。

**5. `allowsExternalPlayback == NO` の条件** ——`policy == longFormVideo (3)`
かつ `[session isAirPlayVideoAllowedByClient] == NO` の**両方**。
`1ae8bddc4: cmp w23,#3` → `1ae8bddd0: bl isAirPlayVideoAllowedByClient` →
`1ae8bddd4: tbz w0,#0`。

**6. MDE 側の性能（RouteSupportsVideo など）を見ているか** ——**見ていない。**
この関数が触るのはセッション側（`routeSharingPolicy` /
`isAirPlayVideoAllowedByClient` / universal URL playback の申告）と、
端末側の状態（MusicVAD / mirroring）だけ。
`currentSystemMusicRoutes` / `currentSystemMirroringRoutes` /
`currentSystemAudioRoutes` は自分の ivar から引いている。
**こちらの `capabilities` や transport type を変えても、この判定は動かない。**

**8. 何が再判定を起こすか** ——活性化時だけではない。実機で
Spotify を載せたまま YouTube を再生すると、interrupt の約 20 ms 後に
`isPlayingVideoOutput: YES` の判定が走り、EffectDeck が切られる。
**README の "The check runs only at activation." は誤りなので直すこと。**

---

## 本題への回答

> `isPlayingVideoOutput == YES` のときに、音だけの MDE が居座れる
> 正規の条件が 1 つでも在るか。

**在る。ただし EffectDeck 側からは満たせない。**

唯一の許可は
`routeSharingPolicy == longFormVideo` かつ `isAirPlayVideoAllowedByClient == NO`。
どちらも**音を出している側のアプリ**の `AVAudioSession` の性質で、
こちらが宣言できるものではない。

**ただしこれは「#3 が直せない」という意味ではない。**
塞がったのは MusicVAD と MDE の capability という 2 本の道だけで、
**`isPlayingVideoOutput` が YES になる条件そのものは別の話**。

### #3（YouTube）

**「動画だから拒否される」ではない。**YouTube を再起動すると同じ動画が通る、
という観測があり、実測でも次が取れている（`mde-watch` 2026-09-21 03:48:50）。

```
YouTube(591) setting routeSharingPolicy to LongFormAudio
ai.nemut.ytlite … isPlayingVideoOutput: NO. routeSharingPolicy 1
Allow … because there is a MusicVAD.
```

**YouTube が鳴っているのに `isPlayingVideoOutput: NO` で、MusicVAD で通っている。**
失敗した回は `YES` だった。`routeSharingPolicy` はどちらも 1 で同じなので、
**分けているのは `isPlayingVideoOutput` の 1 点だけ。**

だから #3 の問いは
「なぜ同じ YouTube が YES になったり NO になったりするのか」に変わった。

### #4（Canvas の無い Spotify で `YES` になる）

同じ問い。音だけなのに YES になる。

### 収束した 1 点

どちらも `isPlayingVideoOutput` を誰が何を根拠に立てているか、に収束した。
**立てているのは MediaToolbox**（AVPlayer の中身）で、
`_kMXSessionProperty_IsPlayingVideoOutput` を MediaExperience から輸入し、
`_MXSessionSetProperty` で送っている（どちらも symtab の undefined external）。
アプリが直接触っているのではない。

MediaToolbox 側の関数名から、見ているのは「動画アプリかどうか」ではなく
**プレイヤーに映像の出口が繋がって回っているか**らしい:

```
_fpfsi_handleVideoOutputsChanged
_fpfs_setVideoTargetArray / _fpfs_setClientVideoLayerArray
_fpfs_isExternalVideoOutput / _fpfs_PlayingVideoOnly
_playerfig_connectLayerSynchronizerToVideoOutputs
_vq_isConfiguredWithVideoOutput
```

これなら「再起動で直る」も「Canvas が無いのに YES」も、
**判定の瞬間に映像の出口が繋がっていたかどうか**で説明が付く。未確認。

---

## 付け足し: `Unable to Connect` は映像の枝とは限らない

Apple の公式文書（`docs/apple/README.md` に写しの要点）:

> The audio device must appear promptly upon activation, or the system deactivates
> your device and playback fails with an "Unable to Connect" message.

**音のデバイスが出るのが遅いだけでも同じ文言が出る。**
#3 を「映像だから蹴られた」と決める前に、こちらを外す必要がある
（今回のログでは映像の枝が実際に走っているので #3 は映像で確定だが、
他の "Unable to Connect" 報告にそのまま当てはめてはいけない）。

---

# 実際に効いているのは MusicVAD（2026-09-21 実測）

判定木を起こしたあとに実機で撮った。**`docs/connect-log.md` の A-10 が
9 月 16 日にほぼ同じ結論へ到達していた**（先に読むべきだった）。
ただし A-10 の 1 点は逆アセンブルで訂正できる。

## A-10 の訂正

> A-10:「`isPlayingVideoOutput` は文言を変えるだけで、どちらでも同じ結末に落ちる」

**違う。**`YES` のときは MusicVAD の枝に到達しない
（`1ae8bddc0: tbz w26,#0` が唯一の入口）。A-10 のデータで `YES` の 3 回が
全部落ちているのは偶然ではなく、構造的にそうなる。

## 数え合わせ

A-10 の 20 回と今回の観測を合わせると:

| `isPlayingVideoOutput` | 結果 | 効いていたもの |
|---|---|---|
| `YES` | 全部失敗 | MusicVAD の枝に到達しない |
| `NO` | 通る 17 / 切られる 3 | **MusicVAD が居るかどうか** |

**レバーは MusicVAD 1 本。**

## MusicVAD の生き死にを実測した

```
04:11:49.446  vaemVADRouteChangeListener: … MusicVAD: NO …
04:11:53.182  CreateMusicVADIfNeeded: Checking if we should create MusicVAD with ports (
04:11:53.182  CreateMusicVADIfNeeded: Creating MusicVAD with port: 396!!!!
04:11:53.443  vaemVADRouteChangeListener: … MusicVAD: YES …
04:11:53.592  Allow … because there is a MusicVAD.
```

**EffectDeck を選んだ「あと」に作られている。**無い状態から、経路の切り替えを
きっかけに作られ、その 0.4 秒後に判定が通っている。

**そのときの経路は内蔵スピーカー**（`tick out=Speaker ports=Speaker`）。
issue #1 の「検出器は特定のポート型でしか作られず、繋がっている無線ポートに依る」は
そのままでは合わない。

## 生成の条件（`_CMSMVAUtility_CreateMusicVADIfNeeded` @ `0x1aea26cdc`）

```
if (vaemMusicVADExists())         → "MusicVAD already exists, nothing to do here."
portType == 'papl' (0x7061706c)   → "Dealing with LL Port, using all wireless ports %@"
                                  → "Checking if we should create MusicVAD with ports %@"
                                  → "Creating MusicVAD with port: %d!!!!"
```

`_vaemMusicVADExists` は 1 行の意味しかない:
`[[MXSessionManager sharedInstance] musicVADID] != 0`。

## いま立っている仮説

**失敗は競争条件ではないか。**判定が VAD の生成より先に走った回が切られている。
上の並びでは生成の 0.4 秒後に判定が来て通った。順が逆なら切られる。
「20% くらいで失敗する」という頻度とも矛盾しない。

**確かめ方**: 失敗した回のログを撮って、`Creating MusicVAD` が
判定より後に来ているか、そもそも出ていないかを見る。
見張り（Mac の `~/mde_watch.sh` → `~/mde-watch.log`）を置いてあるので、
次に失敗したときに自動で残る。

## 静的に追えなかったもの

`isPlayingVideoOutput` を立てているのは MediaToolbox（AVPlayer の中身）で、
`_kMXSessionProperty_IsPlayingVideoOutput` と `_MXSessionSetProperty` を
MediaExperience から輸入している（symtab の undefined external で確認）。
ただし**共有キャッシュから抜いた dylib は GOT が解決されていない**ので、
参照箇所を番地で辿れなかった（`MediaToolbox.asm` 328 万行に 1 件も無い）。
追うなら別の取り出し方が要る。

実測では、ytlite が動画を再生していても `IsPlayingVideoOutput = NO` だった
（`MXSession` の状態ダンプ、`clientType = 4`, `PiP = NO`）。
**「画面に動画が出ているか」という単純な話ではない。**

---

# 呼び分け直し: 「映像が立っている回」ではない（2026-09-21）

上で `#3 (a)` を「本当に映像が立っている回」と書いたが、**これは誤り**なので
呼び方を直す。正しくは **「MediaToolbox が `isPlayingVideoOutput = YES` と
分類した回」**。

同じ YouTube（`ai.nemut.ytlite`）が、同じ動画を再生していても
`YES` と `NO` の両方を出す。実際に映像が出ているかと同じものとして扱うと、
せっかく 1 点に収束した #3 / #4 の共通問題がまた曖昧になる。

`YES` になった後が構造的に詰みであることは変わらない。

```
MDE の経路判定                     … 解決済み（分岐順まで確定）
MusicVAD の時機                    … ほぼ解決（生成の瞬間を実測）
残り: MediaToolbox が isPlayingVideoOutput を YES/NO にする条件
        ↓
    #3 と #4 はここで分岐
```

## sink から逆に辿る

候補の関数名から読むのをやめ、**書き込み先から後ろ向きに辿る**。

```
_MXSessionSetProperty                     0x1ae8922c8  MediaExperience
_kMXSessionProperty_IsPlayingVideoOutput  0x1e1147208  MediaExperience
```

どちらも `ipsw dyld symaddr` で DSC から解決できた。

**抜き出した dylib を grep してはいけない。**共有キャッシュから
`ipsw dyld extract` したものは GOT が解決されていないので、
328 万行の `MediaToolbox.asm` に鍵の番地が 1 件も出ない。
**DSC のまま `ipsw dyld xref` を使う。**

### 完全な DSC の在処

```
/mnt/fs27/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e
```

`/root/img/fs27.dmg`（= `H:\ios27-nfc\dmg\24A435__iPhone17,3\043-70113-702.dmg`）を
`/opt/apfs-fuse/build/apfs-fuse` でマウントしたもの。

**パスに `,` が入っていると FUSE の option 解析が壊れる**ので、
記号の無い所（`/root/img/`）へ symlink を貼ってから渡す。

### 鍵への xref が 0 件でも「参照していない」ではない

輸入したデータシンボルなので、`鍵 → MediaToolbox の GOT 枠 → ADRP/LDR` という
間接参照になっている。0 件なら次の順で探す。

1. MediaToolbox 側のその輸入の slot を特定する
2. slot への xref
3. `_MXSessionSetProperty` の callsite と交差させる

## 動的側は塞がっている

`_MXSessionSetProperty` に breakpoint を置くのが最短だが、非脱獄では無理。

- `devicectl device process launch --start-stopped ai.nemut.ytlite` は
  `error 10004` で失敗。自前署名でも `get-task-allow` が無いと attach できない
- 値を保持して判定に使うのは **audiomxd**（システムデーモン）側で、
  こちらはそもそも attach できない

ytlite を再署名して `get-task-allow` を付ければ開くが、別の作業。

---

# 言い方の精度を上げる（2026-09-21）

## 1. 「YES なら詰み」は限定が要る

正しくは**「EffectDeck 側からは救えない」**で、「OS 全体として必ず拒否」ではない。
`isPlayingVideoOutput == YES` でも、映像の判定より前に在る
`MDESupportsUniversalURLPlayback` の許可と、video 側の
`routeSharingPolicy == longFormVideo && !isAirPlayVideoAllowedByClient` の許可は残る。

```
MediaToolbox が IsPlayingVideoOutput = YES を設定
    ↓
MusicVAD / mirroring の枝は到達不能
    ↓
いま観測している YouTube の session properties では拒否
    ↓
EffectDeck 側の宣言・capability では救えない
```

**#3 の観測条件では実質詰み**、が言えるところ。

## 2. 「分類する」ではなく「設定する」

`isPlayingVideoOutput` を MediaToolbox が**分類している**のか、
**映像の出口の状態をそのまま映しているだけ**なのかは、まさにこれから調べる所。
先に「分類」と呼ぶと結論を先取りする。
**「`kMXSessionProperty_IsPlayingVideoOutput` に YES/NO を設定する」**と書く。

## 3. xref が 0 件でも証拠にならない

`ipsw dyld xref` は本人が `🚧 [WIP]` と書いている。0 件を「参照していない」の
根拠に使わない。輸入シンボルの性質も違う。

```
_MXSessionSetProperty                     … 輸入した関数
                                            → stub / GOT / stub island 越し
kMXSessionProperty_IsPlayingVideoOutput   … 輸入したデータ
                                            → GOT 枠を LDR
```

**export 本体の `0x1e1147208` に xref が無いのは普通に在り得る。**
0 件なら「MediaToolbox 側の輸入の slot → slot への xref」へ落とす。

image はフルパスでなく basename（`--image MediaToolbox`）でよい。

## 4. 動的側: 塞がっているのは ytlite だけ

前に「ytlite にも audiomxd にも attach できないから動的は無理」と書いたが、
**writer を捕まえるだけなら再署名した ytlite に attach できれば足りる。**
MediaToolbox が `_MXSessionSetProperty` を呼ぶ瞬間は、audiomxd へ届く前に
アプリのプロセス内で捕まる。**audiomxd への attach は要らない。**

```
いまの ytlite には get-task-allow が無い   → writer を動的に捕まえられない
再署名して debuggable にする              → writer 側だけなら動的が開く
audiomxd                                   → writer の特定には要らない
```

再署名は別作業なので今は寄り道しない、という判断は変えない。

## 5. 「値を保持しているのは audiomxd」は言い過ぎ

`MXSession` の状態ダンプと経路判定に値が現れることは、**サーバ側にも伝播している**
ことを示すだけで、「唯一の保持場所が audiomxd」とまでは言えない。
`_MXSessionSetProperty` の実装か IPC の経路を見てから書く。

## 現時点のいちばん厳密な書き方

```
MXCustomRoutingController の判定関数
    → 解決済み

MusicVAD が許可に間に合う／間に合わない現象
    → 実測でかなり説明できた
    → ただし「固定の生成遅延」とまでは未確定

残る共通問題:
MediaToolbox が kMXSessionProperty_IsPlayingVideoOutput に
YES / NO を設定する条件
    ↓
#3: 同じ YouTube 動画でも YES / NO
#4: non-Canvas の Spotify でも一時的に YES
```

## 道具の状態（2026-09-21 時点）

`ipsw dyld xref` はまだ動かせていない。**方針の問題ではなく道具の問題。**

| 置き場 | `symaddr` | `xref` |
|---|---|---|
| apfs-fuse のマウント越し | 通る | `invalid dyld_shared_cache magic … at byte 0x0` |
| マウントの外へ写したもの | 通らない | 同じ |

写しでは `dyld_shared_cache_arm64e.symbols` が **I/O error** で落ちた
（5.0G / 78 ファイルは写せた）。**`xref` が `.symbols` を読みに行っていて、
そこが壊れているのではないか**というのがいまの読み。

apfs-fuse の大きな読みが不安定なのは確か（同じファイルで `cp` が落ちる）。

**次に試すこと**

1. `.symbols` を `dd conv=noerror,sync` で埋めながら写す
2. それでも駄目なら `--cache` に自前の a2s を渡す
3. `xref` を諦めて `dyld disass` で `_MXSessionSetProperty` を読み、
   IPC の経路と保持場所を確かめる（「保持しているのは audiomxd」を
   言い過ぎにしないためにも要る）
4. それも駄目なら、`ipsw dyld extract` に `--force-symbols` 相当が在るか見る。
   無ければ MediaToolbox の `__got` と輸入表を自前で突き合わせる
   （slot の番地さえ出れば、抜き出した `MediaToolbox.asm` の
   328 万行から `adrp/ldr` で拾える）

**4 が本命の逃げ道。**抜き出した dylib でも `__got` の**枠の番地**は残っているので、
「鍵の export 番地」ではなく「枠の番地」で探せば当たる。

## 道具の詰まりは 2 段階だった（解決）

**1. 読んでいた MediaToolbox が壊れていた。**

`H:\ios27-nfc\dsc27` は **535MB の部分キャッシュ**で、そこから
`ipsw dyld extract` したものを読んでいた。`ipsw macho info -l` が
`failed to read lazy load dylib info data at offset 0x164e2b10: EOF` で落ちる。

**328 万行の逆アセンブルに GOT の参照が 1 件も出なかったのはこれが理由。**
grep の当て方の問題ではなかった。

完全なキャッシュの `.77.dyldlinkedit` だけで 678MB あるので、
535MB の部分キャッシュに収まるはずがない。**先に大きさを見れば気づけた。**

**2. 完全なキャッシュは apfs-fuse で扱えない。**

```
dyld_shared_cache_arm64e.77.dyldlinkedit   678 MB  … Input/output error
dyld_shared_cache_arm64e.symbols         1,223 MB  … Input/output error
```

`open` すら通らない（`dd conv=noerror` でも駄目）。この 2 つが欠けると
`xref` も `dyld extract` も `invalid dyld_shared_cache magic … at byte 0x0`。
**`symaddr` のような小さい読みは通るので気づきにくい。**

**逃げ道: 7-Zip。**26.03 は APFS を直に読める（`Type = APFS`）。
この dmg は元々 7-Zip で扱っていた（`H:\ios27-nfc\7z.log`）。

```powershell
& 'C:\Program Files\7-Zip\7z.exe' e <dmg> -o<出力先> -y `
  "System\Library\Caches\com.apple.dyld\dyld_shared_cache_arm64e.77.dyldlinkedit" `
  "System\Library\Caches\com.apple.dyld\dyld_shared_cache_arm64e.symbols"
```

**Mac は使わない。**空きが 15 GiB しかなく、6GB の dmg を置くと
ビルド機を圧迫する。

## 完全な DSC の置き場（これから使うもの）

```
/mnt/h/ios-audio/dsc27full/dyld_shared_cache_arm64e
```

5.0G を apfs-fuse で写し、欠けた 2 つを 7-Zip で足したもの。

---

# #4 の真因（2026-09-21 実測で確定）

**Canvas のプレイヤーが `IsPlayingVideoOutput = YES` を立てたまま戻さない。**

見張りが捕まえた並び（`~/mde-watch.log`）:

```
04:17:07.896  -[MXSession(InterfaceImpl) initWithSession:]
              Creating MXSession = <ID: 45a, CoreSessionID = 48
              Name = sid:0x7406f, Spotify(841), 'prim', …
              clientType = 1, IsPlayingOutput = NO, IsPlayingVideoOutput = NO>

04:17:09.043  -[MXSession(InternalUse) setIsPlayingVideoOutput:]
              MXSession(45a) of type FigPlayer for CoreSession sid:0x7406f, Spotify(841)
              setting IsPlayingVideoOutput = YES

04:19:09.454  <ID: 45a, … DoesntActuallyPlayAudio = YES, clientType = 3,
              IsPlayingOutput = NO, IsPlayingVideoOutput = YES>

04:23:05.996  Session with bundleID: com.spotify.client doesn't support currently selected
              protocolID …  isPlayingVideoOutput: YES.  routeSharingPolicy 1
04:23:05.997  Session with bundleID: com.spotify.client playing video or a long-form-video
              app. Will attempt to switch to AirPlay
```

**`45a` が `NO` に戻した記録は 0 件**（窓の中で `grep -c "MXSession(45a).*= NO"` = 0）。
立ててから 6 分後の判定がまだ `YES` を見ている。

## 何が起きているか

**1 つの CoreSession に MXSession が複数ぶら下がる。**

| MXSession | type | clientType | 音 | 映像 |
|---|---|---|---|---|
| `457` | — | 2 | `IsPlayingOutput = YES` | `IsPlayingVideoOutput = NO` |
| `45a` | **FigPlayer** | 1 → 3 | `IsPlayingOutput = NO`<br>`DoesntActuallyPlayAudio = YES` | **`IsPlayingVideoOutput = YES`** |

`45a` は **音を出さず映像だけのプレイヤー** ——Canvas（曲に付くループ動画）。
音を鳴らしているのは `457` のほうで、そちらは `video = NO` のまま。

判定は **CoreSession の値**を読むので、黙っている Canvas のプレイヤーが汚染する。

## 対照

同じ窓で WebKit は**戻している**。

```
04:19:12.330  MXSession(450) of type None for CoreSession com.apple.WebKit(744)
              setting IsPlayingVideoOutput = YES
04:19:14.626  MXSession(450) of type None for CoreSession com.apple.WebKit(744)
              setting IsPlayingVideoOutput = NO      ← 2.3 秒後
```

**戻す実装と戻さない実装が同じ端末に居る。**Spotify の FigPlayer は戻さない。

## これで説明が付くもの

- **Canvas の無い曲でも `YES`** … 前の曲の Canvas で立った値が残っている
- **プロセスを作り直すと直る** … CoreSession ごと消えて、新しいのは `NO` から始まる
- **「20% くらいで失敗する」** … Canvas 付きの曲を通ったあとかどうか

## 回避（利用者に出せる）

**Spotify を一度終了してから選び直す。**CoreSession が消えるので `YES` も消える。
EffectDeck 側から消す手は無い（他のアプリのセッションの property）。

## #3 への当て込み（未確認）

同じ形で説明できるはず。ytlite の映像のプレイヤーがサブセッションとして
`YES` を立て、アプリを作り直すと `NO` から始まる。
「同じ動画でも通ったり通らなかったり」「再起動で直る」と合う。
**ただし #3 でこの並びを撮ったわけではない。**見張りは置いてある。

## 訂正: 「部分キャッシュのせいで壊れていた」は誤り

上で「抜き出した MediaToolbox が壊れていたから GOT が見えなかった」と書いたが、
**誤り。**完全なキャッシュから抜き直したものと **md5 が一致した。**

```
/root/aud/bin/MediaToolbox   809aaebcd8217f0432d8f7e9be600816  … 535MB の部分キャッシュ由来
/root/aud/good/MediaToolbox  809aaebcd8217f0432d8f7e9be600816  … 6.7G の完全キャッシュ由来
```

GOT の参照が出ないのは**抜き出した dylib の性質**で、破損ではない。
GOT の中身はキャッシュ側に在るので、抜き出した単体のファイルには入らない。
`macho info -l` の `failed to read … EOF` も、破損ではなく
**抜き出し物に対する道具の限界**。

`.77.dyldlinkedit`（678MB）が旧セット全体（535MB）より大きいのは事実だが、
**MediaToolbox を抜くぶんには足りていた。**大きさの比較から破損を推したのは
飛躍だった。

**ただし DSC を取り直したこと自体は要る。**部分キャッシュでは `xref` も
`dyld info` もそもそも動かない（`invalid magic at byte 0x0`）。
いまは `info` が 5537 dylib を認識し、sink の番地も両方解決する。

**image のパスは `Frameworks` が正。**`PrivateFrameworks` ではない。

```
/System/Library/Frameworks/MediaToolbox.framework/MediaToolbox
/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience
```

## #4 の言い方を締める

「WebKit が戻しているので仕様ではない」と書いたが、証明できているのは

> **OS が `YES` を保持し続ける不可避な仕様ではない**

まで。**「`NO` に戻す責任が Spotify 側にある」という責任分界は、まだ言えない。**
MediaToolbox / FigPlayer 側の契約（誰がいつ戻すことになっているか）を
読む余地が残っている。

実用上の原因認定 ——**Spotify の Canvas / FigPlayer の生存期間に
古い状態が残る** ——は十分強い。回避策もそれで足りる。

## #3 を確定させるのに要る観測（1 点だけ）

```
ytlite で動画を再生
    ↓
MXSession(xxx) of type FigPlayer for CoreSession …, ytlite
    setting IsPlayingVideoOutput = YES
    ↓
動画を止める／別のものへ
    ↓
… setting IsPlayingVideoOutput = NO が出るか
```

**出なければ #3 は #4 と同じ形**（サブセッションが立てたきり戻さない）。
出るなら別の理由。Spotify の `45a` が戻さなかったのと同じ対照になる。

見張りの注意: `grep --line-buffered -A 10` にすると無関係な行を巻き込んで
**流れが詰まる**（2026-09-21 04:39 で止まった）。`-A` は付けない。

---

# #3 も同じ原因だった（2026-09-21 実測で確定）

見張りが **#3 の失敗（`Unable to Connect`）を丸ごと**捕まえた。

## 書き手は `mediaplaybackd`

```
04:56:57.561  set_property  mediaplaybackd(295)  sibling_of: 0x7408e YouTube(1066)
              key: IsPlayingVideoOutput  value: [0.0]
04:56:58.774  同じ                                value: [0.0]
04:56:59.605  同じ                                value: [1.0]     ← 立った

              MXSession(48c) of type FigPlayer for CoreSession sid:0x7408e, YouTube(1066)
                  setting IsPlayingVideoOutput = YES
              MXSession(493) of type FigPlayer for CoreSession sid:0x7408e, YouTube(1066)
                  setting IsPlayingVideoOutput = YES

04:57:48.295  …以降も 1.0 を書き続ける
04:57:48      判定 → Unable to Connect
```

**アプリではなく `mediaplaybackd`（AVPlayer を代理で回すデーモン）が、
アプリのセッションの兄弟として書いている。**

## 更新モデル

**毎回書き直している。**立てたきりの一発設定ではない。

```
0.0 の書き込み   4 回
1.0 の書き込み  36 回   （1 分間に 20 回以上）
```

## 同じプロセスの中で NO → YES

```
04:54:21  YouTube(1066)  IsPlayingVideoOutput = NO   → Allow（MusicVAD）
                         mediaplaybackd の兄弟セッション無し
04:56:59  mediaplaybackd が 1 に書き換え               兄弟セッション出現
04:57:48  IsPlayingVideoOutput = 1                   → Unable to Connect
```

**同じアプリ・同じ CoreSession（`0x7408e`）**で値が変わっている。
「同じ動画でも通ったり通らなかったり」はこれ。
分けているのは **`mediaplaybackd` 経由の映像プレイヤーが立っているかどうか。**

## 壊れている側の共通点は FigPlayer

0.0 が書かれた 4 回のうち、**停止時に戻しているのは WebKit だけ。**

| | セッションの形 | 立てる | 戻す |
|---|---|---|---|
| WebKit | 自前・type `None` | YES | **NO（2.3 秒後）** |
| Spotify Canvas | **FigPlayer** サブセッション `45a` | YES | 記録なし |
| YouTube | **FigPlayer** サブセッション `48c` / `493`<br>＋ `mediaplaybackd` 兄弟 | 1（36 回） | 記録なし |

**FigPlayer で回している再生は、プレイヤーが消えても 0 に戻らない。**

## #3 と #4 は 1 つの原因

```
FigPlayer の映像プレイヤーが立つ
    ↓
mediaplaybackd が IsPlayingVideoOutput = 1 を書く
    ↓
プレイヤーが消えても 0 に戻らない
    ↓
MXCustomRoutingController が 1 を見る
    ↓
videoish = true → MusicVAD の枝に到達しない
    ↓
AirPlay 探索 1.5 秒 → 見つからない → ローカルへ戻す
    ↓
Unable to Connect
```

- **#4（Spotify）** … Canvas が FigPlayer を立てる。曲が変わっても 1 のまま
- **#3（YouTube）** … 映像が FigPlayer で回る。アプリを作り直すと
  CoreSession ごと消えて 0 から始まる

## EffectDeck 側からできること

**無い。**判定関数は `MediaOutputDevice` を 1 つも読まない。
`IsPlayingVideoOutput` は他のアプリのセッションの property で、
書いているのは `mediaplaybackd`。

**利用者に出せる回避**

- 映像を止めて（音だけにして）から選び直す
- それでも駄目なら、そのアプリを一度終了してから選び直す
  （CoreSession ごと消えるので 1 が消える）

## まだ読んでいないもの

MediaToolbox の中で `1` と `0` を作り分けている条件そのもの。
**ただし実用上はここまでで足りる。**上の並びで #3 / #4 の観測は全部説明できる。

## 訂正: 「1 つの原因に収束」は言い過ぎ

**共通なのは下流の機構だけ。上流の異常は別物。**

```
共通の下流
  FigPlayer 系の video サブセッション
      ↓  IsPlayingVideoOutput = YES
  同じ CoreSession に集約
      ↓
  MXCustomRoutingController が CoreSession の YES を読む
      ↓
  MusicVAD の枝に入れず拒否
```

```
#3（YouTube）
  mediaplaybackd 経由の FigPlayer が**現役**
  → YES を書き続けている
  → その時点では stale ではない
  → video session が生きているので拒否される

#4（Spotify）
  Canvas の FigPlayer が過去に YES を立てた
  → 音も映像も出していない状態になっても NO に戻さない
  → stale な YES が CoreSession に残る
  → 後続の Canvas 無しの曲まで拒否される
```

## 訂正: 「戻しているのは WebKit だけ」の範囲

正しくは **「今回捕捉したログの範囲では、停止時の明示的な `0` 書き戻しを
確認できたのは WebKit だけ」**。

4 対 36 という観測は強いが、**「Spotify / YouTube は絶対に 0 を書かない」**
とまでは言えない。

## #3 で大きかったこと

同じ `PID 1066 / CoreSession 0x7408e` のまま値が変わった。

```
04:54:21           NO  → MusicVAD で allow
04:56:57-59        mediaplaybackd の兄弟セッション出現、0 → 1
04:57:48           YES → reject
```

**アプリの違い・動画の違い・CoreSession の違いでは説明できない。**
途中から **mediaplaybackd / FigPlayer の再生 topology が生えたこと**が
状態を分けている。

## 静的解析の標的が変わった

もう「YouTube がどう YES/NO を決めているか」ではない。

```
mediaplaybackd
    ↓  FigPlayer の生存期間 / video-output の状態
MediaToolbox / MXSession
    ↓
_MXSessionSetProperty(IsPlayingVideoOutput, value)
```

**`value` が何の状態から作られているか**を読むこと。

そして `mediaplaybackd(295)` が書き手だと動的に確定したので、
**MediaToolbox に限った xref で何も出なかったときの意味が変わった。**
今度は `mediaplaybackd` 実行ファイル側の callsite も探索対象になる。
MediaToolbox の中で setter まで完結しているとは、もう仮定しなくてよい。

## いまの #3 の状態

「真因不明」ではない。

- **EffectDeck が落ちる直接原因** … 確定
- **YES を発生させる主体（mediaplaybackd）と状態遷移** … 確定
- **残り** … 何が mediaplaybackd / FigPlayer 経路への切り替えを起こすか、
  と内部実装の静的な裏取り
