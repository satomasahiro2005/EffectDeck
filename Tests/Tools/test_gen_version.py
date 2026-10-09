"""Tools/gen_version.py の試験。"""
from tools_support import (TempDir, env_patch, git, have_git, hermetic_git_env, load_tool, quiet,
                           run_main, unittest, write)

PROJECT = """\
settings:
  base:
    MARKETING_VERSION: "2026.09.22"
    CURRENT_PROJECT_VERSION: "7"
targets:
  Other:
    settings:
      base:
        MARKETING_VERSION: "1.0"
"""

README = """\
# EffectDeck
![EffeTune DSP](https://img.shields.io/badge/EffeTune%20DSP-0.10.0-3B82F6)
Later text: badge/EffeTune%20DSP-0.10.0-3B82F6 stays.
"""


class PureTests(unittest.TestCase):
    def setUp(self):
        self.gv = load_tool("gen_version")

    def test_describe_parse(self):
        self.assertEqual(self.gv.parse_describe("dsp-v0.10.0-3-gabca7ff9"), "0.10.0")
        self.assertEqual(self.gv.parse_describe("dsp-v0.11.0\n"), "0.11.0")
        self.assertEqual(self.gv.parse_describe(""), "")

    def test_badge_replace(self):
        fixed, hits = self.gv.replace_badge(README, "0.11.0")
        self.assertEqual(hits, 1)
        self.assertIn("EffeTune%20DSP-0.11.0-3B82F6)", fixed.splitlines()[1])
        self.assertIn("EffeTune%20DSP-0.10.0-3B82F6 stays", fixed)   # 最初の1つだけ
        # shields.io では - を -- と書く。
        fixed, _ = self.gv.replace_badge(README, "1.0.0-rc1")
        self.assertIn("EffeTune%20DSP-1.0.0--rc1-3B82F6", fixed)

    def test_today_first_only(self):
        out, old, new = self.gv.set_marketing_version(PROJECT, "2026.09.27")
        self.assertEqual((old, new), ("2026.09.22", "2026.09.27"))
        self.assertIn('    MARKETING_VERSION: "2026.09.27"', out)
        self.assertIn('        MARKETING_VERSION: "1.0"', out)
        self.assertEqual(out.replace("2026.09.27", "2026.09.22"), PROJECT)
        with self.assertRaises(ValueError):
            self.gv.set_marketing_version("nothing here", "2026.09.27")


@unittest.skipUnless(have_git(), "git が無い")
class ShallowTests(unittest.TestCase):
    def make_origin(self, tmp, env):
        origin = tmp / "origin"
        origin.mkdir()
        git(origin, "init", "-q", "-b", "main", env=env)
        write(origin / "a.txt", "1\n")
        git(origin, "add", ".", env=env)
        git(origin, "commit", "-q", "-m", "one", env=env)
        write(origin / "a.txt", "2\n")
        git(origin, "commit", "-q", "-am", "two", env=env)
        git(origin, "tag", "dsp-v0.11.0", env=env)
        return origin

    def run_gen(self, tmp, dsp, env, strict=None):
        gv = load_tool("gen_version")
        gv.DSP = dsp
        gv.DST = write(tmp / "project.yml", PROJECT)
        gv.SWIFT = tmp / "UpstreamVersion.swift"
        gv.README = write(tmp / "README.md", README)
        keep = {k: env[k] for k in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM")}
        with env_patch(ET_STRICT=strict, **keep), quiet() as (out, err):
            code = run_main(gv.main, [])
        return code, gv, err.getvalue()

    def test_full_clone_writes_version(self):
        with TempDir() as tmp:
            env = hermetic_git_env(tmp)
            origin = self.make_origin(tmp, env)
            code, gv, err = self.run_gen(tmp, origin, env, strict="1")
            self.assertEqual(code, 0, err)
            self.assertIn('let ETUpstreamVersion = "0.11.0"', gv.SWIFT.read_text("utf-8"))
            self.assertIn("EffeTune%20DSP-0.11.0-", gv.README.read_text("utf-8"))
            # package.json が無ければ、アプリ全体の版は空。
            self.assertIn('let ETUpstreamAppVersion = ""', gv.SWIFT.read_text("utf-8"))

    def test_app_version_comes_from_package_json(self):
        with TempDir() as tmp:
            env = hermetic_git_env(tmp)
            origin = self.make_origin(tmp, env)
            write(origin / "package.json", '{"name": "effetune", "version": "2.11.0"}\n')
            git(origin, "add", "package.json", env=env)
            git(origin, "commit", "-q", "-m", "package", env=env)
            code, gv, err = self.run_gen(tmp, origin, env, strict="1")
            self.assertEqual(code, 0, err)
            text = gv.SWIFT.read_text("utf-8")
            self.assertIn('let ETUpstreamVersion = "0.11.0"', text)
            self.assertIn('let ETUpstreamAppVersion = "2.11.0"', text, "dsp/ の版とは別に読む")

    def test_shallow_fatal_strict(self):
        # actions/checkout の既定は浅い submodule。describe が通っても、浅い木の版は信用しない。
        with TempDir() as tmp:
            env = hermetic_git_env(tmp)
            origin = self.make_origin(tmp, env)
            git(tmp, "clone", "-q", "--depth", "1", origin.as_uri(), "shallow", env=env)
            shallow = tmp / "shallow"
            self.assertEqual(git(shallow, "rev-parse", "--is-shallow-repository", env=env), "true")
            code, gv, err = self.run_gen(tmp, shallow, env)
            self.assertEqual(code, 0, err)        # ET_STRICT が無ければ今までどおり
            gv.SWIFT.unlink()                     # 上の実行が書いたもの。strict では書かないことを見る
            code, gv, err = self.run_gen(tmp, shallow, env, strict="1")
            self.assertNotEqual(code, 0)
            self.assertIn("shallow", err.lower())
            self.assertFalse(gv.SWIFT.exists())

    def test_no_git_is_error(self):
        with TempDir() as tmp:
            env = hermetic_git_env(tmp)
            (tmp / "copy").mkdir()
            with env_patch(GIT_CEILING_DIRECTORIES=str(tmp)):
                code, gv, err = self.run_gen(tmp, tmp / "copy", env)
            self.assertNotEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
