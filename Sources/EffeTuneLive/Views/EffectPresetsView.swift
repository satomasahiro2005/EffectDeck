//  EffectPresetsView.swift
//  エフェクト 1 個ぶんのプリセット。カードの ⋯ から出す。
//
//  鎖ぜんぶを出し入れする PresetsView とは別物。上流も別のダイアログで
//  （js/ui/pipeline/plugin-preset-dialog.js）、節の順番も見出しもそちらに合わせてある:
//  System Presets →（保存欄＋）User Presets（:264-349 の renderContent）。
//
//  一致しているものに印を付ける（上流の `.active`、:285）。
//  一致しなければ何も点けない。**上流に「Custom」という表示は無い。**
//
//  押しても閉じない。上流の activatePreset も閉じずに中身を組み直すだけで
//  （:436-446）、並べて聴き比べるのに閉じられると困る。

import SwiftUI

struct EffectPresetsView: View {
    @Environment(\.dismiss) private var dismiss

    /// 鎖の中の位置。**ここがずれると別のエフェクトを書き換える**ので、
    /// 使う前に下の `node` で型を照合する。
    let index: Int
    /// このカードのエフェクト。プリセットを引く鍵（表示名）もここから取る。
    let spec: ETEffect
    @ObservedObject var dsp: EffeTuneDSP
    @StateObject private var store = EffectPresetStore.shared

    @State private var newName = ""

    /// 上流 getSystemPresetGroups() が返す単位。
    /// SwiftUI の Group と混ざらないよう別の名前にしてある。
    private struct PresetGroup: Identifiable {
        /// グループ名。**Tube Simulator 以外は空**（グループが 1 つしか無い）。
        let id: String
        let presets: [ETEffectPreset]
    }

    // MARK: - いまの段

    /// 適用したあと印を付け直すので、渡された写しではなく鎖から引く。
    /// 出している間に鎖が動いて別のエフェクトになっていたら nil。
    private var node: EffeTuneDSP.Node? {
        guard dsp.chain.indices.contains(index),
              dsp.chain[index].spec.type == spec.type else { return nil }
        return dsp.chain[index]
    }

    /// 出荷時プリセットを上流の並びのまま束ねる。
    /// ETEffectPresetList が上流の順を保っているので、出た順に拾うだけでよい。
    private var groups: [PresetGroup] {
        let all = ETPresetCatalog.presets(for: spec.name)
        var order: [String] = []
        for preset in all where !order.contains(preset.group) { order.append(preset.group) }
        return order.map { label in
            PresetGroup(id: label, presets: all.filter { $0.group == label })
        }
    }

    /// いま一致している出荷時プリセットの id。無ければ空。
    private var activeId: String {
        guard let node = node else { return "" }
        return EffectPresetApply.matchingPresetId(for: spec, current: node.values)
    }

    private var names: [String] { store.names(of: spec.name) }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedName.isEmpty && node != nil }

    // MARK: - 読み書き

    /// 値をまとめて入れ替える。
    private func apply(_ params: [String: Any]) {
        guard let node = node else { return }
        let next = EffectPresetApply.values(for: spec, params: params, current: node.values)
        dsp.setValues(next, at: index)

        // IR Reverb の素材だけは float に載らないので鍵で運ぶ
        // （PipelineStore.swift:74-77 と同じ扱い）。段に書いてから入れ直す。
        // 入れ直しを DSP にやらせるのは、畳んだカードにはビューが無いため
        // （EffeTuneDSP.reloadAssets の注記）。
        if let ir = params[ETIRLoader.presetKey] as? String,
           !ir.isEmpty, ir != node.irId {
            dsp.setIRId(ir, at: index)
            dsp.reloadAssets()
        }
    }

    private func applyUser(_ name: String) {
        guard let params = store.params(of: spec.name, name: name) else { return }
        apply(params)
    }

    // MARK: - 画面

    var body: some View {
        NavigationStack {
            List {
                if !groups.isEmpty { systemSection }
                userSection
            }
            .navigationTitle("Effect Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var systemSection: some View {
        // **一致の判定は 1 回だけ。** 行ごとに引くと、Tube Simulator では
        // 35 行 × 35 件ぶんの突き合わせ（と json の読み直し）になる。
        let active = activeId
        return Section {
            ForEach(groups) { group in
                // グループ名が空なら見出しを出さない（上流 :273-278 の `if (group.label)`）。
                if !group.id.isEmpty {
                    Text(group.id)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(group.presets) { preset in
                    Button {
                        apply(preset.params)
                    } label: {
                        HStack {
                            Text(preset.label).foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if preset.presetId == active {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("System Presets")
        } footer: {
            Text("Changes this effect only.")
        }
    }

    private var userSection: some View {
        Section {
            HStack {
                TextField("Preset name", text: $newName)
                    .textInputAutocapitalization(.words)
                Button("Save") {
                    if let node = node { store.save(trimmedName, of: node) }
                    newName = ""
                }
                .disabled(!canSave)
            }

            if names.isEmpty {
                // 空でも 1 行出す。上流も空のときに言う（ui.pluginPresets.noUserPresets）。
                Text("No saved presets")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in
                    Button {
                        applyUser(name)
                    } label: {
                        Text(name).foregroundStyle(.primary)
                    }
                    // **.onDelete を使わない。** 位置で消すと、続けて払ったときに
                    // 別の行が消える。理由は PresetsView.swift:206-213 に書いてある。
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            store.remove(name, of: spec.name)
                        }
                    }
                }
            }
        } header: {
            Text("User Presets")
        } footer: {
            // 押せないボタンだけ置くと、壊れているのか条件があるのか読めない。
            // 同じ名前で保存すると前のものが黙って消えるので、押す前に言う。
            if !trimmedName.isEmpty && names.contains(trimmedName) {
                Text("A preset named “\(trimmedName)” already exists. Saving replaces it.")
            } else if names.isEmpty {
                Text("Saved under “\(spec.name)”. Only this effect sees them.")
            } else {
                Text("Saved under “\(spec.name)”. Swipe a preset to delete it.")
            }
        }
    }
}
