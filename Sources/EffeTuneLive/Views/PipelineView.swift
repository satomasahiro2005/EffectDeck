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
    /// 「Reset Pipeline」の確認を出しているか。
    /// ツールバーは ToolbarContent で View ではないから .confirmationDialog を
    /// 持てない。押されたことだけ Binding で受け取り、出すのは下の List 側。
    @State private var confirmingReset = false
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
            .toolbar { PipelineToolbar(sheet: $sheet, confirmingReset: $confirmingReset,
                                       dsp: dsp, io: io, hasPeer: hasPeer) }
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
            // 鎖ごと捨てるのは 1 本ずつのスワイプ削除と違って取り消せないので、
            // ⋯ から直接は走らせず一度確かめる。シートと違って重ねても
            // 潰し合わないので、上の .sheet とは別に付けてある。
            .confirmationDialog("Reset Pipeline?",
                                isPresented: $confirmingReset,
                                titleVisibility: .visible) {
                Button("Reset Pipeline", role: .destructive) { dsp.resetToDefault() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Removes every effect and leaves a single Level Meter.")
            }
            .onChange(of: sheet) { old, now in
                if old == .welcome && now == nil { welcomeSeen = true }
            }
            .onAppear {
                // 画面を撮るときは案内を出さない。後ろが見えなくなるので。
                if !welcomeSeen && ETScreenshotSeed.requested == nil { sheet = .welcome }
                // 撮るシートを指定されていればそれを出す。
                if let name = ETScreenshotSeed.sheet, let which = Sheet(rawValue: name) {
                    sheet = which
                }
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
        // 1 回だけ組む。⋯ の Move Up / Move Down が「画面の何行目か」と
        // 「画面の行数」の両方を要るので、行ごとに組み直すと本数ぶん無駄になる。
        let visible = rows

        return List {
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

            // 鎖の真上に出す。ここより下のカードが効いていない、という話なので。
            // 鎖が空のときは出さない。EmptyChainRow が同じことを既に言っている。
            if dsp.bypass && !dsp.chain.isEmpty {
                BypassBanner { dsp.bypass = false }
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
                ForEach(visible) { row in
                    EffectCardView(
                        index: row.index,
                        node: row.node,
                        dsp: dsp,
                        isExpanded: expanded.contains(row.node.id),
                        toggleExpanded: {
                            if expanded.contains(row.node.id) { expanded.remove(row.node.id) }
                            else { expanded.insert(row.node.id) }
                        },
                        // 隣は鎖の隣ではなく**画面の隣**。畳んだ Section の配下と
                        // 入れ替わって行が消えないように、ドラッグと同じ道を通す。
                        moveUp: { moveRow(row.visible, to: row.visible - 1) },
                        moveDown: { moveRow(row.visible, to: row.visible + 2) },
                        canMoveUp: row.visible > 0,
                        canMoveDown: row.visible < visible.count - 1)
                        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        // **.onDelete は使わない。** 詳しくは下の remove(_:)。
                        // こちらは押されたら閉じるだけで、行を消すのは鎖が変わった結果。
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { remove(row.node.id) }
                        }
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
        /// 画面の何行目か。⋯ の Move Up / Move Down が使う。
        /// List の onMove が渡してくる数と同じ数え方（鎖の添字ではない）。
        let visible: Int
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
            .enumerated()
            .map { Row(visible: $0.offset, index: $0.element, node: dsp.chain[$0.element]) }
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

    /// スワイプで消す。**払った行そのものを id で指す。**
    ///
    /// ここが .onDelete だったときに壊れていた。.onDelete は消す相手を
    /// 「ForEach の何番目か」で渡してくるうえ、行を消すアニメーションを
    /// List が自分で先に走らせる。前の削除のそれが終わらないうちに次を払うと、
    /// List が抱えている行の集合が rows より**先頭側に短くなり**、そのまま戻らない。
    /// 短くなった並びの中での位置が渡ってくるので、画面で払ったのとは別の段が消える。
    /// 5 本を間を空けずに払うと、3 本目のあとで画面が 1 枚だけになり、
    /// 以降スワイプも受け付けなくなっていた（Tests/UI/DeleteProbe の testDeleteFast）。
    /// 実測では鎖の側（publish）は最後まで正しく、狂っているのは List の表示だけだった。
    ///
    /// .swipeActions のボタンは押されても List は何もしない。鎖が変わった結果として
    /// 行が 1 つ減るだけなので、数える場所が 1 つになり、ずれようが無い。
    /// 払える範囲と全部払い切ったときの動きは .onDelete と同じ。
    ///
    /// **畳んでいる Section は配下ごと消す。** move(_:to:) が配下を連れて動かすのと
    /// 同じ扱いにしてある。揃えないと壊れる:
    ///
    ///   鎖  [A, B, Section(畳), C, D, E]   画面は 3 行（配下は rows が落とす）
    ///   Section だけを外すと隠す理由が消えるので、同じ更新で C D E が現れる。
    ///   ForEach に渡す配列が削除の最中に 3 から 5 へ**増える**。
    ///   List は消える行を 1 つ前提に対応を組み直すので、そこで食い違い、
    ///   関係ない位置に区切り線が残り、それより下の行がスワイプを受けなくなる。
    ///
    /// 上流は Section を畳んでも行が残る（畳むのはパラメータの表示だけ）ので、
    /// この食い違いが起きず、Section だけを消してよい
    /// （js/ui/pipeline/pipeline-selection-manager.js:93 の deleteSelectedPlugins）。
    /// こちらは幅が無くて行ごと隠しているため、同じにはできない。
    ///
    /// 開いている Section は行 1 つだけ消す。配下は見えているので、
    /// 消えたことにその場で気づける。
    private func remove(_ id: UUID) {
        guard let i = dsp.chain.firstIndex(where: { $0.id == id }) else { return }
        var doomed = IndexSet(integer: i)
        if dsp.chain[i].isSection && !expanded.contains(id) {
            doomed.formUnion(IndexSet(integersIn:
                ETSection.range(after: i, types: dsp.chain.map(\.spec.type))))
        }
        dsp.remove(at: doomed)
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
        for offset in source {
            guard visible.indices.contains(offset) else { continue }
            let i = visible[offset].index
            moving.insert(i)
            if visible[offset].node.isSection && !expanded.contains(visible[offset].node.id) {
                moving.formUnion(IndexSet(integersIn: ETSection.range(after: i, types: types)))
            }
        }
        guard !moving.isEmpty else { return }

        let target = visible.indices.contains(destination) ? visible[destination].index
                                                           : dsp.chain.count
        // 落ちた先が畳んだ Section の中なら、EffeTuneDSP.move が開く
        // （revealHidden）。連れて行った配下は開く理由に数えない。
        dsp.move(from: moving, to: target)
    }

    /// ⋯ の Move Up / Move Down。画面の 1 行を、画面の隣へ動かす。
    ///
    /// 数え方は List の onMove と同じで、上へは 1 つ前、下へは 2 つ先
    /// （自分が抜けるぶん 1 つずれる）。ドラッグと同じ move(_:to:) を通すので、
    /// 畳んだ Section を動かせば配下も付いてくるし、畳んだ Section の中へ
    /// 入ったら開く。鎖の添字で動かしていた頃は、隣が画面に無い行だと
    /// そこへ入り込んで動かした行が消えていた。
    private func moveRow(_ from: Int, to destination: Int) {
        // 端の行では項目を押せないようにしてあるが、-1 を渡すと
        // move(_:to:) が「画面の外＝末尾へ」と解いてしまうので、ここでも止める。
        guard destination >= 0 else { return }
        move(IndexSet(integer: from), to: destination)
    }
}

/// ツールバー。開いている Menu を守るために、本体から切り離してある。
///
/// 中身は sheet の指定しか要らない。親の body が別の理由（鎖の編集など）で
/// 作り直されても、渡す値が同じなら SwiftUI はここを評価し直さないので、
/// 提示の途中の Menu が作り直されずに済む。io は一切読まない。
private struct PipelineToolbar: ToolbarContent {
    @Binding var sheet: PipelineView.Sheet?
    /// 立てると親が確認を出す。ここで出せないのは ToolbarContent が View でないから。
    @Binding var confirmingReset: Bool
    @ObservedObject var dsp: EffeTuneDSP
    let io: AudioIO
    /// 拡張が繋がっているか。繋がっていないあいだマスターを沈める。
    let hasPeer: Bool

    /// マスターの読み上げ。入切と、沈めている理由の両方を言う。
    /// 沈んでいることは目には見えても、読み上げには何も出ないため。
    private var voiceOverValue: String {
        let state = dsp.bypass ? "Bypassed" : "On"
        return hasPeer ? state : state + ", no audio"
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // 鎖ぜんぶの入切。帯を無くしたのでここへ。
            //
            // **カードの電源と同じ絵を出さない。** 同じ丸い power を置くと、
            // どのエフェクトのものか分からないまま 1 個だけ余って見える。
            // 字の入った横長にしてある（MasterPowerToggleStyle）。
            // 切っているあいだは "Bypassed" と出るので、鎖が並んでいるのに
            // 音が変わらない理由が、ここと下の帯の両方から読める。
            //
            // .scaleEffect は外した。0.7 を掛けると当たり判定まで縮んで
            // 44pt が 30.8pt になる（scaleEffect は描画と一緒にタッチも縮める）。
            //
            // 幅は 44pt から 95pt 前後（枠 75 + 左右の余白 20）に増える。
            // 中央の LiveStatusStrip の取り分は変わらない。あれは
            //「バーの中心から右のボタン群の内側まで」の 2 倍で決まっていて
            //（iPhone 16 で約 97pt）、左からは 2×(196.5-(16+95))=171pt あるので、
            // 狭いのは相変わらず右側。LiveStatusStrip.swift:15 の見積もりにある
            //「電源トグル 44」だけが古くなる（あちらは別の担当のファイル）。
            //
            // 音が来ていないあいだは沈めて出す。**bypass は触らない。**
            // 見た目だけの話で、鎖の入切は人が決めた値のまま残す。
            // ここで bypass を立てると、繋がった瞬間に素通しで鳴り始めて、
            // なぜ効かないのか分からなくなる。
            // 押せるままにしてあるのは、繋ぐ前に切っておきたいことがあるため。
            Toggle("All effects", isOn: Binding(get: { !dsp.bypass },
                                                set: { dsp.bypass = !$0 }))
                .toggleStyle(.masterPower)
                .grayscale(hasPeer ? 0 : 1)
                // 0.4 だと 13pt の字が読めない。沈んでいると分かる所で止める。
                .opacity(hasPeer ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.2), value: hasPeer)
                .accessibilityLabel("All effects")
                .accessibilityValue(voiceOverValue)
                .accessibilityHint("Turns every effect in the pipeline on or off")
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
                Divider()
                // 上流に鎖を空にする操作は無く、既定を組む所を
                // 「Initialize default plugins」と呼んでいる（js/app.js:1061）。
                // 戻す先が空ではなく既定なので、Clear ではなく
                // 上流の Reset Audio / Reset Zoom と同じ Reset に寄せた。
                //
                // 押した時点では何もしない。走らせるのは親の確認を通ってから。
                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Label("Reset Pipeline", systemImage: "trash")
                }
                // 既に Level Meter 1 本なら押しても何も変わらない。
                .disabled(dsp.isDefaultChain)
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

/// マスターを切っているあいだ、鎖の頭に出る。
///
/// ツールバーの外に何も出ないと、カードが並んでいるのに音が変わらない理由が
/// 画面から読めない。上流は master を切るとプラグイン名を全部灰に落として
/// これを見せている（js/ui/pipeline/pipeline-core.js:301-322 の plugin-disabled）。
/// こちらはカード側に手を入れず、1 枚の帯で言う。
///
/// Now Playing からも切れる（NowPlaying.swift の再生/一時停止が bypass を動かす）ので、
/// この画面を触っていないのに切れていることがある。なおさら出す。
private struct BypassBanner: View {
    let turnOn: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "power")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text("All effects bypassed")
                        .font(.system(size: 15, weight: .semibold))
                    // 鎖が空のときと同じ言い方にする（下の EmptyChainRow）。
                    Text("The audio passes through untouched.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Button(action: turnOn) {
                    Text("Turn On")
                        .font(.system(size: 13, weight: .semibold))
                        // 見た目を膨らませるためではなく、押せる面を 44pt に
                        // 届かせるための余白。字が 13pt だと、style が足す
                        // 上下 7pt だけでは 30pt 前後にしかならない。
                        .padding(.horizontal, 6)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
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
