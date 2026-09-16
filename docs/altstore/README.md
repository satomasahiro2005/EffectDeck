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

1. `python3 ~/asc.py adp-show <version-id>` で ADP の ID と変種を読む
   （通る前は「ADP はまだ無い」＝ `alternativeDistributionPackage` が `data: null`）
2. `GET https://api.altstore.io/adps/<ADP ID>` → `downloadURL` が返る
3. 落として **階層をそのまま** 置く。`manifest.json` は**一切いじらない**
   （各ファイルのハッシュが変わると使えなくなる）
4. `nemut.ai` の `public/effetune-live/adp/` へ置いて push（GitHub Actions が Cloudflare へ出す）

一式は `~/adp_fetch.sh` が 1 から 4 の手前までやる。

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

## federate（explore.alt.store に出す）— **未解決**

`POST https://api.altstore.io/federate` に `{"source": "<URL>"}`。
ドキュメント上は認証も前提条件も無い（`faq.altstore.io/developers/rest-api.md` 逐語:
「Use this endpoint to make your source discoverable on explore.alt.store」、
Request Body は `source` だけ、Response は `HTTP 200 OK`）。

**2026-09-16 時点で 403。ADP を置いても変わらなかった。**

```
{"headers":[],"line":166,"statusCode":403,"file":"AltMarketplaceKit/FederationManager.swift"}
```

### 潰した読み

| 読み | 結果 |
|---|---|
| URL の形が悪い | **外れ。**`https://nemut.ai` / `…/` / `…/source.json` / `www.` の 4 通りとも同じ 403 |
| `downloadURL` が指す `manifest.json` が 404 だから | **外れ。**ADP を置いて 200 になっても 403 のまま |
| ソースが JSON を返していない | 外れ。UA 無し・AltStore・AsyncHTTPClient のどれでも 200 で JSON が返る |

### 残っている 2 つの読み（決める材料が無い）

同じ `line 166` から、渡す URL によって違う番号が返る:

```
{"source":"https://example.com/nope.json"} -> 404
{"source":"https://nemut.ai"}              -> 403
{"source":"not-a-url"}                     -> 500 AsyncHTTPClient.HTTPClientError error 1
```

1. **向こうがこちらの URL を取りに行った状態をそのまま返している。**
   なら `nemut.ai` が向こうの取得元（AWS）に 403 を返している。
   ただしこちらからは UA を変えても 200 で、別のデータセンターから取らせても 200 だった。
   Cloudflare の bot 対策が AWS の帯だけ弾いている可能性は残る。
   **確かめるには Cloudflare の設定を見る必要があるが、いまのトークンは
   `zone (read)` までで WAF を触れない。**
2. **向こうが自分の台帳を引いている。** `example.com` は未登録なので 404、
   `nemut.ai` は登録済みだが federate が許されていないので 403。

### 分かっていること

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
