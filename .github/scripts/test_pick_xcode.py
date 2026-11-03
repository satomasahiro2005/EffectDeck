#!/usr/bin/env python3
"""pick_xcode.py の試験。/Applications も simctl も触らない（一時ディレクトリと JSON を渡す）。

    python3 -m unittest discover -s .github/scripts -p 'test_*.py'
"""
import contextlib
import io
import json
import os
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pick_simulator  # noqa: E402
import pick_xcode  # noqa: E402

IOS = "com.apple.CoreSimulator.SimRuntime.iOS-"


def runtime(ident, version, build="", available=True):
    return {"identifier": ident, "version": version, "buildversion": build,
            "isAvailable": available, "name": "iOS " + version}


class Base(unittest.TestCase):
    def call(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = pick_xcode.main(argv)
        return code, out.getvalue().strip(), err.getvalue()


class PickXcodeTests(Base):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.apps = tmp.name

    def app(self, name, version=None, build=""):
        path = os.path.join(self.apps, name)
        os.makedirs(os.path.join(path, "Contents"))
        if version is not None:
            with open(os.path.join(path, "Contents", "version.plist"), "wb") as f:
                plistlib.dump({"CFBundleShortVersionString": version, "ProductBuildVersion": build}, f)
        return os.path.realpath(path)

    def alias(self, name, target):
        try:
            os.symlink(os.path.join(self.apps, target), os.path.join(self.apps, name))
        except (OSError, NotImplementedError) as e:
            self.skipTest("symlink を作れない: %s" % e)

    def pick(self):
        return self.call(["xcode", "--apps", self.apps])

    def test_newest_version_wins_even_if_beta(self):
        self.app("Xcode_27.0.app", "27.0", "27A240")
        self.app("Xcode_27.1_beta.app", "27.1", "27B5024e")
        want = self.app("Xcode_27.2_beta.app", "27.2", "27C5012b")
        code, out, err = self.pick()
        self.assertEqual((code, out), (0, want))
        self.assertIn("27.1", err)

    def test_versions_compare_as_numbers(self):
        # 文字で比べると 27.9 が 27.10 より新しくなる。
        want = self.app("Xcode_27.10.app", "27.10", "27K10")
        self.app("Xcode_27.9.app", "27.9", "27J99")
        self.assertEqual(self.pick()[:2], (0, want))

    def test_release_beats_beta_of_same_version(self):
        # beta の build 番号（5024）は正式版（74）より大きいので、番号だけで比べると beta を取る。
        self.app("Xcode_27.1_beta_3.app", "27.1", "27B5024e")
        want = self.app("Xcode_27.1.app", "27.1", "27B74")
        self.assertEqual(self.pick()[:2], (0, want))

    def test_release_candidate_is_not_release(self):
        want = self.app("Xcode_27.1.app", "27.1", "27B74")
        self.app("Xcode_27.1_Release_Candidate.app", "27.1", "27B5080a")
        self.app("Xcode_27.1_RC2.app", "27.1", "27B5090a")
        self.assertEqual(self.pick()[:2], (0, want))

    def test_later_beta_of_same_version_wins(self):
        self.app("Xcode_27.2_beta.app", "27.2", "27C5012b")
        want = self.app("Xcode_27.2_beta_2.app", "27.2", "27C5030d")
        self.assertEqual(self.pick()[:2], (0, want))

    def test_aliases_collapse_to_the_real_app(self):
        want = self.app("Xcode_27.2_beta.app", "27.2", "27C5012b")
        self.app("Xcode_27.0.app", "27.0", "27A240")
        self.alias("Xcode.app", "Xcode_27.0.app")
        self.alias("Xcode_27.2.0_beta.app", "Xcode_27.2_beta.app")
        code, out, err = self.pick()
        self.assertEqual((code, out), (0, want))
        # 実体ごとに 1 行。
        self.assertEqual(err.count("27C5012b"), 1)
        self.assertEqual(err.count("27A240"), 1)

    def test_beta_mark_on_an_alias_counts(self):
        # 実体の名前に印が無くても、別名に beta があれば正式版ではない。
        self.app("Xcode_27.1.app", "27.1", "27B74")
        self.app("Xcode-next.app", "27.1", "27B5024e")
        self.alias("Xcode_27.1_beta.app", "Xcode-next.app")
        self.assertEqual(self.pick()[1], os.path.realpath(os.path.join(self.apps, "Xcode_27.1.app")))

    def test_unreadable_apps_are_skipped(self):
        self.app("Xcode_28.0_beta.app")  # version.plist が無い
        self.app("Xcode_29.app", "junk")
        want = self.app("Xcode_27.0.app", "27.0", "27A240")
        code, out, err = self.pick()
        self.assertEqual((code, out), (0, want))
        self.assertIn("Xcode_28.0_beta.app", err)
        self.assertIn("Xcode_29.app", err)

    def test_no_xcode_fails(self):
        self.app("Xcode_28.0_beta.app")
        code, out, err = self.pick()
        self.assertEqual((code, out), (1, ""))
        self.assertIn("無い", err)

    def test_word_containing_rc_is_not_a_release_candidate(self):
        self.assertFalse(pick_xcode.is_prerelease(["/Applications/Xcode_27.0_Source.app"]))
        self.assertTrue(pick_xcode.is_prerelease(["/Applications/Xcode_27.0_RC.app"]))
        self.assertTrue(pick_xcode.is_prerelease(["/Applications/Xcode_27.0_rc_2.app"]))


class PickRuntimeTests(Base):
    def pick(self, runtimes, sdk=None):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            json.dump({"runtimes": runtimes}, f)
        self.addCleanup(os.unlink, f.name)
        argv = ["runtime", "--json", f.name] + (["--sdk", sdk] if sdk else [])
        return self.call(argv)

    def test_newest_ios_runtime(self):
        code, out, err = self.pick([
            runtime(IOS + "27-0", "27.0", "24A335"),
            runtime(IOS + "27-2", "27.2", "24C5040a"),
            runtime(IOS + "27-1", "27.1", "24B80"),
            runtime("com.apple.CoreSimulator.SimRuntime.watchOS-27-2", "27.9"),
            runtime(IOS + "27-3", "27.3", available=False),
        ])
        self.assertEqual((code, out), (0, "27.2 %s27-2" % IOS))
        self.assertNotIn("watchOS", err)
        self.assertNotIn("27-3", err)

    def test_runtime_newer_than_sdk_is_not_used(self):
        code, out, err = self.pick([runtime(IOS + "27-1", "27.1"), runtime(IOS + "27-2", "27.2")], sdk="27.1")
        self.assertEqual((code, out), (0, "27.1 %s27-1" % IOS))
        self.assertIn("使わない", err)
        # 点の後の版の違いは同じ SDK とみなす。
        code, out, _ = self.pick([runtime(IOS + "27-1", "27.1.2")], sdk="27.1")
        self.assertEqual((code, out), (0, "27.1 %s27-1" % IOS))

    def test_point_release_uses_the_identifier_version(self):
        # 27.0.1 のランタイムの identifier が iOS-27-0 のとき、pick_simulator.py に渡すのは 27.0。
        code, out, _ = self.pick([runtime(IOS + "27-0", "27.0.1", "24A350")])
        self.assertEqual((code, out), (0, "27.0 %s27-0" % IOS))

    def test_output_is_what_pick_simulator_accepts(self):
        # ここで出した版で、同じランタイムの端末を pick_simulator.py が引けること。
        _, out, _ = self.pick([runtime(IOS + "27-0", "27.0.1"), runtime(IOS + "27-2", "27.2")])
        os_version, ident = out.split(" ")
        devices = pick_simulator.ios_devices({"devices": {
            IOS + "27-0": [{"name": "iPad Pro 13-inch (M5)", "udid": "OLD"}],
            ident: [{"name": "iPad Pro 13-inch (M5)", "udid": "NEW"}],
        }})
        self.assertEqual(pick_simulator.pick(devices, "iPad Pro 13-inch (M5)", os_version)[2], "NEW")

    def test_no_usable_runtime_fails(self):
        code, out, err = self.pick([runtime(IOS + "27-2", "27.2")], sdk="27.0")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("27.2", err)
        code, out, _ = self.pick([])
        self.assertEqual((code, out), (1, ""))


if __name__ == "__main__":
    unittest.main()
