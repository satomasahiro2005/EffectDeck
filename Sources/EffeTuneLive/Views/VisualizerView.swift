//  VisualizerView.swift
//  試作の Visualizer。拡張から受けた音で曲を聞き取り、アートワークと曲名を出す
//  （聞き取りは Audio/SongRecognizer.swift。ETFeatures.visualizer が true のときだけ入口が出る）。
//
//  シートで出す（PipelineView.Sheet.visualizer）。出ていて、アプリが前にいるあいだだけ聞き取る。
//  聞き取れていないあいだは枠だけ。「聞いています」「見つかりません」のような字は出さない。

import SwiftUI

struct VisualizerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false

    private var recognizer: ETSongRecognizer { .shared }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                artwork
                if let song = recognizer.current {
                    VStack(spacing: 4) {
                        Text(song.title)
                            .font(.title2.weight(.semibold))
                        if let artist = song.artist {
                            Text(artist)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Visualizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { onScreen = true; update() }
        .onDisappear { onScreen = false; update() }
        .onChange(of: scenePhase) { update() }
    }

    private func update() {
        if onScreen && scenePhase == .active { recognizer.start() } else { recognizer.stop() }
    }

    /// 画像は AsyncImage の既定（URLSession.shared と URLCache.shared）に任せる。自前の置き場は持たない。
    private var artwork: some View {
        AsyncImage(url: recognizer.current?.artworkURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        // 曲が替わったら前の絵を引きずらず、枠から読み直す。
        .id(recognizer.current?.artworkURL)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 480, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            )
    }
}
