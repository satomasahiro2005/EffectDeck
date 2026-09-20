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
