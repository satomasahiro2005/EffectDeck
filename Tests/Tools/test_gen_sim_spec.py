"""Tools/gen_sim_spec.py の試験。project.yml から拡張だけを落とし、ほかは触らない。"""
import re

from tools_support import ROOT, load_tool, unittest

EXT = "EffeTuneLiveExtension"

SPEC = """\
name: EffeTuneLive
options:
  bundleIdPrefix: ai.nemut
targets:
  # ---- 本体 ----
  EffeTuneLive:
    type: application
    dependencies:
      - sdk: CoreText.framework
      # 拡張をここに同梱する。
      - target: EffeTuneLiveExtension
        embed: true
        codeSign: true
      # 共有シートの受け口。
      - target: EffectDeckShare
        embed: true

  # ---- 入れ物（拡張） ----
  # 二行目の説明。
  EffeTuneLiveExtension:
    type: extensionkit-extension
    sources:
      # 中のコメント
      - path: Sources/Extension

  # ---- 共有シート ----
  # 共有シートの説明。
  EffectDeckShare:
    type: app-extension

  Tests:
    type: bundle.unit-test
    dependencies:
      - {target: EffeTuneLiveExtension, embed: false}
      - {target: EffeTuneLive}
schemes:
  EffeTuneLive:
    build:
      targets:
        EffeTuneLive: all
        EffeTuneLiveExtension: all
"""


def top_keys(text, section):
    """section: の直下（2字下げ）の鍵を並びのまま返す。PyYAML に頼らない。"""
    keys, inside = [], False
    for line in text.splitlines():
        if re.match(r"^\S", line):
            inside = line.startswith(section + ":")
            continue
        m = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
        if inside and m:
            keys.append(m.group(1))
    return keys


def block(text, name, indent=2):
    """targets の name: の中身（次の同じ段の鍵まで）。末尾の空行と、次の鍵の見出しコメントは含めない。"""
    lines = text.splitlines()
    start = next(i for i, l in enumerate(lines) if l == " " * indent + name + ":")
    out = []
    for l in lines[start + 1:]:
        if l.strip() and not l.lstrip().startswith("#") and len(l) - len(l.lstrip()) <= indent:
            break
        out.append(l)
    while out and (not out[-1].strip()
                   or (out[-1].lstrip().startswith("#") and len(out[-1]) - len(out[-1].lstrip()) <= indent)):
        out.pop()
    return "\n".join(out)


class SimSpecTests(unittest.TestCase):
    def setUp(self):
        self.gs = load_tool("gen_sim_spec")

    def test_inline_target_form(self):
        out = self.gs.make_sim_spec(SPEC)
        self.assertNotIn(EXT, out)
        self.assertIn("      - {target: EffeTuneLive}", out)
        self.assertIn("name: EffeTuneLiveSim\n", out)

    def test_next_target_keeps_its_header_comment(self):
        out = self.gs.make_sim_spec(SPEC)
        # 共有シートの見出しは残り、拡張の見出しと中のコメントは消える。
        self.assertIn("  # ---- 共有シート ----\n  # 共有シートの説明。\n  EffectDeckShare:", out)
        self.assertNotIn("入れ物", out)
        self.assertNotIn("二行目の説明", out)
        self.assertNotIn("中のコメント", out)
        self.assertNotIn("拡張をここに同梱する", out)
        self.assertIn("      # 共有シートの受け口。\n      - target: EffectDeckShare", out)
        self.assertNotIn("\n\n\n", out)

    def test_targets_minus_extension_fixture(self):
        out = self.gs.make_sim_spec(SPEC)
        self.assertEqual(top_keys(out, "targets"), ["EffeTuneLive", "EffectDeckShare", "Tests"])
        self.assertIn("        EffeTuneLive: all\n", out)

    def test_nothing_to_drop_is_an_error(self):
        with self.assertRaises(ValueError):
            self.gs.make_sim_spec("name: X\ntargets:\n  App:\n    type: application\n")

    def test_targets_minus_extension(self):
        src = (ROOT / "project.yml").read_text("utf-8")
        out = self.gs.make_sim_spec(src)
        before = top_keys(src, "targets")
        self.assertIn(EXT, before)
        self.assertEqual(top_keys(out, "targets"), [t for t in before if t != EXT])
        self.assertEqual(top_keys(out, "schemes"), top_keys(src, "schemes"))
        self.assertNotIn(EXT, out)
        # 落とすのは拡張の塊だけ。ほかのターゲットの中身は1字も変えない。
        for t in top_keys(out, "targets"):
            if t != "EffeTuneLive":
                self.assertEqual(block(out, t), block(src, t), t)

    def test_app_deps_exclude_extension(self):
        src = (ROOT / "project.yml").read_text("utf-8")
        app = block(self.gs.make_sim_spec(src), "EffeTuneLive")
        deps = app[app.index("    dependencies:"):]
        self.assertNotIn(EXT, deps)
        self.assertIn("- target: EffectDeckShare", deps)
        self.assertIn("- sdk: CoreText.framework", deps)

    def test_matches_pyyaml_when_available(self):
        try:
            import yaml  # noqa: F401
        except ImportError:
            self.skipTest("PyYAML が無い")
        import yaml
        src = yaml.safe_load((ROOT / "project.yml").read_text("utf-8"))
        out = yaml.safe_load(self.gs.make_sim_spec((ROOT / "project.yml").read_text("utf-8")))
        self.assertEqual(set(out["targets"]), set(src["targets"]) - {EXT})
        app_deps = [d.get("target") for d in out["targets"]["EffeTuneLive"].get("dependencies", [])]
        self.assertNotIn(EXT, app_deps)
        for name, body in out["targets"].items():
            if name != "EffeTuneLive":
                self.assertEqual(body, src["targets"][name], name)


if __name__ == "__main__":
    unittest.main()
