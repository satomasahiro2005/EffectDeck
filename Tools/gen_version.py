#!/usr/bin/env python3
"""上流 EffeTune の版に追従する。

このアプリは EffeTune の dsp/ をそのまま積んでいるので、
効果の中身は上流の版で決まる。表示する版も合わせる。

project.yml の MARKETING_VERSION を Vendor/effetune/package.json の version で置く。
ビルド番号（CURRENT_PROJECT_VERSION）はこちらの都合なので触らない。
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Vendor" / "effetune" / "package.json"
DST = ROOT / "project.yml"


def main() -> int:
    if not SRC.is_file():
        print("!! package.json が無い", SRC, file=sys.stderr)
        return 1
    version = json.loads(SRC.read_text(encoding="utf-8")).get("version")
    if not version:
        print("!! version が無い", file=sys.stderr)
        return 1

    s = DST.read_text(encoding="utf-8")
    new, n = re.subn(r'(MARKETING_VERSION: )"[^"]*"', r'\1"%s"' % version, s, count=1)
    if n != 1:
        print("!! MARKETING_VERSION が見つからない", file=sys.stderr)
        return 1
    if new != s:
        DST.write_text(new, encoding="utf-8", newline="\n")
    print("version: %s" % version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
