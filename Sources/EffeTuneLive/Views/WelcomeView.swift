//  WelcomeView.swift
//  初回だけ出す案内。
//
//  このアプリは普通ではない形をしている。音を出すのは他のアプリで、
//  それを横取りする Media Device Extension はこのアプリが同梱していて
//  （project.yml の EffeTuneLive が EffeTuneLiveExtension を embed している）、
//  つなぐのはコントロールセンターの出力先。
//  黙っていると「音が来ない」で詰まるので、最初に一度だけ道筋を見せる。
//
//  **Bridge という別アプリはもう無い。** 以前は拡張を別アプリに入れていたが、
//  '!pla' の判定が本体の entitlement ひとつで決まると分かって 1 本になった。
//  案内に Bridge の話が無いのはそのため。

import Combine
import SwiftUI

struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    /// **観測しない。** tick() が 3.3Hz、pollTelemetry() が 30Hz で回るので、
    /// @ObservedObject にすると案内ぜんぶが毎秒作り直される。
    /// 読むのは hasPeer 1 つだけなので、下の LiveStatus に閉じ込めて
    /// そこで publisher から @State へ写す（PipelineView が io を @State へ写しているのと同じ扱い）。
    let io: AudioIO

    /// 初回の案内か、⋯ の「How it works」で開き直したか。
    /// PipelineView は初回だけ自動で出し、閉じたときにこれを立てる
    /// （PipelineView の welcomeSeen）。開き直したときに「Welcome / Start」と
    /// 出すと、何も始まらないのに始まりそうに読めるので、見出しを分ける。
    @AppStorage("welcome.seen") private var welcomeSeen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header

                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                        Step(number: i + 1, icon: step.icon,
                             title: step.title, detail: step.detail)
                    }

                    LiveStatus(io: io)
                }
                .padding(22)
            }
            .navigationTitle(welcomeSeen ? "How it works" : "Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(welcomeSeen ? "Done" : "Start") { dismiss() }
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

    /// 繋がっていれば、案内を読んでいる間に切り替わる。
    ///
    /// io を読むのはここだけ。この型の body しか作り直されないよう、
    /// 案内本体から切り離してある。
    private struct LiveStatus: View {
        let io: AudioIO
        @State private var hasPeer = false

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: hasPeer ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(hasPeer ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(hasPeer ? "Audio is coming in." : "Waiting for audio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial,
                        in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
            // 初期値は購読の初回配信に頼らず合わせる（PipelineView の onAppear と同じ）。
            .onAppear { hasPeer = io.hasPeer }
            .onReceive(io.$hasPeer) { hasPeer = $0 }
        }
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
        // 「ON バッジ」とは書かない。**そのバッジはもう無い。**
        // 鎖ぜんぶの入切はツールバー左上の電源ボタンで、カード 1 枚ずつのも
        // 同じ電源の絵（Components.swift の PowerToggleStyle）。
        StepSpec(icon: "slider.horizontal.3",
                 title: "Add effects",
                 detail: """
                         Tap + to browse. They run in order, top to bottom. The power button \
                         at the top left turns the whole chain off, so the sound passes \
                         through untouched.
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
