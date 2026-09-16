"""落とした ADP を nemut.ai へ置いて、source.json の size を実寸に合わせる。

  python3 adp_place.py <落とした pkg のディレクトリ>

前段は Mac の `~/adp_fetch.sh`（ADP ID を読む → api.altstore.io に聞く → 落とす）。
ここは Windows 側で、`new-nemutai/public/effetune-live/adp/` へ
**階層をそのまま**写す。manifest.json には一切触らない。

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


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    src = pathlib.Path(sys.argv[1])
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

    if SITE.exists():
        shutil.rmtree(SITE)
    shutil.copytree(root, SITE)
    n = sum(1 for _ in SITE.rglob("*") if _.is_file())
    print(f"置いた: {SITE} （{n} ファイル）")

    # variant のどれかの大きさを size にする
    variants = [p for p in SITE.rglob("*") if p.is_file()
                and "variant" in str(p.relative_to(SITE)).lower()]
    if variants:
        pick = max(variants, key=lambda p: p.stat().st_size)
    else:
        pick = max((p for p in SITE.rglob("*") if p.is_file()),
                   key=lambda p: p.stat().st_size)
    size = pick.stat().st_size
    print(f"size = {size}  （{pick.relative_to(SITE)}）")

    for p in SOURCES:
        d = json.loads(p.read_text(encoding="utf-8"))
        v = d["apps"][0]["versions"][0]
        v["size"] = size
        v["downloadURL"] = "https://nemut.ai/effetune-live/adp/manifest.json"
        p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n",
                     encoding="utf-8", newline="\n")
        print("直した", p)

    print()
    print("次: new-nemutai を commit して push（GitHub Actions が Cloudflare へ出す）")
    print("    出たら curl でファイルが取れるか見て、federate を撃ち直す")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
