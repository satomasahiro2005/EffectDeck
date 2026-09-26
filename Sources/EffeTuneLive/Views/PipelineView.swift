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
import UIKit

enum ETLayout {
    /// 鎖に許す横幅。
    ///
    /// **iPad でも iPhone くらいに留める。**カードは名前を左、値を右に置く形なので、
    /// 左右いっぱいに広げると 1 行が長くなりすぎて、どの値がどのつまみのものか
    /// 目で追えなくなる。図も横に伸びるだけで情報は増えない。
    /// iPad に合わせた並べ方（2 列など）を作るまではこの形。
    static var chainMaxWidth: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 440 : .infinity
    }
}

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
    enum Sheet: String, Identifiable, Equatable {
        case picker, settings, routing, presets, ir
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?
    /// 次にピッカーで選んだものを差し込む位置（鎖の添字）。
    /// nil なら末尾。ツールバーの「Add Effect」から開いたときは常に nil。
    @State private var insertAt: Int?
    /// 「Reset chain」の確認を出しているか。
    /// ツールバーは ToolbarContent で View ではないから .confirmationDialog を
    /// 持てない。押されたことだけ Binding で受け取り、出すのは下の List 側。
    @State private var confirmingReset = false
    @State private var pluginError: String?

    /// 切ってある Section を消そうとしている行。消すと配下がその場で鳴り出すので、
    /// 一度だけ確かめる。配下の ON/OFF は書き換えない（about がそう約束している）。
    @State private var confirmingSectionRemoval: UUID?
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

    // MARK: - 並べ替え
    //
    // **Shortcuts と同じ形にしてある。**あちらは WorkflowEditor.framework の中で
    // 全部自作していて、reorderable も onMove も UICollectionView の drag & drop も
    // 使っていない（ipsw swift-dump で数えて 0 件）。要はこの 3 つ:
    //
    //   - 掴んだものの矩形を掴んだ時点で確保し、ドラッグ中ずっと持ち回る
    //     （EditorDragItem が height / initialWidth を持つ）
    //   - 落とし先は**点ではなく矩形の重なり**で決める
    //     （OverlayLayer.State の dragFormationRect と dropItemRects）
    //   - 掴んだものは行の中ではなく**別の層**に描く（overlayHost）
    //
    // 標準の並べ替えはどれも指の点で判定するので、掴んだものが相手より大きいと
    // 中心とのズレぶん判定が早く反転し、釣り合う所で上下に行き来する（実機で
    // session.location を出して確かめた）。面で見れば起きない。

    /// 掴んでいる行。
    @State private var dragging: UUID?
    @State private var dragExternalSnapshot: UIImage?
    /// **掴んだ時点の矩形。**入れ替えても動かさない。
    @State private var anchorRect: CGRect = .zero
    /// 指の縦の移動量。
    @State private var dragShift: CGSize = .zero
    /// 行ごとの矩形。落とし先の判定に使う。
    @State private var rowRects: [UUID: CGRect] = [:]
    /// 器の高さ。最後の帯をどこまで伸ばすかに使う。背面で測る。
    @State private var listHeight: CGFloat = 0

    /// 最後の行より下に敷く帯の高さ。鎖が画面を埋めていないときは残りを埋める。
    ///
    /// **行の「位置」は使わない。**一度 maxY から残りを出したが、あれはスクロールで
    /// 動く座標なので、**帯の高さが変わる→中身の寸法が変わる→また送れる**の堂々巡りに
    /// なった（画面より短い鎖でも上下に送れ、途中で止まった）。
    /// **高さの合計**なら送っても動かない。
    private var tailHeight: CGFloat {
        guard listHeight > 0, !rowRects.isEmpty else { return 96 }
        let content = rowRects.values.reduce(0) { $0 + $1.height }
            + CGFloat(rowRects.count) * 10   // 行の間
        return max(96, listHeight - content)
    }

    /// 左スワイプを開いている行。
    @State private var swiping: UUID?
    /// その行がどれだけ左へずれているか（0 以下）。
    @State private var swipeX: CGFloat = 0
    /// 払い始めた時点のずれ。開いた所から払い直しても飛ばないように。
    @State private var swipeStart: CGFloat = 0

    /// 鎖の中での座標。行の位置も指の位置もこれで測る。
    private static let chainSpace = "chain"
    /// 開いたときに行が左へ寄る量。
    private static let swipeWidth: CGFloat = 78
    /// 行と赤い面のあいだ。カードどうしの間と同じだけ空ける。
    private static let swipeGap: CGFloat = 10

    /// 状態の見直し。ルートの問い合わせなど重いものはこちら。
    /// **図はこちらでは動かさない**（ETDisplayPump が面に合わせて汲む）。
    private let slow = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    /// 背景に回ったら図を汲むのをやめる。前例は GraphCanvas と PitchMeterView。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            chainList
                // iPad は ETLayout が絞る。撮影のときは -ETWidth で上書きできる
                // （iPad で撮るのは高さが要るからで、幅まで iPad になると
                // 実機の見え方にならない）。
                .frame(maxWidth: ETScreenshotSeed.requested == nil
                                 ? ETLayout.chainMaxWidth : ETScreenshotSeed.phoneWidth)
                .frame(maxWidth: .infinity)
                .overlay {
                    if sheet == .picker {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                insertAt = nil
                                sheet = nil
                            }
                    }
                }
            // タイトルは出さない。アプリの中でアプリ名を読む人は居ないし、
            // その 1 行ぶん鎖が見える。
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { PipelineToolbar(sheet: $sheet, confirmingReset: $confirmingReset,
                                       dsp: dsp, io: io, hasPeer: hasPeer) }
            .sheet(item: $sheet) { which in
                switch which {
                case .picker:
                    EffectPickerView(onPick: { spec in
                        dsp.add(spec, at: insertAt)
                        insertAt = nil
                        // **閉じるのはこちら。** ピッカーの中の dismiss() は
                        // 検索が出ている間、シートではなく検索を閉じる。
                        // 検索から選んだときだけ閉じない、という形になっていた。
                        sheet = nil
                    }, onPickAU: { entry in
                        let instanceID = UUID().uuidString
                        guard let externalIndex = try? ETAUExternalBridge.shared.reserve(
                            instanceID: instanceID) else { return }
                        dsp.addExternal(id: entry.id, instanceID: instanceID,
                                        name: entry.name,
                                        category: "Audio Units",
                                        externalIndex: externalIndex, at: insertAt)
                        ETAUHost.shared.create(entry, instanceID: instanceID)
                        insertAt = nil
                        sheet = nil
                    }, onPickJSFX: { entry in
                        let instanceID = UUID().uuidString
                        let insertion = insertAt
                        insertAt = nil
                        sheet = nil
                        ETJSFXHost.shared.prepare(entry, instanceID: instanceID) { result in
                            switch result {
                            case .success(let externalIndex):
                                dsp.addExternal(id: entry.id, instanceID: instanceID,
                                                name: entry.name, category: "JSFX",
                                                externalIndex: externalIndex, at: insertion)
                            case .failure(let error): pluginError = error.localizedDescription
                            }
                        }
                    }, onPickPreset: { name, items in
                        // 名前の付いた Section に包んで挿す。置き換えない。
                        // 鎖ごと置き換えたいときは Presets 画面のほう。
                        dsp.addPreset(named: name, items: items, at: insertAt)
                        insertAt = nil
                        sheet = nil
                    })
                case .settings:
                    SettingsView(io: io)
                case .routing:
                    RoutingView(dsp: dsp)
                case .presets:
                    PresetsView(dsp: dsp)
                case .ir:
                    IRLibraryView()
                }
            }
            // 鎖ごと捨てるのは 1 本ずつのスワイプ削除と違って取り消せないので、
            // ⋯ から直接は走らせず一度確かめる。シートと違って重ねても
            // 潰し合わないので、上の .sheet とは別に付けてある。
            .confirmationDialog("Reset chain?",
                                isPresented: $confirmingReset,
                                titleVisibility: .visible) {
                Button("Reset chain", role: .destructive) { dsp.resetToDefault() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Removes every effect and leaves a single Level Meter.")
            }
            .alert("Could Not Add JSFX", isPresented: Binding(
                get: { pluginError != nil }, set: { if !$0 { pluginError = nil } })) {
                    Button("OK", role: .cancel) { pluginError = nil }
                } message: { Text(pluginError ?? "Unknown error") }
            // 切ってある Section を外すと、止まっていた段がその場で鳴り出す。
            // 配下の ON/OFF は書き換えないので（about が保つと言っている）、
            // 起きることを先に出しておく。
            .confirmationDialog("Remove this section?",
                                isPresented: Binding(
                                    get: { confirmingSectionRemoval != nil },
                                    set: { if !$0 { confirmingSectionRemoval = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let id = confirmingSectionRemoval { removeConfirmed(id) }
                    confirmingSectionRemoval = nil
                }
                Button("Cancel", role: .cancel) { confirmingSectionRemoval = nil }
            } message: {
                Text("The effects inside it will start playing again.")
            }
            .onAppear {
                // **案内の画面は持たない。**
                // 「2 本構成で、他のアプリの音を寄越す」という形が読めないだろう、
                // と思って 1 枚置いていた。いまは鎖の頭の帯（ConnectBanner）が
                // 「別のアプリで少し鳴らしてから、コントロールセンターで EffectDeck を
                // 選ぶ」と言っていて、音が来ていないあいだ出たままになる。
                // 読む場所が 2 つあっても片方しか読まれない。
                //
                // 撮るシートを指定されていればそれを出す。
                if let name = ETScreenshotSeed.sheet, let which = Sheet(rawValue: name) {
                    sheet = which
                }
                // 動きを撮るために、しばらくしてから自分で開く。
                // **4 秒待つ。**シミュレータは画面が出るまで 3 秒以上かかることが
                // あり、1.5 秒だと描いていない間に開き終わって動きが撮れない。
                if ETScreenshotSeed.autoExpand {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        let effects = dsp.chain.filter { !$0.isSection }
                        let at = ETScreenshotSeed.autoExpandIndex
                        if effects.indices.contains(at) { cycle(effects[at]) }
                    }
                }
                // 写した値の初期合わせ。購読の初回配信に頼らない。
                running = io.running
                hasPeer = io.hasPeer
                processingRate = io.processingRate
            }
        }
        .onReceive(slow) { _ in io.tick() }
        // 図は画面の描き直しに合わせて汲む。タイマーで回すと面と揃わず、
        // DSP が出した 60Hz の枠も半分捨てていた（DisplayPump.swift の頭）。
        .onAppear { ETDisplayPump.shared.start { io.pollTelemetry() } }
        .onDisappear { ETDisplayPump.shared.stop() }
        // **背景に回ったら汲むのをやめる。**
        // stop を呼ぶ口は onDisappear だけだったが、これは根のビューなので
        // 背景では来ない。CADisplayLink が残り、DSP 側のテレメトリ速度も 60 の
        // まま夜通し続く（誰も読まない枠を 1 ノードあたり 60 回/秒書く）。
        //
        // **止めるのは `.background` だけ。**`.inactive` で止めると、
        // コントロールセンターを引き下ろすたびに link を作り直し、速度を
        // 60↔0 で往復させる。この製品の導線がまさにコントロールセンター。
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { ETDisplayPump.shared.stop() }
            else { ETDisplayPump.shared.start { io.pollTelemetry() } }
        }
        // **共有シートや「このアプリで開く」から来たファイルを受ける。**
        // 宣言（Info.plist の CFBundleDocumentTypes）だけ足すと、候補には出るのに
        // 押しても何も起きない。受け口はここ 1 か所だけにしてある。
        .onOpenURL { url in
            switch ETInbox.receive(url) {
            case .ir: sheet = .ir
            // 取り込んだ JSFX は一覧に入る。そこから鎖へ足してもらう。
            case .jsfx: sheet = .picker
            // **黙って落とさない。**押しても何も起きないのと見分けが付かない。
            case .failed(let why): pluginError = why
            case .unsupported: break
            }
        }
        // 鎖から外れた段ぶんの「畳んでも消えない選択」を捨てる。
        // MatrixRouting が MatrixView の onAppear でやっているのと同じ掃除。
        .onChange(of: dsp.chain.count) { _, _ in
            ETCardSelection.shared.prune(keeping: dsp.chain.map(\.id))
        }
        // io を丸ごと観測せず、要る値だけを写す。
        .onReceive(io.$running) { running = $0 }
        .onReceive(io.$hasPeer) { hasPeer = $0 }
        .onReceive(io.$processingRate) { processingRate = $0 }
    }

    private var chainList: some View {
        // 1 回だけ組む。⋯ の Move Up / Move Down が「画面の何行目か」と
        // 「画面の行数」の両方を要るので、行ごとに組み直すと本数ぶん無駄になる。
        let visible = rows

        // **List ではなく ScrollView + VStack。**
        //
        // List は行の高さを動かす間も中身を切るので掴んだカードが欠ける。
        // それとは別に、**行の区切り線が視覚上どうしても出る**。
        // .listRowSeparator(.hidden) を付けても仕様として引かれる場所が残る。
        //
        // その代わり .swipeActions が使えない（List の行でしか効かない）ので、
        // 左スワイプの削除はここで自前でやる。判定は ETDragHandle の
        // UIPanGestureRecognizer（横向きのときだけ立つ）。
        return ScrollView {
            VStack(spacing: 0) {
            ClipboardBanner(dsp: dsp)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)

            if !hasPeer {
                ConnectBanner()
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }

            // 鎖の真上に出す。ここより下のカードが効いていない、という話なので。
            // 鎖が空のときは出さない。EmptyChainRow が同じことを既に言っている。
            if dsp.bypass && !dsp.chain.isEmpty {
                BypassBanner { dsp.bypass = false }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }

            if dsp.chain.isEmpty {
                EmptyChainRow { insertAt = nil; sheet = .picker }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 20)
            } else {
                ForEach(visible) { row in
                    // **配下だと分かる印。**左に線を引いて内側へ寄せる。
                    // 続く行で線が繋がるので、Section から次の Section の手前までが
                    // 一組に見える。囲まないし、行間も詰めない。
                    // 伸ばす向きは位置から引く。行の中身から引くと、
                    // 組の切れ目（見出しの手前）で前の組と繋がってしまう。
                    // 線も角も同じ位置から引く。単独（.alone）には引かない。
                    //
                    // **組の上と下にだけ横線を引く。**どこからどこまでが
                    // ひと組なのかが見えないと、掴んだものを組の中へ入れるのか
                    // 外へ出すのかが分からない。終わりの印を持たない構造なので、
                    // 線が唯一の境目になる。
                    VStack(spacing: 0) {
                    // **線は 1 本にする。**直前の組が下線を出していたら引かない。
                    if row.block == .top && !(row.visible > 0
                        && visible[row.visible - 1].block == .bottom) {
                        ETGroupRule()
                    }
                    ETSectionBracket(active: row.showsBracket,
                                     extendsUp: !row.block.roundsTop,
                                     extendsDown: !row.block.roundsBottom) {
                    EffectCardView(
                        index: row.index,
                        node: row.node,
                        dsp: dsp,
                        isExpanded: expanded.contains(row.node.id),
                        isCollapsedFully: dsp.collapsedFully.contains(row.node.id),
                        toggleExpanded: { cycle(row.node) },
                        // 隣は鎖の隣ではなく**画面の隣**。畳んだ Section の配下と
                        // 入れ替わって行が消えないように、ドラッグと同じ道を通す。
                        moveUp: { moveRow(row.visible, to: row.visible - 1) },
                        moveDown: { moveRow(row.visible, to: row.visible + 2) },
                        canMoveUp: row.visible > 0,
                        canMoveDown: row.visible < visible.count - 1,
                        block: row.block)
                    }
                        // 線のぶんは外側の余白から取る。カードの左端は
                        // どちらの行でも 14 に揃う（ETSectionBracket の頭）。
                        .padding(.leading,
                                 row.showsBracket ? ETSectionBracket<EmptyView>.inset : 14)
                        .padding(.trailing, 14)
                        // **角丸が無い辺は余白を半分にする。**組の中では
                        // カードどうしが地続きに見えるほうが、ひと組だと分かる。
                        .padding(.top, row.block.roundsTop ? 5 : 2.5)
                        .padding(.bottom, row.block.roundsBottom ? 5 : 2.5)
                        // **左スワイプで削除。**行だけをずらし、後ろに赤い面を敷く。
                        // .onDelete は使わない（詳しくは下の remove(_:)）。
                        //
                        // **順番が要る。**.background を先に付けると赤い面も
                        // 一緒にずれて、ずっと行の裏に隠れたままになる。
                        // .offset は配置を変えないので、後から付けた
                        // .background は元の位置に残り、行だけが滑って見える。
                        .offset(x: swiping == row.node.id ? swipeX : 0)
                        .background(alignment: .trailing) { deleteAction(row) }
                        // 落とし先の判定に要る。開閉で高さが変わるたびに来る。
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named(Self.chainSpace))
                        } action: { rowRects[row.node.id] = $0 }
                                .opacity(dragging == row.node.id ? 0 : 1)
                        // 掴みは UIKit の長押しで受ける（DragHandle.swift の頭）。
                        // 面は素通しなので、カードのタップも下へ届く。
                        .overlay {
                            ETDragHandle(
                                began: { beginDrag(row) },
                                moved: { d in
                                    dragShift = d
                                    settle(row.node.id)
                                },
                                ended: { endDrag() },
                                swipeBegan: { swipeBegan(row.node.id) },
                                swiped: { dx in swipeChanged(row.node.id, dx) },
                                swipeEnded: { dx, vx in swipeSettled(row.node.id, dx, vx) })
                        }
                        // **ピッカーからつまんだものを受ける。**
                        // カードには何も足さない。落ちたときだけ効く。
                        // 落とした段の手前に入れる（上流の並べ替えと同じ向き）。
                        .dropDestination(for: String.self) { items, _ in
                            guard let type = items.first else { return false }
                            return addDropped(type, at: row.index)
                        }
                    if row.block == .bottom { ETGroupRule() }
                    }
                }


                // **最後の行より下の余白も受ける。**
                // 行にしか落とし所が無いと、鎖の下の空いている所へ落としたときに
                // どこにも入らず、掴んだものが戻っていく。「一番下へ足す」の
                // つもりで落としているので、末尾へ足す。
                //
                // **contentShape を必ず付ける。**Color.clear は描くものが無いので、
                // 枠を持っていても当たりを取らない。帯が在っても落ちなかったのはこれで、
                // 高さの問題ではなかった。
                Color.clear
                    .frame(height: tailHeight)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        guard let type = items.first else { return false }
                        return addDropped(type, at: nil)
                    }
            }
            }
        }
        // **器の背面で落とし先を受ける。**鎖が短いと、最後の段より下は
        // どの行にも属さない余白になる。中身を画面の高さまで伸ばす手もあるが、
        // GeometryReader で包むと外側の寸法の決まり方が変わって余白が崩れた。
        // 背面なら、行に落ちたものは行が先に受け、余った所だけここへ来る。
        .background {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        guard let type = items.first else { return false }
                        return addDropped(type, at: nil)
                    }
                    .onAppear { listHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in listHeight = h }
            }
        }
        .coordinateSpace(name: Self.chainSpace)
        // **掴んだものは別の層に描く。**行の中に重ねると、はみ出したぶんが
        // 切られて位置もずれる（List は行の高さを動かす間も中身を切る）。
        // ここが List の外なので切られない。
        .overlay(alignment: .topLeading) {
            if let id = dragging,
               let row = visible.first(where: { $0.node.id == id }) {
                ETSectionBracket(active: row.showsBracket,
                                 extendsUp: !row.block.roundsTop,
                                 extendsDown: !row.block.roundsBottom) {
                    EffectCardView(
                        index: row.index, node: row.node, dsp: dsp,
                        // A drag snapshot must never mount the same AU view
                        // controller as the real card. Doing so reparents the
                        // controller into the overlay and leaves the row blank
                        // after drop until it is collapsed and reopened.
                        isExpanded: expanded.contains(row.node.id),
                        isCollapsedFully: dsp.collapsedFully.contains(row.node.id),
                        toggleExpanded: {}, moveUp: {}, moveDown: {},
                        canMoveUp: false, canMoveDown: false,
                        externalSnapshot: dragExternalSnapshot,
                        isDragPreview: true, block: row.block)
                }
                // 行と同じ余白を付ける。rowRects は余白の外側で測っているので、
                // 付けないと左右に広く見える。
                .padding(.leading,
                         row.showsBracket ? ETSectionBracket<EmptyView>.inset : 14)
                .padding(.trailing, 14)
                .padding(.top, row.block.roundsTop ? 5 : 2.5)
                .padding(.bottom, row.block.roundsBottom ? 5 : 2.5)
                .frame(width: anchorRect.width, height: anchorRect.height)
                .offset(x: anchorRect.minX + dragShift.width,
                        y: anchorRect.minY + dragShift.height)
                .allowsHitTesting(false)
            }
        }
    }

    /// ピッカーから運ばれてきた文字列がプリセットなら、名前と中身に解く。
    /// 効果は型の文字列をそのまま運ぶので、頭に印を付けて見分ける。
    private func presetPayload(_ text: String) -> (String, [PipelineStore.Loaded])? {
        #if DEBUG
        // 手で組み直さずに見るための鎖（DSP/DebugPresets.swift）。
        // **接頭辞で受ける。**前は "preset:debug:jsfx-host" と字で比べていたので、
        // 名前つきのものは払い出しても誰も受けず、ドラッグだけ黙って効かなかった。
        if text.hasPrefix("preset:debug:"), text != "preset:debug:jsfx-host" {
            let name = String(text.dropFirst("preset:debug:".count))
            if let item = ETDebugPresets.all.first(where: { $0.name == name }) {
                return (name, ETShareLink.parse(item.json, catalog: ETCatalog))
            }
            return nil
        }
        if text == "preset:debug:jsfx-host" {
            let items = ETJSFXHost.shared.debugPresetItems()
            return items.isEmpty ? nil : ("JSFX Host Test", items)
        }
        #endif
        if let name = text.dropPrefixIfPresent("preset:user:") {
            let items = PresetStore.shared.load(name)
            return items.isEmpty ? nil : (name, items)
        }
        if let name = text.dropPrefixIfPresent("preset:system:") {
            guard let preset = ETSystemPresets.first(where: { $0.name == name }) else { return nil }
            let items = ETShareLink.parse(preset.json, catalog: ETCatalog)
            return items.isEmpty ? nil : (name, items)
        }
        return nil
    }

    private func addDropped(_ payload: String, at index: Int?) -> Bool {
        if let preset = presetPayload(payload) {
            dsp.addPreset(named: preset.0, items: preset.1, at: index)
            sheet = nil
            return true
        }
        if let componentID = payload.dropPrefixIfPresent("au:"),
           let entry = ETAUHost.shared.entry(id: componentID) {
            let instanceID = UUID().uuidString
            guard let externalIndex = try? ETAUExternalBridge.shared.reserve(
                instanceID: instanceID) else { return false }
            dsp.addExternal(id: entry.id, instanceID: instanceID, name: entry.name,
                            category: "Audio Units", externalIndex: externalIndex,
                            at: index)
            ETAUHost.shared.create(entry, instanceID: instanceID)
            sheet = nil
            return true
        }
        if let componentID = payload.dropPrefixIfPresent("plugin-jsfx:"),
           let entry = ETJSFXHost.shared.entry(id: componentID) {
            let instanceID = UUID().uuidString
            sheet = nil
            ETJSFXHost.shared.prepare(entry, instanceID: instanceID) { result in
                switch result {
                case .success(let externalIndex):
                    dsp.addExternal(id: entry.id, instanceID: instanceID, name: entry.name,
                                    category: "JSFX", externalIndex: externalIndex, at: index)
                case .failure(let error): pluginError = error.localizedDescription
                }
            }
            return true
        }
        guard let spec = EffeTuneDSP.spec(forType: payload) else { return false }
        if let index { dsp.add(spec, at: index) } else { dsp.add(spec) }
        sheet = nil
        return true
    }

    // MARK: - 左スワイプで削除
    //
    // List をやめたので .swipeActions が使えない。同じ見え方を自前で作る。
    // 指の向きを見て立てるのは UIKit 側（DragHandle.swift の swipe(_:)）。

    /// 行の後ろに敷く赤い面。
    ///
    /// **幅は開いたぶんについてくる。**決め打ちにすると、払っている途中は
    /// 行の下から出たり引っ込んだりするだけで、伸びている感じが出ない。
    /// 行の左端との間は swipeGap ぶん空ける（カードどうしの間と揃える）。
    @ViewBuilder
    private func deleteAction(_ row: Row) -> some View {
        let shown = swiping == row.node.id ? swipeX : 0
        let width = max(0, -shown - Self.swipeGap)
        if width > 0 {
            // 細いうちに角を 16 のままにすると丸が潰れて見える。半分で頭打ち。
            let radius = min(16, width / 2)
            Button(role: .destructive) { remove(row.node.id) } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.red, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .padding(.vertical, 5)
            .padding(.trailing, 14)
        }
    }

    /// 払い始め。**始点を覚える。**渡ってくる移動量は払い始めからの量なので、
    /// 開いた所から払い直したときに覚えていないと 0 へ飛ぶ。
    private func swipeBegan(_ id: UUID) {
        guard dragging == nil else { return }
        if swiping != id {
            swiping = id
            swipeX = 0
        }
        swipeStart = swipeX
    }

    /// 払っている最中。**左にだけ開く。**開き切ったところから先は重くする。
    private func swipeChanged(_ id: UUID, _ dx: CGFloat) {
        guard dragging == nil, swiping == id else { return }
        let x = swipeStart + dx
        let open = -Self.swipeWidth
        if x >= 0 {
            swipeX = 0
        } else if x > open {
            swipeX = x
        } else {
            // 開き切ってから先は 1/3 しか付いてこない。
            swipeX = open + (x - open) / 3
        }
    }

    /// 離した。開くか閉じるかだけを決める。
    private func swipeSettled(_ id: UUID, _ dxRaw: CGFloat, _ vx: CGFloat) {
        guard swiping == id else { return }
        let dx = swipeStart + dxRaw
        let open = -Self.swipeWidth
        // **払い切りでは消さない。**一発で消えると取り返しがつかない。
        // 開くところまでで止めて、ゴミ箱を押させる。
        withAnimation(.snappy(duration: 0.24)) {
            if dx < open / 2 {
                swipeX = open
            } else {
                swipeX = 0
                swiping = nil
            }
        }
    }

    /// 開いているものを閉じる。掴み始めや消したあとに通す。
    private func closeSwipe() {
        guard swiping != nil else { return }
        withAnimation(.snappy(duration: 0.2)) { swipeX = 0; swiping = nil }
    }

    // MARK: - 並べ替え（矩形の重なりで決める）

    /// 掴み始め。掴んだ時点の矩形を確保する。
    private func beginDrag(_ row: Row) {
        guard dragging != row.node.id else { return }
        closeSwipe()
        if row.node.externalID?.hasPrefix("jsfx:") == true {
            dragExternalSnapshot = ETJSFXHost.shared.viewSnapshot(
                instanceID: row.node.externalInstanceID)
        } else if row.node.isExternal {
            dragExternalSnapshot = ETAUHost.shared.viewSnapshot(
                instanceID: row.node.externalInstanceID)
        } else {
            dragExternalSnapshot = nil
        }
        dragging = row.node.id
        anchorRect = rowRects[row.node.id] ?? .zero
        dragShift = .zero
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// 掴みを終える。**どの道から来ても必ずここを通す。**
    ///
    /// 戻す先は掴んだ時点の位置ではなく、**いまその行がいる枠**。入れ替えた
    /// あとに元の位置へ帰すと、行と絵が別の場所に出て一瞬ちらつく。
    ///
    /// `dragging` を同じ withAnimation の中で nil にしてはいけない。層が
    /// その場で消えるだけで戻る動きが出ない（絵が瞬間的に飛ぶ）。
    /// 戻りきってから畳む。
    ///
    /// **畳むのを withAnimation の completion に任せてはいけない。**
    /// 動く値が無いとき（掴んで動かさずに離した、など）completion が
    /// 来ないことがある。来ないと層が出たままになり、その行は
    /// `.opacity(0)` で消えたまま、代わりに出ている層は
    /// `.allowsHitTesting(false)` の絵なので、カードごと操作できなくなる。
    /// 実機で Bit Crusher がそうなった。
    /// 時間で必ず畳む。
    private func endDrag() {
        guard let id = dragging else { return }
        let slot = rowRects[id] ?? anchorRect
        withAnimation(.snappy(duration: Self.returnDuration)) {
            anchorRect = slot
            dragShift = .zero
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.returnDuration))
            // 戻っている間に掴み直されていたら、そちらを消さない。
            if dragging == id {
                dragging = nil
                dragExternalSnapshot = nil
            }
        }
    }

    /// 離してから層を畳むまで。戻りの動きと同じ長さ。
    private static let returnDuration: Double = 0.26

    /// 掴んだものの矩形が隣の矩形とどれだけ重なったかで入れ替える。
    /// 落とし先を決める。**掴んだ矩形の中心と、隣の行の中心を比べるだけ。**
    ///
    /// 重なりが閾値を越えたら入れ替える形は、小さいカードが大きいカードの中へ
    /// 完全に入ったときに破れる。重なりは掴んだ高さ a より大きくならないので、
    /// 戻りの閾値をそこへ置くと `a > a` が永久に偽になって**帰り道が塞がり**、
    /// 下げれば入れ替えた直後にそのまま逆条件が立って**往復する**。
    /// 履歴を見て閾値を変える細工も、決め打ちの距離が要るだけで筋が悪い。
    ///
    /// **比べるのは、掴んだ矩形の「端」と相手の「中心」。**掴んだ高さ a、相手 b、
    /// 行間 g として:
    ///
    ///     入れ替わる          ずれ s > b/2 + g
    ///     入れ替えた後に戻る   s < −g
    ///
    /// 差は **b/2 + 2g**。離れ幅が幾何から出るので、履歴も決め打ちの距離も要らない。
    ///
    /// **中心どうしで比べてはいけない。**それだと s > (a+b)/2 + g となって a が効き、
    /// 918pt のカードを掴んだだけで 500pt 運ばされる。手本（Shortcuts）は大きいものを
    /// 掴んでもわずかな移動で入れ替わる。端で比べれば a が式から消える。
    ///
    /// **入れ替えの動き（0.22 秒）の最中も安全。**`rowRects` はその間ずっと中間の値を
    /// 返すが、相手は上（下）へ動いていく途中なので、相手の中心は逆条件から
    /// **遠ざかる向きにしか動かない**（動き始めの瞬間が等号で、判定は `<` / `>`）。
    /// 閾値でやっていたときに往復していたのは、ここを勘定に入れていなかったため。
    ///
    /// 連続して越えるときも正しい。`[A,B,C]` の A が B を越えても C の位置は
    /// `a+g+b+g` → `b+g+a+g` で変わらないので、次の判定は動きの最中でも狂わない。
    private func settle(_ id: UUID) {
        let visible = rows
        guard let at = visible.firstIndex(where: { $0.node.id == id }) else { return }
        // 判定は縦だけ見る。鎖は 1 列なので横は絵の都合でしかない。
        let moving = anchorRect.offsetBy(dx: 0, dy: dragShift.height)

        if at > 0, let above = rowRects[visible[at - 1].node.id], moving.minY < above.midY {
            swap(at, to: at - 1)
            return
        }
        if at < visible.count - 1, let below = rowRects[visible[at + 1].node.id] {
            if moving.maxY > below.midY {
                // **組の最後から下へ出ようとしたら、組を閉じる。**
                // そのまま入れ替えると、次の組の見出しを飛び越えて
                // 今度はそちらの中に入るだけで、外に出ることができない。
                if visible[at].block == .bottom { leaveGroup(at); return }
                // 下へは 2 つ先。move(_:to:) は List の onMove と同じ数え方。
                swap(at, to: at + 2)
            }
        } else if visible[at].block == .bottom, let mine = rowRects[id],
                  moving.midY > mine.maxY {
            // 鎖の末尾。下に行が無いので入れ替えでは外に出られない。
            // 自分の枠の下端を中心が越えたら、で s > a/2。前の書き方
            // （maxY > mine.maxY + height/2）と同じ量。
            leaveGroup(at)
        }
    }

    /// 組から出す。**掴んでいる段の直前に、名前の無い Section を挿す。**
    ///
    /// 鎖はフラットな配列で Section は「ここから」の印しか持たないので、
    /// 段の位置を動かすだけでは組の外へ出せない（次の組に入るだけ）。
    /// 名前の無い Section を挟めば、そこで前の組が閉じる。上流はただの
    /// 新しい組として読むので、web と行き来しても壊れない。
    private func leaveGroup(_ at: Int) {
        let visible = rows
        guard visible.indices.contains(at) else { return }
        // **判断は模型が持つ。**画面は「この行を外へ」と言うだけ。
        // 直前が既に印か、もう root に居るか、正規化で取り消されるか、は
        // 全部あちらが決めて、起きたかどうかだけを返す。
        let changed = withAnimation(.snappy(duration: 0.22)) {
            dsp.leaveSection(at: visible[at].index)
        }
        // **打ち消されたら振動は出さない。**指に成功を返しておいて何も起きないと、
        // 効かない操作を繰り返させることになる。
        if changed { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    }

    /// 入れ替える。**基準（anchorRect）には手を触れない。**
    ///
    /// 一度、入れ替えのたびに基準を相手の高さぶん送り、同じだけ dragShift を
    /// 引いて打ち消していた。入替の瞬間だけは合うが、次の moved が
    /// `dragShift = dy`（掴んだ時点からの絶対量）で上書きするので、
    /// 打ち消しの側だけが 1 フレームで消えて基準のズラしが残る。
    /// 実機で 1 回測って確かめた（2026-09-17）:
    ///
    ///     掴む at=1 rect=345..448
    ///     入替 1->0 delta=-254 shift=-256
    ///     → 入替の瞬間 91+(-2)=89 は正しいが、次のフレームは 91+(-256)=-165
    ///
    /// 掴んだものは別の層に描いている。絵の位置は「掴んだ時点の矩形＋指の
    /// 移動量」で決まりきっていて、下の並びがどう動こうと関係ない。
    /// 補正そのものが要らなかった。
    private func swap(_ at: Int, to destination: Int) {
        withAnimation(.snappy(duration: 0.22)) { moveRow(at, to: destination) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        /// 段そのものの身元。remove(_:) やスワイプ削除はこちらを使う。
        var id: UUID { node.id }
        /// **ForEach に渡す身元。** 並べ替えのたびに変わるので、List は
        /// 行を動かすのではなく組み直す。

        /// Section の配下か。**画面でそれと分かる印を出すために要る。**
        /// 音の側は sectionGate で止めているが、あれは入切の話で、
        /// 「どれがこの Section のものか」は画面のどこにも出ていなかった。
        /// 組の中での位置。角と線の両方をここから引く。
        /// **2 つに分けない。**以前は「配下か」を別に持っていて、
        /// 畳んだ Section（配下が画面に無い）に線だけ残った。
        var block: ETBlockPosition = .alone

        /// 畳んでいるか。線を引くかの判定に使う。
        var isCollapsed = false

        /// 左の線を出すか。
        ///
        /// 組の中の行と、**畳んだ Section 自身**。畳むと配下の行が消えるので
        /// position() は `.alone` を返すが、そこで線まで消すと「中に何か入っている
        /// 組」なのか「ただの段」なのか見分けが付かない。
        /// 線は出すが下へは伸ばさない（`.alone` は roundsBottom なので伸びない）。
        ///
        /// **開いている無名の Section には出さない。**あれは組を始める印ではなく、
        /// 直前の組を閉じるために置く代用品（ETSection.isUnnamed）。開いたまま
        /// 線を引くと、そこから新しい組が始まるように見える。畳んだときは中身が
        /// 隠れているので、在ることを示すために引く。
        var showsBracket: Bool {
            if block != .alone { return true }
            return node.isSection && isCollapsed
        }

    }

    /// 畳んでいる Section の配下を落としたもの。
    ///
    /// 隠す範囲は Section の次から、次の Section の手前まで。上流が音を止める
    /// 範囲と同じ区切り方にしてある（js/audio/dsp-pipeline-descriptor.js:190-201、
    /// 区切りは入れ子にならず、次の Section に当たったらそこで切り替わる）。
    private var rows: [Row] {
        // **所属を数えるのはここではない。**ETPipelineAnalysis が 1 か所で決める。
        // 画面が `range(after:)` を自分で呼んでいたころは、「名前が空なら組を作らない、
        // ただし切ってあるなら作る」という但し書きを呼ぶ場所ごとに書いていた。
        let a = dsp.analysis
        let chain = dsp.chain

        // 鎖の位置 → Node.id。所属は id で返ってくるので引き直す。
        var indexOf: [UUID: Int] = [:]
        for i in chain.indices { indexOf[chain[i].id] = i }

        // 畳んだ Section の配下は行に出さない。**rootReset も出さない**
        // （あれは Section ではなく、並びが持つ印でしかない）。
        var hidden: Set<Int> = []
        for i in chain.indices {
            if chain[i].isRootReset { hidden.insert(i); continue }
            guard chain[i].isSection, !expanded.contains(chain[i].id) else { continue }
            for member in a.members(of: chain[i].id) {
                if let at = indexOf[member] { hidden.insert(at) }
            }
        }

        // 組に属する行（見出しを含む）。**配下を持たない Section には引かない**
        // （線だけ浮く）。
        var member: Set<Int> = []
        for i in chain.indices where chain[i].isSection {
            let body = a.members(of: chain[i].id)
            guard !body.isEmpty else { continue }
            member.insert(i)
            for id in body { if let at = indexOf[id] { member.insert(at) } }
        }

        let shown = chain.indices.filter { !hidden.contains($0) }
        // 位置は**見えている並び**で決める。畳んだ Section の配下は出ないので、
        // 鎖の位置で決めると画面に無い行を末尾だと思って角が丸まらない。
        // **見出しは必ず組の先頭。**Section が続くと、前の組の最後の配下と
        // 次の見出しが隣り合うので、member だけで見ると途切れず 1 組に見えてしまう。
        func isHead(_ at: Int) -> Bool { chain[shown[at]].isSection }
        func inGroup(_ at: Int) -> Bool { member.contains(shown[at]) }
        func position(_ at: Int) -> ETBlockPosition {
            guard inGroup(at) else { return .alone }
            let next = at + 1 < shown.count && inGroup(at + 1) && !isHead(at + 1)
            if isHead(at) { return next ? .top : .alone }
            let prev = at > 0 && inGroup(at - 1)
            switch (prev, next) {
            case (false, true):  return .top
            case (true, true):   return .middle
            case (true, false):  return .bottom
            case (false, false): return .alone
            }
        }
        return shown.indices.map {
            let node = chain[shown[$0]]
            return Row(visible: $0, index: shown[$0], node: node,
                       block: position($0),
                       isCollapsed: node.isSection && !expanded.contains(node.id))
        }
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
    /// **Section も行 1 つだけ消す。配下は連れない。**
    ///
    /// 畳んでいる Section は配下ごと消していた。理由として書いてあったのは
    /// List の都合で、こういう形だった:
    ///
    ///   鎖  [A, B, Section(畳), C, D, E]   画面は 3 行（配下は rows が落とす）
    ///   Section だけを外すと隠す理由が消えるので、同じ更新で C D E が現れる。
    ///   ForEach に渡す配列が削除の最中に 3 から 5 へ**増える**。
    ///   List は消える行を 1 つ前提に対応を組み直すので、そこで食い違う。
    ///
    /// **その理由はもう無い。**鎖は List ではなく ScrollView + VStack（chainList の頭）。
    /// そして連れて行く条件（`!expanded.contains(id)`）は rows が隠す条件と
    /// 食い違っていた。rows:706-708 は**有効な無名 Section を隠す対象から外して
    /// いる**のに、こちらにその除外が無い。つまり leaveGroup が置いた無名 Section の
    /// 行を払うと、**画面に出ている段が消えていた。**
    ///
    /// ⋯ の Remove（EffectCardView）は元から 1 行しか消しておらず、同じ「消す」が
    /// 2 通りあった。上流も Section だけを消す
    /// （js/ui/pipeline/pipeline-selection-manager.js:93 の deleteSelectedPlugins）。
    ///
    /// **move(_:to:) は配下を連れたまま残す。**見えていないものを置き去りにする
    /// 重みが、消すのと動かすのとで違う。動かすのは戻せるが、消すのは戻せない。
    ///
    /// 切ってある Section を消すと、止まっていた配下がその場で鳴り出す。
    /// 配下の ON/OFF は書き換えない（Section の about が「各段は自分の ON/OFF を
    /// 保つ」と約束している）。代わりに消す前に一言出す。
    private func remove(_ id: UUID) {
        guard let i = dsp.chain.firstIndex(where: { $0.id == id }) else { return }
        // 切ってある Section で、止めている段が在るときだけ確かめる。
        if dsp.chain[i].isSection, !dsp.chain[i].enabled,
           !dsp.analysis.members(of: dsp.chain[i].id).isEmpty {
            confirmingSectionRemoval = id
            return
        }
        dsp.remove(at: IndexSet(integer: i))
    }

    /// 確かめたあとに消す。配下は連れない。
    private func removeConfirmed(_ id: UUID) {
        guard let i = dsp.chain.firstIndex(where: { $0.id == id }) else { return }
        dsp.remove(at: IndexSet(integer: i))
    }

    /// 長押しで動かしたときの置き換え。
    ///
    /// 畳んでいる Section を動かすときは、隠れている配下も一緒に運ぶ。
    /// 見えていないものを置き去りにすると、開くまで気づけないため。
    /// 開いている Section は行 1 つだけ動く（上流の普通のドラッグと同じ。
    /// 範囲ごと動かすのは上流でも Shift+Click の側で、
    /// js/ui/pipeline/pipeline-section-handler.js:78-186 がそれ）。
    /// カードの開閉を回す。
    ///
    ///   開く（パラメータ＋図） → 図だけ → 畳む → 開く …
    ///
    /// 例外が 2 つ。
    ///   - Level Meter は「図だけ」で止める。畳むと名前の行に細い棒が出る形で、
    ///     音が来ているかを見るために置く道具だから
    ///   - 図を持たないもの（IR Reverb）は「図だけ」の段が無いので 開く ↔ 畳む
    private func cycle(_ node: EffeTuneDSP.Node) {
        let id = node.id
        let hasGraph = ETEffectViews.hasGraph(node.spec.type)
        let keepsGraph = node.spec.type == "LevelMeterPlugin"

        // **動かさない。**
        //
        // 20fps で撮って調べた（Scripts は無く、/tmp/rec.sh と frames.swift で
        // 動画から抜いた）。伸び縮みのあいだ List は行の中身を切るので、
        // 0.2 秒のあいだ上の Section のカードが上端で欠け、畳む側のカードは
        // 板だけ消えて字が宙に浮く。材質でも単色でも同じで、色の話ではない。
        //
        // 試して駄目だったもの:
        //   - 出入りの指定（.opacity / .move）… 切られるのは変わらない
        //   - 汲むのを止める … 図が凍って戻る時に跳ねる。こちらが作った不具合
        //   - 板を listRowBackground へ移す … **画面が真っ白になる**
        //
        // 壊れた動きより、瞬時に切り替わるほうが良い。
        if expanded.contains(id) {
            expanded.remove(id)
            // 図が無いものは、開くのをやめたらそのまま畳む。
            if !hasGraph { dsp.collapsedFully.insert(id) }
        } else if !dsp.collapsedFully.contains(id) && hasGraph && !keepsGraph {
            dsp.collapsedFully.insert(id)
        } else {
            dsp.collapsedFully.remove(id)
            expanded.insert(id)
        }
    }

    private func move(_ source: IndexSet, to destination: Int) {
        let visible = rows
        let types = dsp.chain.map(\.spec.type)

        var moving = IndexSet()
        for offset in source {
            guard visible.indices.contains(offset) else { continue }
            let i = visible[offset].index
            moving.insert(i)
            if visible[offset].node.isSection && !expanded.contains(visible[offset].node.id) {
                // 畳んだ組を動かすと配下も付いてくる。配下は Analysis が持つ。
                for member in dsp.analysis.members(of: visible[offset].node.id) {
                    if let at = dsp.chain.firstIndex(where: { $0.id == member }) {
                        moving.insert(at)
                    }
                }
            }
        }
        guard !moving.isEmpty else { return }

        let target = visible.indices.contains(destination) ? visible[destination].index
                                                           : dsp.chain.count
        // 落ちた先が畳んだ Section の中なら、EffeTuneDSP.move が開く
        // （revealHidden）。連れて行った配下は開く理由に数えない。
        let wasVisible = Set(visible.map(\.node.id))
        dsp.move(from: moving, to: target)

        // **見えていたのに消えた段を開く。**
        //
        // EffeTuneDSP.move が開くのは掴んだ行のぶんだけ。畳んだ Section を動かすと、
        // 掴んでいない段が新しくその Section の配下に入ることがある。行は rows から
        // 落ち、同時に sectionGate もその Section の入切へ移る（applySectionGates）。
        // Section が切ってあれば、**画面から消えた段が黙って素通しになる**。
        //   鎖 [SecA(畳), EQ, SecB(開), Comp, Delay] → 画面 [SecA, SecB, Comp, Delay]
        //   SecA を SecB の下へ落とすと [SecB, SecA, EQ, Comp, Delay] になり、
        //   SecA の範囲が Comp と Delay まで伸びる。
        // 掴んだかどうかではなく「見えていたものが消えたか」で開く。
        let nowVisible = Set(rows.map(\.node.id))
        dsp.revealHidden(wasVisible.subtracting(nowVisible))
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
                    Label("Reset chain", systemImage: "trash")
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
                    // **やることをそのまま書く。**「送る」では、どこで何を
                    // 押せばよいのか画面から読めない。選ぶ場所を名指しする。
                    //
                    // **この帯に押し所は無い。** RoutePicker は中身を空にしてある
                    // （RoutePicker.swift の頭。置くとこのアプリが共有の出力
                    // コンテキストへ参加して、帰還ループに引きずられる）。
                    // 出す先を選べるのはコントロールセンターだけ。
                    //
                    // **名乗っている名前は ET_ROUTE_NAME（EffectDeck）。**アプリ名と同じ字にしてある
                    // （Sources/Extension の displayName）。一覧に出る字と
                    // 揃えないと、どれを押せばよいのか分からない。
                    //
                    // 鳴らしてから選ぶ順も落とさない。止まっていると系が
                    // 1.5 秒で経路を戻す（README の If it says Unable to Connect）。
                    Text("""
                         Play audio in another app for a few seconds, then select \
                         EffectDeck as the output in Control Center.
                         """)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)
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

                Text("All effects bypassed")
                    .font(.system(size: 15, weight: .semibold))

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
            Button("Add Effect", action: add)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }
}
