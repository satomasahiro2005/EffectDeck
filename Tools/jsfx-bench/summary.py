#!/usr/bin/env python3
"""ETJSFXBench の JSON をまとめて 1 枚の表にする（Tools/jsfx-bench/run.sh が最後に呼ぶ）。stdlib だけ。

  python3 Tools/jsfx-bench/summary.py build/jsfx-bench/*.json docs/bench/*.json

同じ機種・同じ構成（buildConfig）の JSON を 1 組にする（同じ組の同じ実行系が 2 つあれば後のもの）。
portable の回と wdl-jit の回は別のプロセス（EEL を建て分けるので 1 本に入らない）なので、
port/cpp と jit/cpp はそれぞれの回の中の cpp と比べる。port/jit は回をまたいだ比（温度の差が乗りうる）。
out== は portable と wdl-jit の出力の指紋が同じか。
"""
import json
import sys


def load(paths):
    groups = {}
    for p in paths:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        key = (d["device"]["model"], d["device"].get("osVersion", ""), d.get("buildConfig", ""))
        eel = d.get("eel", "portable")
        if eel in groups.get(key, {}):
            print("note: %s replaces an earlier %s run of %s %s" % (p, eel, key[0], key[2]))
        groups.setdefault(key, {})[eel] = d
    return groups


def variant(run, script, name):
    if not run:
        return None
    for s in run["scripts"]:
        if s["name"] == script:
            for v in s["variants"]:
                if v["name"] == name and v.get("created"):
                    return v
    return None


def us(v, key="medianNs"):
    return "%.1f" % (v[key] / 1000) if v else "-"


def main(paths):
    if not paths:
        print(__doc__)
        return 2
    for (model, osv, config), runs in sorted(load(paths).items()):
        port, jit = runs.get("portable"), runs.get("wdl-jit")
        base = port or jit
        budget = base["budgetNs"]
        print("\n== %s %s  %s  (eel runs: %s)" % (model, osv, config, ", ".join(sorted(runs))))
        print("%-13s %9s %9s %7s %9s %8s %9s %9s %7s %8s %8s %5s %s" % (
            "script", "port_med", "port_p99", "%bud", "cpp_med", "port/cpp", "jit_med", "jit_p99", "%bud",
            "jit/cpp", "port/jit", "out==", "checks"))
        names = [s["name"] for s in base["scripts"]]
        for name in names:
            p, pc = variant(port, name, "portable"), variant(port, name, "cpp")
            j, jc = variant(jit, name, "wdl-jit"), variant(jit, name, "cpp")
            cpp = pc or jc
            checks = []
            for run_v in (pc, jc):
                if run_v:
                    c = run_v["check"]
                    checks.append("cpp %s %s" % ("bit-exact" if c["mismatchedSamples"] == 0 else "maxdiff %.2g" % c["maxAbsDiff"],
                                                 "ok" if c["pass"] else "FAIL"))
            same = "-"
            if p and j:
                same = "yes" if p["outputHash"] == j["outputHash"] else "no"
            print("%-13s %9s %9s %6s%% %9s %8s %9s %9s %6s%% %8s %8s %5s %s" % (
                name, us(p), us(p, "p99Ns"), "%.2f" % (p["medianNs"] / budget * 100) if p else "-",
                us(cpp), "%.1fx" % (p["medianNs"] / pc["medianNs"]) if p and pc else "-",
                us(j), us(j, "p99Ns"), "%.2f" % (j["medianNs"] / budget * 100) if j else "-",
                "%.1fx" % (j["medianNs"] / jc["medianNs"]) if j and jc else "-",
                "%.2fx" % (p["medianNs"] / j["medianNs"]) if p and j else "-",
                same, "; ".join(checks)))
        # portable の回に入っている EEL の実行系（vm-*）。同じ回の portable・cpp と比べる。
        if port:
            vms = []
            for s in port["scripts"]:
                for v in s["variants"]:
                    if v.get("created") and v["name"] not in ("portable", "cpp") and v["name"] not in vms:
                        vms.append(v["name"])
            if vms:
                print("%-13s" % "med_us" + "".join(" %11s" % n[:11] for n in ["portable"] + vms + ["cpp"]) +
                      "   vs portable / x cpp / check")
                for name in names:
                    p, pc = variant(port, name, "portable"), variant(port, name, "cpp")
                    row = [variant(port, name, n) for n in vms]
                    notes = []
                    for n, v in zip(vms, row):
                        if not v:
                            continue
                        c = v["check"]
                        notes.append("%s %s/%s/%s" % (
                            n, "%.2fx" % (p["medianNs"] / v["medianNs"]) if p else "-",
                            "%.1fx" % (v["medianNs"] / pc["medianNs"]) if pc else "-",
                            ("bit-exact" if c["mismatchedSamples"] == 0 else "DIFF") + ("" if c["pass"] else " FAIL")))
                    print("%-13s" % name + "".join(" %11s" % us(v) for v in [p] + row + [pc]) + "   " + "; ".join(notes))
        pol = base["policy"]["obtained"]
        print("   policy %s; wall %s s; passed %s" % (
            pol, ", ".join("%s %.1f" % (k, r["wallSeconds"]) for k, r in sorted(runs.items())),
            all(r["passed"] for r in runs.values())))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
