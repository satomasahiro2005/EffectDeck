#!/usr/bin/env python3
"""EffeTune のプラグインが持つ出荷時プリセットを Swift へ焼く。

上流は各プラグイン .js の先頭に定数表を置き、クラスに
`static getSystemPresetGroups()` を生やしている
（plugins/dynamics/power_amp_sag.js:8-20）。Tube Simulator のグループだけは
spread と filter で組み立てる（plugins/saturation/tube_simulator.js:483-503）ので、
正規表現では取れない。**評価するしかない** ＝ node が要る。
そこは Tools/effect_presets_dump.mjs に任せて、ここは Swift を書くだけ。

node が無いとき・Vendor/effetune が無いときは**生成せずに 0 で戻る**。
生成物は追跡しているので、そのときは既にあるものがそのまま正になる。

**ET_STRICT=1（CI）か --strict では飛ばさずに 1 で止める。**node が無い・Vendor が無い・
dump の出力が JSON として読めない・dump が落としたプラグイン（評価できない・.js が無い）を
!! で報せた・前の生成物に在ったエフェクトが丸ごと消えた（そのプラグインのプリセットが黙って
消える。146 件 / 28 種が 143 / 27 になっても 0 だった）。どれも何も書かない。
いつもは書いて、落とした数を最後の行にも出す（setup.sh は tail -1 しか見せない）。

    python3 Tools/gen_effect_presets.py [--strict] [Vendor/effetune のパス]
"""
import json
import os
import pathlib
import re
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


def raw_hashes(text: str) -> str:
    """text を Swift の生文字列 #…#\"\"\"…\"\"\"#…# に書いたとき、書いたとおりに読まれる # の数。

    \\ に同じ数の # が続けばエスケープ、\"\"\" に同じ数の # が続けばそこで閉じるので、
    どちらも中身に出ない数まで増やす（params の "C:\\\\#x" は中身に \\# を持つ）。
    Tools/gen_presets.py の raw_hashes と同じ。
    """
    hashes = "#"
    while "\\" + hashes in text or '"""' + hashes in text:
        hashes += "#"
    return hashes


def effects_in(path: pathlib.Path) -> set:
    """前に書いた EffectPresets.swift が持つエフェクトの表示名。無ければ空。"""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return set()
    return set(re.findall(r'^      effect: "([^"\\]*)",$', text, re.M))


def strict_mode(argv) -> bool:
    return os.environ.get("ET_STRICT", "") not in ("", "0") or "--strict" in argv


def skip(message: str, strict: bool) -> int:
    """飛ばす。strict なら止める。"""
    if strict:
        print("!! %s（ET_STRICT）。何も書いていない" % message, file=sys.stderr)
        return 1
    print("effect presets: %s。飛ばす（既存の Generated を使う）" % message)
    return 0


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    strict = strict_mode(argv)
    paths = [a for a in argv if a != "--strict"]
    vendor = pathlib.Path(paths[0]).resolve() if paths else ROOT / "Vendor" / "effetune"
    plugins = vendor / "plugins"

    if not (plugins / "plugins.txt").is_file():
        return skip("%s が無い" % plugins, strict)
    if shutil.which("node") is None:
        return skip("node が無い", strict)

    try:
        raw = subprocess.run(["node", str(DUMP), str(plugins)],
                             check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        print("!! dump に失敗", (e.stderr or b"").decode("utf-8", "replace"), file=sys.stderr)
        return 1
    warnings = ""
    if raw.stderr:
        warnings = raw.stderr.decode("utf-8", "replace")
        sys.stderr.write(warnings)
    # dump は評価できなかったプラグイン・.js が無いプラグインを !! で報せて飛ばす（そのプリセットは消える）。
    dropped = [ln for ln in warnings.splitlines() if ln.startswith("!!")]
    if dropped and strict:
        print("!! dump が落としたプラグインが %d ある（ET_STRICT）。何も書いていない"
              % len(dropped), file=sys.stderr)
        return 1

    # **読めなければ既存を残す。**Mac 側で出力が 65536 バイトで切れたことがある。
    # node の版のせいではなく、dump が process.exit() で終わっていたため。
    # Mac のパイプでは stdout の書き込みが非同期で、書き切る前にプロセスが
    # 終わっていた（Windows のパイプは同期なので出ない）。dump は exitCode で
    # 終わるように直したが、切れた JSON で追跡してある Swift を上書きするより
    # 既存を残すほうがましなので、警告だけ出して飛ばす。
    try:
        data = json.loads(raw.stdout.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        print("!! dump の出力が読めない（%s）。既存の Generated を使う" % e,
              file=sys.stderr)
        return 1 if strict else 0

    # dump が !! を出さずに落とす形がある（上流が getSystemPresetGroups を改名した・グループが
    # 空になった。持たないプラグインと見分けられない）。前の生成物に在ったエフェクトが丸ごと
    # 消えていれば報せる。strict では何も書かずに止め、いつもは書く（上流が本当に外したときは、
    # 書いた後の生成物がそれを前として受ける）。
    lost = sorted(effects_in(OUT) - {entry["name"] for entry in data})
    for name in lost:
        print("!! %s のプリセットが dump から消えた（前の %s には在った）" % (name, OUT.name),
              file=sys.stderr)
    if lost and strict:
        print("!! 前の生成物に在ったエフェクトが %d 消えた（ET_STRICT）。何も書いていない" % len(lost),
              file=sys.stderr)
        return 1

    lines = [HEADER.rstrip("\n")]
    count = 0
    for entry in data:
        effect = entry["name"]
        for group in entry["groups"]:
            for preset in group["presets"]:
                compact = json.dumps(preset["params"], ensure_ascii=False,
                                     separators=(",", ":"))
                # 生文字列で囲む。# の数は中身が書いたとおりに読まれる数（raw_hashes）。
                hashes = raw_hashes(compact)
                lines.append("    ETEffectPreset(")
                lines.append("      effect: %s," % swift_quoted(effect))
                lines.append("      presetId: %s," % swift_quoted(preset["id"]))
                lines.append("      label: %s," % swift_quoted(preset["label"]))
                lines.append("      group: %s," % swift_quoted(group["label"]))
                # Swift の複数行文字列は、中身の行が閉じ記号より浅いとエラーになる。
                lines.append('      json: %s"""' % hashes)
                lines.append("      " + compact)
                lines.append('      """%s),' % hashes)
                count += 1
    lines.append(FOOTER)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    # setup.sh は 2>&1 | tail -1 で最後の行しか見せない。上の !! は流れて消えるので、ここにも書く。
    notes = []
    if dropped:
        notes.append("dump が %d プラグインを落とした" % len(dropped))
    if lost:
        notes.append("前の生成物に在った %d エフェクトが消えた" % len(lost))
    print("effect presets: %d 件 / %d エフェクト%s"
          % (count, len(data), "（%s。上の !! を見る）" % "・".join(notes) if notes else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
