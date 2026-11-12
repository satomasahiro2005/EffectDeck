"""SoundFont Player（2.17.0）と Live Audio Receive / Send（2.18.0）を一覧に出さず、
SoundFont Player は音量の追従からも外していること。

EffectPickerView は SwiftUI なので Linux では建てられない。ソースの字で見張る。
カタログからは消さない（プリセット・共有リンク・PC から届く鎖が名指す）ので、それも確かめる。
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
TYPE = "SoundFontPlayerPlugin"


def swift_set(path, name):
    text = (ROOT / path).read_text("utf-8")
    m = re.search(r"static let %s: Set<String> = \[(.*?)\]" % name, text, re.S)
    assert m, "%s に %s が無い" % (path, name)
    return set(re.findall(r'"(\w+)"', m.group(1)))


class PickerHiddenTests(unittest.TestCase):
    def test_picker_hides_exactly_these(self):
        hidden = swift_set("Sources/EffeTuneLive/Views/EffectPickerView.swift", "hiddenTypes")
        self.assertEqual(hidden, {TYPE, "NetworkReceivePlugin", "NetworkSendPlugin"})

    def test_automation_excludes_both_soundfont_types(self):
        excluded = swift_set("Sources/EffeTuneLive/DSP/Automation.swift", "excludedTypes")
        self.assertIn(TYPE, excluded)
        self.assertIn("SFZNotePlayerPlugin", excluded)

    def test_catalog_still_has_it(self):
        catalog = (ROOT / "Sources/EffeTuneLive/Generated/EffectCatalog.swift").read_text("utf-8")
        for t in (TYPE, "NetworkReceivePlugin", "NetworkSendPlugin"):
            self.assertIn('type: "%s"' % t, catalog)


if __name__ == "__main__":
    unittest.main()
