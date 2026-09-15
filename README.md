# EffeTune Live

他のアプリが鳴らしている音を横取りして、[EffeTune](https://github.com/Frieve-A/effetune)
のエフェクトを通して、内蔵スピーカーから出し直す iOS アプリ。
iPhone だけで動く。脱獄も PC も要らない。

```
他のアプリ（Spotify / YouTube など）
  ↓ コントロールセンターの出力先で「EffeTune」を選ぶ
EffeTune Live Bridge の中の Media Device Extension        ← 横取り
  ↓ TCP 127.0.0.1:47101
EffeTune Live
  ↓ EffeTune の DSP コア（100 種）                        ← 加工
内蔵スピーカー                                            ← 差し替え
```

## アプリが 2 つある理由

Media Device Extension を**同梱したアプリは AVAudioSession を開けない**。
どのカテゴリでも `'!pla'`（CannotStartPlaying）で拒否される。その拡張を
出力先に選んでいない状態でも拒否されるし、アプリ側の entitlement を外しても変わらない。
拡張プロセス自身も音を出せない（全カテゴリ `'msrv'`）。

だから拡張を運ぶ側と鳴らす側を分けてある。

| | 中身 | ユーザー |
|---|---|---|
| **EffeTune Live** (`ai.nemut.effetune.player`) | UI・DSP・スピーカー出力 | これを開く |
| **EffeTune Live Bridge** (`ai.nemut.effetune`) | Media Device Extension | 入れておくだけ |

拡張を持たない Live は、EffeTune がシステムの出力先になっていても内蔵スピーカーを
掴んだままでいられる。だから回り込まない。

## 音の加工

EffeTune の `dsp/` をそのまま積んでいる。移植も書き直しもしていないので、PC 版と同じ音が出る。

`dsp/` は host-neutral な C++20 で、ブラウザや WebAudio の API を含まない。
だから WASM を経由せず iOS 向けに arm64 で直接ビルドできる。

画面は `dsp/plugins/**/params.json` と `dsp/generated/cpp/*Params.h` から
`Tools/gen_catalog.py` が組み立てる。エフェクトごとに手で書いていないので、
upstream が増えればサブモジュールを進めて生成し直すだけで増える。

- 詰め順は `*Params.h` が決めている。全部 float で、配列は展開され、enum も bool も float に潰れる
- 音のバッファはプレーナ（ch0 のフレームが frames 個、その後 ch1 …）

## 建て方

```bash
git clone --recurse-submodules <このリポジトリ>
bash Scripts/build.sh
```

要るもの:

- Xcode 27 以降
- iOS 27 以降の実機（拡張の entitlement が iOS 27 からなので、シミュレータでは音が流れない）
- Apple Developer Program の所属（`project.yml` の `DEVELOPMENT_TEAM` を自分のものに変える）
- `xcodegen`、`python3` 3.10 以降（どちらも Homebrew で入る）

つないである実機を自動で探す。複数あるときは `DEV_ID=<UDID> bash Scripts/build.sh`。

**macOS の GUI セッションの Terminal から使うこと。** SSH 越しだと
`codesign` が login keychain に届かず `errSecInternalComponent` で落ちる。

### 自分の Apple ID で建てるときに要る登録

`ai.nemut.*` のままでは通らないので、bundle ID を自分のものに変えたうえで、
Apple Developer のポータルで次を作る。

1. **Media Device Sharing Extension** の identifier
   （Identifiers > 新規 > Media Device Sharing Extension）。審査は無い
2. その値を拡張の entitlement と Info.plist の `UTExportedTypeDeclarations` に書く。
   **entitlement の値は要素 1 個の配列**。文字列で書くと拡張が起動しない
3. アプリ 2 本と拡張の App ID

## 仕掛けの詳細

音の横取りをどうやって見つけたか、何が塞がっていたかは
[ios-audio-tap](https://github.com/satomasahiro2005/ios-audio-tap) に書いてある。

## ライセンス

MIT。同梱しているものは [NOTICE.md](NOTICE.md)。
