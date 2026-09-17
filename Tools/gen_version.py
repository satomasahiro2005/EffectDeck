#!/usr/bin/env python3
"""同梱している EffeTune の版を Swift から読めるようにする。

**アプリの版は上流に追従しない。**以前は上流の `major.minor` に合わせていたが、
やめた。理由は 2 つ。

  1. 上流の名前を冠さなくなったので、番号だけ揃える意味が無い
  2. App Store Connect は同じ版を二度出せない。上流が動かないあいだ、
     こちらの直しを出すたびに末尾を足していく形になっていた

いまは**出した日**を版にする（`2026.09.17`）。`project.yml` の
`MARKETING_VERSION` を手で書くか、`--today` で今日の日付にする。

  python3 Tools/gen_version.py            UpstreamVersion.swift を書くだけ
  python3 Tools/gen_version.py --today    版も今日の日付にする

**同じ日に 2 回は出せない。**版の番号は使い回せず、区切りは 3 つまでなので
4 つ目を足すこともできない。同じ日に出し直すなら、ビルド番号だけ上げる
（版を替えずに差し替えられるのは、まだ審査へ出していないあいだだけ）。

ビルド番号（CURRENT_PROJECT_VERSION）はこちらの都合なので触らない。
「どの EffeTune を積んだか」は UpstreamVersion.swift に別の事実として残る。
"""
import datetime
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Vendor" / "effetune" / "package.json"
DST = ROOT / "project.yml"
# 上流の版を Swift からも読めるようにする。
# **アプリの版とは別の事実。**あちらは「このアプリを出した日」で、
# こちらは「どの EffeTune の dsp を積んだか」。
SWIFT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "UpstreamVersion.swift"


def main() -> int:
    if not SRC.is_file():
        print("!! package.json が無い", SRC, file=sys.stderr)
        return 1
    version = json.loads(SRC.read_text(encoding="utf-8")).get("version")
    if not version:
        print("!! version が無い", file=sys.stderr)
        return 1

    s = DST.read_text(encoding="utf-8")
    found = re.search(r'MARKETING_VERSION: "([^"]*)"', s)
    if not found:
        print("!! MARKETING_VERSION が見つからない", file=sys.stderr)
        return 1
    app = found.group(1)

    if "--today" in sys.argv:
        today = datetime.date.today().strftime("%Y.%m.%d")
        if today != app:
            s = s[:found.start(1)] + today + s[found.end(1):]
            DST.write_text(s, encoding="utf-8", newline="\n")
            print("版を %s から %s へ" % (app, today))
            app = today
        else:
            print("版は既に %s" % app)

    header = [
        "//  UpstreamVersion.swift",
        "//  Tools/gen_version.py が作る。手で直さないこと。",
        "//",
        "//  同梱している EffeTune の版（Vendor/effetune/package.json）。",
        "//  **アプリの版とは別の事実。**あちらは出した日で、",
        "//  こちらは積んだ EffeTune の dsp の版。",
        "",
        'let ETUpstreamVersion = "%s"' % version,
        "",
    ]
    SWIFT.write_text(chr(10).join(header), encoding="utf-8", newline=chr(10))

    # README のバッジは上流の版を出す。手で書くと古くなる。
    readme = ROOT / "README.md"
    if readme.is_file():
        text = readme.read_text(encoding="utf-8")
        fixed, hits = re.subn(r"(badge/EffeTune%20DSP-)[^-]+(-)",
                              r"\g<1>%s\g<2>" % version.replace("-", "--"),
                              text, count=1)
        if hits == 1 and fixed != text:
            readme.write_text(fixed, encoding="utf-8", newline="\n")
            print("README のバッジを直した")
    print("version: app %s / upstream %s" % (app, version))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
