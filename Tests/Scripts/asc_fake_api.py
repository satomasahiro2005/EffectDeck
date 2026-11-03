"""Tools/asc.py を App Store Connect に繋がずに走らせる（Tests/Scripts/sim_test.sh の偽の python3 が呼ぶ）。

  python3 asc_fake_api.py <Tools/asc.py の置き場> <asc.py の引数...>

本物の asc.py を読み込み、call() だけを $STUB_DIR/asc_api.json の決めた返事に差し替えて
main() を走らせる。だから台本が読む出力の形は本物の asc.py のもの（asc.py の print を
変えると、それを読む ship.sh・notarize.sh・adp_fetch.sh の試験が落ちる）。

asc_api.json は {"GET /v1/builds": [返事1, 返事2, ...], ...}。鍵は「メソッド 空白 パスの ? より前」。
同じ鍵が何度も呼ばれると順に返し、尽きたら最後のものを返し続ける（数は $STUB_DIR/asc_count.json）。
呼び出しは calls.log に "asc <メソッド> <パス> <本体の JSON>" で残す。
"""
import importlib.util
import json
import os
import sys

STUB = os.environ["STUB_DIR"]
with open(os.path.join(STUB, "asc_api.json"), encoding="utf-8") as f:
    API = json.load(f)
COUNT = os.path.join(STUB, "asc_count.json")


def call(method, path, body=None):
    key = f"{method} {path.split('?', 1)[0]}"
    with open(os.path.join(STUB, "calls.log"), "a", encoding="utf-8") as f:
        f.write(f"asc {key} {json.dumps(body, sort_keys=True) if body is not None else ''}\n")
    if key not in API:
        print(f"!! asc_fake_api: 返事を決めていない: {key}", file=sys.stderr)
        raise SystemExit(1)
    try:
        with open(COUNT, encoding="utf-8") as f:
            counts = json.load(f)
    except FileNotFoundError:
        counts = {}
    n = counts.get(key, 0)
    counts[key] = n + 1
    with open(COUNT, "w", encoding="utf-8") as f:
        json.dump(counts, f)
    replies = API[key]
    return replies[min(n, len(replies) - 1)]


def main():
    spec = importlib.util.spec_from_file_location("asc", sys.argv[1])
    asc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(asc)
    asc.call = call
    sys.argv = sys.argv[1:]
    return asc.main()


if __name__ == "__main__":
    raise SystemExit(main())
