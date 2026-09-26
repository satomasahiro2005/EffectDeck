#!/usr/bin/env python3
"""EffeTune のプラグインが持つ出荷時プリセットを Swift へ焼く。

上流は各プラグイン .js の先頭に定数表を置き、クラスに
`static getSystemPresetGroups()` を生やしている
（plugins/dynamics/power_amp_sag.js:8-20）。Tube Simulator のグループだけは
spread と filter で組み立てる（plugins/saturation/tube_simulator.js:483-503）ので、
正規表現では取れない。**評価するしかない** ＝ node が要る。
そこは Tools/effect_presets_dump.mjs に任せて、ここは Swift を書くだけ。

node が無いとき・Vendor/effetune が無いときは**生成せずに 0 で戻る**。
生成物は追跡しているので、そのときは既にあるものがそのまま正になる
（gen_presets.py と同じ）。

    python3 Tools/gen_effect_presets.py [Vendor/effetune のパス]
"""
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DUMP = ROOT / "Tools" / "effect_presets_dump.mjs"
OUT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "EffectPresets.swift"

HEADER = """\
//  EffectPresets.swift
//  Tools/gen_effect_presets.py が作る。手で直さないこと。
//
//  中身は EffeTune の各プラグインが定数で持っている出荷時プリセット
//  （上流の呼び名は「System Presets」）。上流は .js の先頭に
//  `const <NAME>_SYSTEM_PRESETS = Object.freeze([...])` を置き、
//  クラスに `static getSystemPresetGroups()` を生やしている。
//  読むのは EffectPresetApply で、params は ETParamCoding.decode が食う。
//
//  鎖ぜんぶのプリセット（SystemPresets.swift）とは別物。あちらは
//  .effetune_preset のファイルで、こちらはエフェクト 1 個ぶんの設定。

import Foundation

/// 出荷時プリセット 1 件。綴りは上流の `{ id, label, params }` に合わせる。
struct ETEffectPreset: Identifiable {
    /// **上流の id は別のエフェクトと重なる。** "gramophone" は
    /// AM Radio Simulator と SW Radio Simulator の両方にある（実測で 5 件）。
    /// ForEach に渡すのはエフェクト名と繋いだこちら。
    var id: String { effect + "/" + presetId }
    /// エフェクトの**表示名**。上流の PluginPresetStore が
    /// this.plugin.name で引くのと同じ鍵。
    let effect: String
    /// 上流の preset.id。一致判定に使う。
    let presetId: String
    /// 画面に出す名前。上流の preset.label。
    let label: String
    /// 上流 getSystemPresetGroups() のグループ名。
    /// **Tube Simulator 以外は全部空**（グループが 1 つしか無い）。
    let group: String
    /// 上流の preset.params をそのまま。辞書へ戻すのは ETEffectPreset.params。
    let json: String
}

/// 上流の並びのまま。グループの順（Pre → Power → Pre+Power）も、
/// グループの中の順も、上流が返したとおり。
let ETEffectPresetList: [ETEffectPreset] = [
"""

FOOTER = """\
]

/// エフェクトの表示名で引く。Dictionary(grouping:) は元の並びを保つので、
/// 上の順番がそのまま残る。
let ETEffectPresets: [String: [ETEffectPreset]] =
    Dictionary(grouping: ETEffectPresetList, by: \\.effect)
"""


def swift_quoted(s: str) -> str:
    # id / label / group は上流の文字列。バックスラッシュも " も出ていないが、
    # 出たら気づけるように弾く（生成物が黙って壊れるより止まるほうがよい）。
    if '"' in s or "\\" in s:
        raise ValueError("Swift の文字列に入れられない: %r" % s)
    return '"%s"' % s


def main() -> int:
    vendor = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 \
        else ROOT / "Vendor" / "effetune"
    plugins = vendor / "plugins"

    if not (plugins / "plugins.txt").is_file():
        print("effect presets: %s が無いので飛ばす" % plugins)
        return 0
    if shutil.which("node") is None:
        print("effect presets: node が無いので飛ばす（既存の Generated を使う）")
        return 0

    try:
        raw = subprocess.run(["node", str(DUMP), str(plugins)],
                             check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        print("!! dump に失敗", e.stderr.decode("utf-8", "replace"), file=sys.stderr)
        return 1
    if raw.stderr:
        sys.stderr.write(raw.stderr.decode("utf-8", "replace"))

    # **読めなければ既存を残す。**Mac 側で出力が 65536 バイトで切れたことがある。
    # node の版のせいではなく、dump が process.exit() で終わっていたため。
    # Mac のパイプでは stdout の書き込みが非同期で、書き切る前にプロセスが
    # 終わっていた（Windows のパイプは同期なので出ない）。dump は exitCode で
    # 終わるように直したが、切れた JSON で追跡してある Swift を上書きするより
    # 既存を残すほうがましなので、警告だけ出して飛ばす。
    try:
        data = json.loads(raw.stdout.decode("utf-8"))
    except json.JSONDecodeError as e:
        print("!! dump の出力が読めない（%s）。既存の Generated を使う" % e,
              file=sys.stderr)
        return 0

    lines = [HEADER.rstrip("\n")]
    count = 0
    for entry in data:
        effect = entry["name"]
        for group in entry["groups"]:
            for preset in group["presets"]:
                compact = json.dumps(preset["params"], ensure_ascii=False,
                                     separators=(",", ":"))
                # 生文字列で囲む。中身に '"""#' が出ないことを確かめてから。
                assert '"""#' not in compact, preset["id"]
                lines.append("    ETEffectPreset(")
                lines.append("      effect: %s," % swift_quoted(effect))
                lines.append("      presetId: %s," % swift_quoted(preset["id"]))
                lines.append("      label: %s," % swift_quoted(preset["label"]))
                lines.append("      group: %s," % swift_quoted(group["label"]))
                # Swift の複数行文字列は、中身の行が閉じ記号より浅いとエラーになる。
                lines.append('      json: #"""')
                lines.append("      " + compact)
                lines.append('      """#),')
                count += 1
    lines.append(FOOTER)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("effect presets: %d 件 / %d エフェクト" % (count, len(data)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
