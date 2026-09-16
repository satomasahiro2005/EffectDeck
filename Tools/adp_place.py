"""落とした ADP を nemut.ai へ置いて、source.json に版の行を足す。

  python3 adp_place.py <落とした pkg のディレクトリ> <版> <ビルド番号> <日付>
  例: python3 adp_place.py /tmp/adp-2.9.1 2.9.1 11 2026-09-17

前段は Mac の `~/adp_fetch.sh`（ADP ID を読む → api.altstore.io に聞く → 落とす）。
ここは Windows 側で、`new-nemutai/public/effetune-live/adp/<版>/` へ
**階層をそのまま**写す。manifest.json には一切触らない
（各ファイルのハッシュが書いてあるので、1 バイト変えると使えなくなる）。

**版ごとに別の場所へ置く。** 上書きすると前の版の downloadURL が 404 になり、
AltStore から古い版へ戻せなくなる。2.9.0 だけは `adp/` の直下に置いてあるので
（最初の配布のときは版を分けていなかった）、そのままにしてある。

size は faq.altstore.io の逐語:
  「The size of your app in bytes.」
  「For ADPs you can pick any of the variants from your `variant` folder to determine the size.」
"""
import json
import pathlib
import shutil
import sys

SITE = pathlib.Path("C:/Users/masahiro/workspace/new-nemutai/public/effetune-live/adp")
SOURCES = [
    pathlib.Path("C:/Users/masahiro/workspace/new-nemutai/public/effetune-live/source.json"),
    pathlib.Path("C:/Users/masahiro/workspace/effetune-live/docs/altstore/source.json"),
]
BASE = "https://nemut.ai/effetune-live/adp"


def main() -> int:
    if len(sys.argv) < 5:
        print(__doc__)
        return 1
    src = pathlib.Path(sys.argv[1])
    version, build, date = sys.argv[2], sys.argv[3], sys.argv[4]
    if not src.is_dir():
        print("!! ディレクトリが無い", src)
        return 1

    manifests = list(src.rglob("manifest.json"))
    if not manifests:
        print("!! manifest.json が見つからない。落とし方を確かめること")
        return 1
    # 一番浅いものを根と見る
    root = min(manifests, key=lambda p: len(p.relative_to(src).parts)).parent
    print("根 =", root)

    dst = SITE / version
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(root, dst)
    n = sum(1 for _ in dst.rglob("*") if _.is_file())
    print(f"置いた: {dst} （{n} ファイル）")

    # variant のどれかの大きさを size にする
    variants = [p for p in dst.rglob("*") if p.is_file()
                and "variant" in str(p.relative_to(dst)).lower()]
    if variants:
        pick = max(variants, key=lambda p: p.stat().st_size)
    else:
        pick = max((p for p in dst.rglob("*") if p.is_file()),
                   key=lambda p: p.stat().st_size)
    size = pick.stat().st_size
    print(f"size = {size}  （{pick.relative_to(dst)}）")

    notes = (pathlib.Path(__file__).parent.parent
             / "docs" / "altstore" / f"whatsnew-{version}.txt")
    description = notes.read_text(encoding="utf-8").strip() if notes.is_file() else ""
    if not description:
        print(f"!! {notes.name} が無い。What's New を書いてから走らせること")
        return 1

    entry = {
        "version": version,
        "buildVersion": build,
        "date": date,
        "localizedDescription": description,
        "downloadURL": f"{BASE}/{version}/manifest.json",
        "size": size,
        "minOSVersion": "27.0",
    }

    for p in SOURCES:
        d = json.loads(p.read_text(encoding="utf-8"))
        versions = d["apps"][0]["versions"]
        # 同じ版が既にあれば差し替え、無ければ先頭へ。**新しい順に並べる。**
        versions = [v for v in versions if v.get("version") != version]
        versions.insert(0, entry)
        d["apps"][0]["versions"] = versions
        p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n",
                     encoding="utf-8", newline="\n")
        print("直した", p)

    print()
    print("次: new-nemutai を commit して push（GitHub Actions が Cloudflare へ出す）")
    print(f"    出たら curl {BASE}/{version}/manifest.json でファイルが取れるか見る")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
