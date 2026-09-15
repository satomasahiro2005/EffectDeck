//  PipelineView.swift
//  本画面。EffeTune の Effect Pipeline にあたる。
//
//  EffeTune との違いと、その理由:
//    - 左のエフェクト一覧は常時は出さない。iPhone の幅では鎖が読めなくなるので + から出す
//    - 再生の開始/停止は持たない。拡張が繋がったら自分で鳴らし始める。
//      鎖を切りたいときは頭の ON を切る（素通しになる）
//    - レベルメーターは下の帯に置かない。要る人は Level Meter を鎖に入れる
//    - Section を畳むと配下の**行ごと**消える。上流はパラメータの表示を畳むだけで
//      行は残る（js/ui/pipeline/pipeline-item-builder.js:795-836）。
//      横に並べられない幅なので、ここだけ変えてある

import Combine
import SwiftUI

struct PipelineView: View {
    /// **io は観測しない。@StateObject にしてはいけない。**
    ///
    /// tick() が 3.3Hz、pollTelemetry() が 30Hz で回る。観測すると
    /// AudioIO が publish するたびに body ごと作り直され、作り直されている間
    /// Menu は提示を終えられない。実機で ⋯ が "Loading…" のまま固まり、
    /// XCUITest で exists=true / enabled=true / hittable=false になっていたのがこれ。
    /// 画面に要る 3 つの値だけを、下で publisher から @State へ写す。
    private let io = AudioIO.shared
    @StateObject private var dsp = EffeTuneDSP.shared

    /// 出しているシート。
    ///
    /// 同じビューに .sheet を何枚も積むと、後から付けたものが効かなくなる。
    /// 実機で ⋯ の項目が全部押せなくなったのがそれ。ひとつにまとめる。
    /// ツールバーを別の型へ出したので、その型からも見えるところに置く。
    enum Sheet: String, Identifiable {
        case picker, settings, routing, presets, welcome, ir
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?
    @AppStorage("welcome.seen") private var welcomeSeen = false
    /// 開いている段。中身は EffeTuneDSP が持っている（足す・入れ替えるを握っているのが
    /// あちらで、端末に残すのも persist() なので）。Section もここに入り、
    /// その場合は自分のパラメータではなく配下の行が消える（下の rows）。
    private var expanded: Set<UUID> {
        get { dsp.expanded }
        nonmutating set { dsp.expanded = newValue }
    }


    /// io から写した値。AudioIO.tick() が同じ値の代入をやめたので、
    /// ここへ届くのは本当に変わったときだけ。初期値は onAppear で合わせる。
    @State private var running = false
    @State private var hasPeer = false
    @State private var processingRate: Double = 48000

    /// 図を動かすための速い方。DSP が 30Hz で吐いているのでそれに合わせる。
    private let fast = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    /// 状態の見直し。ルートの問い合わせなど重いものはこちら。
    private let slow = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            chainList
                // 撮影のときだけ iPhone の幅に絞る。
                // iPad で撮るのは高さが要るからで、幅まで iPad になると
                // 実機の見え方にならない。
                .frame(maxWidth: ETScreenshotSeed.requested == nil
                                 ? .infinity : ETScreenshotSeed.phoneWidth)
                .frame(maxWidth: .infinity)
            // タイトルは出さない。アプリの中でアプリ名を読む人は居ないし、
            // その 1 行ぶん鎖が見える。
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { PipelineToolbar(sheet: $sheet, dsp: dsp, io: io, hasPeer: hasPeer) }
            .sheet(item: $sheet) { which in
                switch which {
                case .picker:
                    EffectPickerView { spec in dsp.add(spec) }
                case .settings:
                    SettingsView(io: io)
                case .routing:
                    RoutingView(dsp: dsp)
                case .presets:
                    PresetsView(dsp: dsp)
                case .welcome:
                    WelcomeView(io: io)
                case .ir:
                    IRLibraryView()
                }
            }
            .onChange(of: sheet) { old, now in
                if old == .welcome && now == nil { welcomeSeen = true }
            }
            .onAppear {
                // 画面を撮るときは案内を出さない。後ろが見えなくなるので。
                if !welcomeSeen && ETScreenshotSeed.requested == nil { sheet = .welcome }
                // 写した値の初期合わせ。購読の初回配信に頼らない。
                running = io.running
                hasPeer = io.hasPeer
                processingRate = io.processingRate
            }
        }
        .onReceive(fast) { _ in io.pollTelemetry() }
        .onReceive(slow) { _ in io.tick() }
        // io を丸ごと観測せず、要る値だけを写す。
        .onReceive(io.$running) { running = $0 }
        .onReceive(io.$hasPeer) { hasPeer = $0 }
        .onReceive(io.$processingRate) { processingRate = $0 }
    }

    private var chainList: some View {

        List {
            ClipboardBanner(dsp: dsp)
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if !hasPeer {
                ConnectBanner()
                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if dsp.chain.isEmpty {
                EmptyChainRow { sheet = .picker }
                    .listRowInsets(EdgeInsets(top: 20, leading: 14, bottom: 20, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(rows) { row in
                    EffectCardView(
                        index: row.index,
                        node: row.node,
                        dsp: dsp,
                        isExpanded: expanded.contains(row.node.id),
                        toggleExpanded: {
                            if expanded.contains(row.node.id) { expanded.remove(row.node.id) }
                            else { expanded.insert(row.node.id) }
                        })
                        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id(row.node.id)
                }
                .onDelete { offsets in
                    dsp.remove(at: chainIndices(of: offsets))
                }
                .onMove { source, destination in
                    move(source, to: destination)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
    }

    // MARK: - 行の組み立て

    /// 画面に出す 1 行。落とす行があるので、鎖の中の位置を一緒に持つ。
    /// EffectCardView は index で dsp を触る（setValue など）ため、
    /// ここがずれると別のエフェクトを書き換える。
    private struct Row: Identifiable {
        let index: Int
        let node: EffeTuneDSP.Node
        var id: UUID { node.id }
    }

    /// 畳んでいる Section の配下を落としたもの。
    ///
    /// 隠す範囲は Section の次から、次の Section の手前まで。上流が音を止める
    /// 範囲と同じ区切り方にしてある（js/audio/dsp-pipeline-descriptor.js:190-201、
    /// 区切りは入れ子にならず、次の Section に当たったらそこで切り替わる）。
    private var rows: [Row] {
        let types = dsp.chain.map(\.spec.type)
        var hidden: Set<Int> = []
        for i in dsp.chain.indices
        where dsp.chain[i].isSection && !expanded.contains(dsp.chain[i].id) {
            hidden.formUnion(ETSection.range(after: i, types: types))
        }
        return dsp.chain.indices
            .filter { !hidden.contains($0) }
            .map { Row(index: $0, node: dsp.chain[$0]) }
    }

    /// 帯に出す本数。Section は音を触らないので数に入れない。
    private var effectCount: Int {
        dsp.chain.filter { !$0.isSection }.count
    }

    /// 画面の行番号を鎖の位置へ戻す。
    private func chainIndices(of offsets: IndexSet) -> IndexSet {
        let visible = rows
        return IndexSet(offsets.compactMap { visible.indices.contains($0) ? visible[$0].index : nil })
    }

    /// 長押しで動かしたときの置き換え。
    ///
    /// 畳んでいる Section を動かすときは、隠れている配下も一緒に運ぶ。
    /// 見えていないものを置き去りにすると、開くまで気づけないため。
    /// 開いている Section は行 1 つだけ動く（上流の普通のドラッグと同じ。
    /// 範囲ごと動かすのは上流でも Shift+Click の側で、
    /// js/ui/pipeline/pipeline-section-handler.js:78-186 がそれ）。
    private func move(_ source: IndexSet, to destination: Int) {
        let visible = rows
        let types = dsp.chain.map(\.spec.type)

        var moving = IndexSet()
        var dragged: Set<UUID> = []      // 掴んだ行だけ。連れて行く配下は入れない
        for offset in source {
            guard visible.indices.contains(offset) else { continue }
            let i = visible[offset].index
            moving.insert(i)
            dragged.insert(visible[offset].node.id)
            if visible[offset].node.isSection && !expanded.contains(visible[offset].node.id) {
                moving.formUnion(IndexSet(integersIn: ETSection.range(after: i, types: types)))
            }
        }
        guard !moving.isEmpty else { return }

        let target = visible.indices.contains(destination) ? visible[destination].index
                                                           : dsp.chain.count
        dsp.move(from: moving, to: target)
        reveal(dragged)
    }

    /// 掴んだ行が畳んだ Section の中に入ったら、その Section を開く。
    ///
    /// 畳んだ Section の下へ落とすと配下に入る。隠す範囲に入った以上そのままでは
    /// 行が消え、どこへ行ったのか分からなくなる。上流は行が残るので起きない。
    /// 連れて行った配下は対象にしない。Section ごと動かしたときに、
    /// 畳んだままにしていたものが勝手に開いてしまうため。
    private func reveal(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let types = dsp.chain.map(\.spec.type)
        for i in dsp.chain.indices
        where dsp.chain[i].isSection && !expanded.contains(dsp.chain[i].id) {
            let inside = ETSection.range(after: i, types: types)
            if inside.contains(where: { ids.contains(dsp.chain[$0].id) }) {
                expanded.insert(dsp.chain[i].id)
            }
        }
    }
}

/// ツールバー。開いている Menu を守るために、本体から切り離してある。
///
/// 中身は sheet の指定しか要らない。親の body が別の理由（鎖の編集など）で
/// 作り直されても、渡す値が同じなら SwiftUI はここを評価し直さないので、
/// 提示の途中の Menu が作り直されずに済む。io は一切読まない。
private struct PipelineToolbar: ToolbarContent {
    @Binding var sheet: PipelineView.Sheet?
    @ObservedObject var dsp: EffeTuneDSP
    let io: AudioIO
    /// 拡張が繋がっているか。繋がっていないあいだマスターを沈める。
    let hasPeer: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // 鎖ごとの入切。帯を無くしたのでここへ。
            //
            // 音が来ていないあいだは沈めて出す。**bypass は触らない。**
            // 見た目だけの話で、鎖の入切は人が決めた値のまま残す。
            // ここで bypass を立てると、繋がった瞬間に素通しで鳴り始めて、
            // なぜ効かないのか分からなくなる。
            // 押せるままにしてあるのは、繋ぐ前に切っておきたいことがあるため。
            Toggle("Effects", isOn: Binding(get: { !dsp.bypass },
                                            set: { dsp.bypass = !$0 }))
                .toggleStyle(.power)
                .labelsHidden()
                .scaleEffect(0.7, anchor: .center)
                .grayscale(hasPeer ? 0 : 1)
                .opacity(hasPeer ? 1 : 0.4)
                .animation(.easeInOut(duration: 0.2), value: hasPeer)
                .accessibilityLabel("Effect pipeline")
                .accessibilityValue(hasPeer ? "" : "No audio")
        }
        ToolbarItem(placement: .principal) {
            // 帯を 1 行使うのをやめて、ナビゲーションの中に入れた。
            // 観測するのはこのビューだけ。
            LiveStatusStrip(io: io)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Presets", systemImage: "square.stack") { sheet = .presets }
            Button("Add Effect", systemImage: "plus") { sheet = .picker }
            // IR Library はここに出さない。IR Reverb のカードから開く。
            Menu {
                Button("Settings", systemImage: "gearshape") { sheet = .settings }
                Button("Routing", systemImage: "arrow.triangle.branch") { sheet = .routing }
                Button("How it works", systemImage: "questionmark.circle") { sheet = .welcome }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("moreMenu")
        }
    }
}

/// 拡張が繋がっていない間だけ、鎖の一番上に出る。
/// 2本構成は普通ではないので、黙っていると詰まる。
private struct ConnectBanner: View {
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text("No audio yet")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Play something in another app, then send it here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                // 押すとシステムの出力先の一覧が出る。そこで EffeTune を選ぶと、
                // いま鳴っているアプリの音がこちらへ来る。
                // コントロールセンターを開くのと同じことを、ここでできる。
                RoutePicker()
                    .frame(width: 40, height: 40)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmptyChainRow: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No effects")
                .font(.system(size: 16, weight: .semibold))
            Text("The audio passes through untouched.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Add Effect", action: add)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }
}
