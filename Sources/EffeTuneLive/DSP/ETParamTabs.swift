//  ETParamTabs.swift
//  専用の画面を持たないエフェクトのうち、上流がツマミをタブに分けているものの表。
//
//  汎用のパラメータ一覧（EffectCardView）がこの表を引いて、タブの帯と、
//  選んだタブのツマミだけを出す。Foundation だけなので、表がカタログと食い違って
//  いないかを実機なしで試せる（ParamTabsTests）。
//
//  上流 EffeTune 2.11.0 の createUI が持つ `definitions` の並びをそのまま写した。
//    AM Radio Simulator : plugins/lofi/am_radio_simulator.js:2136-2166
//    TV Audio Simulator : plugins/lofi/tv_audio_simulator.js:1760-1808
//    Vinyl Simulator    : plugins/lofi/vinyl_simulator.js:1517-1555
//  タブの中の順は各タブの appendChild の順。
//
//  **選んだタブは保存しない。**上流の selectedTab は getParameters に入っておらず
//  （am_radio_simulator.js:1883-1895 ほか）、プリセットにも書かれない。

import Foundation

/// タブ 1 枚ぶん。
struct ETParamTab: Identifiable, Equatable {
    /// 帯に出す字（上流の label）。
    let title: String
    /// このタブに置くパラメータの key。上流が appendChild する順。
    let keys: [String]

    var id: String { title }
}

enum ETParamTabs {

    /// 型名から引く。タブを持たないものは nil。先頭が最初に開くタブ（上流の selectedTab の初期値）。
    static func tabs(for type: String) -> [ETParamTab]? { table[type] }

    private static let table: [String: [ETParamTab]] = [
        // 初期値 'station'（am_radio_simulator.js:1852）。
        "AMRadioSimulatorPlugin": [
            ETParamTab(title: "Station", keys: ["rd", "sm", "tb", "pe", "md", "cp"]),
            ETParamTab(title: "Path", keys: ["sg", "sk", "fd", "st", "in", "io"]),
            ETParamTab(title: "Receiver", keys: ["tn", "bw", "ag", "dt", "hm", "hz"]),
            ETParamTab(title: "Output", keys: ["sp", "og", "mx"]),
        ],
        // 初期値 'standard'（tv_audio_simulator.js:1474）。
        "TVAudioSimulatorPlugin": [
            ETParamTab(title: "Standard", keys: ["ss"]),
            ETParamTab(title: "Programme", keys: ["rd", "tx", "sm", "pr"]),
            ETParamTab(title: "Reception", keys: ["st", "tn", "bw", "mp", "dl", "fd"]),
            ETParamTab(title: "Video Buzz", keys: ["bz"]),
            ETParamTab(title: "Output", keys: ["og", "mx"]),
        ],
        // 初期値 'cutting'（vinyl_simulator.js:1132）。
        "VinylSimulatorPlugin": [
            ETParamTab(title: "Cutting", keys: ["lv", "hf", "mb", "sm"]),
            ETParamTab(title: "Record", keys: ["rp", "rd", "rg", "dr", "st", "sc"]),
            ETParamTab(title: "Stylus", keys: ["sh", "rs", "rc", "tf", "tm", "cm", "dz"]),
            ETParamTab(title: "Output", keys: ["ql", "og", "mx"]),
        ],
    ]

    /// 表にあるすべての型。試験が全部を舐めるのに使う。
    static var types: [String] { Array(table.keys).sorted() }
}
