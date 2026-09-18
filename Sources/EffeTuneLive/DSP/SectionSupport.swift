//  SectionSupport.swift
//  Section は音を触らない飾りで、下に続くエフェクトをひとまとまりにする。
//
//  上流の実装:
//    - plugins/control/section.js — processor は `return data;` だけ。
//      持っているのは `cm`（セクションの名前）ひとつ。
//    - plugins/plugins.txt:123 — `control/section: Section | Control | SectionPlugin`。
//      表示名は "Section"、クラス名は "SectionPlugin"、カテゴリは control。
//    - docs/plugins/control.md:13 — 配下の各エフェクトは自分の ON/OFF を保つ。
//
//  効き目は鎖の側にある。js/audio/dsp-pipeline-descriptor.js:190-212 が答:
//
//      let insideSection = false, sectionEnabled = true;
//      for (const plugin of pipeline) {
//          if (isSectionPlugin(plugin)) {
//              insideSection = true;
//              sectionEnabled = Boolean(plugin.enabled);
//              continue;                       // ← Section 自身は descriptor に入らない
//          }
//          const sectionGate = !insideSection || sectionEnabled;
//          ...
//      }
//
//  ここから分かること3つ:
//    1. 効く範囲は Section の次から**次の Section の手前まで**。Section に当たるたび
//       sectionEnabled が上書きされるだけで、閉じる印は無い。最初の Section より前の
//       段はどの Section にも属さないので常に通る（!insideSection）。
//       同じ範囲の取り方が js/ui/pipeline/pipeline-section-handler.js:250-268
//       findSectionRange にもある（削除・移動・選択・畳みが全部これを使う）。
//    2. 合成は AND。配下の enabled はそのまま、別の口 sectionGate で止める。
//       engine.cpp:753 と :919 がどちらも
//       `if (node.enabled == 0u || node.sectionGate == 0u) continue;`。
//       Section を入れ直せば各段の ON/OFF がそのまま戻る。
//    3. Section 自身は descriptor に一切出ない（上の `continue`）。
//
//  畳み方は js/ui/pipeline/pipeline-item-builder.js:795-830（Shift+クリックで
//  Section から次の Section の手前まで一括で開閉）。ヘッダに出す文字は同 :238-239 で
//  `cm` が空でなければ "<cm> Section"、空なら "Section"。
//
//  Section 自体は et_instance_create しない。カーネルが無いので必ず 0 が返り、
//  instance == 0 のノードが鎖に残ると publish が黙って落として
//  「画面には出ているのに何も掛からない」になる。
//  descriptor には入れない。chain には残す。

import Foundation

enum ETSection {

    /// カタログには載らない。params.json に対応する plugin が無いため。
    /// 名前は plugins/plugins.txt:123 の3列目に合わせてある。
    static let type = "SectionPlugin"

    /// 保存形式に書く表示名。上流は `nm` / `name` に plugin.name をそのまま書くので
    /// （js/utils/serialization-utils.js:37, 90）、web 版と往復するにはこの綴りが要る。
    static let name = "Section"

    /// セクションの名前を入れる保存キー。section.js の `cm`。
    static let commentKey = "cm"

    /// 鎖に置ける飾りとしての見た目。パラメータは持たない
    /// （名前は Node 側に文字列で持つ。ETParam は float しか運べない）。
    /// about は docs/plugins/control.md:13 の説明から。
    static let spec = ETEffect(
        type: type,
        name: name,
        about: "Groups the effects below it so the whole group can be bypassed with one toggle. Each effect keeps its own ON/OFF.",
        category: "control",
        paramsHash: 0,
        floatCount: 0,
        defaults: [],
        params: [])

    static func isSection(_ spec: ETEffect) -> Bool { spec.type == type }

    /// 名前を持たない Section か。
    ///
    /// **組を閉じるためだけに置くもの。**鎖はフラットな配列で、Section は
    /// 「ここから」の印しか持たない（range(after:) を読むこと）。だから
    /// 「組の外」という状態が形式に無い。名前の無い Section を置けば、
    /// 上流はただの新しい組として読み、こちらは組の終わりとして描ける。
    /// 形式を変えないので web と行き来しても壊れない。
    static func isUnnamed(_ comment: String) -> Bool {
        comment.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// ヘッダに出す文字。pipeline-item-builder.js:238-239 と同じ。
    static func title(_ comment: String) -> String {
        let cm = comment.trimmingCharacters(in: .whitespaces)
        return cm.isEmpty ? name : "\(cm) \(name)"
    }

    /// 各段の sectionGate を決める。
    /// dsp-pipeline-descriptor.js:190-212 の insideSection / sectionEnabled と同じ走り方。
    ///
    /// - Parameters:
    ///   - types: 各段の spec.type
    ///   - enabled: 各段の入切
    /// - Returns: 各段の sectionGate（1 なら通す）。Section 自身にも 1 を返すが、
    ///            Section は descriptor に入らないので使われない。
    static func gates(types: [String], enabled: [Bool]) -> [UInt8] {
        precondition(types.count == enabled.count)
        var out = [UInt8](repeating: 1, count: types.count)
        // 最初の Section より前は !insideSection で常に通る。
        var open = true
        for i in types.indices {
            if types[i] == type {
                open = enabled[i]
                out[i] = 1       // Section 自身は区切りに縛られない
            } else {
                out[i] = open ? 1 : 0
            }
        }
        return out
    }

    /// 畳んだときに隠す範囲。Section の次から、次の Section の手前まで。
    /// findSectionRange（pipeline-section-handler.js:250-268）は Section 自身を含む
    /// startIndex..<endIndex を返すが、こちらは配下だけを返す。
    static func range(after index: Int, types: [String]) -> Range<Int> {
        guard types.indices.contains(index), types[index] == type else {
            return index..<index
        }
        var end = index + 1
        while end < types.count && types[end] != type { end += 1 }
        return (index + 1)..<end
    }
}
