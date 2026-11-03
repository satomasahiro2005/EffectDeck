#!/usr/bin/env python3
"""bench の生の tsv（run<i>_total.tsv / run<i>_seam.tsv）を 1 つの md と tsv にまとめる。

  python3 report.py --label baseline-cee1267 --meta meta.txt --raw 生のあるディレクトリ --out results

Mac の標準の python3（3.9）で動くように、新しい構文は使わない。
"""
import argparse
import glob
import os
import re
from collections import OrderedDict

METHOD = """\
- 1 コマは本番の tick と同じ順: ETMeterTap_Write（1/30 秒ぶん）→ pull(rate:now:) → draw(in:)。
  器は 1280x256 の BGRA（premultipliedFirst・little endian・DeviceRGB）を PiPVisualizer.pixelBuffer と同じに上下反転したもの。
  draw が「写す道」を通らなければ（黙って全部描く道に落ちたら）その場で止まる。
- 時計は clock_gettime_nsec_np(CLOCK_UPTIME_RAW)。1 回の読みは数十 ns なので、0.01ms 未満の区画は読みの誤差が乗る。
- 信号は温め（180 コマ = 6 秒。300 列のスペクトログラムは 150 コマで埋まる）のあと、全信号を 30 コマのブロックごとに順に回し、
  ブロックの頭 2 コマは切り替えで冷えているので捨てる。時間のずれ（温度・他のプロセス）が特定の信号に偏らないようにするため。
- 区画別は、MiniMeters.swift の private を外しただけの写しを**建てるたびに元から機械的に作り**（build.sh の sed。書き換えは 10 行で、数が違えば止まる）、
  draw(in:) の中身（copyBackdrop → waveform → spectrum → stereo → levels）を同じ順で 1 つずつ時計で挟んで計る。
  全体の draw と区画に分けた draw は 1 コマおきに先後を入れ替え、どちらかだけが温かい器に当たらないようにしている。
  区画の合計と全体の突き合わせは表 5。「全体の版」は private を外していない元のコードそのもの。
- スペアナは塗りと線（strokePath）を分けられない（同じ関数）ので「線込み」。
- copyBackdrop の内訳（背景の memcpy・スペクトログラムの memcpy）は、中の 2 つのループと同じ書き方を別に計った写し。差は器の検査（CFEqual など）。
- pull の advanceSpectrogram（FFT・スペクトログラムの 1 列・スペアナ）は、pull のあとにもう 1 度単独で呼んで計る。
  その呼びでスペクトログラムは 2 列余計に進む（区画版だけ。重さは変わらない）。pull 全体は全体の版の値。
- 限界: 連続して回すので、30fps で間に休みが入る本番より CPU が高い周波数に張り付きやすく、キャッシュも温かい。
  絶対値でなく、同じ道具での前後比較に使う。省電力モードや電池駆動かは冒頭の記録を見る。
"""


def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        next(fh)
        for line in fh:
            p = line.rstrip("\n").split("\t")
            rows.append({"signal": p[0], "metric": p[1], "n": int(p[2]),
                         "median": float(p[3]), "p95": float(p[4]), "mean": float(p[5]),
                         "min": float(p[6]), "max": float(p[7])})
    return rows


def avg(vals):
    vals = [v for v in vals if v is not None]
    return sum(vals) / len(vals) if vals else None


def fmt(v, d=3):
    return "-" if v is None else ("%." + str(d) + "f") % v


def pct(a, b):
    return "-" if a is None or b is None or a == 0 else "%+.1f%%" % (100 * (b - a) / a)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    # data[(build, run)][(signal, metric)] = 要約の行
    data = OrderedDict()
    for path in sorted(glob.glob(os.path.join(a.raw, "run*_*.tsv"))):
        m = re.match(r"run(\d+)_(total|seam)\.tsv$", os.path.basename(path))
        if m:
            data[(m.group(2), int(m.group(1)))] = {(r["signal"], r["metric"]): r for r in read_tsv(path)}
    runs = sorted(set(k[1] for k in data))
    signals = []
    for rows in data.values():
        for (sig, _) in rows:
            if sig not in signals:
                signals.append(sig)

    def get(build, run, sig, metric, field="median"):
        r = data.get((build, run), {}).get((sig, metric))
        return r[field] if r else None

    def across(build, sig, metric, field="median"):
        return avg([get(build, r, sig, metric, field) for r in runs])

    def mean_over_signals(build, metric, field="median"):
        return avg([across(build, s, metric, field) for s in signals])

    meta = open(a.meta, encoding="utf-8").read().rstrip("\n")

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, a.label + ".tsv"), "w", encoding="utf-8") as t:
        t.write("run\tbuild\tsignal\tmetric\tn\tmedian_ms\tp95_ms\tmean_ms\tmin_ms\tmax_ms\n")
        for (build, run), rows in data.items():
            for (sig, metric), r in rows.items():
                t.write("%d\t%s\t%s\t%s\t%d\t%.5f\t%.5f\t%.5f\t%.5f\t%.5f\n" % (
                    run, build, sig, metric, r["n"], r["median"], r["p95"], r["mean"], r["min"], r["max"]))

    out = []
    w = out.append
    w("# MiniMeters 1 コマの重さ: %s\n" % a.label)
    w("```")
    w(meta)
    w("```\n")
    w("単位は ms/コマ（1280x256 BGRA。30fps の予算は 33.3ms）。run は同じ測定を別プロセスで %d 回。"
      "数字は特記なければ中央値。\n" % len(runs))

    # 表 1: 全体
    w("## 1. 1 コマの全体（本番と同じ MiniMeters.swift をそのまま建てた版）\n")
    head = ["signal"] + ["draw med r%d" % r for r in runs] + ["Δ run"] \
        + ["draw p95 r%d" % r for r in runs] + ["pull med", "pull p95", "frame med (pull+draw)"]
    w("| " + " | ".join(head) + " |")
    w("|" + "|".join(["---"] + ["---:"] * (len(head) - 1)) + "|")
    for s in signals + [None]:
        sel = signals if s is None else [s]
        label = "**全信号の平均**" if s is None else s
        meds = [avg([get("total", r, x, "draw_total") for x in sel]) for r in runs]
        row = [label] + [fmt(v) for v in meds] + [pct(meds[0], meds[-1]) if len(runs) > 1 else "-"]
        row += [fmt(avg([get("total", r, x, "draw_total", "p95") for x in sel])) for r in runs]
        row += [fmt(avg([across("total", x, "pull") for x in sel])),
                fmt(avg([across("total", x, "pull", "p95") for x in sel])),
                fmt(avg([across("total", x, "frame") for x in sel]))]
        w("| " + " | ".join(row) + " |")
    w("")

    # 表 2: 区画
    w("## 2. 区画ごとの中央値（区画に分けて計る版。run の平均）\n")
    cols = [("sec_copy", "背景+スペクトログラムの写し"), ("sec_waveform", "波形"),
            ("sec_spectrum", "スペアナ(線込み)"), ("sec_stereo", "ステレオの点"), ("sec_levels", "レベル")]
    head = ["signal"] + [c[1] for c in cols] + ["区画の和", "同じ版の draw 全体", "和/全体"]
    w("| " + " | ".join(head) + " |")
    w("|" + "|".join(["---"] + ["---:"] * (len(head) - 1)) + "|")
    for s in signals + [None]:
        sel = signals if s is None else [s]
        label = "**全信号の平均**" if s is None else s
        vals = [avg([across("seam", x, c[0]) for x in sel]) for c in cols]
        s_sum = avg([across("seam", x, "sec_sum") for x in sel])
        s_tot = avg([across("seam", x, "draw_total") for x in sel])
        ratio = "-" if not s_sum or not s_tot else "%.3f" % (s_sum / s_tot)
        w("| " + " | ".join([label] + [fmt(v, 4) for v in vals] + [fmt(s_sum, 4), fmt(s_tot, 4), ratio]) + " |")
    w("")
    w("区画の和は、コマごとに区画の時間を足したものの中央値（区画の中央値の和ではない）。\n")

    # 表 3: 写しの内訳
    w("## 3. 背景+スペクトログラムの写し（copyBackdrop）の内訳（全信号の平均）\n")
    cb = mean_over_signals("seam", "sec_copy_backdrop")
    cs = mean_over_signals("seam", "sec_copy_spectrogram")
    ct = mean_over_signals("seam", "sec_copy")
    w("| 部分 | ms |")
    w("|---|---:|")
    w("| 背景 1280x256 の memcpy（同じ書き方を別に計った写し） | %s |" % fmt(cb, 4))
    w("| スペクトログラム 300x256 の memcpy（同上） | %s |" % fmt(cs, 4))
    w("| copyBackdrop 全体 | %s |" % fmt(ct, 4))
    w("| 差（器の検査: CFEqual・ctm など。0.001 未満なら誤差） | %s |" % fmt(None if None in (cb, cs, ct) else ct - cb - cs, 4))
    w("")

    # 表 4: pull
    w("## 4. pull(rate:now:)\n")
    w("| signal | pull med | pull p95 | pull mean | advanceSpectrogram 単独 med | 差（標本ごとの計算） |")
    w("|---|---:|---:|---:|---:|---:|")
    for s in signals + [None]:
        sel = signals if s is None else [s]
        label = "**全信号の平均**" if s is None else s
        pm = avg([across("total", x, "pull") for x in sel])
        p95 = avg([across("total", x, "pull", "p95") for x in sel])
        pmean = avg([across("total", x, "pull", "mean") for x in sel])
        adv = avg([across("seam", x, "pull_advance") for x in sel])
        w("| %s | %s | %s | %s | %s | %s |" % (label, fmt(pm, 4), fmt(p95, 4), fmt(pmean, 4), fmt(adv, 4),
                                                 fmt(None if pm is None or adv is None else pm - adv, 4)))
    w("")

    # 安定度
    w("## 5. 安定度と突き合わせ\n")
    if len(runs) > 1:
        pairs = []
        for s in signals:
            x, y = get("total", runs[0], s, "draw_total"), get("total", runs[-1], s, "draw_total")
            if x and y:
                pairs.append((abs(y - x) / x, s))
        if pairs:
            worst = max(pairs)
            w("- 全体の版の run %d と run %d の draw 中央値の差は、信号ごとに最大 %.1f%%（%s）。"
              % (runs[0], runs[-1], 100 * worst[0], worst[1]))
    diffs = []
    for s in signals:
        x, y = across("total", s, "draw_total"), across("seam", s, "draw_total")
        if x and y:
            diffs.append((abs(y - x) / x, s))
    if diffs:
        d = max(diffs)
        w("- 区画版の draw 全体と、全体の版の draw（建て方だけ違う）の中央値の差は、信号ごとに最大 %.1f%%（%s）。"
          % (100 * d[0], d[1]))
    ratios = []
    for s in signals:
        x, y = across("seam", s, "sec_sum"), across("seam", s, "draw_total")
        if x and y:
            ratios.append(x / y)
    if ratios:
        w("- 区画の和 / 区画版の draw 全体 は %.3f〜%.3f（1 に近いほど、区画に分けても全体を説明できている）。"
          % (min(ratios), max(ratios)))
    w("")

    w("## 6. 測り方\n")
    w(METHOD)
    with open(os.path.join(a.out, a.label + ".md"), "w", encoding="utf-8") as o:
        o.write("\n".join(out) + "\n")
    print("wrote %s/%s.md and .tsv" % (a.out, a.label))


if __name__ == "__main__":
    main()
