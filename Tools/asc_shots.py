#!/usr/bin/env python3
"""App Store のスクリーンショットを入れ替える。Mac の上で走らせる。

  python3 Tools/asc_shots.py <版の id> <画像…>

いま入っているものを消して、渡した順に入れ直す。
6.9 インチ（1320x2868）の組に入れる。Apple は他のサイズへ自動で縮める。

上げ方は 3 段。ここを 1 段でも飛ばすと、ASC の画面では「処理中」のまま止まる。
  1. POST /v1/appScreenshots  … 枠を取る。返ってくる uploadOperations が上げ先
  2. 各 operation の url へ PUT … 分割されていることがあるので全部やる
  3. PATCH … uploaded=true と md5 を送る。ここで初めて Apple が中身を見る
"""
import hashlib
import json
import os
import pathlib
import sys
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import asc  # noqa: E402

# 既定は 6.7/6.9 の組。iPad は ETSHOT_DISPLAY=APP_IPAD_PRO_3GEN_129 で切り替える。
DISPLAY = os.environ.get("ETSHOT_DISPLAY", "APP_IPHONE_67")


def put(op: dict, blob: bytes) -> None:
    chunk = blob[op["offset"]: op["offset"] + op["length"]]
    req = urllib.request.Request(op["url"], method=op["method"], data=chunk)
    for h in op.get("requestHeaders", []):
        req.add_header(h["name"], h["value"])
    with urllib.request.urlopen(req) as r:
        if r.status not in (200, 201, 204):
            raise SystemExit("!! PUT %s" % r.status)


def main() -> int:
    vid = sys.argv[1]
    files = [pathlib.Path(p) for p in sys.argv[2:]]
    if not files:
        print("!! 画像が無い", file=sys.stderr)
        return 1
    for f in files:
        if not f.is_file():
            print("!! 無い", f, file=sys.stderr)
            return 1

    locs = asc.call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    loc = locs["data"][0]["id"]
    print("localization", loc, locs["data"][0]["attributes"].get("locale"))

    sets = asc.call("GET", f"/v1/appStoreVersionLocalizations/{loc}/appScreenshotSets")
    sid = None
    for s in sets.get("data", []):
        if s["attributes"].get("screenshotDisplayType") == DISPLAY:
            sid = s["id"]
    if sid is None:
        d = asc.call("POST", "/v1/appScreenshotSets",
                     {"data": {"type": "appScreenshotSets",
                               "attributes": {"screenshotDisplayType": DISPLAY},
                               "relationships": {"appStoreVersionLocalization": {
                                   "data": {"type": "appStoreVersionLocalizations",
                                            "id": loc}}}}})
        sid = d["data"]["id"]
        print("組を作った", sid)
    else:
        print("組", sid)

    old = asc.call("GET", f"/v1/appScreenshotSets/{sid}/appScreenshots")
    for x in old.get("data", []):
        asc.call("DELETE", f"/v1/appScreenshots/{x['id']}")
    print("消した %d 枚" % len(old.get("data", [])))

    ids = []
    for f in files:
        blob = f.read_bytes()
        d = asc.call("POST", "/v1/appScreenshots",
                     {"data": {"type": "appScreenshots",
                               "attributes": {"fileSize": len(blob),
                                              "fileName": f.name},
                               "relationships": {"appScreenshotSet": {
                                   "data": {"type": "appScreenshotSets",
                                            "id": sid}}}}})
        sid2 = d["data"]["id"]
        for op in d["data"]["attributes"]["uploadOperations"]:
            put(op, blob)
        asc.call("PATCH", f"/v1/appScreenshots/{sid2}",
                 {"data": {"type": "appScreenshots", "id": sid2,
                           "attributes": {"uploaded": True,
                                          "sourceFileChecksum":
                                              hashlib.md5(blob).hexdigest()}}})
        ids.append(sid2)
        print("上げた", f.name, sid2)

    # 並び順は relationships の appScreenshots を丸ごと置くと決まる。
    asc.call("PATCH", f"/v1/appScreenshotSets/{sid}/relationships/appScreenshots",
             {"data": [{"type": "appScreenshots", "id": i} for i in ids]})
    print("並べ替えた %d 枚" % len(ids))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
