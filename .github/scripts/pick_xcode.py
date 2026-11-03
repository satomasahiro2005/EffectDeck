#!/usr/bin/env python3
"""canary.yml で、image にあるいちばん新しい Xcode（beta も含む）と、それで走る
いちばん新しい iOS のランタイムを選ぶ。

    python3 .github/scripts/pick_xcode.py xcode [--apps /Applications]
        Xcode*.app の Contents/version.plist を読み、いちばん新しいものの実体の場所を出す
    python3 .github/scripts/pick_xcode.py runtime [--sdk 27.2] [--json runtimes.json]
        xcrun simctl list runtimes available -j から、いちばん新しい iOS のランタイムを選び
        「pick_simulator.py の --os に渡す版」と「ランタイムの identifier」を空白で区切って出す
        （--json は試験用。simctl を叩かない）

Xcode の新しさ:
- CFBundleShortVersionString（27.1 など）を数で比べる（27.10 は 27.9 より新しい）
- 版が同じなら正式版を beta・RC より新しいとみなす。version.plist には beta の印が無いので、
  image の名前の付け方（Xcode_27.1_beta.app のように beta・Release_Candidate・RC が付く）で見る
- それも同じなら ProductBuildVersion（27B5024e など）を 数・文字・数・文字 に分けて比べる
- 同じ実体の別名（Xcode.app や Xcode_27.0.0.app などの symlink）は 1 つにまとめる

ランタイムの新しさは version（27.0.1 など）を数で比べ、同じなら buildversion で比べる。
--sdk を渡すと、その SDK（major.minor）より新しいランタイムは使わない。

標準ライブラリだけ（runner の python3 に pip で何かを足さない）。
候補と選んだものは標準エラーへ、答えだけを標準出力へ出す。
"""
import argparse
import glob
import json
import os
import plistlib
import re
import subprocess
import sys

IOS_MARKER = ".SimRuntime.iOS-"
# 名前のどこかにこれがあれば正式版ではない（Xcode_27.1_beta_2.app・Xcode_16.0_Release_Candidate.app など）。
PRERELEASE = re.compile(r"beta|release[ _-]?candidate|(?:^|[^a-z])rc(?:\d|[^a-z]|$)", re.IGNORECASE)


def version_key(text):
    """"27.1" → (27, 1, 0)。数でない版は None。"""
    parts = (text or "").strip().split(".")
    if not parts or not all(p.isdigit() for p in parts):
        return None
    nums = [int(p) for p in parts]
    return tuple(nums + [0] * (3 - len(nums)))


def build_key(build):
    """Apple の build 番号 "27B5024e" → (27, "B", 5024, "e")。形の違うものは後ろに回す。"""
    m = re.fullmatch(r"(\d+)([A-Z])(\d+)([a-z]?)", (build or "").strip())
    if not m:
        return (-1, "", -1, build or "")
    return (int(m.group(1)), m.group(2), int(m.group(3)), m.group(4))


def is_prerelease(paths):
    """どれかの名前（.app を除いたもの）に beta・RC の印があれば正式版ではない。"""
    for p in paths:
        stem = os.path.basename(p)
        if stem.endswith(".app"):
            stem = stem[:-len(".app")]
        if PRERELEASE.search(stem):
            return True
    return False


def list_xcodes(apps_dir):
    """apps_dir/Xcode*.app を読んで、実体ごとに 1 つの dict を返す（読めないものは標準エラーに出して飛ばす）。"""
    found = {}
    for path in sorted(glob.glob(os.path.join(apps_dir, "Xcode*.app"))):
        real = os.path.realpath(path)
        if real in found:
            if found[real] is not None:
                found[real]["names"].append(path)
            continue
        plist = os.path.join(real, "Contents", "version.plist")
        try:
            with open(plist, "rb") as f:
                info = plistlib.load(f)
        except (OSError, plistlib.InvalidFileException, ValueError) as e:
            print("-- %s を飛ばす（version.plist を読めない: %s）" % (path, e), file=sys.stderr)
            found[real] = None
            continue
        short = info.get("CFBundleShortVersionString", "")
        key = version_key(short)
        if key is None:
            print("-- %s を飛ばす（版が数でない: %r）" % (path, short), file=sys.stderr)
            found[real] = None
            continue
        found[real] = {
            "path": real,
            "names": [path],
            "version": short,
            "build": info.get("ProductBuildVersion", ""),
            "version_key": key,
        }
    xcodes = [x for x in found.values() if x is not None]
    for x in xcodes:
        x["prerelease"] = is_prerelease([x["path"]] + x["names"])
    return xcodes


def xcode_sort_key(x):
    return (x["version_key"], not x["prerelease"], build_key(x["build"]))


def pick_xcode(apps_dir):
    xcodes = sorted(list_xcodes(apps_dir), key=xcode_sort_key, reverse=True)
    if not xcodes:
        print("!! %s に読める Xcode*.app が無い" % apps_dir, file=sys.stderr)
        return None
    print("Xcode（新しい順。* が選んだもの）:", file=sys.stderr)
    for i, x in enumerate(xcodes):
        aliases = [n for n in x["names"] if n != x["path"]]
        print("  %s %-7s %-10s %-7s %s%s" % (
            "*" if i == 0 else " ", x["version"], x["build"] or "?",
            "beta" if x["prerelease"] else "正式",
            x["path"], "（別名 %s）" % ", ".join(aliases) if aliases else ""), file=sys.stderr)
    return xcodes[0]


def ios_runtimes(data):
    """simctl list runtimes available -j の中身から iOS のランタイムだけを並べる。"""
    out = []
    for r in data.get("runtimes", []):
        ident = r.get("identifier", "")
        if IOS_MARKER not in ident or not r.get("isAvailable", True):
            continue
        key = version_key(r.get("version", ""))
        if key is None:
            continue
        # pick_simulator.py は端末の束ね先（…SimRuntime.iOS-27-0）から版を読むので、同じところから作る。
        # 27.0.1 のランタイムの identifier は iOS-27-0 のことがあり、version をそのまま渡すと合わない。
        os_for_pick = ident.split(IOS_MARKER, 1)[1].replace("-", ".")
        out.append({"identifier": ident, "version": r.get("version", ""),
                    "build": r.get("buildversion", ""), "version_key": key, "os": os_for_pick})
    return out


def pick_runtime(data, sdk=None):
    runtimes = sorted(ios_runtimes(data), key=lambda r: (r["version_key"], build_key(r["build"])),
                      reverse=True)
    limit = version_key(sdk) if sdk else None
    if sdk and limit is None:
        print("-- SDK の版が数でない（%r）ので絞らない" % sdk, file=sys.stderr)
    usable = [r for r in runtimes if limit is None or r["version_key"][:2] <= limit[:2]]
    print("iOS のランタイム（新しい順。* が選んだもの）:", file=sys.stderr)
    for r in runtimes:
        mark = "*" if usable and r is usable[0] else " "
        note = "" if r in usable else "（SDK %s より新しいので使わない）" % sdk
        print("  %s iOS %-8s %-10s %s%s" % (mark, r["version"], r["build"] or "?", r["identifier"], note),
              file=sys.stderr)
    if not usable:
        print("!! 使える iOS のランタイムが無い%s" % ("（SDK %s 以下）" % sdk if sdk else ""), file=sys.stderr)
        return None
    return usable[0]


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="what", required=True)
    ax = sub.add_parser("xcode", help="いちばん新しい Xcode の場所")
    ax.add_argument("--apps", default="/Applications", help="Xcode*.app を探す場所")
    ar = sub.add_parser("runtime", help="いちばん新しい iOS のランタイム")
    ar.add_argument("--sdk", help="この iphonesimulator SDK の版より新しいランタイムは使わない")
    ar.add_argument("--json", help="simctl の JSON を読む（試験用）")
    args = ap.parse_args(argv)

    if args.what == "xcode":
        x = pick_xcode(args.apps)
        if x is None:
            return 1
        print(x["path"])
        return 0

    if args.json:
        with open(args.json, encoding="utf-8") as f:
            data = json.load(f)
    else:
        raw = subprocess.run(["xcrun", "simctl", "list", "runtimes", "available", "-j"],
                             check=True, capture_output=True, text=True).stdout
        data = json.loads(raw)
    r = pick_runtime(data, args.sdk)
    if r is None:
        return 1
    print("%s %s" % (r["os"], r["identifier"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
