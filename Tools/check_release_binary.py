#!/usr/bin/env python3
"""出荷する形（Release の書庫・ipa）の EffectDeck を、実機へ入れる前に機械で確かめる。stdlib だけ。

  bash Scripts/check_release_binary.sh                        ${ARCHIVE_DIR:-/tmp}/EffeTuneLive.xcarchive
  bash Scripts/check_release_binary.sh path/to/EffectDeck.ipa
  python3 Tools/check_release_binary.py --flavor store build/Release.xcarchive   （CI。署名なし）

なぜ要るか（364f940）: 資産を送り込む口 et_instance_asset_begin_ptr を dlsym で引いていた。
Release の書庫では実行ファイルのシンボルが strip されるので見つからず、資産を使う 7 種が
出荷版で全部動かなかった。Debug と plain build は strip されないので、手元では一度も出なかった。

見るもの（名前は --skip に渡すもの）:

  strip      本体の実行ファイルが strip 済みか。strip されていないものを見ても何も言えない
             （364f940 は Release の plain build を「確かめた」ことにして外した）。--allow-unstripped で外す
  debugbuild *.debug.dylib・__preview.dylib が無い（Debug で建てた .app を渡していない）
  lookup     名前で引く口（dlsym・CFBundleGetFunctionPointerForName・NSClassFromString・objc_getClass・
             NSSelectorFromString・Selector("…") など）の字が、そのソースを建てた実行ファイルで引ける
             （export trie・取り込み・ObjC のクラス一覧・メソッド名）。字でない引数は測れないので落とす
  abiname    自前の C の口（ET…・et_…）の名前がそのまま実行ファイルの字に在るなら、export されている
             （ソースを読まずに、名前で引く形が戻ってきたのを拾う）
  plist      Info.plist（識別子・3 本の版が同じ・展開されていない $(…)・拡張の口・
             NSExtensionPrincipalClass などクラス名で引くものが実在する。UI…・NS… の系のクラスは測らない）
  entitle    署名の entitlements。media-device-extension は本体では鍵が在って中身が空（ITMS-91183）、
             中身を持つのは Media Device Extension の .appex だけ。App Group・associated domains・iCloud KVS。
             署名済みならリポジトリの .entitlements の鍵が全部入っていること、ipa なら get-task-allow が無いことも
  samples    Debug/JSFXFactory の見本と Debug/JSFXBench（速さを測る台の入力）。店の版（青）には無い。
             TestFlight（紫・ET_BETA）には追跡しているものだけが中身ごと同じで在る。
             Local/DebugJSFXFactory（第三者の実物）はどちらにも無い
  debugonly  #if DEBUG の中にだけある字（Sources/EffeTuneLive/DSP/DebugPresets.swift の鎖など）が
             実行ファイルに無い。DebugPresets.swift はファイルごと囲っていない（呼ぶ側が囲う）ので、
             そこで宣言した名前を #if DEBUG の外で使う所があればソースの段で落とし、その場所を出す
  crosscheck Mac の nm・codesign があれば、ここでの読み取り（export trie・entitlements）と突き合わせる

署名の無い書庫（CI の CODE_SIGNING_ALLOWED=NO）では entitlements をリポジトリの .entitlements から読み、
そう書く。青か紫かは CFBundleIconName から決める（決まらなければ --flavor）。
一つでも FAIL なら 1、入口の誤りは 2 で終わる。
"""
import argparse
import functools
import hashlib
import os
import pathlib
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------------------
# 出荷物の決まりごと。project.yml（構成 Beta / Release）・*.entitlements の写し。
# 変えたらここも直す（ここが挙げるファイルが無ければ FAIL で気づく）。
# ---------------------------------------------------------------------------

APP_GROUP = "group.ai.nemut.effetune"
APPLINKS = "applinks:effectdeck.nemut.ai"
MEDIA_DEVICE_KEY = "com.apple.developer.media-device-extension"
GROUPS_KEY = "com.apple.security.application-groups"
DOMAINS_KEY = "com.apple.developer.associated-domains"
KVS_KEY = "com.apple.developer.ubiquity-kvstore-identifier"
GET_TASK_ALLOW = "get-task-allow"
MEDIA_PROTOCOL_CONFORMS = "public.media-sharing-protocol"

# 役 → 束の識別子・入る場所・署名に使う .entitlements。
BUNDLES = {
    "app": {
        "id": "ai.nemut.effetune",
        "dir": None,
        "entitlements": "Sources/EffeTuneLive/EffeTuneLive.entitlements",
    },
    # ExtensionKit の拡張は PlugIns/ ではなく Extensions/ に入る。
    "device": {
        "id": "ai.nemut.effetune.extension",
        "dir": "Extensions",
        "entitlements": "Sources/Extension/Extension.entitlements",
    },
    "share": {
        "id": "ai.nemut.effetune.share",
        "dir": "PlugIns",
        "entitlements": "Sources/ShareExtension/ShareExtension.entitlements",
    },
}
ROLE_LABEL = {"app": "本体", "device": "Media Device Extension", "share": "共有の拡張"}

# アイコンの名前（project.yml の ET_APPICON）で青と紫を見分ける。project.yml の Beta 構成が
# アイコンと ET_BETA を同じ所で決めるので、紫なら見本が在る、が成り立つ。
ICON_FLAVOR = {"EffeTuneLive": "store", "EffectDeckPublicBeta": "beta"}

# どのソースがどの実行ファイルに入るか（project.yml の sources の写し。写し忘れは
# Tests/Tools/test_check_release_binary.py の ProjectYmlTests が本物の project.yml と突き合わせて落とす）。
# (場所, 役, 積むものの正規表現, 積まないものの正規表現)。正規表現は場所からの相対パスに当てる。
# 場所が / で終わらなければファイル 1 本。WDL は名指しのものしか積まない（eel_lice.h などは建たない）。
SOURCE_ROLES = [
    ("Sources/EffeTuneLive/", ("app",), None, None),
    ("Sources/Shared/", ("app", "device"), None, None),
    ("Sources/Extension/", ("device",), None, None),
    ("Sources/ShareExtension/", ("share",), None, None),
    ("Vendor/effetune/dsp/core/", ("app",), None, r"test[^/]*\.cpp$"),
    # calibrate_tables.cpp は int main を持つ単体ツール。project.yml が積まない。
    ("Vendor/effetune/dsp/plugins/", ("app",), None, r"test[^/]*\.cpp$|(^|/)calibrate_tables\.cpp$"),
    ("Vendor/effetune/dsp/include/", ("app",), None, None),
    ("Vendor/effetune/dsp/vendor/pffft/src/", ("app",), None, r"test[^/]*$"),
    ("Vendor/ysfx/sources/", ("app",), None,
     r"^(lice_stb|eel2-gas)/|^ysfx_audio_(flac|wav)\.cpp$|^ysfx_utils_fts\.cpp$"),
    ("Vendor/ysfx/include/", ("app",), None, None),
    ("Vendor/ysfx/thirdparty/WDL/source/WDL/eel2/", ("app",),
     r"^nseel-(caltab|cfunc|compiler|eval|lextab|ram|yylex)\.c$", None),
    ("Vendor/ysfx/thirdparty/WDL/source/WDL/fft.c", ("app",), None, None),
    # JSFX のレジスタ型 VM。project.yml では YSFX の中（拡張には入らない）。
    ("Sources/JSFXVM/", ("app",), None, None),
    ("Vendor/ysfx/thirdparty/WDL/source/WDL/lice/", ("app",),
     r"^lice(_arc|_colorspace|_image|_line|_palette|_texgen|_text)?\.cpp$", None),
    # Note Spectrogram のモデル（Scripts/setup.sh が吐く）。.S は読まない（名前で引く口は書けない）。
    ("Generated/note-models/", ("app",), None, None),
]
# setup.sh が用意するもの。無ければ読めなかったと書く（黙って通さない）。
FETCHED_HEADS = ("Vendor/", "Generated/")
# 拡張は DSP コアを積まない（project.yml の EffeTuneLiveExtension の excludes）。
DEVICE_SHARED_EXCLUDES = re.compile(r"^(ETPipeline|ETResample|ETPreviewTone|ETJSFXHost|ETJSFXBench|ETJSFXBenchEngine"
                                    r"|ETJSFXBenchPorts|ETLICEFont)\.")
SHARE_EXTRA_SOURCES = ("Sources/EffeTuneLive/DSP/ETRemoteFile.swift",
                       "Sources/EffeTuneLive/DSP/ETShareInbox.swift")
SOURCE_SUFFIXES = (".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".h", ".hpp")

# 名前で引く口。値は（引くものの種類, 名前が入る引数の位置）。
LOOKUP_CALLS = {
    "dlsym": ("symbol", 1),
    "CFBundleGetFunctionPointerForName": ("symbol", 1),
    "CFBundleGetDataPointerForName": ("symbol", 1),
    "NSClassFromString": ("class", 0),
    "objc_getClass": ("class", 0),
    "objc_lookUpClass": ("class", 0),
    "objc_getRequiredClass": ("class", 0),
    "classNamed": ("class", 0),
    "NSSelectorFromString": ("selector", 0),
    "sel_registerName": ("selector", 0),
    "sel_getUid": ("selector", 0),
    # Swift の Selector("…")。#selector(…) は建てるときに決まるので見ない。
    "Selector": ("selector", 0),
}
SWIFT_ONLY_CALLS = {"Selector"}
OBJC_OR_SWIFT_CALLS = {"classNamed"}
# 系の側にあって取り込んでいないものを名前で引くときだけ、理由つきでここへ書く（いまは無い）。
LOOKUP_ALLOW = {}

# 名前で引くクラスを書く Info.plist の鍵。
PLIST_CLASS_KEYS = ("NSExtensionPrincipalClass", "NSPrincipalClass", "UISceneDelegateClassName",
                    "UISceneClassName", "UIApplicationDelegateClassName")
# そこに UIKit・Foundation のクラス（UIApplication・UIWindowScene など）を書くのは普通で、それは束の外に在る。
# Module.Class・_Tt… の形は自前の Swift のクラスなので、この形に当たらず必ず束で引く。
SYSTEM_CLASS = re.compile(r"^(UI|NS)[A-Z][A-Za-z0-9_]*$")

# 自前の C の口の宣言を拾うところ。
ABI_HEADER_GLOBS = ("Sources/Shared/*.h", "Sources/Extension/*.h", "Vendor/effetune/dsp/include/effetune/abi.h")
ABI_DECL = re.compile(r"\b((?:ET[A-Z][A-Za-z0-9]*(?:_[A-Za-z0-9_]+)?)|et_[A-Za-z0-9_]+)\s*\(")
# 字として入っていても名前で引いていないと分かっているもの（いまは無い）。
ABI_STRING_ALLOW = set()

# #if DEBUG で囲わずに、呼ぶ側が囲っているもの。ファイルの字は全部 Debug だけのもの。
# 呼ぶ側が囲っていることも debug_only_callers で確かめる（囲っていなければ字は必ず残る）。
DEBUG_ONLY_FILES = ("Sources/EffeTuneLive/DSP/DebugPresets.swift",)
# Swift の字のうち 15 バイトまでは命令に埋め込まれて __cstring に出ない。見るのは 16 バイトから。
DEBUG_LITERAL_MIN_BYTES = 16

# Release の書庫なら実行ファイルのローカルシンボルはほぼ 0。strip されていないものは数千ある。
STRIP_LOCAL_LIMIT = 64

DEBUG_BUILD_NAMES = re.compile(r"(\.debug\.dylib|^__preview\.dylib)$")
JSFX_SUFFIXES = (".jsfx", ".jsfx-inc")
SAMPLES_DIR = "DebugJSFXFactory"
TRACKED_SAMPLES = "Debug/JSFXFactory"
# 積んでよい自前の JSFX の組（.app の中のフォルダ, 追跡しているフォルダ, 紫に必ず在るか）。
# 見本と、速さを測る台の入力（Scripts/embed_debug_jsfx.sh・docs/jsfx-bench.md）。規則は同じで、
# 台の入力はリポジトリに無ければ見ない（無いものを紫に求めない）。
SAMPLE_SETS = ((SAMPLES_DIR, TRACKED_SAMPLES, True), ("DebugJSFXBench", "Debug/JSFXBench", False))
IGNORED_NAMES = {".DS_Store"}

ALL_CHECKS = ("strip", "debugbuild", "lookup", "abiname", "plist", "entitle", "samples", "debugonly",
              "crosscheck")


class InputError(Exception):
    """渡されたものが読めない。2 で終わる。"""


# ---------------------------------------------------------------------------
# Mach-O を読む。nm・otool・codesign の無い Linux でも同じに読めるよう、自前で読む。
# ---------------------------------------------------------------------------

MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_CODE_SIGNATURE = 0x1D
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_DYLD_CHAINED_FIXUPS = 0x80000034
S_CSTRING_LITERALS = 0x2
ZEROFILL_TYPES = (0x1, 0xC, 0x12)
N_STAB = 0xE0
N_TYPE = 0x0E
N_EXT = 0x01
N_SECT = 0x0E
N_UNDF = 0x0
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171


class MachOError(Exception):
    pass


def _reads(method):
    """読んでいる途中で表が壊れていると分かったら、どのファイルかを付けて MachOError にする。"""
    @functools.wraps(method)
    def wrapper(self, *args, **kwargs):
        try:
            return method(self, *args, **kwargs)
        except MachOError as e:
            if self.path in str(e):
                raise
            raise MachOError("%s: %s" % (self.path, e)) from e
        except (struct.error, IndexError) as e:
            raise MachOError("%s: %s" % (self.path, e)) from e
    return wrapper


def uleb(b, p):
    result = shift = 0
    while True:
        if p >= len(b):
            raise MachOError("ULEB128 が途中で切れている")
        byte = b[p]
        p += 1
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result, p
        shift += 7


def cstr_bytes(b, p):
    e = b.find(b"\0", p)
    if e < 0:
        e = len(b)
    return b[p:e]


class Segment:
    __slots__ = ("name", "vmaddr", "vmsize", "fileoff", "filesize")

    def __init__(self, name, vmaddr, vmsize, fileoff, filesize):
        self.name, self.vmaddr, self.vmsize, self.fileoff, self.filesize = name, vmaddr, vmsize, fileoff, filesize


class Section:
    __slots__ = ("segname", "sectname", "addr", "size", "offset", "flags")

    def __init__(self, segname, sectname, addr, size, offset, flags):
        self.segname, self.sectname, self.addr, self.size, self.offset, self.flags = (
            segname, sectname, addr, size, offset, flags)


class MachO:
    """64 ビットの Mach-O（fat なら arm64 の切れ端）。"""

    def __init__(self, path, blob=None):
        self.path = str(path)
        if blob is None:
            blob = pathlib.Path(path).read_bytes()
        self.data = self._thin(blob)
        self.segments = []
        self.sections = []
        self.symtab = None
        self.dyld_info = None
        self.exports_range = None
        self.chained_range = None
        self.codesig_range = None
        self._parse()
        self.base = next((s.vmaddr for s in self.segments if s.fileoff == 0 and s.filesize), 0)
        self._formats = None
        self._cache = {}

    @staticmethod
    def _thin(blob):
        if len(blob) < 32:
            raise MachOError("Mach-O にしては短すぎる")
        magic_be = struct.unpack_from(">I", blob, 0)[0]
        if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
            count = struct.unpack_from(">I", blob, 4)[0]
            arches = []
            for i in range(count):
                if magic_be == FAT_MAGIC:
                    cpu, _sub, off, size, _align = struct.unpack_from(">iiIII", blob, 8 + 20 * i)
                else:
                    cpu, _sub, off, size, _align, _res = struct.unpack_from(">iiQQII", blob, 8 + 32 * i)
                arches.append((cpu, off, size))
            if not arches:
                raise MachOError("fat の中身が空")
            cpu, off, size = next((a for a in arches if a[0] == CPU_TYPE_ARM64), arches[0])
            blob = blob[off:off + size]
        magic = struct.unpack_from("<I", blob, 0)[0]
        if magic == MH_MAGIC_64:
            return blob
        if magic == MH_MAGIC:
            raise MachOError("32 ビットの Mach-O は見ない")
        raise MachOError("Mach-O ではない")

    def _parse(self):
        d = self.data
        _magic, self.cputype, _sub, self.filetype, ncmds, sizeofcmds, _flags, _res = struct.unpack_from(
            "<IiiIIIII", d, 0)
        off, end = 32, 32 + sizeofcmds
        for _ in range(ncmds):
            if off + 8 > end:
                raise MachOError("load command が header の大きさを越えている")
            cmd, size = struct.unpack_from("<II", d, off)
            if size < 8 or off + size > end:
                raise MachOError("load command の大きさが壊れている")
            if cmd == LC_SEGMENT_64:
                name = d[off + 8:off + 24].rstrip(b"\0").decode("ascii", "replace")
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", d, off + 24)
                nsects = struct.unpack_from("<I", d, off + 64)[0]
                self.segments.append(Segment(name, vmaddr, vmsize, fileoff, filesize))
                for i in range(nsects):
                    so = off + 72 + 80 * i
                    sectname = d[so:so + 16].rstrip(b"\0").decode("ascii", "replace")
                    segname = d[so + 16:so + 32].rstrip(b"\0").decode("ascii", "replace")
                    addr, ssize = struct.unpack_from("<QQ", d, so + 32)
                    offset, _align, _reloff, _nreloc, flags = struct.unpack_from("<IIIII", d, so + 48)
                    self.sections.append(Section(segname, sectname, addr, ssize, offset, flags))
            elif cmd == LC_SYMTAB:
                self.symtab = struct.unpack_from("<IIII", d, off + 8)
            elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                self.dyld_info = struct.unpack_from("<10I", d, off + 8)
            elif cmd == LC_DYLD_EXPORTS_TRIE:
                self.exports_range = struct.unpack_from("<II", d, off + 8)
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                self.chained_range = struct.unpack_from("<II", d, off + 8)
            elif cmd == LC_CODE_SIGNATURE:
                self.codesig_range = struct.unpack_from("<II", d, off + 8)
            off += size

    # -- 場所 ---------------------------------------------------------------

    def section(self, segname, sectname):
        return next((s for s in self.sections if s.segname == segname and s.sectname == sectname), None)

    def section_bytes(self, s):
        if (s.flags & 0xFF) in ZEROFILL_TYPES or not s.offset:
            return b""
        return self.data[s.offset:s.offset + s.size]

    def _range(self, r):
        if not r:
            return b""
        off, size = r
        return self.data[off:off + size]

    def file_offset(self, vmaddr):
        for s in self.segments:
            if s.vmaddr <= vmaddr < s.vmaddr + s.filesize:
                return s.fileoff + (vmaddr - s.vmaddr)
        return None

    def _segment_index(self, vmaddr):
        for i, s in enumerate(self.segments):
            if s.vmaddr <= vmaddr < s.vmaddr + max(s.vmsize, s.filesize):
                return i
        return None

    # -- 番地（chained fixups を解く） ----------------------------------------

    def _chained(self):
        return self._range(self.chained_range)

    @_reads
    def pointer_formats(self):
        """段の番号 → pointer_format。chained fixups が無ければ {}。"""
        if self._formats is not None:
            return self._formats
        self._formats = {}
        d = self._chained()
        if len(d) >= 28:
            starts = struct.unpack_from("<I", d, 4)[0]
            if starts + 4 <= len(d):
                count = struct.unpack_from("<I", d, starts)[0]
                for i in range(count):
                    so = struct.unpack_from("<I", d, starts + 4 + 4 * i)[0]
                    if so and starts + so + 8 <= len(d):
                        self._formats[i] = struct.unpack_from("<H", d, starts + so + 6)[0]
        return self._formats

    def decode_pointer(self, raw, fmt):
        """ディスク上の 8 バイトを番地にする。外への bind なら None。"""
        if fmt is None:
            return raw
        if fmt in (2, 6):  # DYLD_CHAINED_PTR_64 / 64_OFFSET
            if raw >> 63:
                return None
            target = raw & 0xFFFFFFFFF
            high8 = (raw >> 36) & 0xFF
            return (target if fmt == 2 else self.base + target) | (high8 << 56)
        if fmt in (1, 9, 12):  # arm64e
            if (raw >> 62) & 1:
                return None
            if raw >> 63:
                return self.base + (raw & 0xFFFFFFFF)
            target = raw & 0x7FFFFFFFFFF
            high8 = (raw >> 43) & 0xFF
            return (target if fmt == 1 else self.base + target) | (high8 << 56)
        return None

    def read_pointer(self, vmaddr):
        fo = self.file_offset(vmaddr)
        if fo is None or fo + 8 > len(self.data):
            return None
        raw = struct.unpack_from("<Q", self.data, fo)[0]
        fmt = self.pointer_formats().get(self._segment_index(vmaddr)) if self.chained_range else None
        return self.decode_pointer(raw, fmt)

    def cstring_at(self, vmaddr):
        fo = self.file_offset(vmaddr)
        return None if fo is None else cstr_bytes(self.data, fo)

    # -- シンボル -------------------------------------------------------------

    @_reads
    def symbols(self):
        if "symbols" in self._cache:
            return self._cache["symbols"]
        out = []
        if self.symtab:
            symoff, nsyms, stroff, strsize = self.symtab
            strtab = self.data[stroff:stroff + strsize]
            for i in range(nsyms):
                strx, ntype, nsect, ndesc, nvalue = struct.unpack_from("<IBBHQ", self.data, symoff + 16 * i)
                name = cstr_bytes(strtab, strx).decode("utf-8", "replace") if strx else ""
                out.append((name, ntype, nsect, ndesc, nvalue))
        self._cache["symbols"] = out
        return out

    def local_defined(self):
        """strip で消えるもの。stab でなく、外へ出しておらず、どこかの節に在るシンボル。"""
        return [s for s in self.symbols()
                if not (s[1] & N_STAB) and (s[1] & N_TYPE) == N_SECT and not (s[1] & N_EXT)]

    @_reads
    def exports(self):
        """dlsym が見る export trie の名前（先頭の _ 付き）。"""
        if "exports" in self._cache:
            return self._cache["exports"]
        if self.exports_range:
            trie = self._range(self.exports_range)
        elif self.dyld_info:
            trie = self._range((self.dyld_info[8], self.dyld_info[9]))
        else:
            trie = b""
        names = set()
        stack, seen = [(0, b"")], set()
        while stack and trie:
            node, prefix = stack.pop()
            if node in seen or node >= len(trie):
                continue
            seen.add(node)
            size, p = uleb(trie, node)
            if size:
                names.add(prefix.decode("utf-8", "replace"))
            p += size
            if p >= len(trie):
                continue
            children = trie[p]
            p += 1
            for _ in range(children):
                edge = cstr_bytes(trie, p)
                p += len(edge) + 1
                child, p = uleb(trie, p)
                stack.append((child, prefix + edge))
        self._cache["exports"] = names
        return names

    @_reads
    def imports(self):
        """外の dylib から取り込む名前（先頭の _ 付き）。bind 表・chained fixups・nlist の未定義。"""
        if "imports" in self._cache:
            return self._cache["imports"]
        names = {s[0] for s in self.symbols()
                 if not (s[1] & N_STAB) and (s[1] & N_TYPE) == N_UNDF and (s[1] & N_EXT) and s[0]}
        d = self._chained()
        if len(d) >= 28:
            _ver, _starts, imports_off, symbols_off, count, fmt, sym_fmt = struct.unpack_from("<7I", d, 0)
            if sym_fmt == 0:
                for i in range(count):
                    if fmt == 1:
                        name_off = struct.unpack_from("<I", d, imports_off + 4 * i)[0] >> 9
                    elif fmt == 2:
                        name_off = struct.unpack_from("<I", d, imports_off + 8 * i)[0] >> 9
                    elif fmt == 3:
                        name_off = struct.unpack_from("<Q", d, imports_off + 16 * i)[0] >> 32
                    else:
                        break
                    names.add(cstr_bytes(d, symbols_off + name_off).decode("utf-8", "replace"))
        if self.dyld_info:
            info = self.dyld_info
            for off, size in ((info[2], info[3]), (info[4], info[5]), (info[6], info[7])):
                names |= bind_opcode_names(self._range((off, size)))
        self._cache["imports"] = names
        return names

    # -- 字 ------------------------------------------------------------------

    @_reads
    def cstrings(self, include_objc=True):
        """cstring_literals の節の字（bytes の集合）。"""
        key = ("cstrings", include_objc)
        if key in self._cache:
            return self._cache[key]
        out = set()
        for s in self.sections:
            if (s.flags & 0xFF) != S_CSTRING_LITERALS:
                continue
            if not include_objc and s.sectname.startswith("__objc_"):
                continue
            out.update(x for x in self.section_bytes(s).split(b"\0") if x)
        self._cache[key] = out
        return out

    @_reads
    def objc_methnames(self):
        out = set()
        for s in self.sections:
            if s.sectname == "__objc_methname":
                out.update(x.decode("utf-8", "replace") for x in self.section_bytes(s).split(b"\0") if x)
        return out

    @_reads
    def objc_classes(self):
        """ObjC のクラス一覧（__objc_classlist → class_t → class_ro_t → name）。"""
        if "classes" in self._cache:
            return self._cache["classes"]
        names = set()
        for s in self.sections:
            if s.sectname != "__objc_classlist":
                continue
            for i in range(len(self.section_bytes(s)) // 8):
                cls = self.read_pointer(s.addr + 8 * i)
                data = self.read_pointer(cls + 32) if cls is not None else None
                if data is None:
                    continue
                ro = data & ~7 & ((1 << 56) - 1)
                name_ptr = self.read_pointer(ro + 24)
                name = self.cstring_at(name_ptr) if name_ptr is not None else None
                if name:
                    names.add(name.decode("utf-8", "replace"))
        self._cache["classes"] = names
        return names

    # -- 署名 ----------------------------------------------------------------

    def entitlements(self):
        """(出どころ, dict)。出どころは signature・simulated（シミュレータの __entitlements）・None。"""
        s = self.section("__TEXT", "__entitlements")
        if s is not None and s.size:
            return "simulated", _load_plist(self.section_bytes(s), self.path + " の __entitlements")
        d = self._range(self.codesig_range)
        if len(d) < 12:
            return None, None
        magic, _length, count = struct.unpack_from(">III", d, 0)
        if magic != CSMAGIC_EMBEDDED_SIGNATURE:
            return None, None
        for i in range(count):
            if 12 + 8 * i + 8 > len(d):
                break
            _slot, boff = struct.unpack_from(">II", d, 12 + 8 * i)
            if boff + 8 > len(d):
                continue
            bmagic, blen = struct.unpack_from(">II", d, boff)
            if bmagic == CSMAGIC_EMBEDDED_ENTITLEMENTS:
                return "signature", _load_plist(d[boff + 8:boff + blen], self.path + " の署名")
        return None, None


def bind_opcode_names(b):
    """LC_DYLD_INFO の bind 表から名前だけを拾う。"""
    names, p = set(), 0
    while p < len(b):
        byte = b[p]
        p += 1
        op, imm = byte & 0xF0, byte & 0x0F
        if op in (0x00, 0x10, 0x30, 0x50, 0x90, 0xB0):
            continue
        if op in (0x20, 0x60, 0x70, 0x80, 0xA0):
            _, p = uleb(b, p)
        elif op == 0x40:
            name = cstr_bytes(b, p)
            names.add(name.decode("utf-8", "replace"))
            p += len(name) + 1
        elif op == 0xC0:
            _, p = uleb(b, p)
            _, p = uleb(b, p)
        elif op == 0xD0:
            if imm == 0x00:
                _, p = uleb(b, p)
        else:
            break
    return names


def _load_plist(data, where):
    try:
        return plistlib.loads(data)
    except Exception as e:  # plistlib は形の誤りでいろいろな例外を投げる
        raise MachOError("%s を plist として読めない: %s" % (where, e))


def swift_objc_name(name):
    """NSClassFromString が受ける Module.Class を、ObjC の実行時の名前（_TtC…）にする。"""
    parts = name.split(".")
    if len(parts) < 2 or not all(parts):
        return name
    return "_Tt" + "C" * (len(parts) - 1) + "".join("%d%s" % (len(p.encode("utf-8")), p) for p in parts)


# ---------------------------------------------------------------------------
# ソースを読む
# ---------------------------------------------------------------------------

def read_text(path):
    return pathlib.Path(path).read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")


def _skip_string(text, i, swift):
    """text[i] が " のとき、字の終わりの次の位置を返す。Swift の \\( … ) の中の字も飛ばす。"""
    n = len(text)
    if swift and text.startswith('"""', i):
        j = i + 3
        while j < n:
            if text[j] == "\\":
                j += 2
                continue
            if text.startswith('"""', j):
                return j + 3
            j += 1
        return n
    j = i + 1
    while j < n and text[j] != "\n":
        c = text[j]
        if c == "\\":
            if swift and j + 1 < n and text[j + 1] == "(":
                j = _skip_parens(text, j + 1, swift)
                continue
            j += 2
            continue
        if c == '"':
            return j + 1
        j += 1
    return j


def _skip_parens(text, i, swift):
    """text[i] が ( のとき、対になる ) の次の位置を返す。"""
    depth, j, n = 0, i, len(text)
    while j < n:
        c = text[j]
        if c == '"':
            j = _skip_string(text, j, swift)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


_C_TOKENS = re.compile(r"//[^\n]*|/\*.*?(?:\*/|\Z)|\"(?:\\.|[^\"\\\n])*\"?|'(?:\\.|[^'\\\n])*'?", re.S)


def _blank(text):
    return re.sub(r"[^\n]", " ", text)


def _blank_comment(m):
    tok = m.group(0)
    if tok.startswith("//") or tok.startswith("/*"):
        return _blank(tok)
    return tok


def _blank_strings(clean, swift):
    """字（と C の文字）の中身を空白にした写し。長さと行は保つので、位置は clean と同じに使える。
    字に書いた dlsym(…) や名前をコードとして数えないため。Swift の \\( … ) の中はコードなので残す
    （その中の字はまた空白にする）。raw 文字列（#"…"#）の \\( は字。"""
    if not swift:
        return _C_TOKENS.sub(lambda m: _blank(m.group(0)), clean)
    return _swift_code_only(clean, 0, len(clean))


def _swift_code_only(text, start, end):
    out, i = [], start
    while i < end:
        j = text.find('"', i, end)
        if j < 0:
            out.append(text[i:end])
            break
        out.append(text[i:j])
        stop = min(_skip_string(text, j, True), end)
        out.append(_swift_blank_literal(text, j, stop))
        i = stop
    return "".join(out)


def _swift_blank_literal(text, start, stop):
    if start > 0 and text[start - 1] == "#":
        return _blank(text[start:stop])
    out, k = [], start
    while k < stop:
        if text[k] == "\\" and k + 1 < stop:
            if text[k + 1] == "(":
                close = min(_skip_parens(text, k + 1, True), stop)
                inner = close - 1 if close > k + 2 and text[close - 1] == ")" else close
                out.append("  " + _swift_code_only(text, k + 2, inner) + " " * (close - inner))
                k = close
                continue
            out.append(_blank(text[k:k + 2]))
            k += 2
            continue
        out.append(_blank(text[k]))
        k += 1
    return "".join(out)


def strip_comments(text, swift):
    """注釈を空白にする（行は保つ）。字はそのまま残す。Swift の /* */ は入れ子にする。"""
    if not swift:
        return _C_TOKENS.sub(_blank_comment, text)
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if text.startswith("/*", i):
            j, depth = i + 2, 1
            while j < n and depth:
                if swift and text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
            continue
        c = text[i]
        if c == '"':
            j = _skip_string(text, i, swift)
            out.append(text[i:j])
            i = j
            continue
        if c == "'" and not swift:
            j = i + 1
            while j < n and text[j] not in "'\n":
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(text[i:j])
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _call_args(text, open_idx, swift):
    """text[open_idx] の ( から、上の段の , で分けた引数を返す。閉じなければ None。"""
    args, depth, start, j, n = [], 0, open_idx + 1, open_idx, len(text)
    limit = min(n, open_idx + 4000)
    while j < limit:
        c = text[j]
        if c == '"':
            j = _skip_string(text, j, swift)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(text[start:j].strip())
                return args if args != [""] else []
        elif c == "," and depth == 1:
            args.append(text[start:j].strip())
            start = j + 1
        j += 1
    return None


_LITERAL_FORMS = (
    re.compile(r'^"((?:[^"\\\n]|\\.)*)"$'),
    re.compile(r'^@"((?:[^"\\\n]|\\.)*)"$'),
    re.compile(r'^CFSTR\s*\(\s*"((?:[^"\\\n]|\\.)*)"\s*\)$'),
)


def _literal(arg):
    """引数が字そのもの（"x"・@"x"・CFSTR("x")・Swift の ("x")）ならその字、でなければ None。"""
    arg = arg.strip()
    while arg.startswith("(") and arg.endswith(")"):
        arg = arg[1:-1].strip()
    for form in _LITERAL_FORMS:
        m = form.match(arg)
        if m:
            if "\\(" in m.group(1):
                return None
            return re.sub(r"\\(.)", r"\1", m.group(1))
    return None


# Bundle.main.classNamed( のように前が . のものも拾う。my_dlsym( や #selector( は拾わない。
CALL_RE = re.compile(r"(?<![\w#@$])(%s)\s*\(" % "|".join(sorted(LOOKUP_CALLS, key=len, reverse=True)))
OBJC_CLASSNAMED_RE = re.compile(r"\bclassNamed:\s*(@\"(?:[^\"\\\n]|\\.)*\"|[^\]\s]+)")
SILGEN_RE = re.compile(r'@_silgen_name\s*\(\s*"([^"]+)"\s*\)')
SILGEN_START = re.compile(r"@_silgen_name\b")
LOOKUP_PREFILTER = re.compile("|".join(sorted(LOOKUP_CALLS)) + "|@_silgen_name")
DECL_BEFORE = re.compile(r"(\bfunc\s+|\*\s*|\b(?:void|int|Class|SEL|id|extern)\s+)$")


class Lookup:
    __slots__ = ("path", "line", "call", "kind", "name", "roles")

    def __init__(self, path, line, call, kind, name, roles):
        self.path, self.line, self.call, self.kind, self.name, self.roles = path, line, call, kind, name, roles

    def where(self):
        return "%s:%d" % (self.path, self.line)


def source_files(repo):
    """{相対パス: 役の集合}。project.yml の sources の写し。"""
    out = {}
    for head, roles, include, exclude in SOURCE_ROLES:
        base = repo / head
        if not head.endswith("/"):
            if base.is_file():
                out.setdefault(head, set()).update(roles)
            continue
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*")):
            if not p.is_file() or p.suffix not in SOURCE_SUFFIXES:
                continue
            sub = p.relative_to(base).as_posix()
            if include and not re.search(include, sub):
                continue
            if exclude and re.search(exclude, sub):
                continue
            r = set(roles)
            if head == "Sources/Shared/" and DEVICE_SHARED_EXCLUDES.match(p.name):
                r.discard("device")
            out.setdefault(p.relative_to(repo).as_posix(), set()).update(r)
    for rel in SHARE_EXTRA_SOURCES:
        if (repo / rel).is_file():
            out.setdefault(rel, set()).add("share")
    return out


def missing_source_roots(repo):
    return [head for head, _r, _i, _e in SOURCE_ROLES
            if head.startswith(FETCHED_HEADS) and not (repo / head).exists()]


def _line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def scan_lookups(repo, files=None):
    """名前で引く口を拾う。(lookups, silgen, 読んだ本数)。"""
    files = source_files(repo) if files is None else files
    lookups, silgen = [], []
    for rel, roles in sorted(files.items()):
        swift = rel.endswith(".swift")
        objc = rel.endswith((".m", ".mm"))
        text = read_text(repo / rel)
        if not LOOKUP_PREFILTER.search(text):
            continue
        clean = strip_comments(text, swift)
        # 呼び出しは字の外でだけ探す（位置は clean と同じ）。引数の字は clean から読む。
        code = _blank_strings(clean, swift)
        for m in CALL_RE.finditer(code):
            call = m.group(1)
            if call in SWIFT_ONLY_CALLS and not swift:
                continue
            if call in OBJC_OR_SWIFT_CALLS and not (swift or objc):
                continue
            line_start = code.rfind("\n", 0, m.start()) + 1
            if DECL_BEFORE.search(code[line_start:m.start()]):
                continue
            args = _call_args(clean, m.end() - 1, swift)
            if args is None:
                continue
            kind, index = LOOKUP_CALLS[call]
            name = _literal(args[index]) if index < len(args) else None
            lookups.append(Lookup(rel, _line_of(clean, m.start()), call, kind, name, frozenset(roles)))
        if objc:
            for m in OBJC_CLASSNAMED_RE.finditer(code):
                real = OBJC_CLASSNAMED_RE.match(clean, m.start())
                lookups.append(Lookup(rel, _line_of(clean, m.start()), "classNamed:", "class",
                                      _literal(real.group(1)) if real else None, frozenset(roles)))
        for m in SILGEN_START.finditer(code):
            real = SILGEN_RE.match(clean, m.start())
            if real:
                silgen.append((rel, _line_of(clean, m.start()), real.group(1)))
    return lookups, silgen, len(files)


def abi_names(repo):
    """自前の C の口の名前。ヘッダと、Patches/*.diff が足す行から拾う。"""
    names = set()
    for pattern in ABI_HEADER_GLOBS:
        for p in sorted(repo.glob(pattern)):
            names.update(ABI_DECL.findall(strip_comments(read_text(p), False)))
    for p in sorted((repo / "Patches").glob("*.diff")):
        for line in read_text(p).split("\n"):
            if line.startswith("+") and not line.startswith("+++"):
                names.update(ABI_DECL.findall(line[1:]))
    return names


# -- #if DEBUG の中の字 ------------------------------------------------------

DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


def _is_debug_condition(cond):
    c = cond.replace(" ", "").replace("\t", "")
    if "||" in c:
        return False
    return any(part.strip("()") == "DEBUG" for part in c.split("&&"))


def _is_not_debug_condition(cond):
    return cond.replace(" ", "").replace("\t", "") in ("!DEBUG", "!(DEBUG)")


def debug_line_flags(clean):
    """行ごとに、DEBUG でしか建たない行か。枝ごとに [この枝は DEBUG だけか, 前の枝に !DEBUG が在ったか]。
    #if !DEBUG の後ろの #elseif・#else は、どれも DEBUG でしか建たない。"""
    stack, flags = [], []
    for line in clean.split("\n"):
        m = DIRECTIVE.match(line)
        if m:
            kw, cond = m.group(1), m.group(2).strip()
            if kw == "if":
                stack.append([_is_debug_condition(cond), _is_not_debug_condition(cond)])
            elif kw == "elseif" and stack:
                after_not_debug = stack[-1][1]
                stack[-1] = [after_not_debug or _is_debug_condition(cond),
                             after_not_debug or _is_not_debug_condition(cond)]
            elif kw == "else" and stack:
                stack[-1] = [stack[-1][1], stack[-1][1]]
            elif kw == "endif" and stack:
                stack.pop()
            flags.append(False)
            continue
        flags.append(any(frame[0] for frame in stack))
    return flags


_SWIFT_ESCAPES = {"0": "\0", "\\": "\\", "t": "\t", "n": "\n", "r": "\r", '"': '"', "'": "'"}


def _unescape_swift(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        nxt = s[i + 1:i + 2]
        if nxt == "(":
            return None
        if nxt == "u" and s[i + 2:i + 3] == "{":
            end = s.find("}", i + 3)
            if end < 0:
                return None
            try:
                out.append(chr(int(s[i + 3:end], 16)))
            except ValueError:
                return None
            i = end + 1
            continue
        if nxt in _SWIFT_ESCAPES:
            out.append(_SWIFT_ESCAPES[nxt])
            i += 2
            continue
        return None
    return "".join(out)


def _multiline_value(body):
    """\"\"\" と \"\"\" の間（両端を含まない）を、Swift が束ねるときと同じ字にする。"""
    if not body.startswith("\n"):
        return None
    lines = body[1:].split("\n")
    indent = lines[-1]
    if indent.strip():
        return None
    content = lines[:-1]
    pieces = []
    for i, ln in enumerate(content):
        if ln.startswith(indent):
            ln = ln[len(indent):]
        elif not ln.strip():
            ln = ""
        last = i == len(content) - 1
        trailing = len(ln) - len(ln.rstrip("\\"))
        if trailing % 2 == 1:
            pieces.append(ln[:-1])
        else:
            pieces.append(ln + ("" if last else "\n"))
    return _unescape_swift("".join(pieces))


def swift_literals(clean):
    """(値, 位置)。値が決まらないもの（埋め込み・raw 文字列）は値を None にする。"""
    i, n = 0, len(clean)
    while i < n:
        j = clean.find('"', i)
        if j < 0:
            return
        raw = j > 0 and clean[j - 1] == "#"
        end = _skip_string(clean, j, True)
        if clean.startswith('"""', j):
            value = None if raw else _multiline_value(clean[j + 3:end - 3])
        else:
            value = None if raw else _unescape_swift(clean[j + 1:end - 1])
        yield value, j
        i = end


C_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def debug_only_literals(repo, files=None):
    """{字(bytes): (パス, 行)}。DEBUG でしか建たない所にだけある 16 バイト以上の字。"""
    files = source_files(repo) if files is None else files
    debug, released = {}, set()
    for rel in sorted(f for f in files if f.endswith(".swift")):
        clean = strip_comments(read_text(repo / rel), True)
        flags = debug_line_flags(clean)
        whole = rel in DEBUG_ONLY_FILES
        for value, pos in swift_literals(clean):
            if value is None:
                continue
            b = value.encode("utf-8")
            line = clean.count("\n", 0, pos)
            if whole or (line < len(flags) and flags[line]):
                if len(b) >= DEBUG_LITERAL_MIN_BYTES:
                    debug.setdefault(b, (rel, line + 1))
            else:
                released.add(b)
    candidates = {b for b in debug if b not in released}
    # C の側にも同じ字があれば出荷物に入って当然なので引く。改行を含む字は C の 1 つの字にならない。
    probes = {b.decode("utf-8") for b in candidates if b"\n" not in b}
    for rel in sorted(f for f in files if not f.endswith(".swift")):
        if not probes:
            break
        text = read_text(repo / rel)
        if not any(p in text for p in probes):
            continue
        for m in C_LITERAL.finditer(strip_comments(text, False)):
            released.add(re.sub(r"\\(.)", r"\1", m.group(1)).encode("utf-8"))
    return {b: w for b, w in debug.items() if b not in released}


_TOP_DECL = re.compile(r"(?:\b(?:public|internal|fileprivate|private|final|static|nonisolated|indirect)\s+)*"
                       r"\b(?:enum|struct|class|actor|protocol|typealias|func|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)")


def _top_level_names(text):
    """括弧の外（ファイルの一番上の段）で宣言した名前。"""
    names, depth = [], 0
    for line in text.split("\n"):
        if depth == 0:
            names.extend(m.group(1) for m in _TOP_DECL.finditer(line.split("{", 1)[0]))
        depth += line.count("{") - line.count("}")
    return names


def debug_only_callers(repo, files=None):
    """[(パス, 行, 名前, DEBUG_ONLY_FILES のどれか)]。Debug だけのファイルが宣言した名前を
    #if DEBUG の外で使っている所。そこは Release でも建つので、そのファイルの字は出荷物に残る。"""
    files = source_files(repo) if files is None else files
    owners = {}
    for rel in DEBUG_ONLY_FILES:
        if (repo / rel).is_file():
            code = _blank_strings(strip_comments(read_text(repo / rel), True), True)
            for name in _top_level_names(code):
                owners.setdefault(name, rel)
    if not owners:
        return []
    pattern = re.compile(r"\b(%s)\b" % "|".join(re.escape(n) for n in sorted(owners)))
    out = []
    for rel in sorted(f for f in files if f.endswith(".swift") and f not in DEBUG_ONLY_FILES):
        clean = strip_comments(read_text(repo / rel), True)
        flags = debug_line_flags(clean)
        for number, line in enumerate(_blank_strings(clean, True).split("\n")):
            if number < len(flags) and flags[number]:
                continue
            for m in pattern.finditer(line):
                out.append((rel, number + 1, m.group(1), owners[m.group(1)]))
    return out


# ---------------------------------------------------------------------------
# 束を読む
# ---------------------------------------------------------------------------

class Bundle:
    def __init__(self, role, path, info):
        self.role, self.path, self.info = role, path, info
        self.executable = None
        self.macho = None
        self.error = None

    def label(self):
        return "%s（%s）" % (self.path.name, ROLE_LABEL.get(self.role, self.role))


def resolve_input(path, workdir):
    """(.app のパス, 種類)。種類は xcarchive・ipa・app。"""
    p = pathlib.Path(path)
    if not p.exists():
        raise InputError("%s が無い" % p)
    if p.is_dir() and p.suffix == ".xcarchive":
        apps = sorted((p / "Products" / "Applications").glob("*.app"))
        kind = "xcarchive"
    elif p.is_file() and p.suffix == ".ipa":
        try:
            with zipfile.ZipFile(p) as z:
                z.extractall(workdir)
        except zipfile.BadZipFile as e:
            raise InputError("%s を zip として開けない: %s" % (p, e))
        apps = sorted((pathlib.Path(workdir) / "Payload").glob("*.app"))
        kind = "ipa"
    elif p.is_dir() and p.suffix == ".app":
        apps, kind = [p], "app"
    else:
        raise InputError("%s は .xcarchive・.ipa・.app のどれでもない" % p)
    if len(apps) != 1:
        raise InputError("%s に .app が %d 本ある（1 本のはず）" % (p, len(apps)))
    return apps[0], kind


def read_info(bundle_dir):
    path = bundle_dir / "Info.plist"
    if not path.is_file():
        raise InputError("%s が無い" % path)
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except Exception as e:  # 形の誤り
        raise InputError("%s を読めない: %s" % (path, e))


def collect_bundles(app_dir):
    """(役 → Bundle, 予定にない .appex のパス)。"""
    found, unknown = {}, []
    ids = {spec["id"]: role for role, spec in BUNDLES.items()}
    found["app"] = Bundle("app", app_dir, read_info(app_dir))
    for sub in ("Extensions", "PlugIns"):
        for appex in sorted((app_dir / sub).glob("*.appex")):
            info = read_info(appex)
            role = ids.get(info.get("CFBundleIdentifier"))
            if role is None or role == "app" or role in found:
                unknown.append(appex)
                continue
            found[role] = Bundle(role, appex, info)
    for b in found.values():
        name = b.info.get("CFBundleExecutable")
        if isinstance(name, str) and name and (b.path / name).is_file():
            b.executable = b.path / name
            try:
                b.macho = MachO(b.executable)
            except (MachOError, struct.error) as e:
                b.error = "%s を Mach-O として読めない: %s" % (b.executable, e)
        else:
            b.error = "CFBundleExecutable（%r）の実行ファイルが %s に無い" % (name, b.path)
    return found, unknown


def framework_images(app_dir):
    """本体に入っている dylib・framework（dlsym は同じプロセスに載った全部を見る）。"""
    images = []
    fw = app_dir / "Frameworks"
    if not fw.is_dir():
        return images
    for p in sorted(fw.glob("*.dylib")):
        images.append(p)
    for d in sorted(fw.glob("*.framework")):
        exe = d / d.stem
        if exe.is_file():
            images.append(exe)
    out = []
    for p in images:
        try:
            out.append(MachO(p))
        except (MachOError, struct.error):
            continue
    return out


def detect_flavor(info):
    names = set()
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        icons = info.get(key)
        primary = icons.get("CFBundlePrimaryIcon") if isinstance(icons, dict) else None
        name = primary.get("CFBundleIconName") if isinstance(primary, dict) else None
        if isinstance(name, str):
            names.add(name)
    flavors = {ICON_FLAVOR[n] for n in names if n in ICON_FLAVOR}
    if len(flavors) == 1:
        return flavors.pop(), sorted(names)
    return None, sorted(names)


def is_code_signed(bundle_dir):
    return (bundle_dir / "_CodeSignature" / "CodeResources").is_file()


# ---------------------------------------------------------------------------
# 書き出し
# ---------------------------------------------------------------------------

class Report:
    def __init__(self, skip=(), out=None):
        self.skip = set(skip)
        self.out = out or sys.stdout
        self.counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
        self._skipped_once = set()

    def enabled(self, check):
        if check in self.skip:
            if check not in self._skipped_once:
                self._skipped_once.add(check)
                self.add("SKIP", check, "--skip で外した")
            return False
        return True

    def add(self, status, check, message):
        self.counts[status] += 1
        self.out.write("%-4s  %-10s %s\n" % (status, check, message))

    def ok(self, check, message):
        self.add("PASS", check, message)

    def fail(self, check, message):
        self.add("FAIL", check, message)

    def skipped(self, check, message):
        self.add("SKIP", check, message)


# ---------------------------------------------------------------------------
# 検査
# ---------------------------------------------------------------------------

def check_strip(rep, bundles, allow_unstripped):
    """本体の実行ファイルで「出荷する形か」を決める。拡張は数を書くだけ
    （どちらでも、ここで見るのは出荷する実物なので、名前で引けるかの判断は正しい）。"""
    for b in bundles.values():
        if not b.macho:
            continue
        n = len(b.macho.local_defined())
        if n <= STRIP_LOCAL_LIMIT:
            rep.ok("strip", "%s: ローカルシンボル %d 個（strip 済み）" % (b.executable.name, n))
        elif b.role != "app":
            rep.ok("strip", "%s: ローカルシンボル %d 個（strip されていない。出荷もこの形で、判断はこれで正しい）"
                   % (b.executable.name, n))
        elif allow_unstripped:
            rep.skipped("strip", "%s: ローカルシンボル %d 個（strip されていない。--allow-unstripped）"
                        % (b.executable.name, n))
        else:
            rep.fail("strip", "%s: ローカルシンボル %d 個。strip されていない（plain build か Debug）。"
                              "書庫（xcodebuild archive）を渡す。strip されていないものでは名前で引く口が"
                              "通ってしまい、364f940 を見逃す" % (b.executable.name, n))


def check_debug_build(rep, app_dir):
    hits = sorted(p.relative_to(app_dir).as_posix() for p in app_dir.rglob("*")
                  if p.is_file() and DEBUG_BUILD_NAMES.search(p.name))
    if hits:
        for h in hits:
            rep.fail("debugbuild", "%s が入っている。Debug で建てた束（ENABLE_DEBUG_DYLIB）" % h)
    else:
        rep.ok("debugbuild", "*.debug.dylib・__preview.dylib は無い")


def _images_for(role, bundles, frameworks):
    b = bundles.get(role)
    if not b or not b.macho:
        return None, []
    return b, ([b.macho] + (frameworks if role == "app" else []))


def check_lookups(rep, repo, bundles, frameworks, files):
    lookups, silgen, scanned = scan_lookups(repo, files)
    vendor_missing = missing_source_roots(repo)
    if vendor_missing:
        rep.skipped("lookup", "submodule・生成物が無いので読んでいない: %s" % ", ".join(vendor_missing))
    for lk in lookups:
        if (lk.path, lk.call) in LOOKUP_ALLOW:
            rep.ok("lookup", "%s %s は除外（%s）" % (lk.where(), lk.call, LOOKUP_ALLOW[(lk.path, lk.call)]))
            continue
        if lk.name is None:
            rep.fail("lookup", "%s: %s の引数が字でない。出荷版で引けるか測れないので、直に呼ぶか字にする"
                     % (lk.where(), lk.call))
            continue
        for role in sorted(lk.roles):
            b, images = _images_for(role, bundles, frameworks)
            if b is None:
                continue
            ok, how = _resolve(lk.kind, lk.name, images)
            msg = '%s %s("%s") → %s' % (lk.where(), lk.call, lk.name, b.executable.name)
            if ok:
                rep.ok("lookup", "%s: %s" % (msg, how))
            else:
                rep.fail("lookup", "%s: %s" % (msg, how))
    for rel, line, name in silgen:
        rep.ok("lookup", '%s:%d @_silgen_name("%s") はリンクの時に決まる（strip の影響を受けない）'
               % (rel, line, name))
    if not lookups:
        rep.ok("lookup", "名前で引く口はソースに無い（%d 本を読んだ）" % scanned)


def _resolve(kind, name, images):
    if kind == "symbol":
        sym = "_" + name
        for m in images:
            if sym in m.exports():
                return True, "export trie に在る"
        if sym in images[0].imports():
            return True, "外の dylib から取り込んでいる（dlsym で見つかる）"
        return False, ("export されていない。Release の strip で消えるので出荷版では NULL が返る。"
                       "dlsym をやめて直に呼ぶ（364f940）")
    if kind == "class":
        names = images[0].objc_classes()
        for candidate in (name, swift_objc_name(name)):
            if candidate in names:
                return True, "ObjC のクラス一覧に %s が在る" % candidate
        return False, "ObjC のクラス一覧に無い（%s）。名前を変えたか、クラスが消えた" % swift_objc_name(name)
    if name in images[0].objc_methnames():
        return True, "__objc_methname に在る"
    return False, "この実行ファイルのメソッド名に無い"


def check_abi_names(rep, repo, bundles):
    names = abi_names(repo)
    if not names:
        rep.fail("abiname", "自前の C の口の名前を 1 つも拾えない（%s の場所が変わった？）"
                 % ", ".join(ABI_HEADER_GLOBS))
        return
    hits = 0
    for b in bundles.values():
        if not b.macho:
            continue
        strings = b.macho.cstrings(include_objc=False)
        for name in sorted(names):
            if name in ABI_STRING_ALLOW or name.encode() not in strings:
                continue
            hits += 1
            if "_" + name in b.macho.exports():
                rep.ok("abiname", '%s: 字 "%s" が在り、export もされている' % (b.executable.name, name))
            else:
                rep.fail("abiname", '%s: 自前の口の名前 "%s" が字として入っているのに export されていない。'
                         "名前で引いているなら出荷版では見つからない（364f940）" % (b.executable.name, name))
    if not hits:
        rep.ok("abiname", "自前の C の口の名前（%d 個）はどの実行ファイルにも字として入っていない" % len(names))


def _walk_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield k
            for x in _walk_strings(v):
                yield x
    elif isinstance(value, (list, tuple)):
        for v in value:
            for x in _walk_strings(v):
                yield x


def _walk_class_keys(value):
    if isinstance(value, dict):
        for k, v in value.items():
            if k in PLIST_CLASS_KEYS and isinstance(v, str):
                yield k, v
            for x in _walk_class_keys(v):
                yield x
    elif isinstance(value, list):
        for v in value:
            for x in _walk_class_keys(v):
                yield x


def media_protocol_ids(info):
    out = []
    for decl in info.get("UTExportedTypeDeclarations") or []:
        if isinstance(decl, dict) and MEDIA_PROTOCOL_CONFORMS in (decl.get("UTTypeConformsTo") or []):
            ident = decl.get("UTTypeIdentifier")
            if isinstance(ident, str):
                out.append(ident)
    return out


def check_plist(rep, bundles, unknown, app_dir):
    for path in unknown:
        rep.fail("plist", "予定にない拡張 %s（BUNDLES に無い識別子）" % path.relative_to(app_dir).as_posix())
    for role, spec in BUNDLES.items():
        b = bundles.get(role)
        if b is None:
            rep.fail("plist", "%s（%s）が束に無い" % (ROLE_LABEL[role], spec["id"]))
            continue
        where = b.path.parent.name if b.role != "app" else ""
        if spec["dir"] and where != spec["dir"]:
            rep.fail("plist", "%s が %s/ でなく %s/ に入っている" % (b.path.name, spec["dir"], where))
        info = b.info
        ident = info.get("CFBundleIdentifier")
        if ident == spec["id"]:
            rep.ok("plist", "%s: CFBundleIdentifier = %s" % (b.label(), ident))
        else:
            rep.fail("plist", "%s: CFBundleIdentifier が %r（%s のはず）" % (b.label(), ident, spec["id"]))
        raw = sorted({s for s in _walk_strings(info) if "$(" in s})
        if raw:
            rep.fail("plist", "%s: 展開されていないビルド変数 %s" % (b.label(), ", ".join(raw)))
        if b.error:
            rep.fail("plist", "%s: %s" % (b.label(), b.error))
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            if not isinstance(info.get(key), str) or not info.get(key):
                rep.fail("plist", "%s: %s が無い" % (b.label(), key))
    app = bundles.get("app")
    if app is None:
        return
    same = True
    for role in ("device", "share"):
        b = bundles.get(role)
        if b is None:
            continue
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            if b.info.get(key) != app.info.get(key):
                same = False
                rep.fail("plist", "%s: %s が %r、本体は %r。店が受け取らない（ITMS-90473 など）"
                         % (b.label(), key, b.info.get(key), app.info.get(key)))
    if same:
        rep.ok("plist", "版 %s（%s）は本体と拡張で同じ"
               % (app.info.get("CFBundleShortVersionString"), app.info.get("CFBundleVersion")))

    info = app.info
    _expect(rep, app, info.get("ITSAppUsesNonExemptEncryption") is False,
            "ITSAppUsesNonExemptEncryption = NO", "ITSAppUsesNonExemptEncryption が NO でない（輸出の答えを毎回聞かれる）")
    _expect(rep, app, "audio" in (info.get("UIBackgroundModes") or []),
            "UIBackgroundModes に audio", "UIBackgroundModes に audio が無い（裏で音が止まる）")
    _expect(rep, app, bool(info.get("NSMicrophoneUsageDescription")),
            "NSMicrophoneUsageDescription が在る", "NSMicrophoneUsageDescription が無い（playAndRecord で落ちる）")

    dev = bundles.get("device")
    if dev is not None:
        point = (dev.info.get("EXAppExtensionAttributes") or {}).get("EXExtensionPointIdentifier")
        _expect(rep, dev, point == "com.apple.media-device-extension",
                "EXExtensionPointIdentifier = com.apple.media-device-extension",
                "EXExtensionPointIdentifier が %r" % point)
        ids = media_protocol_ids(dev.info)
        _expect(rep, dev, len(ids) == 1, "UTExportedTypeDeclarations の口 = %s" % ", ".join(ids),
                "%s に準じる UTExportedTypeDeclarations が %d 個（1 個のはず）" % (MEDIA_PROTOCOL_CONFORMS, len(ids)))
    share = bundles.get("share")
    if share is not None:
        point = (share.info.get("NSExtension") or {}).get("NSExtensionPointIdentifier")
        _expect(rep, share, point == "com.apple.share-services",
                "NSExtensionPointIdentifier = com.apple.share-services", "NSExtensionPointIdentifier が %r" % point)
    for b in bundles.values():
        for key, name in _walk_class_keys(b.info):
            if not b.macho:
                continue
            ok, how = _resolve("class", name, [b.macho])
            if ok:
                rep.ok("plist", "%s: %s = %s は %s" % (b.label(), key, name, how))
            elif SYSTEM_CLASS.match(name):
                rep.skipped("plist", "%s: %s = %s は系のクラス（束の外なので測らない）" % (b.label(), key, name))
            else:
                rep.fail("plist", "%s: %s = %s が %s。拡張が開かない" % (b.label(), key, name, how))


def _expect(rep, b, cond, good, bad):
    if cond:
        rep.ok("plist", "%s: %s" % (b.label(), good))
    else:
        rep.fail("plist", "%s: %s" % (b.label(), bad))


def _pattern_for(value, bundle_id):
    """.entitlements の $(…) を署名後の形の正規表現にする。"""
    parts, pos = [], 0
    for m in re.finditer(r"\$\((\w+)\)", value):
        parts.append(re.escape(value[pos:m.start()]))
        var = m.group(1)
        if var in ("TeamIdentifierPrefix", "AppIdentifierPrefix"):
            parts.append(r"[A-Z0-9]{10}\.")
        elif var == "PRODUCT_BUNDLE_IDENTIFIER":
            parts.append(re.escape(bundle_id))
        else:
            parts.append(".+")
        pos = m.end()
    parts.append(re.escape(value[pos:]))
    return re.compile("".join(parts) + r"\Z")


def _covers(signed, source, bundle_id):
    if isinstance(source, str):
        return isinstance(signed, str) and bool(_pattern_for(source, bundle_id).match(signed))
    if isinstance(source, list):
        if not isinstance(signed, list):
            return False
        return all(any(_covers(s, x, bundle_id) for s in signed) for x in source)
    if isinstance(source, dict):
        return isinstance(signed, dict) and all(k in signed and _covers(signed[k], v, bundle_id)
                                                for k, v in source.items())
    return signed == source


def read_source_entitlements(repo, role):
    path = repo / BUNDLES[role]["entitlements"]
    if not path.is_file():
        raise InputError("%s が無い（BUNDLES の写しが古い）" % BUNDLES[role]["entitlements"])
    with open(path, "rb") as f:
        return plistlib.load(f)


def entitlement_rules(role, ents, info, signed):
    """(良いか, 字) の列。signed は署名から読んだか（False はリポジトリの .entitlements）。"""
    out = []
    groups = ents.get(GROUPS_KEY) or []
    out.append((APP_GROUP in groups, "App Group %s" % APP_GROUP))
    media = ents.get(MEDIA_DEVICE_KEY)
    if role == "app":
        out.append((media == [], "%s は鍵が在って中身が空（中身が在ると AVAudioSession が '!pla'、"
                                 "鍵が無いとアップロードで ITMS-91183）。いま %r" % (MEDIA_DEVICE_KEY, media)))
        domains = ents.get(DOMAINS_KEY) or []
        out.append((APPLINKS in domains, "associated domains に %s" % APPLINKS))
        dev_mode = [d for d in domains if "mode=developer" in d]
        out.append((not dev_mode, "associated domains に ?mode=developer が無い" +
                    ("（いま %s）" % ", ".join(dev_mode) if dev_mode else "")))
        kvs = ents.get(KVS_KEY)
        if signed:
            good = isinstance(kvs, str) and re.match(r"[A-Z0-9]{10}\.%s\Z" % re.escape(BUNDLES["app"]["id"]), kvs)
            out.append((bool(good), "iCloud KVS = <チーム>.%s（いま %r）" % (BUNDLES["app"]["id"], kvs)))
        else:
            out.append((isinstance(kvs, str) and bool(kvs), "iCloud KVS の鍵が在る"))
    elif role == "device":
        ids = media_protocol_ids(info)
        out.append((isinstance(media, list) and bool(media) and all(i in media for i in ids) and bool(ids),
                    "%s = %r が Info.plist の口 %r を持つ" % (MEDIA_DEVICE_KEY, media, ids)))
    else:
        out.append((MEDIA_DEVICE_KEY not in ents, "%s を持たない（中身を持つのは Media Device Extension だけ）"
                    % MEDIA_DEVICE_KEY))
    return out


def check_entitlements(rep, repo, bundles, kind, require_signed, codesign):
    for role in BUNDLES:
        b = bundles.get(role)
        if b is None or b.macho is None:
            continue
        try:
            origin, ents = b.macho.entitlements()
        except MachOError as e:
            rep.fail("entitle", "%s: %s" % (b.label(), e))
            continue
        signed_bundle = is_code_signed(b.path)
        signed = origin is not None
        if not signed:
            if signed_bundle:
                rep.fail("entitle", "%s: 署名されているのに entitlements が無い" % b.label())
                continue
            if require_signed:
                rep.fail("entitle", "%s: 署名が無い（--require-signed）" % b.label())
                continue
            ents = read_source_entitlements(repo, role)
            rep.skipped("entitle", "%s: 署名が無いので %s から読んだ（署名後の値は測れない）"
                        % (b.label(), BUNDLES[role]["entitlements"]))
        else:
            source = read_source_entitlements(repo, role)
            missing = [k for k, v in source.items() if k not in ents or not _covers(ents[k], v, BUNDLES[role]["id"])]
            if missing:
                rep.fail("entitle", "%s: %s に在る %s が署名に無いか値が違う（profile に無い capability は"
                         "書き出しで落ちる）" % (b.label(), BUNDLES[role]["entitlements"], ", ".join(missing)))
            else:
                rep.ok("entitle", "%s: %s の鍵が全部署名に在る（%s）"
                       % (b.label(), BUNDLES[role]["entitlements"], origin))
            if kind == "ipa":
                if ents.get(GET_TASK_ALLOW) is True:
                    rep.fail("entitle", "%s: get-task-allow が YES（開発用の署名で書き出した）" % b.label())
                else:
                    rep.ok("entitle", "%s: get-task-allow は無い" % b.label())
            if codesign:
                _crosscheck_codesign(rep, codesign, b, ents)
        for good, text in entitlement_rules(role, ents, b.info, signed):
            (rep.ok if good else rep.fail)("entitle", "%s: %s" % (b.label(), text))


def _crosscheck_codesign(rep, codesign, b, ents):
    r = subprocess.run([codesign, "-d", "--entitlements", "-", "--xml", str(b.path)],
                       capture_output=True)
    if r.returncode != 0 or not r.stdout.strip():
        rep.skipped("crosscheck", "%s: codesign -d が読めない（%s）"
                    % (b.label(), r.stderr.decode("utf-8", "replace").strip()[:120]))
        return
    try:
        theirs = plistlib.loads(r.stdout)
    except Exception as e:  # 形の誤り
        rep.skipped("crosscheck", "%s: codesign の出力を plist として読めない（%s）" % (b.label(), e))
        return
    if theirs == ents:
        rep.ok("crosscheck", "%s: codesign -d の entitlements と一致" % b.label())
    else:
        rep.fail("crosscheck", "%s: codesign -d の entitlements と食い違う（ここでの読み取りが古い）" % b.label())


def _hash_tree(root):
    out = {}
    if not root.is_dir():
        return out
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.name not in IGNORED_NAMES:
            out[p.relative_to(root).as_posix()] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def check_samples(rep, repo, app_dir, flavor):
    shipped_dirs = [app_dir / shipped_name for shipped_name, _, _ in SAMPLE_SETS]
    stray = sorted(p.relative_to(app_dir).as_posix() for p in app_dir.rglob("*")
                   if p.is_file() and p.suffix.lower() in JSFX_SUFFIXES
                   and not any(d in p.parents for d in shipped_dirs))
    for s in stray:
        rep.fail("samples", "JSFX が %s の外に入っている: %s"
                 % ("・".join(n + "/" for n, _, _ in SAMPLE_SETS), s))
    for shipped_name, tracked_name, required in SAMPLE_SETS:
        _check_sample_set(rep, repo, app_dir, flavor, shipped_name, tracked_name, required)


def _check_sample_set(rep, repo, app_dir, flavor, shipped_name, tracked_name, required):
    tracked_dir = repo / tracked_name
    tracked = _hash_tree(tracked_dir)
    shipped_dir = app_dir / shipped_name
    shipped = _hash_tree(shipped_dir)
    foreign = sorted(rel for rel, h in shipped.items() if tracked.get(rel) != h)
    for rel in foreign:
        why = "中身が %s と違う" % tracked_name if rel in tracked else "%s に無い" % tracked_name
        rep.fail("samples", "%s/%s: %s。Local/DebugJSFXFactory の第三者の実物は再配布しない"
                 % (shipped_name, rel, why))
    if flavor == "store":
        if shipped_dir.exists():
            rep.fail("samples", "店の版に %s/ が在る（%d 本）。Tools/review_notes.txt の「ships no scripts」が嘘になる"
                     % (shipped_name, len(shipped)))
        else:
            rep.ok("samples", "店の版に %s/ は無い" % shipped_name)
    else:
        if not tracked:
            if required:
                rep.fail("samples", "%s が空か無い。紫の版に積む見本が無い" % tracked_name)
            return
        missing = sorted(set(tracked) - set(shipped))
        if missing:
            rep.fail("samples", "紫（ET_BETA）なのに見本が欠けている: %s（アイコンと中身は同じ構成で決める。"
                     "project.yml の Beta）" % ", ".join(missing))
        elif not foreign:
            rep.ok("samples", "紫の版の %s/ は %s の %d 本と中身まで同じ" % (shipped_name, tracked_name, len(tracked)))


def check_debug_only(rep, repo, bundles, files):
    # 先にソースで。呼ぶ側が 1 か所でも囲っていなければ、下の字は Release でも必ず残る。
    for rel, line, name, owner in debug_only_callers(repo, files):
        rep.fail("debugonly", "%s:%d: %s（%s）を #if DEBUG の外で使っている。Release でも建つので %s の字が"
                              "出荷物に残る。呼ぶ側を #if DEBUG で囲う（%s だけを囲うと Release が建たない）"
                 % (rel, line, name, owner, pathlib.PurePosixPath(owner).name, pathlib.PurePosixPath(owner).name))
    literals = debug_only_literals(repo, files)
    for rel in DEBUG_ONLY_FILES:
        if (repo / rel).is_file() and not any(w[0] == rel for w in literals.values()):
            rep.fail("debugonly", "%s から字を 1 つも拾えない（読み方が古い）" % rel)
    hits = 0
    for b in bundles.values():
        if not b.macho:
            continue
        strings = b.macho.cstrings(include_objc=True)
        for value, (rel, line) in sorted(literals.items(), key=lambda kv: kv[1]):
            if value in strings:
                hits += 1
                shown = value.decode("utf-8", "replace").replace("\n", "\\n")
                rep.fail("debugonly", '%s: Debug だけの字が入っている（%s:%d "%s"）'
                         % (b.executable.name, rel, line, shown[:60] + ("…" if len(shown) > 60 else "")))
    if not hits:
        rep.ok("debugonly", "Debug だけの字（%d 個）はどの実行ファイルにも無い" % len(literals))


def check_nm(rep, nm, bundles):
    for b in bundles.values():
        if not b.macho:
            continue
        cmd = [nm, "--dyldinfo-only", "--defined-only", "--extern-only", "-j"]
        if b.macho.cputype == CPU_TYPE_ARM64:
            cmd += ["-arch", "arm64"]
        r = subprocess.run(cmd + [str(b.executable)], capture_output=True, text=True)
        if r.returncode != 0:
            rep.skipped("crosscheck", "%s: nm が読めない（%s）" % (b.executable.name, r.stderr.strip()[:120]))
            continue
        theirs = {ln.strip() for ln in r.stdout.splitlines() if ln.strip() and not ln.startswith("<")}
        mine = b.macho.exports()
        if theirs == mine:
            rep.ok("crosscheck", "%s: nm の export（%d 個）と一致" % (b.executable.name, len(mine)))
        else:
            rep.fail("crosscheck", "%s: nm の export と食い違う（nm だけ: %s / ここだけ: %s）"
                     % (b.executable.name, sorted(theirs - mine)[:5], sorted(mine - theirs)[:5]))


def find_tool(name, env_name):
    """環境変数（空なら使わない）→ xcrun → PATH の順に探す。"""
    if env_name in os.environ:
        value = os.environ[env_name]
        return value or None
    if sys.platform == "darwin" and shutil.which("xcrun"):
        r = subprocess.run(["xcrun", "--find", name], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    for candidate in (name, "llvm-" + name) if name == "nm" else (name,):
        found = shutil.which(candidate)
        if found:
            return found
    return None


# ---------------------------------------------------------------------------

def default_input():
    return os.path.join(os.environ.get("ARCHIVE_DIR", "/tmp"), "EffeTuneLive.xcarchive")


def parse_args(argv):
    ap = argparse.ArgumentParser(description="出荷する形の EffectDeck を確かめる（364f940 の再発よけ）")
    ap.add_argument("path", nargs="?", default=None,
                    help=".xcarchive・.ipa・.app（既定 ${ARCHIVE_DIR:-/tmp}/EffeTuneLive.xcarchive）")
    ap.add_argument("--flavor", choices=("auto", "store", "beta"), default="auto",
                    help="店の版（青）か TestFlight（紫・ET_BETA）か。auto は CFBundleIconName から")
    ap.add_argument("--repo", default=str(ROOT), help="ソースを読むリポジトリ（既定はこのファイルの上）")
    ap.add_argument("--allow-unstripped", action="store_true",
                    help="strip されていなくても落とさない（試しに見るときだけ）")
    ap.add_argument("--require-signed", action="store_true", help="署名が無ければ落とす")
    ap.add_argument("--skip", default="", help="外す検査を , で（%s）" % ",".join(ALL_CHECKS))
    ap.add_argument("--no-crosscheck", action="store_true", help="nm・codesign と突き合わせない")
    args = ap.parse_args(argv)
    skip = [s for s in args.skip.split(",") if s]
    unknown = [s for s in skip if s not in ALL_CHECKS]
    if unknown:
        ap.error("--skip に知らない名前: %s" % ", ".join(unknown))
    args.skip = skip
    return args


def run(args, out=None):
    out = out or sys.stdout
    repo = pathlib.Path(args.repo).resolve()
    if not (repo / "project.yml").is_file():
        raise InputError("%s はリポジトリではない（project.yml が無い）" % repo)
    path = args.path or default_input()
    workdir = tempfile.mkdtemp(prefix="et-release-check-")
    try:
        app_dir, kind = resolve_input(path, workdir)
        bundles, unknown = collect_bundles(app_dir)
        app = bundles["app"]
        flavor, icons = detect_flavor(app.info)
        flavor_note = "CFBundleIconName=%s" % (",".join(icons) or "無し")
        if args.flavor != "auto":
            if flavor and flavor != args.flavor:
                raise InputError("--flavor %s だがアイコンは %s（%s）" % (args.flavor, flavor, flavor_note))
            flavor, flavor_note = args.flavor, "--flavor"
        elif flavor is None:
            raise InputError("青か紫か決まらない（%s）。--flavor store か --flavor beta を渡す" % flavor_note)
        out.write("== %s（%s、%s: %s）\n" % (path, kind, "店の版" if flavor == "store" else "TestFlight",
                                             flavor_note))
        rep = Report(args.skip, out)
        files = source_files(repo)
        frameworks = framework_images(app_dir)
        if rep.enabled("strip"):
            check_strip(rep, bundles, args.allow_unstripped)
        if rep.enabled("debugbuild"):
            check_debug_build(rep, app_dir)
        if rep.enabled("plist"):
            check_plist(rep, bundles, unknown, app_dir)
        if rep.enabled("entitle"):
            codesign = None
            if not args.no_crosscheck and "crosscheck" not in args.skip:
                codesign = find_tool("codesign", "CODESIGN") if sys.platform == "darwin" else os.environ.get("CODESIGN")
            check_entitlements(rep, repo, bundles, kind, args.require_signed, codesign)
        if rep.enabled("lookup"):
            check_lookups(rep, repo, bundles, frameworks, files)
        if rep.enabled("abiname"):
            check_abi_names(rep, repo, bundles)
        if rep.enabled("samples"):
            check_samples(rep, repo, app_dir, flavor)
        if rep.enabled("debugonly"):
            check_debug_only(rep, repo, bundles, files)
        if not args.no_crosscheck and rep.enabled("crosscheck"):
            nm = find_tool("nm", "NM")
            if nm:
                check_nm(rep, nm, bundles)
            else:
                rep.skipped("crosscheck", "nm が無い（Mac では xcrun nm、Linux では llvm-nm）")
        out.write("== PASS %d / FAIL %d / SKIP %d\n" % (rep.counts["PASS"], rep.counts["FAIL"], rep.counts["SKIP"]))
        return 1 if rep.counts["FAIL"] else 0
    except (MachOError, struct.error) as e:
        # 読んでいる途中で壊れていると分かった実行ファイル。確かめ切れていないので FAIL（1）でなく 2。
        raise InputError("実行ファイルを読み切れない（壊れているか、ここが知らない形）: %s" % e) from e
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return run(args)
    except InputError as e:
        sys.stderr.write("!! %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
