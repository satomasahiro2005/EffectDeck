"""Tools/gen_effect_presets.py の試験。ET_STRICT=1 では飛ばさずに止まること。"""
import json
import re
import shutil
import subprocess
from unittest import mock

from tools_support import (ROOT, TempDir, env_patch, have_node, load_tool, quiet, run_main,
                           swift_raw_text, unittest, vendor_at_pin, write)

PLUGINS_TXT = """\
[core]
ignored: x | y | z
[plugins]
# comment
dynamics/sag: Power Amp Sag | Dynamics | PowerAmpSagPlugin | css
dynamics/broken: Broken | Dynamics | BrokenPlugin
"""

SAG_JS = """
const SAG_PRESETS = Object.freeze([{ id: 'soft', label: 'Soft', params: { sg: 1 } }]);
class PowerAmpSagPlugin extends PluginBase {
    static getSystemPresetGroups() { return [{ label: '', presets: SAG_PRESETS }]; }
}
"""

BROKEN_JS = """
class BrokenPlugin extends PluginBase {
    static getSystemPresetGroups() { throw new Error('boom'); }
}
"""


def fake_run(stdout, stderr=b"", returncode=0):
    def run(*args, **kwargs):
        if returncode:
            raise subprocess.CalledProcessError(returncode, args[0], stdout, stderr)
        return subprocess.CompletedProcess(args[0], 0, stdout, stderr)
    return run


class GenEffectPresetsTests(unittest.TestCase):
    def setUp(self):
        self.ge = load_tool("gen_effect_presets")

    def vendor(self, tmp, broken=False):
        write(tmp / "vendor/plugins/plugins.txt", PLUGINS_TXT)
        write(tmp / "vendor/plugins/dynamics/sag.js", SAG_JS)
        if broken:
            write(tmp / "vendor/plugins/dynamics/broken.js", BROKEN_JS)
        self.ge.OUT = tmp / "EffectPresets.swift"
        return tmp / "vendor"

    def run_gen(self, vendor, strict=None):
        with env_patch(ET_STRICT=strict), quiet() as (out, err):
            code = run_main(self.ge.main, [str(vendor)])
        return code, out.getvalue(), err.getvalue()

    def test_swift_quoted_rejects_quote_and_backslash(self):
        self.assertEqual(self.ge.swift_quoted("Pre+Power"), '"Pre+Power"')
        with self.assertRaises(ValueError):
            self.ge.swift_quoted('a"b')
        with self.assertRaises(ValueError):
            self.ge.swift_quoted("a\\b")

    def test_footer_keeps_keypath_backslash(self):
        self.assertIn("by: \\.effect)", self.ge.FOOTER)

    def test_missing_vendor_fails_strict(self):
        with TempDir() as tmp:
            self.ge.OUT = tmp / "EffectPresets.swift"
            self.assertEqual(self.run_gen(tmp / "nowhere")[0], 0)
            self.assertNotEqual(self.run_gen(tmp / "nowhere", strict="1")[0], 0)

    def test_missing_node_fails_strict(self):
        with TempDir() as tmp:
            vendor = self.vendor(tmp)
            with mock.patch.object(self.ge.shutil, "which", return_value=None):
                self.assertEqual(self.run_gen(vendor)[0], 0)
                code, out, err = self.run_gen(vendor, strict="1")
            self.assertNotEqual(code, 0)
            self.assertIn("node", err)
            self.assertFalse(self.ge.OUT.exists())

    def test_unparsable_output_fails_strict(self):
        # 切れた JSON（Mac のパイプで 65536 バイトで切れた事故）。既定では既存を残して 0、strict では止める。
        with TempDir() as tmp:
            vendor = self.vendor(tmp)
            with mock.patch.object(self.ge.shutil, "which", return_value="node"), \
                    mock.patch.object(self.ge.subprocess, "run", fake_run(b'[{"name": "x", "gro')):
                self.assertEqual(self.run_gen(vendor)[0], 0)
                code, out, err = self.run_gen(vendor, strict="1")
            self.assertNotEqual(code, 0)
            self.assertFalse(self.ge.OUT.exists())

    def test_dumper_warning_fails_strict(self):
        # dump が評価できなかったプラグイン（!! 行）を飛ばして続けても、strict では止める。
        good = json.dumps([{"name": "Power Amp Sag", "groups": [
            {"label": "", "presets": [{"id": "soft", "label": "Soft", "params": {"sg": 1}}]}]}]).encode()
        with TempDir() as tmp:
            vendor = self.vendor(tmp)
            run = fake_run(good, b"!! dynamics/broken \xe3\x82\x92\xe8\xa9\x95\xe4\xbe\xa1\xe3\x81\xa7\xe3\x81\x8d\xe3\x81\xaa\xe3\x81\x84: boom\n")
            with mock.patch.object(self.ge.shutil, "which", return_value="node"), \
                    mock.patch.object(self.ge.subprocess, "run", run):
                code, out, err = self.run_gen(vendor, strict="1")
                self.assertNotEqual(code, 0)
                self.assertFalse(self.ge.OUT.exists())
                code, out, err = self.run_gen(vendor)
            self.assertEqual(code, 0)
            self.assertIn("!! dynamics/broken", err)
            text = self.ge.OUT.read_text("utf-8")
        self.assertIn('presetId: "soft"', text)
        self.assertIn('      {"sg":1}', text)

    def test_dropped_plugins_on_last_line(self):
        # setup.sh は 2>&1 | tail -1 で最後の 1 行しか見せない。!! の行は stderr で先に流れて消えるので、
        # 落とした数を最後の行に書く（gen_presets・gen_catalog と同じ）。
        good = json.dumps([{"name": "Power Amp Sag", "groups": [
            {"label": "", "presets": [{"id": "soft", "label": "Soft", "params": {"sg": 1}}]}]}]).encode()
        with TempDir() as tmp:
            vendor = self.vendor(tmp)
            run = fake_run(good, "!! dynamics/broken を評価できない: boom\n".encode("utf-8"))
            with mock.patch.object(self.ge.shutil, "which", return_value="node"), \
                    mock.patch.object(self.ge.subprocess, "run", run):
                code, out, err = self.run_gen(vendor)
        self.assertEqual(code, 0, err)
        last = out.strip().splitlines()[-1]
        self.assertIn("effect presets: 1 件 / 1 エフェクト", last)
        self.assertIn("1 プラグインを落とした", last)

    def test_effect_lost_since_last_output_fails_strict(self):
        # dump が !! を出さずに落とす形（上流が getSystemPresetGroups を改名した、グループが
        # 空になった）。前の生成物に在ったエフェクトが丸ごと消えたら、strict では何も書かずに
        # 止め、いつもは書いて !! と最後の行で報せる。
        both = json.dumps([
            {"name": "Power Amp Sag", "groups": [
                {"label": "", "presets": [{"id": "soft", "label": "Soft", "params": {"sg": 1}}]}]},
            {"name": "Tube Simulator", "groups": [
                {"label": "Pre", "presets": [{"id": "warm", "label": "Warm", "params": {"dr": -12}}]}]},
        ]).encode()
        one = json.dumps([{"name": "Power Amp Sag", "groups": [
            {"label": "", "presets": [{"id": "soft", "label": "Soft", "params": {"sg": 1}}]}]}]).encode()
        with TempDir() as tmp:
            vendor = self.vendor(tmp)
            with mock.patch.object(self.ge.shutil, "which", return_value="node"):
                with mock.patch.object(self.ge.subprocess, "run", fake_run(both)):
                    self.assertEqual(self.run_gen(vendor, strict="1")[0], 0)
                before = self.ge.OUT.read_bytes()
                with mock.patch.object(self.ge.subprocess, "run", fake_run(one)):
                    code, out, err = self.run_gen(vendor, strict="1")
                    self.assertNotEqual(code, 0)
                    self.assertIn("Tube Simulator", err)
                    self.assertEqual(self.ge.OUT.read_bytes(), before)
                    code, out, err = self.run_gen(vendor)
                self.assertEqual(code, 0, err)
                self.assertIn("!! Tube Simulator", err)
                self.assertIn("1 エフェクトが消えた", out.strip().splitlines()[-1])
                self.assertNotIn('effect: "Tube Simulator"', self.ge.OUT.read_text("utf-8"))
                # 書いた後は、それが前の生成物。同じ dump なら黙って通る。
                with mock.patch.object(self.ge.subprocess, "run", fake_run(one)):
                    code, out, err = self.run_gen(vendor, strict="1")
                self.assertEqual(code, 0, err)
                self.assertNotIn("!!", err)

    def test_backslash_hash_survives_swift_raw_string(self):
        # params の "C:\\#x" は中身に \# を持つ。#"""…"""# の中では \# がエスケープで、
        # Swift は \#x を読めずに止まるか別の字にする。中身に出ない数まで # を増やす。
        params = {"path": "C:\\#x", "plain": 1}
        dumped = json.dumps([{"name": "Power Amp Sag", "groups": [
            {"label": "", "presets": [{"id": "odd", "label": "Odd", "params": params}]}]}]).encode()
        with TempDir() as tmp:
            vendor = self.vendor(tmp)
            with mock.patch.object(self.ge.shutil, "which", return_value="node"), \
                    mock.patch.object(self.ge.subprocess, "run", fake_run(dumped)):
                code, out, err = self.run_gen(vendor, strict="1")
            self.assertEqual(code, 0, err)
            text = self.ge.OUT.read_text("utf-8")
        m = re.search(r'      json: (#+)"""\n      (.*)\n      """\1\),', text)
        self.assertIsNotNone(m, text)
        self.assertEqual(m.group(1), "##")
        self.assertEqual(json.loads(swift_raw_text(m.group(1), m.group(2))), params)

    def test_raw_hashes(self):
        self.assertEqual(self.ge.raw_hashes('{"sg":1}'), "#")
        self.assertEqual(self.ge.raw_hashes('{"p":"C:\\\\#x"}'), "##")
        self.assertEqual(self.ge.raw_hashes('a\\##b"""#'), "###")

    @unittest.skipUnless(have_node(), "node が無い")
    def test_end_to_end_with_node(self):
        with TempDir() as tmp:
            vendor = self.vendor(tmp, broken=True)
            code, out, err = self.run_gen(vendor)
            self.assertEqual(code, 0, err)
            self.assertIn("!! dynamics/broken", err)
            text = self.ge.OUT.read_text("utf-8")
            self.assertIn('effect: "Power Amp Sag"', text)
            self.assertIn("effect presets: 1 件 / 1 エフェクト", out)
            code, out, err = self.run_gen(vendor, strict="1")
            self.assertNotEqual(code, 0)

    # 作業ツリーの Vendor が固定した版のときだけ比べる（別の版だと追跡しているファイルのせいにして落ちる）。
    @unittest.skipUnless(have_node() and vendor_at_pin("effetune", "plugins"),
                         "node が無いか、Vendor/effetune が固定した版でない（無い・別の版・plugins に手が入っている）")
    def test_committed_file_matches_vendor(self):
        # 追跡している EffectPresets.swift を Vendor から作り直すと同じになる。
        with TempDir() as tmp:
            self.ge.OUT = tmp / "EffectPresets.swift"
            code, out, err = self.run_gen(ROOT / "Vendor/effetune", strict="1")
            self.assertEqual(code, 0, err)
            fresh = self.ge.OUT.read_text("utf-8")
        committed = (ROOT / "Sources/EffeTuneLive/Generated/EffectPresets.swift").read_bytes()
        self.assertEqual(fresh, committed.decode("utf-8").replace("\r\n", "\n"))


if __name__ == "__main__":
    unittest.main()
