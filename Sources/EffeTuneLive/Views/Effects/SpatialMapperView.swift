import SwiftUI

/// Matrices use output * 16 + input, including channels currently outside the route.
///
/// **見せるのは経路の幅だけ。保存は 16×16 のまま**（上流も同じ）。
/// 出力は段が受け取る幅（All なら鎖の幅、Stereo と対は 2、単独は 1）、
/// 入力は min(ic, 出力の数)（spatial_mapper.js:204-219 の _routedChannelCount /
/// _displayInputChannelCount）。幅は EffeTuneDSP.routedChannels(of:) が engine.cpp と
/// 同じ式で出しているので、それを使う。
struct SpatialMapperView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    @State private var component = "dm"
    @State private var output = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if node.channelSpec != -2 {
                Button("Use all output channels") {
                    dsp.setRouting(at: index, channelSpec: -2)
                }
                Text("Spatial Mapper needs Routing set to All to send sound beyond channels 1–2.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(node.spec.params.filter { !$0.isArray }) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
            Picker("Component", selection: $component) {
                Text("Direct").tag("dm")
                Text("Diffuse").tag("fm")
                Text("Residual").tag("rm")
            }.pickerStyle(.segmented)
            Stepper("Output \(shownOutput + 1)", value: Binding(
                get: { shownOutput },
                set: { output = $0 }
            ), in: 0...(outputCount - 1))
            if let matrix = node.spec.params.first(where: { $0.key == component }) {
                ForEach(0..<inputCount, id: \.self) { input in
                    let offset = matrix.offset + shownOutput * 16 + input
                    HStack {
                        Text("Input \(input + 1)").font(.caption)
                        Slider(value: Binding(
                            get: { Double(node.values[offset]) },
                            set: { dsp.setValue(Float($0), at: index, offset: offset) }
                        ), in: -1...1, step: 0.01)
                        .accessibilityLabel("\(component) input \(input + 1) to output \(shownOutput + 1)")
                        ETValueField(text: String(format: "%+.2f", node.values[offset]),
                                     label: "\(component) input \(input + 1)",
                                     editText: { ETNumberText.draft(Double(node.values[offset])) }) { typed in
                            dsp.setValue(Float(min(max(typed, -1), 1)), at: index, offset: offset)
                        }
                    }
                }
            }
        }
    }

    /// 段が受け取る幅。1〜16。
    private var outputCount: Int {
        min(16, max(1, EffeTuneDSP.routedChannels(of: node)))
    }

    /// 選んでいた出力が幅の外へ出たら、端に寄せて見せる。**選択そのものは残す。**
    /// 経路を戻せば元の出力に戻る。
    private var shownOutput: Int {
        min(output, outputCount - 1)
    }

    private var inputCount: Int {
        guard let param = node.spec.params.first(where: { $0.key == "ic" }) else {
            return min(2, outputCount)
        }
        return min(outputCount, min(16, max(1, Int(node.values[param.offset]))))
    }
}
