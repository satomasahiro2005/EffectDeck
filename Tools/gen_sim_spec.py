#!/usr/bin/env python3
"""シミュレータ用のプロジェクト仕様を作る。

MediaDevice.framework はシミュレータに無いので、拡張を含むスキームは
`Unable to resolve module dependency: 'MediaDevice'` で建たない。
画面を撮るのに拡張は要らない（音が来ないだけで画面は同じものが出る）ので、
拡張のターゲットと、本体からの埋め込みを落とした仕様を書き出す。

project.yml を YAML として読まずに行で削る。Mac に PyYAML が居ない。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "project.yml"
DST = ROOT / "project-sim.yml"
EXT = "EffeTuneLiveExtension"

lines = SRC.read_text(encoding="utf-8").splitlines()
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

    # 本体の dependencies から拡張の埋め込みを落とす。
    #       - target: EffeTuneLiveExtension
    #         embed: true
    #         codeSign: true
    m = re.match(r"^(\s*)- target: " + EXT + r"\s*$", line)
    if m:
        indent = len(m.group(1))
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if not nxt.strip():
                break
            if len(nxt) - len(nxt.lstrip()) <= indent:
                break
            i += 1
        dropped_dep = True
        continue

    # 拡張のターゲットまるごと。次の同じ段の key まで飛ばす。
    m = re.match(r"^(\s*)" + EXT + r":\s*$", line)
    if m:
        indent = len(m.group(1))
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if nxt.strip() and not nxt.lstrip().startswith("#"):
                if len(nxt) - len(nxt.lstrip()) <= indent:
                    break
            i += 1
        dropped_target = True
        continue

    out.append(line)
    i += 1

if not (dropped_target and dropped_dep):
    print(f"!! 落とせなかった target={dropped_target} dep={dropped_dep}", file=sys.stderr)
    sys.exit(1)

if EXT in "\n".join(out):
    print("!! 参照が残っている", file=sys.stderr)
    sys.exit(1)

DST.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"sim spec: {DST.name}")
