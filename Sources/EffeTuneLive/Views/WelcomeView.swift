//  WelcomeView.swift
//  初回だけ出す案内。
//
//  このアプリは普通ではない形をしている。音を出すのは他のアプリで、
//  それを横取りする仕掛けは別のアプリ（EffeTune Live Bridge）に入っていて、
//  つなぐのはコントロールセンターの出力先。
//  黙っていると「音が来ない」で詰まるので、最初に一度だけ道筋を見せる。
//
//  Bridge は入れるだけでよい（開かなくても拡張は登録される。実機で確認済み）。
//  だから「Bridge を開いてください」とは言わない。

import SwiftUI

struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var io: AudioIO

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header

                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                        Step(number: i + 1, icon: step.icon,
                             title: step.title, detail: step.detail)
                    }

                    liveStatus
                }
                .padding(22)
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EffeTune Live puts effects on the audio from other apps.")
                .font(.title3.weight(.semibold))
            Text("""
                 Whatever is playing — music, video, a podcast — passes through the same \
                 effects as the desktop version of EffeTune, and comes back out of whatever \
                 you are listening on.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 繋がっていれば、案内を読んでいる間に緑になる。
    private var liveStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: io.hasPeer ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(io.hasPeer ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(io.hasPeer ? "Audio is coming in." : "Waiting for audio.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }

    private struct StepSpec {
        let icon: String
        let title: String
        let detail: String
    }

    private static let steps: [StepSpec] = [
        StepSpec(icon: "play.circle",
                 title: "Play something in another app",
                 detail: "Any app works. EffeTune Live does not play anything itself."),
        StepSpec(icon: "airplayaudio",
                 title: "Open Control Center and pick EffeTune as the output",
                 detail: """
                         EffeTune shows up there like a speaker. Picking it sends that app's \
                         audio here instead.
                         """),
        StepSpec(icon: "slider.horizontal.3",
                 title: "Add effects",
                 detail: """
                         Tap + to browse. They run in order, top to bottom. Turning off the ON \
                         badge at the top lets the sound through untouched.
                         """),
    ]

    private struct Step: View {
        let number: Int
        let icon: String
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(.quaternary)
                    Image(systemName: icon).font(.system(size: 17))
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(number). \(title)")
                        .font(.system(size: 15, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
