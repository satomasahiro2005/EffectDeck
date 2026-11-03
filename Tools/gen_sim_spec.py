#!/usr/bin/env python3
"""シミュレータ用のプロジェクト仕様を作る。

MediaDevice.framework はシミュレータに無いので、拡張を含むスキームは
`Unable to resolve module dependency: 'MediaDevice'` で建たない。
画面を撮るのに拡張は要らない（音が来ないだけで画面は同じものが出る）ので、
拡張のターゲットと、本体からの埋め込みを落とした仕様を書き出す。

project.yml を YAML として読まずに行で削る。Mac に PyYAML が居ない。
落とすもの:

  - `EffeTuneLiveExtension:` のターゲットまるごと。**すぐ上の見出しコメントも一緒に落とし、
    次のターゲットの見出しは残す。**前は中身を飛ばすときに次のターゲット（EffectDeckShare）の
    見出しまで食べ、拡張の見出し（「入れ物」）がそちらの上に残っていた
  - `- target: EffeTuneLiveExtension` の依存（下に続く embed などと、すぐ上のコメントごと）と、
    1行の `- {target: EffeTuneLiveExtension, …}`
  - スキームの `EffeTuneLiveExtension: all` のような1行の鍵
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "project.yml"
DST = ROOT / "project-sim.yml"
EXT = "EffeTuneLiveExtension"

_NAME = r"""["']?%s["']?""" % EXT
DEP_BLOCK = re.compile(r"^(\s*)- target:\s*%s\s*(#.*)?$" % _NAME)
DEP_INLINE = re.compile(r"^(\s*)- \{\s*target:\s*%s\s*(,[^}]*)?\}\s*(#.*)?$" % _NAME)
KEY_BLOCK = re.compile(r"^(\s*)%s:\s*(#.*)?$" % _NAME)
KEY_LINE = re.compile(r"^(\s*)%s:\s*\S.*$" % _NAME)


def indent_of(line):
    return len(line) - len(line.lstrip())


def is_comment(line):
    return line.lstrip().startswith("#")


def drop_header(out, indent):
    """out の末尾にある、同じ段の見出しコメント（空行で切れるまで）を落とす。"""
    while out and is_comment(out[-1]) and indent_of(out[-1]) == indent:
        out.pop()


def make_sim_spec(text):
    """project.yml の中身から project-sim.yml の中身を作る。落とせなければ ValueError。"""
    lines = text.splitlines()
    out = []
    i = 0
    dropped_target = False
    dropped_dep = False

    while i < len(lines):
        line = lines[i]

        # 名前を変える。実機用の .xcodeproj を潰さないため。
        if line.startswith("name: "):
            out.append("name: EffeTuneLiveSim")
            i += 1
            continue

        # 本体の dependencies から拡張の埋め込みを落とす（1行の形）。
        #       - {target: EffeTuneLiveExtension, embed: true}
        m = DEP_INLINE.match(line)
        if m:
            drop_header(out, len(m.group(1)))
            dropped_dep = True
            i += 1
            continue

        # 同じく、下に続く形。
        #       - target: EffeTuneLiveExtension
        #         embed: true
        #         codeSign: true
        m = DEP_BLOCK.match(line)
        if m:
            indent = len(m.group(1))
            drop_header(out, indent)
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if not nxt.strip() or indent_of(nxt) <= indent:
                    break
                i += 1
            dropped_dep = True
            continue

        # 拡張のターゲットまるごと。次の同じ段の key まで飛ばし、その key の見出しコメントは残す。
        m = KEY_BLOCK.match(line)
        if m:
            indent = len(m.group(1))
            drop_header(out, indent)
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if nxt.strip() and not is_comment(nxt) and indent_of(nxt) <= indent:
                    break
                j += 1
            # 次の key のすぐ上にある同じ段（か浅い）のコメントと空行は、次の key のもの。
            k = j
            while k > i + 1 and (not lines[k - 1].strip()
                                 or (is_comment(lines[k - 1]) and indent_of(lines[k - 1]) <= indent)):
                k -= 1
            # 見出しを落とした後に空行が2つ並ばないように。
            if out and not out[-1].strip():
                while k < j and not lines[k].strip():
                    k += 1
            i = k
            dropped_target = True
            continue

        # スキームの `EffeTuneLiveExtension: all` のような1行の鍵。
        if KEY_LINE.match(line):
            i += 1
            continue

        out.append(line)
        i += 1

    if not (dropped_target and dropped_dep):
        raise ValueError("落とせなかった target=%s dep=%s" % (dropped_target, dropped_dep))
    result = "\n".join(out) + "\n"
    if EXT in result:
        raise ValueError("参照が残っている")
    return result


def main():
    try:
        spec = make_sim_spec(SRC.read_text(encoding="utf-8"))
    except ValueError as e:
        print("!! %s" % e, file=sys.stderr)
        return 1
    DST.write_text(spec, encoding="utf-8", newline="\n")
    print(f"sim spec: {DST.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
