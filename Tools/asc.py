#!/usr/bin/env python3
"""App Store Connect API を叩く最小の道具。

以前この作業場にあった `asc` が消えていたので書き直した。
鍵は ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8。

  python3 asc.py builds                       ビルドの一覧（新しい順）
  python3 asc.py build <build-id>             1 本の詳細
  python3 asc.py encryption <build-id>        輸出コンプライアンスを「該当なし」にする
  python3 asc.py attach <version-id> <build-id>  版にビルドを結びつける
  python3 asc.py version <version-id>         版の状態
  python3 asc.py versions                     版の一覧（新しい順）
  python3 asc.py new-version <2.9.1>          版を作る（公証用。前の版が
                                              READY_FOR_DISTRIBUTION になると
                                              その版へは二度と出せない）
  python3 asc.py notary                       公証（Notarization）の提出一覧
  python3 asc.py get <path>                   任意の GET（path は /v1/... から）
  python3 asc.py patch <path> <body.json>     任意の PATCH（本体はファイル）
  python3 asc.py post <path> <body.json>      任意の POST
  python3 asc.py delete <path> [body.json]    任意の DELETE
  python3 asc.py resubmit <submission-id>     却下された提出を直したあと出し直す

GitHub Actions の release.yml が使う（どれも読むだけか、内部グループへ足すだけ）:
  python3 asc.py next-build [--floor N]       次のビルド番号（ASC の最大 + 1）を数字だけで出す
  python3 asc.py train-check <版>             版が開いていれば 0、閉じていれば 3
  python3 asc.py wait-build <版> <N> <秒>     処理が VALID になるのを待ち、build の ID を出す
                                              （INVALID/FAILED は 1、時間切れは 4）
  python3 asc.py add-internal <build-id>      ビルドを内部グループ "Internal" に足す
                                              （外部グループには足さない・拒む）
  python3 asc.py cert-ids                     証明書の "id type name" の一覧（読むだけ）
  python3 asc.py profile <名前> <bundle-id> <出力先>
                                              App Store 用プロファイル 1 つを取り <uuid>.mobileprovision に書く。
                                              名前が同じ ACTIVE な IOS_APP_STORE が**ちょうど 1 つ**で、
                                              bundle ID が合い、配布用証明書 DIST_CERT_ID に結ばれているときだけ
                                              通る（読むだけ。uuid を出す）

GitHub Actions の asc-ops.yml が使う（書く。main から手で回すだけ）:
  python3 asc.py regen-profile <名前> <bundle-id>
                                              bundle ID に INTER_APP_AUDIO が無ければ足し、同じ名前の
                                              プロファイルを（状態を問わず）全部消して、IOS_APP_STORE を
                                              配布用証明書 DIST_CERT_ID で作り直す。id と状態を出す
  python3 asc.py beta-submit <build-id>       Tools/beta_notes.txt を en-US の What to Test に書き、
                                              輸出コンプライアンスが未設定なら「該当なし」にし、外部グループ
                                              "EffectDeck Public Beta" に足して、TestFlight の審査へ出す
                                              （出してあれば出し直さない）。betaReviewState を出す

KEY_ID と ISSUER は環境変数 ASC_KEY_ID・ASC_ISSUER_ID で上書きできる（既定は下の値）。
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

KEY_ID = os.environ.get("ASC_KEY_ID") or "JYMYS92KUB"
ISSUER = os.environ.get("ASC_ISSUER_ID") or "175cb308-6a31-42f0-970a-e72757f60bde"
KEY = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{KEY_ID}.p8"
APP = "6812467517"
# 配布用証明書（Apple Distribution: Masahiro Sato）。release.yml が runner に入れる p12 はこれ。
# プロファイルがこの証明書に結ばれていなければ、署名しても配布に使えない。
DIST_CERT_ID = "4CGZ2DSM55"
BASE = "https://api.appstoreconnect.apple.com"
# TestFlight の外部グループ（審査を通してから配る相手）。beta-submit はここにだけ足す。
PUBLIC_BETA_GROUP = "EffectDeck Public Beta"
# What to Test の本文（en-US）。beta-submit が読む。
BETA_NOTES = Path(__file__).resolve().parent / "beta_notes.txt"


def token() -> str:
    """ES256 の JWT を作る。

    PyJWT が入っていないので openssl で署名する。
    ヘッダとペイロードは base64url、署名は DER から R||S へ直す。
    """
    import base64
    import struct

    def b64(d: bytes) -> str:
        return base64.urlsafe_b64encode(d).decode().rstrip("=")

    header = b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"},
                            separators=(",", ":")).encode())
    now = int(time.time())
    payload = b64(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 1200,
                              "aud": "appstoreconnect-v1"},
                             separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()

    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(KEY)],
        input=signing_input, capture_output=True, check=True).stdout

    # DER (SEQUENCE { INTEGER r, INTEGER s }) を 32 バイトずつの生の値へ。
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7F) - 1
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        ln = der[i + 1]
        v = der[i + 2: i + 2 + ln].lstrip(b"\x00")
        out += b"\x00" * (32 - len(v)) + v
        i += 2 + ln
    return f"{header}.{payload}.{b64(out)}"


def call(method: str, path: str, body=None):
    req = urllib.request.Request(
        BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token()}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        print(f"!! HTTP {e.code} {path}", file=sys.stderr)
        print(raw[:2000], file=sys.stderr)
        raise SystemExit(1)


# ---- GitHub Actions（release.yml）が使う部品 ----------------------------------

# 「この版の列車は閉じた」とみなす版の状態。閉じた版番号（以下）には、もうビルドを足せない。
# 新しい名前（appVersionState）と古い名前（appStoreState）の両方を見る。
CLOSED_STATES = {
    "ACCEPTED", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE",
    "PROCESSING_FOR_DISTRIBUTION", "READY_FOR_DISTRIBUTION",
    "REPLACED_WITH_NEW_VERSION",
    "READY_FOR_SALE", "PROCESSING_FOR_APP_STORE", "PREORDER_READY_FOR_SALE",
}


def vtuple(s: str):
    """版の文字列を数の組へ。数字とドットだけでなければ文字列のまま（等しいか、だけ比べる）。"""
    try:
        return tuple(int(x) for x in s.split("."))
    except (ValueError, AttributeError):
        return s


def pages(path: str):
    """links.next を辿って data を全部返す。"""
    out = []
    while path:
        d = call("GET", path)
        out.extend(d.get("data", []))
        nxt = (d.get("links") or {}).get("next")
        path = nxt[len(BASE):] if nxt and nxt.startswith(BASE) else None
    return out


def next_build(floor: int = 0) -> int:
    """ASC にある最大のビルド番号 + 1。処理中・失敗した upload も数える（番号は再利用できない）。"""
    nums = [floor]
    for b in pages(f"/v1/builds?filter[app]={APP}&fields[builds]=version&limit=200"):
        v = (b.get("attributes") or {}).get("version")
        if v and str(v).isdigit():
            nums.append(int(v))
    for u in pages(f"/v1/apps/{APP}/buildUploads?limit=200"):
        v = (u.get("attributes") or {}).get("cfBundleVersion")
        if v and str(v).isdigit():
            nums.append(int(v))
    return max(nums) + 1


def closed_train(version: str):
    """version 以上の版が承認済みの状態にあれば (その版, 状態)。無ければ None。"""
    want = vtuple(version)
    for v in pages(f"/v1/apps/{APP}/appStoreVersions?limit=200"):
        a = v.get("attributes") or {}
        if a.get("platform") not in (None, "IOS"):
            continue
        hit = sorted(({a.get("appVersionState"), a.get("appStoreState")} - {None}) & CLOSED_STATES)
        if not hit:
            continue
        state = hit[0]
        got = vtuple(a.get("versionString") or "")
        if got == want or (isinstance(got, tuple) and isinstance(want, tuple) and got >= want):
            return a.get("versionString"), state
    return None


def internal_group_id() -> str:
    """名前が Internal で、内部グループであるものの ID。ちょうど 1 つでなければ止まる。"""
    # This relationship endpoint does not accept filter[name]. Fetch all pages
    # and match locally, retaining the unique-name and internal-only checks.
    groups = [g for g in pages(f"/v1/apps/{APP}/betaGroups?limit=200")
              if (g.get("attributes") or {}).get("name") == "Internal"]
    if len(groups) != 1:
        print(f"!! Internal という名前のグループが {len(groups)} 個ある（1 個のはず）", file=sys.stderr)
        raise SystemExit(1)
    if not (groups[0].get("attributes") or {}).get("isInternalGroup"):
        print("!! Internal が内部グループではない。外部グループには足さない", file=sys.stderr)
        raise SystemExit(1)
    return groups[0]["id"]


def fetch_profile(name: str, bundle_id: str, out_dir: str) -> str:
    """名前 name の App Store 用プロファイルを 1 つ取って <uuid>.mobileprovision に書き、uuid を返す。

    ACTIVE な IOS_APP_STORE で名前が一致するものがちょうど 1 つ、その bundle ID が bundle_id、
    結ばれた証明書に DIST_CERT_ID が入っていること。どれか欠けたら何も書かず SystemExit(1)。
    """
    import base64
    import re
    import urllib.parse

    def fail(msg: str):
        print(f"!! {msg}", file=sys.stderr)
        raise SystemExit(1)

    q = urllib.parse.quote(name, safe="")
    d = call("GET", f"/v1/profiles?filter[name]={q}&include=bundleId,certificates&limit=200")
    hits = [p for p in d.get("data", [])
            if (p.get("attributes") or {}).get("name") == name
            and (p.get("attributes") or {}).get("profileState") == "ACTIVE"
            and (p.get("attributes") or {}).get("profileType") == "IOS_APP_STORE"]
    if len(hits) != 1:
        fail(f"プロファイル {name} の ACTIVE な IOS_APP_STORE が {len(hits)} 個ある（1 個のはず）")
    prof = hits[0]
    rel = prof.get("relationships") or {}
    bid = ((rel.get("bundleId") or {}).get("data") or {}).get("id")
    included = d.get("included", [])
    ident = next(((i.get("attributes") or {}).get("identifier") for i in included
                  if i.get("type") == "bundleIds" and i.get("id") == bid), None)
    if ident != bundle_id:
        fail(f"プロファイル {name} の bundle ID は {ident}（{bundle_id} のはず）")
    certs = {c.get("id") for c in (rel.get("certificates") or {}).get("data") or []}
    if DIST_CERT_ID not in certs:
        fail(f"プロファイル {name} に配布用証明書 {DIST_CERT_ID} が結ばれていない（{sorted(certs)}）")
    a = prof.get("attributes") or {}
    uuid, content = a.get("uuid"), a.get("profileContent")
    if not uuid or not re.fullmatch(r"[0-9A-Fa-f-]{36}", uuid) or not content:
        fail(f"プロファイル {name} に uuid か中身が無い")
    try:
        raw = base64.b64decode(content, validate=True)
    except ValueError:
        fail(f"プロファイル {name} の中身が base64 でない")
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{uuid}.mobileprovision").write_bytes(raw)
    return uuid


def _fail(msg: str):
    print(f"!! {msg}", file=sys.stderr)
    raise SystemExit(1)


def regen_profile(name: str, bundle_id: str) -> dict:
    """bundle_id の App Store 用プロファイル name を作り直し、新しいプロファイルの data を返す。

    1) bundle ID に INTER_APP_AUDIO の capability が無ければ足す（無いままだとプロファイルに
       inter-app-audio が入らず、本体の entitlements と合わない）。
    2) 名前が name と完全に一致するプロファイルを状態を問わず全部消す（ASC は同じ名前を許さない）。
    3) IOS_APP_STORE を DIST_CERT_ID に結んで作る。
    """
    import urllib.parse

    q = urllib.parse.quote(bundle_id, safe="")
    bids = [b for b in pages(f"/v1/bundleIds?filter[identifier]={q}&limit=200")
            if (b.get("attributes") or {}).get("identifier") == bundle_id]
    if len(bids) != 1:
        _fail(f"bundle ID {bundle_id} が {len(bids)} 個ある（1 個のはず）")
    bid = bids[0]["id"]

    caps = pages(f"/v1/bundleIds/{bid}/bundleIdCapabilities")
    if any((c.get("attributes") or {}).get("capabilityType") == "INTER_APP_AUDIO" for c in caps):
        print(f"{bundle_id}: INTER_APP_AUDIO はもうある", file=sys.stderr)
    else:
        call("POST", "/v1/bundleIdCapabilities",
             {"data": {"type": "bundleIdCapabilities",
                       "attributes": {"capabilityType": "INTER_APP_AUDIO"},
                       "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}}}})
        print(f"{bundle_id}: INTER_APP_AUDIO を足した", file=sys.stderr)

    qn = urllib.parse.quote(name, safe="")
    old = [p for p in pages(f"/v1/profiles?filter[name]={qn}&limit=200")
           if (p.get("attributes") or {}).get("name") == name]
    for p in old:
        call("DELETE", f"/v1/profiles/{p['id']}")
        print(f"古いプロファイル {p['id']}（{(p.get('attributes') or {}).get('profileState')}）を消した",
              file=sys.stderr)

    d = call("POST", "/v1/profiles",
             {"data": {"type": "profiles",
                       "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                       "relationships": {
                           "bundleId": {"data": {"type": "bundleIds", "id": bid}},
                           "certificates": {"data": [{"type": "certificates", "id": DIST_CERT_ID}]}}}})
    return d.get("data") or {}


def public_beta_group_id() -> str:
    """名前が PUBLIC_BETA_GROUP の外部グループの ID。ちょうど 1 つで、内部グループでないこと。"""
    groups = [g for g in pages(f"/v1/apps/{APP}/betaGroups?limit=200")
              if (g.get("attributes") or {}).get("name") == PUBLIC_BETA_GROUP]
    if len(groups) != 1:
        _fail(f"{PUBLIC_BETA_GROUP} という名前のグループが {len(groups)} 個ある（1 個のはず）")
    if (groups[0].get("attributes") or {}).get("isInternalGroup"):
        _fail(f"{PUBLIC_BETA_GROUP} が内部グループになっている（外部グループのはず）")
    return groups[0]["id"]


def beta_submit(build_id: str) -> str:
    """build_id を外部テストの審査へ出し、betaReviewState を返す。"""
    try:
        notes = BETA_NOTES.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        _fail(f"{BETA_NOTES} が無い（What to Test の本文）")
    if not notes:
        _fail(f"{BETA_NOTES} が空")
    if len(notes) > 4000:
        _fail(f"{BETA_NOTES} が {len(notes)} 字（4000 字まで）")

    # 外部グループを先に確かめる（無い・2 つある・内部になっているなら何も書かずに止まる）。
    gid = public_beta_group_id()

    # 1) What to Test（en-US）。あれば書き換え、無ければ作る。
    locs = pages(f"/v1/builds/{build_id}/betaBuildLocalizations?limit=50")
    en = [l for l in locs if (l.get("attributes") or {}).get("locale") == "en-US"]
    if en:
        call("PATCH", f"/v1/betaBuildLocalizations/{en[0]['id']}",
             {"data": {"type": "betaBuildLocalizations", "id": en[0]["id"],
                       "attributes": {"whatsNew": notes}}})
        print("What to Test（en-US）を書き換えた", file=sys.stderr)
    else:
        call("POST", "/v1/betaBuildLocalizations",
             {"data": {"type": "betaBuildLocalizations",
                       "attributes": {"locale": "en-US", "whatsNew": notes},
                       "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        print("What to Test（en-US）を作った", file=sys.stderr)

    # 2) 輸出コンプライアンス。未設定のときだけ「該当なし」。
    attrs = (call("GET", f"/v1/builds/{build_id}").get("data") or {}).get("attributes") or {}
    if attrs.get("usesNonExemptEncryption") is None:
        call("PATCH", f"/v1/builds/{build_id}",
             {"data": {"type": "builds", "id": build_id,
                       "attributes": {"usesNonExemptEncryption": False}}})
        print("usesNonExemptEncryption = false にした", file=sys.stderr)

    # 3) 外部グループへ。
    call("POST", f"/v1/betaGroups/{gid}/relationships/builds",
         {"data": [{"type": "builds", "id": build_id}]})
    print(f"{PUBLIC_BETA_GROUP} ({gid}) に足した", file=sys.stderr)

    # 4) 審査の提出。ビルドにもうあれば作らない。
    subs = call("GET", f"/v1/betaAppReviewSubmissions?filter[build]={build_id}&limit=5").get("data") or []
    if subs:
        sub = subs[0]
        print(f"審査の提出はもうある（{sub.get('id')}）", file=sys.stderr)
    else:
        sub = call("POST", "/v1/betaAppReviewSubmissions",
                   {"data": {"type": "betaAppReviewSubmissions",
                             "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}}
                   ).get("data") or {}
        print(f"審査へ出した（{sub.get('id')}）", file=sys.stderr)
    return (sub.get("attributes") or {}).get("betaReviewState") or "?"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]

    if cmd == "next-build":
        floor = 0
        if len(sys.argv) > 3 and sys.argv[2] == "--floor":
            floor = int(sys.argv[3])
        print(next_build(floor))
        return 0

    if cmd == "train-check":
        version = sys.argv[2]
        hit = closed_train(version)
        if hit:
            print(f"!! MARKETING_VERSION {version} は閉じている（{hit[0]} が {hit[1]}）。"
                  "python3 Tools/gen_version.py --today を回して main へ入れ、CI が通ってから"
                  "もう一度タグを打つ", file=sys.stderr)
            return 3
        print(f"版 {version} は開いている")
        return 0

    if cmd == "wait-build":
        version, num, limit = sys.argv[2], sys.argv[3], int(sys.argv[4])
        deadline = time.time() + limit
        while True:
            d = call("GET", f"/v1/builds?filter[app]={APP}&filter[version]={num}"
                            f"&filter[preReleaseVersion.version]={version}&limit=5")
            for b in d.get("data", []):
                state = (b.get("attributes") or {}).get("processingState")
                if state == "VALID":
                    print(b["id"])
                    return 0
                if state in ("INVALID", "FAILED"):
                    print(f"!! build {num} が {state} になった", file=sys.stderr)
                    return 1
            if time.time() >= deadline:
                print(f"!! build {num} の処理が {limit} 秒で終わらない", file=sys.stderr)
                return 4
            time.sleep(30)

    if cmd == "add-internal":
        # 内部グループ（Internal）だけ。グループ ID は引数に取らない。外部グループ
        # （EffectDeck Public Beta）への追加と審査への提出は本人が手でやる。
        gid = internal_group_id()
        call("POST", f"/v1/betaGroups/{gid}/relationships/builds",
             {"data": [{"type": "builds", "id": sys.argv[2]}]})
        print(f"build {sys.argv[2]} を内部グループ Internal ({gid}) に足した")
        return 0

    if cmd == "cert-ids":
        for c in pages("/v1/certificates?limit=200"):
            a = c.get("attributes") or {}
            print(c["id"], a.get("certificateType"), a.get("name"))
        return 0

    if cmd == "profile":
        print(fetch_profile(sys.argv[2], sys.argv[3], sys.argv[4]))
        return 0

    if cmd == "regen-profile":
        p = regen_profile(sys.argv[2], sys.argv[3])
        print(p.get("id"), (p.get("attributes") or {}).get("profileState"))
        return 0

    if cmd == "beta-submit":
        print(beta_submit(sys.argv[2]))
        return 0

    if cmd == "builds":
        d = call("GET", f"/v1/builds?filter[app]={APP}&limit=10"
                        "&sort=-uploadedDate")
        for b in d.get("data", []):
            a = b["attributes"]
            print(f'{b["id"]}  build {a.get("version"):>3}  '
                  f'{a.get("processingState"):<12} {a.get("uploadedDate")} '
                  f'expired={a.get("expired")}')
        return 0

    if cmd == "build":
        d = call("GET", f"/v1/builds/{sys.argv[2]}")
        print(json.dumps(d["data"]["attributes"], indent=2, ensure_ascii=False))
        return 0

    if cmd == "encryption":
        call("PATCH", f"/v1/builds/{sys.argv[2]}",
             {"data": {"type": "builds", "id": sys.argv[2],
                       "attributes": {"usesNonExemptEncryption": False}}})
        print("ok")
        return 0

    if cmd == "attach":
        vid, bid = sys.argv[2], sys.argv[3]
        call("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build",
             {"data": {"type": "builds", "id": bid}})
        print("ok")
        return 0

    if cmd == "version":
        d = call("GET", f"/v1/appStoreVersions/{sys.argv[2]}")
        print(json.dumps(d["data"]["attributes"], indent=2, ensure_ascii=False))
        return 0

    if cmd == "versions":
        d = call("GET", f"/v1/apps/{APP}/appStoreVersions?limit=20")
        for v in d.get("data", []):
            a = v["attributes"]
            print(f'{v["id"]}  {a.get("versionString"):<8} '
                  f'{a.get("appVersionState"):<24} {a.get("createdDate")}')
        return 0

    if cmd == "new-version":
        # 公証は版ごと。前の版が READY_FOR_DISTRIBUTION になったら、
        # ビルドを差し替えて出し直すことはできない（版を作る）。
        # reviewType を NOTARIZATION にしないと App Store の審査になる。
        d = call("POST", "/v1/appStoreVersions",
                 {"data": {"type": "appStoreVersions",
                           "attributes": {"platform": "IOS",
                                          "versionString": sys.argv[2],
                                          "reviewType": "NOTARIZATION",
                                          "releaseType": "AFTER_APPROVAL",
                                          "copyright": "2026 nemut.ai"},
                           "relationships": {"app": {"data": {
                               "type": "apps", "id": APP}}}}})
        print(d["data"]["id"])
        return 0

    if cmd == "notary":
        d = call("GET", "/v1/notarizationSubmissions?limit=10")
        for s in d.get("data", []):
            a = s["attributes"]
            print(f'{s["id"]}  {a.get("status"):<22} {a.get("createdDate")}')
        return 0

    if cmd == "cancel":
        # 審査待ちの提出を取り下げる。審査に入る前しか通らない。
        sid = sys.argv[2]
        call("PATCH", f"/v1/reviewSubmissions/{sid}",
             {"data": {"type": "reviewSubmissions", "id": sid,
                       "attributes": {"canceled": True}}})
        print("ok")
        return 0

    if cmd == "submit":
        # 版を審査（公証）へ出す。1) 提出を作る 2) 版を項目として足す 3) 出す
        vid = sys.argv[2]
        d = call("POST", "/v1/reviewSubmissions",
                 {"data": {"type": "reviewSubmissions",
                           "attributes": {"platform": "IOS"},
                           "relationships": {"app": {"data": {
                               "type": "apps", "id": APP}}}}})
        sid = d["data"]["id"]
        print("submission", sid)
        call("POST", "/v1/reviewSubmissionItems",
             {"data": {"type": "reviewSubmissionItems",
                       "relationships": {
                           "reviewSubmission": {"data": {
                               "type": "reviewSubmissions", "id": sid}},
                           "appStoreVersion": {"data": {
                               "type": "appStoreVersions", "id": vid}}}}})
        call("PATCH", f"/v1/reviewSubmissions/{sid}",
             {"data": {"type": "reviewSubmissions", "id": sid,
                       "attributes": {"submitted": True}}})
        print("submitted")
        return 0

    if cmd == "resubmit":
        # 却下された提出（UNRESOLVED_ISSUES）を直したあと出し直す。
        # **項目を resolved にしてからでないと** submitted が
        # 「Version is not ready to be submitted yet」の 409 で断られ続ける
        # （2026.09.28 で 25 分それを待った）。
        sid = sys.argv[2]
        for item in call("GET", f"/v1/reviewSubmissions/{sid}/items")["data"]:
            if item["attributes"].get("state") in ("REJECTED", "UNRESOLVED_ISSUES"):
                call("PATCH", f"/v1/reviewSubmissionItems/{item['id']}",
                     {"data": {"type": "reviewSubmissionItems", "id": item["id"],
                               "attributes": {"resolved": True}}})
        d = call("PATCH", f"/v1/reviewSubmissions/{sid}",
                 {"data": {"type": "reviewSubmissions", "id": sid,
                           "attributes": {"submitted": True}}})
        print(d["data"]["attributes"].get("state"))
        return 0

    if cmd == "submissions":
        d = call("GET", f"/v1/apps/{APP}/reviewSubmissions?limit=5")
        for s2 in d.get("data", []):
            a = s2["attributes"]
            print(s2["id"], a.get("state"), a.get("submittedDate"))
        return 0

    if cmd == "adp-create":
        # 代替配布パッケージを作る。公証が通ってからでないと通らない。
        vid = sys.argv[2]
        d = call("POST", "/v1/alternativeDistributionPackages",
                 {"data": {"type": "alternativeDistributionPackages",
                           "relationships": {"appStoreVersion": {"data": {
                               "type": "appStoreVersions", "id": vid}}}}})
        print(json.dumps(d, indent=2, ensure_ascii=False))
        return 0

    if cmd == "adp-show":
        # 版 → ADP → その版 → 変種（url と fileChecksum を持つ）まで辿る。
        vid = sys.argv[2]
        d = call("GET", f"/v1/appStoreVersions/{vid}/alternativeDistributionPackage")
        if not d.get("data"):
            print("ADP はまだ無い")
            return 0
        aid = d["data"]["id"]
        print("adp", aid)
        vs = call("GET", f"/v1/alternativeDistributionPackages/{aid}/versions")
        for v in vs.get("data", []):
            print(" version", v["id"], json.dumps(v["attributes"], ensure_ascii=False))
            va = call("GET",
                      f"/v1/alternativeDistributionPackageVersions/{v['id']}/variants")
            for x in va.get("data", []):
                print("   variant", x["id"],
                      json.dumps(x["attributes"], ensure_ascii=False))
        return 0

    if cmd == "adp-url":
        # ADP の zip の URL だけを出す。ASC が直接くれる（期限つき）。
        vid = sys.argv[2]
        d = call("GET", f"/v1/appStoreVersions/{vid}/alternativeDistributionPackage")
        if not d.get("data"):
            print("!! ADP はまだ無い", file=sys.stderr)
            return 1
        aid = d["data"]["id"]
        vs = call("GET", f"/v1/alternativeDistributionPackages/{aid}/versions")
        for v in vs.get("data", []):
            a = v["attributes"]
            if a.get("state") == "COMPLETED" and a.get("url"):
                print(a["url"])
                return 0
        print("!! COMPLETED の版が無い", file=sys.stderr)
        return 1

    if cmd == "adp-variants":
        # 変種を "publicId<TAB>url" で出す。manifest の assetPath と対で使う。
        vid = sys.argv[2]
        d = call("GET", f"/v1/appStoreVersions/{vid}/alternativeDistributionPackage")
        if not d.get("data"):
            print("!! ADP はまだ無い", file=sys.stderr)
            return 1
        aid = d["data"]["id"]
        vs = call("GET", f"/v1/alternativeDistributionPackages/{aid}/versions")
        for v in vs.get("data", []):
            if v["attributes"].get("state") != "COMPLETED":
                continue
            va = call("GET",
                      f"/v1/alternativeDistributionPackageVersions/{v['id']}/variants")
            for x in va.get("data", []):
                print(f'{x["id"]}	{x["attributes"]["url"]}')
        return 0

    if cmd == "get":
        print(json.dumps(call("GET", sys.argv[2]), indent=2, ensure_ascii=False))
        return 0

    if cmd == "delete":
        # 関係を外す DELETE は本体が要る（betaGroups の builds など）。
        body = None
        if len(sys.argv) > 3:
            body = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
        d = call("DELETE", sys.argv[2], body)
        print(json.dumps(d, indent=2, ensure_ascii=False) if d else "ok")
        return 0

    if cmd in ("patch", "post"):
        # 任意の PATCH / POST。本体は JSON のファイルで渡す。
        # 引数に JSON を直接書くと ssh 越しの引用符で必ず壊れる。
        body = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
        d = call(cmd.upper(), sys.argv[2], body)
        print(json.dumps(d, indent=2, ensure_ascii=False))
        return 0

    print(__doc__)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
