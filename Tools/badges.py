#!/usr/bin/env python3
"""README の Downloads と Rating のバッジ（shields.io の endpoint）に使う JSON を書く。

  python3 Tools/badges.py <出力先ディレクトリ>

GitHub Actions の badges.yml が回し、出力先を孤立ブランチ badges に 1 コミットで force-push する
（main の履歴は増やさない）。前回の days.json が出力先にあれば読み、足りない日だけ取りに行く。

  rating.json     全世界の平均の星と件数。iTunes lookup を国ごとに引き、件数で重みづけして平均する。
  downloads.json  全世界の累計ダウンロード数。売上レポート（SALES/SUMMARY/DAILY）の初回ダウンロードと
                  再ダウンロードの Units を、出た日から昨日（太平洋時間）まで日ごとに足す
                  （App Store Connect の Total Downloads と同じ。アップデートは数えない）。
  days.json       日ごとの Product Type Identifier 別の Units（次の回が足りない日だけ取りに行くため。
                  数える種類を変えても取り直さずに済むよう、種類を絞らずに残す）

売上レポートは Sales の権限がある API キーでないと 403 になる（asc.py の鍵は持っていない）。
鍵は ASC_KEY_ID の ~/.appstoreconnect/private_keys/AuthKey_<id>.p8、ベンダー番号は ASC_VENDOR_NUMBER。
どちらか無ければ downloads.json は前のまま（無ければ書かない）にし、rating.json だけ書く。
"""
import csv
import datetime as dt
import gzip
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc  # noqa: E402  token() と BASE と APP を使う

APP = asc.APP
COLOR = "3B82F6"

# App Store がある国（storefront）。無い国を引いても結果が空なだけ。
STOREFRONTS = """
ae ag ai al am ao ar at au az ba bb bd be bf bg bh bj bm bn bo br bs bt bw by bz ca cd cg ch ci cl
cm cn co cr cv cy cz de dk dm do dz ec ee eg es fi fj fm fr ga gb gd ge gh gm gr gt gw gy hk hn hr
hu id ie il in iq is it jm jo jp ke kg kh kn kr kw ky kz la lb lc lk lr lt lu lv ly ma md me mg mk
ml mm mn mo mr ms mt mu mv mw mx my mz na ne ng ni nl no np nr nz om pa pe pg ph pk pl pt pw py qa
ro rs ru rw sa sb sc se sg si sk sl sn sr st sv sz tc td th tj tm tn to tr tt tw tz ua ug us uy uz
vc ve vg vn vu xk ye za zm zw
""".split()

# 数える Product Type Identifier。初回ダウンロード（1…）と再ダウンロード（3…）。アップデート（7…）は数えない。
DOWNLOAD = {"1", "1F", "1T", "1E", "1EP", "1EU", "F1",
            "3", "3F", "3T", "F3"}


def get_json(url: str):
    """iTunes lookup を引く。1 分に 20 回ほどで 403/429 を返すので、そのときは待って引き直す。"""
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (403, 429, 503) and attempt < 4:
                time.sleep(60)
                continue
            raise


def lookup(country: str):
    d = get_json(f"https://itunes.apple.com/lookup?id={APP}&country={country}")
    return (d.get("results") or [None])[0]


def rating():
    total = 0
    weighted = 0.0
    for cc in STOREFRONTS:
        r = lookup(cc)
        time.sleep(3.2)
        if not r:
            continue
        n = int(r.get("userRatingCount") or 0)
        if n:
            total += n
            weighted += float(r["averageUserRating"]) * n
    return (weighted / total if total else 0.0), total


def sales_report(day: str, vendor: str):
    """その日の SUMMARY の行。無い日（売上ゼロか、まだ出ていない）は None。"""
    q = ("filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY"
         f"&filter[vendorNumber]={vendor}&filter[version]=1_1&filter[reportDate]={day}")
    req = urllib.request.Request(f"{asc.BASE}/v1/salesReports?{q}",
                                 headers={"Authorization": f"Bearer {asc.token()}",
                                          "Accept": "application/a-gzip"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            text = gzip.decompress(r.read()).decode("utf-8")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        print(f"!! HTTP {e.code} salesReports {day}", file=sys.stderr)
        print(e.read().decode()[:1000], file=sys.stderr)
        raise SystemExit(1)
    return list(csv.DictReader(io.StringIO(text), delimiter="\t"))


def downloads(days: dict, vendor: str, start: dt.date) -> dict:
    """足りない日だけ取り、days を埋めて返す。3 日より前で 404 の日は 0 と決める。"""
    today = dt.datetime.now(ZoneInfo("America/Los_Angeles")).date()
    d = start
    while d < today:
        key = d.isoformat()
        if key not in days:
            rows = sales_report(key, vendor)
            if rows is not None:
                units = {}
                for r in rows:
                    if r.get("Apple Identifier") == APP:
                        t = r["Product Type Identifier"]
                        units[t] = units.get(t, 0) + int(r["Units"])
                days[key] = units
            elif (today - d).days >= 3:
                days[key] = {}
        d += dt.timedelta(days=1)
    return days


def short(n: int) -> str:
    if n < 1000:
        return str(n)
    for unit, size in (("M", 1_000_000), ("k", 1000)):
        if n >= size:
            v = n / size
            s = f"{v:.1f}" if v < 10 else f"{v:.0f}"
            return s.removesuffix(".0") + unit
    return str(n)


def badge(label: str, message: str, color: str = COLOR) -> dict:
    return {"schemaVersion": 1, "label": label, "message": message, "color": color}


def write(path: Path, data) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1, sort_keys=True) + "\n",
                    encoding="utf-8")


def main() -> int:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    avg, count = rating()
    write(out / "rating.json",
          badge("rating", f"★ {avg:.1f} ({count})", "yellow") if count else badge("rating", "none", "lightgrey"))
    print(f"rating {avg:.3f} ({count})")

    vendor = os.environ.get("ASC_VENDOR_NUMBER", "")
    if not vendor or not asc.KEY.exists():
        print("downloads: 鍵かベンダー番号が無いので前のまま")
        return 0
    days_path = out / "days.json"
    days = json.loads(days_path.read_text(encoding="utf-8")) if days_path.exists() else {}
    released = lookup("us")["releaseDate"]  # 例 2026-09-30T07:00:00Z
    start = dt.date.fromisoformat(released[:10]) - dt.timedelta(days=1)
    days = downloads(days, vendor, start)
    total = sum(n for units in days.values() for t, n in units.items() if t in DOWNLOAD)
    write(days_path, days)
    write(out / "downloads.json", badge("downloads", short(total)))
    print(f"downloads {total}（{len(days)} 日）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
