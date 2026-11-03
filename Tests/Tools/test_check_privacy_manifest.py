"""Tools/check_privacy_manifest.py の試験。stdlibだけ（Tests/Toolsの他の試験の道具には頼らない）。

    python -m unittest discover -s Tests/Tools -p "test_check_privacy_manifest.py"

- 実物のリポジトリ（project.ymlと3本のマニフェスト）がそのまま通ること
- 起動からの秒が字になっている間は、アプリのマニフェストに3D61.1があること。3D61.1を
  外すときは、秒の渡し先が追えなければ落とす（見張りが形の変化で黙らないように）
- 使っているのに申告が無い分類で落ちること（静的ライブラリの分はアプリの分）
- 出すバンドルの種類ごとにマニフェストが要ること、project.ymlの読めない形・無いパスで落ちること
- grepが注釈・字・メンバー呼び出しに騙されないこと
- マニフェストの無効な形（TN3181）を拾うこと
- --binary は cc と nm があるときだけ（Linuxのオブジェクトで同じ道を通す）
"""
import contextlib
import importlib.util
import io
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
TOOL = ROOT / "Tools" / "check_privacy_manifest.py"
_loaded = 0


def load():
    global _loaded
    _loaded += 1
    spec = importlib.util.spec_from_file_location("check_privacy_manifest_%d" % _loaded, TOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def write(path, text):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    return path


def manifest(categories=None, **top):
    data = {"NSPrivacyTracking": False, "NSPrivacyCollectedDataTypes": []}
    if categories:
        data["NSPrivacyAccessedAPITypes"] = [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategory" + cat,
             "NSPrivacyAccessedAPITypeReasons": list(reasons)}
            for cat, reasons in categories.items()]
    data.update(top)
    return plistlib.dumps(data)


PROJECT = """\
name: Sample
targets:
  # アプリ。静的ライブラリLibを畳み込む
  App:
    type: application
    sources:
      - path: App
        excludes: ["**/*.icon/**"]
      - path: Shared
        excludes:
          - "Skip.*"
      - path: Vendor/lib
        includes: ["**/*.c"]
        excludes: ["**/*test*.c"]
      - path: Resources
        buildPhase: resources
    dependencies:
      - target: Lib
      - target: Share
        embed: true
  Lib:
    type: library.static
    sources:
      - path: Lib
  Share:
    type: app-extension
    sources:
      - path: Share
  Tests:
    type: bundle.unit-test
    sources:
      - path: Tests
"""


class Repo:
    """試験用のリポジトリ。App / Share の2本を出す。"""

    def __enter__(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="privacy-"))
        write(self.root / "project.yml", PROJECT)
        write(self.root / "App/Main.swift", "let x = 1\n")
        write(self.root / "Share/Share.swift", "let y = 2\n")
        write(self.root / "Lib/lib.c", "int lib(void) { return 0; }\n")
        write(self.root / "Shared/Keep.c", "int keep;\n")
        write(self.root / "Vendor/lib/a.c", "int a;\n")
        write(self.root / "Tests/T.swift", "import Foundation\nlet d = UserDefaults.standard\n")
        self.set_manifest("App")
        self.set_manifest("Share")
        return self

    def __exit__(self, *exc):
        shutil.rmtree(self.root, ignore_errors=True)
        return False

    def set_manifest(self, target, categories=None, **top):
        (self.root / target / "PrivacyInfo.xcprivacy").write_bytes(manifest(categories, **top))

    def run(self, *args, bundles=None):
        mod = load()
        mod.BUNDLES = {"App": "App/PrivacyInfo.xcprivacy", "Share": "Share/PrivacyInfo.xcprivacy"}
        mod.BUNDLES.update(bundles or {})
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = mod.main(["--repo", str(self.root)] + list(args))
        return code, out.getvalue()


# MARK: - 起動からの秒が字になるか（3D61.1の見張り）
#
# ETLogTapの行には壁時計の時刻が付くので、そこへsystemUptimeをそのまま書くと起動時刻が出る。
# ログの末尾はReport a problemの本文に入って端末の外へ出る（人が見て送る）ので3D61.1が要る。
# 見るのは1ファイルの中の流れだけ:
# - 秒を読んだ所（systemUptime / mach_absolute_time()）と、それを入れた名前（let/varと代入）
# - 秒をそのまま返す関数・計算プロパティ（return の値か、1式だけの本体）は、呼んだ所を読んだ所と
#   同じに数える（何段でも・ファイルをまたいでも）。型の中の宣言は、括らずに呼ぶのは同じファイルの中
#   だけ・括って呼ぶ（x.now()）のはどこでも。大域の宣言はどこでも。.now() は DispatchTime などの別物
# - 引き算の片側は「間隔」なので追わない（アプリの開始からの秒にすれば3D61.1は外せる）
# - 秒が String( / String(format: / "\( )" / ETLogTap.record( の中に入れば「字になった」
# - 他の関数へ渡した所は、その関数の定義を探す。定義が見つからない・定義のあるファイルが
#   ETLogTap.recordを呼ぶ・Stringを返す なら「追えない」。3D61.1を外すときだけこれで落とす
# 追わないもの: 引数として受けた先で溜めた値を、別の所で字にする流れ（1段より深いところ）。

_UPTIME_READ = re.compile(r"(?:\bProcessInfo\s*\.\s*processInfo\s*\.\s*)?\bsystemUptime\b"
                          r"|\bmach_absolute_time\s*\(\s*\)")
_TEXT_SINKS = {"String", "NSString", "record", "appendingFormat", "localizedStringWithFormat",
               "print", "debugPrint", "NSLog"}
# 値の形を変えるだけの呼び出しと、括りの括弧（外側の文脈を見る）
_SAME_VALUE = {"", "[", "Double", "Float", "Float64", "Int", "Int64", "UInt64", "TimeInterval",
               "CGFloat", "max", "min", "abs", "round", "floor", "ceil",
               "if", "guard", "while", "switch", "case", "return", "try", "await", "in", "else",
               # 標準の入れ物へ入れるだけ（アプリに同じ名前のfuncがあっても、名前では分けられない）
               "append", "insert", "merge", "updateValue"}
_FUNC_START = re.compile(r"\bfunc\b|\binit\s*[?!]?\s*[(<]")
_LOCAL_BIND = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::[^=]*)?=(?!=)")
_ASSIGN = re.compile(r"(?:^|[{;])\s*(?:self\s*\.\s*)?(\w+)\s*[+*/]?=(?!=)")
_CONTINUATION = re.compile(r"^\s*(?:\.(?!\.)|\+|-(?!>)|\*|/|\?\?|&&|\|\||\?|:(?!:))")
_CONDITION = re.compile(r"^\s*(?:\}\s*else\s+)?(?:if|guard|while)\b")


def _blank_strings(mod, code):
    """字の中身を空白にする（行は保つ）。\\( ) の中はコードなので残す。"""
    out, i, n = [], 0, len(code)
    while i < n:
        c = code[i]
        if c == '"' or (c == "#" and re.match(r'#+"', code[i:i + 8])):
            j = mod._string_end(code, i, True)
            out.append(_keep_interpolations(mod, code[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _keep_interpolations(mod, lit):
    if lit.startswith("#"):
        return re.sub(r"[^\n]", " ", lit)
    out, i, n = [], 0, len(lit)
    while i < n:
        if lit.startswith("\\(", i):
            j = mod._interpolation_end(lit, i + 2)
            out.append("\\(" + _blank_strings(mod, lit[i + 2:j - 1]) + ")")
            i = j
        elif lit[i] == "\\" and i + 1 < n:
            out.append(" " + ("\n" if lit[i + 1] == "\n" else " "))
            i += 2
        else:
            out.append("\n" if lit[i] == "\n" else " ")
            i += 1
    return "".join(out)


def _statements(code):
    """[(始まりの行, 文)]。括弧が閉じるまでと、演算子・.で始まる続きの行を1つにつなぐ。"""
    out, buf, start, depth = [], [], 1, 0
    for number, line in enumerate(code.split("\n"), 1):
        if not buf:
            start = number
        buf.append(line)
        for c in line:
            if c in "([":
                depth += 1
            elif c in ")]":
                depth = max(0, depth - 1)
        if depth == 0:
            text = " ".join(buf)
            buf = []
            if not text.strip():
                continue
            if out and _CONTINUATION.match(text):
                out[-1] = (out[-1][0], out[-1][1] + " " + text)
            else:
                out.append((start, text))
    if buf:
        out.append((start, " ".join(buf)))
    return out


def _in_difference(s, a, b):
    """s[a:b]が引き算の片側か（括りの括弧は越えて見る）。"""
    after = s[b:].lstrip(" \t)")
    if after.startswith("-") and not after.startswith(("->", "-=")):
        return True
    before = s[:a].rstrip(" \t(")
    if before.endswith("-"):
        prev = before[:-1].rstrip()
        return bool(prev) and (prev[-1].isalnum() or prev[-1] in "_)]")
    return False


def _rhs_end(s, start):
    """代入の右辺の終わり。if / guard / while の条件では次の , か { まで。"""
    if not _CONDITION.match(s):
        return len(s)
    depth = 0
    for i in range(start, len(s)):
        c = s[i]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif depth == 0 and c in ",{":
            return i
    return len(s)


def _contexts(s, p):
    """s[p]を囲む括弧を内から外へ。呼び出しはその名前、\\( は "\\(", [ は "["。"""
    stack = []
    for i in range(p):
        c = s[i]
        if c == "(":
            if i and s[i - 1] == "\\":
                stack.append("\\(")
                continue
            j = i - 1
            while j >= 0 and s[j] in " \t":
                j -= 1
            k = j
            while k >= 0 and (s[k].isalnum() or s[k] == "_"):
                k -= 1
            stack.append(s[k + 1:j + 1])
        elif c == "[":
            stack.append("[")
        elif c in ")]" and stack:
            stack.pop()
    return stack[::-1]


def _close(code, i, opening, closing):
    """code[i]の開き括弧に対応する閉じの次の位置。"""
    depth = 0
    for j in range(i, len(code)):
        if code[j] == opening:
            depth += 1
        elif code[j] == closing:
            depth -= 1
            if depth == 0:
                return j + 1
    return len(code)


_DECL = re.compile(r"\bfunc\s+(\w+)|\bvar\s+(\w+)\s*:")
# 名前の後ろから本体の { までにこれがあれば、本体の無い宣言（protocolの要件・保存するvar）。
# { が次の行にある書き方（Allman）は読むので、改行では切らない
_HEAD_STOP = re.compile(r"[}=;]|\b(?:func|var|let|init|subscript|case|struct|class|enum|protocol"
                        r"|extension|actor|typealias|deinit|if|guard|for|while|switch|do|repeat|return)\b")


def _decl_bodies(code):
    """[(名前, funcか, 大域か, 本体)]。値を返す関数（-> がある）と計算プロパティだけ。"""
    out, depth, at = [], 0, 0
    for m in _DECL.finditer(code):
        chunk = code[at:m.start()]
        depth, at = depth + chunk.count("{") - chunk.count("}"), m.start()
        is_func, name, i = m.group(1) is not None, m.group(1) or m.group(2), m.end()
        if is_func:
            j = code.find("(", i)
            if j < 0 or (code[i:j].strip() and not code[i:j].lstrip().startswith("<")):
                continue
            i = _close(code, j, "(", ")")
        brace = code.find("{", i)
        head = code[i:brace]
        if brace < 0 or _HEAD_STOP.search(head) or (is_func and "->" not in head):
            continue
        body = code[brace + 1:_close(code, brace, "{", "}") - 1]
        if not is_func and re.match(r"\s*(?:didSet|willSet)\b", body):
            continue
        out.append((name, is_func, depth == 0, body))
    return out


def _expr_end(text):
    """return の後ろの式。閉じていない } か深さ0の ; まで。"""
    depth = 0
    for i, c in enumerate(text):
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth < 0:
                return text[:i]
        elif c == ";" and depth == 0:
            return text[:i]
    return text


def _read_re(sources, rel):
    """relの中で秒を読む形: systemUptime / mach_absolute_time() と、秒を返す関数・計算プロパティ。"""
    pats = [_UPTIME_READ.pattern]
    for name, is_func, is_global, where in sorted(sources):
        qualified = r"(?<=[\w)\]?!]\.)"  # x.now / self.now / f().now（.now だけは別の型の静的メンバー）
        before = r"(?:%s|(?<![\w.]))" % qualified if (is_global or where == rel) else qualified
        after = r"(?=\s*\()" if is_func else r"(?!:)"
        pats.append(r"%s%s\b%s" % (before, re.escape(name), after))
    return re.compile("|".join(pats))


def _read_spans(s, read_re, names=()):
    """秒を読んだ所 [(始まり, 終わり)]。呼び出しは括弧の閉じまで（now() - began を引き算と見るため）。"""
    spans = []
    for m in read_re.finditer(s):
        a, b = m.start(), m.end()
        call = re.match(r"\s*\(", s[b:])
        if call and not s[a:b].endswith(")"):
            b = _close(s, b + call.end() - 1, "(", ")")
        spans.append((a, b))
    names = sorted(names, key=len, reverse=True)
    if names:
        pat = r"(?:(?<=self\.)|(?<![\w.]))(%s)\b(?!:)" % "|".join(map(re.escape, names))
        spans += [(m.start(1), m.end(1)) for m in re.finditer(pat, s)]
    return spans


def _returns_uptime(body, read_re):
    """本体が秒をそのまま返すか（return の値・return の無い1文だけの本体・get { } の中）。"""
    inner = re.match(r"\s*get\s*\{", body)
    if inner:
        rest = body[inner.end() - 1:]
        body = rest[1:_close(rest, 0, "{", "}") - 1]
    stmts = [s for _, s in _statements(body)]
    exprs = [_expr_end(s[m.end():]) for s in stmts for m in re.finditer(r"\breturn\b", s)]
    if not exprs and len(stmts) == 1 and not (_LOCAL_BIND.search(stmts[0]) or _ASSIGN.search(stmts[0])):
        exprs = stmts
    names = set()  # 本体の中で秒を入れた名前（let up = …; return up）
    for s in stmts:
        for m in _LOCAL_BIND.finditer(s):
            rhs = s[m.end():_rhs_end(s, m.end())]
            if any(not _in_difference(rhs, a, b) for a, b in _read_spans(rhs, read_re, names)):
                names.add(m.group(1))
    return any(not _in_difference(e, a, b) and all(c in _SAME_VALUE for c in _contexts(e, a))
               for e in exprs for a, b in _read_spans(e, read_re, names))


def uptime_flow(mod, texts):
    """texts: {rel: Swiftの中身}。戻りは(字になった所 ['rel:行'], 渡した所 [(rel, 行, 呼んだ名前)])。"""
    codes = {rel: _blank_strings(mod, mod.strip_comments(texts[rel], swift=True)) for rel in sorted(texts)}
    decls = {rel: _decl_bodies(code) for rel, code in codes.items()}
    # 秒を返す関数・計算プロパティ {(名前, funcか, 大域か, rel)}。返す値がまた別の関数の値でも追う
    sources = set()
    while True:
        found = set()
        for rel, code in codes.items():
            read_re = _read_re(sources, rel)
            found |= {(name, is_func, is_global, rel) for name, is_func, is_global, body in decls[rel]
                      if (name, is_func, is_global, rel) not in sources and _returns_uptime(body, read_re)}
        if not found:
            break
        sources |= found
    carriers, handed = [], []
    for rel, code in codes.items():
        read_re = _read_re(sources, rel)
        local, prop = set(), set()
        for line, s in _statements(code):
            if _FUNC_START.search(s):
                local = set()
            # (名前, 名前の位置, 右辺の始まり, 右辺の終わり, 入れる先)
            binds = [(m.group(1), m.start(1), m.end(), _rhs_end(s, m.end()), into)
                     for rx, into in ((_LOCAL_BIND, local), (_ASSIGN, prop)) for m in rx.finditer(s)]
            targets = {at for _, at, _, _, _ in binds}
            spans = _read_spans(s, read_re, local | prop)
            live = [(a, b) for a, b in spans if a not in targets and not _in_difference(s, a, b)]
            if not live:
                continue
            for name, _, begin, end, into in binds:
                if any(begin <= a < end for a, _ in live):
                    into.add(name)
            place = "%s:%d" % (rel, line)
            for a, _ in live:
                ctx = _contexts(s, a)
                if any(c == "\\(" or c in _TEXT_SINKS for c in ctx):
                    if place not in carriers:
                        carriers.append(place)
                    continue
                callee = next((c for c in ctx if c not in _SAME_VALUE), None)
                if callee and (rel, line, callee) not in handed:
                    handed.append((rel, line, callee))
    return carriers, handed


def untraced(mod, texts, handed):
    """渡した先のうち、字にしていないと言えないもの ['rel:行 → 名前（訳）']。"""
    codes = {rel: _blank_strings(mod, mod.strip_comments(t, swift=True)) for rel, t in texts.items()}
    out = []
    for rel, line, callee in handed:
        if callee[:1].isupper():
            pat = re.compile(r"\b(?:struct|class|enum|actor)\s+%s\b" % re.escape(callee))
        else:
            pat = re.compile(r"\bfunc\s+%s\b" % re.escape(callee))
        defs = [(r, m.end()) for r, code in codes.items() for m in pat.finditer(code)]
        why = "定義が無い" if not defs else None
        for r, end in defs:
            if re.search(r"\bETLogTap\s*\.\s*record\s*\(", codes[r]):
                why = "%sがETLogTap.recordを呼ぶ" % r
            elif not callee[:1].isupper():
                brace = codes[r].find("{", end)
                if re.search(r"->\s*(?:String|Substring|NSString)\b", codes[r][end:brace if brace >= 0 else None]):
                    why = "%sのfunc %sがStringを返す" % (r, callee)
        if why:
            out.append("%s:%d → %s（%s）" % (rel, line, callee, why))
    return out


class UptimeFlowTests(unittest.TestCase):
    """uptime_flow / untraced が、形を変えても字になる流れを取りこぼさないこと。"""

    def flow(self, **files):
        mod = load()
        texts = {name.replace("_", "/") + ".swift": text for name, text in files.items()}
        carriers, handed = uptime_flow(mod, texts)
        return carriers, untraced(mod, texts, handed)

    def test_bound_then_formatted_then_recorded(self):
        # いまのAudioIOの形（t=は起動からの秒）
        carriers, _ = self.flow(A=(
            "func tick() {\n"
            "    let up = ProcessInfo.processInfo.systemUptime\n"
            "    let line = String(format: \"peer %@ t=%.3f\",\n"
            "                      nowPeer ? \"up\" : \"down\", up)\n"
            "    ETLogTap.record(line)\n"
            "}\n"))
        self.assertEqual(carriers, ["A.swift:3", "A.swift:5"])

    def test_inlined_into_format_arguments(self):
        carriers, _ = self.flow(A="let line = String(format: \"t=%.3f\", ProcessInfo.processInfo.systemUptime)\n")
        self.assertEqual(carriers, ["A.swift:1"])

    def test_interpolation_and_conversions(self):
        carriers, _ = self.flow(A="func f() {\n    let up = Double(mach_absolute_time())\n"
                                  "    ETLogTap.record(\"t=\\(max(0, up))\")\n}\n")
        self.assertEqual(carriers, ["A.swift:3"])

    def test_helper_that_returns_the_line(self):
        helper = "enum RouteLog {\n    static func line(t: Double) -> String { String(format: \"t=%.3f\", t) }\n}\n"
        carriers, _ = self.flow(A=(
            "func f() {\n    let up = ProcessInfo.processInfo.systemUptime\n"
            "    let line = RouteLog.line(t: up)\n    ETLogTap.record(line)\n}\n"), B=helper)
        self.assertEqual(carriers, ["A.swift:4"])
        carriers, _ = self.flow(A="ETLogTap.record(RouteLog.line(t: ProcessInfo.processInfo.systemUptime))\n", B=helper)
        self.assertEqual(carriers, ["A.swift:1"])

    def test_property_carries_across_functions(self):
        carriers, _ = self.flow(A=(
            "func a() {\n    lastUp = ProcessInfo.processInfo.systemUptime\n}\n"
            "func b() {\n    ETLogTap.record(String(format: \"%.3f\", lastUp))\n}\n"))
        self.assertEqual(carriers, ["A.swift:5"])

    def test_value_returned_by_a_helper_or_computed_property(self):
        # 読む所を関数・計算プロパティへ移しても、呼んだ所で読んだのと同じに数える
        carriers, _ = self.flow(A=(
            "func uptimeNow() -> Double {\n    return ProcessInfo.processInfo.systemUptime\n}\n"
            "func tick() {\n    ETLogTap.record(String(format: \"t=%.3f\", uptimeNow()))\n}\n"))
        self.assertEqual(carriers, ["A.swift:5"])
        carriers, _ = self.flow(A=(
            "var stamp: Double { ProcessInfo.processInfo.systemUptime }\n"
            "func tick() {\n    ETLogTap.record(\"t=\\(stamp)\")\n}\n"))
        self.assertEqual(carriers, ["A.swift:3"])
        # { を次の行に置く書き方
        carriers, _ = self.flow(A=(
            "var stamp: Double\n{\n    ProcessInfo.processInfo.systemUptime\n}\n"
            "func tick()\n{\n    ETLogTap.record(\"t=\\(stamp)\")\n}\n"))
        self.assertEqual(carriers, ["A.swift:7"])
        # 別のファイルの型の中（名前で括って呼ぶ）・大域の関数（括らずに呼ぶ）・名前に入れてから返す
        carriers, _ = self.flow(
            A="func tick() {\n    let up = Clock.now()\n    ETLogTap.record(\"t=\\(up)\")\n}\n",
            B="enum Clock {\n    static func now() -> Double {\n"
              "        Double(mach_absolute_time()) / 1e9\n    }\n}\n")
        self.assertEqual(carriers, ["A.swift:3"])
        carriers, _ = self.flow(
            A="ETLogTap.record(String(uptimeNow()))\n",
            B="func uptimeNow() -> Double {\n    let up = ProcessInfo.processInfo.systemUptime\n    return up\n}\n")
        self.assertEqual(carriers, ["A.swift:1"])
        # 返す値がまた別の関数の値（get の中・何段でも）
        carriers, _ = self.flow(A=(
            "var stamp: Double {\n    get { base() }\n    set { }\n}\n"
            "func base() -> Double { max(0, ProcessInfo.processInfo.systemUptime) }\n"
            "func tick() { ETLogTap.record(\"t=\\(stamp)\") }\n"))
        self.assertEqual(carriers, ["A.swift:6"])

    def test_only_declarations_with_a_value_body(self):
        # protocolの要件・保存するvar・値を返さない関数・関数の中の var t: Double の次の if は本体でない
        code = ("protocol P {\n    func now() -> Double\n    var up: Double { get }\n}\n"
                "final class S {\n    var stored: Double\n    init() { stored = 0 }\n"
                "    var level: Double = 0 { didSet { } }\n"
                "    func f() {\n        var t: Double\n        if ready { t = 1 }\n    }\n"
                "    lazy var formatter: DateFormatter = {\n        let f = DateFormatter()\n        return f\n    }()\n"
                "    func g<T>(_ x: T) -> Double\n    {\n        1\n    }\n    var late: Double\n    deinit { }\n}\n"
                "var top: Double { 2 }\n")
        self.assertEqual([(name, is_func, is_global) for name, is_func, is_global, _ in _decl_bodies(code)],
                         [("up", False, False), ("g", True, False), ("top", False, True)])

    def test_returned_interval_and_other_names_are_not_reads(self):
        # 返すのが間隔なら追わない。起動からの秒を返す関数も、引き算の片側なら間隔
        carriers, untraced_ = self.flow(A=(
            "func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - start }\n"
            "final class State {\n    func now() -> Double {\n"
            "        return Double(mach_absolute_time()) * 1e-9\n    }\n}\n"
            "func tick() {\n    ETLogTap.record(\"e=\\(elapsed())\")\n"
            "    let began = state.now()\n    let spent = state.now() - began\n"
            "    ETLogTap.record(\"spent=\\(spent)\")\n}\n"
            # 同じファイルの引数 now（関数の now ではない）と、値を返さない関数の中で比べるだけの秒
            "func g(now: Double) { ETLogTap.record(\"n=\\(now)\") }\n"
            "func poll() { if ProcessInfo.processInfo.systemUptime > deadline { fire() } }\n"
            "func arm() { DispatchQueue.main.async(execute: { poll() }) }\n"
            # 見張り（willSet）の付いた保存するプロパティは、秒を返すものではない
            "var level: Double {\n    willSet { if ProcessInfo.processInfo.systemUptime > deadline { fire() } }\n}\n"
            "func show() { ETLogTap.record(\"l=\\(level)\") }\n"),
            # 同じ名前の別物: 他のファイルで括らずに呼ぶ now()（引数の autoclosure）と .now()（DispatchTime）
            B="func pick(now: @autoclosure () -> [Int]) -> String {\n    let current = now()\n"
              "    q.asyncAfter(deadline: .now() + 30) {}\n    return \"\\(current)\"\n}\n")
        self.assertEqual((carriers, untraced_), ([], []))

    def test_since_app_start_is_an_interval(self):
        carriers, untraced_ = self.flow(A=(
            "func tick() {\n"
            "    let up = ProcessInfo.processInfo.systemUptime - ETLogTap.origin\n"
            "    let line = String(format: \"t=%.3f\", up)\n"
            "    ETLogTap.record(line)\n"
            "    let gap = (ProcessInfo.processInfo.systemUptime) - last\n"
            "    ETLogTap.record(\"gap=\\(gap)\")\n"
            "}\n"))
        self.assertEqual((carriers, untraced_), ([], []))

    def test_string_contents_and_comments_are_not_code(self):
        carriers, _ = self.flow(A=(
            "func f() {\n    let up = ProcessInfo.processInfo.systemUptime\n"
            "    // ETLogTap.record(String(up))\n"
            "    ETLogTap.record(String(format: \"%@ up\", up2 ? \"up\" : \"down\"))\n}\n"))
        self.assertEqual(carriers, [])

    def test_handed_to_a_pure_rule_is_cleared(self):
        rule = "struct Rule {\n    mutating func observe(now: TimeInterval) -> Bool { now > 1 }\n}\n"
        carriers, untraced_ = self.flow(A=(
            "func f() {\n    let now = ProcessInfo.processInfo.systemUptime\n"
            "    if rule.observe(now: now) {\n        ETLogTap.record(\"rebuild\")\n    }\n}\n"), B=rule)
        self.assertEqual((carriers, untraced_), ([], []))

    def test_handed_to_a_logger_or_unknown_is_untraced(self):
        logger = "enum Diag {\n    static func route(t: Double) { ETLogTap.record(\"\\(t)\") }\n}\n"
        carriers, untraced_ = self.flow(A="Diag.route(t: ProcessInfo.processInfo.systemUptime)\n", B=logger)
        self.assertEqual(carriers, [])
        self.assertEqual(len(untraced_), 1)
        self.assertIn("A.swift:1 → route", untraced_[0])
        _, untraced_ = self.flow(A="let d = Date(timeIntervalSinceNow: ProcessInfo.processInfo.systemUptime)\n")
        self.assertEqual(len(untraced_), 1)
        self.assertIn("定義が無い", untraced_[0])
        _, untraced_ = self.flow(A="let s = RouteLog.stamp(ProcessInfo.processInfo.systemUptime)\n",
                                 B="enum RouteLog {\n    static func stamp(_ t: Double)\n        -> String { \"\" }\n}\n")
        self.assertIn("Stringを返す", untraced_[0])


def _app_swift_texts():
    mod = load()
    targets = mod.parse_yaml((ROOT / "project.yml").read_text(encoding="utf-8"))["targets"]
    files, _ = mod.bundle_sources(ROOT, targets, "EffeTuneLive")
    return mod, {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in sorted(set(files))
                 if rel.endswith(".swift")}


class RealRepositoryTests(unittest.TestCase):
    def test_repository_manifests_cover_sources(self):
        mod = load()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = mod.main([])
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("OK", out.getvalue())

    def test_every_shipped_bundle_has_a_manifest_file(self):
        mod = load()
        for target, rel in mod.BUNDLES.items():
            declared, errors = mod.read_manifest(ROOT / rel)
            self.assertEqual(errors, [], "%s: %s" % (target, errors))
            self.assertTrue(declared, target)

    def test_yaml_forms_xcodegen_accepts(self):
        mod = load()
        doc = mod.parse_yaml(
            "a:\n"
            "  - {path: X, excludes: [\"*.h\", 'b''c'], optional: true}\n"
            "  - |\n    line1\n    line2: not a key\n"
            "b: >-\n  folded\n  text\n"
            "c: [1, [2, 3], {k: v}]\n"
            "d: &anchor\n  e: f\n"
            "url: http://x.y/z\n")
        self.assertEqual(doc["a"][0], {"path": "X", "excludes": ["*.h", "b'c"], "optional": "true"})
        self.assertEqual(doc["a"][1], "line1\nline2: not a key")
        self.assertEqual(doc["b"].split(), ["folded", "text"])
        self.assertEqual(doc["c"], ["1", ["2", "3"], {"k": "v"}])
        self.assertEqual(doc["d"], {"e": "f"})
        self.assertEqual(doc["url"], "http://x.y/z")
        for bad in ("a: [1, 2\n", "a: {k: v\n", "a: 1\n    b: 2\n", "a:\n  - x\n b: 1\n"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                mod.parse_yaml(bad)

    def test_project_yml_is_read(self):
        mod = load()
        targets = mod.parse_yaml((ROOT / "project.yml").read_text(encoding="utf-8"))["targets"]
        self.assertEqual(targets["EffeTuneLive"]["type"], "application")
        self.assertEqual(targets["YSFX"]["type"], "library.static")
        self.assertEqual(targets["EffectDeckShare"]["type"], "app-extension")
        self.assertEqual(targets["EffeTuneLiveExtension"]["type"], "extensionkit-extension")
        share = [s if isinstance(s, str) else s["path"] for s in targets["EffectDeckShare"]["sources"]]
        self.assertIn("Sources/EffeTuneLive/DSP/ETShareInbox.swift", share)
        ysfx = targets["YSFX"]["sources"][0]
        self.assertEqual(ysfx["path"], "Vendor/ysfx/sources")
        self.assertIn("ysfx_utils_fts.cpp", ysfx["excludes"])
        self.assertIn({"target": "YSFX"}, targets["EffeTuneLive"]["dependencies"])

    def test_uptime_in_report_log_declares_bug_report_reason(self):
        # 起動からの秒が字になる所があれば3D61.1が要る。無ければ外してよいが、そのときは秒の
        # 渡し先がすべて追えること（追えないまま外すと、形が変わっただけで見張りが黙る）。
        mod, texts = _app_swift_texts()
        carriers, handed = uptime_flow(mod, texts)
        declared, errors = mod.read_manifest(ROOT / "Sources/EffeTuneLive/PrivacyInfo.xcprivacy")
        self.assertEqual(errors, [])
        if "3D61.1" in declared.get("SystemBootTime", set()):
            return
        self.assertEqual(carriers, [], "起動からの秒が字になって報告のログへ行く。3D61.1を戻すか、"
                                       "アプリの開始からの秒（引き算）にする")
        self.assertEqual(untraced(mod, texts, handed), [],
                         "起動からの秒の渡し先が追えない。3D61.1を残すか、渡し先で字にしない形にする")


class SourceModeTests(unittest.TestCase):
    def test_missing_category_fails(self):
        with Repo() as repo:
            write(repo.root / "App/Store.swift", "let v = UserDefaults.standard.bool(forKey: \"a\")\n")
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"MISSING UserDefaults .*App/Store.swift:1")

    def test_declared_category_passes(self):
        # --strictで回す（@AppStorageを拾えないと、申告だけ残ってUNUSEDで落ちる）
        with Repo() as repo:
            write(repo.root / "App/Store.swift", "@AppStorage(\"k\") var k = 0\n")
            repo.set_manifest("App", {"UserDefaults": ["CA92.1"]})
            code, out = repo.run("--strict")
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r"ok +UserDefaults +CA92\.1 +App/Store\.swift:1  @AppStorage")

    def test_static_library_counts_for_the_app(self):
        # 静的なフレームワークも中身はアプリの実行ファイルへ入る
        for kind in ("library.static", "framework.static"):
            with self.subTest(kind=kind), Repo() as repo:
                write(repo.root / "project.yml", PROJECT.replace("type: library.static", "type: " + kind, 1))
                write(repo.root / "Lib/io.c", "#include <sys/stat.h>\nint f(int fd) { struct stat s; return fstat(fd, &s); }\n")
                code, out = repo.run()
                self.assertEqual(code, 1, out)
                self.assertRegex(out, r"MISSING FileTimestamp .*Lib/io.c:2")
                repo.set_manifest("App", {"FileTimestamp": ["C617.1"]})
                code, out = repo.run()
                self.assertEqual(code, 0, out)

    def test_each_bundle_is_judged_on_its_own_sources(self):
        with Repo() as repo:
            write(repo.root / "Share/Clock.swift", "let t = ProcessInfo.processInfo.systemUptime\n")
            repo.set_manifest("App", {"SystemBootTime": ["35F9.1"]})
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"Share  Share/PrivacyInfo.xcprivacy\n  MISSING SystemBootTime")
        self.assertRegex(out, r"UNUSED  SystemBootTime")

    def test_includes_and_excludes_follow_xcodegen(self):
        with Repo() as repo:
            write(repo.root / "Shared/Skip.c", "unsigned long long t(void) { return mach_absolute_time(); }\n")
            write(repo.root / "Vendor/lib/sub/fs_test.c", "int g(const char *p) { return statfs(p, 0); }\n")
            write(repo.root / "Vendor/lib/sub/fs.h", "int h(const char *p) { return statfs(p, 0); }\n")
            write(repo.root / "App/Icon.icon/x.swift", "let d = UserDefaults.standard\n")
            write(repo.root / "Resources/r.swift", "let d = UserDefaults.standard\n")
            code, out = repo.run()
            self.assertEqual(code, 0, out)
            write(repo.root / "Vendor/lib/sub/fs.c", "int g(const char *p) { return statfs(p, 0); }\n")
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"MISSING DiskSpace .*Vendor/lib/sub/fs.c:1")

    def test_unit_test_bundle_is_not_shipped(self):
        with Repo() as repo:
            code, out = repo.run()
        self.assertEqual(code, 0, out)
        self.assertNotIn("Tests/T.swift", out)

    def test_every_shipped_type_needs_a_bundle_entry(self):
        # 種類はここに書き写す（ツールの表を読むと、表から消えても気づけない）。
        # 出さないと言える種類（試験・道具・畳み込む静的なもの）の外は、知らない種類も出すものとして扱う
        extra = "  Widget:\n    type: %s\n    sources:\n      - path: Share\n"
        for kind in ("application", "app-extension", "extensionkit-extension", "framework",
                     "app-extension.messages", "app-extension.intents-service", "library.dynamic",
                     "xpc-service", "bundle", "no-such-type"):
            with self.subTest(kind=kind), Repo() as repo:
                write(repo.root / "project.yml", PROJECT + extra % kind)
                code, out = repo.run()
                self.assertEqual(code, 1, out)
                self.assertIn("Widget（%s）は出すバンドルなのにBUNDLESに無い" % kind, out)
        with Repo() as repo:
            write(repo.root / "project.yml", PROJECT + "  Widget:\n    sources:\n      - path: Share\n")
            code, out = repo.run()
            self.assertEqual(code, 1, out)
            self.assertIn("Widget（typeが無い）は出すバンドルなのにBUNDLESに無い", out)
        for kind in ("library.static", "framework.static", "bundle.unit-test", "bundle.ui-testing",
                     "bundle.ocunit-test", "tool"):
            with self.subTest(kind=kind), Repo() as repo:
                write(repo.root / "project.yml", PROJECT + extra % kind)
                code, out = repo.run()
                self.assertEqual(code, 0, out)

    def test_bundle_entry_missing_from_project_fails(self):
        with Repo() as repo:
            code, out = repo.run(bundles={"Gone": "Gone/PrivacyInfo.xcprivacy"})
        self.assertEqual(code, 1, out)
        self.assertIn("BUNDLESのGoneがproject.ymlに無い", out)

    def test_block_scalar_does_not_hide_later_targets(self):
        script = ("    type: application\n    preBuildScripts:\n      - name: Embed\n"
                  "        script: |\n          set -e\n          echo \"a: b\"\n\n          bash x.sh\n"
                  "        basedOnDependencyAnalysis: false\n")
        with Repo() as repo:
            write(repo.root / "project.yml", PROJECT.replace("    type: application\n", script, 1))
            write(repo.root / "Share/Clock.swift", "let t = ProcessInfo.processInfo.systemUptime\n")
            write(repo.root / "Lib/io.c", "int f(int fd) { struct stat s; return fstat(fd, &s); }\n")
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertNotIn("project.ymlに無い", out)
        self.assertRegex(out, r"MISSING FileTimestamp .*Lib/io.c:1")
        self.assertRegex(out, r"Share  Share/PrivacyInfo.xcprivacy\n  MISSING SystemBootTime")

    def test_flow_mapping_source_is_scanned(self):
        with Repo() as repo:
            write(repo.root / "project.yml",
                  PROJECT.replace("      - path: Lib\n", "      - {path: Lib, excludes: [\"skip/**\"]}\n", 1))
            write(repo.root / "Lib/io.c", "int f(int fd) { struct stat s; return fstat(fd, &s); }\n")
            write(repo.root / "Lib/skip/fs.c", "int g(const char *p) { return statfs(p, 0); }\n")
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"MISSING FileTimestamp .*Lib/io.c:1")
        self.assertNotIn("DiskSpace", out)

    def test_unreadable_project_yml_stops(self):
        with Repo() as repo:
            write(repo.root / "project.yml",
                  PROJECT.replace("    type: library.static\n", "    type: library.static\n      stray: 1\n", 1))
            code, out = repo.run()
        self.assertEqual(code, 2, out)
        self.assertIn("行目が読めない", out)

    def test_missing_source_path_fails_unless_optional_or_generated(self):
        with Repo() as repo:
            write(repo.root / "project.yml",
                  PROJECT.replace("      - path: Share\n", "      - path: Share\n      - path: Sahred\n", 1))
            code, out = repo.run()
            self.assertEqual(code, 1, out)
            self.assertIn("sourcesのSahredが無い", out)
            write(repo.root / "project.yml", PROJECT.replace(
                "      - path: Share\n",
                "      - path: Share\n      - path: Sahred\n        optional: true\n      - path: Generated/models\n", 1))
            code, out = repo.run()
        self.assertEqual(code, 0, out)
        self.assertIn("NOTE Share: Sahredが無い", out)
        self.assertIn("NOTE Share: Generated/modelsが無い", out)

    def test_missing_manifest_fails_even_without_api_use(self):
        with Repo() as repo:
            (repo.root / "Share/PrivacyInfo.xcprivacy").unlink()
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertIn("マニフェストが無い", out)

    def test_missing_vendor_is_a_note_unless_required(self):
        with Repo() as repo:
            shutil.rmtree(repo.root / "Vendor/lib")
            (repo.root / "Vendor/lib").mkdir()
            code, out = repo.run()
            self.assertEqual(code, 0, out)
            self.assertIn("NOTE App: Vendor/lib", out)
            code, out = repo.run("--require-vendor")
        self.assertEqual(code, 1, out)

    def test_unused_declaration_warns_and_strict_fails(self):
        with Repo() as repo:
            repo.set_manifest("App", {"DiskSpace": ["E174.1"]})
            code, out = repo.run()
            self.assertEqual(code, 0, out)
            self.assertIn("UNUSED  DiskSpace", out)
            code, out = repo.run("--strict")
        self.assertEqual(code, 1, out)


class GrepTests(unittest.TestCase):
    def hits(self, text, name="x.swift"):
        mod = load()
        with tempfile.TemporaryDirectory() as tmp:
            path = write(pathlib.Path(tmp) / name, text)
            return [(cat, place.split(":")[1]) for cat, place, _ in mod.scan_file(path, name)]

    def test_comments_do_not_count(self):
        self.assertEqual(self.hits("// UserDefaults\n/* systemUptime\n /* nested */ mach_absolute_time() */\nlet a = 1\n"), [])
        self.assertEqual(self.hits("/* stat(p) */ int a; // fstat(fd)\n", "x.c"), [])

    def test_string_with_slashes_does_not_hide_code(self):
        self.assertEqual(self.hits('let u = "https://x"; let t = mach_absolute_time()\n'), [("SystemBootTime", "1")])
        self.assertEqual(self.hits('let s = "\\(a ?? "//") \\(ProcessInfo.processInfo.systemUptime)"\n'),
                         [("SystemBootTime", "1")])
        self.assertEqual(self.hits('let r = #"a"b//"#; let d = UserDefaults.standard\n'), [("UserDefaults", "1")])
        self.assertEqual(self.hits('let m = """\n// UserDefaults\n"""\n'), [("UserDefaults", "2")])
        self.assertEqual(self.hits("char q = '\"'; int r = lstat(p, &s); // '\n", "x.c"), [("FileTimestamp", "1")])

    def test_member_calls_and_prefixes_do_not_count(self):
        src = "int lstate = 0;\nobj.stat(1);\np->fstat(2);\nfstatus(3);\nstruct stat s;\n#include <sys/stat.h>\n"
        self.assertEqual(self.hits(src, "x.cpp"), [])
        self.assertEqual(self.hits("::stat(p, &s);\nfstat (fd, &s);\n", "x.cpp"),
                         [("FileTimestamp", "1"), ("FileTimestamp", "2")])

    def test_foundation_names(self):
        src = ("fm.setAttributes([.modificationDate: Date()], ofItemAtPath: p)\n"
               "let k: URLResourceKey = .contentModificationDateKey\n"
               "let c = attrs[.creationDate]\n"
               "let f = attrs[.systemFreeSize]\n"
               "let v = URLResourceKey.volumeAvailableCapacityForImportantUsageKey\n"
               "let m = UITextInputMode.activeInputModes\n"
               "let values = try url.resourceValues(forKeys: [.fileSizeKey])\n"
               "let x = values.contentModificationDate\n")
        self.assertEqual(self.hits(src), [("FileTimestamp", "1"), ("FileTimestamp", "2"), ("FileTimestamp", "3"),
                                          ("DiskSpace", "4"), ("DiskSpace", "5"), ("ActiveKeyboards", "6")])
        self.assertEqual(self.hits("[NSUserDefaults standardUserDefaults];\nNSFileModificationDate;\n"
                                   "CFPreferencesCopyAppValue(k, a);\n", "x.m"),
                         [("UserDefaults", "1"), ("FileTimestamp", "2"), ("UserDefaults", "3")])

    def test_module_qualified_calls_count(self):
        # 型に同じ名前のメンバーがあると Darwin.stat( と書く。モジュール名で括っても C の関数
        src = ("let r = Darwin.stat(path, &st)\nlet q = Darwin.lstat(path, &st)\n"
               "let u = Darwin.mach_absolute_time()\nlet g = Glibc.fstat(fd, &st)\n"
               "let f = Foundation.statfs(p, &s)\nlet m = box.Darwin.stat(p)\n")
        self.assertEqual(self.hits(src), [("FileTimestamp", "1"), ("FileTimestamp", "2"), ("SystemBootTime", "3"),
                                          ("FileTimestamp", "4"), ("DiskSpace", "5")])

    def test_getattrlist_counts_for_both_categories(self):
        self.assertEqual(sorted(self.hits("getattrlist(p, &l, b, n, 0);\n", "x.c")),
                         [("DiskSpace", "1"), ("FileTimestamp", "1")])

    def test_ignore_marker(self):
        self.assertEqual(self.hits("let d = model.creationDate // privacy-manifest: ignore 記事の作成日\n"), [])


class ManifestTests(unittest.TestCase):
    def errors(self, data):
        mod = load()
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "PrivacyInfo.xcprivacy"
            path.write_bytes(data if isinstance(data, bytes) else plistlib.dumps(data))
            return mod.read_manifest(path)

    def assertInvalid(self, data, fragment):
        _, errors = self.errors(data)
        self.assertTrue(any(fragment in e for e in errors), "%r not in %r" % (fragment, errors))

    def base(self, **extra):
        data = {"NSPrivacyTracking": False, "NSPrivacyCollectedDataTypes": []}
        data.update(extra)
        return data

    def api(self, cat, reasons):
        return {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategory" + cat,
                "NSPrivacyAccessedAPITypeReasons": reasons}

    def test_valid(self):
        declared, errors = self.errors(self.base(NSPrivacyAccessedAPITypes=[
            self.api("UserDefaults", ["CA92.1", "1C8F.1"]), self.api("DiskSpace", ["E174.1"])]))
        self.assertEqual(errors, [])
        self.assertEqual(declared, {"UserDefaults": {"CA92.1", "1C8F.1"}, "DiskSpace": {"E174.1"}})

    def test_tn3181_shapes(self):
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[]), "NSPrivacyAccessedAPITypesが空")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("UserDefaults", [])]), "理由が空")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("Camera", ["CA92.1"])]), "知らない分類")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("UserDefaults", ["35F9.1"])]),
                           "UserDefaultsの理由に35F9.1は無い")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("SystemBootTime", ["35F9.1"]),
                                                                self.api("SystemBootTime", ["8FFB.1"])]), "2回ある")
        self.assertInvalid(self.base(NSPrivacyTrackingDomains=["t.example.com"]), "falseなのに")
        self.assertInvalid(self.base(NSPrivacyTracking=True, NSPrivacyTrackingDomains=[]), "trueなのに")
        self.assertInvalid(self.base(NSPrivacyTracking="NO"), "Booleanでない")
        self.assertInvalid(self.base(NSPrivacyTracking=True, NSPrivacyTrackingDomains=["https://t.example.com/"]),
                           "追跡ドメインの形")
        self.assertInvalid(self.base(NSPrivacyUnknown=1), "知らない鍵 NSPrivacyUnknown")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[dict(self.api("UserDefaults", ["CA92.1"]), Extra=1)]),
                           "知らない鍵 Extra")
        self.assertInvalid(b"<plist><dict><key>a</key></plist>", "plistとして読めない")

    def test_sdk_only_reasons_rejected_in_app(self):
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("UserDefaults", ["C56D.1"])]), "third-party SDK")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("FileTimestamp", ["0A2A.1"])]), "third-party SDK")

    def test_app_policy(self):
        self.assertInvalid({"NSPrivacyCollectedDataTypes": []}, "NSPrivacyTrackingをfalse")
        self.assertInvalid({"NSPrivacyTracking": False}, "NSPrivacyCollectedDataTypesを配列")
        self.assertInvalid(self.base(NSPrivacyCollectedDataTypes=[{
            "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeCrashData",
            "NSPrivacyCollectedDataTypeLinked": False, "NSPrivacyCollectedDataTypeTracking": False,
            "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]}]),
            "何も集めない")


def _tool(name):
    return shutil.which(name)


@unittest.skipUnless(_tool("cc") and _tool("nm"), "cc と nm が要る（Linux/Mac）")
class BinaryModeTests(unittest.TestCase):
    """--binary。Linuxではオブジェクトファイル（ELF）で同じ道を通す。Macでは.appのMach-Oを読む。"""

    C = r"""
#include <sys/stat.h>
extern unsigned long long mach_absolute_time(void);
const char selectors[] = "\0systemUptime\0";
int f(int fd) { struct stat s; return fstat(fd, &s) + (int)mach_absolute_time(); }
"""

    def build_app(self, root, with_manifest):
        app = root / "Sample.app"
        (app / "PlugIns" / "Share.appex").mkdir(parents=True)
        src = write(root / "main.c", self.C)
        subprocess.run(["cc", "-c", "-o", str(app / "Sample"), str(src)], check=True)
        with open(app / "Info.plist", "wb") as f:
            plistlib.dump({"CFBundleExecutable": "Sample"}, f)
        write(root / "empty.c", "int nothing(void) { return 0; }\n")
        subprocess.run(["cc", "-c", "-o", str(app / "PlugIns/Share.appex/Share"), str(root / "empty.c")], check=True)
        if with_manifest:
            (app / "PrivacyInfo.xcprivacy").write_bytes(
                manifest({"FileTimestamp": ["C617.1"], "SystemBootTime": ["35F9.1"]}))
        return app

    def run_binary(self, app):
        mod = load()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = mod.main(["--binary", str(app), "-v"])
        return code, out.getvalue()

    def test_imports_and_selectors_are_found(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.build_app(pathlib.Path(tmp), with_manifest=False)
            code, out = self.run_binary(app)
        self.assertEqual(code, 1, out)
        self.assertIn("マニフェストが無い", out)
        self.assertRegex(out, r"MISSING FileTimestamp .*fstat")
        self.assertRegex(out, r"MISSING SystemBootTime .*mach_absolute_time \(\+1\)\n +Sample  systemUptime\n")

    def test_debug_dylib_is_read(self):
        # XcodeのDebugでは実行ファイルは殻で、中身は<App>.debug.dylibにある
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            app = self.build_app(root, with_manifest=False)
            (app / "Sample").replace(app / "Sample.debug.dylib")
            subprocess.run(["cc", "-c", "-o", str(app / "Sample"), str(root / "empty.c")], check=True)
            code, out = self.run_binary(app)
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"MISSING FileTimestamp .*Sample.debug.dylib  fstat")

    def test_declared_passes_and_clean_extension_needs_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.build_app(pathlib.Path(tmp), with_manifest=True)
            code, out = self.run_binary(app)
        self.assertEqual(code, 0, out)
        self.assertIn("Share.appex", out)
        self.assertIn("Required Reason APIは見つからない", out)


if __name__ == "__main__":
    unittest.main()
