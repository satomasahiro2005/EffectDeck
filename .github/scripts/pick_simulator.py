#!/usr/bin/env python3
"""CI の macOS ジョブで、テストを走らせるシミュレータを 1 台選んで UDID を出す。

    python3 .github/scripts/pick_simulator.py --name "iPad Pro 13-inch (M5)" --os 27.0
    python3 .github/scripts/pick_simulator.py --json simctl.json ...   (試験用。simctl を叩かない)

- 名前と iOS の版が両方合う端末があればそれ
- 無ければ同じ版の iPad Pro、iPad、iPhone の順で最初のもの
  （runner の image は週ごとに入れ替わり、名前が消えることがある。版さえ合えば単体テストは同じ）
- **版が合う端末が 1 台も無ければ止める。**配備先が iOS 27.0 なので、ほかの版では建っても走らない

標準ライブラリだけ（runner の python3 に pip で何かを足さない）。
選んだ端末は標準エラーへ、UDID だけを標準出力へ出す。
"""
import argparse
import json
import subprocess
import sys


def ios_devices(data):
    """simctl list devices available -j の中身から (版, 名前, UDID) を並べる。"""
    out = []
    for runtime, devices in data.get("devices", {}).items():
        # com.apple.CoreSimulator.SimRuntime.iOS-27-0
        marker = ".SimRuntime.iOS-"
        if marker not in runtime:
            continue
        version = runtime.split(marker, 1)[1].replace("-", ".")
        for d in devices:
            if d.get("isAvailable", True):
                out.append((version, d["name"], d["udid"]))
    return out


def same_version(actual, wanted):
    """27.0 は 27.0 と 27.0.1 に合う（点の後の版だけ違う runtime は同じ SDK で走る）。27.1 には合わない。"""
    return actual == wanted or actual.startswith(wanted + ".")


def pick(devices, name, os_version):
    same_os = [d for d in devices if same_version(d[0], os_version)]
    for d in same_os:
        if d[1] == name:
            return d
    for prefix in ("iPad Pro", "iPad", "iPhone"):
        for d in sorted(same_os, key=lambda d: d[1]):
            if d[1].startswith(prefix):
                return d
    return None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--os", dest="os_version", required=True)
    ap.add_argument("--json", help="simctl の JSON を読む（試験用）")
    args = ap.parse_args(argv)

    if args.json:
        with open(args.json, encoding="utf-8") as f:
            data = json.load(f)
    else:
        raw = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                             check=True, capture_output=True, text=True).stdout
        data = json.loads(raw)

    devices = ios_devices(data)
    chosen = pick(devices, args.name, args.os_version)
    if chosen is None:
        print("!! iOS %s のシミュレータが無い。居るもの:" % args.os_version, file=sys.stderr)
        for d in sorted(devices):
            print("   iOS %s  %s  %s" % d, file=sys.stderr)
        return 1
    if chosen[1] != args.name:
        print("!! %s (iOS %s) が無いので代わりを使う" % (args.name, args.os_version),
              file=sys.stderr)
    print("simulator: %s (iOS %s) %s" % (chosen[1], chosen[0], chosen[2]), file=sys.stderr)
    print(chosen[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
