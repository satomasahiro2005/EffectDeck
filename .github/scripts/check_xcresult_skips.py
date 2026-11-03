#!/usr/bin/env python3
"""CI の macOS ジョブ（logic）で、xcresult から飛ばした（skip した）試験を拾って照合する。
「緑」が、予定の試験を走らせた緑であるように。

    python3 .github/scripts/check_xcresult_skips.py --xcresult build/Logic.xcresult
    python3 .github/scripts/check_xcresult_skips.py --json tests.json   (試験用。xcresulttool を叩かない)

- 飛ばした試験が許可の表（既定は隣の allowed_skips.txt）に無ければ落とす
- 走った試験が 1 本も無ければ落とす（全部 skip、または xcresult に試験が無い）
- 表にあって今回の結果に居ない名前は ::warning:: で知らせるだけ（名前を変えた・消した）

読むのは `xcrun xcresulttool get test-results tests`（Xcode 16 からの構造化した出力）。
出力はいつも JSON で、--format は付けない（Xcode 27.0 の xcresulttool は --format xml を渡しても
JSON を返す。知らない引数は黙って捨てる）。

試験 1 本は nodeType が "Test Case" の節。その result か、下に付く回の節（Repetition・
Test Case Run・Device・Arguments・Test Plan Configuration）の result のどれかが "Skipped" なら
飛ばしたとみなす。-retry-tests-on-failure で取り直した回がどの形で付くかは実物の xcresult で
確かめていない（schema の nodeType から。取り直しの回で skip しても拾うため）。
名前は nodeIdentifier（`Suite/testName()`）。末尾の () は表に書いても書かなくてもよい。

標準ライブラリだけ（runner の python3 に pip で何かを足さない）。
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ALLOW = os.path.join(HERE, "allowed_skips.txt")

# 1 回走らせた結果を持つ節。Test Case の下にぶら下がる。
RUN_TYPES = ("Repetition", "Test Case Run", "Device", "Arguments", "Test Plan Configuration")
RAN = ("Passed", "Failed", "Expected Failure")


def norm(ident):
    """`Suite/test()` と `Suite/test` を同じものとして扱う。"""
    ident = ident.strip()
    return ident[:-2] if ident.endswith("()") else ident


def read_allowlist(path):
    """`Suite/testName()  # 理由`。理由の無い行は受けない。返すのは ({正規化した名前: (書いた名前, 理由)}, [誤り])。"""
    allowed, bad = {}, []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f.read().splitlines(), 1):
            body, _, why = line.partition("#")
            body = body.strip()
            if not body:
                continue
            if not why.strip():
                bad.append("%s:%d: 理由が無い（`%s  # 理由`）" % (path, n, body))
                continue
            allowed[norm(body)] = (body, why.strip())
    return allowed, bad


def test_cases(data):
    """Test Case の節を (名前, [結果...], [skip の文面...]) で並べる。同じ名前が何度出ても 1 つにまとめる。"""
    cases = {}

    def outcomes(node, results, messages):
        for c in node.get("children", []) or []:
            kind = c.get("nodeType")
            if kind in RUN_TYPES and c.get("result"):
                results.append(c["result"])
            if kind == "Skip Message" and c.get("name"):
                messages.append(c["name"])
            if kind in RUN_TYPES:
                outcomes(c, results, messages)

    def walk(node, suite):
        kind = node.get("nodeType")
        if kind == "Test Case":
            ident = node.get("nodeIdentifier") or "%s/%s" % (suite or "?", node.get("name", "?"))
            entry = cases.setdefault(norm(ident), (ident, [], []))
            if node.get("result"):
                entry[1].append(node["result"])
            outcomes(node, entry[1], entry[2])
            return
        if kind == "Test Suite":
            suite = node.get("name", suite)
        for c in node.get("children", []) or []:
            walk(c, suite)

    for top in data["testNodes"]:
        walk(top, None)
    return cases


def load_from_xcresult(path):
    if not os.path.isdir(path):
        print("::error::%s が無い（試験の段が xcresult を書く前に止まった）" % path)
        return None
    proc = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        print("::error::xcresulttool が %s を読めない（終了 %d）" % (path, proc.returncode))
        print(proc.stderr, file=sys.stderr)
        return None
    return json.loads(proc.stdout)


def main(argv=None):
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--xcresult", help="xcodebuild -resultBundlePath で書いた束")
    src.add_argument("--json", help="xcresulttool get test-results tests の出力を読む（試験用）")
    ap.add_argument("--allow", default=DEFAULT_ALLOW, help="許可の表（既定: %(default)s）")
    args = ap.parse_args(argv)

    allowed, bad = read_allowlist(args.allow)
    if bad:
        for b in bad:
            print("::error::%s" % b)
        return 1

    if args.json:
        with open(args.json, encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = load_from_xcresult(args.xcresult)
        if data is None:
            return 1
    if not isinstance(data, dict) or not isinstance(data.get("testNodes"), list):
        print("::error::xcresulttool の出力に testNodes が無い（形が変わった？）")
        return 1

    cases = test_cases(data)
    ran = [c for c in cases.values() if any(r in RAN for r in c[1])]
    skipped = sorted((c for c in cases.values() if "Skipped" in c[1]), key=lambda c: c[0])
    unexpected = [c for c in skipped if norm(c[0]) not in allowed]

    for ident, _, messages in skipped:
        said = " / ".join(messages) or "（skip の文面なし）"
        if norm(ident) in allowed:
            print("::notice title=許可した skip::%s — %s（許可の理由: %s）"
                  % (ident, said, allowed[norm(ident)][1]))
        else:
            print("::error title=予定外の skip::%s — %s" % (ident, said))
    for key, (written, _) in sorted(allowed.items()):
        if key not in cases:
            print("::warning::許可の表の %s が今回の結果に居ない（名前を変えたか消した。%s から外せる）"
                  % (written, os.path.basename(args.allow)))

    print("走った試験 %d 本・飛ばした試験 %d 本（うち許可 %d 本）"
          % (len(ran), len(skipped), len(skipped) - len(unexpected)))
    failed = False
    if not ran:
        print("::error::試験が 1 本も走っていない（Test Case %d 本）" % len(cases))
        failed = True
    if unexpected:
        try:
            where = os.path.relpath(args.allow)
        except ValueError:  # Windows でドライブが違う
            where = args.allow
        print("::error::予定外の skip が %d 本。飛ばさないように直すか、%s に理由つきで足す"
              % (len(unexpected), where))
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
