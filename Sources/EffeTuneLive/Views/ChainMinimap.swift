//  ChainMinimap.swift
//  2列のときの左の一覧。REAPERのFX chainの左の欄にあたる。
//
//  鎖の1行（エフェクトかSection）につき1行。**高さは全部同じ44pt**（Listの詰めた行の高さ）で、
//  名前だけを出す。右は鎖を全部開いて並べているので、ここは「どこに何があるか」と「動かす」の場所。
//
//    - 行を押すと、右がそのカードへその場で飛ぶ（動かさない。動かすと通り道の図が全部起きる）
//    - 右で見えているカードの行は地に色が付く
//    - 並べ替えはここだけ（ListのonMove。長押しで掴む）。右の長押しは2列では切ってある
//    - ピッカーからつまんだものは行の間へ落とせる（onInsert）
//    - 頭の電源はカードの電源と同じもの。別の入切を持たない
//    - Level Meterの行だけ、クリップしたときに行の右端へOVERLOADの札を出す（カードと同じ決め方）
//    - 一番下に出力補正の行（右の鎖の下の行と同じもの）。鎖の項目ではないので掴めない。
//      落としたものは鎖の末尾へ（右の出力補正の行と同じ）
//    - その下の空きは末尾の帯（ETMinimapTail）が埋め、落としたものは鎖の末尾へ（右の末尾の帯と同じ）
//
//  行の並びは右と同じrowsから作る（PipelineView.minimapItems）。
//  onMoveの数え方がそのままmove(_:to:)の数え方になる。

import SwiftUI
import UniformTypeIdentifiers

/// 左の一覧の1行ぶん。PipelineViewのrowsから作る。
struct ETMinimapItem: Identifiable, Equatable {
    let id: UUID
    /// 鎖の中の位置。入切を書くのに使う。
    let index: Int
    let name: String
    let isSection: Bool
    /// Sectionの配下。字下げする。
    let indented: Bool
    let enabled: Bool
    /// 音が通らない（自分が切ってある、またはSectionに止められている）。薄く出す。
    let muted: Bool
    /// Level Meterのときだけ、棒を読むtap。
    let levelTap: UInt32?
}

/// 左の一覧の行に付ける身元。**右のカードの身元（UUID）と型を分ける。**
/// 右のscrollTo(UUID)が左の行に当たらないように。
struct ETMinimapID: Hashable {
    let id: UUID
}

struct ChainMinimap: View {
    let items: [ETMinimapItem]
    let dsp: EffeTuneDSP
    let viewport: ETChainViewport
    /// 右の出力補正の行の身元。nilなら出さない（PCの鎖を編集している間。右も出していない）。
    let correction: UUID?
    /// 画面の行番号で動かす。ListのonMoveと同じ数え方。
    let move: (IndexSet, Int) -> Void
    /// ピッカーから運ばれた文字列と、落とした先（鎖の添字）。
    let insert: (String, ETChainEditing.AddTarget) -> Void

    @State private var tracker = ETMinimapTracker()
    /// 末尾の帯の高さ。一覧が画面を埋めていないときは残りを埋める（ETMinimapTail）。
    @State private var tail: CGFloat = ETMinimapRow.height

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(items) { item in
                    ETMinimapRow(item: item, dsp: dsp, viewport: viewport, tracker: tracker)
                        .id(ETMinimapID(id: item.id))
                }
                .onMove(perform: move)
                .onInsert(of: [.plainText]) { offset, providers in
                    // 落とした行の手前へ。一番下なら末尾。
                    let at: ETChainEditing.AddTarget = items.indices.contains(offset)
                        ? .gap(items[offset].index) : .end
                    guard let provider = providers.first else { return }
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let text = object as? NSString else { return }
                        let payload = text as String
                        Task { @MainActor in insert(payload, at) }
                    }
                }
                // **ForEachの外に置く。**onMove・onInsertの数え方に入れない（動かせず、ここへは落とせない）。
                if let correction {
                    ETMinimapCorrectionRow(id: correction, viewport: viewport, insert: insert)
                        .id(ETMinimapID(id: correction))
                }
                ETMinimapTail(height: tail, insert: insert)
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, ETMinimapRow.height)
            // 帯の高さ = 見えている高さ − 帯より上の合計（中身 − いまの帯）。
            // **位置でなく高さで出す。**送っても変わらないので、帯が変わる→また送れる、の堂々巡りにならない
            // （PipelineView.tailHeightと同じ理由）。切り捨てて、短い一覧が送れるようにしない。
            .onScrollGeometryChange(for: ETMinimapSpace.self) {
                ETMinimapSpace(content: $0.contentSize.height,
                               visible: $0.containerSize.height - $0.contentInsets.top - $0.contentInsets.bottom)
            } action: { _, space in
                let want = max(ETMinimapRow.height, (space.visible - (space.content - tail)).rounded(.down))
                if abs(want - tail) >= 1 { tail = want }
            }
            .onScrollPhaseChange { _, phase in tracker.phase = phase }
            .background {
                ETMinimapFollow(viewport: viewport, tracker: tracker, proxy: proxy)
            }
        }
    }
}

/// 左の一覧が自分で持つ覚え。**観測しない。**書くたびに一覧が組み直されないように。
@MainActor
private final class ETMinimapTracker {
    /// 一覧そのものの送りの状態。人が送っている間は付いて送らない。
    var phase: ScrollPhase = .idle
    /// 9割以上見えている行。
    var shown: Set<UUID> = []
}

/// 右の一番上のカードが変わったら、その行が見えるところまで一覧を送る。
///
/// 送るのは、その行が9割も見えていなくて、一覧が止まっているときだけ。
/// 人が一覧を送っている最中に取り合わない。字だけなので動かしてよい。
private struct ETMinimapFollow: View {
    let viewport: ETChainViewport
    let tracker: ETMinimapTracker
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: viewport.leading) { _, id in
                guard let id, tracker.phase == .idle, !tracker.shown.contains(id) else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(ETMinimapID(id: id))
                }
            }
    }
}

private struct ETMinimapRow: View {
    /// 行の高さ。**全部の行で同じ。**Listの詰めた行の高さで、頭の電源の押し所と同じ。
    /// Level MeterのOVERLOADの札もこの中に収める。
    static let height = ETMetrics.hitTarget

    let item: ETMinimapItem
    let dsp: EffeTuneDSP
    let viewport: ETChainViewport
    let tracker: ETMinimapTracker

    var body: some View {
        HStack(spacing: 2) {
            // **押し所は別に持つ。**行を押す（飛ぶ）とも、長押しで掴む（動かす）とも
            // 取り合わないように、電源は自分の44ptだけを受ける（.plainのボタン）。
            Toggle("Enabled", isOn: Binding(
                get: { item.enabled },
                set: { dsp.setEnabled($0, at: item.index) }))
                .toggleStyle(.power)
                .labelsHidden()
                .accessibilityLabel(item.name)

            Button {
                viewport.request(item.id)
            } label: {
                // **名前を先に並べる。**札を右端へ寄せるのはSpacerでなく名前の枠で持つ。
                // Spacerを挟むとHStackの間隔がその両側に付いて名前が16pt削られ、
                // OVERLOADの間「Level M…」に縮んでいた（列260pt）。
                // 札はfixedSizeなので、入らないときに切れるのは名前のほう。
                HStack(spacing: 4) {
                    Group {
                        if item.isSection {
                            Text(item.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(item.name)
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    // Level Meterの行はクリップしたときだけOVERLOADを出す。棒は出さない（オーナーの判断）。
                    if let tap = item.levelTap {
                        ETMinimapOverload(tap: tap)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
        }
        .padding(.leading, (item.indented ? 14 : 0) + 6)
        .padding(.trailing, 14)
        .frame(height: Self.height)
        .opacity(item.muted ? 0.55 : 1)
        .onScrollVisibilityChange(threshold: 0.9) { visible in
            if visible { tracker.shown.insert(item.id) } else { tracker.shown.remove(item.id) }
        }
        // **行の指定（listRow〜）は一番外に付ける。**onScrollVisibilityChangeより内側に
        // 付けると、Listまで届かずに黙って捨てられる（iPadOS 27のシミュレータで、付ける順を
        // 変えて確かめた。.sidebarでも.plainでも、.idの有無でも同じ）。
        // 地の色が見えているカードの行にも付かず、上下に11ptずつの既定の余白が残って
        // 行が66ptになっていたのはこれ。
        //
        // 余白は上下左右とも0にし、中身の側（上のpadding）で持つ。行は中身の44ptになり、
        // 地の色は行いっぱいに敷かれて、続く行と繋がって1本の帯になる。
        .listRowInsets(EdgeInsets())
        .listRowBackground(viewport.onScreen.contains(item.id)
                           ? Color.accentColor.opacity(0.14) : nil)
    }
}

/// 左の一覧の中身と見えている高さ。末尾の帯の高さを出すのに使う。
private struct ETMinimapSpace: Equatable {
    let content: CGFloat
    let visible: CGFloat
}

/// 最後の行より下の空き。落としたものは鎖の末尾へ（右の末尾の帯と同じ）。
///
/// **一覧の中の行として敷く。**Listの背面は中身の上で放したものを受けず、onInsertは行の間でしか
/// 起きないので、敷かないと最後の行より下は何も受けない（掴んだものが戻っていく）。
/// ForEachの外なので、onMove・onInsertの数え方には入らない。行の間の口はそのまま。
/// **contentShapeを必ず付ける。**Color.clearは枠を持っていても当たりを取らない。
private struct ETMinimapTail: View {
    let height: CGFloat
    let insert: (String, ETChainEditing.AddTarget) -> Void

    var body: some View {
        Color.clear
            .frame(height: height)
            .contentShape(.rect)
            .dropDestination(for: String.self) { items, _ in
                guard let type = items.first else { return false }
                insert(type, .end)
                return true
            }
            .accessibilityHidden(true)
            .moveDisabled(true)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// 出力補正の行。エフェクトの行と同じ形（電源と名前）。電源は右の行の電源と同じもの。
/// 押すと右の出力補正の行へ飛ぶ（エフェクトの行と同じ。シートは右の行から開く）。
/// 落としたものは鎖の末尾へ（右の出力補正の行と同じ。補正の中身には入れない）。
private struct ETMinimapCorrectionRow: View {
    let id: UUID
    let viewport: ETChainViewport
    let insert: (String, ETChainEditing.AddTarget) -> Void

    @ObservedObject private var oc = OutputCorrection.shared

    var body: some View {
        HStack(spacing: 2) {
            Toggle("Output Correction", isOn: Binding(get: { oc.isOn }, set: { oc.setOn($0) }))
                .toggleStyle(.power)
                .labelsHidden()
                .accessibilityLabel("Output Correction")

            Button {
                viewport.request(id)
            } label: {
                Text("Output Correction")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
        }
        // 値はETMinimapRowの写し（字下げなしの行）。
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: ETMinimapRow.height)
        .opacity(oc.isOn ? 1 : 0.55)
        .contentShape(.rect)
        .dropDestination(for: String.self) { items, _ in
            guard let type = items.first else { return false }
            insert(type, .end)
            return true
        }
        .moveDisabled(true)
        .listRowInsets(EdgeInsets())
        .listRowBackground(viewport.onScreen.contains(id)
                           ? Color.accentColor.opacity(0.14) : nil)
    }
}

/// Level Meterの行の札。クリップしてからLevelMeterView.overloadTimeの間だけ、
/// カードと同じOVERLOADの札（GraphCanvasのbadge）を行の右端に出す。それ以外は何も出さない。
///
/// **字はカードより一回り小さい（9pt、字間を足さない、左右4pt）。**カードと同じ10ptだと
/// 札が74ptあり、Section配下の字下げした行では列260ptでも「Level Meter」（約80pt）が入らない。
/// この大きさで札は約61pt、字下げした行でも名前との間に数ptの余りが出る。色と形はカードと同じ。
///
/// **テレメトリを観測するのはこのViewだけ。**一覧ぜんぶが枠ごとに組み直されないように。
/// 決め方はカードと同じ（LevelMeterView.overloads）。
private struct ETMinimapOverload: View {
    let tap: UInt32

    @ObservedObject private var telemetry = Telemetry.shared
    @State private var until: Date?

    var body: some View {
        let reading = LevelMeterView.read(telemetry.frame(tap: tap, type: .level))
        ZStack {
            if let until, Date() < until {
                // 色と形はGraphCanvasのbadgeと同じ。字と左右の余白だけ詰める（上の説明）。
                Text("OVERLOAD")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.tint, in: .capsule)
                    .fixedSize()
            }
        }
        .onChange(of: reading?.sequence ?? 0) { _, _ in advance(reading) }
    }

    /// 新しい枠が来たときだけ見る（LevelMeterView.advanceと同じ）。
    private func advance(_ reading: LevelMeterView.Reading?) {
        guard let reading else { return }
        let now = Date()
        if let until, now >= until { self.until = nil }
        if LevelMeterView.overloads(reading) {
            until = now.addingTimeInterval(LevelMeterView.overloadTime)
        }
    }
}
