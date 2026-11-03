#!/usr/bin/env python3
"""check_privacy_manifest.py
出すバンドルごとに、Required Reason API（Appleのprivacy manifest）の申告漏れを見る。
標準ライブラリだけ（CIのLinuxでもMacでもそのまま走る）。

    python3 Tools/check_privacy_manifest.py                   # ソースをgrepして照合
    python3 Tools/check_privacy_manifest.py --require-vendor  # Vendorのsubmoduleが無ければ落とす
    python3 Tools/check_privacy_manifest.py --binary <.app|.xcarchive>  # 建てたものをnm -uで照合
    python3 Tools/check_privacy_manifest.py -v                # 見つけた場所を全部出す

- **どのソースがどのバンドルへ入るかはproject.ymlが決める。**ここに一覧を持たない。
  静的ライブラリ（YSFX）は、それに依存するバンドルの分として数える
- 出さないと言える種類（試験・道具・静的なもの）の外のターゲットがBUNDLESに無ければ落とす。
  知らない種類・typeの無いものも出すものとして扱う。ターゲットを足したときにマニフェストを忘れないため
- 分類・APIの名前・理由の表はAppleの「Describing use of required reason API」
  （NSPrivacyAccessedAPITypeの値、2026-09に読んだもの）を写した。理由は表にあるかだけを
  見る。どれを選ぶかは人が決める（いま選んでいる理由とその訳はCATEGORIESの下に書いた）
- マニフェストの形はTN3181の「無効」の条件で見る（空のNSPrivacyAccessedAPITypes、
  空の理由、NSPrivacyTracking=falseなのに追跡ドメインがある、知らない鍵、など）。
  加えてこのアプリの約束（site/src/text.jsのPRIVACY: 何も集めない・追跡しない）とも照らす
- 使っているのに申告が無い分類があれば1で落ちる。申告してあるのに使っていない分類は
  警告だけ（--strictで落とす）
- 行に「privacy-manifest: ignore」と書くと、その行の一致を数えない。名前がたまたま同じ
  別物のためで、訳も同じ行に書く
- grepなので#ifの分岐は読まないし、含めたヘッダーの中も追わない。本当に積まれているかは
  --binaryで見る（App Store Connectが見るのも実行ファイルが引いている名前）
"""
import argparse
import os
import pathlib
import plistlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = "PrivacyInfo.xcprivacy"

# 出すバンドル（project.ymlのターゲット名）と、そのマニフェスト。
# マニフェストはターゲットのフォルダに置けば、xcodegenが拡張子を知らないファイルとして
# Copy Bundle Resourcesへ入れる（XcodeGenのSourceGenerator.getDefaultBuildPhase）。
BUNDLES = {
    "EffeTuneLive": "Sources/EffeTuneLive/" + MANIFEST,
    "EffeTuneLiveExtension": "Sources/Extension/" + MANIFEST,
    "EffectDeckShare": "Sources/ShareExtension/" + MANIFEST,
}
# 出さない種類（試験・道具）。これとFOLDED_TYPESの外は、知らない種類も含めて出すものとして扱う
# （app-extension.messages・library.dynamic・xpc-serviceなどを足したときに黙って読まないままにしない）
NOT_SHIPPED_TYPES = {"bundle.unit-test", "bundle.ui-testing", "bundle.ocunit-test", "tool"}
# 中身が依存するバンドルの実行ファイルへ入る種類。そのバンドルの分として数える
FOLDED_TYPES = {"library.static", "framework.static"}
# sources:のパスが無くても落とさない所。Vendor/はsubmodule（--require-vendorで落とす）、
# Generated/はScripts/setup.shが作る（.gitignore。新しいcloneには無い）。それ以外で無いのは書き違い
VENDOR_PREFIX = "Vendor/"
GENERATED_PREFIXES = ("Generated/",)

PREFIX = "NSPrivacyAccessedAPICategory"
# 分類 -> 使ってよい理由（Appleの表）。
CATEGORIES = {
    "FileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "SystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "DiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "ActiveKeyboards": {"3EC4.1", "54BD.1"},
    "UserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}
# 「third-party SDKだけが申告できる」とAppleが書いている理由。アプリと拡張では使えない。
SDK_ONLY = {"0A2A.1", "C56D.1"}

# いま選んでいる理由とその訳（照合には使わない。マニフェストを直すときに読む）。
#   FileTimestamp  C617.1  JSFXの取り込み（Application Support）とApp GroupのInboxの
#                          更新日時で並べる・古い箱を捨てる。ysfxのfstatは読んだファイルの
#                          dev/inodeを取る。どれもアプリの入れ物の中。人には見せない（DDA9.1は要らない）
#   SystemBootTime 35F9.1  systemUptime / mach_absolute_timeは間隔を測るためだけ（処理時間・
#                          作り直しの間隔・テレメトリの遅れ・ドライバーのゼロ時刻の周期）
#                  3D61.1  アプリだけ。AudioIOが経路と接続の行に「t=<systemUptime>」を書き、
#                          ETLogTapは行ごとに壁時計の時刻を付ける（2つを引くと起動時刻が出る）。
#                          その末尾がReport a problemのメール・GitHub issueの本文に入り、人が見て
#                          送るかを決める。t=をアプリの開始からの秒にすれば35F9.1だけで済む
#                          （Tests/Toolsのtest_uptime_in_report_log_declares_bug_report_reasonが見張る）
#                          **Attach logは3D61.1の外。**ログの全体（最大1MB）を中身を見せずに共有シートへ
#                          渡すので、「報告の一部として人に目立つように見せる」を満たさない。直すのは
#                          AudioIOのt=（アプリの開始からの秒にする）。そうすれば3D61.1ごと外せる
#   UserDefaults   CA92.1  UserDefaults.standardだけ。App Groupのsuiteは使っていない（1C8F.1は要らない）

# このアプリの約束（site/src/text.jsのPRIVACY）。集めるものを足すなら、先にそちらを直してからここを変える。
EXPECT_TRACKING = False
EXPECT_COLLECTED_EMPTY = True

TOP_KEYS = {"NSPrivacyTracking", "NSPrivacyTrackingDomains",
            "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"}
API_KEYS = {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"}


# SwiftでCの関数をモジュール名で括って呼ぶ形（型に同じ名前のメンバーがあるとDarwin.stat(と書く）
_C_MODULES = ("Darwin", "Glibc", "Foundation", "CoreFoundation")


def _call(name):
    """Cの関数呼び出し。メンバー（a.stat( / a->stat(）とSwiftの$0.stat(は除く。
    Darwin.stat( のようにモジュール名で括ったものは数える。"""
    return r"(?:(?<![\w.$])(?:%s)\s*\.\s*|(?<![\w.$])(?<!->))%s\s*\(" % ("|".join(_C_MODULES), name)


_GETATTR = ("getattrlist", "fgetattrlist", "getattrlistat")
SOURCE_PATTERNS = {
    "UserDefaults": [r"\bUserDefaults\b", r"\bNSUserDefaults\b", r"@AppStorage\b",
                     r"\bCFPreferences\w*\s*\("],
    "FileTimestamp": [r"\.creationDate\b", r"\.modificationDate\b", r"\bfileModificationDate\b",
                      r"\bcontentModificationDateKey\b", r"\bcreationDateKey\b",
                      r"\bNSFile(?:Creation|Modification)Date\b",
                      r"\bNSURL(?:ContentModification|Creation)DateKey\b"]
                     + [_call(n) for n in _GETATTR + ("getattrlistbulk", "stat", "fstat", "fstatat",
                                                      "lstat", "stat64", "fstat64", "lstat64")],
    # KERN_BOOTTIMEはAppleの表に無いが、起動時刻そのものを読むので同じ扱いにする。
    "SystemBootTime": [r"\bsystemUptime\b", _call("mach_absolute_time"), r"\bKERN_BOOTTIME\b",
                       r"kern\.boottime"],
    "DiskSpace": [r"\b(?:NSURL|\.)?[vV]olume(?:AvailableCapacity(?:ForImportantUsage|ForOpportunisticUsage)?"
                  r"|TotalCapacity)Key\b",
                  r"\.systemFreeSize\b", r"\.systemSize\b", r"\bNSFileSystem(?:Free)?Size\b"]
                 + [_call(n) for n in _GETATTR + ("statfs", "statvfs", "fstatfs", "fstatvfs")],
    "ActiveKeyboards": [r"\bactiveInputModes\b"],
}
_COMPILED = {cat: [re.compile(p) for p in pats] for cat, pats in SOURCE_PATTERNS.items()}

# --binary: 実行ファイルが外から引く名前（nm -u）とObjCのセレクタ（NULで区切られた字）。
_BIN_GETATTR = {"getattrlist", "fgetattrlist", "getattrlistat"}
BINARY_SYMBOLS = {
    "UserDefaults": {"NSUserDefaults"},  # _OBJC_CLASS_$_NSUserDefaults
    "FileTimestamp": _BIN_GETATTR | {"getattrlistbulk", "stat", "fstat", "fstatat", "lstat",
                                     "stat64", "fstat64", "lstat64", "NSFileCreationDate",
                                     "NSFileModificationDate", "NSURLContentModificationDateKey",
                                     "NSURLCreationDateKey"},
    "SystemBootTime": {"mach_absolute_time"},
    "DiskSpace": _BIN_GETATTR | {"statfs", "statvfs", "fstatfs", "fstatvfs", "NSFileSystemFreeSize",
                                 "NSFileSystemSize", "NSURLVolumeAvailableCapacityKey",
                                 "NSURLVolumeAvailableCapacityForImportantUsageKey",
                                 "NSURLVolumeAvailableCapacityForOpportunisticUsageKey",
                                 "NSURLVolumeTotalCapacityKey"},
    "ActiveKeyboards": set(),
}
BINARY_PREFIXES = {"UserDefaults": ("CFPreferences",)}
BINARY_SELECTORS = {"SystemBootTime": {"systemUptime"}, "ActiveKeyboards": {"activeInputModes"},
                    "FileTimestamp": {"fileModificationDate"}}

CODE_EXT = {".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp"}
IGNORE_MARK = "privacy-manifest: ignore"


# MARK: - project.yml（使っている範囲のYAMLだけ読む。MacにもCIにもPyYAMLは無い）

def _strip_yaml_comment(line):
    quote = None
    for i, c in enumerate(line):
        if quote:
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


_KEY = re.compile(r"""^("[^"]*"|'[^']*'|[^\s"'\[{#-][^:]*?|<<|-[^\s:][^:]*?):(?:\s+(.*))?$""")
# 「script: |」の類（中身は次の行から、鍵より深い段に続く）
_BLOCK_SCALAR = re.compile(r"^[|>](?:[1-9][-+]?|[-+][1-9]?)?$")


def _unanchor(text):
    """「&錨 値」の値。錨だけなら空。"""
    text = text.strip()
    if text.startswith("&"):
        text = text.split(None, 1)[1] if " " in text else ""
    return text


def _flow(text, i, key=False):
    """[a, b] / {k: v} / "字" / 字 を1つ読む。戻りは(値, 次の位置)。"""
    n = len(text)
    while i < n and text[i] in " \t":
        i += 1
    if i >= n:
        return None, i
    c = text[i]
    if c in "[{":
        close, items, out = "]" if c == "[" else "}", [], {}
        i += 1
        while True:
            while i < n and text[i] in " \t":
                i += 1
            if i >= n:
                raise ValueError("閉じていない %s: %s" % (c, text))
            if text[i] == close:
                return (items if c == "[" else out), i + 1
            if c == "[":
                value, i = _flow(text, i)
                items.append(value)
            else:
                k, i = _flow(text, i, key=True)
                while i < n and text[i] in " \t":
                    i += 1
                value = None
                if i < n and text[i] == ":":
                    value, i = _flow(text, i + 1)
                out[k] = value
            while i < n and text[i] in " \t":
                i += 1
            if i < n and text[i] == ",":
                i += 1
            elif i < n and text[i] != close:
                raise ValueError("読めない字 %r: %s" % (text[i], text))
    if c in "\"'":
        j, buf = i + 1, []
        while j < n:
            if c == "'" and text.startswith("''", j):
                buf.append("'")
                j += 2
            elif c == '"' and text[j] == "\\" and j + 1 < n:
                buf.append(text[j + 1])
                j += 2
            elif text[j] == c:
                return "".join(buf), j + 1
            else:
                buf.append(text[j])
                j += 1
        raise ValueError("閉じていない引用: %s" % text)
    j = i
    while j < n and text[j] not in ",]}" and not (
            key and text[j] == ":" and (j + 1 == n or text[j + 1] in " \t,]}")):
        j += 1
    return text[i:j].strip(), j


def _scalar(text):
    text = _unanchor(text)
    if text[:1] in ("[", "{"):
        value, end = _flow(text, 0)
        if text[end:].strip():
            raise ValueError("読めない: %s" % text)
        return value
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    return text


def _block_scalar(lines, pos, parent):
    """「|」「>」の中身。親の段（parent）より深い行が続くあいだ。"""
    texts = []
    while pos < len(lines) and lines[pos][0] > parent:
        texts.append(lines[pos][1])
        pos += 1
    return "\n".join(texts), pos


def _unreadable(line):
    return ValueError("project.ymlの%d行目が読めない: %s" % (line[2], line[1]))


def _block(lines, pos, indent):
    if pos >= len(lines) or lines[pos][0] < indent:
        return None, pos
    ind = lines[pos][0]
    if lines[pos][1] == "-" or lines[pos][1].startswith("- "):
        out = []
        while pos < len(lines) and lines[pos][0] == ind and (
                lines[pos][1] == "-" or lines[pos][1].startswith("- ")):
            rest = lines[pos][1][1:].strip()
            if not rest:
                value, pos = _block(lines, pos + 1, ind + 1)
            elif _BLOCK_SCALAR.match(_unanchor(rest)):
                value, pos = _block_scalar(lines, pos + 1, ind)
            elif _KEY.match(rest):
                # 「- path: X」の続きの鍵は、pathと同じ段（ind + 2）に並ぶ
                lines[pos] = (ind + 2, rest, lines[pos][2])
                value, pos = _block(lines, pos, ind + 2)
            else:
                value, pos = _scalar(rest), pos + 1
            out.append(value)
        return out, pos
    out = {}
    while pos < len(lines) and lines[pos][0] == ind and not lines[pos][1].startswith("- "):
        m = _KEY.match(lines[pos][1])
        if not m:
            raise _unreadable(lines[pos])
        key, rest = _scalar(m.group(1)), (m.group(2) or "").strip()
        pos += 1
        if _BLOCK_SCALAR.match(_unanchor(rest)):
            out[key], pos = _block_scalar(lines, pos, ind)
            continue
        if rest and not (rest.startswith("&") and " " not in rest):
            out[key] = _scalar(rest)
            continue
        nested = pos < len(lines) and (lines[pos][0] > ind or (
            lines[pos][0] == ind and lines[pos][1].startswith("- ")))
        if nested:
            out[key], pos = _block(lines, pos, lines[pos][0])
        else:
            out[key] = None
    return out, pos


def parse_yaml(text):
    """読めない形があれば黙って飛ばさずValueErrorにする（後ろのターゲットが消えて見えるため）。"""
    lines = []
    for number, raw in enumerate(text.replace("\r\n", "\n").split("\n"), 1):
        line = _strip_yaml_comment(raw).rstrip()
        if line.strip():
            lines.append((len(line) - len(line.lstrip(" ")), line.strip(), number))
    value, pos = _block(lines, 0, 0) if lines else ({}, 0)
    if pos < len(lines):
        raise _unreadable(lines[pos])
    return value or {}


# MARK: - ソースを拾う（xcodegenのincludes / excludesと同じ見方）

def glob_re(pattern):
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r"\Z")


def _as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def _matches(rel, patterns):
    parts = rel.split("/")
    prefixes = ["/".join(parts[:k]) for k in range(1, len(parts) + 1)]
    return any(p.match(x) for p in patterns for x in prefixes)


def source_files(repo, entry):
    """1件のsources:から、コンパイルされるファイル（リポジトリからの相対）を返す。
    戻りの2つ目は「無い・空（submoduleを取っていない・生成前）」かどうか。"""
    if isinstance(entry, str):
        entry = {"path": entry}
    if not isinstance(entry, dict):
        raise ValueError("sourcesの項目が読めない: %r" % (entry,))
    if entry.get("buildPhase") == "resources" or entry.get("type") == "folder":
        return [], False
    rel = str(entry.get("path", "")).rstrip("/")
    base = repo / rel
    if base.is_file():
        return ([rel] if base.suffix in CODE_EXT else []), False
    if not base.is_dir() or not any(base.iterdir()):
        return [], True
    includes = [glob_re(p) for p in _as_list(entry.get("includes"))]
    excludes = [glob_re(p) for p in _as_list(entry.get("excludes"))]
    out = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            path = pathlib.Path(dirpath) / name
            if name.startswith(".") or path.suffix not in CODE_EXT:
                continue
            inner = path.relative_to(base).as_posix()
            if includes and not any(p.match(inner) for p in includes):
                continue
            if excludes and _matches(inner, excludes):
                continue
            out.append(path.relative_to(repo).as_posix())
    return out, False


def bundle_sources(repo, targets, name, seen=None):
    """バンドルに積まれるファイルと、無い・空だったsources:の項目。静的ライブラリの依存は畳み込む。"""
    seen = seen if seen is not None else set()
    if name in seen:
        return [], []
    seen.add(name)
    target = targets.get(name) or {}
    files, missing = [], []
    for entry in _as_list(target.get("sources")):
        got, absent = source_files(repo, entry)
        files += got
        if absent:
            missing.append({"path": entry} if isinstance(entry, str) else entry)
    for dep in _as_list(target.get("dependencies")):
        dep_name = dep.get("target") if isinstance(dep, dict) else None
        if dep_name and (targets.get(dep_name) or {}).get("type") in FOLDED_TYPES:
            more, gone = bundle_sources(repo, targets, dep_name, seen)
            files += more
            missing += gone
    return files, missing


# MARK: - grep

def strip_comments(text, swift):
    """注釈を空白に置き換える（行は保つ）。字の中身は残す（Swiftの\\( )の中はコード）。"""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif two == "/*":
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                elif swift and text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                else:
                    j += 1
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c == '"' or (swift and c == "#" and re.match(r'#+"', text[i:i + 8])) or (
                not swift and c == "'" and not (i > 0 and text[i - 1].isalnum())):
            j = _string_end(text, i, swift)
            out.append(text[i:j])
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _string_end(text, i, swift):
    n = len(text)
    hashes = 0
    while swift and i < n and text[i] == "#":
        hashes, i = hashes + 1, i + 1
    quote = text[i]
    multi = swift and text.startswith('"""', i)
    close = ('"""' if multi else quote) + "#" * hashes
    i += 3 if multi else 1
    while i < n:
        if text.startswith(close, i):
            return i + len(close)
        c = text[i]
        if c == "\n" and not multi:
            return i
        if c == "\\" and not hashes:
            if swift and text.startswith("\\(", i):
                i = _interpolation_end(text, i + 2)
                continue
            i += 2
            continue
        i += 1
    return n


def _interpolation_end(text, i):
    depth, n = 1, len(text)
    while i < n and depth:
        c = text[i]
        if c == '"':
            i = _string_end(text, i, True)
            continue
        depth += {"(": 1, ")": -1}.get(c, 0)
        i += 1
    return i


def scan_file(path, rel):
    """[(分類, 'rel:行', 一致した字)]。"""
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    code = strip_comments(raw, swift=path.suffix == ".swift").split("\n")
    raw_lines = raw.split("\n")
    hits = []
    for number, line in enumerate(code, 1):
        if not line.strip() or IGNORE_MARK in raw_lines[number - 1]:
            continue
        for cat, patterns in _COMPILED.items():
            for p in patterns:
                m = p.search(line)
                if m:
                    hits.append((cat, "%s:%d" % (rel, number), m.group(0).strip()))
                    break
    return hits


# MARK: - マニフェスト

def read_manifest(path):
    """(分類 -> 理由の集合, 誤りの一覧)。"""
    errors = []
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except FileNotFoundError:
        return None, ["マニフェストが無い"]
    except Exception as e:  # plistlib.InvalidFileException, ExpatError など
        return None, ["plistとして読めない: %s" % e]
    if not isinstance(data, dict):
        return None, ["最上位が辞書でない"]
    for key in sorted(set(data) - TOP_KEYS):
        errors.append("知らない鍵 %s（無効なマニフェストになる）" % key)

    tracking = data.get("NSPrivacyTracking")
    domains = data.get("NSPrivacyTrackingDomains")
    if "NSPrivacyTracking" in data and not isinstance(tracking, bool):
        errors.append("NSPrivacyTrackingがBooleanでない")
    if domains is not None and not (isinstance(domains, list) and all(isinstance(d, str) for d in domains)):
        errors.append("NSPrivacyTrackingDomainsが字の配列でない")
    elif tracking is True and not domains:
        errors.append("NSPrivacyTrackingがtrueなのにNSPrivacyTrackingDomainsが空")
    elif tracking is not True and domains:
        errors.append("NSPrivacyTrackingがfalseなのにNSPrivacyTrackingDomainsに中身がある")
    for d in domains or []:
        if isinstance(d, str) and (not d or re.search(r"[/?#:\s]", d)):
            errors.append("追跡ドメインの形が違う（道・問い・末尾の/は書かない）: %r" % d)
    if EXPECT_TRACKING is False and tracking is not False:
        errors.append("NSPrivacyTrackingをfalseと書く（このアプリは追跡しない。site/src/text.jsのPRIVACY）")

    collected = data.get("NSPrivacyCollectedDataTypes")
    if not isinstance(collected, list):
        errors.append("NSPrivacyCollectedDataTypesを配列で書く")
    elif EXPECT_COLLECTED_EMPTY and collected:
        errors.append("NSPrivacyCollectedDataTypesが空でない（このアプリは何も集めない。"
                      "変えるならsite/src/text.jsのPRIVACYとこのファイルのEXPECT_*を先に直す）")

    declared = {}
    types = data.get("NSPrivacyAccessedAPITypes")
    if types is None:
        return declared, errors
    if not isinstance(types, list) or not types:
        errors.append("NSPrivacyAccessedAPITypesが空または配列でない（使わないなら鍵ごと消す）")
        return declared, errors
    for item in types:
        if not isinstance(item, dict):
            errors.append("NSPrivacyAccessedAPITypesの中に辞書でないものがある")
            continue
        for key in sorted(set(item) - API_KEYS):
            errors.append("NSPrivacyAccessedAPITypesの中に知らない鍵 %s" % key)
        full = item.get("NSPrivacyAccessedAPIType")
        cat = full[len(PREFIX):] if isinstance(full, str) and full.startswith(PREFIX) else None
        if cat not in CATEGORIES:
            errors.append("知らない分類 %r" % (full,))
            continue
        if cat in declared:
            errors.append("%sが2回ある" % cat)
        reasons = item.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(reasons, list) or not reasons or not all(isinstance(r, str) for r in reasons):
            errors.append("%sの理由が空または字の配列でない" % cat)
            continue
        for r in reasons:
            if r not in CATEGORIES[cat]:
                errors.append("%sの理由に%sは無い（使えるのは%s）" % (cat, r, ", ".join(sorted(CATEGORIES[cat]))))
            elif r in SDK_ONLY:
                errors.append("%sの%sはthird-party SDKだけが申告できる" % (cat, r))
        if len(set(reasons)) != len(reasons):
            errors.append("%sの理由が重なっている" % cat)
        declared[cat] = set(reasons)
    return declared, errors


# MARK: - 照合

def compare(label, manifest_label, used, declared, errors, strict, verbose):
    """used: 分類 -> [(場所, 字)]。戻りは落とすかどうか。"""
    failed = bool(errors)
    print("%s  %s" % (label, manifest_label))
    for e in errors:
        print("  ERROR %s" % e)
    declared = declared or {}
    for cat in sorted(set(used) | set(declared)):
        where = used.get(cat, [])
        reasons = ",".join(sorted(declared.get(cat, ()))) or "-"
        if cat not in declared:
            status, failed = "MISSING", True
        elif not where:
            status = "UNUSED"
            failed = failed or strict
        else:
            status = "ok"
        head = "  ".join(where[0]) if where else "（見つからない）"
        if len(where) > 1:
            head += " (+%d)" % (len(where) - 1)
        print("  %-7s %-15s %-8s %s" % (status, cat, reasons, head))
        if verbose:
            for place, text in where[1:]:
                print("  %32s %s  %s" % ("", place, text))
    if not used and not declared:
        print("  （Required Reason APIは見つからない）")
    return failed


def check_sources(repo, strict=False, require_vendor=False, verbose=False):
    try:
        spec = parse_yaml((repo / "project.yml").read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        print("check_privacy_manifest: project.ymlが読めない: %s" % e, file=sys.stderr)
        return 2
    targets = spec.get("targets") or {}
    failed = False
    for name, target in sorted(targets.items()):
        kind = (target or {}).get("type")
        if kind not in NOT_SHIPPED_TYPES | FOLDED_TYPES and name not in BUNDLES:
            print("ERROR %s（%s）は出すバンドルなのにBUNDLESに無い。マニフェストを置いて足す"
                  "（出さない種類ならNOT_SHIPPED_TYPESへ）" % (name, kind or "typeが無い"))
            failed = True
    for name in sorted(BUNDLES):
        if name not in targets:
            print("ERROR BUNDLESの%sがproject.ymlに無い" % name)
            failed = True
    for name in sorted(n for n in BUNDLES if n in targets):
        try:
            files, missing = bundle_sources(repo, targets, name)
        except ValueError as e:
            print("check_privacy_manifest: project.ymlが読めない: %s" % e, file=sys.stderr)
            return 2
        used = {}
        for rel in sorted(set(files)):
            for cat, place, text in scan_file(repo / rel, rel):
                used.setdefault(cat, []).append((place, text))
        declared, errors = read_manifest(repo / BUNDLES[name])
        for entry in missing:
            m = str(entry.get("path", "")).rstrip("/")
            vendor = m.startswith(VENDOR_PREFIX)
            optional = str(entry.get("optional", "")).lower() in ("true", "yes")
            if vendor and require_vendor:
                errors.append("%sが無い（submoduleを取ってから走らせる）" % m)
            elif not (vendor or optional or m.startswith(GENERATED_PREFIXES) or (repo / m).exists()):
                # xcodegenも無いパスでは止まる（optional: trueを除く）。書き違いを黙って読まないままにしない
                errors.append("sourcesの%sが無い（xcodegenも止まる）" % m)
            else:
                print("NOTE %s: %sが無い・空なので読んでいない%s" % (
                    name, m, "（--require-vendorで落とす）" if vendor else ""))
        if compare(name, BUNDLES[name], used, declared, errors, strict, verbose):
            failed = True
    print("FAIL" if failed else "OK")
    return 1 if failed else 0


# MARK: - --binary（建てた.appを見る。Macのnmで、App Store Connectと同じく実行ファイルの参照を読む）

def bundles_in(path):
    path = pathlib.Path(path)
    if path.suffix == ".xcarchive":
        apps = sorted((path / "Products" / "Applications").glob("*.app"))
        if not apps:
            return []
        path = apps[0]
    out = [path]
    for sub in ("PlugIns", "Extensions"):
        out += sorted((path / sub).glob("*.appex"))
    out += sorted((path / "Frameworks").glob("*.framework"))
    return out


def executables_of(bundle):
    """バンドルの実行ファイルと、同じ段のdylib。XcodeのDebugは中身を<App>.debug.dylibへ
    分ける（ENABLE_DEBUG_DYLIB）ので、実行ファイルだけ読むと何も見つからない。"""
    info = bundle / "Info.plist"
    try:
        with open(info, "rb") as f:
            name = plistlib.load(f).get("CFBundleExecutable")
    except (OSError, ValueError):
        name = None
    found = [bundle / (name or bundle.stem)] + sorted(bundle.glob("*.dylib"))
    return [p for p in found if p.is_file()]


def binary_usage(exe, nm):
    result = subprocess.run([nm, "-u", str(exe)], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("%s -u %s: %s" % (nm, exe, result.stderr.strip()))
    names = set()
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line.endswith(":"):
            continue
        name = line.split()[-1].split("@")[0]
        m = re.match(r"_?OBJC_CLASS_\$_(\w+)$", name)
        if m:
            names.add(m.group(1))
            continue
        name = name.split("$")[0]
        names.add(name)
        if name.startswith("_"):
            names.add(name[1:])
    blob = exe.read_bytes()
    used = {}
    for cat in CATEGORIES:
        hits = sorted(names & BINARY_SYMBOLS.get(cat, set()))
        hits += sorted(n for n in names if n.startswith(BINARY_PREFIXES.get(cat, ("\0",))))
        hits += sorted(s for s in BINARY_SELECTORS.get(cat, ())
                       if (b"\0" + s.encode() + b"\0") in blob)
        if hits:
            used[cat] = [(exe.name, h) for h in dict.fromkeys(hits)]
    return used


def check_binary(path, nm, strict=False, verbose=False):
    bundles = bundles_in(path)
    if not bundles or not bundles[0].is_dir():
        print("check_privacy_manifest: .appが見つからない: %s" % path, file=sys.stderr)
        return 2
    failed = False
    for bundle in bundles:
        exes = executables_of(bundle)
        if not exes:
            print("NOTE %s: 実行ファイルが無いので読まない" % bundle.name)
            continue
        used = {}
        try:
            for exe in exes:
                for cat, where in binary_usage(exe, nm).items():
                    used.setdefault(cat, []).extend(where)
        except (OSError, RuntimeError) as e:
            print("check_privacy_manifest: %s" % e, file=sys.stderr)
            return 2
        manifest = bundle / MANIFEST
        if manifest.exists() or used:
            declared, errors = read_manifest(manifest)
        else:
            declared, errors = {}, []
        if compare(bundle.name, manifest.relative_to(bundle.parent).as_posix(),
                   used, declared, errors, strict, verbose):
            failed = True
    print("FAIL" if failed else "OK")
    return 1 if failed else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--repo", default=str(ROOT), help="リポジトリの根（試験用）")
    ap.add_argument("--binary", metavar="APP", help="建てた.appか.xcarchiveを見る（nm -u）")
    ap.add_argument("--nm", default=os.environ.get("NM", "nm"), help="nmの場所（既定はnm）")
    ap.add_argument("--require-vendor", action="store_true",
                    help="Vendor/のsubmoduleが無い・空なら落とす（CIのgeneratedジョブ）")
    ap.add_argument("--strict", action="store_true", help="申告してあって使っていない分類も落とす")
    ap.add_argument("-v", "--verbose", action="store_true", help="見つけた場所を全部出す")
    args = ap.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure") and not sys.stdout.isatty():
        sys.stdout.reconfigure(encoding="utf-8")  # Windowsでパイプへ出すとcp932になるため
    if args.binary:
        return check_binary(args.binary, args.nm, args.strict, args.verbose)
    return check_sources(pathlib.Path(args.repo), args.strict, args.require_vendor, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
