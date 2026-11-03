#!/usr/bin/env python3
"""make_package.py（Tests/Fuzz）
外から来る字を読むコードを libFuzzer で叩くための SwiftPM パッケージを書く。標準ライブラリだけ。

    python3 Tests/Fuzz/make_package.py --repo <repo> --out <dir> [--add <path> ...]

- **何を建てるかは Linux の単体テストと同じ。**Tests/Linux/make_package.py の collect を
  そのまま呼ぶので、project.yml に登録したアプリのファイルと代役（Tests/Linux/Shims）が
  そのまま入る。ここに一覧を持たない
- 違うのは 2 つだけ:
    - Tests/Unit のファイルは入れない（XCTest を連れてくる。fuzz は試験の道具を使わない）
    - 代わりに Tests/Fuzz/Harness/*.swift を入れ、1 本の実行ファイル EffectDeckFuzz にする。
      どの的を叩くかは環境変数 ET_FUZZ_TARGET で選ぶ（Harness/Entry.swift）
- project.yml にまだ無いが的に要るファイルは --add で足す（Linux の make_package.py と同じ）
- 資源（chain/ や見本の JSON）は入れない。的は資源を読まない
"""
import argparse
import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
TARGET = "EffectDeckFuzz"
HARNESS = "Tests/Fuzz/Harness"


def load_linux_packager():
    path = HERE.parent / "Linux" / "make_package.py"
    spec = importlib.util.spec_from_file_location("linux_make_package", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def package_swift(mp, sources):
    deps = ", ".join('"%s"' % m for m in mp.SHIM_MODULES)
    targets = []
    for mod, mdeps in mp.SHIM_MODULES.items():
        extra = ""
        if mod == "CCompression":
            extra = ', linkerSettings: [.linkedLibrary("z")]'
        targets.append('        .target(name: "%s", dependencies: [%s], path: "Shims/%s"%s),'
                       % (mod, ", ".join('"%s"' % d for d in mdeps), mod, extra))
    src = ",\n".join('                "%s"' % s for s in sources)
    return """// swift-tools-version:5.9
// Tests/Fuzz/make_package.py が書いたもの。手で直さない。
// tools-version 5.9 なので Swift 5 の言語モードで建つ（Xcode のバンドルと同じ）。
// **-sanitize=fuzzer,address と -parse-as-library は run.sh が -Xswiftc で渡す。**
// main は libFuzzer が持つので、このターゲットに main.swift は無い。
import PackageDescription

let package = Package(
    name: "EffectDeckFuzz",
    targets: [
%s
        .executableTarget(
            name: "%s",
            dependencies: [%s],
            path: "repo",
            sources: [
%s
            ],
            swiftSettings: [
                // Linux の Foundation は URLSession を FoundationNetworking に分けている。
                // アプリのファイルに import を足さずに済むよう、全ファイルへ暗黙に読み込ませる。
                .unsafeFlags(["-Xfrontend", "-import-module", "-Xfrontend", "FoundationNetworking"]),
            ]
        ),
    ]
)
""" % ("\n".join(targets), TARGET, deps, src)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--add", nargs="*", default=[])
    a = ap.parse_args()
    repo = pathlib.Path(a.repo)
    out = pathlib.Path(a.out)
    mp = load_linux_packager()

    sources, _resources = mp.collect(repo, list(a.add))
    # 試験の道具（XCTest を引く）は入れない。代役のうちモジュールへ直接入るもの
    # （Tests/Linux/Shims/FoundationGaps）は collect が足してあるのでそのまま。
    sources = [s for s in sources if not s.startswith("Tests/Unit/")]
    harness = sorted(p.relative_to(repo).as_posix()
                     for p in (repo / HARNESS).glob("*.swift"))
    if not harness:
        mp.fail("%s に .swift が無い" % HARNESS)
    sources += harness

    names = {}
    for s in sources:
        n = pathlib.PurePosixPath(s).name
        if n in names:
            mp.fail("同じ名前のSwiftが2つ: %s と %s（SwiftPMは建てられない）" % (names[n], s))
        names[n] = s

    keep = set()
    for rel in sources:
        mp.sync(repo / rel, out / "repo" / rel, keep,
                mp.split_catalog if rel == mp.CATALOG else None)
    shim_root = repo / "Tests/Linux/Shims"
    for mod in mp.SHIM_MODULES:
        d = shim_root / mod
        if not d.is_dir():
            mp.fail("代役 %s が無い" % d)
        for rel in mp.walk(shim_root, mod):
            mp.sync(shim_root / rel, out / "Shims" / rel, keep)

    pkg = out / "Package.swift"
    text = package_swift(mp, sources)
    if not pkg.exists() or pkg.read_text(encoding="utf-8") != text:
        pkg.write_text(text, encoding="utf-8")
    keep.add(pkg)

    # 一覧から外れたものを消す（.build は触らない）。
    import os
    for top in ("repo", "Shims"):
        root = out / top
        if not root.exists():
            continue
        for dirpath, _dirnames, filenames in os.walk(root, topdown=False):
            for f in filenames:
                p = pathlib.Path(dirpath) / f
                if p not in keep:
                    p.unlink()
            if not os.listdir(dirpath):
                os.rmdir(dirpath)

    (out / "sources.txt").write_text("".join(s + "\n" for s in sources), encoding="utf-8")
    print("make_package(fuzz): sources %d (harness %d)" % (len(sources), len(harness)))


if __name__ == "__main__":
    sys.exit(main())
