//  VisualizerEditorView.swift
//  Visualizer の編集の持ち主（モデル）。編集画面（VisualizerView.swift）・キャンバス・インスペクタ・
//  追加・プリセットの画面が同じ 1 つを見る。
//
//  **設定を直に書き換える。**保存・取り消しの別枠は無い（Save / Cancel を置かない）。1 回の変更は全体の写しを
//  積んで（ETVisualizerHistory）、取り消し・やり直しで戻す。ドラッグ中は舞台（ETVisualizerStage）の下書きだけを
//  替え（preview）、離したときに 1 回だけ書く（commit）。
//
//  編集する相手は 2 つ。画面の Visualizer（settings.scene）と Floating Meters（settings.floating。縦横比つき）。
//  画面のほうは portrait / landscape のどちらの並びを編集するかを選べる（枠の形と違う向きを選ぶと、
//  その向きの形の枠にキャンバスを置く）。Floating Meters の並びは縦横比で決まる（9:16 だけ portrait）。

import Combine
import SwiftUI

enum ETVisualizerEditTarget: Hashable {
    case inApp, floating
}

/// 取り消しの 1 件。画面の場面と Floating Meters を一緒に写す（編集の相手を替えても戻せる）。
struct ETVisualizerEditorDocument: Equatable {
    var scene: ETVisualizerScene
    var floating: ETFloatingMetersScene
}

@MainActor
final class ETVisualizerEditorModel: ObservableObject {

    let stage = ETVisualizerStage()
    private let settings = ETVisualizerSettings.shared

    @Published var target: ETVisualizerEditTarget = .inApp {
        didSet {
            guard target != oldValue else { return }
            select(nil)
            syncStage()
        }
    }
    /// 画面の編集で、どちらの向きの並びを編集するか。キャンバスが枠の形を伝えるまでは nil で、伝わったらその形。
    @Published var editingLayout: ETVisualizerLayoutKey? {
        didSet {
            guard editingLayout != oldValue else { return }
            select(nil)
            syncStage()
        }
    }
    @Published private(set) var selection: UUID?
    @Published private(set) var editing = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var history = ETVisualizerHistory<ETVisualizerEditorDocument>(limit: 50)
    /// 画面の形（キャンバスが伝える）。
    private var physicalLayout: ETVisualizerLayoutKey?
    /// 設定が替わったら、これを観測する画面も組み直す（場面は設定が持っているので）。
    private var settingsSink: AnyCancellable?

    init() {
        settingsSink = settings.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    // MARK: 読む

    var document: ETVisualizerEditorDocument {
        ETVisualizerEditorDocument(scene: settings.scene, floating: settings.floating)
    }

    /// いま編集している場面。
    var editedScene: ETVisualizerScene { target == .inApp ? settings.scene : settings.floating.scene }

    /// いま編集している並び。
    var layout: ETVisualizerLayoutKey {
        switch target {
        case .inApp: return editingLayout ?? physicalLayout ?? .landscape
        case .floating: return settings.floating.layout
        }
    }

    /// 見える要素（曲を使えない版では曲の要素を除く）。重なりは配列の順（先頭が奥）。
    var elements: [ETVisualizerElement] { editedScene.elements(layout, allowsSong: ETFeatures.visualizer) }

    func element(_ id: UUID) -> ETVisualizerElement? { elements.first { $0.id == id } }

    var selectedElement: ETVisualizerElement? { selection.flatMap(element) }

    var floatingAspect: ETVisualizerAspect {
        get { settings.floating.aspect }
        set {
            var next = settings.floating
            next.aspect = newValue
            commitDocument(floating: next)
        }
    }

    // MARK: 状態

    func setEditing(_ on: Bool) {
        guard editing != on else { return }
        editing = on
        if !on {
            target = .inApp
            editingLayout = nil
            select(nil)
        }
        syncStage()
    }

    /// キャンバスが枠の形を伝える。いま枠の形を編集していた（まだ選んでいない、または前の枠の形のまま）なら、新しい形へ。
    func reportPhysical(_ layout: ETVisualizerLayoutKey) {
        if editingLayout == nil || editingLayout == physicalLayout { editingLayout = layout }
        physicalLayout = layout
    }

    func select(_ id: UUID?) {
        let next = id.flatMap { id in elements.contains { $0.id == id } ? id : nil }
        if selection != next { selection = next }
    }

    /// 舞台へ、いま編集している場面と向きを入れる。
    func syncStage() {
        let mode: ETVisualizerStage.Mode = target == .inApp ? .inApp : .floating(settings.floating.aspect)
        if stage.mode != mode { stage.mode = mode }
        stage.scene = editing ? editedScene : settings.scene
        stage.forcedLayout = editing ? layout : nil
        stage.placeholders = editing
    }

    // MARK: 書く

    private func write(_ scene: ETVisualizerScene) {
        switch target {
        case .inApp:
            settings.set(scene)
        case .floating:
            settings.set(ETFloatingMetersScene(aspect: settings.floating.aspect, scene: scene))
        }
    }

    private func updateHistoryFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// 場面を変える。変わらなければ何も積まない。同じ coalesce の鍵が 1 秒以内に続けば 1 回の取り消しにまとめる。
    func commit(_ change: (inout ETVisualizerScene) -> Void, coalesce: String? = nil) {
        let before = document
        var scene = editedScene
        change(&scene)
        scene = scene.normalized()
        if scene != editedScene {
            history.record(before, coalesce: coalesce, now: CACurrentMediaTime())
            write(scene)
            updateHistoryFlags()
        }
        // 下書き（ドラッグ中の矩形）を本物で上書きする。変わらなくても。
        select(selection)
        syncStage()
    }

    /// 縦横比のように、場面でなく文書全体を変えるもの。
    private func commitDocument(floating: ETFloatingMetersScene) {
        let before = document
        settings.set(floating)
        if document != before {
            history.record(before, coalesce: nil, now: CACurrentMediaTime())
            updateHistoryFlags()
        }
        syncStage()
    }

    /// ドラッグ・つまみ中の矩形を、設定に書かずに舞台だけへ見せる。
    func preview(_ rects: [UUID: ETVisualizerRect]) {
        var scene = editedScene
        scene[layout] = scene[layout].map { element in
            guard let rect = rects[element.id] else { return element }
            var copy = element
            copy.rect = rect
            return copy
        }
        stage.scene = scene
    }

    func undo() {
        guard let previous = history.undo(current: document) else { return }
        restore(previous)
    }

    func redo() {
        guard let next = history.redo(current: document) else { return }
        restore(next)
    }

    private func restore(_ document: ETVisualizerEditorDocument) {
        settings.set(document.scene)
        settings.set(document.floating)
        updateHistoryFlags()
        select(selection)
        syncStage()
    }

    // MARK: 要素

    func canAdd(_ kind: ETVisualizerElementKind) -> Bool {
        ETVisualizerEditing.canAdd(kind, to: editedScene[layout])
    }

    /// 足して選ぶ。いちばん手前に置く。
    func add(_ kind: ETVisualizerElementKind, jsfx entry: ETJSFXHost.Entry? = nil, canvas: CGSize) {
        guard canAdd(kind), canvas.width > 0, canvas.height > 0 else { return }
        let payload = entry.map { ETVisualizerJSFXElement(entryID: $0.id, name: $0.name) }
        guard kind != .jsfx || payload != nil else { return }
        let id = UUID()
        let layout = layout
        let aspect = Double(canvas.width / canvas.height)
        commit { scene in
            scene[layout].append(ETVisualizerEditing.newElement(kind, id: id, aspect: aspect, jsfx: payload))
        }
        select(id)
    }

    var canDuplicate: Bool {
        guard let element = selectedElement else { return false }
        return canAdd(element.kind)
    }

    func duplicateSelection() {
        guard let id = selection, canDuplicate else { return }
        let copy = UUID()
        let layout = layout
        commit { $0[layout] = ETVisualizerEditing.duplicate($0[layout], id, newID: copy) }
        select(copy)
    }

    func deleteSelection() {
        guard let id = selection else { return }
        let layout = layout
        commit { scene in scene[layout].removeAll { $0.id == id } }
        select(nil)
    }

    func arrange(_ op: ETVisualizerArrange) {
        guard let id = selection else { return }
        let layout = layout
        commit { $0[layout] = ETVisualizerEditing.arrange($0[layout], id, op) }
    }

    func canArrange(_ op: ETVisualizerArrange) -> Bool {
        guard let id = selection else { return false }
        return ETVisualizerEditing.canArrange(editedScene[layout], id, op)
    }

    /// もう一方の向きの並びを、いまの向きへ写す（id は振り直す）。
    func copyLayout(from other: ETVisualizerLayoutKey) {
        let layout = layout
        guard other != layout else { return }
        commit { scene in
            scene[layout] = scene[other].map { element in
                var copy = element
                copy.id = UUID()
                return copy
            }
        }
        select(nil)
    }

    /// プリセットを当てる。縦横比（Floating Meters）はそのまま。
    func apply(preset: ETVisualizerScene) {
        commit { $0 = preset.withFreshIDs() }
        select(nil)
    }

    /// JSFX のつまみ 1 つ。実値を要素に残し、動いている VM へも渡す。
    func setJSFXSlider(_ id: UUID, index: UInt32, value: Double) {
        guard value.isFinite else { return }
        ETVisualizerJSFXPool.shared.setSlider(id, index: index, value: value)
        let layout = layout
        commit({ scene in
            guard let i = scene[layout].firstIndex(where: { $0.id == id }) else { return }
            scene[layout][i].jsfx?.sliders[index] = value
        }, coalesce: "slider:\(id):\(index)")
    }
}
