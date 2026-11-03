#!/usr/bin/env python3
"""check_xcresult_skips.py の試験。xcresulttool は叩かない（JSON を渡す）。

    python3 -m unittest discover -s .github/scripts -p 'test_*.py'

testdata/logic_xcode27_passed.json は Xcode 27.0（xcresulttool 25115）が Logic の実際の回
（iPad Pro 13-inch (M5)・iOS 27.0。309 本すべて Passed）について出した
`xcresulttool get test-results tests` を、3 つの Suite の 7 本に削ったもの。値は手を入れていない。
testdata/logic_xcode27_skipped.json はそこから 2 本を Skipped にしたもの。skip した節の形
（Skip Message の子・"Test skipped - " で始まる文面・キーの並び）は、同じ Xcode が別の
プロジェクトで XCTSkip した実物の節に合わせた。
取り直しの回（Repetition）の形だけは実物が無く、schema の nodeType から作っている。
"""
import contextlib
import copy
import io
import json
import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_xcresult_skips  # noqa: E402

DATA = os.path.join(HERE, "testdata")
ROOT = os.path.dirname(os.path.dirname(HERE))
DESTROY = "JSFXStabilityTests/testDestroyWaitsForARunningSaveState()"
BASS = "BassManagementTests/testIntegerArraysAreWrittenAsInt()"


def fixture(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


def cases_of(data):
    """(Suite の節, Test Case の節) を並べる。"""
    for plan in data["testNodes"]:
        for bundle in plan["children"]:
            for suite in bundle["children"]:
                for case in suite["children"]:
                    yield suite, case


def mark_skipped(data, ident, message="Test skipped - 例"):
    for _, case in cases_of(data):
        if case["nodeIdentifier"] == ident:
            case["result"] = "Skipped"
            case["children"] = [{"name": message, "nodeType": "Skip Message"}]
            return data
    raise KeyError(ident)


class CheckXcresultSkipsTests(unittest.TestCase):
    def write(self, text, suffix):
        with tempfile.NamedTemporaryFile("w", suffix=suffix, delete=False, encoding="utf-8") as f:
            f.write(text)
        self.addCleanup(os.unlink, f.name)
        return f.name

    def run_main(self, data, allow=None):
        """allow が None なら本物の allowed_skips.txt を読む。"""
        path = self.write(json.dumps(data, ensure_ascii=False), ".json")
        argv = ["--json", path]
        if allow is not None:
            argv += ["--allow", self.write(allow, ".txt")]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check_xcresult_skips.main(argv)
        return code, out.getvalue() + err.getvalue()

    def errors(self, out):
        return [l for l in out.splitlines() if l.startswith("::error")]

    def test_real_run_without_skips_passes(self):
        code, out = self.run_main(fixture("logic_xcode27_passed.json"))
        self.assertEqual(code, 0, out)
        self.assertIn("走った試験 7 本・飛ばした試験 0 本", out)
        self.assertEqual(self.errors(out), [])

    def test_allowed_skip_passes_and_is_shown(self):
        data = mark_skipped(fixture("logic_xcode27_passed.json"), DESTROY,
                            "Test skipped - SaveState が先に終わった（重ねられなかった）")
        code, out = self.run_main(data)
        self.assertEqual(code, 0, out)
        self.assertIn("走った試験 6 本・飛ばした試験 1 本（うち許可 1 本）", out)
        notice = [l for l in out.splitlines() if l.startswith("::notice")]
        self.assertEqual(len(notice), 1)
        self.assertIn(DESTROY, notice[0])
        self.assertIn("重ねられなかった", notice[0])

    def test_unexpected_skip_fails_and_names_the_test(self):
        code, out = self.run_main(fixture("logic_xcode27_skipped.json"))
        self.assertEqual(code, 1, out)
        errors = self.errors(out)
        self.assertTrue(any(BASS in l and "まだ書いていない" in l for l in errors), out)
        # 許可した方は error に出さない。
        self.assertFalse(any(DESTROY in l for l in errors), out)
        self.assertIn("予定外の skip が 1 本", out)

    def test_skip_is_not_allowed_by_the_suite_name_alone(self):
        code, out = self.run_main(fixture("logic_xcode27_skipped.json"),
                                  allow="BassManagementTests  # Suite ごと\n" + DESTROY + "  # 理由\n")
        self.assertEqual(code, 1, out)

    def test_allowlist_name_may_omit_the_parentheses(self):
        allow = DESTROY[:-2] + "  # 理由\n" + BASS + "  # 理由\n"
        code, out = self.run_main(fixture("logic_xcode27_skipped.json"), allow=allow)
        self.assertEqual(code, 0, out)

    def test_allowlist_line_without_reason_fails(self):
        code, out = self.run_main(fixture("logic_xcode27_passed.json"), allow=DESTROY + "\n")
        self.assertEqual(code, 1, out)
        self.assertIn("理由が無い", out)
        code, out = self.run_main(fixture("logic_xcode27_passed.json"), allow=DESTROY + "  #   \n")
        self.assertEqual(code, 1, out)

    def test_no_tests_at_all_fails(self):
        data = fixture("logic_xcode27_passed.json")
        data["testNodes"] = []
        code, out = self.run_main(data)
        self.assertEqual(code, 1, out)
        self.assertIn("1 本も走っていない", out)
        # bundle はあるが中身が空（建ったが試験を 1 本も拾えなかった）。
        data = fixture("logic_xcode27_passed.json")
        data["testNodes"][0]["children"][0]["children"] = []
        code, out = self.run_main(data)
        self.assertEqual(code, 1, out)
        self.assertIn("1 本も走っていない", out)

    def test_every_test_skipped_fails_even_if_all_allowed(self):
        data = fixture("logic_xcode27_passed.json")
        allow = ""
        for _, case in cases_of(data):
            mark_skipped(data, case["nodeIdentifier"])
            allow += case["nodeIdentifier"] + "  # 全部許す\n"
        code, out = self.run_main(data, allow=allow)
        self.assertEqual(code, 1, out)
        self.assertIn("1 本も走っていない（Test Case 7 本）", out)

    def test_whole_suite_skip_lists_every_case(self):
        # setUp で XCTSkip すると Suite の中が全部 Skipped になる（Suite 自身も Skipped）。
        # 数えるのは Test Case だけで、Suite の result は見ない。
        data = fixture("logic_xcode27_passed.json")
        for suite, case in cases_of(data):
            if suite["name"] == "WireCodecTests":
                suite["result"] = "Skipped"
                mark_skipped(data, case["nodeIdentifier"])
        code, out = self.run_main(data)
        self.assertEqual(code, 1, out)
        self.assertEqual(len([l for l in self.errors(out) if "WireCodecTests/" in l]), 2, out)
        self.assertIn("走った試験 5 本・飛ばした試験 2 本（うち許可 0 本）", out)

    def test_skip_in_a_retried_run_is_caught(self):
        # -retry-tests-on-failure: 1 回目に落ちて、取り直しで skip した。Test Case の result が
        # 何であっても、回の節に Skipped があれば拾う（形は schema の nodeType から作ったもの）。
        data = fixture("logic_xcode27_passed.json")
        for _, case in cases_of(data):
            if case["nodeIdentifier"] == BASS:
                case["result"] = "Failed"
                case["children"] = [
                    {"name": "First Run", "nodeType": "Repetition", "result": "Failed",
                     "children": [{"name": "XCTAssertEqual failed", "nodeType": "Failure Message"}]},
                    {"name": "Retry 1", "nodeType": "Repetition", "result": "Skipped",
                     "children": [{"name": "Test skipped - 取り直しで飛んだ", "nodeType": "Skip Message"}]},
                ]
        code, out = self.run_main(data)
        self.assertEqual(code, 1, out)
        self.assertTrue(any(BASS in l and "取り直しで飛んだ" in l for l in self.errors(out)), out)

    def test_retried_then_passed_is_not_a_skip(self):
        data = fixture("logic_xcode27_passed.json")
        for _, case in cases_of(data):
            if case["nodeIdentifier"] == BASS:
                case["children"] = [
                    {"name": "First Run", "nodeType": "Repetition", "result": "Failed"},
                    {"name": "Retry 1", "nodeType": "Repetition", "result": "Passed"},
                ]
        code, out = self.run_main(data)
        self.assertEqual(code, 0, out)
        self.assertIn("走った試験 7 本・飛ばした試験 0 本", out)

    def test_same_test_under_two_configurations_counts_once(self):
        # 構成・端末ごとに同じ木がもう 1 つ並んでも、1 本として数える。片方で skip すれば拾う。
        data = fixture("logic_xcode27_passed.json")
        second = copy.deepcopy(data["testNodes"][0])
        data["testNodes"].append(second)
        mark_skipped({"testNodes": [second]}, BASS)
        code, out = self.run_main(data)
        self.assertEqual(code, 1, out)
        self.assertIn("走った試験 7 本・飛ばした試験 1 本（うち許可 0 本）", out)

    def test_stale_allowlist_entry_only_warns(self):
        allow = DESTROY + "  # 理由\nGoneTests/testRemoved()  # 消した試験\n"
        code, out = self.run_main(fixture("logic_xcode27_passed.json"), allow=allow)
        self.assertEqual(code, 0, out)
        warn = [l for l in out.splitlines() if l.startswith("::warning")]
        self.assertEqual(len(warn), 1, out)
        self.assertIn("GoneTests/testRemoved()", warn[0])

    def test_output_without_test_nodes_fails(self):
        code, out = self.run_main({"devices": [], "testPlanConfigurations": []})
        self.assertEqual(code, 1, out)
        self.assertIn("testNodes が無い", out)

    def test_missing_result_bundle_fails(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = check_xcresult_skips.main(["--xcresult", os.path.join(DATA, "no-such.xcresult")])
        self.assertEqual(code, 1)
        self.assertIn("no-such.xcresult が無い", out.getvalue())

    def test_repo_allowlist_names_tests_that_xctskip(self):
        # 表の 1 行ずつ: 理由があり、その試験が Tests/ に在って、同じファイルに XCTSkip がある。
        allowed, bad = check_xcresult_skips.read_allowlist(check_xcresult_skips.DEFAULT_ALLOW)
        self.assertEqual(bad, [])
        self.assertTrue(allowed)
        sources = {}
        for d, _, files in os.walk(os.path.join(ROOT, "Tests")):
            for name in files:
                if name.endswith(".swift"):
                    with open(os.path.join(d, name), encoding="utf-8") as f:
                        sources[os.path.join(d, name)] = f.read()
        for written, _ in allowed.values():
            suite, _, test = check_xcresult_skips.norm(written).partition("/")
            hits = [p for p, text in sources.items()
                    if re.search(r"class %s\b" % re.escape(suite), text)
                    and re.search(r"func %s\(" % re.escape(test), text)]
            self.assertEqual(len(hits), 1, "%s: Tests/ に 1 つだけ在るはず（%s）" % (written, hits))
            self.assertIn("XCTSkip", sources[hits[0]], written)


if __name__ == "__main__":
    unittest.main()
