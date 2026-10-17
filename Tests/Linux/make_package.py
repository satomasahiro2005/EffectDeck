#!/usr/bin/env python3
"""make_package.py
Logicバンドル（project.ymlのEffeTuneLiveUnitTests）を、Linuxのswift testで走るSwiftPMの
パッケージに写す。標準ライブラリだけで書いてある（CIのswiftイメージにpipは無い）。

    python3 Tests/Linux/make_package.py --repo <repo> --out <dir> [--add <path> ...]

- **何を入れるかはproject.ymlが決める。**ここに一覧を持たない。登録を忘れたファイルは
  Linuxでも落ちるので、Macで初めて気付くことにならない
- 落とすのは.cpp .mm .h .c .m（Swiftのテストに入らない）と、JSFX*Tests・JSFXHostSupport
  （ysfxを建てるのでMacだけ）、VisualizerSettings*（Combineが要るのでMacだけ）
- アプリのソースは書き換えない。Linuxに無いもの（os / Accelerate / CryptoKit /
  Compression、FoundationにあってLinuxに無いAPI）はTests/Linux/Shimsの代役で埋める。
  例外は生成物のEffectCatalog.swiftだけで、1つの配列リテラルを1件ずつの定数に分けて写す
  （中身と順番は同じ。split_catalogの説明を参照）
- 資源（buildPhase: resources / type: folder）はリポジトリと同じ相対パスに置く。
  TestResource.urlがBundleで見つけられないとき#filePathから辿るのと同じ形になる
- 写し先は中身が同じなら書き直さない（.buildの差分ビルドを生かす）。一覧から外れた
  ファイルは消す
"""
import argparse
import fnmatch
import os
import pathlib
import re
import sys

TARGET = "EffeTuneLiveUnitTests"
DROP_EXT = {".cpp", ".mm", ".h", ".c", ".m", ".hpp"}
DROP_NAMES = ["JSFX*Tests.swift", "JSFXHostSupport.swift", "VisualizerSettings*.swift"]
# Linux用の代役。モジュールごとのフォルダで、名前がそのままimportの名前になる。
SHIM_MODULES = {
    "os": [],
    "OSLog": ["os"],
    "Accelerate": [],
    "CryptoKit": [],
    "CCompression": [],
    "Compression": ["CCompression"],
}
# テストのモジュールへ直接入れる代役（FoundationにあってLinuxに無い関数など）。
IN_MODULE_SHIMS = "Tests/Linux/Shims/FoundationGaps"


def fail(msg):
    print("make_package: " + msg, file=sys.stderr)
    sys.exit(2)


def parse_sources(project_yml):
    """EffeTuneLiveUnitTestsのsources:を[(path, attrs)]で返す。YAMLを全部は読まない。"""
    lines = project_yml.read_text(encoding="utf-8").replace("\r\n", "\n").split("\n")
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^  %s:\s*$" % TARGET, line):
            start = i
            break
    if start is None:
        fail("project.ymlに%sが無い" % TARGET)

    def indent(s):
        return len(s) - len(s.lstrip(" "))

    items = []
    in_sources = False
    list_indent = None
    for line in lines[start + 1:]:
        body = line.split("#", 1)[0].rstrip() if not line.lstrip().startswith("#") else ""
        if not body.strip():
            continue
        ind = indent(body)
        if ind <= 2:
            break  # 次のターゲット
        if ind == 4:
            in_sources = body.strip() == "sources:"
            continue
        if not in_sources:
            continue
        text = body.strip()
        if text.startswith("- "):
            if list_indent is None:
                list_indent = ind
            if ind != list_indent:
                continue  # excludes: などの入れ子の一覧
            entry = text[2:].strip()
            m = re.match(r"^path:\s*(.+)$", entry)
            path = (m.group(1) if m else entry).strip().strip("'\"")
            items.append([path, {}])
        elif items and ind > (list_indent or 0):
            m = re.match(r"^(\w+):\s*(.*)$", text)
            if m and m.group(2):
                items[-1][1][m.group(1)] = m.group(2).strip().strip("'\"")
    if not items:
        fail("%sのsources:が読めない" % TARGET)
    return items


def dropped(rel, explicit):
    name = pathlib.PurePosixPath(rel).name
    if pathlib.PurePosixPath(rel).suffix in DROP_EXT:
        return True
    if explicit:
        return False
    return any(fnmatch.fnmatch(name, pat) for pat in DROP_NAMES)


def walk(repo, rel):
    base = repo / rel
    if base.is_file():
        return [rel]
    out = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for f in sorted(filenames):
            if f.startswith("."):
                continue
            p = pathlib.Path(dirpath) / f
            out.append(p.relative_to(repo).as_posix())
    return out


def collect(repo, adds):
    sources, resources = [], []
    for path, attrs in parse_sources(repo / "project.yml"):
        if not (repo / path).exists():
            fail("project.ymlの%sが無い" % path)
        is_resource = attrs.get("buildPhase") == "resources" or attrs.get("type") == "folder"
        for rel in walk(repo, path):
            if is_resource:
                resources.append(rel)
            elif rel.endswith(".swift"):
                if not dropped(rel, explicit=False):
                    sources.append(rel)
            elif not dropped(rel, explicit=False):
                resources.append(rel)  # xcodegenはソースのフォルダにある非ソースを資源にする
    for add in adds:
        p = pathlib.Path(add)
        if p.is_absolute():
            try:
                p = p.resolve().relative_to(repo.resolve())
            except ValueError:
                fail("--add %s はリポジトリの外" % add)
        rel = os.path.normpath(p.as_posix()).replace(os.sep, "/")
        if rel.startswith("../") or not (repo / rel).exists():
            fail("--add %s が無い" % add)
        for r in walk(repo, rel):
            if r.endswith(".swift"):
                sources.append(r)
            elif not dropped(r, explicit=True):
                resources.append(r)
    for r in walk(repo, IN_MODULE_SHIMS):
        if r.endswith(".swift"):
            sources.append(r)

    def uniq(xs):
        seen, out = set(), []
        for x in xs:
            if x not in seen:
                seen.add(x)
                out.append(x)
        return out

    sources, resources = uniq(sources), uniq(resources)
    names = {}
    for s in sources:
        n = pathlib.PurePosixPath(s).name
        if n in names:
            fail("同じ名前のSwiftが2つ: %s と %s（SwiftPMは建てられない）" % (names[n], s))
        names[n] = s
    return sources, resources


CATALOG = "Sources/EffeTuneLive/Generated/EffectCatalog.swift"


def split_catalog(data):
    """EffectCatalog.swiftの`let ETCatalog: [ETEffect] = [ ... ]`を、1件ずつの定数に分けた写しにする。

    1つの配列リテラルに107件（約1700行）あると、swiftcはその式1つの型を解くのに5GB近く使い、
    ジョブが2本重なるとWSL（とCIの小さい機械）を落とす。**中身は1文字も変えない。**
    各ETEffect(...)をそのまま`let _etCatalogNNN: ETEffect = ...`へ移し、ETCatalogはそれを
    同じ順に並べるだけ。形が想定と違えば止める（丸ごと建てて機械を落とすよりよい）。
    """
    text = data.decode("utf-8")
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(nl)
    head = "let ETCatalog: [ETEffect] = ["
    if lines.count(head) != 1 or lines.count("]") < 1:
        fail("%s の形が想定と違う（`%s` と `]` の行が要る）" % (CATALOG, head))
    start = lines.index(head)
    end = start + 1 + lines[start + 1:].index("]")
    body = lines[start + 1:end]
    chunks, cur = [], None
    for line in body:
        if line == "    ETEffect(":
            if cur is not None:
                chunks.append(cur)
            cur = [line]
        elif cur is None:
            if line.strip():
                fail("%s: ETEffect( より前に行がある: %r" % (CATALOG, line))
        else:
            cur.append(line)
    if cur is not None:
        chunks.append(cur)
    if not chunks or len(chunks) != sum(1 for l in body if l == "    ETEffect("):
        fail("%s を1件ずつに分けられない" % CATALOG)
    out = lines[:start]
    names = []
    for i, chunk in enumerate(chunks):
        while chunk and not chunk[-1].strip():
            chunk.pop()
        last = chunk[-1].rstrip()
        if i < len(chunks) - 1:
            if not last.endswith(","):
                fail("%s: %d件目の終わりに , が無い" % (CATALOG, i))
            last = last[:-1]
        elif last.endswith(","):
            last = last[:-1]
        chunk[-1] = last
        name = "_etCatalog%03d" % i
        names.append(name)
        out.append("let %s: ETEffect =" % name)
        out.extend(chunk)
    out.append("// Tests/Linux/make_package.py が1件ずつの定数に分けた写し（中身と順番は元と同じ）。")
    out.append(head)
    out.extend("    %s," % n for n in names)
    out.extend(lines[end:])
    return nl.join(out).encode("utf-8")


def sync(src, dst, keep, transform=None):
    keep.add(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    data = src.read_bytes()
    if transform is not None:
        data = transform(data)
    if dst.exists() and dst.read_bytes() == data:
        return
    dst.write_bytes(data)


def skip_patterns(repo):
    """skip.txtの1行＝`Class/testMethod  # 理由`。理由の無い行は受けない。"""
    path = repo / "Tests/Linux/skip.txt"
    out = []
    if not path.exists():
        return out
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        test, _, reason = line.partition("#")
        test = test.strip()
        if not reason.strip():
            fail("skip.txt:%d に理由が無い（`Class/testMethod  # 理由`）" % n)
        if not re.match(r"^\w+(/\w+)?$", test):
            fail("skip.txt:%d の形が違う: %s" % (n, test))
        out.append(test)
    return out


def package_swift(sources, resources):
    deps = ", ".join('"%s"' % m for m in SHIM_MODULES)
    targets = []
    for mod, mdeps in SHIM_MODULES.items():
        extra = ""
        if mod == "CCompression":
            extra = ', linkerSettings: [.linkedLibrary("z")]'
        targets.append('        .target(name: "%s", dependencies: [%s], path: "Shims/%s"%s),'
                       % (mod, ", ".join('"%s"' % d for d in mdeps), mod, extra))
    src = ",\n".join('                "%s"' % s for s in sources)
    # 資源はTestResourceが#filePathから辿って読む。SwiftPMの資源にはしない（Bundle.moduleは使わない）。
    exc = ",\n".join('                "%s"' % r for r in resources)
    return """// swift-tools-version:5.9
// Tests/Linux/make_package.pyが書いたもの。手で直さない。
// tools-version 5.9なのでSwift 5の言語モードで建つ（Xcodeのバンドルと同じ）。
import PackageDescription

let package = Package(
    name: "EffectDeckLinux",
    targets: [
%s
        .testTarget(
            name: "%s",
            dependencies: [%s],
            path: "repo",
            exclude: [
%s
            ],
            sources: [
%s
            ],
            swiftSettings: [
                // DarwinのFoundationはURLSessionまで含むが、LinuxではFoundationNetworkingに分かれている。
                // アプリのファイルにimportを足さずに済むよう、全ファイルへ暗黙に読み込ませる。
                .unsafeFlags(["-Xfrontend", "-import-module", "-Xfrontend", "FoundationNetworking"]),
            ]
        ),
    ]
)
""" % ("\n".join(targets), TARGET, deps, exc, src)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--add", nargs="*", default=[])
    a = ap.parse_args()
    repo = pathlib.Path(a.repo)
    out = pathlib.Path(a.out)
    sources, resources = collect(repo, a.add)

    keep = set()
    for rel in sources + resources:
        sync(repo / rel, out / "repo" / rel, keep, split_catalog if rel == CATALOG else None)
    shim_root = repo / "Tests/Linux/Shims"
    for mod in SHIM_MODULES:
        d = shim_root / mod
        if not d.is_dir():
            fail("代役 %s が無い" % d)
        for rel in walk(shim_root, mod):
            sync(shim_root / rel, out / "Shims" / rel, keep)

    pkg = out / "Package.swift"
    text = package_swift(sources, resources)
    if not pkg.exists() or pkg.read_text(encoding="utf-8") != text:
        pkg.write_text(text, encoding="utf-8")
    keep.add(pkg)

    # 一覧から外れたものを消す（.buildは触らない）。
    for top in ("repo", "Shims"):
        root = out / top
        if not root.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(root, topdown=False):
            for f in filenames:
                p = pathlib.Path(dirpath) / f
                if p not in keep:
                    p.unlink()
            if not os.listdir(dirpath):
                os.rmdir(dirpath)

    (out / "skip.txt").write_text("".join(s + "\n" for s in skip_patterns(repo)), encoding="utf-8")
    (out / "sources.txt").write_text("".join(s + "\n" for s in sources), encoding="utf-8")
    (out / "resources.txt").write_text("".join(s + "\n" for s in resources), encoding="utf-8")
    tests = [s for s in sources if s.endswith("Tests.swift")]
    print("make_package: sources %d (tests %d), resources %d, skip %d"
          % (len(sources), len(tests), len(resources), len(skip_patterns(repo))))


if __name__ == "__main__":
    main()
