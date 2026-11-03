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

    /// 文字サイズに追従させた数値欄の高さ（UIKit 側で測るとき用）。
    /// SwiftUI の中では ETValueFrame の @ScaledMetric を使い、これは ETTapOutside のように
    /// View の外から当たりを測る所だけが読む。既定の文字サイズでは controlHeight と同じ。
    static var scaledControlHeight: CGFloat {
        UIFontMetrics(forTextStyle: .footnote).scaledValue(for: controlHeight)
    }
}

// MARK: - アクセシビリティの共通部品
//
// 他のビューはここだけを使う。
//   .etFont(size: 14)                      文字サイズ設定に追従する .font(.system(size:))
//   .etValueFrame() / .etValueFrame(isField: true)   数値欄の枠（68x30 を文字サイズに追従させる）
//   etWithAnimation(.snappy) { ... }       視差効果を減らすとき動かさない withAnimation
//   ETMotion.animation(.snappy)            同じ判定で Animation? だけ欲しいとき
//   .etAnimation(.snappy, value: x)        同じ判定の .animation(_:value:)
//   ETAssistiveState                       VoiceOver / スイッチコントロールが動いているか（DynamicProperty）

/// 文字サイズ設定に追従する固定ポイントのフォント。
///
/// **既定の文字サイズ（Large）では .font(.system(size:)) と同じ大きさ。**
/// @ScaledMetric は relativeTo の文字スタイルの伸び方で size を拡大する。
/// 伸び方を揃えるため、size から近い文字スタイルを選ぶ（relativeTo を渡せば上書き）。
private struct ETFontModifier: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, relativeTo style: Font.TextStyle,
         weight: Font.Weight, design: Font.Design) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaledSize, weight: weight, design: design))
    }
}

enum ETFontStyle {
    /// 既定サイズが近い文字スタイル。16 は callout、15 は subheadline、14 と 13 は footnote、
    /// 12 は caption、11 以下は caption2。
    static func nearest(to size: CGFloat) -> Font.TextStyle {
        switch size {
        case 32...:   return .largeTitle
        case 26...:   return .title
        case 21...:   return .title2
        case 19...:   return .title3
        case 17...:   return .body
        case 16...:   return .callout
        case 15...:   return .subheadline
        case 13...:   return .footnote
        case 12...:   return .caption
        default:      return .caption2
        }
    }
}

extension View {
    /// `.font(.system(size:weight:design:))` の、文字サイズ設定に追従する版。
    /// 既定のサイズでは見た目が変わらない。ツールバーのように伸ばせない所には使わない。
    func etFont(size: CGFloat,
                relativeTo style: Font.TextStyle? = nil,
                weight: Font.Weight = .regular,
                design: Font.Design = .default) -> some View {
        modifier(ETFontModifier(size: size,
                                relativeTo: style ?? ETFontStyle.nearest(to: size),
                                weight: weight, design: design))
    }
}

/// 数値欄の枠。68x30 を文字サイズに追従させる。
///
/// 既定の文字サイズ（Large）では今までと同じ 68x30 の固定の枠。
/// 他の文字サイズでは、字と同じ比率で枠も伸び縮みする（字だけ変わって枠が合わなくなるのを防ぐ）。
/// 組み方が変わるのはアクセシビリティサイズだけで、そこでは
/// 縮めずに（minimumScaleFactor は外す）枠のほうを広げる。
/// - `isField: false`（ValueBox）: 字の長さに合わせて最小の枠より広がる。
///   それでも幅を超える値（"20.00 kHz"）は、"20.00 k…" と単位を落とさず折り返して全部出す。
/// - `isField: true`（TextField）: TextField は余白を取れるだけ取るので幅は決め打ち。
///   アクセシビリティサイズでは 9 字の "-12.50 dB" が入るよう 1.3 倍にする。
private struct ETValueFrame: ViewModifier {
    @ScaledMetric(relativeTo: .footnote) private var width = ETMetrics.valueWidth
    @ScaledMetric(relativeTo: .footnote) private var height = ETMetrics.controlHeight
    @Environment(\.dynamicTypeSize) private var typeSize
    let isField: Bool
    let shrinks: Bool
    /// 通常サイズで 1 行に固定するか（ValueBox だけ。ほかの Text は今までどおり行数を指定しない）。
    let singleLine: Bool

    func body(content: Content) -> some View {
        if !typeSize.isAccessibilitySize {
            // ValueBox は 1 行のまま（今まで Text 側に付けていた lineLimit(1) をここへ移した）。
            if singleLine {
                content
                    .lineLimit(1)
                    .minimumScaleFactor(shrinks ? 0.7 : 1)
                    .frame(width: width, height: height)
            } else {
                content
                    .minimumScaleFactor(shrinks ? 0.7 : 1)
                    .frame(width: width, height: height)
            }
        } else if isField {
            content
                .frame(width: width * 1.3)
                .frame(minHeight: height)
        } else {
            // 縮めず折り返す。欄の枠の中で字が詰まらないよう、左右に余白を足す。
            content
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .frame(minWidth: width, minHeight: height)
        }
    }
}

extension View {
    /// 数値欄の枠と、アクセシビリティサイズより下での縮小の下限。ValueBox・ETValueField・ParameterRow の欄が使う。
    /// `shrinks: false` は通常サイズでも字を縮めない（今まで縮めていなかった欄用）。
    func etValueFrame(isField: Bool = false, shrinks: Bool = true, singleLine: Bool = false) -> some View {
        modifier(ETValueFrame(isField: isField, shrinks: shrinks, singleLine: singleLine))
    }
}

/// 視差効果を減らす設定のときは動かさない。
///
/// ドラッグへの追従はそのままでよい（指に付いてくる動きは酔いの原因にならない）。
/// 動かさないのは、カードの開閉・並べ替えの着地・チップの切り替えのような、
/// 押したあとに画面が勝手に動く所だけ。
enum ETMotion {
    @MainActor
    static func animation(_ animation: Animation?) -> Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : animation
    }
}

/// `withAnimation` の、視差効果を減らす設定に従う版。
@MainActor
func etWithAnimation<Result>(_ animation: Animation? = .default,
                             _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(ETMotion.animation(animation), body)
}

private struct ETAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` の、視差効果を減らす設定に従う版。
    func etAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(ETAnimationModifier(animation: animation, value: value))
    }
}

/// VoiceOver かスイッチコントロールが動いているか。
///
/// View の中では `private var assistive = ETAssistiveState()` として持つ
/// （環境値なので、設定が変わると View が作り直される）。
/// UIViewRepresentable は private な保持を足すと memberwise init が private になり
/// 呼び出し側が壊れるので、`reorderLongPress(in: context.environment)` を使う
/// （makeUIView / updateUIView の context は常に最新の環境値を持つ）。
/// 並べ替えの長押しは通常 0.25 秒、動いているときだけシステム既定の 0.5 秒にする。
struct ETAssistiveState: DynamicProperty {
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    var isRunning: Bool { voiceOver || switchControl }

    /// 並べ替えを始める長押しの秒数。
    var reorderLongPress: Double { isRunning ? 0.5 : 0.25 }

    /// 環境値を直接渡すとき用（UIViewRepresentable の context.environment）。
    static func reorderLongPress(in environment: EnvironmentValues) -> Double {
        environment.accessibilityVoiceOverEnabled || environment.accessibilitySwitchControlEnabled ? 0.5 : 0.25
    }
}

enum ETAssistive {
    /// View の外から見るとき用（環境値が使えない所）。
    @MainActor
    static var isRunning: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }
}

/// エフェクトの入切。EffeTune は各エフェクトの頭に ON のバッジを置いている。
struct PowerBadge: View {
    let isOn: Bool

    var body: some View {
        Text("ON")
            .etFont(size: 11, weight: .heavy)
            .tracking(0.5)
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .modifier(ETPowerBadgeFrame())
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: .capsule)
    }
}

/// ON バッジの枠。通常の文字サイズでは今までどおり 42x26 の固定。
///
/// 字（etFont）だけが伸びて枠が固定のままだと、アクセシビリティサイズで "ON" が "…" に潰れる。
/// そこでは字を縮めず、字の大きさに合わせて枠のほうを広げる（最小は文字サイズに追従した 42x26）。
private struct ETPowerBadgeFrame: ViewModifier {
    @ScaledMetric(relativeTo: .caption2) private var width: CGFloat = 42
    @ScaledMetric(relativeTo: .caption2) private var height: CGFloat = 26
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minWidth: width, minHeight: height)
        } else {
            content.frame(width: 42, height: 26)
        }
    }
}

/// 名前と操作子を並べる行。通常は横一列、アクセシビリティサイズでは縦に積む。
///
/// 数値欄（ETValueField）は幅が決め打ちなので、大きな文字で横に並べると名前の列が
/// 数文字分しか残らず、"Fr…" や "Gai/n" になる。ParameterRow と同じく、そこでだけ縦にする。
/// 通常サイズの並びは今までの HStack（中央揃え）のまま。
///
/// `content` には積んでいるかどうかを渡す。Spacer は縦では場所を取るだけなので、
/// 横のときだけ置くのに使う。
struct ETAdaptiveStack<Content: View>: View {
    private let spacing: CGFloat?
    private let stackedSpacing: CGFloat
    private let content: (_ stacked: Bool) -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    // Environment を private で持つので、memberwise init には頼れない。
    init(spacing: CGFloat? = 8, stackedSpacing: CGFloat = 4,
         @ViewBuilder content: @escaping (_ stacked: Bool) -> Content) {
        self.spacing = spacing
        self.stackedSpacing = stackedSpacing
        self.content = content
    }

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: stackedSpacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout { content(stacked) }
    }
}

/// 見出しや節の頭に置く、文字だけの操作（Reset / Import など）。
///
/// 小さい青字だけだとボタンに見えず、押せる場所も分からなかった。標準の small bordered にする。
/// 見た目（カプセル）と並びの高さは標準のまま、押せる面だけを label の中で 44pt まで広げる
/// （余白を足して同じだけ引く。外側に contentShape を付けても Button の当たりは広がらない）。
/// footnote の 1 行は標準で約 16pt なので、上下 14 ずつで 44pt。
struct ETTextActionButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .padding(.vertical, 14)
                .contentShape(.rect)
                .padding(.vertical, -14)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// 名前（見出し）・メニュー・入切の行。PEQ のバンドの頭に使う。
///
/// 横に並べると、メニューの値（"Peaking"）が UIKit のラベルに狭い幅で渡されて
/// 1 字ずつ折り返し、カードの高さの計算も合わなくなる（次の行が本文に重なった）。
/// アクセシビリティサイズでは、見出しと入切を上、メニューを下の 1 行に積み、
/// メニューは折り返さない大きさ（fixedSize）で出す。通常サイズは今までの 1 行のまま。
struct ETMenuHeader<MenuContent: View, Trailing: View>: View {
    private let title: String
    private let menu: MenuContent
    private let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    init(title: String, @ViewBuilder menu: () -> MenuContent, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.menu = menu()
        self.trailing = trailing()
    }

    private var label: some View {
        Text(title)
            .etFont(size: 10, weight: .semibold)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    label
                    Spacer(minLength: 0)
                    trailing
                }
                menu
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 8) {
                label
                // L 以下は今のまま。それより大きいと細い提案幅で「Peak-/ing」と折り返し、
                // カードの高さが伸びきらず次の行と重なるので、折り返さず内容の幅を使う。
                menu
                    .fixedSize(horizontal: typeSize > .large, vertical: false)
                Spacer(minLength: 0)
                trailing
            }
        }
    }
}

/// スライダーの右に出す数値。EffeTune は打ち込みもできる欄にしている。
struct ValueBox: View {
    let text: String

    var body: some View {
        // 1 行にするかは etValueFrame が決める（アクセシビリティサイズでは折り返して単位を残す）。
        Text(text)
            .etFont(size: 13, design: .monospaced)
            .etValueFrame(singleLine: true)
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
            .etFont(size: 13, design: .monospaced)
            .lineLimit(1)
            .focused($focused)
            .etValueFrame(isField: true)
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
            // 何も無い所・カードの名前・2列の左の一覧を触ったときも確定させる（ETTapOutside）。
            .etCommitsOnTapOutside($focused) { apply() }
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

/// **打ち込み中の数値欄の外を触ったら、欄を確定させる。**窓に認識器を1つだけ付ける。
///
/// 数値欄（ETValueField・ParameterRow）が確定するのは、Return・キーボードを下げる・
/// 別の欄を触るの3つだけだった。iPadで数を打って何も無い所・カードの名前・2列の左の一覧を
/// 触っても欄は打ち込み中のまま残り、打った値が渡らなかった（シミュレータ、10枚とも）。
///
/// **SwiftUIの.onTapGestureでは拾い切れない。**地（ScrollViewの背面）に付けると、
/// カードの中の余白・自分のonTapGestureを持つカードの名前・左の一覧に届かない。
/// 親に付けると子の欄や部品と取り合う。窓の認識器は触りを奪わず
/// （cancelsTouchesInView = false）、ほかの認識器と同時に立つので、押した部品はそのまま動く。
///
/// - **字の欄の上では受けない。**別の欄へ移る・同じ欄の中でカーソルを動かすのはUIKitに任せる
///   （別の欄へ移ったときは欄が外れて今も確定する）。受けると、移った先の欄まで外れうる。
/// - **打ち込み中の欄の塗りの中でも受けない。**数値欄の塗りは高さ30pt（ETMetrics.controlHeight）で、
///   中の字の欄は1行ぶんの高さしか持たないことがある。そのときの上下の帯は字の欄ではないので、
///   見ないと、同じ欄の端を触っただけで確定して打ち込みが終わる。
/// - **外すのは数値欄だけ。**合図を受けた欄が自分で確定する（etCommitsOnTapOutside）。
///   ほかの字の欄（Sectionの名前・プリセットの名前・検索）やJSFXのキーボード受けは触らない。
@MainActor
final class ETTapOutside: NSObject, UIGestureRecognizerDelegate {
    /// 外を触った合図。
    nonisolated static let tapped = Notification.Name("ETTapOutside")
    private static let shared = ETTapOutside()

    /// 前面の窓に付ける。付いていれば何もしない。数値欄が打ち込みを始めたときに呼ぶ。
    /// 付けるのは最初の1回だけで、後は付けたまま（欄が無いときは合図を受ける相手が居ないだけ）。
    static func install() {
        for scene in UIApplication.shared.connectedScenes {
            guard let window = (scene as? UIWindowScene)?.keyWindow,
                  !(window.gestureRecognizers ?? []).contains(where: { $0.delegate === shared })
            else { continue }
            let recognizer = UITapGestureRecognizer(target: shared, action: #selector(ETTapOutside.fire(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesEnded = false
            recognizer.requiresExclusiveTouchType = false
            recognizer.delegate = shared
            window.addGestureRecognizer(recognizer)
        }
    }

    @objc private func fire(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        NotificationCenter.default.post(name: Self.tapped, object: nil)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextInput { return false }
            view = current.superview
        }
        return !Self.insideEditingBox(touch)
    }

    /// 打ち込み中の字の欄を、塗りの高さ（ETMetrics.controlHeight）まで上下に広げた中を触ったか。
    /// 欄は塗りの真ん中に居るので、触った所から上下に塗りの半分ずつずらした点を引けば、
    /// 帯のどこを触っても片方が欄に当たる。当たった欄が打ち込み中のときだけ枠を測って比べる。
    private static func insideEditingBox(_ touch: UITouch) -> Bool {
        guard let window = touch.window else { return false }
        let point = touch.location(in: window)
        let height = ETMetrics.scaledControlHeight
        let reach = height / 2
        for dy in [reach, -reach] {
            var hit = window.hitTest(CGPoint(x: point.x, y: point.y + dy), with: nil)
            while let current = hit, !(current is UITextInput) { hit = current.superview }
            guard let field = hit, field.isFirstResponder else { continue }
            let frame = field.convert(field.bounds, to: window)
            let band = max(0, (height - frame.height) / 2)
            if frame.insetBy(dx: 0, dy: -band).contains(point) { return true }
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension View {
    /// 数値欄に付ける。打ち込み中に外を触ったら`commit`を呼ぶ（ETTapOutside）。
    ///
    /// **@FocusStateを落とすだけにせず、ここで確定させる。**iPhoneではカードの名前を触ると
    /// カードが畳まれて欄ごと消え、消えた欄にはonChange(of: focused)が来ない。
    /// 合図は触った瞬間に届くので、畳まれる前に確定できる。
    /// `commit`は欄の@FocusStateも落とすこと（落とさないと打ち込み中のまま残る）。
    func etCommitsOnTapOutside(_ focused: FocusState<Bool>.Binding,
                               commit: @escaping () -> Void) -> some View {
        self
            .onChange(of: focused.wrappedValue) { _, now in
                if now { ETTapOutside.install() }
            }
            .onReceive(NotificationCenter.default.publisher(for: ETTapOutside.tapped)) { _ in
                if focused.wrappedValue { commit() }
            }
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

/// **鎖に残る表示の設定。**`etRemembers` との違いはそこだけ。
///
/// あちらは端末の中だけの覚え（ETCardSelection）で、アプリを終うと消える。
/// こちらは Node に入って保存形式へ出るので、開き直しても、プリセットにも、
/// 共有リンクにも残る。**上流がプリセットに書いているものだけ**を通すこと
/// （DSP/DisplayParams.swift に表がある）。
extension View {
    /// 文字を raw に持つ列挙。**rawValue をそのまま書く**ので、
    /// 綴りは上流に合わせてあること（`Normal` / `log-hq` など）。
    func etSaved<T>(_ value: Binding<T>, key: String, index: Int,
                    dsp: EffeTuneDSP) -> some View
    where T: RawRepresentable & Equatable, T.RawValue == String {
        self
            .onAppear {
                guard let raw = dsp.node(at: index)?.display[key],
                      let v = T(rawValue: raw) else { return }
                value.wrappedValue = v
            }
            .onChange(of: value.wrappedValue) { _, v in
                dsp.setDisplay(v.rawValue, key: key, at: index)
            }
    }

    /// 入切。**綴りは呼ぶ側が決める。**上流は `vl` を true/false、
    /// `dm` を "line"/"bar" で書いていて、同じ Bool でも字が違う。
    func etSaved(_ value: Binding<Bool>, key: String, index: Int,
                 dsp: EffeTuneDSP, on: String = "true", off: String = "false") -> some View {
        self
            .onAppear {
                guard let raw = dsp.node(at: index)?.display[key] else { return }
                value.wrappedValue = raw == on
            }
            .onChange(of: value.wrappedValue) { _, v in
                dsp.setDisplay(v ? on : off, key: key, at: index)
            }
    }

    /// 数。上流は数値で書くので、持つ字は `String(Double)` の形にしておく。
    func etSaved(_ value: Binding<Double>, key: String, index: Int,
                 dsp: EffeTuneDSP) -> some View {
        self
            .onAppear {
                guard let raw = dsp.node(at: index)?.display[key],
                      let v = Double(raw) else { return }
                value.wrappedValue = v
            }
            .onChange(of: value.wrappedValue) { _, v in
                dsp.setDisplay(String(v), key: key, at: index)
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

    /// 外から来たものの作者。**AU と JSFX をここ 1 か所で引く。**
    ///
    /// externalID は AU が "type:subtype:manufacturer"、JSFX が "jsfx:<sha256>"。
    /// JSFX の作者はソースの `author:` 行から読んである（ETJSFXHost.metadata）。
    /// 取れないときは空（端末から AU を消した後、ソースに author: が無いとき）。
    static func author(externalID: String) -> String {
        if externalID.hasPrefix("jsfx:") {
            return ETJSFXHost.shared.entry(id: externalID)?.author ?? ""
        }
        return ETAUHost.shared.entry(id: externalID)?.manufacturer ?? ""
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

    /// 刻みから桁数を決める。JSFX の slider は `<min,max,inc>` の inc を持っている。
    ///
    /// **`%g` を使わない。**あれは有効桁を超えると指数に落ちるので、精度 3 では
    /// 1000 が `1e+03`、12001 が `1.2e+04` になる（可聴域がまるごとそれに当たる）。
    /// `%f` 系は指数表記を持たない。
    ///
    /// inc を書いていない slider は 0 で来るので、そのときは整数判定と有効 4 桁相当に落とす。
    /// **丸めて見せるだけで、実値が刻みの格子に乗るわけではない**
    /// （ysfx の正規化→実値は inc を使わない素の線形写像）。
    static func stepped(_ v: Double, step: Double) -> String {
        guard v.isFinite else { return "—" }
        let value = abs(v) < 1e-9 ? 0 : v   // -0 と 1e-17 を 0 に寄せる
        let decimals: Int
        // **無限の刻みを通さない。**inc は strtod そのままで、`inf` や 1e999 が来る。
        // -log10(inf) は -inf で、Int() がメインスレッドで落ちる。
        if step > 0, step.isFinite {
            // -1e-9 は境界対策。step=1 で -log10(1) が -0.0 側に転ぶと 1 桁になる。
            decimals = min(6, max(0, Int(ceil(-log10(step) - 1e-9))))
        } else if value == value.rounded() {
            decimals = 0
        } else {
            decimals = min(6, max(0, 3 - Int(floor(log10(abs(value))))))
        }
        return String(format: "%.\(decimals)f", value)
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
                .etFont(size: 20, weight: .medium)
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint)
                                                    : AnyShapeStyle(.secondary))
                .frame(minWidth: ETMetrics.hitTarget, minHeight: ETMetrics.hitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Button で描くと、支援技術に「入切できる」と「いま入／切」が伝わるかが OS 任せになる。
        // 読み上げの木だけ本物の Toggle にする（見た目は上の Button のまま）。
        // .automatic を明示するのは、環境の .power を継いで makeBody が入れ子で呼ばれないため。
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.automatic)
        }
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
            // この 2 つの字（11・12pt）は etFont にしない。ツールバーの枠は伸ばせず、
            // 伸ばすと隣のボタンを押しのける。代わりに下の Large Content Viewer を出す。
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
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.automatic)
        }
        // ツールバーは伸ばせないので字は固定のまま、長押しで大きな表示を出す
        // （文字サイズをアクセシビリティサイズにしているときだけ出る）。
        .accessibilityShowsLargeContentViewer {
            Label("Effects", systemImage: configuration.isOn ? "power" : "power.dotted")
        }
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

    /// 図に最新の枠を届けるか。偽のあいだETTelemetryFeedは知らせを止める。
    ///
    /// 2列のときはカードを全部開くので、画面の外にも図が並ぶ。
    /// 立てたり落としたりするのはETLiveRowだけで、1列のときは常に真。
    @Entry var etGraphLive: Bool = true

    /// カードを開いたままにするか。**2列のときだけ真。**
    ///
    /// 開閉の印（カードの矢印とSectionの44ptのボタン）を出さない。
    /// ただし図を持つカードは図だけの形にできるので、矢印を出す。
    /// 開いているかどうかはPipelineViewが渡すisExpandedが決めていて、
    /// iPhoneの開閉の覚え（dsp.expanded / dsp.collapsedFully）は書かない。
    @Entry var etCardsPinnedOpen: Bool = false

    /// 音量に追従する PEQ の、もう1台（相方）が鳴らしている値。nil なら無い。
    /// PEQ の図が2台ぶんを足した曲線を描く（EffeTuneDSP.soundingPEQ）。読むだけの印は薄く出す。
    @Entry var etPEQCompanionValues: [Float]? = nil
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

extension View {
    /// ナビゲーションバーの題を、アプリの字として描く（題の行は iOS が描くので、アプリの「標準より小さくしない」が
    /// 届かず、最小の設定で題だけ小さくなった）。navigationTitle も置くので、戻るボタンや読み上げはそのまま。
    func etNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .etFont(size: 17, weight: .semibold)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}
