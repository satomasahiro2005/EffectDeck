//  VisualizerEditorView.swift
//  Visualizer の編集画面。アプリの中の画面と Floating Meters を同じ部品で替える。
//  標準の List / Toggle / セグメントだけで、縦横比・見た目・出すパネルと並び順を変える。
//  変えるとその場で保存され、見本にも PiP にも効く。
//
//  並べ替えは長押しで掴む（Edit は置かない。PresetsView と同じ）。
//  アートワークは曲の聞き取りが使える版（ETFeatures.visualizer）でしか出ない。
//  観測するのは設定だけで、フレームごとの値は見ない（見本の面が自分で回す）。

import SwiftUI

struct ETVisualizerEditorView: View {
    @ObservedObject private var settings = ETVisualizerSettings.shared
    @State private var surface: ETVisualizerSurface = .inApp

    private var config: ETVisualizerConfig { settings.config(surface) }

    var body: some View {
        List {
            Section {
                ETVisualizerSurfaceView(surface: surface, preview: true)
                    .id(surface)
                    .aspectRatio(previewRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.black)
            }
            Section {
                Picker("Surface", selection: $surface) {
                    Text("Visualizer").tag(ETVisualizerSurface.inApp)
                    Text("Floating Meters").tag(ETVisualizerSurface.floating)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Layout") {
                ETSegmentedChoice(title: "Aspect Ratio", values: ETVisualizerAspect.choices(for: surface),
                                  label: \.label, selection: binding(\.aspect))
                ETSegmentedChoice(title: "Style", values: ETVisualizerStyle.allCases,
                                  label: \.label, selection: binding(\.style))
            }
            Section("Panels") {
                ForEach(visiblePanels) { panel in
                    Toggle(panel.kind.label, isOn: panelBinding(panel.kind))
                        .disabled(panel.isOn && onCount == 1)
                }
                .onMove(perform: move)
            }
            if isOn(.spectrum) && config.style == .effetune {
                Section("Spectrum") {
                    ETSegmentedChoice(title: "Display", values: ETSpectrumDisplay.allCases,
                                      label: \.label, selection: binding(\.spectrumDisplay))
                }
            }
            if isOn(.analogMeter) {
                Section("Analog Meter") {
                    ETSegmentedChoice(title: "Mode", values: ETAnalogMeterChoice.allCases,
                                      label: \.label, selection: binding(\.analogMode))
                }
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
        .navigationTitle("Customize")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 見本

    /// 見本の形。Floating Meters は PiP の器と同じ形、Fit は窓の形。
    private var previewRatio: Double {
        if surface == .floating {
            let size = ETVisualizerLayout.pipPixelSize(config.aspect.ratio ?? 5)
            return Double(size.0) / Double(size.1)
        }
        if let ratio = config.aspect.ratio { return ratio }
        if let last = ETVisualizerLayerView.lastInAppFitRatio { return last }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.bounds.size ?? CGSize(width: 16, height: 9)
        return ETVisualizerLayout.fitRatio(width: Double(window.width), height: Double(window.height))
    }

    // MARK: パネル

    /// 出せるパネル。アートワークは曲の聞き取りが使える版でだけ。
    private func isVisible(_ panel: ETVisualizerPanel) -> Bool {
        panel.kind != .artwork || ETFeatures.visualizer
    }

    private var visiblePanels: [ETVisualizerPanel] { config.panels.filter(isVisible) }

    /// 入っているパネルの数。最後の 1 つは切れない（何も出ない画面にしない）。
    private var onCount: Int { visiblePanels.filter(\.isOn).count }

    private func isOn(_ kind: ETVisualizerPanelKind) -> Bool {
        config.panels.contains { $0.kind == kind && $0.isOn }
    }

    private func panelBinding(_ kind: ETVisualizerPanelKind) -> Binding<Bool> {
        Binding(get: { isOn(kind) },
                set: { on in
                    var next = config
                    if let index = next.panels.firstIndex(where: { $0.kind == kind }) { next.panels[index].isOn = on }
                    settings.set(next, for: surface)
                })
    }

    /// 並べ替え。出ていないパネル（Release のアートワーク）は動かさず、後ろに付ける。
    private func move(_ source: IndexSet, to destination: Int) {
        var visible = visiblePanels
        let hidden = config.panels.filter { !isVisible($0) }
        visible.move(fromOffsets: source, toOffset: destination)
        var next = config
        next.panels = visible + hidden
        settings.set(next, for: surface)
    }

    /// 設定の 1 つの項目を、保存しながら替える束縛。
    private func binding<Value>(_ keyPath: WritableKeyPath<ETVisualizerConfig, Value>) -> Binding<Value> {
        Binding(get: { config[keyPath: keyPath] },
                set: { value in
                    var next = config
                    next[keyPath: keyPath] = value
                    settings.set(next, for: surface)
                })
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
