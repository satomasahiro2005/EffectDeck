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
//    - Level Meterの行だけ、行の右端に棒を出す（カードと同じテレメトリ）
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
    /// 画面の行番号で動かす。ListのonMoveと同じ数え方。
    let move: (IndexSet, Int) -> Void
    /// ピッカーから運ばれた文字列と、差し込む鎖の位置（nilなら末尾）。
    let insert: (String, Int?) -> Void

    @State private var tracker = ETMinimapTracker()

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
                    let at = items.indices.contains(offset) ? items[offset].index : nil
                    guard let provider = providers.first else { return }
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let text = object as? NSString else { return }
                        let payload = text as String
                        Task { @MainActor in insert(payload, at) }
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, ETMinimapRow.height)
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
    /// Level Meterの棒もこの中に収める。
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
                HStack(spacing: 8) {
                    if item.isSection {
                        Text(item.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(item.name)
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // **棒は名前の下ではなく右端に置く。**名前（15pt）の下に2本積むと44ptに
                    // 収まらず、名前が上へ押し出され、Rの棒が次の行へはみ出していた。
                    // 右端なら名前はどの行とも同じ高さに並ぶ。
                    if let tap = item.levelTap {
                        ETMinimapLevel(tap: tap)
                            .frame(width: ETMinimapLevel.width)
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

/// Level Meterの行の棒。1チャンネル1本、標準のGauge（.linearCapacity）で出す。
/// 行の右端に、上からL、Rの順で積む。
///
/// **テレメトリを観測するのはこのViewだけ。**一覧ぜんぶが枠ごとに組み直されないように。
/// 読み方と落ちる速さはカード（LevelMeterView）と同じ。
/// 3チャンネル以上は2段に振り分ける。行の高さを変えないため。
private struct ETMinimapLevel: View {
    /// 棒の幅。名前の取り分を残す（一覧は最小220pt）。
    static let width: CGFloat = 64

    let tap: UInt32

    @ObservedObject private var telemetry = Telemetry.shared
    /// 棒の値（dB）。枠が来るたびに落としながら追いかける。
    @State private var bars: [Int: Double] = [:]
    @State private var lastFall = Date()

    var body: some View {
        let reading = LevelMeterView.read(telemetry.frame(tap: tap, type: .level))
        let count = reading?.peaks.count ?? 0
        let lines = min(count, 2)
        let perLine = lines == 0 ? 0 : (count + lines - 1) / lines
        VStack(spacing: 4) {
            ForEach(0..<lines, id: \.self) { line in
                HStack(spacing: 3) {
                    ForEach(line * perLine ..< min(count, (line + 1) * perLine), id: \.self) { ch in
                        // **名札はGaugeに渡さない。**labelsHiddenを付けても.linearCapacityは
                        // 名札（L、R）を棒の上に描き、1本ぶん背が伸びていた。
                        // 何のチャンネルかは読み上げにだけ出す。
                        Gauge(value: level(ch, reading), in: LevelMeterView.floorDB...0) {
                            EmptyView()
                        }
                        .gaugeStyle(.linearCapacity)
                        .accessibilityLabel(LevelMeterView.label(ch, of: count))
                    }
                }
            }
        }
        .onChange(of: reading?.sequence ?? 0) { _, _ in advance(reading) }
        .onAppear { lastFall = Date() }
    }

    private func level(_ ch: Int, _ reading: LevelMeterView.Reading?) -> Double {
        let now = reading.map { ETdB.fromAmplitude($0.peaks[ch], floor: LevelMeterView.floorDB) }
            ?? LevelMeterView.floorDB
        return min(0, max(LevelMeterView.floorDB, bars[ch] ?? now))
    }

    /// 新しい枠が来たときだけ落とす（LevelMeterView.advanceと同じ計算）。
    private func advance(_ reading: LevelMeterView.Reading?) {
        guard let reading else { return }
        let now = Date()
        let dt = min(max(now.timeIntervalSince(lastFall), 0), 0.5)
        lastFall = now
        var next: [Int: Double] = [:]
        for ch in reading.peaks.indices {
            let db = ETdB.fromAmplitude(reading.peaks[ch], floor: LevelMeterView.floorDB)
            let fallen = (bars[ch] ?? LevelMeterView.floorDB) - LevelMeterView.fallRate * dt
            next[ch] = max(db, max(fallen, LevelMeterView.floorDB))
        }
        bars = next
    }
}
