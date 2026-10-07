#!/usr/bin/env python3
"""Tools/jsfx-bench/opcodes.py — run.sh --profile の数（スクリプトごとの JSON）を 1 枚にまとめる。

  python3 Tools/jsfx-bench/opcodes.py build/jsfx-bench/opcodes/*.json [--json out.json] [--md out.md] [--top 20]

並べ方は「スクリプトを同じ重さで足したもの」（各スクリプトの中の割合を 7 本で平均）。
fir や slow のように 1 フレームの命令が多いものだけで決まらないように。生の合計も横に出す。
組の 1 つめが (start) のものは回の頭（@sample の 1 命令め）。
"""
import json
import math
import sys


def main(argv):
    files, out_json, out_md, top = [], None, None, 20
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--json":
            out_json = argv[i + 1]; i += 2
        elif a == "--md":
            out_md = argv[i + 1]; i += 2
        elif a == "--top":
            top = int(argv[i + 1]); i += 2
        else:
            files.append(a); i += 1
    if not files:
        print(__doc__)
        return 2
    runs = []
    for f in sorted(files):
        with open(f, encoding="utf-8") as fh:
            d = json.load(fh)
        blocks = math.ceil(d["seconds"] * 48000 / 256) + math.ceil(d["warmupSeconds"] * 48000 / 256)
        d["frames"] = blocks * 256
        runs.append(d)
    names = runs[0]["names"]
    n = len(names)
    ops_eq = [0.0] * n
    ops_raw = [0] * n
    pairs_eq, pairs_raw = {}, {}
    per_script = []
    for d in runs:
        total = sum(d["ops"])
        per_script.append({"script": d["scripts"], "frames": d["frames"], "ops": total,
                           "opsPerFrame": round(total / d["frames"], 2)})
        for k, c in enumerate(d["ops"]):
            ops_raw[k] += c
            ops_eq[k] += c / total / len(runs)
        ptotal = sum(c for _, _, c in d["pairs"])
        for a, b, c in d["pairs"]:
            pairs_raw[(a, b)] = pairs_raw.get((a, b), 0) + c
            pairs_eq[(a, b)] = pairs_eq.get((a, b), 0.0) + c / ptotal / len(runs)
    raw_total = sum(ops_raw)
    raw_ptotal = sum(pairs_raw.values())
    top_ops = sorted(range(n), key=lambda k: -ops_eq[k])
    top_pairs = sorted(pairs_eq, key=lambda p: -pairs_eq[p])

    def script_share(d, a, b=None):
        if b is None:
            return d["ops"][a] / sum(d["ops"])
        t = sum(c for _, _, c in d["pairs"])
        return sum(c for x, y, c in d["pairs"] if x == a and y == b) / t

    result = {
        "weighting": "each script equal (mean of per-script shares)",
        "scripts": per_script,
        "ops": [{"op": names[k], "share": round(ops_eq[k], 5), "rawCount": ops_raw[k],
                 "rawShare": round(ops_raw[k] / raw_total, 5)} for k in top_ops if ops_raw[k]],
        "pairs": [{"first": names[a], "second": names[b], "share": round(pairs_eq[(a, b)], 5),
                   "rawCount": pairs_raw[(a, b)], "rawShare": round(pairs_raw[(a, b)] / raw_ptotal, 5),
                   "byScript": {d["scripts"]: round(script_share(d, a, b), 4) for d in runs}}
                  for (a, b) in top_pairs],
    }
    lines = []
    lines.append("scripts: " + ", ".join(f"{s['script']} {s['opsPerFrame']} ops/frame" for s in per_script))
    lines.append("")
    lines.append(f"top {top} opcodes (equal weight / raw)")
    for k in top_ops[:top]:
        lines.append(f"  {names[k]:<28} {ops_eq[k]*100:6.2f}%  {ops_raw[k]/raw_total*100:6.2f}%")
    lines.append("")
    lines.append(f"top {top} pairs (equal weight / raw)")
    for (a, b) in top_pairs[:top]:
        lines.append(f"  {names[a]:<28} -> {names[b]:<28} {pairs_eq[(a, b)]*100:6.2f}%  "
                     f"{pairs_raw[(a, b)]/raw_ptotal*100:6.2f}%")
    print("\n".join(lines))
    if out_json:
        with open(out_json, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(result, fh, indent=1, ensure_ascii=False)
            fh.write("\n")
    if out_md:
        md = ["| # | 1 つめ | 2 つめ | 割合（等重） | 割合（生） | " + " | ".join(d["scripts"] for d in runs) + " |",
              "|---:|---|---|---:|---:|" + "---:|" * len(runs)]
        for i, (a, b) in enumerate(top_pairs[:top], 1):
            md.append(f"| {i} | `{names[a]}` | `{names[b]}` | {pairs_eq[(a, b)]*100:.2f}% | "
                      f"{pairs_raw[(a, b)]/raw_ptotal*100:.2f}% | " +
                      " | ".join(f"{script_share(d, a, b)*100:.1f}" for d in runs) + " |")
        with open(out_md, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(md) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
