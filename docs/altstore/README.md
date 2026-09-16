# AltStore PAL で配るまでの手順

**推測を書かない。** 各行の出どころは faq.altstore.io と App Store Connect API の実測。

## 道具

`asc.py`（Mac の `~/asc.py`）。以前この作業場にあった `asc` が消えていたので書き直した。
鍵は `~/.appstoreconnect/private_keys/AuthKey_JYMYS92KUB.p8`。
JWT は PyJWT を使わず `openssl dgst -sha256 -sign` で署名して、DER を R‖S へ直している。

```
python3 ~/asc.py builds                        ビルドの一覧
python3 ~/asc.py encryption <build-id>         輸出コンプライアンスを「該当なし」に
python3 ~/asc.py attach <version-id> <build-id> 版にビルドを結びつける
python3 ~/asc.py version <version-id>          版の状態
python3 ~/asc.py cancel <submission-id>        審査待ちの提出を取り下げる
python3 ~/asc.py submit <version-id>           版を審査（公証）へ出す
python3 ~/asc.py submissions                   提出の一覧
python3 ~/asc.py adp-show <version-id>         ADP → その版 → 変種まで辿る
```

固定値:

| | |
|---|---|
| app | `6812467517` |
| version (2.9.0) | `51742091-f729-4a5a-8147-66077fa0164b` |
| key / issuer | `JYMYS92KUB` / `175cb308-6a31-42f0-970a-e72757f60bde` |

## 順番

1. **上げる**（`Scripts/archive.sh` → `xcodebuild -exportArchive` → `xcrun altool --upload-app`）
   `altool` は `--apiKey` / `--apiIssuer` で通る。`asc` は要らない。
2. **`usesNonExemptEncryption` を false に**。一度立てると二度目は 409 になる（`You cannot update when the value is already set.`）
3. **版に結びつける**。**審査待ちの間は差し替えられない**
   （409 `The specified pre-release build could not be added.`）。
   差し替えるなら先に `cancel` してから。取り下げると版は `DEVELOPER_REJECTED` になり、
   そこで `attach` が通る
4. **`submit`**。3 段階（提出を作る → 版を項目として足す → `submitted: true`）
5. **公証の承認を待つ**。`appVersionState` が `WAITING_FOR_REVIEW` から動く

## ADP（Alternative Distribution Package）

**自分で作るものではない。公証のときに Apple が生成する。**

> **`GET https://api.altstore.io/adps/<ADP ID>` は使わない。** ASC の ADP ID を渡すと
> 404 が返る（`{"statusCode":404,"file":"AltMarketplaceKit/GetADP.swift","line":33}`）。
> **ASC が zip の URL を直接くれる**ので、そちらから落とす。

1. `python3 ~/asc.py adp-url <version-id>` で zip の URL を取る
   （通る前は「ADP はまだ無い」＝ `alternativeDistributionPackage` が `data: null`）
2. 落として展開する。**中身は `manifest.json` と `signature` の 2 つだけ**（約 3KB）
3. `manifest.json` が `variant/<publicId>.ipa` を**相対で**指しているので、
   `python3 ~/asc.py adp-variants <version-id>` が出す URL から
   その 2 本も落として同じ階層に置く。
   落としたら sha256 が ASC の `fileChecksum` と一致するか見る
4. `python3 Tools/adp_place.py <pkg のディレクトリ>` で
   `new-nemutai/public/effetune-live/adp/` へ階層のまま写し、`source.json` の
   `size` を変種の実寸に合わせる。**`manifest.json` は一切いじらない**
   （各ファイルのハッシュが変わると使えなくなる）
5. `new-nemutai` を commit して push（GitHub Actions が Cloudflare へ出す）

1 から 3 は `~/adp_fetch.sh` にしてある。
zip の URL には `accessKey` が付いていて **2 日で切れる**（`urlExpirationDate`）。

## source.json

| 欄 | 何を入れるか（逐語） |
|---|---|
| `downloadURL` | 「The URL of the `manifest.json` in your uploaded ADP, or the root directory of the ADP itself.」 |
| `size` | 「The size of your app in bytes.」「For ADPs you can pick any of the variants from your `variant` folder to determine the size.」 |
| `fediUsername` | explore.alt.store の口座名になる。**後から変えられない**（`nemutai` で確定済み） |

## `nemut.ai` と打つだけで出るようにする

AltStore はソースの URL をそのまま取りに行き、`/source.json` のようなパスを補わない。
`new-nemutai/src/worker.js` がルートで出し分けている:

- UA に `AltStore` が入る、または `Accept` に `application/json` が入る → ソースの JSON
- それ以外 → いつものサイト

`Vary: User-Agent, Accept` だけだと Cloudflare の縁が片方を掴んだまま返し続けたので、
`Cache-Control: no-store` も付けてある。

実測（2026-09-16）:

```
curl -H "User-Agent: AltStore/2.0" https://nemut.ai/   → 200 application/json
curl -H "User-Agent: Mozilla/5.0"  https://nemut.ai/   → 200 text/html
curl                               https://nemut.ai/source.json → 200 application/json
```

## federate（explore.alt.store に出す）

`POST https://api.altstore.io/federate` に `{"source": "<URL>"}`。
ドキュメント上は認証も前提条件も無い（`faq.altstore.io/developers/rest-api.md` 逐語:
「Use this endpoint to make your source discoverable on explore.alt.store」、
Request Body は `source` だけ、Response は `HTTP 200 OK`）。

**2026-09-16 に通った。受理の返事は `The source is pending approval.`**

### 403 の正体は Cloudflare の Bot fight mode だった

向こう（AWS）がこちらの URL を取りに行った結果をそのまま返していた。
`nemut.ai` の Security → Settings → **Bot fight mode が ON** で、AWS の帯を
403 で弾いていた。**Worker より前に走るので Worker では直せない。**
ダッシュボードで OFF にしたら federate が 200 を返した。**戻すとまた 403 になる。**

こちらから `curl` で 200 が返っていたのは、ブラウザや curl の指紋が
bot 判定を通っていただけ。「別のデータセンターから取らせても 200」も、
そこが AWS ではなかったため。

### 外れた読み（記録として残す）

| 読み | 結果 |
|---|---|
| URL の形が悪い | 外れ。`https://nemut.ai` / `…/` / `…/source.json` / `www.` の 4 通りとも同じ 403 |
| `downloadURL` が指す `manifest.json` が 404 だから | 外れ。ADP を置いて 200 になっても 403 のまま |
| ソースが JSON を返していない | 外れ。UA 無し・AltStore・AsyncHTTPClient のどれでも 200 で JSON が返る |
| 向こうが自分の台帳を引いている | 外れ。取りに来ていた |

**federate は「探せるようにする」だけで、入れるのには要らない。**
`nemut.ai` と打てばソースは出るし、そこから ADP まで繋がっている（下記）。

## 通し確認（2026-09-16）

```
curl -H "User-Agent: AltStore/2.0" https://nemut.ai/            200 application/json
curl https://nemut.ai/effetune-live/adp/manifest.json           200 4096
curl https://nemut.ai/effetune-live/adp/signature               200 2757
curl https://nemut.ai/effetune-live/adp/variant/<publicId>.ipa  200 9452894
```

変種 2 本の sha256 は ASC の `fileChecksum` と一致:

```
842593beafd659e41279d3114f10c963410bfb8d62c37dd864239b7f706c53b6  10a19580-…ipa
400406cdc0f5f0f2ed0a266371d01ee9cf9d506a94ed9b52707ebdfa00e0db47  152dd787-…ipa
```

`source.json` は 2.9.0 / build 10 / `downloadURL` が `adp/manifest.json` /
`size` が 9452894（変種の実寸）。

## 署名で詰まったとき（2026-09-17）

**`errSecInternalComponent` はパスワードの話ではない。**
配布用の証明書が `login` と `effetune-release` の**両方**に入っていて、
セッションが両方を見ていた。`security find-identity -v -p codesigning` に
同じ `Apple Distribution: Masahiro Sato (C82ST8T9MN)` が 4 つ並び、
codesign が選べずに落ちていた。

そのセッションの検索リストを login だけに絞ると通る:

```bash
security list-keychains -s ~/Library/Keychains/login.keychain-db
```

**`-d user` で書き換えても効かない。** あれは利用者ドメインを書くだけで、
もう開いている Aqua セッションの一覧は変わらない。署名するセッションの中で
撃つこと（`~/gui_export.sh` と `~/gui_ship.sh` の頭に入れてある）。

外れた読み:

| 読み | 結果 |
|---|---|
| `effetune-release` のパスワードが違う | 外れ。ssh からは `~/signing/kc.pw` で開く |
| キーチェーンが自動で再ロックされている | 外れ。`no-timeout` にしても変わらない |
| 鍵の ACL（`set-key-partition-list`）が足りない | 外れ。入れても同じ |

GUI セッションで `security unlock-keychain` が「パスフレーズが違う」と
言っていたのは、SecurityAgent のダイアログが出て消された結果
（errSecAuthFailed=51）。**開けるのは ssh から 1 回だけにして、
GUI の側で unlock を撃たない。**

## Cloudflare が配布を 2 回壊している

**nemut.ai の Cloudflare は Worker より前に走る層を持っていて、そこで落ちると
コードでは直せない。**2 回とも症状が「こちらからは取れるのに、向こうからは取れない」
で、原因が見えにくかった。

| いつ | 何が | 症状 | 直し方 |
|---|---|---|---|
| 2026-09-16 | **Bot fight mode** | `federate` が 403。向こう（AWS）がソースを取りに来て弾かれていた | Security → Settings で OFF |
| 2026-09-17 | **Hotlink Protection** | AltStore の頁でアプリのアイコンが出ない。画像が `error code: 1011` で 403 | Configuration Rule で `effetune-live/*` だけ OFF |

### Hotlink Protection の見分け方

Referer で分かれる。**Referer が無ければ通る**ので、curl でも Discord の埋め込み
クローラーでも取れてしまう。落ちるのは**ブラウザが他所のページから読むとき**だけ。

```bash
curl -sS -o /dev/null -w "%{http_code}\n"                        https://nemut.ai/effetune-live/icon.png   # 200
curl -sS -o /dev/null -w "%{http_code}\n" -e https://altstore.io/ https://nemut.ai/effetune-live/icon.png   # 403
curl -sS                                  -e https://altstore.io/ https://nemut.ai/effetune-live/icon.png   # error code: 1011
```

`1011` が Hotlink Protection。`1010` は Browser Integrity Check なので別物。

### 入れたルール

Rules → Configuration Rules に 1 本:

```
名前   effetune-live: allow hotlinking
条件   (http.request.full_uri wildcard r"https://nemut.ai/effetune-live/*")
設定   Hotlink Protection = OFF
```

**サイト全体は切っていない。**配布用の画像だけ他所から読めればよく、
残りは守られたままにしたいので。

### 触れないもの

`wrangler` のトークンは `zone (read)` までで、**ゾーンの設定を API から変えられない**。
この手の直しはダッシュボードを開くしかない。
