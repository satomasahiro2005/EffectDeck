//  Components.swift
//  画面の部品と寸法。色はまだ決めていないので、ここでは持たない。
//  いまはシステムの意味づけ（primary / secondary / tint）に任せてある。
//
//  角丸は数値で持つ。
//
//  iOS 26 の concentric（器の丸みに追従させる）を一度入れたが、
//  器から遠い小さな部品では引き算の結果 0 になり、
//  minimum を付けても実機で角が消えていた。
//  見た目が先なので、値は cardRadius / innerRadius の 2 つだけに寄せてある。

import SwiftUI
import UIKit
import Foundation

enum ETMetrics {
    static let cardPadding: CGFloat = 14
    static let valueWidth: CGFloat = 68
    static let controlHeight: CGFloat = 30
    /// 押せる面の下限。HIG は 44×44pt を求めている。
    /// 見た目はこれより小さくてよいが、当たり判定はここまで広げる。
    static let hitTarget: CGFloat = 44
    /// カードの丸み。**ここだけが数値を持つ。**
    /// 外枠の丸み。
    static let cardRadius: CGFloat = 16
    /// 内側の部品の丸み。
    ///
    /// concentric をやめて数値で持っている。
    /// 器の丸みに追従させるのが筋だが、器から遠い小さな部品では
    /// 引き算の結果 0 になり、minimum を付けても実機で角が消えていた。
    /// 見た目が先なので数値にしてある。変えるのはこの 1 行。
    static let innerRadius: CGFloat = 8
}

/// エフェクトの入切。EffeTune は各エフェクトの頭に ON のバッジを置いている。
struct PowerBadge: View {
    let isOn: Bool

    var body: some View {
        Text("ON")
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 42, height: 26)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: .capsule)
    }
}

/// スライダーの右に出す数値。EffeTune は打ち込みもできる欄にしている。
struct ValueBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
            .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
    }
}

/// 打ち込める数値欄。ValueBox の姉妹で、見た目は同じ。
///
/// **ValueBox は作り替えない。**あちらは打ち込めては困るものにも使われている
/// （NoteSpectrogram の音名。上流も note_spectrogram.js で readOnly にしている）。
///
/// 形は ParameterRow.valueField に倣う。Text に onTapGesture を足す形にしないのは、
/// ボタンでもテキスト欄でもない物には VoiceOver も Voice Control も届かないから。
struct ETValueField: View {
    /// 画面に出す字。編集していない間はこれを出す。単位を付けてよい。
    let text: String
    /// 読み上げ用の名前。
    var label: String = ""
    /// 打ち込みを始めるときの下書き。
    ///
    /// **画面の字をそのまま渡さないこと。**"1.50 k" や "2.00 oct" のような字は
    /// Double(_:) が nil を返すので、何も打たずに外すと黙って捨てられる。
    /// ここには数だけを渡す。
    let editText: () -> String
    /// 打たれた数。**挟むのは受け側の仕事**（範囲はここでは知らない）。
    let commit: (Double) -> Void

    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: Binding(
            get: { editing ? draft : text },
            set: { draft = $0 }))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .focused($focused)
            .frame(width: ETMetrics.valueWidth, height: ETMetrics.controlHeight)
            .background(.quaternary, in: .rect(cornerRadius: ETMetrics.innerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ETMetrics.innerRadius, style: .continuous)
                .stroke(.tint, lineWidth: editing ? 1 : 0))
            .submitLabel(.done)
            .onSubmit { apply() }
            .onChange(of: focused) { _, now in
                if now {
                    draft = editText()
                    editing = true
                } else if editing {
                    // 他を触ってキーボードが引っ込んだときも確定させる。
                    // これが無いと、打った値が渡らないまま消える。
                    apply()
                }
            }
            .accessibilityLabel(label)
            .accessibilityValue(text)
    }

    private func apply() {
        editing = false
        focused = false
        guard let typed = Double(draft.trimmingCharacters(in: .whitespaces)) else { return }
        commit(typed)
    }
}

/// カードを畳んでも消えない、画面だけの選択。
///
/// 図の表示の切り替え（Frequency Scale、バンドのタブ、表示の種類）は音に関係しないので
/// Node.values に席が無い。@State に置くとカードを畳んだ時点で View ごと消えて
/// 既定へ戻るため、開き直すと選び直しになる。鍵は Node.id。
///
/// **音には一切関係しない。**席ができるまでの仮置きで、端末にも残さない。
/// 前例は MatrixRouting（MatrixView.swift）。あれは経路の表で型が違うので別に置く。
@MainActor
final class ETCardSelection {

    static let shared = ETCardSelection()

    /// 中身は文字列で持つ。Int も Bool も、文字を raw に持つ enum も同じ器に入る。
    private var byNode: [UUID: [String: String]] = [:]

    private init() {}

    func raw(_ key: String, for id: UUID) -> String? { byNode[id]?[key] }

    func set(_ raw: String, key: String, for id: UUID) {
        byNode[id, default: [:]][key] = raw
    }

    /// 鎖から外れた段のぶんを捨てる。
    func prune(keeping ids: [UUID]) {
        let live = Set(ids)
        byNode = byNode.filter { live.contains($0.key) }
    }
}

extension View {
    /// **畳んでも消えない選択。**@State を ETCardSelection と同期させる。
    ///
    /// カードは畳むと View ごと木から消える（EffectCardView の段 3）。人の操作では
    /// 開き直すときに必ず段 3 を通るので、@State だけでは毎回既定へ戻る。
    /// 音に関係しない表示の選択（バンドのタブ、縦軸、棒表示）はここで覚える。
    ///
    /// 既定値は今の @State の値をそのまま使う（置き場に無いときは動かさない）。
    func etRemembers(_ value: Binding<Int>, key: String, node id: UUID) -> some View {
        self
            .onAppear {
                if let s = ETCardSelection.shared.raw(key, for: id), let v = Int(s) {
                    value.wrappedValue = v
                }
            }
            .onChange(of: value.wrappedValue) { _, v in
                ETCardSelection.shared.set(String(v), key: key, for: id)
            }
    }

    func etRemembers(_ value: Binding<Bool>, key: String, node id: UUID) -> some View {
        self
            .onAppear {
                if let s = ETCardSelection.shared.raw(key, for: id) {
                    value.wrappedValue = s == "1"
                }
            }
            .onChange(of: value.wrappedValue) { _, v in
                ETCardSelection.shared.set(v ? "1" : "0", key: key, for: id)
            }
    }

    func etRemembers(_ value: Binding<Double>, key: String, node id: UUID) -> some View {
        self
            .onAppear {
                if let s = ETCardSelection.shared.raw(key, for: id), let v = Double(s) {
                    value.wrappedValue = v
                }
            }
            .onChange(of: value.wrappedValue) { _, v in
                ETCardSelection.shared.set(String(v), key: key, for: id)
            }
    }

    func etRemembers<T>(_ value: Binding<T>, key: String, node id: UUID) -> some View
    where T: RawRepresentable & Equatable, T.RawValue == String {
        self
            .onAppear {
                if let s = ETCardSelection.shared.raw(key, for: id), let v = T(rawValue: s) {
                    value.wrappedValue = v
                }
            }
            .onChange(of: value.wrappedValue) { _, v in
                ETCardSelection.shared.set(v.rawValue, key: key, for: id)
            }
    }
}

/// カードとピッカーで、外から来たものの format と作者を同じ形で出す。
@MainActor
enum ETPluginLabel {
    /// "Audio Units · Vendor" の形。作者が空なら format だけ。
    static func detail(format: String, author: String) -> String {
        let a = author.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? format : format + " · " + a
    }

    /// AU の作者。externalID は "type:subtype:manufacturer" で、ETAUHost の entry を引ける。
    /// 取れないときは空（端末から AU を消した後など）。
    static func author(externalID: String) -> String {
        ETAUHost.shared.entry(id: externalID)?.manufacturer ?? ""
    }
}

/// 数を人が読む形にする。**指数表記にしない。**
///
/// `%.3g` は有効桁 3 桁を超えると指数に落ちるので、1000 が `1e+03` になる。
/// 可聴域の周波数（20〜20000）がまるごとそれに当たる。整数は厳密値で出す。
enum ETNumberText {
    static func plain(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        if v == v.rounded() && abs(v) < 1e9 { return String(Int(v)) }
        let a = abs(v)
        if a >= 100 { return String(format: "%.0f", v) }
        if a >= 10 { return String(format: "%.1f", v) }
        if a >= 0.1 { return String(format: "%.2f", v) }
        // ここまで小さいと 2 桁では 0.00 になる。桁を足す。
        return String(format: "%.4f", v)
    }

    /// 打ち込みの下書き用。単位も丸めも付けない。
    static func draft(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        return v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%g", v)
    }
}

/// エフェクト 1 個ぶんの枠。
///
/// これ自身が器になるので、丸みを数値で持つのはここだけ。
/// containerShape を名乗っておかないと、中の concentric が画面を器と見て
/// 引き算で 0 になる。
/// 組の中での位置。
///
/// **組の内側を向く角だけ角にする。**全部丸いと、並んでいるだけなのか
/// 一組なのかが形に出ない。行間は詰めない（詰めるとカードが切れて別の問題が出る）。
enum ETBlockPosition {
    case alone, top, middle, bottom

    var roundsTop: Bool { self == .alone || self == .top }
    var roundsBottom: Bool { self == .alone || self == .bottom }

    /// 行の上下に空ける量。listRowInsets と、板を描くときの寄せに同じ値を使う。
    var topInset: CGFloat { 5 }
    var bottomInset: CGFloat { 5 }

    var radii: RectangleCornerRadii {
        let r = ETMetrics.cardRadius
        return RectangleCornerRadii(topLeading: roundsTop ? r : 0,
                                    bottomLeading: roundsBottom ? r : 0,
                                    bottomTrailing: roundsBottom ? r : 0,
                                    topTrailing: roundsTop ? r : 0)
    }
}

struct Card<Content: View>: View {
    var block: ETBlockPosition = .alone
    @ViewBuilder var content: Content

    /// 位置を色で出す。`-ETDebugBlocks 1` のときだけ。確かめるためだけのもの。
    private var debugTint: AnyShapeStyle? {
        guard ETScreenshotSeed.debugBlocks else { return nil }
        switch block {
        case .alone:  return AnyShapeStyle(.gray)
        case .top:    return AnyShapeStyle(.red)
        case .middle: return AnyShapeStyle(.green)
        case .bottom: return AnyShapeStyle(.blue)
        }
    }

    var body: some View {
        content
            // 背景はここで描く。listRowBackground へ移すと画面が真っ白になる
            // （行の面に形を置くと List が中身を描かなくなる。実機で確認）。
            // 単色（secondarySystemGroupedBackground）にも替えてみたが、
            // **この画面の地も白なので板が見えなくなった。**材質のままにする。
            .background(debugTint ?? AnyShapeStyle(.regularMaterial),
                        in: .rect(cornerRadii: block.radii, style: .continuous))
            .containerShape(.rect(cornerRadii: block.radii, style: .continuous))
    }
}

extension String {
    /// dsp/plugins の下の名前を、EffeTune の一覧に出ている見出しへ。
    var categoryLabel: String {
        switch self {
        case "eq":   return "EQ"
        case "lofi": return "Lo-Fi"
        // control に居るのは Section だけで、音を触らない。効果と同じ顔で
        // 「Control」と出ると効果の一種に見えるので、何をするものかで呼ぶ。
        case "control": return "Grouping"
        default:     return prefix(1).uppercased() + dropFirst()
        }
    }
}

/// 刻みが 0 のときに落ちない Slider。
///
/// SwiftUI の Slider(value:in:step:) は step が 0 だと落ちる。
/// params.json に step を持たないパラメータがあるので、そのまま渡すと
/// カードを開いた瞬間に死ぬ。刻みが無いものは step を取らない方を使う。
struct ETSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0

    var body: some View {
        if step > 0 {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }
}

/// 対数目盛りのスライダー。周波数や Rate のつまみに使う。
///
/// EffeTune は createLogarithmicParameterControl でこの形を作っている。
/// つまみの位置は log10 で決まり（plugin-base.js:1405-1420
/// `const logMin = Math.log10(min)` … `((logValue - logMin) / logRange) * 100`）、
/// 値は位置から `Math.pow(10, logMin + (sliderPos / 100) * logRange)` で戻す。
/// 値そのものは線形のまま持つので、DSP に渡す数はリニア版と変わらない。
///
/// 刻みは位置側にしか無い。plugin-base.js:1413 が `slider.step = 0.1`（可動域 0-100 の 1/1000）
/// を置くだけで、パラメータの step は数値欄の矢印と表示桁数にしか効かず
/// （plugin-base.js:1443-1448 の `toFixed(step < 0.1 ? 2 : …)`）、
/// つまみが返す値は丸めていない。だからここでも値は丸めない。
/// 位置の 1/1000 は iPhone の幅では 0.3pt を切るので、位置は連続で持つ。
/// 整数で持つパラメータの丸めは、呼ぶ側が渡す Binding が受け持つ。
struct ETLogSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Slider(value: Binding(get: { position }, set: { move(to: $0) }), in: 0...1)
    }

    private var lower: Double { range.lowerBound }
    private var upper: Double { range.upperBound }
    /// 何桁ぶんの幅か。
    private var decades: Double { log10(upper) - log10(lower) }

    private var position: Double {
        guard lower > 0, decades > 0 else { return 0 }
        let v = min(max(value, lower), upper)
        return (log10(v) - log10(lower)) / decades
    }

    private func move(to p: Double) {
        guard lower > 0, decades > 0 else { return }
        let clamped = min(max(p, 0), 1)
        value = min(max(pow(10, log10(lower) + clamped * decades), lower), upper)
    }
}

/// 0 を含む対数スライダー。左端の 1 目盛りだけが 0 で、その右は下限から上限までの対数。
///
/// Static Rate のように、0（鳴らさない）と 0.01 から上の広い範囲を同じつまみで扱う値に使う。
/// 上流は各プラグインが同じ _createZeroAwareLogControl を持っている
/// （am_radio_simulator.js:2060-2100 / sw_radio_simulator.js:1785-1825 /
/// vinyl_simulator.js:1413-1453。3 本とも中身は同じ）。
///
/// 位置は 0-1000 の 1 刻みで、0 だけが値 0。1 以上は
/// `floor * Math.pow(max / floor, (position - 1) / 999)`。
/// 下限は 3 本とも 0.001 に固定してある（am_radio_simulator.js:2085 の `const floor = 0.001;`）。
struct ETZeroAwareLogSlider: View {
    @Binding var value: Double
    let maximum: Double

    /// 0 の次の目盛りが取る値。
    private static let floor = 0.001
    private static let steps = 1000.0

    var body: some View {
        Slider(value: Binding(get: { position }, set: { move(to: $0) }),
               in: 0...Self.steps, step: 1)
    }

    private var position: Double {
        guard maximum > Self.floor, value > 0 else { return 0 }
        let v = min(max(value, Self.floor), maximum)
        return 1 + (Self.steps - 1) * log(v / Self.floor) / log(maximum / Self.floor)
    }

    private func move(to p: Double) {
        guard maximum > Self.floor else { return }
        let clamped = min(max(p, 0), Self.steps)
        if clamped < 1 {
            value = 0
            return
        }
        let ratio = (clamped - 1) / (Self.steps - 1)
        value = min(Self.floor * pow(maximum / Self.floor, ratio), maximum)
    }
}


/// エフェクトの入切。
///
/// 見た目は EffeTune の ON バッジに寄せているが、中身は Toggle。
/// Button で作ると支援技術からはただのボタンに見え、入っているのか切れて
/// いるのかが伝わらない（HIG: Toggles）。
/// 状態を色だけで伝えないよう、字形も変える（入は塗り、切は輪郭）。
/// 当たり判定は 44pt を確保する。
struct PowerToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "power.circle.fill" : "power.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint)
                                                    : AnyShapeStyle(.secondary))
                .frame(width: ETMetrics.hitTarget, height: ETMetrics.hitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == PowerToggleStyle {
    static var power: PowerToggleStyle { PowerToggleStyle() }
}

/// 鎖ぜんぶの入切。**カード 1 枚ずつの電源と同じ絵にしない。**
///
/// 上流は pipeline の見出しの一番左に置いている
/// （effetune.html:262 `<button class="toggle-button master-toggle" title="Toggle all effects">ON</button>`）。
/// 絵はカード側の ON バッジと同じで、区別しているのは位置だけ。
/// 右隣に「Effect Pipeline」の見出しがあるから、鎖ぜんぶのものだと読める。
/// こちらは見出しを出していないので、位置では読めない。だから字を出す。
///
/// 切ったときは「素通しになっている」ことまで出す。
/// 上流も master を切るとプラグイン名を全部灰に落とし、鎖が効いていないと見せる
/// （js/ui/pipeline/pipeline-core.js:301-322 の plugin-disabled）。
/// 言葉は Now Playing に出しているものと揃える（NowPlaying.swift:65 の "Bypassed"）。
///
/// configuration.label は描かない。文言が入切で変わるため。
/// 読み上げの名前は呼ぶ側が accessibilityLabel で付ける。
struct MasterPowerToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                // 絵で入切を言う。切っているときは斜線入り。
                Image(systemName: configuration.isOn ? "power" : "power.dotted")
                    .font(.system(size: 11, weight: .bold))
                // **字は変えない。** 以前は入で "Effects"、切で "Bypassed" と
                // 出していたが、8 文字はツールバーの左枠に入らず "Bypas..." と切れた。
                // 中心の帯と右のボタン 3 つに挟まれて、ここに使える幅は
                // iPhone 16 でおよそ 100pt しかない。
                // 切っていることは塗りと絵、それと鎖の上に出る帯が言う。
                Text("Effects")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(configuration.isOn ? AnyShapeStyle(.white)
                                                : AnyShapeStyle(.secondary))
            // ツールバーに詰められて切れないようにする。
            // 幅は字が固定なので動かない。
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(configuration.isOn ? AnyShapeStyle(.tint)
                                           : AnyShapeStyle(.quaternary),
                        in: .capsule)
            // 見えている丸みは 28pt ぶんだが、押せる面は 44pt 取る（HIG: Touch targets）。
            .frame(height: ETMetrics.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == MasterPowerToggleStyle {
    static var masterPower: MasterPowerToggleStyle { MasterPowerToggleStyle() }
}

/// 図だけを見たいとき true。Analyzer 系のカードが立てる。
/// ParameterRow がこれを見て自分を消すので、専用の画面を 1 つずつ直さずに済む。
extension EnvironmentValues {
    @Entry var etGraphOnly: Bool = false

    /// 畳んだカードで図を出すときの高さの上限。nil なら figure の言い値のまま。
    ///
    /// **畳む意味を残すため。** analyzer は畳んでも図を出すようにしてあるが、
    /// Stereo Meter のように幅から正方形を作るものは 340pt 前後になり、
    /// 畳んでもカードが縮まない＝畳めないのと同じだった。
    /// GraphCanvas の 1 箇所で当たるので、12 本ある図に個別の細工は要らない。
    @Entry var etGraphMaxHeight: CGFloat? = nil
}

/// 組（Section とその配下）の上と下に引く横線。
///
/// **終わりの印を持たない構造の埋め合わせ。**鎖はフラットな配列で、
/// Section は「ここから」の印しか持たない。だから画面の上では、どこまでが
/// ひと組なのかが線でしか分からない。掴んだものを組の中へ入れるのか
/// 外へ出すのかも、この線を越えたかどうかで読む。
struct ETGroupRule: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
    }
}

extension String {
    /// 頭が prefix なら、その先を返す。違えば nil。
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
