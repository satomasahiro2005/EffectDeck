//  VisualizerView.swift
//  Visualizer の画面。CoreGraphics の描き手（Views/Visualizer/）が画面いっぱいに描く。
//  どのパネルを出すか・並び順・縦横比・見た目は右上の Customize で替える（Floating Meters と同じ設定の形）。
//
//  シートで出す（PipelineView.Sheet.visualizer）。出ていて、アプリが前にいるあいだだけ回る。
//  曲名と歌手名は出さない（Dynamic Island に出ている）。アートワークはパネルの 1 つで、
//  曲の聞き取りが使える版（ETFeatures.visualizer）でだけ出る。

import SwiftUI

struct VisualizerView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Route: Hashable {
        case customize
    }

    /// 撮影用に `-ETVisualizerRoute customize` で設定の画面から開く。
    @State private var path: [Route] = UserDefaults.standard.string(forKey: "ETVisualizerRoute") == "customize"
        ? [.customize] : []

    var body: some View {
        NavigationStack(path: $path) {
            ETVisualizerSurfaceView(surface: .inApp)
                // 舞台は安全領域の中に置き（Dynamic Island やホームインジケータの下に潜らせない）、
                // 背景の黒だけ端まで広げる。
                .background { Color.black.ignoresSafeArea(edges: [.bottom, .horizontal]) }
                .navigationTitle("Visualizer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink(value: Route.customize) {
                            Label("Customize", systemImage: "slider.horizontal.3")
                        }
                    }
                }
                .navigationDestination(for: Route.self) { _ in
                    ETVisualizerEditorView()
                }
        }
        // 全画面の向きを固定していたら外す。iPhone だけ（ETInterfaceOrientation.rotates）。
        .onAppear {
            ETInterfaceOrientation.request(.all)
#if DEBUG
            ETVisualizerSnapshot.runIfRequested()
#endif
        }
    }
}
