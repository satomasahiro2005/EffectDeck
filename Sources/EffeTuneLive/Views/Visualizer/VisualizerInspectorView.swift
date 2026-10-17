//  VisualizerInspectorView.swift
//  編集画面のインスペクタ（選んだ要素の設定）と Scene の画面（背景・カード・測る所）。標準の Form だけ。
//  どの操作も ETVisualizerEditorModel.commit を通る（取り消しが効く）。色・不透明度・つまみのように
//  続けて動かすものは coalesce の鍵を渡し、1 秒以内なら取り消し 1 回にまとまる。
//  説明文は置かない。

import SwiftUI
import UIKit

extension ETVisualizerColor {
    /// ColorPicker の色から。8bit に丸める（不透明度は持たない）。
    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32(min(max((v * 255).rounded(), 0), 255)) }
        self.init((byte(r) << 16) | (byte(g) << 8) | byte(b))
    }

    var swiftUIColor: Color {
        let c = components
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

/// 続けて動かす値の 1 行（スライダーと割合の字）。
private struct OpacityRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0.1...1

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - 要素

struct ETVisualizerInspectorView: View {
    @ObservedObject var editor: ETVisualizerEditorModel
    @ObservedObject private var pool = ETVisualizerJSFXPool.shared
    @Environment(\.dismiss) private var dismiss

    /// 選んでいる要素の設定。キャンバスで別の要素を選べば、そちらに替わる。
    var body: some View {
        let element = editor.selectedElement
        NavigationStack {
            Group {
                if let element { form(element) } else { Color.clear }
            }
            .navigationTitle(element?.kind.label ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: 束縛

    private func binding<T>(_ element: ETVisualizerElement, _ keyPath: WritableKeyPath<ETVisualizerElement, T>,
                            coalesce: String? = nil) -> Binding<T> {
        Binding(get: { element[keyPath: keyPath] },
                set: { value in change(element.id, coalesce: coalesce) { $0[keyPath: keyPath] = value } })
    }

    private func change(_ id: UUID, coalesce: String? = nil, _ body: @escaping (inout ETVisualizerElement) -> Void) {
        let layout = editor.layout
        editor.commit({ scene in
            guard let i = scene[layout].firstIndex(where: { $0.id == id }) else { return }
            body(&scene[layout][i])
        }, coalesce: coalesce.map { "\($0):\(id)" })
    }

    private func colorBinding(_ element: ETVisualizerElement) -> Binding<Color> {
        Binding(get: { element.color.swiftUIColor },
                set: { color in change(element.id, coalesce: "color") { $0.color = ETVisualizerColor(color) } })
    }

    /// 見た目を替えたら、色もその見た目の既定に戻す。
    private func lookBinding(_ element: ETVisualizerElement) -> Binding<ETVisualizerStyle> {
        Binding(get: { element.look },
                set: { look in
                    change(element.id) {
                        $0.look = look
                        $0.color = ETVisualizerElement.defaultColor(kind: $0.kind, look: look)
                    }
                })
    }

    // MARK: 中身

    @ViewBuilder
    private func form(_ element: ETVisualizerElement) -> some View {
        Form {
            switch element.kind {
            case .artwork:
                Section("Style") {
                    ETSegmentedChoice(title: "Look", values: ETVisualizerStyle.allCases, label: \.label,
                                      selection: lookBinding(element))
                }
                effects(element, meter: false)
            case .title, .artist:
                Section("Text") {
                    ColorPicker("Color", selection: colorBinding(element), supportsOpacity: false)
                    Picker("Font", selection: binding(element, \.font)) {
                        ForEach(ETVisualizerFont.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Toggle("Bold", isOn: binding(element, \.bold))
                    ETSegmentedChoice(title: "Alignment", values: ETVisualizerAlignment.allCases, label: \.label,
                                      selection: binding(element, \.alignment))
                }
                effects(element, meter: false)
            case .jsfx:
                jsfxSections(element)
            default:
                Section("Style") {
                    ETSegmentedChoice(title: "Look", values: ETVisualizerStyle.allCases, label: \.label,
                                      selection: lookBinding(element))
                    if showsColor(element) {
                        ColorPicker("Color", selection: colorBinding(element), supportsOpacity: false)
                    }
                    if element.kind == .spectrum && element.look == .effetune {
                        ETSegmentedChoice(title: "Display", values: ETSpectrumDisplay.allCases, label: \.label,
                                          selection: binding(element, \.spectrumDisplay))
                    }
                    if element.kind == .analogMeter {
                        ETSegmentedChoice(title: "Meter", values: ETAnalogMeterChoice.allCases, label: \.label,
                                          selection: binding(element, \.analogMode))
                    }
                }
                effects(element, meter: true)
            }
        }
    }

    /// 色が効かない描き方: スペクトログラム（量の色）、Classic の波形とステレオ（帯の色）。
    private func showsColor(_ element: ETVisualizerElement) -> Bool {
        if element.kind == .spectrogram { return false }
        if element.look == .classic && (element.kind == .waveform || element.kind == .stereo) { return false }
        return true
    }

    @ViewBuilder
    private func effects(_ element: ETVisualizerElement, meter: Bool) -> some View {
        Section("Effects") {
            Toggle("Card", isOn: binding(element, \.card))
            if meter {
                Toggle("Glow", isOn: binding(element, \.glow))
            }
            OpacityRow(title: "Opacity", value: binding(element, \.opacity, coalesce: "opacity"))
            if meter {
                Toggle("Flip Horizontal", isOn: binding(element, \.flipX))
                Toggle("Flip Vertical", isOn: binding(element, \.flipY))
            }
        }
    }

    // MARK: JSFX

    @ViewBuilder
    private func jsfxSections(_ element: ETVisualizerElement) -> some View {
        let payload = element.jsfx
        let info = pool.info[element.id]
        Section("JSFX") {
            LabeledContent("Script", value: ETJSFXHost.shared.entry(id: payload?.entryID ?? "")?.name ?? payload?.name ?? "")
            LabeledContent("Status", value: info?.status.label ?? "Stopped")
            Picker("Blend", selection: Binding(
                get: { element.jsfx?.blend ?? .normal },
                set: { blend in change(element.id) { $0.jsfx?.blend = blend } })) {
                ForEach(ETVisualizerBlend.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
        }
        if let parameters = info?.parameters, !parameters.isEmpty {
            Section("Parameters") {
                ForEach(parameters) { parameter in
                    parameterRow(parameter, element: element)
                }
            }
        }
        effects(element, meter: false)
    }

    @ViewBuilder
    private func parameterRow(_ parameter: ETJSFXHost.Parameter, element: ETVisualizerElement) -> some View {
        let current = element.jsfx?.sliders[parameter.id] ?? parameter.value
        if parameter.isEnumeration {
            // **Int(Double) を直に使わない。**スクリプトは NaN も 1e30 も書ける（ETJSFXLoader.enumIndex）。
            Picker(parameter.name, selection: Binding(
                get: { ETJSFXLoader.enumIndex(current, count: parameter.enumNames.count) },
                set: { editor.setJSFXSlider(element.id, index: parameter.id, value: Double($0)) })) {
                ForEach(Array(parameter.enumNames.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
            }
            .pickerStyle(.menu)
        } else if parameter.maximum > parameter.minimum {
            let runtime = pool.runtime(element.id)
            VStack(alignment: .leading) {
                Text(parameter.name)
                Slider(value: Binding(
                    get: { runtime?.normalized(parameter.id, current) ?? 0 },
                    set: { n in
                        guard let runtime else { return }
                        editor.setJSFXSlider(element.id, index: parameter.id,
                                             value: runtime.fromNormalized(parameter.id, n))
                    }), in: 0...1)
            }
        }
    }
}

// MARK: - Scene

/// 背景・カード・測る所。いま編集している場面（画面の Visualizer か Floating Meters）の。
struct ETVisualizerSceneSheet: View {
    @ObservedObject var editor: ETVisualizerEditorModel
    @ObservedObject private var settings = ETVisualizerSettings.shared
    @Environment(\.dismiss) private var dismiss

    private func background<T>(_ keyPath: WritableKeyPath<ETVisualizerBackground, T>,
                               coalesce: String? = nil) -> Binding<T> {
        Binding(get: { editor.editedScene.background[keyPath: keyPath] },
                set: { value in editor.commit({ $0.background[keyPath: keyPath] = value }, coalesce: coalesce) })
    }

    private func colorBinding(_ keyPath: WritableKeyPath<ETVisualizerBackground, ETVisualizerColor>,
                              coalesce: String) -> Binding<Color> {
        Binding(get: { editor.editedScene.background[keyPath: keyPath].swiftUIColor },
                set: { color in
                    editor.commit({ $0.background[keyPath: keyPath] = ETVisualizerColor(color) }, coalesce: coalesce)
                })
    }

    var body: some View {
        let kind = editor.editedScene.background.kind
        NavigationStack {
            Form {
                Section("Background") {
                    Picker("Background", selection: background(\.kind)) {
                        ForEach(ETVisualizerBackgroundKind.allCases.filter { $0 != .artwork || ETFeatures.visualizer }) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch kind {
                    case .solid:
                        ColorPicker("Color", selection: colorBinding(\.color, coalesce: "bgColor"), supportsOpacity: false)
                    case .gradient:
                        ColorPicker("Top", selection: colorBinding(\.color, coalesce: "bgColor"), supportsOpacity: false)
                        ColorPicker("Bottom", selection: colorBinding(\.color2, coalesce: "bgColor2"), supportsOpacity: false)
                    case .artwork:
                        ColorPicker("Color", selection: colorBinding(\.color, coalesce: "bgColor"), supportsOpacity: false)
                        OpacityRow(title: "Dim", value: background(\.dim, coalesce: "dim"), range: 0...0.9)
                    }
                }
                Section("Cards") {
                    ColorPicker("Color", selection: colorBinding(\.cardColor, coalesce: "cardColor"), supportsOpacity: false)
                    ColorPicker("Border", selection: colorBinding(\.cardBorder, coalesce: "cardBorder"), supportsOpacity: false)
                    OpacityRow(title: "Opacity", value: background(\.cardOpacity, coalesce: "cardOpacity"))
                }
                Section("Source") {
                    ETSegmentedChoice(title: "Source", values: ETVisualizerSource.allCases,
                                      label: \.label, selection: $settings.source)
                }
                if ETFeatures.visualizer {
                    Section("Song Recognition") {
                        ETRecognitionStatusRow()
                    }
                }
            }
            .navigationTitle("Scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// 曲の聞き取りの取得状況（デバッグ用。Debug と Beta だけ）。
/// 自分だけが ETSongRecognizer を観測して、編集画面の他の行を組み直さない。
struct ETRecognitionStatusRow: View {
    var body: some View {
        Text(ETSongRecognizer.shared.status)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
