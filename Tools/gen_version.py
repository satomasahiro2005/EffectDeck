#!/usr/bin/env python3
"""上流 EffeTune の版に追従する。ただし**末尾はこちらの番号**。

このアプリは EffeTune の dsp/ をそのまま積んでいるので、
効果の中身は上流の版で決まる。表示する版もそこに合わせる。

**合わせるのは上 2 つ（major.minor）だけ。** 末尾（patch）はこちらの配布の回数。
上流が動いていないあいだもアプリ側の直しは出るし、**App Store Connect は
同じ版を二度公証に出せない**（版が READY_FOR_DISTRIBUTION になると、
ビルドの差し替えが 409 ENTITY_ERROR.RELATIONSHIP.INVALID.INVALID_STATE で弾かれる。
2026-09-17 に実測）。上流の版をそのまま名乗ると、上流が動くまで出し直せない。

  上流 2.9.0、こちら 2.9.0 → 2.9.1 → 2.9.2 …
  上流が 2.10.0 になったら 2.10.0 から数え直す

ビルド番号（CURRENT_PROJECT_VERSION）はこちらの都合なので触らない。
「どの EffeTune を積んだか」は UpstreamVersion.swift に別の事実として残る。
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Vendor" / "effetune" / "package.json"
DST = ROOT / "project.yml"
# 上流の版を Swift からも読めるようにする。MARKETING_VERSION と同じ値になるが、
# あちらは「このアプリの版」でこちらは「どの EffeTune の dsp を積んだか」。
# 意味が違うので別の事実として持つ。
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

    # 上 2 つが同じなら、末尾はこちらのものなので触らない。
    def head(v: str) -> str:
        return ".".join(v.split(".")[:2])

    current = found.group(1)
    app = current if head(current) == head(version) else head(version) + ".0"
    if app != current:
        s = s[:found.start(1)] + app + s[found.end(1):]
        DST.write_text(s, encoding="utf-8", newline="\n")
    header = [
        "//  UpstreamVersion.swift",
        "//  Tools/gen_version.py が作る。手で直さないこと。",
        "//",
        "//  同梱している EffeTune の版（Vendor/effetune/package.json）。",
        "//  アプリの版は同じ数字に揃えてあるが、意味が違う。",
        "//  あちらは「このアプリの何度目の配布か」、",
        "//  こちらは「どの EffeTune の dsp を積んだか」。",
        "",
        'let ETUpstreamVersion = "%s"' % version,
        "",
    ]
    SWIFT.write_text(chr(10).join(header), encoding="utf-8", newline=chr(10))
    print("version: %s" % version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
