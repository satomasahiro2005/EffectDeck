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
"""
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

KEY_ID = "JYMYS92KUB"
ISSUER = "175cb308-6a31-42f0-970a-e72757f60bde"
KEY = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{KEY_ID}.p8"
APP = "6812467517"
BASE = "https://api.appstoreconnect.apple.com"


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


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]

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
