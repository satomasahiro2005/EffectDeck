"""シェルで `$NAME` の直後に全角の文字を続けない。

macOS のランナーの bash 3.2 は、ロケールが UTF-8 でないとき全角の頭のバイトを
変数名の続きとして読む。`$FLAVOR（構成 $CONFIG）` は変数が空になり括弧も欠けて、
Actions の summary が化けた（2026-10-03）。`${NAME}` と囲めば起きない。
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATTERN = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7F])")


class ShellMultibyteTests(unittest.TestCase):
    def test_no_bare_variable_before_multibyte(self):
        files = sorted(
            list((ROOT / ".github" / "workflows").glob("*.yml"))
            + list((ROOT / "Scripts").rglob("*.sh"))
            + list((ROOT / "Tests" / "Scripts").rglob("*.sh"))
        )
        bad = []
        for path in files:
            for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if PATTERN.search(line):
                    bad.append(f"{path.relative_to(ROOT)}:{i}: {line.strip()}")
        self.assertEqual(bad, [], "変数を ${NAME} と囲む:\n" + "\n".join(bad))


if __name__ == "__main__":
    unittest.main()
