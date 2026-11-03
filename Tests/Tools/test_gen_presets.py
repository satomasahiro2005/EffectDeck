"""Tools/gen_presets.py の試験。同梱の鎖プリセットを黙って落とさないこと。"""
import json
import re

from tools_support import (ROOT, TempDir, env_patch, load_tool, quiet, run_main, swift_raw_text,
                           unittest, vendor_at_pin, write)

RAW = re.compile(r'      category: "([^"]*)",\n      name: "([^"]*)",\n      effectCount: (\d+),\n'
                 r'      json: (#+)"""\n      (.*)\n      """\4\),')


def embedded(swift_text):
    """SystemPresets.swift に埋めた (分類, 名前, 段数, JSON) を読み戻す。"""
    return [(m.group(1), m.group(2), int(m.group(3)), json.loads(swift_raw_text(m.group(4), m.group(5))))
            for m in RAW.finditer(swift_text)]


class GenPresetsTests(unittest.TestCase):
    def setUp(self):
        self.gp = load_tool("gen_presets")

    def run_gen(self, tmp, strict=None):
        self.gp.SRC = tmp / "presets"
        self.gp.OUT = tmp / "SystemPresets.swift"
        with env_patch(ET_STRICT=strict), quiet() as (out, err):
            code = run_main(self.gp.main)
        return code, out.getvalue(), err.getvalue()

    def preset(self, tmp, rel, data):
        write(tmp / "presets" / rel, json.dumps(data, ensure_ascii=False))

    def test_count_equals_files(self):
        with TempDir() as tmp:
            self.preset(tmp, "spatial/wide_room.effetune_preset", {"pipeline": [{"name": "A"}, {"name": "B"}]})
            self.preset(tmp, "utils/level.effetune_preset", {"pipeline": [{"name": "Level Meter"}]})
            self.preset(tmp, "odd/Mixed_case.effetune_preset", {"pipeline": []})
            code, out, err = self.run_gen(tmp)
            self.assertEqual(code, 0, err)
            items = embedded((tmp / "SystemPresets.swift").read_text("utf-8"))
        self.assertEqual(len(items), 3)
        self.assertEqual([(c, n, k) for c, n, k, _ in items],
                         [("odd", "Mixed Case", 0), ("Spatial", "Wide Room", 2), ("Utilities", "Level", 1)])

    def test_broken_fails_strict(self):
        with TempDir() as tmp:
            self.preset(tmp, "utils/good.effetune_preset", {"pipeline": []})
            write(tmp / "presets/utils/broken.effetune_preset", '{"pipeline": [')
            write(tmp / "presets/utils/shape.effetune_preset", '{"chain": []}')
            code, out, err = self.run_gen(tmp, strict="1")
            self.assertNotEqual(code, 0)
            self.assertIn("broken.effetune_preset", err)
            self.assertIn("shape.effetune_preset", err)
            self.assertFalse((tmp / "SystemPresets.swift").exists())
            # ET_STRICT が無ければ今までどおり書く（警告は出す）。
            code, out, err = self.run_gen(tmp)
            self.assertEqual(code, 0)
            self.assertIn("broken.effetune_preset", err)
            self.assertEqual(len(embedded((tmp / "SystemPresets.swift").read_text("utf-8"))), 1)

    def test_embedded_json_roundtrip(self):
        # 埋めた字を Swift の生文字列の読み方で JSON に読み戻すと元のファイルと同じ。
        data = {"pipeline": [{"name": "Section", "cm": "引用\"符 \\ と #"}, {"name": "Gain", "vl": -3.5}]}
        with TempDir() as tmp:
            self.preset(tmp, "utils/tricky.effetune_preset", data)
            code, out, err = self.run_gen(tmp)
            self.assertEqual(code, 0, err)
            text = (tmp / "SystemPresets.swift").read_text("utf-8")
            items = embedded(text)
        self.assertEqual(items[0][3], data)
        self.assertIn('json: #"""', text)    # 要らなければ # は 1 つのまま（今の生成物と同じ字）

    def test_backslash_hash_survives_swift_raw_string(self):
        # JSON の "C:\\#name" は中身に \# を持つ。#"""…"""# の中では \# がエスケープなので、
        # Swift は \#n を改行と読み JSON が壊れる（プリセットが黙って読めなくなる）。
        # 中身に出ない数まで # を増やす。
        data = {"pipeline": [{"name": "Section", "cm": "C:\\#name \\##x"}]}
        with TempDir() as tmp:
            self.preset(tmp, "utils/hash.effetune_preset", data)
            code, out, err = self.run_gen(tmp, strict="1")
            self.assertEqual(code, 0, err)
            text = (tmp / "SystemPresets.swift").read_text("utf-8")
            items = embedded(text)
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0][3], data)
        self.assertIn('json: ###"""', text)

    def test_title_uses_upstream_names_for_new_mastering_only(self):
        self.assertEqual(self.gp.title("rnb_soul", "mastering"), "R&B and Soul")
        self.assertEqual(self.gp.title("hip_hop", "mastering"), "Hip-Hop")
        # 既存のカテゴリは今の綴りのまま。
        self.assertEqual(self.gp.title("hip_hop", "others"), "Hip Hop")
        self.assertEqual(self.gp.title("fm_radio"), "Fm Radio")

    def test_raw_hashes(self):
        self.assertEqual(self.gp.raw_hashes('{"a":"x"}'), "#")
        self.assertEqual(self.gp.raw_hashes('{"a":"x\\\\#y"}'), "##")
        self.assertEqual(self.gp.raw_hashes('a"""#b'), "##")
        self.assertEqual(self.gp.raw_hashes('a\\##b"""#'), "###")

    # 作業ツリーの Vendor が固定した版のときだけ比べる（別の版だと追跡しているファイルのせいにして落ちる）。
    @unittest.skipUnless(vendor_at_pin("effetune", "presets"),
                         "Vendor/effetune が固定した版でない（無い・別の版・presets に手が入っている）")
    def test_committed_file_matches_vendor(self):
        # 追跡している SystemPresets.swift が Vendor の .effetune_preset と同じ中身を持つ。
        committed = embedded((ROOT / "Sources/EffeTuneLive/Generated/SystemPresets.swift").read_text("utf-8"))
        files = sorted((ROOT / "Vendor/effetune/presets").rglob("*.effetune_preset"))
        self.assertEqual(len(committed), len(files))
        by_name = {(c, n): d for c, n, _, d in committed}
        for f in files:
            key = (self.gp.LABEL.get(f.parent.name, f.parent.name), self.gp.title(f.stem, f.parent.name))
            self.assertEqual(by_name[key], json.loads(f.read_text("utf-8")), f.name)


if __name__ == "__main__":
    unittest.main()
