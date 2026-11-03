#!/usr/bin/env python3
"""同梱している EffeTune の dsp/ の版を Swift から読めるようにする。

**アプリの版は上流に追従しない。**以前は上流の `major.minor` に合わせていたが、
やめた。理由は 2 つ。

  1. 上流の名前を冠さなくなったので、番号だけ揃える意味が無い
  2. App Store Connect は同じ版を二度出せない。上流が動かないあいだ、
     こちらの直しを出すたびに末尾を足していく形になっていた

いまは**出した日**を版にする（`2026.09.17`）。`project.yml` の
`MARKETING_VERSION` を手で書くか、`--today` で今日の日付にする。

  python3 Tools/gen_version.py            UpstreamVersion.swift を書くだけ
  python3 Tools/gen_version.py --today    版も今日の日付にする
  python3 Tools/gen_version.py --strict   浅い submodule でも止める（ET_STRICT=1 と同じ）

**同じ日に 2 回は出せない。**版の番号は使い回せず、区切りは 3 つまでなので
4 つ目を足すこともできない。同じ日に出し直すなら、ビルド番号だけ上げる
（版を替えずに差し替えられるのは、まだ審査へ出していないあいだだけ）。

ビルド番号（CURRENT_PROJECT_VERSION）はこちらの都合なので触らない。
「どの EffeTune を積んだか」は UpstreamVersion.swift に別の事実として残る。

**浅い submodule の版は信用しない（ET_STRICT=1 のとき）。**actions/checkout の既定の
submodule は深さ 1 でタグが付いてこない。describe が落ちるか、辿れた古いタグを答える。
CI では Vendor/effetune を --filter=blob:none で取る（履歴とタグは全部、中身は要る分だけ）。
"""
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DSP = ROOT / "Vendor" / "effetune"
DST = ROOT / "project.yml"
README = ROOT / "README.md"
# 上流の版を Swift からも読めるようにする。
# **アプリの版とは別の事実。**あちらは「このアプリを出した日」で、
# こちらは「積んでいる dsp/ 自体の版」。
#
# **package.json の version ではない。**あれは EffeTune アプリ全体（web/js 側）の
# 版で、dsp/ の版とは別に動く。実際 2.10.0 のときの dsp/ は 0.10.0 だった。
# dsp/ 単体には package.json が無く、上流が打っている `dsp-v*` の git タグが
# 唯一の正本（Vendor/effetune 側で `git tag | grep ^dsp-` すれば見える）。
SWIFT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "UpstreamVersion.swift"


def strict_mode(argv) -> bool:
    return os.environ.get("ET_STRICT", "") not in ("", "0") or "--strict" in argv


def parse_describe(out: str) -> str:
    """`git describe` の答えから版を取る。

    dsp-v0.10.0 か、タグから外れていれば dsp-v0.10.0-3-gabca7ff9 のような形。
    後者はコミットのぶら下がりまで版に含めると README のバッジが荒れるので、
    タグそのものの数字だけ使う。
    """
    return out.strip().removeprefix("dsp-v").split("-")[0]


def dsp_version() -> str:
    """`dsp/` の版。直近の dsp-v* タグから取る。"""
    out = subprocess.run(
        ["git", "-C", str(DSP), "describe", "--tags", "--match", "dsp-v*"],
        capture_output=True, text=True, check=True).stdout
    return parse_describe(out)


def app_version() -> str:
    """EffeTune アプリ全体の版（Vendor/effetune/package.json の version）。無ければ空。

    公式の EffeTune は hello の返事に dsp を出さず、app（= この版）だけを出す。
    その PC とこちらの積んでいる上流の版を比べて、食い違いを出すのに使う（ETRemoteHostInfo.mismatch）。
    **dsp/ の版とは別の事実。**機能の有無は features と effects で決め、この版は表示だけに使う。
    """
    try:
        data = json.loads((DSP / "package.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    version = data.get("version") if isinstance(data, dict) else None
    return version.strip() if isinstance(version, str) else ""


def is_shallow() -> bool:
    r = subprocess.run(["git", "-C", str(DSP), "rev-parse", "--is-shallow-repository"],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "true"


def replace_badge(text: str, version: str):
    """README のバッジ（最初の1つ）を版に替える。shields.io では - を -- と書く。"""
    return re.subn(r"(badge/EffeTune%20DSP-)[^-]+(-)",
                   r"\g<1>%s\g<2>" % version.replace("-", "--"), text, count=1)


def set_marketing_version(text: str, today: str):
    """project.yml の最初の MARKETING_VERSION を today にする。(新しい中身, 前の版, 後の版)。"""
    found = re.search(r'MARKETING_VERSION: "([^"]*)"', text)
    if not found:
        raise ValueError("MARKETING_VERSION が見つからない")
    return text[:found.start(1)] + today + text[found.end(1):], found.group(1), today


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    strict = strict_mode(argv)
    if not DSP.is_dir():
        print("!! Vendor/effetune が無い", DSP, file=sys.stderr)
        return 1
    if strict and is_shallow():
        print("!! Vendor/effetune が浅い clone（shallow）で、dsp-v* のタグを信用できない。"
              "git submodule update --init --filter=blob:none Vendor/effetune で取り直す",
              file=sys.stderr)
        return 1
    try:
        version = dsp_version()
    except (subprocess.CalledProcessError, OSError) as e:
        print("!! dsp-v* タグが見つからない（Vendor/effetune の submodule を確かめる）",
              e, file=sys.stderr)
        return 1
    if not version:
        print("!! version が無い", file=sys.stderr)
        return 1

    s = DST.read_text(encoding="utf-8")
    found = re.search(r'MARKETING_VERSION: "([^"]*)"', s)
    if not found:
        print("!! MARKETING_VERSION が見つからない", file=sys.stderr)
        return 1
    app = found.group(1)

    if "--today" in argv:
        today = datetime.date.today().strftime("%Y.%m.%d")
        if today != app:
            s, _, _ = set_marketing_version(s, today)
            DST.write_text(s, encoding="utf-8", newline="\n")
            print("版を %s から %s へ" % (app, today))
            app = today
        else:
            print("版は既に %s" % app)

    header = [
        "//  UpstreamVersion.swift",
        "//  Tools/gen_version.py が作る。手で直さないこと。",
        "//",
        "//  積んでいる EffeTune の dsp/ 自体の版（Vendor/effetune の dsp-v* タグ）。",
        "//  **アプリの版とは別の事実。**あちらは出した日で、",
        "//  EffeTune アプリ全体の版（package.json）とも別。",
        "//",
        "//  ETUpstreamAppVersion は積んでいる EffeTune アプリ全体の版（Vendor/effetune/package.json）。",
        "//  公式の PC は hello の返事に dsp の版を出さず、この版だけを出す。食い違いの表示にだけ使う。",
        "//  読めなければ空。",
        "",
        'let ETUpstreamVersion = "%s"' % version,
        'let ETUpstreamAppVersion = "%s"' % app_version(),
        "",
    ]
    SWIFT.write_text(chr(10).join(header), encoding="utf-8", newline=chr(10))

    # README のバッジは上流の版を出す。手で書くと古くなる。
    if README.is_file():
        text = README.read_text(encoding="utf-8")
        fixed, hits = replace_badge(text, version)
        if hits == 1 and fixed != text:
            README.write_text(fixed, encoding="utf-8", newline="\n")
            print("README のバッジを直した")
    print("version: app %s / upstream %s" % (app, version))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
