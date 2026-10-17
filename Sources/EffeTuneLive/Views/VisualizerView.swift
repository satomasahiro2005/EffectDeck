//  VisualizerView.swift
//  Visualizer の画面。全画面のカバー（PipelineView の .fullScreenCover）で出し、自分で作った場面
//  （Views/Visualizer/VisualizerScene.swift）を CoreGraphics の描き手が画面いっぱいに描く。
//  縦横比は選ばない（画面の形に従い、向きごとの並びを描く）。
//
//  見ているあいだ: 右上に 3 つのボタン（Presets・Edit・Close）。3 秒で隠れ、画面を叩くと出入りする。
//  編集: 同じ面をキャンバスにして、要素を足し、動かし、大きさを替え、重なりを替える（VisualizerEditorCanvas.swift）。
//  選んだ要素の設定はインスペクタ（VisualizerInspectorView.swift）。Floating Meters も同じ場面・同じ編集画面で、
//  上のセグメント（幅の狭い画面では下の Layout のメニュー）で編集の相手を替える。変えるとその場で保存され、見ている画面にも PiP にも効く。
//
//  出ていて、アプリが前にいるあいだだけ回る（面が止める）。説明文は置かない。

import SwiftUI

struct VisualizerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor = ETVisualizerEditorModel()
    @State private var chromeVisible = true
    /// 変えると隠すまでの数え直し（.task(id:)）。
    @State private var chromeToken = 0
    @State private var showPresets = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if editor.editing {
                ETVisualizerEditScreen(editor: editor)
            } else {
                viewer
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // 全画面の向きを固定していたら外す。iPhone だけ（ETInterfaceOrientation.rotates）。
            ETInterfaceOrientation.request(.all)
            // 撮影用に `-ETVisualizerRoute edit` で編集画面から開く。
            if UserDefaults.standard.string(forKey: "ETVisualizerRoute") == "edit" { editor.setEditing(true) }
            editor.syncStage()
#if DEBUG
            ETVisualizerSnapshot.runIfRequested()
#endif
        }
    }

    // MARK: 見る

    private var viewer: some View {
        ZStack {
            ETVisualizerSurfaceView(stage: editor.stage)
                .ignoresSafeArea()
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                    chromeToken += 1
                }
            // 安全領域の中。ボタン以外は叩きを通す。
            Color.clear
                .overlay(alignment: .topTrailing) {
                    if chromeVisible || showPresets {
                        HStack(spacing: 12) {
                            chromeButton("square.stack", "Presets") { showPresets = true }
                            chromeButton("pencil", "Edit") { editor.setEditing(true) }
                            chromeButton("xmark", "Close") { dismiss() }
                        }
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                        .transition(.opacity)
                    }
                }
        }
        .task(id: chromeToken) {
            guard chromeVisible, !showPresets else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = false }
        }
        // 閉じたら、また 3 秒数える。
        .onChange(of: showPresets) { _, _ in chromeToken += 1 }
        .sheet(isPresented: $showPresets) {
            // 当てた絵が見えるように、半分の高さで止められる（Scene・Inspector と同じ）。
            ETVisualizerPresetsView(target: .inApp, model: editor)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    private func chromeButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
        }
        .accessibilityLabel(label)
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }
}

// MARK: - 編集

private enum EditSheet: Identifiable {
    case add, presets, scene
    /// 選んでいる要素の設定。選びが替われば中身も替わる（要素は持たない）。
    case inspect

    var id: String {
        switch self {
        case .add: return "add"
        case .presets: return "presets"
        case .scene: return "scene"
        case .inspect: return "inspect"
        }
    }
}

private struct ETVisualizerEditScreen: View {
    @ObservedObject var editor: ETVisualizerEditorModel
    @State private var sheet: EditSheet?
    @State private var canvasSize = CGSize(width: 1, height: 1)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            ETVisualizerEditorCanvas(editor: editor, canvasSize: $canvasSize) { _ in sheet = .inspect }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { topBar }
                .toolbar { bottomBar }
        }
        // 選びが無くなった（空いた所を叩いた・相手や並びを替えた）ら、設定の画面は閉じる。空の Form を残さない。
        .onChange(of: editor.selection) { _, new in
            if new == nil, case .inspect? = sheet { sheet = nil }
        }
        // 提示は 1 枚だけ（同じ View に .sheet を重ねない）。
        .sheet(item: $sheet) { which in
            switch which {
            case .add:
                ETVisualizerElementPicker(editor: editor, canvas: canvasSize)
            case .presets:
                ETVisualizerPresetsView(target: editor.target, model: editor)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            case .scene:
                ETVisualizerSceneSheet(editor: editor)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            case .inspect:
                // 後ろのキャンバスを触れるままにして、動かしながら見られるようにする。
                ETVisualizerInspectorView(editor: editor)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
    }

    // MARK: 上

    @ToolbarContentBuilder
    private var topBar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("Undo", systemImage: "arrow.uturn.backward") { editor.undo() }
                .labelStyle(.iconOnly)
                .disabled(!editor.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { editor.redo() }
                .labelStyle(.iconOnly)
                .disabled(!editor.canRedo)
        }
        // 幅の狭い画面（iPhone の縦）では上の段に入らないので、下の Layout のメニューに入れる。
        if horizontalSizeClass == .regular {
            ToolbarItem(placement: .principal) {
                targetPicker
                    .pickerStyle(.segmented)
                    .fixedSize()
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                editor.select(nil)
                editor.setEditing(false)
            }
        }
    }

    // MARK: 下

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button("Add", systemImage: "plus") { sheet = .add }
                .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Presets", systemImage: "square.stack") { sheet = .presets }
                .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Scene", systemImage: "paintpalette") { sheet = .scene }
                .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .bottomBar) { layoutMenu }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { arrangeMenu }
        ToolbarItem(placement: .bottomBar) {
            Button("Duplicate", systemImage: "plus.square.on.square") { editor.duplicateSelection() }
                .labelStyle(.iconOnly)
                .disabled(!editor.canDuplicate)
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Delete", systemImage: "trash", role: .destructive) { editor.deleteSelection() }
                .labelStyle(.iconOnly)
                .disabled(editor.selection == nil)
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Inspect", systemImage: "slider.horizontal.3") {
                if editor.selection != nil { sheet = .inspect }
            }
            .labelStyle(.iconOnly)
            .disabled(editor.selection == nil)
        }
    }

    /// 画面の編集は向き（Portrait / Landscape）と、もう一方からの写し。Floating Meters は縦横比。
    private var layoutMenu: some View {
        Menu {
            if horizontalSizeClass != .regular {
                targetPicker
                    .pickerStyle(.inline)
                Divider()
            }
            if editor.target == .inApp {
                Picker("Layout", selection: Binding(get: { editor.layout }, set: { editor.editingLayout = $0 })) {
                    ForEach(ETVisualizerLayoutKey.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                let other: ETVisualizerLayoutKey = editor.layout == .portrait ? .landscape : .portrait
                Button("Copy from \(other.label)") { editor.copyLayout(from: other) }
            } else {
                Picker("Aspect Ratio", selection: Binding(get: { editor.floatingAspect },
                                                          set: { editor.floatingAspect = $0 })) {
                    ForEach(ETVisualizerAspect.choices(for: .floating)) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Layout", systemImage: "rectangle.portrait.rotate")
        }
    }

    private var targetPicker: some View {
        Picker("Target", selection: $editor.target) {
            Text("Visualizer").tag(ETVisualizerEditTarget.inApp)
            Text("Floating Meters").tag(ETVisualizerEditTarget.floating)
        }
    }

    private var arrangeMenu: some View {
        Menu {
            Button("Bring to Front") { editor.arrange(.front) }
                .disabled(!editor.canArrange(.front))
            Button("Bring Forward") { editor.arrange(.forward) }
                .disabled(!editor.canArrange(.forward))
            Button("Send Backward") { editor.arrange(.backward) }
                .disabled(!editor.canArrange(.backward))
            Button("Send to Back") { editor.arrange(.back) }
                .disabled(!editor.canArrange(.back))
        } label: {
            Label("Arrange", systemImage: "square.3.layers.3d")
        }
        .disabled(editor.selection == nil)
    }
}
