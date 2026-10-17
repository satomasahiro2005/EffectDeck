//  VisualizerPresetsView.swift
//  場面のプリセット。上から: 今の場面を名前を付けて保存、自分で保存した場面（User Presets）、組み込みの場面（System Presets）。
//  作りは PresetsView.swift に合わせる（保存の行・スワイプの Delete / Overwrite / Rename・確認の .alert）。
//
//  押すと今編集している場面に当てる（取り消し 1 回で戻る）。シートは閉じない。Floating Meters のときは縦横比を変えない。
//  曲を使う組み込みの場面（Now Playing）は曲の聞き取りが使える版でだけ出る。

import SwiftUI

struct ETVisualizerPresetsView: View {
    let target: ETVisualizerEditTarget
    @ObservedObject var model: ETVisualizerEditorModel
    @ObservedObject private var settings = ETVisualizerSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    /// 出している 1 枚。**書いてもその場では出さない。**出ているものが閉じてから出る
    /// （ETAlertQueue。PresetsView と同じ。名前を打たせる .alert の Save から断りを出すため）。
    private var dialog: Dialog? {
        get { dialogs.current }
        nonmutating set {
            if let newValue { dialogs.present(newValue) } else { dialogs.dismissed() }
        }
    }
    @State private var dialogs = ETAlertQueue<Dialog>()
    private var dialogShown: Binding<Bool> {
        let ticket = dialogs.ticket
        return Binding(get: { dialogs.current != nil },
                       set: { if !$0 { dialogs.closed(ticket) } })
    }
    @State private var renaming: String?
    @State private var typed = ""

    private enum Dialog: Identifiable {
        case delete(String)
        case overwrite(String)
        case failed(String)

        var id: String {
            switch self {
            case .delete(let name): return "delete:" + name
            case .overwrite(let name): return "overwrite:" + name
            case .failed(let why): return "failed:" + why
            }
        }

        var title: String {
            switch self {
            case .delete(let name): return "Delete “\(name)”?"
            case .overwrite(let name): return "Overwrite “\(name)”?"
            case .failed: return "Could not rename"
            }
        }

        var message: String {
            switch self {
            case .delete: return "This cannot be undone."
            case .overwrite: return "The saved scene is overwritten with the scene you have now."
            case .failed(let why): return why
            }
        }
    }

    private var currentScene: ETVisualizerScene {
        target == .inApp ? settings.scene : settings.floating.scene
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sortedUserScenes: [ETVisualizerScene] {
        settings.userScenes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func row(_ scene: ETVisualizerScene) -> some View {
        Button {
            model.apply(preset: scene)
        } label: {
            HStack {
                Text(scene.name).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if currentScene.sameLook(as: scene) {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    /// 名前を替える。重なる名前なら断る（PresetsView の Rename と同じ）。
    private func rename(_ old: String, to typed: String) {
        let name = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty, name != old else { return }
        if !settings.renameUserScene(old, to: name) {
            dialog = .failed("There is already a scene called “\(name)”.")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Scene name", text: $newName)
                            .textInputAutocapitalization(.words)
                        Button("Save") {
                            settings.saveUserScene(currentScene, name: trimmedName)
                            newName = ""
                        }
                        .disabled(trimmedName.isEmpty)
                    }
                } header: {
                    Text("Save current scene")
                } footer: {
                    // 同じ名前で保存すると前のものが黙って消えるので、押す前に言う。
                    if !trimmedName.isEmpty && settings.userScenes.contains(where: { $0.name == trimmedName }) {
                        Text("A scene named “\(trimmedName)” already exists. Saving replaces it.")
                    }
                }
                Section("User Presets") {
                    if settings.userScenes.isEmpty {
                        Text("No saved scenes")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedUserScenes, id: \.name) { scene in
                            row(scene)
                                // 先に書いたものが端に近い側へ出る。左から Rename / Overwrite / Delete と読める。
                                // 完全スワイプで消さない（allowsFullSwipe: false）。
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Delete", role: .destructive) { dialog = .delete(scene.name) }
                                    Button("Overwrite") { dialog = .overwrite(scene.name) }
                                        .tint(.blue)
                                    Button("Rename") {
                                        typed = scene.name
                                        renaming = scene.name
                                    }
                                    .tint(.indigo)
                                }
                        }
                    }
                }
                Section("System Presets") {
                    ForEach(ETVisualizerPresets.available(allowsSong: ETFeatures.visualizer)) { preset in
                        row(preset.scene)
                    }
                }
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // 提示は 1 枚ずつ。確認と名前を打たせるのは出す条件が重ならない。
            .alert(dialog?.title ?? "",
                   isPresented: dialogShown,
                   presenting: dialog) { what in
                switch what {
                case .delete(let name):
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) { settings.deleteUserScene(named: name) }
                case .overwrite(let name):
                    Button("Cancel", role: .cancel) {}
                    Button("Overwrite", role: .destructive) { settings.saveUserScene(currentScene, name: name) }
                case .failed:
                    Button("OK", role: .cancel) {}
                }
            } message: { what in
                Text(what.message)
            }
            .alert("Rename scene",
                   isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { old in
                TextField("Name", text: $typed)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Save") { rename(old, to: typed) }
            }
            // 出ていた 1 枚が消えた回に鳴り、次の 1 枚を出すのはその次の回（AlertQueue.swift）。
            .onChange(of: dialogs.canAdvance) { _, ready in
                if ready { Task { @MainActor in dialogs.advance() } }
            }
        }
    }
}
