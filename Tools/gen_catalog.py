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

同じspecsから、ChatGPTなどに鎖を組ませるための語彙も書く（CHAIN.mdが指す）。

  chain/v<dspの版>/effects.json     機械で読む形
  chain/v<dspの版>/index.md         全部のnmを分類ごとに1行ずつ
  chain/v<dspの版>/<分類>.md        鍵・名札・形・範囲・選択肢・既定値

**古い版のフォルダは消さない。**古いビルドの依頼文は古い版を名指しする。
**別のパラメータで同じ版のフォルダを上書きしない。**effects.jsonのdspParamsで確かめる。

**外した型があれば黙らない。**生成ヘッダが無い・読めない・詰め幅が合わない型はカタログから
落ちる（アプリからそのエフェクトが消える）。いつもは stderr に !! で出して続け、
ET_STRICT=1（CI）か --strict では何も書かずに 1 で止める。

  python Tools/gen_catalog.py [--strict]
"""

import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENDOR = ROOT / "Vendor" / "effetune"
DSP = VENDOR / "dsp"
JS_PLUGINS = VENDOR / "plugins"
OUT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "EffectCatalog.swift"
CHAIN = ROOT / "chain"
UPSTREAM_VERSION = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "UpstreamVersion.swift"
PARAM_CODING = ROOT / "Sources" / "EffeTuneLive" / "DSP" / "ETParamCoding.swift"

MEMBER = re.compile(r"^\s*float\s+(\w+)\s*(?:\[(\d+)\])?\s*;")
HASH = re.compile(r"kHash\s*=\s*(0x[0-9a-fA-F]+)u")
COUNT = re.compile(r"kFloatCount\s*=\s*(\d+)u")
# super('名前', '説明')。**引用符は'でも"でもよく、説明は'a' + 'b'と足してあることがある。**
# 'だけを見ていた頃は、"で書いた7種（Hi Pass Filterなど）の説明が空になり、
# 足してあるSBC Codec Simulatorの説明が"round trip, "で切れていた。
JS_STR = r"""(?:'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")"""
JS_CAT = r"%s(?:\s*\+\s*%s)*" % (JS_STR, JS_STR)
SUPER = re.compile(r"super\(\s*(%s)\s*,\s*(%s)\s*[,)]" % (JS_CAT, JS_CAT), re.S)
JS_PART = re.compile(r"""'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)\"""")

BS = chr(92)


def strict_mode():
    """ET_STRICT=1（CI）か --strict。外した型を警告で済ませず止める。"""
    return os.environ.get("ET_STRICT", "") not in ("", "0") or "--strict" in sys.argv[1:]


# 保存している値と画面に出す値がずれるもの。(type, メンバ名) -> ETParamScale。
#
# **表で持つ。名前の綴りから当てない。**
# tilt_eq の pivotExponent は自然対数（kernel.cpp:131 が std::exp）だが、
# digital_error_emulator / g726_adpcm_simulator の *Exponent は pow(10, x) の
# 指数で、上流はその指数を "10^x" のラベルでそのまま見せている。
# 名前が Exponent で終わるかどうかで分けると後者まで変換してしまう。
# 配列パラメータの書き方を**数えて**確かめる。
#
# 上流の配列形式:
#   - オブジェクト配列  "bs": [{"en":…}, …]   params.json の objectArrayKey
#   - 添字付き          "f0" "f1" "f2" …      js が params['f' + i] で書く
#   - 平らな配列        "dm": [...]            FLAT_ARRAYS の表にあるものだけ
# 5Band PEQ を平らな "f": [...] で書いていたときは、
# プリセットが一つも読めず曲線が平坦になっていた。
# 将来 params.json が増えたときに黙って同じ穴に落ちないよう、
# 「object でも indexed でもない配列」が出たらここで止める。
#
# **平らな配列は表で持つ。検査と flatArrayKey の出力の両方がこの表を見る。**
# 検査だけ外すと ro0..ro15 の添字形式で書かれ、web 版とプリセットが食い違う。
#   - Spatial Mapper (2.10.0): dm / fm / rm は 16×16 の行列
#   - Bass Management (2.11.0): ro / fc / sl / rt / ri は 16ch 分
#     （bass_management.js の getParameters / setParameters が平らなまま読み書きする）
FLAT_ARRAYS = {
    "SpatialMapperPlugin": ("dm", "fm", "rm"),
    "BassManagementPlugin": ("ro", "fc", "sl", "rt", "ri"),
}


def is_flat_array(type_name, f):
    return f.get("arrayKey") in FLAT_ARRAYS.get(type_name, ())


def check_array_shape(meta, type_name, category, folder):
    js = JS_PLUGINS / category / (folder + ".js")
    src = js.read_text(encoding="utf-8", errors="replace") if js.exists() else ""
    for f in meta.get("fields", []):
        if (f.get("count") or 1) <= 1 or f.get("objectArrayKey"):
            continue
        if is_flat_array(type_name, f):
            continue
        k = f.get("key") or f["name"]
        indexed = (re.search(r"\[\s*['\"]%s['\"]\s*\+" % re.escape(k), src)
                   or re.search(r"`%s\$\{" % re.escape(k), src))
        if not indexed:
            raise SystemExit(
                "!! %s の配列 %s が object でも indexed でもない。"
                "書き方を確かめて ETParamCoding を直すこと（%s）"
                % (type_name, k, js))


SCALES = {
    ("TiltEQPlugin", "pivotExponent"): "naturalExp",
}


# 画面の並びが createUI の行番号だけでは決まらないもの。(type, key) -> 直前に置く key。
# Tonal Balance EQ の Averaging Time は専用の行を作る関数（createAveragingTimeControl）が
# createUI より前にあり、そのラベルの行が先頭に化ける。createUI では Smoothing の次に並ぶ。
UI_AFTER = {
    ("TonalBalanceEQPlugin", "at"): "sm",
}

# 保存形式にも鎖の語彙にも出さないパラメータ。(type, メンバ名)。DSP の float には載るので
# catalog には残し、ETParam.runtimeOnly で印を付ける（ETParamCoding が書かず・読まない）。
# Tonal Balance EQ の mp（測定の一時停止）は TONAL_BALANCE_EQ_DEFAULTS にも getParameters にも
# 無く、画面の操作も無い。ライブラリの bindings だけが立てる実行時の旗。
# Adaptive Prediction（2.13.0）の resetToken は Reset を押すたびに増える数。kernel は値が変わったら学習を
# 捨てる。上流は getSerializableParameters で消し、プリセットの照合からも外す
# （getPresetComparisonExcludedKeys）。
RUNTIME_ONLY = {
    ("TonalBalanceEQPlugin", "measurementPaused"),
    ("AdaptivePredictionEffectPlugin", "resetToken"),
}


# ---------------------------------------------------------------- 鎖の語彙（chain/）

# 鎖の字では組めないもの。**手で持つ。**type -> 理由（英語。そのままindex.mdに出る）。
#
# 材料がparamsの外にあるものだけを入れる。paramsを持たないだけのMuteや
# Polarity Inversionは鎖に置けば働くので入れない。Matrixだけは経路（mx）が
# paramsに無く、鎖の字で書いても読まれない（MatrixRoutingが端末の中だけで持つ）。
# 残りはAssetReattach.swiftが入れ直している型とIR Reverb。
#
# 5Band FIR PEQ・Group Delay EQ / PEQ・FIR Crossoverは、設計の材料（pm / tp / f0など）を
# 鎖に持てるようになった（DSP/DesignParams.swift）。アプリから写した鎖は材料ごと戻る。
# ただし材料の鍵はこの語彙に載せていない（floatのparamsではないのでspecsに無い）ので、
# 依頼文で組ませると既定の設計にしかならない。「持てない」とは書かず「この一覧の鍵では
# 設計しない」と書く。材料を持てなかった頃のビルドにも同じ版の語彙が渡りうるが、どちらにも正しい。
CHAIN_UNSUPPORTED = {
    "MatrixPlugin": "its routing is set in the app and a chain cannot carry it",
    "IRReverbPlugin": "it needs an impulse response file that the user imports",
    "FiveBandFIRPEQPlugin": "its bands are designed in the app, not from the keys listed here",
    "GroupDelayEqPlugin": "its filter is designed in the app, not from the keys listed here",
    "GroupDelayPEQPlugin": "its filter is designed in the app, not from the keys listed here",
    "RoomEqPlugin": "it needs a room measurement made in the app",
    "CrosstalkCancellationPlugin": "it needs a measurement made in the app",
    "FIRCrossoverPlugin": "its crossover is designed in the app, not from the keys listed here",
    "SFZNotePlayerPlugin": "it needs an SFZ instrument that the user imports",
}

# 保存している値が見た目の数と違うもの。(type, メンバ名) -> (印, 説明)。
# **SCALESとは別の表。**あちらはアプリの画面が換算するものだけで、ここは
# 鎖を書く側が間違えるものを全部挙げる。Modal Resonatorの*Logも自然対数
# （modal_resonator.jsのLOG_20 / LOG_20000）だが、画面は生の数のまま見せている。
_LN_HZ = ("ln(Hz)", "natural log of the frequency in Hz: 3.0 = 20 Hz, 6.91 = 1 kHz, 9.9 = 20 kHz")
_POW10 = ("10^x", "exponent of the rate: -6 means 10^-6")
CHAIN_SCALED = {
    ("TiltEQPlugin", "pivotExponent"): _LN_HZ,
    ("ModalResonatorPlugin", "frequencyLog"): _LN_HZ,
    ("ModalResonatorPlugin", "lowPassLog"): _LN_HZ,
    ("ModalResonatorPlugin", "highPassLog"): _LN_HZ,
    ("DigitalErrorEmulatorPlugin", "bitErrorRateExponent"): _POW10,
    ("G726ADPCMSimulatorPlugin", "radioBitErrorExponent"): _POW10,
}


def allowed_values():
    """ETAllowedValuesの表をSwiftから読む。**写しを持たない。**

    決まった値しか取らない数（Oversamplingの1/2/4/8）は、範囲の中でも外れた値を
    decodeが黙って捨てる。語彙に書かないと鎖を書く側に分からない。
    表の正はETParamCoding.swiftで、ChainTextTestsが語彙と突き合わせる。
    """
    text = PARAM_CODING.read_text(encoding="utf-8")
    start = text.find("enum ETAllowedValues")
    end = text.find("\nenum ", start + 1)
    if start < 0:
        raise SystemExit("!! ETParamCoding.swiftにETAllowedValuesが無い")
    table = {}
    for m in re.finditer(r'"(\w+)\.(\w+)":\s*\[([^\]]*)\]', text[start:end if end > 0 else None]):
        table[(m.group(1), m.group(2))] = [float(v) for v in m.group(3).split(",") if v.strip()]
    return table


def run_git(*args):
    try:
        return subprocess.run(["git", *args], capture_output=True, text=True)
    except OSError:
        return None


def same_path(a, b):
    return os.path.normcase(os.path.realpath(a)) == os.path.normcase(os.path.realpath(b))


def vendor_is_checkout():
    """Vendor/effetuneが自前のgitの作業ツリーか。

    **Macへ送った木はgitではない**（.gitごと無い写し）。そこで版を確かめようとすると
    setup.shが毎回止まるので、確かめるのはgitの作業ツリーのときだけにする。
    Vendor/effetuneが空で上の木だけがgitのときも、上の木を答えるので外れる。
    """
    top = run_git("-C", str(VENDOR), "rev-parse", "--show-toplevel")
    return bool(top and top.returncode == 0 and top.stdout.strip()
                and same_path(top.stdout.strip(), VENDOR))


def check_vendor_pin():
    """固定した版と違うVendor/effetuneから作らない。

    このリポジトリが指しているgitlink（HEADかindexのどちらか）とVendorのHEADを比べる。
    違う版のまま走ると、カタログも語彙も黙ってその版へ変わる（Windowsの作業ツリーは
    dsp-v0.10.0のまま、固定は0.11.0だった）。**固定より新しいのも通さない。**
    タグの間のコミットはdescribeが前のタグの版を答えるので、前の版のフォルダ（chain/v<版>/）を
    上書きしてしまう。上流へ追従するときは、Vendorを進めてgit add Vendor/effetuneしてから
    走らせる（indexのgitlinkも固定として受ける）。
    """
    head = run_git("-C", str(VENDOR), "rev-parse", "HEAD")
    if not head or head.returncode != 0:
        return
    actual = head.stdout.strip()
    pins = set()
    for args in (("ls-tree", "HEAD", "Vendor/effetune"), ("ls-files", "--stage", "Vendor/effetune")):
        r = run_git("-C", str(ROOT), *args)
        if r and r.returncode == 0:
            m = re.search(r"\b([0-9a-f]{40})\b", r.stdout)
            if m:
                pins.add(m.group(1))
    if not pins or actual in pins:
        return
    raise SystemExit(
        "!! Vendor/effetune（%s）が固定した版（%s）と違う。"
        "戻すならgit submodule update --init Vendor/effetune、"
        "上流へ追従するならgit add Vendor/effetuneを先に"
        % (actual[:8], ", ".join(p[:8] for p in sorted(pins))))


def dsp_params_fingerprint(specs):
    """語彙の元になったDSPのパラメータの形。型ごとのハッシュとfloatの数から作る。

    上流がパラメータを変えると変わり、この生成器の直し（説明や表の書き方）では変わらない。
    effects.jsonに`dspParams`として残し、同じ版のフォルダを別の形で上書きしないのに使う。
    """
    h = hashlib.sha256()
    for s in sorted(specs, key=lambda x: x["type"]):
        h.update(("%s:%08x:%d\n" % (s["type"], s["hash"], s["floatCount"])).encode("utf-8"))
    return h.hexdigest()[:16]


def check_chain_folder(version, fingerprint):
    """chain/v<版>/が別のパラメータから作ってあれば止める。**何か書く前に呼ぶ。**

    版の名前は作業ツリーならdsp-v*のタグ、gitでない写し（Mac）では追跡してある
    UpstreamVersion.swiftから取る。どちらも中身より遅れることがある（タグの間のコミット、
    gen_version.pyより先に走るsetup.sh）。そのまま書くと前の版のフォルダが新しい中身で
    上書きされ、古いビルドの依頼が読む語彙が変わる。
    """
    old = CHAIN / ("v" + version) / "effects.json"
    if not old.exists():
        return
    try:
        recorded = json.loads(old.read_text(encoding="utf-8")).get("dspParams")
    except ValueError:
        recorded = None
    if recorded and recorded != fingerprint:
        raise SystemExit(
            "!! chain/v%s/は別のDSPのパラメータから作ってある（%s、いまは%s）。"
            "版の名前（dsp-v*のタグかUpstreamVersion.swift）が中身に追いついているか確かめる。"
            "置き換えてよいなら、そのフォルダを消してから走らせる"
            % (version, recorded, fingerprint))


def dsp_version(checkout):
    """語彙のフォルダに付ける版。

    gitの作業ツリーならgen_version.pyと同じくdsp-v*のタグから取る（追従の途中でも
    新しい版になる）。gitでない写しでは、追跡してあるUpstreamVersion.swiftを読む。
    """
    if checkout:
        r = run_git("-C", str(VENDOR), "describe", "--tags", "--match", "dsp-v*")
        if r and r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip().removeprefix("dsp-v").split("-")[0]
    m = re.search(r'ETUpstreamVersion\s*=\s*"([^"]+)"', UPSTREAM_VERSION.read_text(encoding="utf-8"))
    if not m:
        raise SystemExit("!! UpstreamVersion.swiftから版を読めない")
    return m.group(1)


def jnum(v):
    """JSONに書く数。整数で表せるものは整数で書く（20.0より20のほうが読みやすい）。"""
    v = float(v)
    return int(v) if v.is_integer() and abs(v) < 1e15 else v


def typed(info, raw):
    """floatの既定値を保存形式の型へ（ETParamCoding.tidyと同じ）。"""
    if info["kind"] == "enum":
        i = int(round(raw))
        return info["options"][i] if 0 <= i < len(info["options"]) else i
    if info["kind"] == "toggle":
        return raw >= 0.5
    return jnum(raw)


def md_value(v):
    if isinstance(v, bool):
        return "`true`" if v else "`false`"
    if isinstance(v, str):
        return "`\"%s\"`" % v.replace("|", "\\|")
    if isinstance(v, float):
        return "`%s`" % ("%.6g" % v)
    return "`%s`" % v


def md_key(p):
    if p["shape"] == "indexed":
        return "`%s0` … `%s%d`" % (p["key"], p["key"], p["count"] - 1)
    if p["shape"] == "object-array":
        return "`%s[].%s`" % (p["array"], p["key"])
    return "`%s`" % p["key"]


def md_shape(p):
    if p["shape"] == "indexed":
        return "indexed ×%d" % p["count"]
    if p["shape"] == "object-array":
        return "object array ×%d" % p["count"]
    if p["shape"] == "flat":
        return "flat array ×%d" % p["count"]
    return "scalar"


def md_values(p):
    if p["kind"] == "enum":
        text = "one of " + ", ".join(md_value(o) for o in p["options"])
    elif p["kind"] == "toggle":
        text = "`true` or `false`"
    else:
        text = "%s to %s" % (md_value(p["min"]), md_value(p["max"]))
        if p["step"]:
            text += ", step %s" % ("%.6g" % p["step"])
        # 10^xは印と同じ字なので2度書かない。
        if p["unit"] and p["unit"] != p.get("scale"):
            text += ", " + p["unit"].replace("|", "\\|")
    if "allowed" in p:
        text += "; only " + ", ".join(md_value(v) for v in p["allowed"])
    if "scale" in p:
        text += "; **%s**: %s" % (p["scale"], p["scaleNote"])
    return text


def md_default(p):
    d = p["default"]
    if not isinstance(d, list):
        return md_value(d)
    if all(x == d[0] for x in d):
        return "%s ×%d" % (md_value(d[0]), len(d))
    if len(d) > 16:
        return "%d values (see effects.json)" % len(d)
    return ", ".join(md_value(x) for x in d)


def check_chain_unsupported(specs):
    """CHAIN_UNSUPPORTEDの表の型が全部カタログに居るか。**何か書く前に呼ぶ。**"""
    types = {s["type"] for s in specs}
    missing = sorted(set(CHAIN_UNSUPPORTED) - types)
    if missing:
        raise SystemExit("!! CHAIN_UNSUPPORTEDにカタログに無い型がある: %s" % ", ".join(missing))


def write_chain(specs, version, fingerprint):
    """chain/v<版>/に語彙を書く。**書くのはその版のフォルダだけ。**"""
    check_chain_unsupported(specs)

    effects = []
    for s in sorted(specs, key=lambda x: (x["category"], x["name"])):
        e = {"nm": s["name"], "type": s["type"], "category": s["category"], "about": s["about"]}
        if s["type"] in CHAIN_UNSUPPORTED:
            e["unsupported"] = CHAIN_UNSUPPORTED[s["type"]]
        e["params"] = s["chain"]
        effects.append(e)

    folder = CHAIN / ("v" + version)
    folder.mkdir(parents=True, exist_ok=True)
    written = []

    def put(name, text):
        (folder / name).write_text(text, encoding="utf-8", newline="\n")
        written.append(name)

    # 1エフェクト1行。字下げすると16×16の行列が1要素1行に割れて160 KBを超える。
    rows = ",\n".join(json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in effects)
    put("effects.json", '{"dsp":%s,"dspParams":%s,"generator":"Tools/gen_catalog.py","effects":[\n%s\n]}\n'
        % (json.dumps(version), json.dumps(fingerprint), rows))

    categories = []
    for e in effects:
        if e["category"] not in categories:
            categories.append(e["category"])

    head = [
        "# EffectDeck effects, EffeTune DSP %s" % version,
        "",
        "Generated by `Tools/gen_catalog.py` from the effects EffectDeck is built with. Do not edit.",
        "",
        "Every effect name (`nm`) a chain can use, by category, with what the effect is for.",
        "The keys, ranges, options and defaults of each effect are in its category file.",
        "How to write the chain itself: [CHAIN.md](../../CHAIN.md).",
        "",
        "`Section` is not an effect. `{\"nm\":\"Section\",\"cm\":\"Name\"}` groups the stages after it,",
        "up to the next Section (see CHAIN.md).",
        "",
    ]
    for c in categories:
        head.append("## %s ([%s.md](%s.md))" % (c, c, c))
        head.append("")
        for e in (x for x in effects if x["category"] == c):
            line = "- `%s`" % e["nm"]
            if e["about"]:
                line += " — " + e["about"]
            if "unsupported" in e:
                line += ". **Not for chains:** %s." % e["unsupported"]
            head.append(line)
        head.append("")
    put("index.md", "\n".join(head))

    for c in categories:
        out = [
            "# %s effects, EffeTune DSP %s" % (c, version),
            "",
            "Generated by `Tools/gen_catalog.py`. Do not edit. All effect names: [index.md](index.md).",
            "",
            "Values are the stored values in the stored units. Write only the keys you change;",
            "the others keep the defaults shown. Shapes:",
            "",
            "- scalar: `\"vl\": -3`",
            "- indexed: one key per element, `\"f0\": 100, \"f1\": 316`",
            "- object array: `\"bs\": [{\"f\": 100}, {}, …]`, one object per element in order;",
            "  `{}` keeps that element's defaults. `bs[].f` below means member `f` of each object in `bs`.",
            "- flat array: `\"dm\": [1, 0, …]`, one number per element in order",
            "",
        ]
        for e in (x for x in effects if x["category"] == c):
            out.append("## %s" % e["nm"])
            out.append("")
            if e["about"]:
                out.append(e["about"] + ".")
                out.append("")
            if "unsupported" in e:
                out.append("**Not for chains:** %s." % e["unsupported"])
                out.append("")
                continue
            if not e["params"]:
                out.append("No keys: `{\"nm\":\"%s\"}`." % e["nm"])
                out.append("")
                continue
            out.append("| Key | Label | Shape | Values | Default |")
            out.append("|---|---|---|---|---|")
            for p in e["params"]:
                out.append("| %s | %s | %s | %s | %s |" % (
                    md_key(p), p["label"].replace("|", "\\|"), md_shape(p), md_values(p), md_default(p)))
            out.append("")
        put(c + ".md", "\n".join(out))

    # 同じ版のフォルダに残った古い分類だけ消す。他の版のフォルダは触らない。
    for old in folder.iterdir():
        if old.is_file() and old.name not in written:
            old.unlink()
    return folder


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

# この字や語の後ろの / は割り算ではなく正規表現リテラルの始まり。
REGEX_AFTER = set("(,=:[!&|?{};+-*%<>~^")
REGEX_AFTER_WORDS = {"return", "typeof", "case", "do", "else", "in", "instanceof", "new", "delete",
                     "void", "throw", "yield", "await", "of"}


def regex_end(t, i):
    """t[i] の / から始まる正規表現リテラルの終わり（フラグの後ろ）。同じ行で閉じなければ None。"""
    j, n = i + 1, len(t)
    in_class = False
    while j < n:
        c = t[j]
        if c == "\n":
            return None
        if c == BS:
            j += 2
            continue
        if c == "[":
            in_class = True
        elif c == "]":
            in_class = False
        elif c == "/" and not in_class:
            j += 1
            while j < n and (t[j].isalnum() or t[j] in "_$"):
                j += 1
            return j
        j += 1
    return None


def strip_comments(t):
    """// と /* */ を空白に潰す。文字列と正規表現リテラルの中は触らない。行数は変えない。

    **正規表現リテラルを飛ばす。**`s.replace(/'/g, '')` の ' を文字列の始まりと取ると、
    次の ' までが文字列になってその間のコメントが残り、そこから先が食い違う
    （コメントの中の ' で閉じた後ろのコードがコメント扱いで消える）。
    / が割り算か正規表現かは、直前の字（演算子や括弧の後ろなら正規表現）で決める。
    ただし ++ と -- の後ろは割り算（count++ / 2）。++ の後ろに正規表現は来ない（リテラルは
    増やせない）。+ や - が隙間なく続くときは 2 つずつ ++ / -- になるので、続いた数が偶数なら
    最後は ++ / --、奇数なら最後は 1 つの + / -（a+++/x/ は a++ + /x/）。
    """
    out = []
    i, n = 0, len(t)
    quote = None
    esc = False
    last = ""      # コメントの外で最後に書いた空白でない字
    run = 0        # last と同じ字が隙間なく続いた数（++ と -- を見分ける）
    word = ""      # last が語の終わりなら、その語
    gap = False    # last の後ろに空白かコメントを挟んだか（語が続いているか）
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
                last, run, word, gap = c, 1, "", False
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
            gap = True
            continue
        if c == "/" and t[i + 1:i + 2] == "*":
            j = t.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in t[i:j]))
            i = j
            gap = True
            continue
        after_update = last in ("+", "-") and run % 2 == 0     # ++ か -- の後ろ（値の後ろ）
        if c == "/" and not after_update and \
                (last == "" or last in REGEX_AFTER or word in REGEX_AFTER_WORDS):
            j = regex_end(t, i)
            if j is not None:
                out.append(t[i:j])
                i = j
                last, run, word, gap = ")", 1, "", False    # リテラルの後ろは値。次の / は割り算
                continue
        out.append(c)
        if c.isspace():
            gap = True
        else:
            if c.isalnum() or c in "_$":
                word = word + c if word and not gap else c
            else:
                word = ""
            run = run + 1 if c == last and not gap else 1
            last, gap = c, False
        i += 1
    return "".join(out)


OPENERS = "([{"
CLOSERS = ")]}"


def split_args(t, lp, close=")"):
    """t[lp] が '('（close が ']' なら '['）のとき、トップレベルのカンマで割った引数を返す。

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
            if depth == 0 and c == close:
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


JS_NUMS = r"[-+]?(?:\d+\.?\d*|\.\d+)"
CONST_ARRAY = re.compile(
    r"\bconst\s+([A-Z_][A-Z0-9_]*)\s*=\s*(?:Object\.freeze\(\s*)?"
    r"\[\s*(%s(?:\s*,\s*%s)*)\s*,?\s*\]" % (JS_NUMS, JS_NUMS))
CONST_OBJECT = re.compile(r"\bconst\s+([A-Z_][A-Z0-9_]*)\s*=\s*Object\.freeze\(\s*\{")
OBJECT_RANGE = re.compile(r"(\w+)\s*:\s*\[\s*(%s(?:\s*,\s*%s)*)\s*,?\s*\]" % (JS_NUMS, JS_NUMS))
SPREAD = re.compile(r"\.\.\.\s*([A-Z_][A-Z0-9_]*)(?:\.(\w+))?")


def const_number_lists(text):
    """ファイルの先頭にある数だけの定数配列を引けるようにする。

      const RHYTHM_ANALYZER_MN_RANGE = [40, 192];                  -> (NAME, None)
      const TONAL_BALANCE_EQ_RANGES = Object.freeze({ tc: [20, 1000], … })   -> (NAME, 'tc')

    戻り値は (定数名, キーか None) -> "40, 192"（数をカンマで繋いだ文字列）。
    """
    table = {}
    for m in CONST_ARRAY.finditer(text):
        table[(m.group(1), None)] = ", ".join(x.strip() for x in m.group(2).split(","))
    for m in CONST_OBJECT.finditer(text):
        # 対応する } まで。入れ子の {} は数えるが、文字列の中の括弧までは見ない（定数の表だけ読む）。
        depth, i = 1, m.end()
        while i < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        for mm in OBJECT_RANGE.finditer(text[m.end():i]):
            table[(m.group(1), mm.group(1))] = ", ".join(x.strip() for x in mm.group(2).split(","))
    return table


def resolve_spreads(text):
    """createParameterControl('Min BPM', ...MN_RANGE, 1, …) の ...定数 を、数に置き換える。

    **spread は引数 1 つに見えるので、そのままだと後ろの引数が全部 1 つずつずれる**
    （Rhythm Analyzer の Min BPM は刻みも単位も取れず、Tonal Balance EQ の Corner は
    ラベルを取れなかった）。数だけの定数配列（と、その配列を持つ Object.freeze の表）の
    spread だけ解く。読めないものはそのまま。行は変わらない。
    """
    table = const_number_lists(text)

    def sub(m):
        return table.get((m.group(1), m.group(2)), m.group(0))
    return SPREAD.sub(sub, text)


def read_ui(path, keys):
    """createUI が画面に出しているものを key ごとに集める。

    戻り値は key -> {label, unit, lo, hi, step, line}。
    unit と範囲は取れなかったら None（params.json の値をそのまま使う合図）。
    line は画面での並び順に使う。
    """
    text = resolve_spreads(strip_comments(path.read_text(encoding="utf-8", errors="replace")))
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
        elif (first is None and string_of(at(args, 1)) in keys
              and string_of(at(args, 2)) is not None
              and (len(args) <= 6 or string_of(args[6]) is not None)):
            # 第1引数が置き場所（DOM 要素）で、key とラベルがその後ろに来る形。
            #   adaptive_prediction_effect.js:155  addParameter(predictionControls, 'gap', 'Gap', 0, 500, 0.1, 'ms')
            # 8 番目（toDisplay）があると目盛りがモデル値そのものでない（Weight Decay の 0 は
            # 無限大）ので、createParameterControl と同じく範囲も単位も持ってこない。
            # 7 番目が単位の字でないもの（phase_select_eq.js の _createNumberField は getter）は
            # 別の形なので拾わない。
            lo = hi = step = unit = None
            if len(args) <= 7:
                lo, hi, step = (number_of(at(args, 3)), number_of(at(args, 4)),
                                number_of(at(args, 5)))
                unit = "" if len(args) <= 6 else string_of(at(args, 6))
                if lo is None or hi is None or step is None:
                    lo = hi = step = unit = None
            put(string_of(at(args, 1)), m.start(), label=string_of(at(args, 2)),
                unit=unit, lo=lo, hi=hi, step=step)

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

    # 4. 行を表で持ち、ループで作成関数に渡しているもの（sfz_note_player.js:522, 526）。
    #      for (const [key, label] of [['hi', 'Highest'], ['md', 'Middle'], …]) createCheckboxControl(…)
    #      for (const [key, labelText, min, max, step, unit] of [['th', 'Threshold', 0.01, 1, 0.01, ''], …])
    #    中身が [key, ラベル] か [key, ラベル, 最小, 最大, 刻み, 単位] のリテラルだけの配列を拾う。
    #    ほかの段で取れなかった key にしか効かない。同じ行に並ぶ行は書いた順に並べる
    #    （行番号が同じだと params.json の順になり、Highest / Middle / Lowest が逆になる）。
    for m in TUPLE_ROW.finditer(text):
        args = split_args(text, m.start(), close="]")
        if args is None or len(args) not in (2, 6):
            continue
        key, label = string_of(args[0]), string_of(args[1])
        if key not in keys or key in found or label is None:
            continue
        lo = hi = step = unit = None
        if len(args) == 6:
            lo, hi, step = number_of(args[2]), number_of(args[3]), number_of(args[4])
            unit = string_of(args[5])
            if lo is None or hi is None or step is None or unit is None:
                continue
        put(key, m.start(), label=label, unit=unit, lo=lo, hi=hi, step=step)
        line = found[key]["line"]
        found[key]["line"] = line + (m.start() - text.rfind("\n", 0, m.start())) / 10000.0

    return found


# [ 'key', 'Label' … ] の始まり。split_args は開き括弧の位置から読む。
TUPLE_ROW = re.compile(r"\[(?=\s*(?:'[^'\\]*'|\"[^\"\\]*\")\s*,\s*(?:'|\"|this\._t\s*\())")


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


def js_string(expr):
    """JSの文字列の式（'a' + "b"）を1つの字へ。戻すエスケープは引用符だけ（名前と説明にほかは出ない）。"""
    text = "".join(a or b for a, b in JS_PART.findall(expr))
    return text.replace("\\'", "'").replace('\\"', '"')


def display_name(type_name, category, folder):
    """EffeTune の JS が持っている製品名を拾う。無ければ型名から作る。"""
    js = JS_PLUGINS / category / (folder + ".js")
    if js.exists():
        m = SUPER.search(js.read_text(encoding="utf-8", errors="replace"))
        if m:
            return js_string(m.group(1)), js_string(m.group(2))
    return camel_to_words(type_name.replace("Plugin", "")), ""


def main():
    if not DSP.exists():
        sys.exit("Vendor/effetune が無い。git submodule update --init を先に。")

    # **書き始める前に版を確かめる。**固定と違うVendorから作ると、カタログも語彙もその版へ変わる。
    checkout = vendor_is_checkout()
    if checkout:
        check_vendor_pin()
    version = dsp_version(checkout)
    allowed = allowed_values()

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
        check_array_shape(meta, type_name, category, folder)

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
        for (t, k), after in UI_AFTER.items():
            if t == type_name and k in ui and after in ui:
                ui[k] = dict(ui[k], line=ui[after]["line"] + 0.5)

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

            # 上流がオブジェクト配列で書くもの。
            #   "bs": [{"en": …, "ft": …}, …]
            # 平らな "en": [...] にすると段の en と衝突して潰れ、web 版も
            # 同梱プリセットも読めない（Sources/EffeTuneLive/DSP/EffectSpec.swift の
            # objectArrayKey のコメントに経緯）。
            extra = ""
            if is_flat_array(type_name, f):
                extra += ", flatArrayKey: %s" % swift_str(f["arrayKey"])
            oak, mk = f.get("objectArrayKey"), f.get("memberKey")
            if oak and mk and mcount > 1:
                extra += ", objectArrayKey: %s, memberKey: %s" % (
                    swift_str(oak), swift_str(mk))
                stat["objarr"] = stat.get("objarr", 0) + 1

            # 保存値と表示値がずれるもの。表を明示で持つ。名前から当てない。
            scale = SCALES.get((type_name, mname))
            if scale:
                extra += ", scale: .%s" % scale
            runtime_only = (type_name, mname) in RUNTIME_ONLY
            if runtime_only:
                extra += ", runtimeOnly: true"

            # 鎖の語彙（chain/）に書く1行。鍵は保存形式で実際に書く名前にする
            # （オブジェクト配列はmemberKey、平らな配列はarrayKey。ETParamCodingと同じ）。
            info = {"key": key, "label": label}
            if is_flat_array(type_name, f):
                info.update(key=f["arrayKey"], shape="flat", count=mcount)
            elif oak and mk and mcount > 1:
                info.update(key=mk, shape="object-array", array=oak, count=mcount)
            elif mcount > 1:
                info.update(shape="indexed", count=mcount)
            else:
                info["shape"] = "scalar"
            if kind == "enum":
                info.update(kind="enum", options=list(f.get("values", [])))
            elif kind == "bool":
                info["kind"] = "toggle"
            else:
                info.update(kind="number", min=jnum(lo), max=jnum(hi), step=jnum(step or 0),
                            unit=unit)
            if (type_name, key) in allowed:
                info["allowed"] = [jnum(v) for v in allowed[(type_name, key)]]
            if (type_name, mname) in CHAIN_SCALED:
                info["scale"], info["scaleNote"] = CHAIN_SCALED[(type_name, mname)]

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
            else:
                vals = [dv_f] * mcount
            defaults.extend(vals)
            # 要素ごとの既定値を全部書く。ETParam.defaultValueは先頭の1つしか持たない。
            info["default"] = ([typed(info, v) for v in vals] if mcount > 1
                               else typed(info, vals[0]))

            if runtime_only:
                info["runtimeOnly"] = True
            params.append((
                u.get("line"),
                "        ETParam(name: %s, key: %s, label: %s, kind: %s, defaultValue: %r, "
                "offset: %d, count: %d%s)"
                % (swift_str(mname), swift_str(key), swift_str(label),
                   kind_swift, dv_f, offset, mcount, extra),
                info))
            offset += mcount

        if offset != float_count:
            skipped.append((type_name, "詰め幅が合わない %d != %d" % (offset, float_count)))
            continue

        # 画面の並びは createUI が足した順。詰め順（offset）とは別なので、
        # ここで並べ替えても et_instance_set_params に渡す配列は変わらない。
        order = display_order([p[0] for p in params])
        ordered = [params[i][1] for i in order]
        if ordered != [p[1] for p in params]:
            stat["order"] += 1

        name, about = display_name(type_name, category, folder)
        specs.append({
            "type": type_name, "name": name, "about": about, "category": category,
            "hash": phash, "floatCount": float_count,
            "params": ordered, "defaults": defaults,
            "chain": [params[i][2] for i in order if not params[i][2].get("runtimeOnly")],
        })

    # **外した型は黙らない。**そのエフェクトはアプリから消える。CI（ET_STRICT=1）では何も書かずに止める。
    if skipped:
        print("!! 外したもの（カタログに入らない＝アプリから消える）:", file=sys.stderr)
        for t, why in skipped:
            print("!!   %-34s %s" % (t, why), file=sys.stderr)
        if strict_mode():
            sys.exit("!! 外した型が %d ある（ET_STRICT）。何も書いていない" % len(skipped))

    text = render_catalog(specs)

    # 語彙のフォルダと表を確かめてからカタログを書く。止まるならどちらも書かない。
    fingerprint = dsp_params_fingerprint(specs)
    check_chain_folder(version, fingerprint)
    check_chain_unsupported(specs)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8", newline="\n")

    folder = write_chain(specs, version, fingerprint)

    print("書いた: %s" % OUT.relative_to(ROOT))
    print("書いた: %s/（鎖の語彙）" % folder.relative_to(ROOT).as_posix())
    print("エフェクト %d 種 / パラメータ %d 個"
          % (len(specs), sum(len(s["params"]) for s in specs)))
    print("createUI から: 名前 %d / 単位 %d / 範囲 %d / 並べ替えた型 %d"
          % (stat["label"], stat["unit"], stat["range"], stat["order"]))
    print("createUI に出てこないパラメータ %d 個は params.json のまま" % stat["miss"])
    if skipped:
        print("外したもの %d 型（上の !! を見る）" % len(skipped))


def render_catalog(specs):
    """EffectCatalog.swift の中身。分類・名前の順に1つの配列リテラルへ並べる。

    Tests/Linux/make_package.py の split_catalog はこの形（`let ETCatalog: [ETEffect] = [` の下に
    `    ETEffect(` の塊が並ぶ）を前提に1件ずつの定数へ分けて写す。形を変えるならあちらも一緒に。
    """
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
    return "\n".join(lines)


if __name__ == "__main__":
    main()
