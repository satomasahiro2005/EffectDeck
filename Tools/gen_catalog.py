#!/usr/bin/env python3
"""EffeTune の DSP 定義から Swift のカタログを作る。

詰め順の正本は dsp/generated/cpp/*Params.h。あれは gen-dsp-params.mjs が吐いたもので、
メンバの並びがそのまま et_instance_set_params に渡す float の並びになっている。
配列は展開され、enum も bool も float に潰れている。

画面に出る文字（名前・単位）と並び順の正本は plugins/<分類>/<名前>.js の createUI。
params.json の publicName / unit は DSP 側の都合で、画面に出ている文字とは別物。
createUI で見つからなかったパラメータだけ params.json の値を使う。

範囲と刻みは、createUI のつまみが素のモデル値を出しているときだけ createUI から取る。
`createParameterControl('Balance', -100, 100, 1, this.bl * 100, …, '%', 'bl', v => v * 100)`
のような目盛りを変換している行は、その -100..100 を持ってくるとモデルに 100 倍の値が入る。
そういう行は範囲も単位も触らない（表示の変換は Swift 側に無い）。

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

BS = chr(92)


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


# ---------------------------------------------------------------- JS を読む

def strip_comments(t):
    """// と /* */ を空白に潰す。文字列の中は触らない。行数は変えない。"""
    out = []
    i, n = 0, len(t)
    quote = None
    esc = False
    while i < n:
        c = t[i]
        if quote:
            out.append(c)
            if esc:
                esc = False
            elif c == BS:
                esc = True
            elif c == quote:
                quote = None
            i += 1
            continue
        if c in "'\"`":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "/" and t[i + 1:i + 2] == "/":
            j = t.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if c == "/" and t[i + 1:i + 2] == "*":
            j = t.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in t[i:j]))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


OPENERS = "([{"
CLOSERS = ")]}"


def split_args(t, lp):
    """t[lp] が '(' のとき、トップレベルのカンマで割った引数を返す。

    テンプレート文字列の ${…} も 1 つの塊として飛ばす。閉じ括弧が無ければ None。
    """
    i = lp + 1
    n = len(t)
    depth = 0
    cur, args = [], []
    while i < n:
        c = t[i]
        if c in "'\"`":
            q = c
            j = i + 1
            esc = False
            while j < n:
                d = t[j]
                if esc:
                    esc = False
                elif d == BS:
                    esc = True
                elif d == q:
                    break
                elif q == "`" and d == "$" and t[j + 1:j + 2] == "{":
                    k, b = j + 2, 1
                    while k < n and b:
                        if t[k] == "{":
                            b += 1
                        elif t[k] == "}":
                            b -= 1
                        k += 1
                    j = k - 1
                j += 1
            cur.append(t[i:j + 1])
            i = j + 1
            continue
        if c in OPENERS:
            depth += 1
        elif c in CLOSERS:
            if depth == 0 and c == ")":
                args.append("".join(cur))
                return [a.strip() for a in args]
            depth -= 1
        elif c == "," and depth == 0:
            args.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    return None


STR_LIT = re.compile(r"^'((?:[^'\\]|\\.)*)'$|^\"((?:[^\"\\]|\\.)*)\"$")
NUM_LIT = re.compile(r"^[-+]?(?:\d+\.?\d*|\.\d+)$")
PLAIN_VALUE = re.compile(r"^this\.\w+$")
I18N = re.compile(r"^this\._t\s*\(")

# plugin-base.js の作成関数。引数の位置がそのまま画面に出る。
#   createParameterControl(label, min, max, step, value, setter, unit, modelKey, toDisplay)
#   createSelectControl(label, options, value, setter, modelKey)
#   createRadioGroup(label, options, value, setter, modelKey)
#   createCheckboxControl(label, checked, setter, modelKey)
#   createNoteRangeControl(label, value, setter, modelKey)  … note_spectrogram.js:648
FACTORY = re.compile(
    r"\bcreate(LogarithmicParameterControl|ParameterControl|SelectControl"
    r"|RadioGroup|CheckboxControl|NoteRangeControl)\s*\(")
ANY_CALL = re.compile(r"(?<![\w$])([A-Za-z_$][\w$]*)\s*\(")
LABEL_EL = re.compile(r"\.textContent\s*=\s*(?:'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\")\s*;")
RANGE_INPUT = re.compile(r"(\w+)\.type\s*=\s*['\"]range['\"]")


def string_of(arg):
    """文字列リテラルなら中身。this._t('key', 'Dry') は第2引数。それ以外は None。"""
    if arg is None:
        return None
    arg = arg.strip()
    m = STR_LIT.match(arg)
    if m:
        s = m.group(1) if m.group(1) is not None else m.group(2)
        return s.replace(BS + "'", "'").replace(BS + '"', '"')
    if I18N.match(arg):
        inner = split_args(arg, arg.index("("))
        if inner and len(inner) > 1:
            return string_of(inner[1])
    return None


def number_of(arg):
    if arg is None:
        return None
    arg = arg.strip().strip("'\"")
    return float(arg) if NUM_LIT.match(arg) else None


def at(args, i):
    return args[i] if args and i < len(args) else None


def read_ui(path, keys):
    """createUI が画面に出しているものを key ごとに集める。

    戻り値は key -> {label, unit, lo, hi, step, line}。
    unit と範囲は取れなかったら None（params.json の値をそのまま使う合図）。
    line は画面での並び順に使う。
    """
    text = strip_comments(path.read_text(encoding="utf-8", errors="replace"))
    found = {}

    def line_of(pos):
        return text.count("\n", 0, pos) + 1

    def put(key, pos, label=None, unit=None, lo=None, hi=None, step=None):
        if key not in keys or key in found:
            return
        found[key] = {"label": label, "unit": unit, "lo": lo, "hi": hi,
                      "step": step, "line": line_of(pos)}

    # 1. plugin-base.js の作成関数。
    for m in FACTORY.finditer(text):
        args = split_args(text, m.end() - 1)
        if args is None:
            continue
        kind = m.group(1)
        if kind in ("ParameterControl", "LogarithmicParameterControl"):
            # 目盛りがモデル値そのものでない行は、範囲も単位も持ってこない。
            scaled = len(args) > 8 or not PLAIN_VALUE.match((at(args, 4) or "").strip())
            lo, hi, step = (number_of(at(args, 1)), number_of(at(args, 2)),
                            number_of(at(args, 3)))
            if scaled or lo is None or hi is None or step is None:
                lo = hi = step = None
            unit = None
            if not scaled:
                # 第7引数が無ければ単位無し。定数や `dB re ${…}` は読めないので触らない。
                unit = "" if len(args) <= 6 else string_of(at(args, 6))
            put(string_of(at(args, 7)), m.start(), label=string_of(at(args, 0)),
                unit=unit, lo=lo, hi=hi, step=step)
        elif kind in ("SelectControl", "RadioGroup"):
            put(string_of(at(args, 4)), m.start(), label=string_of(at(args, 0)))
        elif kind in ("CheckboxControl", "NoteRangeControl"):
            put(string_of(at(args, 3)), m.start(), label=string_of(at(args, 0)))

    # 2. プラグインが自前で持っているヘルパ。key が第1引数か最後の引数のどちらかで、
    #    ラベルがその隣にある形だけ拾う。
    #      tube_simulator.js:7333   linear('dr', 'Input Volume', -96, 0, 0.1, 'dB')
    #      vinyl_simulator.js:1531  _createZeroAwareLogControl('Dust', 10000, this.dr, …, '/s', 'dr')
    for m in ANY_CALL.finditer(text):
        args = split_args(text, m.end() - 1)
        if args is None or len(args) < 2:
            continue
        first, last = string_of(at(args, 0)), string_of(args[-1])
        if first in keys and string_of(at(args, 1)) is not None:
            lo, hi, step = (number_of(at(args, 2)), number_of(at(args, 3)),
                            number_of(at(args, 4)))
            unit = string_of(at(args, 5))
            if lo is None or hi is None or step is None:
                lo = hi = step = unit = None
            put(first, m.start(), label=string_of(at(args, 1)),
                unit=unit, lo=lo, hi=hi, step=step)
        elif last in keys and first is not None:
            # 引数の位置がヘルパごとに違うので、名前と並び順だけもらう。
            put(last, m.start(), label=first)

    # 3. label 要素に直書きしているもの（bit_crusher.js:235 の 'TPDF Dither:' など）。
    #    textContent から次の textContent までを 1 かたまりと見て、
    #    その中でいちばん近い key の参照でひもづける。
    #    パターンの優先ではなく近さで選ぶ。tilt_eq.js は 'Pivot Freq (Hz):' の
    #    かたまりの末尾に this.setSlope() があり、優先で選ぶと sl を拾ってしまう。
    sites = [(m.start(), m.group(1) if m.group(1) is not None else m.group(2))
             for m in LABEL_EL.finditer(text)]
    for i, (pos, label) in enumerate(sites):
        if not label.endswith(":"):
            continue
        stop = min(sites[i + 1][0] if i + 1 < len(sites) else len(text), pos + 2000)
        block = text[pos:stop]
        hits = []
        for pat, setter_case in ((r"this\.set([A-Z]\w*)\s*\(", True),
                                 (r"setParameters\s*\(\s*\{\s*(\w+)\s*:", False),
                                 (r"_commitParameter\s*\(\s*'(\w+)'", False),
                                 (r"this\.(\w+)\b", False)):
            for mm in re.finditer(pat, block):
                cand = mm.group(1)
                if setter_case:
                    cand = cand[0].lower() + cand[1:]
                if cand in ("id", "name"):
                    continue    # plugin-base 側のもの。パラメータではない
                if cand in keys and cand not in found:
                    hits.append((mm.start(), cand))
        if not hits:
            continue
        key = min(hits)[1]
        # 生の <input type="range"> に値がそのまま入っているときだけ、範囲も取る。
        lo = hi = step = None
        rm = RANGE_INPUT.search(block)
        if rm:
            var = rm.group(1)
            if re.search(re.escape(var) + r"\.value\s*=\s*this\." + re.escape(key) + r"\b", block):
                def attr(kind):
                    a = re.search(re.escape(var) + r"\." + kind + r"\s*=\s*([^;]+);", block)
                    return number_of(a.group(1)) if a else None
                lo, hi, step = attr("min"), attr("max"), attr("step")
                if lo is None or hi is None or step is None:
                    lo = hi = step = None
        put(key, pos, label=label.rstrip(":").strip(), lo=lo, hi=hi, step=step)

    return found


def display_order(lines):
    """createUI の行番号（無ければ None）の列から、画面に出す順の添字を返す。

    createUI に出てこないパラメータは、params.json で隣にいるものの位置に付ける。
    末尾へ寄せると、画面に出ているのが 1 つだけの型（modal_resonator の Mix など）で
    その 1 つが先頭に来てしまう。
    """
    n = len(lines)
    rank = [None] * n
    for i, ln in enumerate(lines):
        if ln is not None:
            rank[i] = (ln, 0)
    for i in range(n):
        if rank[i] is not None:
            continue
        prev = next((j for j in range(i - 1, -1, -1) if lines[j] is not None), None)
        if prev is not None:
            rank[i] = (lines[prev], i - prev)
        else:
            nxt = next((j for j in range(i + 1, n) if lines[j] is not None), None)
            rank[i] = (lines[nxt], i - nxt) if nxt is not None else (10 ** 6, i)
    return sorted(range(n), key=lambda i: (rank[i], i))


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
    stat = {"label": 0, "unit": 0, "range": 0, "order": 0, "miss": 0}

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

        # createUI の modelKey は params.json の key のことも name のこともある
        # （oscilloscope.js は 'displayTime' を渡していて、key は 'dt'）。
        ui_keys = set()
        for f in meta.get("fields", []):
            for k in (f.get("key"), f.get("name")):
                if k:
                    ui_keys.add(k)
        js_path = JS_PLUGINS / category / (folder + ".js")
        ui = read_ui(js_path, ui_keys) if js_path.exists() else {}

        params, defaults, offset = [], [], 0
        for mname, mcount in members:
            f = by_name.get(mname, {})
            kind = f.get("kind", "float")
            dv = f.get("default", 0)

            u = ui.get(f.get("key")) or ui.get(f.get("name")) or ui.get(mname) or {}

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
                unit = f.get("unit") or ""
                if u.get("lo") is not None:
                    if (float(lo if lo is not None else 0), float(hi if hi is not None else 1),
                            float(step or 0)) != (u["lo"], u["hi"], u["step"]):
                        stat["range"] += 1
                    lo, hi, step = u["lo"], u["hi"], u["step"]
                if u.get("unit") is not None and u["unit"] != unit:
                    stat["unit"] += 1
                    unit = u["unit"]
                # 刻みが 1 以上なら画面は整数。plugin-base.js:1378 の
                # toFixed(… step < 1 ? 1 : 0) と同じ扱いにする。
                is_int = kind == "int" or float(step or 0) >= 1
                kind_swift = ".number(min: %r, max: %r, step: %r, unit: %s, isInteger: %s)" % (
                    float(lo), float(hi), float(step or 0),
                    swift_str(unit), "true" if is_int else "false")

            # 配列のパラメータは default も配列で来る（バンドごとの周波数など）。
            # そのまま float() に掛けると落ちて 0 になり、既定値が全部消える。
            dv_list = None
            if isinstance(dv, list):
                dv_list = dv
                dv = dv[0] if dv else 0
                if kind == "enum":
                    values = f.get("values", [])
                    dv_f = float(values.index(dv)) if dv in values else 0.0
                elif kind == "bool":
                    dv_f = 1.0 if dv is True else 0.0
                else:
                    try:
                        dv_f = float(dv)
                    except (TypeError, ValueError):
                        dv_f = 0.0

            fallback = f.get("publicName") or camel_to_words(mname)
            label = fallback
            if u.get("label"):
                label = u["label"]
                # label 要素は 'Vol (dB):' のように単位を文字の中に入れている。
                # ParameterRow が単位を足すので、同じ単位なら外す。
                if kind not in ("enum", "bool"):
                    tail = re.search(r"\s*\(([^()]*)\)$", label)
                    if tail and f.get("unit") and tail.group(1) == (u.get("unit") or f.get("unit")):
                        label = label[:tail.start()].strip()
                if label != fallback:
                    stat["label"] += 1
            if not u:
                stat["miss"] += 1
            # 保存形式は params.json の key を使う。無ければメンバ名で代用する。
            key = f.get("key") or mname
            params.append((
                u.get("line"),
                "        ETParam(name: %s, key: %s, label: %s, kind: %s, defaultValue: %r, "
                "offset: %d, count: %d)"
                % (swift_str(mname), swift_str(key), swift_str(label),
                   kind_swift, dv_f, offset, mcount)))
            if dv_list is not None:
                # 要素ごとに違う既定値を持つ。足りない分は先頭で埋める。
                vals = []
                for i in range(mcount):
                    raw = dv_list[i] if i < len(dv_list) else (dv_list[0] if dv_list else 0)
                    if kind == "enum":
                        values = f.get("values", [])
                        vals.append(float(values.index(raw)) if raw in values else 0.0)
                    elif kind == "bool":
                        vals.append(1.0 if raw is True else 0.0)
                    else:
                        try:
                            vals.append(float(raw))
                        except (TypeError, ValueError):
                            vals.append(0.0)
                defaults.extend(vals)
            else:
                defaults.extend([dv_f] * mcount)
            offset += mcount

        if offset != float_count:
            skipped.append((type_name, "詰め幅が合わない %d != %d" % (offset, float_count)))
            continue

        # 画面の並びは createUI が足した順。詰め順（offset）とは別なので、
        # ここで並べ替えても et_instance_set_params に渡す配列は変わらない。
        ordered = [params[i][1] for i in display_order([p[0] for p in params])]
        if ordered != [p[1] for p in params]:
            stat["order"] += 1

        name, about = display_name(type_name, category, folder)
        specs.append({
            "type": type_name, "name": name, "about": about, "category": category,
            "hash": phash, "floatCount": float_count,
            "params": ordered, "defaults": defaults,
        })

    lines = [
        "//  EffectCatalog.swift",
        "//  Tools/gen_catalog.py が作る。手で直さないこと。",
        "//",
        "//  詰め順は EffeTune の dsp/generated/cpp/*Params.h と同じ。",
        "//  et_instance_set_params にはこの順で float を並べて渡す。",
        "//  params の並びは EffeTune の createUI が画面に出す順で、詰め順とは別。",
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
    print("createUI から: 名前 %d / 単位 %d / 範囲 %d / 並べ替えた型 %d"
          % (stat["label"], stat["unit"], stat["range"], stat["order"]))
    print("createUI に出てこないパラメータ %d 個は params.json のまま" % stat["miss"])
    if skipped:
        print("外したもの:")
        for t, why in skipped:
            print("  %-34s %s" % (t, why))


if __name__ == "__main__":
    main()
