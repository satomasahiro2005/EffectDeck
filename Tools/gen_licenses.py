#!/usr/bin/env python3
"""ライセンス本文を Swift へ焼く。

外へリンクを張るのではなく、本文をアプリに同梱する。
配布物の中身と表示が食い違わないよう、置き場のファイルをそのまま読む。

ライセンスが別ファイルでなくソースの頭のコメントにしか無いもの（DPF の Base64.hpp）は、
その文面を Licenses/ に写して読む。写しが元の頭のコメントとずれていれば（どちらかにだけ在る行が
あれば）止める（COPIES）。
Tools/check_repo.py は、ここの ITEMS が全部 NOTICE.md に書いてあるかも見る。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "Licenses.swift"

ITEMS = [
    ("EffectDeck", "MIT", "nemut.ai", "LICENSE"),
    ("EffeTune", "MIT", "Yoshiyuki Kobayashi", "Vendor/effetune/LICENSE"),
    ("PFFFT", "BSD-3-Clause", "Julien Pommier", "Vendor/effetune/dsp/vendor/pffft/LICENSE.txt"),
    ("ysfx", "Apache-2.0", "Jean Pierre Cimalando, Joep Vanlier and contributors", "Vendor/ysfx/LICENSE"),
    ("WDL / LICE", "zlib-style", "Cockos Incorporated and contributors", "Vendor/ysfx/thirdparty/WDL/LICENSE.txt"),
    # ysfx_utils.cpp が #include して base64 の出し入れに使う（JSFX の状態の保存）。
    # 注意書きは DPF の ISC と、元になった René Nyffenegger のコードの zlib 形式の 2 つ。
    ("DPF Base64", "ISC, zlib-style", "Filipe Coelho, Jean Pierre Cimalando, René Nyffenegger",
     "Licenses/dpf-base64.LICENSE"),
    # Rhythm Analyzer の rd6_math.h（2.12.0 では g2_math.h、2.13.0 で改名）にある atan / atan2 は fdlibm 5.3 の移植。
    # 注意書きは Sun Microsystems のもので、ソースの頭のコメントにしか無い。
    ("fdlibm", "Sun Microsystems permissive", "Sun Microsystems, Inc.", "Licenses/fdlibm.LICENSE"),
    # Synthetic Binaural Room（MIT、M0Rf30/easyeffects-presets）は外してある。使うのは
    # Virtual Room（feature/brir）で、まだアプリに入っていない。入れるときに、
    # 142c217で足したLicenses/easyeffects-presets.LICENSEとNOTICE.mdの節と一緒に戻す。
    # **feature/brirをそのまま混ぜると、ここで外したものは戻らない**（あちらは触っていないので）。
]


# Licenses/ の写し -> 元のソース、または (元のソース, 写さない見出しの行)。元がある木（Vendor/ysfx を
# 取ってある）では、写しと元の頭のコメント（最初のコードの行より前）を丸ごと突き合わせる。
COPIES = {
    # 頭のコメントのうち、節の見出し（// Helpers）は注意書きでないので写さない。罫線（// ---）は
    # 見出しに挙げなくても落とす。
    "Licenses/dpf-base64.LICENSE": ("Vendor/ysfx/sources/base64/Base64.hpp", ("Helpers",)),
    # rd6_math.h の頭のコメントは fdlibm の注意書きだけ（2.12.0 の g2_math.h にあったファイルの説明は無い）。
    "Licenses/fdlibm.LICENSE": "Vendor/effetune/dsp/plugins/analyzer/rhythm_analyzer/rd6_math.h",
}


def copy_source(value):
    """COPIES の値を (元のソース, 写さない見出しの行) にする。"""
    if isinstance(value, str):
        return value, ()
    return value[0], tuple(value[1])


def squash(text: str) -> str:
    """コメントの印（/* * //）・改行・空白の違いを無視して比べるための形。"""
    return re.sub(r"[\s*/]+", "", text)


def header_comments(text: str) -> list:
    """ソースの頭のコメントの中身を行ごとに（印を外し、空白を 1 つに詰めて）返す。

    最初のコードの行（空行・コメント・# で始まる前処理の行のどれでもない行）の手前まで。
    Base64.hpp は注意書きの後に #pragma と #include を挟んで 2 つめの注意書きを置くので、
    前処理の行では止めない。罫線だけの行（// ----）は落とし、空行は段落の切れ目として残す。
    """
    bodies = []
    in_block = False
    for line in text.splitlines():
        s = line.strip()
        if in_block:
            end = s.find("*/")
            bodies.append(s if end < 0 else s[:end])
            if end >= 0:
                in_block = False
                if s[end + 2:].strip():
                    break
            continue
        if not s or s.startswith("#"):
            bodies.append("")
            continue
        if s.startswith("//"):
            bodies.append(s[2:])
            continue
        if s.startswith("/*"):
            s = s[2:]
            end = s.find("*/")
            bodies.append(s if end < 0 else s[:end])
            if end < 0:
                in_block = True
            elif s[end + 2:].strip():
                break
            continue
        break
    lines = []
    for body in bodies:
        body = " ".join(re.sub(r"^[\s*/]+", "", body).split())
        if re.fullmatch(r"[-=*/_~#]*", body):
            body = ""
        lines.append(body)
    return lines


def compare_copy(copy_text: str, source_text: str, skip=()) -> list:
    """写しと元の頭のコメントの食い違い。同じなら空。

    どちら向きにも見る。写しの段落が元に在るかだけでは、上流が足した著作者や条項を
    写しが持っていなくても通ってしまう（ISC は注意書きを全部載せることを求める）。
    """
    head = [ln for ln in header_comments(source_text) if ln not in skip]
    if squash("\n".join(head)) == squash(copy_text):
        return []
    copy = [" ".join(ln.split()) for ln in copy_text.splitlines()]
    only_source = [ln for ln in head if ln and ln not in copy]
    only_copy = [ln for ln in copy if ln and ln not in head]
    parts = []
    if only_source:
        parts.append("元にだけ在る行: " + " / ".join(only_source[:3]))
    if only_copy:
        parts.append("写しにだけ在る行: " + " / ".join(only_copy[:3]))
    return ["；".join(parts) or "同じ行が揃っているが、並びか数が違う"]


def raw_hashes(text: str) -> str:
    """text を Swift の生文字列 #…#\"\"\"…\"\"\"#…# に書いたとき、書いたとおりに読まれる # の数。

    \\ に同じ数の # が続けばエスケープ、\"\"\" に同じ数の # が続けばそこで閉じるので、
    どちらも中身に出ない数まで増やす。Tools/gen_presets.py の raw_hashes と同じ。
    """
    hashes = "#"
    while "\\" + hashes in text or '"""' + hashes in text:
        hashes += "#"
    return hashes


def source_tree(source: str) -> pathlib.Path:
    """元のソースが入っている木（Vendor/ysfx）。submodule を取っていなければ空のフォルダか無い。"""
    return ROOT.joinpath(*pathlib.PurePosixPath(source).parts[:2])


def check_copies():
    """写しの文面が元のソースの頭のコメントと同じか。ずれていれば説明の列を返す。"""
    bad = []
    for copy, value in COPIES.items():
        source, skip = copy_source(value)
        src = ROOT / source
        if not src.is_file():
            tree = source_tree(source)
            if tree.is_dir() and any(tree.iterdir()):
                # 木は在るのに元が無い＝上流が動かした。黙って確かめるのをやめない。
                bad.append("%s の元の %s が無い（上流で動いた？ COPIES を直す）" % (copy, source))
            # 木ごと無い（Vendor/ysfx を取っていない）ときは確かめられない
            continue
        for d in compare_copy((ROOT / copy).read_text(encoding="utf-8"),
                              src.read_text(encoding="utf-8"), skip):
            bad.append("%s が %s の頭のコメントと違う: %s" % (copy, source, d))
    return bad


def main() -> int:
    drift = check_copies()
    if drift:
        for d in drift:
            print("!!", d, file=sys.stderr)
        return 1
    lines = [
        "//  Licenses.swift",
        "//  Tools/gen_licenses.py が作る。手で直さないこと。",
        "//",
        "//  本文は置き場のファイルをそのまま読んでいる。",
        "//  外へリンクを張らず同梱するのは、配布物と表示が食い違わないようにするため。",
        "",
        "import Foundation",
        "",
        "struct ETLicense: Identifiable {",
        "    var id: String { name }",
        "    let name: String",
        "    let license: String",
        "    let author: String",
        "    let text: String",
        "}",
        "",
        "let ETLicenses: [ETLicense] = [",
    ]
    for name, lic, author, rel in ITEMS:
        path = ROOT / rel
        if not path.is_file():
            print("!! 無い", rel, file=sys.stderr)
            return 1
        text = path.read_text(encoding="utf-8").strip()
        hashes = raw_hashes(text)
        lines += [
            "    ETLicense(",
            '      name: "%s",' % name,
            '      license: "%s",' % lic,
            '      author: "%s",' % author,
            '      text: %s"""' % hashes,
            # Swift の複数行文字列は、中身の行が閉じ記号より浅いとエラーになる。
            *['      ' + ln if ln else '' for ln in text.splitlines()],
            '      """%s),' % hashes,
        ]
    lines += ["]", ""]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("licenses: %d 本" % len(ITEMS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
