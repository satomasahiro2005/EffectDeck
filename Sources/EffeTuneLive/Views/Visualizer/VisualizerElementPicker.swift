//  VisualizerElementPicker.swift
//  要素を足す画面。メーター 7 種・曲の要素（曲の聞き取りが使える版だけ）・@gfx を持つ JSFX。
//  押すと足して選び、閉じる。入らない行（上限）は無効にして見せる。

import SwiftUI

struct ETVisualizerElementPicker: View {
    @ObservedObject var editor: ETVisualizerEditorModel
    @ObservedObject private var catalog = ETVisualizerJSFXCatalog.shared
    /// キャンバスの大きさ（点）。正方形の要素を点で正方形にするのに使う。
    let canvas: CGSize
    @Environment(\.dismiss) private var dismiss

    private static let meters: [ETVisualizerElementKind] = [
        .spectrum, .spectrogram, .waveform, .oscilloscope, .stereo, .levelMeter, .analogMeter,
    ]
    private static let song: [ETVisualizerElementKind] = [.artwork, .title, .artist]

    private func row(_ kind: ETVisualizerElementKind) -> some View {
        Button {
            editor.add(kind, canvas: canvas)
            dismiss()
        } label: {
            Text(kind.label)
        }
        // 色を決めずにボタンの色（無効なら薄く）に任せる。字を黒に戻す。
        .tint(.primary)
        .disabled(!editor.canAdd(kind))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Meters") {
                    ForEach(Self.meters) { row($0) }
                }
                if ETFeatures.visualizer {
                    Section("Song") {
                        ForEach(Self.song) { row($0) }
                    }
                }
                if !catalog.graphical.isEmpty {
                    Section("JSFX") {
                        ForEach(catalog.graphical) { entry in
                            Button {
                                editor.add(.jsfx, jsfx: entry, canvas: canvas)
                                dismiss()
                            } label: {
                                Text(entry.name)
                            }
                            .tint(.primary)
                            .disabled(!editor.canAdd(.jsfx))
                        }
                    }
                }
            }
            .navigationTitle("Add Element")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { catalog.refresh() }
        }
    }
}
