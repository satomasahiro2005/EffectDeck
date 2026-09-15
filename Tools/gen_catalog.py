#!/usr/bin/env python3
"""EffeTune の DSP 定義から Swift のカタログを作る。

詰め順の正本は dsp/generated/cpp/*Params.h。あれは gen-dsp-params.mjs が吐いたもので、
メンバの並びがそのまま et_instance_set_params に渡す float の並びになっている。
配列は展開され、enum も bool も float に潰れている。

UI に要る情報（範囲・単位・選択肢・既定値）は dsp/plugins/**/params.json から取る。
表示名は EffeTune 本体の JS が持っているので、そこから拾う。

  python Tools/gen_catalog.py
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DSP = ROOT / "Vendor" / "effetune" / "dsp"
JS_PLUGINS = ROOT / "Vendor" / "effetune" / "plugins"
OUT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "EffectCatalog.swift"

MEMBER = re.compile(r"^\s*float\s+(\w+)\s*(?:\[(\d+)\])?\s*;")
HASH = re.compile(r"kHash\s*=\s*(0x[0-9a-fA-F]+)u")
COUNT = re.compile(r"kFloatCount\s*=\s*(\d+)u")
SUPER = re.compile(r"super\(\s*'((?:[^'\\]|\\.)*)'\s*,\s*'((?:[^'\\]|\\.)*)'", re.S)


def parse_header(path):
    """生成ヘッダから (メンバ順, ハッシュ, float総数) を読む。"""
    text = path.read_text(encoding="utf-8")
    members = []
    for line in text.splitlines():
        m = MEMBER.match(line)
        if m:
            members.append((m.group(1), int(m.group(2) or 1)))
    h = HASH.search(text)
    c = COUNT.search(text)
    if not h or not c:
        return None
    return members, int(h.group(1), 16), int(c.group(1))


def camel_to_words(s):
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", s)
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", " ", s)
    return s[:1].upper() + s[1:]


def swift_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def display_name(type_name, category, folder):
    """EffeTune の JS が持っている製品名を拾う。無ければ型名から作る。"""
    js = JS_PLUGINS / category / (folder + ".js")
    if js.exists():
        m = SUPER.search(js.read_text(encoding="utf-8", errors="replace"))
        if m:
            return m.group(1).replace("\\'", "'"), m.group(2).replace("\\'", "'")
    return camel_to_words(type_name.replace("Plugin", "")), ""


def main():
    if not DSP.exists():
        sys.exit("Vendor/effetune が無い。git submodule update --init を先に。")

    specs = []
    skipped = []

    for pj in sorted(DSP.glob("plugins/**/params.json")):
        meta = json.loads(pj.read_text(encoding="utf-8"))
        type_name = meta["type"]
        header = DSP / "generated" / "cpp" / (type_name + "Params.h")
        if not header.exists():
            skipped.append((type_name, "生成ヘッダが無い"))
            continue
        parsed = parse_header(header)
        if parsed is None:
            skipped.append((type_name, "ヘッダを読めない"))
            continue
        members, phash, float_count = parsed

        rel = pj.relative_to(DSP / "plugins").parts   # (category, folder, params.json)
        category, folder = rel[0], rel[1]

        # params.json のフィールドを名前で引けるようにする。
        # 配列は arrayKey / objectArrayKey+memberKey で名前がずれることがあるので、
        # ヘッダのメンバ名に一致するものを優先し、無ければ name で引く。
        by_name = {}
        for f in meta.get("fields", []):
            for k in (f.get("name"), f.get("arrayKey"), f.get("memberKey"), f.get("key")):
                if k and k not in by_name:
                    by_name[k] = f

        params, defaults, offset = [], [], 0
        for mname, mcount in members:
            f = by_name.get(mname, {})
            kind = f.get("kind", "float")
            dv = f.get("default", 0)

            if kind == "enum":
                values = f.get("values", [])
                dv_f = float(values.index(dv)) if dv in values else 0.0
                kind_swift = ".enumeration([%s])" % ", ".join(swift_str(v) for v in values)
            elif kind == "bool":
                dv_f = 1.0 if dv is True else 0.0
                kind_swift = ".toggle"
            else:
                try:
                    dv_f = float(dv)
                except (TypeError, ValueError):
                    dv_f = 0.0
                lo = f.get("min", 0)
                hi = f.get("max", 1)
                step = f.get("step", 0)
                unit = f.get("unit", "")
                kind_swift = ".number(min: %r, max: %r, step: %r, unit: %s, isInteger: %s)" % (
                    float(lo), float(hi), float(step or 0),
                    swift_str(unit), "true" if kind == "int" else "false")

            label = f.get("publicName") or camel_to_words(mname)
            # 保存形式は params.json の key を使う。無ければメンバ名で代用する。
            key = f.get("key") or mname
            params.append(
                "        ETParam(name: %s, key: %s, label: %s, kind: %s, defaultValue: %r, "
                "offset: %d, count: %d)"
                % (swift_str(mname), swift_str(key), swift_str(label),
                   kind_swift, dv_f, offset, mcount))
            defaults.extend([dv_f] * mcount)
            offset += mcount

        if offset != float_count:
            skipped.append((type_name, "詰め幅が合わない %d != %d" % (offset, float_count)))
            continue

        name, about = display_name(type_name, category, folder)
        specs.append({
            "type": type_name, "name": name, "about": about, "category": category,
            "hash": phash, "floatCount": float_count,
            "params": params, "defaults": defaults,
        })

    lines = [
        "//  EffectCatalog.swift",
        "//  Tools/gen_catalog.py が作る。手で直さないこと。",
        "//",
        "//  詰め順は EffeTune の dsp/generated/cpp/*Params.h と同じ。",
        "//  et_instance_set_params にはこの順で float を並べて渡す。",
        "",
        "import Foundation",
        "",
        "let ETCatalog: [ETEffect] = [",
    ]
    for s in sorted(specs, key=lambda x: (x["category"], x["name"])):
        lines.append("    ETEffect(")
        lines.append("      type: %s," % swift_str(s["type"]))
        lines.append("      name: %s," % swift_str(s["name"]))
        lines.append("      about: %s," % swift_str(s["about"]))
        lines.append("      category: %s," % swift_str(s["category"]))
        lines.append("      paramsHash: %#010x," % s["hash"])
        lines.append("      floatCount: %d," % s["floatCount"])
        lines.append("      defaults: [%s]," % ", ".join("%r" % v for v in s["defaults"]))
        lines.append("      params: [")
        lines.append(",\n".join(s["params"]))
        lines.append("      ]),")
    lines.append("]")
    lines.append("")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")

    print("書いた: %s" % OUT.relative_to(ROOT))
    print("エフェクト %d 種 / パラメータ %d 個"
          % (len(specs), sum(len(s["params"]) for s in specs)))
    if skipped:
        print("外したもの:")
        for t, why in skipped:
            print("  %-34s %s" % (t, why))


if __name__ == "__main__":
    main()
