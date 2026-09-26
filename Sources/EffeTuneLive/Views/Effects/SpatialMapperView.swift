import SwiftUI

/// Matrices use output * 16 + input, including channels currently outside the route.
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
            }
            ForEach(node.spec.params.filter { !$0.isArray }) { param in
                ParameterRow(param: param, nodeIndex: index, values: node.values, dsp: dsp)
            }
            Picker("Component", selection: $component) {
                Text("Direct").tag("dm")
                Text("Diffuse").tag("fm")
                Text("Residual").tag("rm")
            }.pickerStyle(.segmented)
            Stepper("Output \(output + 1)", value: $output, in: 0...15)
            if let matrix = node.spec.params.first(where: { $0.key == component }) {
                ForEach(0..<inputCount, id: \.self) { input in
                    let offset = matrix.offset + output * 16 + input
                    HStack {
                        Text("Input \(input + 1)").font(.caption)
                        Slider(value: Binding(
                            get: { Double(node.values[offset]) },
                            set: { dsp.setValue(Float($0), at: index, offset: offset) }
                        ), in: -1...1, step: 0.01)
                        .accessibilityLabel("\(component) input \(input + 1) to output \(output + 1)")
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

    private var inputCount: Int {
        guard let param = node.spec.params.first(where: { $0.key == "ic" }) else { return 2 }
        return min(16, max(1, Int(node.values[param.offset])))
    }
}
