#!/usr/bin/env python3
"""ライセンス本文を Swift へ焼く。

外へリンクを張るのではなく、本文をアプリに同梱する。
配布物の中身と表示が食い違わないよう、置き場のファイルをそのまま読む。
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "Licenses.swift"

ITEMS = [
    ("EffeTune Live", "MIT", "nemut.ai", "LICENSE"),
    ("EffeTune", "MIT", "Yoshiyuki Kobayashi", "Vendor/effetune/LICENSE"),
    ("PFFFT", "BSD-3-Clause", "Julien Pommier", "Vendor/effetune/dsp/vendor/pffft/LICENSE.txt"),
]


def main() -> int:
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
        assert '"""' not in text, rel
        lines += [
            "    ETLicense(",
            '      name: "%s",' % name,
            '      license: "%s",' % lic,
            '      author: "%s",' % author,
            '      text: #"""',
            # Swift の複数行文字列は、中身の行が閉じ記号より浅いとエラーになる。
            *['      ' + ln if ln else '' for ln in text.splitlines()],
            '      """#),',
        ]
    lines += ["]", ""]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("licenses: %d 本" % len(ITEMS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
