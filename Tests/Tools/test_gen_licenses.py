"""Tools/gen_licenses.py の試験。アプリに積んでいるコードのライセンスを全部出すこと。"""
import re

from tools_support import (ROOT, TempDir, load_tool, quiet, run_main, swift_raw_text, unittest,
                           vendor_at_pin, write)


class GenLicensesTests(unittest.TestCase):
    def setUp(self):
        self.gl = load_tool("gen_licenses")

    def test_lists_dpf_base64(self):
        # ysfx_utils.cpp が #include する DPF の Base64.hpp（ISC と zlib 形式の注意書き）。
        names = [item[0] for item in self.gl.ITEMS]
        self.assertIn("DPF Base64", names)
        entry = next(item for item in self.gl.ITEMS if item[0] == "DPF Base64")
        self.assertEqual(entry[3], "Licenses/dpf-base64.LICENSE")
        text = (ROOT / entry[3]).read_text("utf-8")
        self.assertIn("Filipe Coelho", text)
        self.assertIn("René Nyffenegger", text)
        self.assertIn("permission notice appear in all copies", text)

    def test_lists_fdlibm(self):
        # Rhythm Analyzer の rd6_math.h（2.13.0、2.12.0 では g2_math.h）にある atan / atan2 は fdlibm 5.3 の移植。
        entry = next(item for item in self.gl.ITEMS if item[0] == "fdlibm")
        self.assertEqual(entry[3], "Licenses/fdlibm.LICENSE")
        text = (ROOT / entry[3]).read_text("utf-8")
        self.assertIn("Sun Microsystems", text)
        self.assertIn("provided that this notice", text)

    @unittest.skipUnless(vendor_at_pin("effetune", "dsp/plugins/analyzer/rhythm_analyzer"),
                         "Vendor/effetune が固定した版でない")
    def test_fdlibm_copy_matches_vendor_header(self):
        self.assertEqual(self.gl.check_copies(), [])

    # Base64.hpp でなく木（Vendor/ysfx）が固定した版かで見る。上流が Base64.hpp を動かしたら、
    # 飛ばさずに落ちる。別の版の checkout と比べて写しのせいにしない。
    @unittest.skipUnless(vendor_at_pin("ysfx", "sources/base64"),
                         "Vendor/ysfx が固定した版でない（無い・別の版・sources/base64 に手が入っている）")
    def test_base64_copy_matches_vendor_header(self):
        self.assertEqual(self.gl.check_copies(), [])

    def test_copy_source_moved_is_reported(self):
        # 元の木（Vendor/ysfx）は在るのに元のファイルが無い＝上流が動かした。黙って確かめるのを
        # やめず、止める。木ごと無い（submodule を取っていない、空のフォルダ）ときだけ飛ばす。
        with TempDir() as tmp:
            write(tmp / "copy.LICENSE", "Copyright (C) 2020 Someone\n")
            self.gl.ROOT = tmp
            self.gl.COPIES = {"copy.LICENSE": "Vendor/lib/src/a.hpp"}
            self.assertEqual(self.gl.check_copies(), [])
            (tmp / "Vendor/lib").mkdir(parents=True)
            self.assertEqual(self.gl.check_copies(), [])
            write(tmp / "Vendor/lib/LICENSE", "x\n")
            bad = self.gl.check_copies()
            self.assertEqual(len(bad), 1, bad)
            self.assertIn("Vendor/lib/src/a.hpp", bad[0])
            self.gl.OUT = tmp / "Licenses.swift"
            self.gl.ITEMS = [("Copy", "MIT", "x", "copy.LICENSE")]
            with quiet():
                self.assertNotEqual(run_main(self.gl.main), 0)
            self.assertFalse((tmp / "Licenses.swift").exists())

    def test_copy_drift_detected(self):
        with TempDir() as tmp:
            write(tmp / "src.hpp", "/*\n * Copyright (C) 2020 Someone\n * Permission granted.\n */\ncode();\n")
            write(tmp / "copy.LICENSE", "Copyright (C) 2020 Someone\nPermission granted.\n")
            self.gl.ROOT = tmp
            self.gl.COPIES = {"copy.LICENSE": "src.hpp"}
            self.assertEqual(self.gl.check_copies(), [])
            write(tmp / "copy.LICENSE", "Copyright (C) 2021 Someone Else\nPermission granted.\n")
            self.assertEqual(len(self.gl.check_copies()), 1)

    def check(self, src, copy, source="src.hpp"):
        with TempDir() as tmp:
            write(tmp / "src.hpp", src)
            write(tmp / "copy.LICENSE", copy)
            self.gl.ROOT = tmp
            self.gl.COPIES = {"copy.LICENSE": source}
            return self.gl.check_copies()

    # 元の頭のコメント（Base64.hpp と同じ形: 注意書き、#pragma と #include、// の出典、2 つめの注意書き）。
    HEADER = ("/*\n * Copyright (C) 2020 Someone\n *\n * Permission granted.\n */\n\n#pragma once\n"
              "#include <x>\n\n// ------------\n// based on http://example.invalid/b64\n\n"
              "/*\n   Copyright (C) 2004 Other\n\n   1. First.\n\n   2. Second.\n*/\n\n"
              "// ------------\n// Helpers\n\n#ifndef X\nnamespace N {\n// after the code starts\n}\n")
    COPY = ("Copyright (C) 2020 Someone\n\nPermission granted.\n\nbased on http://example.invalid/b64\n\n"
            "Copyright (C) 2004 Other\n\n1. First.\n\n2. Second.\n")

    def test_copy_matches_whole_header(self):
        # 罫線（// ---）は写さなくてよい。見出し（// Helpers）は COPIES に挙げたものだけ飛ばす。
        # 最初のコードの行（namespace）より後ろのコメントは注意書きでない。
        self.assertEqual(self.check(self.HEADER, self.COPY, ("src.hpp", ["Helpers"])), [])
        bad = self.check(self.HEADER, self.COPY)
        self.assertEqual(len(bad), 1, bad)
        self.assertIn("Helpers", bad[0])

    def test_copyright_added_to_source_detected(self):
        # 上流が著作者を足した（ISC は注意書きを全部載せることを求める）。写しの段落が
        # 元に在るかだけ見ていると、写しが古いままでも通ってしまう。
        src = self.HEADER.replace(" * Copyright (C) 2020 Someone\n",
                                  " * Copyright (C) 2020 Someone\n * Copyright (C) 2025 Newcomer\n")
        bad = self.check(src, self.COPY, ("src.hpp", ["Helpers"]))
        self.assertEqual(len(bad), 1, bad)
        self.assertIn("Newcomer", bad[0])

    def test_clause_added_to_source_detected(self):
        src = self.HEADER.replace("   2. Second.\n", "   2. Second.\n\n   3. Third.\n")
        bad = self.check(src, self.COPY, ("src.hpp", ["Helpers"]))
        self.assertEqual(len(bad), 1, bad)
        self.assertIn("3. Third.", bad[0])

    def test_line_comment_added_to_source_detected(self):
        src = self.HEADER.replace("// based on", "// Copyright (C) 2025 Newcomer\n// based on")
        bad = self.check(src, self.COPY, ("src.hpp", ["Helpers"]))
        self.assertEqual(len(bad), 1, bad)
        self.assertIn("Newcomer", bad[0])

    def test_missing_file_fails(self):
        with TempDir() as tmp:
            self.gl.ROOT = tmp
            self.gl.OUT = tmp / "Licenses.swift"
            self.gl.COPIES = {}
            self.gl.ITEMS = [("Nothing", "MIT", "x", "NOPE")]
            with quiet():
                self.assertNotEqual(run_main(self.gl.main), 0)
            self.assertFalse((tmp / "Licenses.swift").exists())

    def test_backslash_hash_survives_swift_raw_string(self):
        # 本文に \# か """# があれば、#"""…"""# の中では Swift が別の字に読む（閉じる）。
        # 中身に出ない数まで # を増やし、本文は書いたとおりに読まれる。
        body = 'Copyright (C) 2020 Someone\n\nSee C:\\#docs and the """# marker.'
        with TempDir() as tmp:
            write(tmp / "odd.LICENSE", body + "\n")
            self.gl.ROOT = tmp
            self.gl.OUT = tmp / "Licenses.swift"
            self.gl.COPIES = {}
            self.gl.ITEMS = [("Odd", "MIT", "x", "odd.LICENSE")]
            with quiet():
                self.assertEqual(run_main(self.gl.main), 0)
            text = (tmp / "Licenses.swift").read_text("utf-8")
        m = re.search(r'      text: (#+)"""\n(.*?)\n      """\1\),', text, re.S)
        self.assertIsNotNone(m, text)
        self.assertEqual(m.group(1), "##")
        lines = [ln[6:] if ln else "" for ln in m.group(2).split("\n")]
        self.assertEqual(swift_raw_text(m.group(1), "\n".join(lines)), body)

    def test_committed_file_lists_every_item(self):
        text = (ROOT / "Sources/EffeTuneLive/Generated/Licenses.swift").read_text("utf-8")
        names = re.findall(r'^      name: "([^"]*)",$', text, re.M)
        self.assertEqual(names, [item[0] for item in self.gl.ITEMS])


if __name__ == "__main__":
    unittest.main()
