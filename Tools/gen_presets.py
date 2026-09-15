#!/usr/bin/env python3
"""EffeTune 同梱のプリセットを Swift へ焼く。

Vendor/effetune/presets/<category>/<name>.effetune_preset をそのまま持ち込む。
中身は PipelineStore.parse がそのまま受ける形（{"pipeline": [...]}) なので、
変換はせず JSON の文字列のまま埋める。エフェクト名と鍵の対応は読み込み時に取る。

リソースとして同梱しないのは、.xcassets の外のファイルを束ねると
名前の衝突で「Multiple commands produce」に当たるため。
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Vendor" / "effetune" / "presets"
OUT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "BuiltinPresets.swift"

LABEL = {
    "4ch": "4 Channel",
    "amp_sim": "Amp Simulation",
    "lofi": "Lo-Fi",
    "others": "Others",
    "processor": "Processor",
    "spatial": "Spatial",
    "spkr_sim": "Speaker Simulation",
    "utils": "Utilities",
    "visualize": "Visualize",
}


def title(stem: str) -> str:
    return " ".join(w.capitalize() if w.islower() else w for w in stem.split("_"))


def swift_string(s: str) -> str:
    # 生文字列で囲む。中身に "### が出ないことを確かめてから使う。
    assert '"###' not in s
    return '#"""#'.join([])  # 使わない


def main() -> int:
    if not SRC.is_dir():
        print("!! presets が無い", SRC, file=sys.stderr)
        return 1

    items = []
    for path in sorted(SRC.rglob("*.effetune_preset")):
        category = path.parent.name
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            print("!! 読めない", path, e, file=sys.stderr)
            continue
        if not isinstance(data, dict) or not isinstance(data.get("pipeline"), list):
            print("!! 形が違う", path, file=sys.stderr)
            continue
        # 余分な空白を落として埋める。往復はしないので整形は不要。
        compact = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        items.append((LABEL.get(category, category), title(path.stem), compact,
                      len(data["pipeline"])))

    lines = [
        "//  BuiltinPresets.swift",
        "//  Tools/gen_presets.py が作る。手で直さないこと。",
        "//",
        "//  中身は EffeTune 同梱の .effetune_preset をそのまま持ってきたもの。",
        "//  読むのは PipelineStore.parse で、ユーザーが保存したものと同じ経路を通る。",
        "",
        "import Foundation",
        "",
        "struct ETBuiltinPreset: Identifiable {",
        "    var id: String { category + \"/\" + name }",
        "    let category: String",
        "    let name: String",
        "    let effectCount: Int",
        "    let json: String",
        "}",
        "",
        "let ETBuiltinPresets: [ETBuiltinPreset] = [",
    ]
    for category, name, compact, count in items:
        lines.append("    ETBuiltinPreset(")
        lines.append('      category: "%s",' % category)
        lines.append('      name: "%s",' % name)
        lines.append("      effectCount: %d," % count)
        # Swift の複数行文字列は、中身の行が閉じ記号より浅いとエラーになる。
        lines.append('      json: #"""')
        lines.append('      ' + compact)
        lines.append('      """#),')
    lines.append("]")
    lines.append("")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("presets: %d 本 / %d カテゴリ" % (len(items), len({i[0] for i in items})))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
