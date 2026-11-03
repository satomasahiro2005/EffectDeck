//  TabbedParameterList.swift
//  汎用のパラメータ一覧を、上流と同じタブで分けて出す。
//
//  ツマミの行は ParameterRow をそのまま使う。増えるのはタブの帯だけ。
//  どの型がどのタブにどの key を置くかは DSP/ETParamTabs.swift の表にある。

import SwiftUI

struct TabbedParameterList: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    let tabs: [ETParamTab]

    /// 開いているタブ。先頭が既定（上流の selectedTab の初期値）。
    /// 上流は保存しないが、カードを畳むと View が消えるので、畳んでも残る置き場に控える
    /// （端末の中だけ。鎖には書かない）。
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tab", selection: $selected) {
                ForEach(tabs.indices, id: \.self) { i in
                    Text(tabs[i].title).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ForEach(rows) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
        }
        .etRemembers($selected, key: "paramTab", node: node.id)
    }

    /// 開いているタブのツマミ。表に載っていて型に無い key は飛ばす。
    private var rows: [ETParam] {
        guard !tabs.isEmpty else { return [] }
        let tab = tabs[min(max(selected, 0), tabs.count - 1)]
        return tab.keys.compactMap { key in node.spec.params.first { $0.key == key } }
    }
}
