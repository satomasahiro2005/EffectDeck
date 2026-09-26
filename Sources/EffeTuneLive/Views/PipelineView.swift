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

    /// 2列（左に一覧、右に全部開いたカード）のときのカードの幅の上限。
    ///
    /// **ScrollViewの内側で絞る。**外で絞ると両脇の余白が鎖の外になり、
    /// そこに指を置いても送れず、ピッカーからつまんだものも落とせない。
    /// 名前と値の行が読める幅はchainMaxWidthの話と同じで、図を広げても情報は増えない。
    static let detailMaxWidth: CGFloat = 672
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
        case picker, settings, routing, presets, ir, tips
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?
    /// 2列の+（popoverの付け先）がもう画面に居るか。PipelineToolbarが立てる。
    @State private var pickerAnchored = false
    /// 2列で、ピッカーをpopoverでなく根のシートで出しているか。
    /// **出すときに決め、閉じるまで変えない**（openPicker）。
    @State private var pickerInSheet = false
    /// 「Reset chain」の確認を出しているか。
    /// ツールバーは ToolbarContent で View ではないから .confirmationDialog を
    /// 持てない。押されたことだけ Binding で受け取り、出すのは下の List 側。
    @State private var confirmingReset = false
    @State private var pluginError: String?
    /// 開いたリンクが読めなかった（鎖が空、/j の中身が壊れている）。pluginError と同じ .alert で出す
    /// （同じ View に .alert を 2 枚積むと先に付いたほうが出なくなる）。
    @State private var linkError: String?
    /// 開いたリンクの鎖。**入れ替えは取り消せないので一度確かめる**（Reset と同じ形）。
    /// タップ 1 回で今の鎖が消えると、押し間違いで積み上げたものを失う。
    @State private var pendingChain: [PipelineStore.Loaded]?
    /// シートを畳み終えてから出すもの（afterClosingSheet）。
    @State private var afterSheet: (() -> Void)?

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

    // MARK: - 並べ方（1列/2列）
    //
    // iPadの広い窓では2列にする。左に鎖の一覧（ChainMinimap）、右に鎖を全部開いて並べる。
    // iPhoneと狭い窓は今までどおりの1列で、道筋も同じ（stack(_:)）。
    // 2列はiPhoneの開閉の覚え（dsp.expanded / dsp.collapsedFully）を読まず、書きもしない。
    // 窓を狭めると、iPhoneで最後に置いた開閉のまま出る。

    @Environment(\.horizontalSizeClass) private var hSize
    /// 窓の幅が2列に足りるか。**640で立て、620を切るまで落とさない。**
    /// 1本の線にすると、Stage Managerで窓の端を引いているあいだ行き来する。
    /// 書くのは跨いだときだけ（updateWideEnough）。
    @State private var wideEnough = true
    /// 画面に出している並べ方。起きた直後（nil）だけwantsSplitにそのまま従う。
    ///
    /// **切り替えは1回遅らせる。**切り替える前に、掴みを離す・払いを閉じる・
    /// ピッカーを閉じる・読んでいた位置を覚える、を前の並べ方のうちに済ませる（flip(to:)）。
    /// 同じ回で切り替えると、前の並べ方の行がもう居ない。
    @State private var layoutSplit: Bool?
    /// 左の一覧を出しているか。システムのサイドバーのボタンが切り替える。
    @State private var columns: NavigationSplitViewVisibility = .all
    /// 右と左を繋ぐもの（ChainViewport.swift）。
    @State private var viewport = ETChainViewport()
    /// 行の矩形（ChainViewport.swift）。観測しない。
    @State private var geometry = ETRowGeometry()
    /// 左の一覧で押したときに、慣性で流れている右を止めてから飛ぶ。
    @State private var brake = ETScrollBrake()
    /// 2列の右で、上のカードの高さが変わっても読んでいる位置を保つ（ChainViewport.swift）。観測しない。
    @State private var keeper = ETReadingKeeper()

    /// 2列にしたい状態か。
    ///
    /// **iPadに限る。**Pro Maxの横置きもregularを返すので、幅だけで決めるとiPhoneが2列になる。
    /// 撮影のときは1列（iPhoneの幅で撮るため）。`-ETLayout wide`のときだけ2列で撮る。
    private var wantsSplit: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && hSize == .regular
            && wideEnough
            && (ETScreenshotSeed.requested == nil || ETScreenshotSeed.wideLayout)
    }

    /// 2列を出しているか。
    private var usesSplit: Bool { layoutSplit ?? wantsSplit }

    /// その行を開いて出すか。2列では全部開く。iPhoneの覚えは書き換えない。
    private func isOpen(_ id: UUID) -> Bool { usesSplit || expanded.contains(id) }

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
    /// 行の高さの合計（行の間を含む）。**変わったときだけ書く。**
    ///
    /// 行ごとの矩形そのものは観測しない箱（geometry）に入れてある。矩形は送るたびに
    /// 変わるので、@Stateに置くと1コマごとにbodyが走り直していた。高さの合計は
    /// 送っても変わらないので、ここに置いても送るだけでは書かれない。
    @State private var rowsHeight: CGFloat = 0
    /// 器の高さ。最後の帯をどこまで伸ばすかに使う。背面で測る。
    @State private var listHeight: CGFloat = 0

    /// 最後の行より下に敷く帯の高さ。鎖が画面を埋めていないときは残りを埋める。
    ///
    /// **行の「位置」は使わない。**一度 maxY から残りを出したが、あれはスクロールで
    /// 動く座標なので、**帯の高さが変わる→中身の寸法が変わる→また送れる**の堂々巡りに
    /// なった（画面より短い鎖でも上下に送れ、途中で止まった）。
    /// **高さの合計**なら送っても動かない。
    private var tailHeight: CGFloat {
        guard listHeight > 0, rowsHeight > 0 else { return 96 }
        return max(96, listHeight - rowsHeight)
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
        // 1 回だけ組む。⋯ の Move Up / Move Down が「画面の何行目か」と
        // 「画面の行数」の両方を要るので、行ごとに組み直すと本数ぶん無駄になる。
        // 2列では左の一覧も同じ並びから作る。onMoveの数え方がmove(_:to:)と揃う。
        let visible = rows

        // **GroupではなくZStack。**本物の器なので、onAppear / onDisappearは1回ずつ来る。
        // Groupは枝ごとに配るので、並べ方が切り替わると、新しい枝が汲み始めた後に
        // 古い枝が汲むのを止めることがある。
        // シート・確認・警告と汲む仕組みも、どちらの枝でもなくここに付ける。
        // 並べ方を切り替えても消えないように。
        ZStack {
            if usesSplit {
                split(visible)
            } else {
                stack(visible)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { updateWideEnough($0) }
        .sheet(item: presentedSheet, onDismiss: runAfterSheet) { which in
            switch which {
            case .picker:
                ETPickerHost(dsp: dsp, sheet: $sheet, pluginError: $pluginError)
            case .settings:
                SettingsView(io: io)
            case .routing:
                RoutingView(dsp: dsp)
            case .presets:
                PresetsView(dsp: dsp)
            case .ir:
                IRLibraryView()
            // ConnectBanner の Help から。Settings 側は自分の NavigationStack で押す。
            case .tips:
                NavigationStack {
                    ConnectionTipsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { sheet = nil }
                            }
                        }
                }
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
        .confirmationDialog("Replace chain?",
                            isPresented: Binding(
                                get: { pendingChain != nil },
                                set: { if !$0 { pendingChain = nil } }),
                            titleVisibility: .visible) {
            Button("Replace chain", role: .destructive) {
                if let items = pendingChain { dsp.replaceChain(with: items) }
                pendingChain = nil
            }
            Button("Cancel", role: .cancel) { pendingChain = nil }
        }
        .alert(linkError != nil ? "Could Not Open Link" : "Could Not Add JSFX", isPresented: Binding(
            get: { pluginError != nil || linkError != nil },
            set: { if !$0 { pluginError = nil; linkError = nil } })) {
                Button("OK", role: .cancel) { pluginError = nil; linkError = nil }
            } message: { Text(linkError ?? pluginError ?? "Unknown error") }
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
            // 「コントロールセンターで EffectDeck を選ぶ」と言っていて、
            // 音が来ていないあいだ出たままになる。
            // 読む場所が 2 つあっても片方しか読まれない。
            //
            // ConnectionTipsView は案内ではない。選んでも繋がらなかったときに
            // 開く画面で、始め方は書いていない。
            //
            // 撮るシートを指定されていればそれを出す。
            // ピッカーはpresentPickerを通す。2列ではまだ+が無いので、popoverにすると落ちる。
            if let name = ETScreenshotSeed.sheet, let which = Sheet(rawValue: name) {
                if which == .picker { presentPicker() } else { sheet = which }
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
        .onReceive(slow) { _ in io.tick() }
        // 図は画面の描き直しに合わせて汲む。タイマーで回すと面と揃わず、
        // DSP が出した 60Hz の枠も半分捨てていた（DisplayPump.swift の頭）。
        .onAppear {
            ETDisplayPump.shared.start { io.pollTelemetry() }
            drainShared()
            // 起きた直後の並べ方をここで固める。この先の切り替えはflip(to:)を通す。
            if layoutSplit == nil { layoutSplit = wantsSplit }
        }
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
            if phase == .active { drainShared() }
        }
        // **共有シートや「このアプリで開く」から来たファイルを受ける。**
        // 宣言（Info.plist の CFBundleDocumentTypes）だけ足すと、候補には出るのに
        // 押しても何も起きない。受け口はここと drainShared の 2 か所。
        //
        // **共有リンク（effectdeck.nemut.ai。別名の fxd.nemut.ai も読む）も同じ口に来る。**
        // Universal Link は SwiftUI では onOpenURL に届く。ファイルより先に見る。
        .onOpenURL { url in
            if let route = ETFXDLink.route(url) {
                openLink(route)
                return
            }
            // **ファイル以外は ETInbox へ渡さない。**https の URL を渡すと
            // IRLibrary が Data(contentsOf:) で画面を止めたまま取りに行く。
            guard url.isFileURL else { return }
            show(ETInbox.receive(url))
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
        // 並べ方を切り替える。片付けは前の並べ方が出ているうちに済ませる。
        .onChange(of: wantsSplit) { _, now in flip(to: now) }
        // 鎖の並び。左の一覧の「右で一番上のカード」と、足したカードを見せるのに使う。
        .onChange(of: dsp.chain.map(\.id), initial: true) { old, new in
            viewport.setOrder(new)
            if old != new { revealNew(old, new) }
        }
    }

    /// 2列。左に鎖の一覧、右に鎖を全部開いて並べる。
    ///
    /// **標準のNavigationSplitView。**サイドバーのボタン、材質、列の幅はシステムに任せる。
    /// `.balanced`にして、縦置きでも一覧をカードの上に被せず横に並べる。
    private func split(_ visible: [Row]) -> some View {
        NavigationSplitView(columnVisibility: $columns) {
            ChainMinimap(items: minimapItems(visible), dsp: dsp, viewport: viewport,
                         move: { move($0, to: $1) },
                         insert: { _ = addDropped($0, at: $1) })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            chainList(visible, split: true)
                .environment(\.etCardsPinnedOpen, true)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { chainToolbar(pickerAsPopover: true) }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// 1列。iPhoneと、iPadの狭い窓。**今までの形そのまま。**
    private func stack(_ visible: [Row]) -> some View {
        NavigationStack {
            chainList(visible, split: false)
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
                            .onTapGesture { sheet = nil }
                    }
                }
            // タイトルは出さない。アプリの中でアプリ名を読む人は居ないし、
            // その 1 行ぶん鎖が見える。
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { chainToolbar(pickerAsPopover: false) }
        }
    }

    private func chainToolbar(pickerAsPopover: Bool) -> PipelineToolbar {
        PipelineToolbar(sheet: $sheet, confirmingReset: $confirmingReset,
                        dsp: dsp, io: io, hasPeer: hasPeer,
                        pickerAsPopover: pickerAsPopover,
                        pickerAnchored: $pickerAnchored, pickerInSheet: $pickerInSheet,
                        pluginError: $pluginError, afterSheet: $afterSheet)
    }

    /// 根の.sheetに渡すもの。**2列ではピッカーを普通はここへ出さない。**+に付けたpopoverが出す。
    /// +がまだ居ないうちに開いたときだけ、ここへ出す（pickerInSheet）。
    /// 1列では$sheetそのものと同じ。
    private var presentedSheet: Binding<Sheet?> {
        Binding(get: { usesSplit && sheet == .picker && !pickerInSheet ? nil : sheet },
                set: { sheet = $0 })
    }

    /// ピッカーを出す。空の鎖のAdd Effect、取り込んだJSFX、JSFXのリンク、撮影の-ETSheetはここを通す。
    ///
    /// 2列ではpopoverなので、**別のシートが出ていたら先に畳む。**シートが出ている上に
    /// popoverは出せない。1列は今までどおり、出ているシートと入れ替える。
    private func presentPicker() {
        guard usesSplit, let open = sheet, open != .picker else {
            openPicker()
            return
        }
        afterClosingSheet { openPicker() }
    }

    /// ピッカーを立てる。**2列で+がまだ画面に居なければ、popoverでなくシートで出す。**
    ///
    /// popoverは+を付け先にする。付け先が無いうちに出すと、UIKitが
    /// 「sourceViewかbarButtonItemが要る」（NSGenericException）で落とす。
    /// 起きた直後に共有の拡張がJSFXを置いていた（onAppearのdrainShared）、
    /// JSFXのリンクで起こされた（onOpenURL）、-ETSheet pickerで起こした、のどれもここへ来る。
    /// どちらで出すかは開くときに決め、閉じるまで変えない。途中で+が現れても、
    /// 出ているシートを畳んでpopoverへ出し直すことはしない。
    /// 既に出ているなら何もしない。
    private func openPicker() {
        guard sheet != .picker else { return }
        pickerInSheet = usesSplit && !pickerAnchored
        sheet = .picker
    }

    /// シートを出す。2列でピッカーのpopoverが出ていたら、先に畳んでから出す。
    /// popoverが畳み終わる前にシートを出すと、出ないまま残る。1列は今までどおり入れ替える。
    private func presentSheet(_ which: Sheet) {
        guard usesSplit, sheet == .picker else {
            sheet = which
            return
        }
        afterClosingSheet { sheet = which }
    }

    /// 窓の幅。**跨いだときだけ書く。**同じ値を書いても、送るたびの組み直しは起きないが、
    /// 窓の端を引いている間ずっと書くことになる。
    private func updateWideEnough(_ width: CGFloat) {
        // iPhoneは2列にしないので、測っても書かない。
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        if wideEnough, width < 620 {
            wideEnough = false
        } else if !wideEnough, width >= 640 {
            wideEnough = true
        }
    }

    /// 並べ方を切り替える（回したとき、Stage Managerで窓を広げ・狭めたとき、Split Viewの境を動かしたとき）。
    ///
    /// **前の並べ方が出ているうちに片付ける。**切り替えると行が全部作り直されるので、
    /// 掴んでいる行・払って開いている行はそのまま居なくなる。
    ///   - 掴みはその場で離す。戻る動きを待たない（戻る先の行がもう居ない）
    ///   - 払いは閉じる
    ///   - ピッカーは閉じる。1列ではシート、2列ではpopoverで、出し方が違う
    ///   - 読んでいたカードを覚え、新しい並べ方で上端へ戻す（restoreAnchor）
    /// 古い行の認識器から後で届くmovedは、行の側のguardが捨てる。
    private func flip(to split: Bool) {
        guard layoutSplit != split else { return }
        if dragging != nil {
            dragging = nil
            dragExternalSnapshot = nil
            dragShift = .zero
        }
        if swiping != nil {
            swipeX = 0
            swiping = nil
        }
        if sheet == .picker { sheet = nil }
        // 新しい並べ方の+が出るまでは付け先が無い。出れば+の側が立て直す。
        pickerAnchored = false
        let showing = usesSplit
        viewport.arm(split: showing)
        viewport.forget(split: showing)
        // 覚えた位置は前の並べ方のもの。新しい並べ方では選び直す。
        keeper.follow(nil, top: nil, offset: 0, order: [])
        geometry.reset()
        rowsHeight = 0
        layoutSplit = split
    }

    /// 足したカードが画面に無ければ、上端へ出す。**2列のときだけ。**
    ///
    /// 押して足す・落とす・JSFXが後から入る・プリセット・鎖ごとの入れ替えの全部が
    /// 鎖の並びの変化として来るので、足す口の側には何も書かない。
    /// 見えているかは行が測れてから決める（measured）。掴んでいる最中は触らない
    /// （組から出すときに無名のSectionが入る）。
    private func revealNew(_ old: [UUID], _ new: [UUID]) {
        guard usesSplit, dragging == nil else { return }
        let before = Set(old)
        let shown = Set(rows.map(\.node.id))
        guard let id = new.first(where: { !before.contains($0) && shown.contains($0) }) else { return }
        // **先に測れていたらここで決める。**新しい行の最初の測りとこのonChangeの
        // どちらが先に来るかは決まっていない。測りが先だと、待ちが残ったまま次に
        // 送ったときに消化され、人が送っている最中に飛んでいた。
        if let rect = geometry[id] {
            reveal(id, rect)
        } else {
            geometry.pendingReveal = id
        }
    }

    /// 行が測れた。並べ替えの判定と最後の帯の高さ、足したカードの確かめ、
    /// 2列で読んでいる位置を保つのに使う。
    private func measured(_ id: UUID, _ rect: CGRect) {
        geometry.record(id, rect)
        let height = geometry.contentHeight
        if rowsHeight != height { rowsHeight = height }
        if geometry.pendingReveal == id {
            geometry.pendingReveal = nil
            reveal(id, rect)
        }
        if id == keeper.id { keepReading(rect) }
    }

    /// 読んでいるカードが、送っていないのに動いた。動いたぶん送り直す（ETReadingKeeper）。
    ///
    /// **測れたその場で直す。**次の回へ回すと、その間はずれた位置のまま描かれうる。
    private func keepReading(_ rect: CGRect) {
        guard usesSplit, let scroll = brake.scrollView else { return }
        let top = -scroll.adjustedContentInset.top
        let offset = scroll.contentOffset.y
        let touched = scroll.isTracking || scroll.isDragging || scroll.isDecelerating
        let keeps = !touched && viewport.anchor == nil && offset > top + 0.5
        let moved = keeper.measured(top: rect.minY, offset: offset,
                                    order: dsp.chain.map(\.id), keeps: keeps)
        guard moved != 0 else { return }
        // 上が縮んだときは一番上より上へは送らない。
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: max(top, offset + moved)),
                                animated: false)
    }

    /// 読んでいるカードを選び直す。**2列のときだけ。**止まったときと、左の一覧で飛んだときに呼ぶ。
    ///
    /// `id`を渡せばそのカード。渡さなければ、上端が画面に入っている一番上のカード
    /// （無ければ、画面の上端にかかっているカード）。
    /// 上端にかかっているだけのカードは、見えていない上の部分が伸びても読む位置は動かないので、
    /// 上端が見えているカードのほうを選ぶ。
    private func followReading(_ id: UUID? = nil) {
        guard usesSplit, let scroll = brake.scrollView else { return }
        let order = dsp.chain.map(\.id)
        var chosen = id
        if chosen == nil {
            let visibleTop = scroll.adjustedContentInset.top
            let present = Set(order)
            var below: (id: UUID, y: CGFloat)?
            var above: (id: UUID, y: CGFloat)?
            for (row, rect) in geometry.rects where present.contains(row) {
                if rect.minY >= visibleTop - 1 {
                    if rect.minY < listHeight, rect.minY < (below?.y ?? .infinity) {
                        below = (row, rect.minY)
                    }
                } else if rect.minY > (above?.y ?? -.infinity) {
                    above = (row, rect.minY)
                }
            }
            chosen = below?.id ?? above?.id
        }
        keeper.follow(chosen, top: chosen.flatMap { geometry[$0]?.minY },
                      offset: scroll.contentOffset.y, order: order)
    }

    /// 足したカードが画面の外なら、そこへ飛ぶ。
    private func reveal(_ id: UUID, _ rect: CGRect) {
        // 矩形はScrollViewに付けた座標なので、0からlistHeightが見えている範囲。
        if rect.maxY <= 0 || rect.minY >= listHeight { viewport.request(id) }
    }

    /// 左の一覧から頼まれた所へ飛ぶ。**動かさない。**
    /// 動かすと通り道のカードが全部画面に入り、図が次々に起きる。
    /// 慣性で流れているとscrollToが効かないので、先に止める（ETScrollBrake）。
    private func jumpTo(_ jump: ETJump, _ proxy: ScrollViewProxy) {
        guard let id = jump.id else { return }
        // 飛んだ先を読んでいるカードにする。この後で上のカードが伸びても、そこに留まる。
        followReading(id)
        brake.jump {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(id, anchor: .top) }
        }
    }

    /// 覚えたカードを上端へ戻す。覚えていなければ何もしない。
    /// 切り替えた直後と、中身の高さが変わるたびに呼ぶ（AUの画面は遅れて大きさを決める）。
    private func restoreAnchor(_ proxy: ScrollViewProxy) {
        guard let id = viewport.anchor else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { proxy.scrollTo(id, anchor: .top) }
    }

    /// 左の一覧の行。右と同じ並びから作る。
    private func minimapItems(_ visible: [Row]) -> [ETMinimapItem] {
        visible.map { row in
            let node = row.node
            let name = node.isSection
                ? (node.sectionName.isEmpty ? "Section" : node.sectionName)
                : node.etDisplayName
            return ETMinimapItem(id: node.id,
                                 index: row.index,
                                 name: name,
                                 isSection: node.isSection,
                                 // 右で左に線が付く行（Sectionの配下）と同じ行を字下げする。
                                 indented: !node.isSection && row.block != .alone,
                                 enabled: node.enabled,
                                 muted: node.isMuted,
                                 levelTap: node.spec.type == "LevelMeterPlugin" ? node.tapId : nil)
        }
    }

    /// 取り込んだ結果を出す。「このアプリで開く」と共有の拡張で同じ出し方にする。
    private func show(_ received: ETInbox.Received, unsupported: String? = nil) {
        switch received {
        case .ir: presentSheet(.ir)
        // 取り込んだ JSFX は一覧に入る。そこから鎖へ足してもらう。
        case .jsfx: presentPicker()
        // **黙って落とさない。**押しても何も起きないのと見分けが付かない。
        case .failed(let why): presentError(why)
        case .unsupported: if let unsupported { presentError(unsupported) }
        }
    }

    /// 警告を出す。2列でピッカーのpopoverが出ていたら、先に畳んでから出す（presentSheetと同じ）。
    /// popoverの上には警告が出ない。1列は今までどおりその場で立てる。
    private func presentError(_ why: String) {
        guard usesSplit, sheet == .picker else {
            pluginError = why
            return
        }
        afterClosingSheet { pluginError = why }
    }

    /// 共有の拡張（EffectDeckShare）が App Group に置いたものを拾う。
    /// 起動時と、前へ出るたびに呼ぶ。拡張は判定できないので、ここで
    /// 「このアプリで開く」と同じ ETInbox.receive に通す。
    ///
    /// **音でも JSFX でもなかったときも出す。**「このアプリで開く」は OS が
    /// 型で候補を絞っているが、共有はリンクなので何でも来る。黙ると Add を
    /// 押したのに何も起きない形になる。
    private func drainShared() {
        guard let root = ETShareInbox.root else { return }
        for received in ETShareInbox.drain(in: root, { ETInbox.receive($0) }) {
            show(received, unsupported: ETInbox.unsupportedLink)
        }
    }

    /// 鎖。1列でも2列でも同じもの。`split`は2列の右に置くときに真。
    private func chainList(_ visible: [Row], split: Bool) -> some View {
        // **List ではなく ScrollView + VStack。**
        //
        // List は行の高さを動かす間も中身を切るので掴んだカードが欠ける。
        // それとは別に、**行の区切り線が視覚上どうしても出る**。
        // .listRowSeparator(.hidden) を付けても仕様として引かれる場所が残る。
        //
        // その代わり .swipeActions が使えない（List の行でしか効かない）ので、
        // 左スワイプの削除はここで自前でやる。判定は ETDragHandle の
        // UIPanGestureRecognizer（横向きのときだけ立つ）。
        //
        // 2列でもVStackのまま（LazyVStackにしない）。画面の外の行を畳むと
        // AUやJSFXの画面が外れ、並べ替えに要る矩形も消える。
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 0) {
            ClipboardBanner(dsp: dsp)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)

            if !hasPeer {
                ConnectBanner(openTips: { sheet = .tips })
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
                EmptyChainRow { presentPicker() }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 20)
            } else {
                ForEach(visible) { row in
                    // 見えているかを左の一覧へ知らせ、2列では見えていない図を止める。
                    ETLiveRow(id: row.node.id, split: split, viewport: viewport) {
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
                        // 2列では全部開く。iPhoneの開閉の覚えは読まない。
                        isExpanded: isOpen(row.node.id),
                        isCollapsedFully: !split && dsp.collapsedFully.contains(row.node.id),
                        toggleExpanded: split ? {} : { cycle(row.node) },
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
                        // 送るたびにも来るが、観測しない箱へ書くだけなのでbodyは走らない。
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named(Self.chainSpace))
                        } action: { measured(row.node.id, $0) }
                                .opacity(dragging == row.node.id ? 0 : 1)
                        // 掴みは UIKit の長押しで受ける（DragHandle.swift の頭）。
                        // 面は素通しなので、カードのタップも下へ届く。
                        // 2列の右では掴まない。並べ替えは左の一覧でやる。
                        .overlay {
                            ETDragHandle(
                                reorders: !split,
                                began: { beginDrag(row) },
                                moved: { d in
                                    // 並べ方を切り替えた後に、古い行の認識器から届いたものは捨てる。
                                    guard dragging == row.node.id else { return }
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
                    // 左の一覧から飛ぶ先。
                    .id(row.node.id)
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
            .modifier(ETDetailColumn(split: split, brake: brake))
        }
        // 触れたら戻す先の覚えを外す。そこから先は人が読む位置を決める。
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting { viewport.anchor = nil }
            // 止まったところで、読んでいるカードを選び直す（2列だけ）。
            if split, phase == .idle { followReading() }
        }
        // 覚えている間は、中身の高さが変わるたびに戻す（遅れて大きさを決めるAUの画面）。
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
            restoreAnchor(proxy)
        }
        // **器の背面で落とし先を受ける。**鎖が短いと、最後の段より下は
        // どの行にも属さない余白になる。中身を画面の高さまで伸ばす手もあるが、
        // GeometryReader で包むと外側の寸法の決まり方が変わって余白が崩れた。
        // 背面なら、行に落ちたものは行が先に受け、余った所だけここへ来る。
        // 2列の両脇の余白もここへ落ちる。
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
                        isExpanded: isOpen(row.node.id),
                        isCollapsedFully: !split && dsp.collapsedFully.contains(row.node.id),
                        toggleExpanded: {}, moveUp: {}, moveDown: {},
                        canMoveUp: false, canMoveDown: false,
                        externalSnapshot: dragExternalSnapshot,
                        isDragPreview: true, block: row.block)
                }
                // 行と同じ余白を付ける。矩形は余白の外側で測っているので、
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
        // 右の幅が変わった（回した、左の一覧を出し入れした）。読んでいたカードを上端に保つ。
        // 1列（iPhone）では何もしない。
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { old, new in
            guard split, old > 0, old != new else { return }
            // 覚えている最中なら覚え直さない。切り替えた直後は列が広がる間に何度も来て、
            // そのときの見えている範囲はまだ新しい並べ方のものではない。
            if viewport.anchor == nil { viewport.arm(split: true) }
            restoreAnchor(proxy)
        }
        .onChange(of: viewport.jump) { _, jump in jumpTo(jump, proxy) }
        // 並べ方を切り替えた直後。行が並んでから戻すので次の回に回す。
        .onAppear { Task { @MainActor in restoreAnchor(proxy) } }
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
        anchorRect = geometry[row.node.id] ?? .zero
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
        let slot = geometry[id] ?? anchorRect
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
    /// **入れ替えの動き（0.22 秒）の最中も安全。**行の矩形（`geometry`）はその間ずっと中間の値を
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

        if at > 0, let above = geometry[visible[at - 1].node.id], moving.minY < above.midY {
            swap(at, to: at - 1)
            return
        }
        if at < visible.count - 1, let below = geometry[visible[at + 1].node.id] {
            if moving.maxY > below.midY {
                // **組の最後から下へ出ようとしたら、組を閉じる。**
                // そのまま入れ替えると、次の組の見出しを飛び越えて
                // 今度はそちらの中に入るだけで、外に出ることができない。
                if visible[at].block == .bottom { leaveGroup(at); return }
                // 下へは 2 つ先。move(_:to:) は List の onMove と同じ数え方。
                swap(at, to: at + 2)
            }
        } else if visible[at].block == .bottom, let mine = geometry[id],
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
            guard chain[i].isSection, !isOpen(chain[i].id) else { continue }
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
                       isCollapsed: node.isSection && !isOpen(node.id))
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

    /// 開いたリンクを振り分ける（ETFXDLink.route）。
    ///
    /// 鎖はクリップボードの帯と同じ ETShareLink.parse で読む。**すぐには入れ替えない。**
    /// JSFX は一覧へ入れてピッカーを開く。ファイルで受けたときと同じ（ETInbox の .jsfx）。
    private func openLink(_ route: ETFXDLink.Route) {
        switch route {
        case .chain(let text):
            let loaded = ETShareLink.parse(text, catalog: ETCatalog)
            if loaded.isEmpty {
                afterClosingSheet { linkError = "That link had no chain in it." }
            } else {
                afterClosingSheet { pendingChain = loaded }
            }
        case .jsfx(let source):
            do {
                // **importText ではなく importSource。**リンクの中身は送り手のソースそのもので、
                // ``` の囲いを探して切ると別の 1 本になる。
                try ETJSFXHost.shared.importSource(source)
                presentPicker()
            } catch {
                // 読めた上で取り込めなかった（この版では JSFX を閉じている、など）。
                let why = error.localizedDescription
                afterClosingSheet { pluginError = why }
            }
        case .failed(let why):
            // リンクそのものが読めない。鎖が空のときと同じ題で出す。
            afterClosingSheet { linkError = why.localizedDescription }
        case .ignored:
            break
        }
    }

    /// **シートの上には確認も警告も出ない。畳み終えてから出す。**
    /// sheet = nil と出す側を同じ更新で立てると、畳む途中で出す側が落ちても
    /// 気づけない（鎖の確認なら、押したリンクが何もしなかった形になる）。
    /// 続きは .sheet の onDismiss（runAfterSheet）が走らせる。
    ///
    /// 2列のピッカーはpopoverで、onDismissを持たない。そちらはpopoverの中身が
    /// 消えたとき（PipelineToolbarのonDisappear）に、提示が片付くのを待ってから走らせる。
    private func afterClosingSheet(_ show: @escaping () -> Void) {
        guard sheet != nil else { show(); return }
        afterSheet = show
        sheet = nil
    }

    private func runAfterSheet() {
        let next = afterSheet
        afterSheet = nil
        next?()
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
            if visible[offset].node.isSection && !isOpen(visible[offset].node.id) {
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
    /// 2列のとき。+はシートではなく、自分に付けたpopoverでピッカーを出す。
    /// 閉じた後の続き（afterSheet）もこちらで走らせる。popoverはonDismissを持たないので。
    let pickerAsPopover: Bool
    /// +が画面に居るか。**立てるのはこちら**、読むのは親のopenPicker。
    @Binding var pickerAnchored: Bool
    /// 親がピッカーを根のシートで出したか。そのあいだpopoverは出さない。
    @Binding var pickerInSheet: Bool
    @Binding var pluginError: String?
    @Binding var afterSheet: (() -> Void)?

    /// popoverを出しているか。中身はsheetの.pickerで、根の.sheetはそれを見ない（presentedSheet）。
    /// 親がシートで出したときは偽のまま。
    private var pickerShown: Binding<Bool> {
        Binding(get: { sheet == .picker && !pickerInSheet },
                set: { if !$0, sheet == .picker, !pickerInSheet { sheet = nil } })
    }

    /// マスターの読み上げ。入切と、沈めている理由の両方を言う。
    /// 沈んでいることは目には見えても、読み上げには何も出ないため。
    private var voiceOverValue: String {
        let state = dsp.bypass ? "Bypassed" : "On"
        return hasPeer ? state : state + ", no audio"
    }

    /// popoverが閉じた後の続き（「Replace chain?」やJSFXの警告）を走らせる。
    ///
    /// **畳み終わるのを待つ。**popoverの中身のonDisappearは、畳む動きが終わる前に
    /// 来ることがある。その最中に確認や警告を出すと、出ないまま残る
    /// （シートのほうはonDismissで畳み終わりを待っている。afterClosingSheet）。
    private func runAfterPopover() {
        guard afterSheet != nil else { return }
        let after = $afterSheet
        Task { @MainActor in
            await ETPresentation.settled()
            let next = after.wrappedValue
            after.wrappedValue = nil
            next?()
        }
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
            if pickerAsPopover {
                // **+から出す。**選ぶたびに閉じる。つまんで運ぶと自分で閉じ、
                // 右のカード・余白、左の一覧の行の間のどれへでも落とせる。
                // 押せたなら+は画面に居る。popoverで出す。
                Button("Add Effect", systemImage: "plus") {
                    pickerInSheet = false
                    sheet = .picker
                }
                    .popover(isPresented: pickerShown) {
                        ETPickerHost(dsp: dsp, sheet: $sheet, pluginError: $pluginError,
                                     waitsForDismissal: true)
                            .frame(minWidth: 380, idealWidth: 420,
                                   minHeight: 520, idealHeight: 720)
                            .onDisappear { runAfterPopover() }
                    }
                    // **付け先ができたことを親へ知らせる。1回遅らせる。**
                    // 出てきた同じ回ではツールバーの項目がまだ組み上がっていないことがあり、
                    // 起きた直後のonAppear（drainSharedなど）もその回に走る。
                    // それより前に開いたものは親がシートで出す（openPicker）。
                    .onAppear {
                        Task { @MainActor in pickerAnchored = true }
                    }
                    .onDisappear { pickerAnchored = false }
            } else {
                Button("Add Effect", systemImage: "plus") { sheet = .picker }
            }
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

/// ピッカーと、選んだものを鎖へ足す4つの口。**シートでもpopoverでも同じものを出す。**
///
/// 足すのはいつも末尾（落として位置を決めるほうはPipelineView.addDropped）。
/// 閉じるのはこちら。ピッカーの中のdismiss()は、検索が出ている間シートではなく
/// 検索を閉じる。検索から選んだときだけ閉じない、という形になっていた。
struct ETPickerHost: View {
    let dsp: EffeTuneDSP
    @Binding var sheet: PipelineView.Sheet?
    @Binding var pluginError: String?
    /// popoverで出しているとき。足せなかった警告を、popoverが畳み終わってから出す。
    /// JSFXは音の準備が無いとその場で失敗し、閉じる途中に警告を立てると出ないまま残る。
    /// シート（1列）は今までどおりその場で立てる。
    var waitsForDismissal = false

    var body: some View {
        EffectPickerView(onPick: { spec in
            dsp.add(spec, at: nil)
            sheet = nil
        }, onPickAU: { entry in
            let instanceID = UUID().uuidString
            guard let externalIndex = try? ETAUExternalBridge.shared.reserve(
                instanceID: instanceID) else { return }
            dsp.addExternal(id: entry.id, instanceID: instanceID,
                            name: entry.name,
                            category: "Audio Units",
                            externalIndex: externalIndex, at: nil)
            ETAUHost.shared.create(entry, instanceID: instanceID)
            sheet = nil
        }, onPickJSFX: { entry in
            let instanceID = UUID().uuidString
            sheet = nil
            ETJSFXHost.shared.prepare(entry, instanceID: instanceID) { result in
                switch result {
                case .success(let externalIndex):
                    dsp.addExternal(id: entry.id, instanceID: instanceID,
                                    name: entry.name, category: "JSFX",
                                    externalIndex: externalIndex, at: nil)
                case .failure(let error): report(error.localizedDescription)
                }
            }
        }, onPickPreset: { name, items in
            // 名前の付いた Section に包んで挿す。置き換えない。
            // 鎖ごと置き換えたいときは Presets 画面のほう。
            dsp.addPreset(named: name, items: items, at: nil)
            sheet = nil
        })
    }

    private func report(_ why: String) {
        guard waitsForDismissal else {
            pluginError = why
            return
        }
        Task { @MainActor in
            await ETPresentation.settled()
            pluginError = why
        }
    }
}

/// 窓の上の提示（シート・popover・確認）が片付くのを待つ。
@MainActor
enum ETPresentation {
    /// 何も出ていなくなるまで待つ。最長1秒。**待つのは畳む動きの終わりだけ。**
    /// 決め打ちの時間で待つと、速い端末では余計に待たせ、遅い端末では足りない。
    static func settled() async {
        for _ in 0..<50 where busy {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static var busy: Bool {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.rootViewController else { return false }
        return presents(root)
    }

    /// 自分か子のどれかが何かを出しているか。2列では列ごとに子の器があり、
    /// popoverを出すのが根ではなく列の器のことがあるので、子まで見る。
    private static func presents(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains { presents($0) }
    }
}

/// 拡張が繋がっていない間だけ、鎖の一番上に出る。
/// 2本構成は普通ではないので、黙っていると詰まる。
private struct ConnectBanner: View {
    let openTips: () -> Void

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
                    // **出力を選ぶ押し所はこの帯に無い。** RoutePicker は中身を空にしてある
                    // （RoutePicker.swift の頭。置くとこのアプリが共有の出力
                    // コンテキストへ参加して、帰還ループに引きずられる）。
                    // 出す先を選べるのはコントロールセンターだけ。
                    // 右の Help は既知の制限の画面を開くだけ。
                    //
                    // **名乗っている名前は ET_ROUTE_NAME（EffectDeck）。**アプリ名と同じ字にしてある
                    // （Sources/Extension の displayName）。一覧に出る字と
                    // 揃えないと、どれを押せばよいのか分からない。
                    //
                    // **鳴らしてから選ぶ順は書かない**（#1 の訂正）。止めている間に選んでも
                    // 基本的に戻されない。一時停止が原因と確かめた失敗は無い。
                    Text("Pick EffectDeck as the output in Control Center.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                // **帯は選び損ねたときにも戻ってくる。**経路を戻されると繋がりが切れて
                // hasPeer が落ちるので、失敗を見分ける仕掛けを持たなくてもここに出る。
                // 原因は言わない。言わなければ外れることもない。
                //
                // 大きさは BypassBanner の Turn On に揃える（押せる面 44pt）。
                // 主の操作ではないので bordered。
                Button(action: openTips) {
                    Text("Help")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Known limitations")
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

/// 2列の右の鎖の列。**ScrollViewの内側で**カードの幅を絞り、左の一覧から飛ぶための止め具を付ける。
/// 内側で絞るので、両脇の余白も一緒に送れて、落とし先にもなる。
/// 1列では何もしない（今までの形のまま。440の絞りは外側、stack(_:)が付ける）。
private struct ETDetailColumn: ViewModifier {
    let split: Bool
    let brake: ETScrollBrake

    @ViewBuilder
    func body(content: Content) -> some View {
        if split {
            content
                .frame(maxWidth: ETLayout.detailMaxWidth)
                .frame(maxWidth: .infinity)
                .etScrollBrake(brake)
        } else {
            content
        }
    }
}
