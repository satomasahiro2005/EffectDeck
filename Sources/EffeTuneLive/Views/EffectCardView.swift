//  EffectCardView.swift
//  エフェクト 1 個ぶんのカード。
//
//  EffeTune は頭に「⋮ / ON / 名前」を置き、その下にパラメータを並べている。そこは同じ。
//  違うのは開閉で、頭を触ると畳める。既定は開いた状態。
//
//  ▲▼・削除は EffeTune では横に並んでいるが、場所を食うので ⋯ にまとめ、
//  並べ替えと削除はリストの標準の動き（長押しで移動・横に払って削除）に任せている。
//
//  Section だけは別の見た目にする（下の SectionCardView）。上流も同じ骨で作りつつ、
//  class に section を足して枠の色を変えている（js/ui/pipeline/pipeline-item-builder.js:28-29）。

import SwiftUI
import AVFoundation
import UIKit

struct EffectCardView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    let isExpanded: Bool
    /// 畳んでいて、図も出さない。`isExpanded` が真のときは意味を持たない。
    let isCollapsedFully: Bool
    let toggleExpanded: () -> Void
    /// ⋯ の Move Up / Move Down。**画面の隣の行**と入れ替える。
    ///
    /// 鎖の添字で 1 つ動かすと、隣が畳んだ Section の配下（画面に無い行）のときに
    /// そこへ入り込んで、動かした行が画面から消える。どこが隣かを知っているのは
    /// 行を組んでいる PipelineView なので、中身はあちらから渡してもらう。
    let moveUp: () -> Void
    let moveDown: () -> Void
    /// 画面の端の行か。鎖の本数ではなく**見えている行**で決める。
    let canMoveUp: Bool
    let canMoveDown: Bool
    /// Frozen AU UI used only by the floating reorder card.
    var externalSnapshot: UIImage? = nil
    /// Prevent a floating reorder card from mounting any live external UI even
    /// when the first frame has not arrived yet.
    var isDragPreview = false
    /// 組の中での位置。内側を向く角を角にする。
    var block: ETBlockPosition = .alone

    /// カードから開くもの。
    ///
    /// **1 枚にまとめる。** 同じビューに .sheet を積むと後から付けた方しか
    /// 出ない（PipelineView.swift:29-32 と IRReverbView.swift の fileImporter で
    /// 踏んでいる）。カードごとに 1 枚ずつ並ぶのは別の話で、そちらは問題ない。
    ///
    /// **PipelineView ではなくここが出す。** あちらの sheet は private で、
    /// どのカードから開いたかを運ぶ口も無い。
    private enum Sheet: String, Identifiable {
        /// この段だけの Routing。⋯ からと、印を押したときに開く。
        case routing
        /// エフェクト 1 個ぶんのプリセット。
        case presets
        case jsfxSource

        var id: String { rawValue }
    }

    @State private var sheet: Sheet?

    var body: some View {
        if node.isSection {
            SectionCardView(index: index, node: node, dsp: dsp,
                            isExpanded: isExpanded, toggleExpanded: toggleExpanded,
                            block: block)
        } else {
            effectCard
        }
    }

    private var effectCard: some View {
        Card(block: block) {
            VStack(alignment: .leading, spacing: 0) {
                header
                // **畳んでいても図を出すもの。**
                // Level Meter は畳むと「Analyzer」という字だけが残るが、
                // この道具は音が来ているかを見るために置くので、
                // 字より棒のほうが要る。図だけの形で細く出す。
                if !isExpanded && !isCollapsedFully && showsCollapsedGraph && !inlinesGraph {
                    // 図だけの形で下に置く。切らない。
                    // 一度 150pt で切ってみたが、横軸の字まで落ちて壊れて見えた。
                    // 高さが要るのは図がそれだけの情報を持っているからで、
                    // 畳んだ状態でも見たいものはそこにある。
                    ETEffectViews.view(index: index, node: node, dsp: dsp)
                        .environment(\.etGraphOnly, true)
                        .environment(\.etGraphMaxHeight, Self.collapsedGraphHeight)
                        .padding(.horizontal, ETMetrics.cardPadding)
                        .padding(.bottom, ETMetrics.cardPadding)
                        .allowsHitTesting(false)
                }
                if isExpanded && hasBody {
                    Group {
                        if node.isExternal {
                            ExternalProcessorView(externalID: node.externalID ?? "",
                                                  instanceID: node.externalInstanceID,
                                                  snapshot: externalSnapshot,
                                                  isDragPreview: isDragPreview)
                        } else if ETEffectViews.has(node.spec.type) {
                            // 専用の画面を持つものは、そちらがパラメータまで面倒を見る。
                            ETEffectViews.view(index: index, node: node, dsp: dsp)
                                .environment(\.etGraphOnly, false)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(node.spec.params) { param in
                                    ParameterRow(param: param, nodeIndex: index,
                                                 values: node.values, dsp: dsp)
                                }
                            }
                        }
                    }
                    .padding(ETMetrics.cardPadding)
                }
            }
        }
        .opacity(isMuted ? 0.55 : 1)
        .sheet(item: $sheet) { which in
            switch which {
            case .routing: EffectRoutingSheet(index: index, node: node, dsp: dsp)
            case .presets: EffectPresetsView(index: index, spec: node.spec, dsp: dsp)
            case .jsfxSource: JSFXSourceView(instanceID: node.externalInstanceID)
            }
        }
    }

    /// 音が通らない状態か。自分の入切と、上にある Section の入切の両方で決まる。
    ///
    /// 上流も同じ掛け算で、鎖の中の位置から区切りの入切を引いて
    /// plugin-disabled を付けている（js/ui/pipeline/pipeline-core.js:309-323）。
    /// 区切りの側の答えは sectionGate に入っている。
    /// DSP も `node.enabled == 0 || node.sectionGate == 0` で読み飛ばす
    /// （dsp/core/engine.cpp:919）ので、見た目の条件をそれに合わせる。
    private var isMuted: Bool { !node.enabled || node.sectionGate == 0 }

    private var header: some View {
        HStack(spacing: 6) {
            // Button ではなく Toggle。支援技術に入切が伝わるようにする。
            Toggle("Enabled", isOn: Binding(
                get: { node.enabled },
                set: { dsp.setEnabled($0, at: index) }))
                .toggleStyle(.power)
                .labelsHidden()
                .accessibilityLabel(node.spec.name)

            // **畳んだ Level Meter は図を名前の場所へ入れる。**
            // 横長の棒 2 本と目盛りなので、名前があった枠にそのまま収まる。
            // これでカードが 1 行になり、鎖の先頭に置いても場所を食わない。
            // 他の analyzer（図が縦に伸びるもの）は下に置く。
            if inlinesGraph {
                ETEffectViews.view(index: index, node: node, dsp: dsp)
                    .environment(\.etGraphOnly, true)
                    .allowsHitTesting(false)
                    .accessibilityLabel(node.spec.name)
            } else if !hidesName {
                VStack(alignment: .leading, spacing: 1) {
                    // 折り返さない。幅が足りないときは縮める。
                    // "Digital Error Emulator" や "Spectrum Analyzer" は iPhone 幅で
                    // 2 行に折れていた。
                    Text(displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                // 名前も図も頭には出さない（図は下に来る）。
                // 読み上げだけ残す。図は読み上げられないので。
                Color.clear.frame(width: 0, height: 0)
                    .accessibilityHidden(false)
                    .accessibilityLabel(node.spec.name)
            }

            Spacer(minLength: 4)

            // 既定（0→0 の All）から外れたものだけ出す。
            // 普通の鎖は一直線なので、普段は何も出ない。
            //
            // **出ているときは押せる。** 印が出ているということは行き先を
            // いじってあるということで、次に触りたいのもそこ。⋯ を開いて
            // Routing を選ぶより、目に見えている印をそのまま押すほうが速い。
            // 矢印を押し所にしていないのとは事情が違う（あちらは行を押すのと
            // 結果が同じだった）。
            if !node.isDefaultRouting || node.isGated {
                Button { sheet = .routing } label: {
                    Text(ETRouting.badge(node))
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint, in: .capsule)
                        .foregroundStyle(.white)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Routing \(ETRouting.badge(node))")
            }

            if hasBody {
                // **印であって押し所ではない。**
                // 押すのは行そのもの（下の onTapGesture）。
                // 矢印にも当たり判定があると、行の手つきと取り合って
                // 押せたり押せなかったりに見える。しかも文字を押すのと
                // 結果が同じなので、分ける意味が無い。
                // **右向き↔下向きにする。上向きにしない。**
                // 0°↔180°（下↔上）だと並べ替えの矢印に見える。カードは長押しで
                // 動かせるうえ、⋯ の中に Move Up / Move Down が上下の矢印で
                // 並んでいるので、同じ形が開閉にも使われていると取り違える。
                // 右→下は開閉の作法で、下の Section の印とも揃う。
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Menu {
                if node.externalID?.hasPrefix("jsfx:") == true {
                    Button { sheet = .jsfxSource } label: {
                        Label("View Source", systemImage: "doc.text.magnifyingglass")
                    }
                }
                // 並びは上流に合わせて routing → preset → reset
                // （js/ui/pipeline/pipeline-item-builder.js:133-145）。
                //
                // 全体の Routing はツールバーにもあるが、あちらは鎖を見渡す画面。
                // 「このカードの行き先」を変えたいときにここから直に開ける。
                Button { sheet = .routing } label: {
                    Label("Routing…", systemImage: "arrow.triangle.branch")
                }
                // 絵はしおり（上流 :360 の SVG も bookmark の d）。
                // **Reset Parameters とは別の口。**あちらは既定へ戻すもので、
                // プリセットの一覧に混ぜない。
                if !node.isExternal {
                    Button { sheet = .presets } label: {
                        Label("Effect Presets", systemImage: "bookmark")
                    }
                    Button { dsp.resetParams(at: index) } label: {
                        Label("Reset Parameters", systemImage: "arrow.counterclockwise")
                    }
                }
                Button(action: moveUp) {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(!canMoveUp)
                Button(action: moveDown) {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(!canMoveDown)
                Divider()
                Button(role: .destructive) {
                    dsp.remove(at: IndexSet(integer: index))
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
        }
        // 両端の部品は 44pt / 34pt の当たり判定を取っていて、絵の周りに 12pt / 9pt の
        // 余白を自分で持っている。器の内側（cardPadding = 14）をそのまま足すと、
        // 電源の絵だけが本文より 12pt 内側に入るうえ、名前に回る幅が 28pt 減って
        // iPhone 幅で 2 行に折れる。ここでは足りない分だけを足して、
        // 電源の絵の左端を本文の左端に揃える。
        .padding(.leading, 2)
        .padding(.trailing, 4)
        // 名前を出していないときは詰める。字が無いのに 2 行ぶんの高さを
        // 取ると、頭の行が空白のまま 44pt 居座る。
        // 図をこの行に入れているときは、図のぶんだけ少し戻す。
        .padding(.vertical, inlinesGraph ? 8 : (hidesName ? 2 : 10))
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasBody else { return }
            // **動かさない。**理由は PipelineView の cycle() の頭に書いた。
            //
            // withAnimation は閉包の中で起きた書き換えすべてに掛かるので、
            // cycle() の側から外しても、ここで包み直せば同じことになる。
            // 20fps で撮って測ったら、指で触る道は今も 0.2 秒伸び縮みしていて、
            // 上の行が丸ごと消える枠・板が落ちて字だけ浮く枠・図が二重に
            // 描かれる枠が 1 サイクルに 4〜5 枚ずつ写った。1 番目でも出る。
            toggleExpanded()
        }
    }

    /// 頭に名前を出さないか。**図を名前の場所へ入れるときだけ。**
    ///
    /// 名前を消して図を下に置くと、頭の行が空のまま残って場所を食う。
    /// 名前が要らないのは、図がその場所に収まって 1 行になるものだけ。
    /// 畳んだときに図へ許す高さ。
    ///
    /// **畳んだら縮むこと。** 以前は図の言い値のままで、Stereo Meter のように
    /// 幅から正方形を作るものは 340pt 前後になり、畳んでもカードが縮まなかった。
    /// 一度 150pt で切ってみたが、外から切ると横軸の字まで落ちて壊れて見えた。
    /// いまは GraphCanvas が自分の高さを決めるときに上限として使うので、
    /// 中身はこの高さに収まる形で引き直される。
    static let collapsedGraphHeight: CGFloat = 132

    private var hidesName: Bool { inlinesGraph }

    /// 図を名前の場所へ入れるか。**横長で背の低い図だけ。**
    ///
    /// Level Meter は棒 2 本と目盛りで、名前 2 行ぶんの高さに収まる。
    /// しかも棒を見れば何かは分かるので、"Level Meter / Analyzer" の字は
    /// 同じことを二度書いている。
    /// Spectrum Analyzer や Stereo Meter は図が縦に伸びるので入らない。
    /// そちらは名前を残して、図はその下に置く。
    private var inlinesGraph: Bool {
        showsCollapsedGraph && !isExpanded && !isCollapsedFully
            && node.spec.type == "LevelMeterPlugin"
    }


    /// 畳んでいるあいだも図を出すか。**図を持つものは全部そうする。**
    ///
    /// 畳んで字だけにしても「Analyzer」としか出ない。この分類は見るために
    /// 鎖へ入れるものなので、畳んだ状態でも動いているものが見えたほうがよい。
    /// 出すのは図だけの形（つまみも目盛りも畳んだもの）なので、
    /// 一覧としての高さは字 1 行ぶんより少し増える程度に収まる。
    /// 畳んだときに図だけを出すか。
    ///
    /// **`has` ではなく `hasGraph`。** 専用の画面はあるが図は描かないもの
    /// （IR Reverb）を `has` で拾うと、畳んでいるのに取り込む口と状態行が
    /// そのまま出て、隣のカードに重なってボタンを塞ぐ（実機で確認）。
    private var showsCollapsedGraph: Bool { ETEffectViews.hasGraph(node.spec.type) }


    /// 開いて出すものがあるか。図だけのエフェクト（Level Meter など）も開ける。
    private var hasBody: Bool {
        node.isExternal || !node.spec.params.isEmpty || ETEffectViews.has(node.spec.type)
    }

    /// 1 行目に出す名前。
    ///
    /// 古い鎖は AU の名前に "Vendor: " が付いている（足すときに entry.title を渡していた
    /// 頃のもの）。作者は 2 行目へ移したので二重になる。**作者名と一致する頭だけ**落とす。
    /// 端末から AU を消すと作者が空になり、そのときは落とせないまま出る。
    private var displayName: String {
        guard let externalID = node.externalID else { return node.spec.name }
        let author = ETPluginLabel.author(externalID: externalID)
        guard !author.isEmpty, node.spec.name.hasPrefix(author + ": ") else { return node.spec.name }
        return String(node.spec.name.dropFirst(author.count + 2))
    }

    /// 畳んでいるときに何をしているかが分かるよう、主要な値を 1 行にする。
    ///
    /// 開いているときは同じ値がすぐ下に出ているので、分類の方を出す。
    /// そうしないと、どのエフェクトなのかを言う行が頭から消える。
    private var summary: String {
        // 外から来たものは、分類の隣に作者を出す。
        // AU の作者は取れていたのに、名前の接頭辞（"Vendor: Name"）として 1 行目へ
        // 混ざっていた。名前欄は lineLimit(1) なので、長いと肝心のプラグイン名が
        // 末尾から落ちる。作者はこちらへ移した。
        if let externalID = node.externalID {
            return ETPluginLabel.detail(format: node.spec.category.categoryLabel,
                                        author: ETPluginLabel.author(externalID: externalID))
        }
        if isExpanded && hasBody { return node.spec.category.categoryLabel }
        // 畳んだ状態で図を出すものは、その下に図が来る。
        // 字でも分類名しか出ないので、分類を出しておく（重複しない）。
        if !isExpanded && !isCollapsedFully && showsCollapsedGraph {
            return node.spec.category.categoryLabel
        }
        guard !node.spec.params.isEmpty else { return node.spec.category.categoryLabel }
        let shown = node.spec.params.prefix(3).compactMap { param -> String? in
            guard !param.isArray,
                  node.values.indices.contains(param.offset) else { return nil }
            let v = node.values[param.offset]
            // 既定のままの値は出さない。触った所だけを見せる。
            // 選択肢（.enumeration）にも同じ物差しを当てる。ここを抜いていたので、
            // SBC Codec Simulator は既定のまま "Channel Mode Joint Stereo" を出し、
            // Digital Error Emulator は "Mode 10A" を出して、分類を押し出していた。
            guard v != param.defaultValue else { return nil }
            return "\(param.label) \(valueText(param, v))"
        }
        return shown.isEmpty ? node.spec.category.categoryLabel : shown.joined(separator: " · ")
    }

    /// 値 1 個ぶんの文字列。
    ///
    /// ETParam.format は入切を「入 / 切」で返す（EffectSpec.swift:37-38）。
    /// 画面に出す文言は英語なので、入切だけここで組む。
    private func valueText(_ param: ETParam, _ v: Float) -> String {
        if case .toggle = param.kind { return v >= 0.5 ? "On" : "Off" }
        return param.format(v)
    }
}

/// AU parameters are deliberately presented by the external node rather than
/// by a fixed post-insert settings screen. The selected AU host owns the
/// parameter tree and persists values; this view only provides the same inline
/// editing affordance as native EffeTune parameters.
private struct ExternalProcessorView: View {
    @ObservedObject private var au = ETAUHost.shared
    @ObservedObject private var jsfx = ETJSFXHost.shared
    @ObservedObject private var prefs = Preferences.shared
    let externalID: String
    let instanceID: String
    let snapshot: UIImage?
    let isDragPreview: Bool
    @State private var controller: UIViewController?
    @State private var requestingView = false
    @State private var fullScreen = false
    @State private var movingToFullScreen = false
    @State private var isOnScreen = true

    var body: some View {
        let parameters = au.parameters(instanceID: instanceID)
        Group {
        if isDragPreview {
            // Reorder overlays must be inert for every external processor.
            // Mounting a second JSFX canvas changes the same VM's gfx_w/gfx_h
            // and its disappearance can hide the surviving inline window.
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(minHeight: 180, idealHeight: 300, maxHeight: 520)
            } else {
                Color.black.frame(height: 180)
            }
        } else if externalID.hasPrefix("jsfx:") {
            let jsfxParameters = jsfx.parameters(instanceID: instanceID)
            if jsfx.hasGFX(instanceID: instanceID) {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack(alignment: .topTrailing) {
                        if prefs.jsfxCanvasMode == .pixelPerfect {
                            let size = jsfx.preferredGFXSize(instanceID: instanceID)
                            ScrollView([.horizontal, .vertical]) {
                                JSFXGFXView(instanceID: instanceID, fixedSize: size,
                                            isVisible: isOnScreen && !fullScreen)
                            }
                            .frame(height: min(360, max(180, size.height)))
                        } else {
                            JSFXGFXView(instanceID: instanceID,
                                        isVisible: isOnScreen && !fullScreen)
                        }
                        Button {
                                movingToFullScreen = true
                                Task { @MainActor in
                                    await Task.yield()
                                    ETInterfaceOrientation.request(.landscapeRight)
                                    for _ in 0..<40 where !ETInterfaceOrientation.isLandscape {
                                        try? await Task.sleep(nanoseconds: 20_000_000)
                                    }
                                    fullScreen = true
                                }
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .accessibilityLabel("Full Screen")
                        .buttonStyle(.glass(.regular.interactive()))
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .padding(8)
                    }
                    .fullScreenCover(isPresented: $fullScreen, onDismiss: {
                        ETInterfaceOrientation.request(.portrait)
                        movingToFullScreen = false
                    }) {
                        JSFXFullScreenEditor(instanceID: instanceID,
                                             isPresented: $fullScreen)
                    }
                    jsfxParameterRows(jsfxParameters)
                    jsfxTriggers
                }
            } else if jsfxParameters.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(jsfx.status(instanceID: instanceID))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    jsfxTriggers
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    jsfxParameterRows(jsfxParameters)
                    jsfxTriggers
                }
            }
        } else if let controller {
            ZStack(alignment: .topTrailing) {
                if movingToFullScreen {
                    Color.clear.frame(height: 260)
                } else {
                    ETAUViewControllerHost(controller: controller)
                        .frame(minHeight: 260, idealHeight: 360, maxHeight: 520)
                }
                Button {
                    movingToFullScreen = true
                    Task { @MainActor in
                        // Rotate the scene before presenting the AU. This
                        // avoids drawing one portrait frame of the plug-in
                        // and then snapping it sideways.
                        await Task.yield()
                        ETInterfaceOrientation.request(.landscapeRight)
                        for _ in 0..<40 where !ETInterfaceOrientation.isLandscape {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        fullScreen = true
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.glass(.regular.interactive()))
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Full Screen")
                .padding(8)
            }
            .fullScreenCover(isPresented: $fullScreen, onDismiss: {
                ETInterfaceOrientation.request(.portrait)
                movingToFullScreen = false
            }) {
                ETAUFullScreenEditor(controller: controller, isPresented: $fullScreen)
            }
        } else if parameters.isEmpty {
            Text(au.status(instanceID: instanceID))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(parameters, id: \.address) { parameter in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(parameter.displayName)
                                .font(.footnote)
                            Spacer()
                            // `%.3g` は 1000 を `1e+03` にするので使わない。
                            // 打ち込みもできる欄にする（読み取り専用の Text だった）。
                            ETValueField(text: ETNumberText.plain(Double(parameter.value)),
                                         label: parameter.displayName,
                                         editText: { ETNumberText.draft(Double(parameter.value)) }) { typed in
                                let lo = Double(parameter.minValue)
                                let hi = Double(parameter.maxValue)
                                au.setParameter(parameter, value: min(max(typed, lo), hi))
                            }
                        }
                        Slider(value: Binding(
                            get: { Double(parameter.value) },
                            set: { au.setParameter(parameter, value: $0) }),
                            in: Double(parameter.minValue)...Double(parameter.maxValue))
                    }
                }
            }
        }
        }
        .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
        .task(id: au.revision) {
            // The card normally opens before asynchronous AU instantiation has
            // finished. Retry when the host revision changes; the old one-shot
            // onAppear permanently missed every native view in that common case.
            guard controller == nil, !requestingView,
                  au.providesUserInterface(instanceID: instanceID) == true else { return }
            requestingView = true
            au.requestViewController(instanceID: instanceID) {
                controller = $0
                requestingView = false
            }
        }
    }

    @ViewBuilder
    private func jsfxParameterRows(_ parameters: [ETJSFXHost.Parameter]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parameters) { parameter in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(parameter.name).font(.footnote)
                        Spacer()
                        Text(String(format: "%.3g", parameter.value))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if parameter.isEnumeration {
                        Picker(parameter.name, selection: Binding(
                            get: { Int(parameter.value.rounded()) },
                            set: { jsfx.setParameter(instanceID: instanceID,
                                                     parameterID: parameter.id, value: Double($0)) })) {
                            ForEach(Array(parameter.enumNames.enumerated()), id: \.offset) {
                                Text($0.element).tag($0.offset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } else if parameter.maximum > parameter.minimum {
                        Slider(value: Binding(
                            get: { jsfx.normalizedValue(instanceID: instanceID,
                                                       parameterID: parameter.id,
                                                       value: parameter.value) },
                            set: { jsfx.setNormalizedParameter(instanceID: instanceID,
                                                               parameterID: parameter.id, value: $0) }),
                               in: 0...1)
                    }
                }
            }
        }
    }


    private var jsfxTriggers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Triggers").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<10, id: \.self) { index in
                    Button("\(index + 1)") {
                        jsfx.sendTrigger(instanceID: instanceID, index: UInt32(index))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct JSFXGFXView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var jsfx = ETJSFXHost.shared
    let instanceID: String
    var fixedSize: CGSize? = nil
    var fullScreen = false
    var isVisible = true
    @State private var image: CGImage?
    @State private var drawing = false
    @State private var windowOwner = UUID()

    var body: some View {
        let preferred = jsfx.preferredGFXSize(instanceID: instanceID)
        let retina = jsfx.gfxWantsRetina(instanceID: instanceID)
        GeometryReader { geometry in
            let active = isVisible && scenePhase == .active
            let renderKey = JSFXGFXRenderKey(width: Int(geometry.size.width.rounded()),
                                             height: Int(geometry.size.height.rounded()),
                                             active: active)
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: UIScreen.main.scale)
                        .resizable()
                        .interpolation(retina ? .high : .none)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                JSFXKeyboardCapture(instanceID: instanceID)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let scale = jsfx.gfxPixelScale(instanceID: instanceID,
                                                   size: geometry.size,
                                                   screenScale: UIScreen.main.scale)
                    jsfx.updateMouse(instanceID: instanceID,
                                     point: CGPoint(x: value.location.x * scale,
                                                    y: value.location.y * scale),
                                     buttons: 1)
                }
                .onEnded { value in
                    let scale = jsfx.gfxPixelScale(instanceID: instanceID,
                                                   size: geometry.size,
                                                   screenScale: UIScreen.main.scale)
                    jsfx.updateMouse(instanceID: instanceID,
                                     point: CGPoint(x: value.location.x * scale,
                                                    y: value.location.y * scale),
                                     buttons: 0)
                })
            .task(id: renderKey) {
                guard active else { return }
                let fps = max(1, min(120, jsfx.gfxFrameRate(instanceID: instanceID)))
                while !Task.isCancelled {
                    if !drawing {
                        drawing = true
                        jsfx.renderGFX(instanceID: instanceID, size: geometry.size,
                                       scale: UIScreen.main.scale) {
                            if let rendered = $0 { image = rendered }
                            drawing = false
                        }
                    }
                    do {
                        try await Task.sleep(for: .seconds(1.0 / Double(fps)))
                    } catch {
                        break
                    }
                }
            }
            .onChange(of: active, initial: true) { _, active in
                jsfx.updateGFXWindow(instanceID: instanceID, owner: windowOwner,
                                     focused: active, visible: active)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .modifier(JSFXGFXLayout(preferred: fixedSize ?? preferred,
                                fixedSize: fixedSize, fullScreen: fullScreen))
        .clipped()
        .onDisappear {
            jsfx.updateGFXWindow(instanceID: instanceID, owner: windowOwner,
                                 focused: false, visible: false)
        }
    }
}

private struct JSFXGFXRenderKey: Hashable {
    let width: Int
    let height: Int
    let active: Bool
}

private struct JSFXGFXLayout: ViewModifier {
    let preferred: CGSize
    let fixedSize: CGSize?
    let fullScreen: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let fixedSize {
            content.frame(width: fixedSize.width, height: fixedSize.height)
        } else if fullScreen {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
                .aspectRatio(max(0.25, preferred.width / max(1, preferred.height)),
                             contentMode: .fit)
                .frame(minHeight: 180, maxHeight: 360)
        }
    }
}

private struct JSFXFullScreenEditor: View {
    let instanceID: String
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            JSFXGFXView(instanceID: instanceID, fullScreen: true)
                // Give the newly-created canvas the complete landscape safe
                // area. A one-sided safeAreaPadding left its proposal at the
                // inline width on some presentation transitions.
                .padding(8)
            Button { isPresented = false } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close")
            .font(.system(size: 15, weight: .bold))
            .buttonStyle(.glass(.regular.interactive()))
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .padding(.top, 8)
            .padding(.trailing, 12)
        }
    }
}

private struct JSFXSourceView: View {
    @Environment(\.dismiss) private var dismiss
    let instanceID: String

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Text(ETJSFXHost.shared.sourceText(instanceID: instanceID) ?? "Source unavailable")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            .navigationTitle("JSFX Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct JSFXKeyboardCapture: UIViewRepresentable {
    let instanceID: String
    func makeUIView(context: Context) -> ETJSFXKeyboardView {
        let view = ETJSFXKeyboardView()
        view.instanceID = instanceID
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }
    func updateUIView(_ view: ETJSFXKeyboardView, context: Context) {
        view.instanceID = instanceID
    }
}

private final class ETJSFXKeyboardView: UIView {
    var instanceID = ""
    override var canBecomeFirstResponder: Bool { true }

    private func event(_ press: UIPress, pressed: Bool) {
        guard let key = press.key else { return }
        var modifiers: UInt32 = 0
        if key.modifierFlags.contains(.shift) { modifiers |= 1 }
        if key.modifierFlags.contains(.control) { modifiers |= 2 }
        if key.modifierFlags.contains(.alternate) { modifiers |= 4 }
        if key.modifierFlags.contains(.command) { modifiers |= 8 }
        let special: [UIKeyboardHIDUsage: UInt32] = [
            .keyboardDeleteOrBackspace: 0x08, .keyboardEscape: 0x1b,
            .keyboardDeleteForward: 0x7f, .keyboardLeftArrow: 0xe00c,
            .keyboardUpArrow: 0xe00d, .keyboardRightArrow: 0xe00e,
            .keyboardDownArrow: 0xe00f, .keyboardHome: 0xe012,
            .keyboardEnd: 0xe013, .keyboardInsert: 0xe014
        ]
        let code = special[key.keyCode]
            ?? key.charactersIgnoringModifiers.unicodeScalars.first.map(\.value)
        guard let code else { return }
        ETJSFXHost.shared.updateKey(instanceID: instanceID, modifiers: modifiers,
                                    key: code, pressed: pressed)
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        presses.forEach { self.event($0, pressed: true) }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        presses.forEach { self.event($0, pressed: false) }
        super.pressesEnded(presses, with: event)
    }
}

private struct ETAUFullScreenEditor: View {
    let controller: UIViewController
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ETAUViewControllerHost(controller: controller)
                .padding(.top, 8)
                .background(Color(uiColor: .systemBackground))
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
            }
                .buttonStyle(.glass(.regular.interactive()))
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Close")
                .padding(.top, 8)
                .padding(.trailing, 12)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
}

@MainActor
private enum ETInterfaceOrientation {
    static var isLandscape: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation.isLandscape == true
    }

    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        ETAppDelegate.supportedOrientations = mask
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            print("orientation request failed: \(error.localizedDescription)")
        }
    }
}

private struct ETAUViewControllerHost: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> ETAUContainerViewController {
        let container = ETAUContainerViewController()
        container.attach(controller)
        return container
    }

    func updateUIViewController(_ container: ETAUContainerViewController, context: Context) {
        container.attach(controller)
    }

    static func dismantleUIViewController(_ container: ETAUContainerViewController,
                                           coordinator: ()) {
        container.detach()
    }
}

/// Owns the AU view explicitly. SwiftUI may destroy/recreate a card while it is
/// reordered; returning the AU controller itself leaves it parented to the old
/// representable and the new card becomes blank. This container reparents it
/// and pins the plug-in view to every edge for both inline and full-screen use.
private final class ETAUContainerViewController: UIViewController {
    private weak var hosted: UIViewController?

    func attach(_ controller: UIViewController) {
        guard hosted !== controller || controller.parent !== self else { return }
        if let parent = controller.parent, parent !== self {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        if hosted !== controller { detach() }
        hosted = controller
        guard controller.parent !== self else { return }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    func detach() {
        guard let controller = hosted, controller.parent === self else {
            hosted = nil
            return
        }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        hosted = nil
    }
}

/// Section の行。音は触らず、下に続くエフェクトをひとまとまりにする。
///
/// 上流との対応:
///   - 枠を緑にして普通の行と分ける（effetune.css:1103-1108 の
///     `.pipeline-item.section` が 2px 実線の `--et-success`、
///      その値は effetune-theme.css:6 の #4CAF50）。
///     こちらはシステムの緑で、同じ値ではない。数値の色を持たないのは
///     Components.swift の方針に合わせたもの
///   - 頭に出すのは `"<cm> Section"`。cm が空なら `"Section"` だけ
///     （js/ui/pipeline/pipeline-item-builder.js:238-242）
///   - 名前を打ち込む欄は上流ではカードの中（plugins/control/section.js の createUI）。
///     こちらは開く中身が他に無いので頭へ出す
///   - ルーティングのボタンは出さない（pipeline-item-builder.js:133）
///   - プリセットの UI も出さない（section.js の `hidePresetUI = true`）
///
/// 畳みは上流と意味が違う。上流の Shift+Click は区切りの範囲ぶんの
/// **パラメータ UI** をまとめて開閉するだけで、行そのものは残る
/// （pipeline-item-builder.js:795-836）。iPhone は縦しか無いので、
/// こちらは行ごと隠す（隠すのは PipelineView）。何本隠れているかを頭に出すのは、
/// 行が消える以上どこへ行ったのかが分からなくなるため。
private struct SectionCardView: View {
    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    var block: ETBlockPosition = .alone

    /// 打ち込み中の文字。確定するまで dsp へ渡さない。
    ///
    /// 上流は input のたびに updateParameters() を呼んでいる（section.js）が、
    /// こちらで同じことをすると 1 打鍵ごとに @Published chain が変わり、
    /// 画面が丸ごと作り直される。ツールバーと ⋯ の Menu が "Loading…" のまま
    /// 固まるのがこれなので、確定（改行・欄から離れる）でだけ書く。
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        Card(block: block) {
            // 間隔と余白はエフェクトの頭と同じ。隣り合う札なので、
            // 電源の絵と名前の左端が揃っていないと目に付く。
            HStack(spacing: 6) {
                // Section 自身の入切。切ると次の Section の手前までが止まる
                // （dsp-pipeline-descriptor.js:190-201 / engine.cpp:919）。
                Toggle("Enabled", isOn: Binding(
                    get: { node.enabled },
                    set: { dsp.setEnabled($0, at: index) }))
                    .toggleStyle(.power)
                    .labelsHidden()
                    .accessibilityLabel(accessibilityName)

                VStack(alignment: .leading, spacing: 1) {
                    // 上流の placeholder は "Enter the section name"（section.js）。
                    // 幅が無いので短くしてある。
                    TextField("Section name", text: $draft)
                        .font(.system(size: 16, weight: .semibold))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($editing)
                        .onSubmit { commit() }

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // 畳む・開く。Menu にはしない（提示が終わらない件を追っている最中で、
                // 原因は高頻度の再描画）。1 手で効く直のボタンにする。
                Button {
                    if editing { commit() }
                    // **動かさない。**カードの側（上の onTapGesture）と同じ。
                    // Section は配下の行そのものが増え減りするので、包むと
                    // 行の抜き差しにも動きが掛かる。
                    toggleExpanded()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: ETMetrics.hitTarget, height: ETMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isExpanded ? "Collapse section" : "Expand section")
            }
            .padding(.leading, 2)
            .padding(.vertical, 10)
        }
        .opacity(node.enabled ? 1 : 0.55)
        .onAppear { draft = node.sectionName }
        .onChange(of: node.sectionName) { _, now in
            // プリセットや共有リンクの取り込みで名前が外から変わる。
            // 打ち込んでいる最中は上書きしない（section.js の registerUIRefresh と同じ）。
            if !editing { draft = now }
        }
        .onChange(of: editing) { _, now in
            if !now { commit() }
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = name
        guard name != node.sectionName else { return }
        dsp.setSectionName(name, at: index)
    }

    /// 頭に出す行。Section の名前は欄そのものなので、ここには種別と中身の数を出す。
    private var subtitle: String {
        let n = ETSection.range(after: index, types: dsp.chain.map(\.spec.type)).count
        guard n > 0 else { return "Section" }
        let effects = "\(n) effect\(n == 1 ? "" : "s")"
        return isExpanded ? "Section · \(effects)" : "Section · \(effects) hidden"
    }

    /// 支援技術へ渡す名前。上流の表示と同じ組み立て
    /// （pipeline-item-builder.js:238-242）。
    private var accessibilityName: String {
        node.sectionName.isEmpty ? "Section" : "\(node.sectionName) Section"
    }
}
