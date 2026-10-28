//  MatrixView.swift
//  Matrix。入力×出力の格子で経路を入切し（ON）、位相を反転する（Ø）。
//
//  上流は plugins/basics/matrix.js:
//      createUI                  :264-281  表だけを置く
//      _buildMatrixTable         :283-385  ヘッダは Output と Input、升は ON と Ø の 2 つ
//      generateRouting           :161-176  格子を mx へ。入力が外、出力が内の順
//      toggleCellActive          :206-218  切ると位相反転も一緒に落ちる
//      toggleCellPhaseInvert     :222-231  入っている升だけ反転できる
//      _displayChannelCount      :237-243  8 本。8 を超えるものがあれば 16 本
//      updateChannelAvailability :477-520  実際の本数を超えた行と升は薄くする
//  既定の経路は対角 2 本（matrix.js:105-111 の "0011"、params.json の default も同じ）。
//
//  テレメトリ: ETFrameType.channelCount = 9、formatVersion 1、payload は u32 が 1 本。
//  （matrix/kernel.cpp:14-15, 102-108 が書き、matrix.js:445-458 が同じ形を読む）
//  音が通るまで枠は出ない（kernel.cpp:103 が telemetry_channels_ == 0 で戻る）。
//  なので本数が分からないうちは薄くしない。
//
//  DSP へは mx の文字列ではなく matrix-routes-v1 の並びで渡す。
//  matrix/kernel.cpp:51-71（stageParameterBytes）が読む形:
//      0   u8   1        版。ここが 1 でないと ET_ERR_ARGS
//      1   u8   0
//      2   u16  本数     1024 まで
//      4+  u8×3 入力 / 出力 / 位相     長さは 4 + 本数*3 ちょうど
//  入力と出力は 15 まで、位相は 0 か 1。外れると 1 本でも全体が弾かれる。

import SwiftUI

struct MatrixView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    /// 入っている経路。鍵は 入力<<4 | 出力、値は位相反転。
    /// 鍵の順に並べると generateRouting（matrix.js:161-176）と同じ順になる。
    /// nil は「まだ置き場から取っていない」。取るのは cells。
    @State private var routes: [UInt8: Bool]?
    /// テレメトリで分かった本数。0 は枠がまだ来ていない。
    @State private var channels = 0

    private static let labelWidth: CGFloat = 52
    private static let headerHeight: CGFloat = 22
    /// 升は ON と Ø の 2 つぶん。押せる面を 44 まで広げるので倍になる。
    private static let cellWidth: CGFloat = ETMetrics.hitTarget * 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            grid
            ChannelCountProbe(tap: node.tapId, channels: $channels)
        }
        .onAppear {
            MatrixRouting.shared.prune(keeping: dsp.nodes.map(\.id))
            push(cells)
        }
        // 新しい instance は既定の対角で始まる（kernel.cpp のメンバ初期化）。
        // 画面に出ている経路と食い違うので、instance が変わったら入れ直す。
        // 2.14.0 までは reset（et_instance_reset・時間の巻き戻し・再開）でも対角へ戻り、
        // instance が変わらないのでここは動かず、画面だけ人の経路を出していた。2.15.0 で
        // reset は経路に触らなくなった（上流 basics/matrix/kernel.cpp。topology_native_test が見る）。
        .onChange(of: node.instance) { _, _ in push(cells) }
    }

    // MARK: 格子

    private var grid: some View {
        let size = gridSize
        return HStack(spacing: 0) {
            // 左の 1 列は固定。横に流れるのは出力側だけ（matrix.js は sticky 指定、
            // matrix.css:66-71 の .matrix-sticky-row）。
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: Self.labelWidth, height: Self.headerHeight)
                caption("Input")
                    .frame(width: Self.labelWidth, height: Self.headerHeight)
                    .overlay(alignment: .bottom) { rule }
                ForEach(Array(0..<size), id: \.self) { input in
                    channelLabel(input)
                        .frame(width: Self.labelWidth, height: ETMetrics.hitTarget)
                        .opacity(dim(input) ? 0.5 : 1)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    caption("Output")
                        .frame(width: CGFloat(size) * Self.cellWidth, height: Self.headerHeight)
                    HStack(spacing: 0) {
                        // 列の見出しは薄くしない。上流が disabled を付けるのは
                        // 行（tr）と升（td）だけで、thead には付けていない（matrix.js:487-519）。
                        ForEach(Array(0..<size), id: \.self) { output in
                            channelLabel(output)
                                .frame(width: Self.cellWidth, height: Self.headerHeight)
                        }
                    }
                    .overlay(alignment: .bottom) { rule }

                    ForEach(Array(0..<size), id: \.self) { input in
                        HStack(spacing: 0) {
                            ForEach(Array(0..<size), id: \.self) { output in
                                cell(input: input, output: output)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(input: Int, output: Int) -> some View {
        let key = Self.key(input, output)
        let phase = cells[key]
        return HStack(spacing: 0) {
            pad("ON", name: "Input \(input + 1) to output \(output + 1)", on: phase != nil) { toggleActive(key) }
            pad("Ø", name: "Invert phase, input \(input + 1) to output \(output + 1)",
                on: phase == true, heavy: true) { togglePhase(key) }
        }
        .frame(width: Self.cellWidth, height: ETMetrics.hitTarget)
        // 升は押せるままにしておく。上流も薄くするだけで外さない（matrix.js:500-519）。
        .opacity(dim(input) || dim(output) ? 0.5 : 1)
    }

    private func pad(_ label: String, name: String, on: Bool, heavy: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                // 升の幅は固定で広げられないので、文字サイズ設定には追従させず、
                // 大きな文字は長押しの拡大表示で読ませる。
                .font(.system(size: 11, weight: heavy ? .heavy : .bold))
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 36, height: 30)
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
                .frame(width: ETMetrics.hitTarget, height: ETMetrics.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityShowsLargeContentViewer()
        // 「ON」「Ø」だけでは、どの入力から出力への升か分からない。
        .accessibilityLabel(name)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private func channelLabel(_ channel: Int) -> some View {
        Text("Ch \(channel + 1)")
            .etFont(size: 11)
            .foregroundStyle(.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .etFont(size: 10, weight: .semibold)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private var rule: some View {
        Rectangle().fill(.quaternary).frame(height: 1)
    }

    /// 実際の本数を超えた行と升（matrix.js:487-519）。
    private func dim(_ channel: Int) -> Bool { channels > 0 && channel >= channels }

    /// matrix.js:237-243。8 本。入っている経路か実際の本数が 8 を超えたら 16 本。
    private var gridSize: Int {
        var required = channels
        for key in cells.keys {
            required = max(required, Int(key >> 4) + 1, Int(key & 0x0f) + 1)
        }
        return required > 8 ? 16 : 8
    }

    // MARK: 経路をいじる

    private static func key(_ input: Int, _ output: Int) -> UInt8 {
        UInt8(input << 4 | output)
    }

    private var cells: [UInt8: Bool] { routes ?? MatrixRouting.shared.routes(node.id) }

    /// matrix.js:206-218。切った升は位相反転も落とす。
    private func toggleActive(_ key: UInt8) {
        var next = cells
        if next.removeValue(forKey: key) == nil { next[key] = false }
        update(next)
    }

    /// matrix.js:222-231。入っている升だけ反転できる。
    private func togglePhase(_ key: UInt8) {
        guard let phase = cells[key] else { return }
        var next = cells
        next[key] = !phase
        update(next)
    }

    private func update(_ next: [UInt8: Bool]) {
        routes = next
        MatrixRouting.shared.set(next, for: node.id)
        push(next)
    }

    // MARK: DSP へ渡す

    private func push(_ routes: [UInt8: Bool]) {
        MatrixRouting.push(routes, node: node, engine: dsp.engine)
    }

    // MARK: 枠を読む

    /// Telemetry を見るのはここだけ。格子ごと 30Hz で作り直さないよう、
    /// 本数が変わったときだけ外へ渡す。
    private struct ChannelCountProbe: View {

        let tap: UInt32
        @Binding var channels: Int

        @ETTelemetryFeed private var telemetry

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear { channels = count }
                .onChange(of: count) { _, now in channels = now }
        }

        /// matrix.js:445-458 と同じ門。u32 が 1 本だけ、1..16。
        private var count: Int {
            guard let frame = telemetry.frame(tap: tap, type: .channelCount),
                  frame.matches(version: 1),
                  frame.hasPayload(bytes: 4),
                  let n = frame.payloadView.u32(at: 0),
                  n >= 1, n <= 16 else { return 0 }
            return Int(n)
        }
    }
}

/// 経路の置き場。
///
/// mx は文字列なので float の並びである Node.values に入らず、いまは Node にも
/// PipelineStore にも席が無い。カードを畳むと View ごと消えるため、@State に置くと
/// 開き直した格子だけ既定へ戻り、カーネルには人が入れた経路が残る、という
/// 食い違いが出る。席ができるまでの仮置き。
///
/// 鍵は Node.id。鎖から外れた段のぶんは、開いたときに捨てる。
@MainActor
final class MatrixRouting {

    static let shared = MatrixRouting()

    /// 既定は対角 2 本。matrix.js:105-111 と params.json の default（"0011"）、
    /// カーネルのメンバ初期化（kernel.cpp。2.15.0 で reset から移った）が同じものを置いている。
    static let initial: [UInt8: Bool] = [0x00: false, 0x11: false]

    private var byNode: [UUID: [UInt8: Bool]] = [:]

    private init() {}

    func routes(_ id: UUID) -> [UInt8: Bool] { byNode[id] ?? Self.initial }

    func set(_ routes: [UInt8: Bool], for id: UUID) { byNode[id] = routes }

    func prune(keeping ids: [UUID]) {
        let live = Set(ids)
        byNode = byNode.filter { live.contains($0.key) }
    }

    /// 既定の対角へ戻してカーネルへも送る。上流の Reset は mx を足した時の値へ戻す
    /// （pipeline-item-builder.js:392-410、既定は matrix.js:105-111）。
    /// 畳んだカードにはビューが無いので、送るのはここでやる。
    func reset(_ node: EffeTuneDSP.Node, engine: UInt32) {
        byNode[node.id] = nil
        Self.push(Self.initial, node: node, engine: engine)
    }

    /// kernel.cpp:51-71 が読む並びに詰める。本数は 1024 まで。
    static func packed(_ routes: [UInt8: Bool]) -> [UInt8] {
        let keys = routes.keys.sorted().prefix(1024)
        var bytes: [UInt8] = [1, 0, UInt8(keys.count & 0xff), UInt8(keys.count >> 8)]
        bytes.reserveCapacity(4 + keys.count * 3)
        for key in keys {
            bytes.append(key >> 4)
            bytes.append(key & 0x0f)
            bytes.append(routes[key] == true ? 1 : 0)
        }
        return bytes
    }

    static func push(_ routes: [UInt8: Bool], node: EffeTuneDSP.Node, engine: UInt32) {
        guard engine != 0, node.instance != 0 else { return }
        let bytes = packed(routes)
        _ = bytes.withUnsafeBufferPointer {
            et_instance_set_param_bytes(engine, node.instance, $0.baseAddress,
                                        UInt32(bytes.count), node.spec.paramsHash, 0)
        }
    }
}
