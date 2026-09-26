//  ChainViewport.swift
//  右の鎖（ScrollView）と左の一覧（ChainMinimap）を繋ぐもの。
//
//  **向きは片道。**右が「いま画面に入っているカード」を書き、左が読む。
//  左が「そこへ飛んで」と頼み、右が読む。どちらも相手の値を書き戻さない。
//  両方向に結ぶと、並べ替えで掴んでいる行を追いかけたり、送った位置と
//  選んだ行が互いを動かし合ったりする。
//
//  **PipelineViewのbodyはonScreenとleadingを読まない。**送るたびに
//  鎖ぜんぶが組み直されるのを避けるため。読むのは左の一覧の行だけ。

import Observation
import SwiftUI

/// 飛び先の頼み。**回数を持つ。**同じ行を続けて押しても、2回目も飛ぶように
/// （ピッカーのJumpと同じ形）。
struct ETJump: Equatable {
    var id: UUID?
    var count = 0
}

@Observable @MainActor
final class ETChainViewport {
    /// 2列の右で、1%でも見えているカード。左の一覧の行だけが読む（行の地の色）。
    private(set) var onScreen: Set<UUID> = []
    /// onScreenのうち鎖で一番上のもの。左の一覧が付いて送るのに使う。
    private(set) var leading: UUID?
    /// 左の一覧から頼まれた飛び先。右のonChangeだけが読む。
    private(set) var jump = ETJump()

    /// 鎖の並び（Node.id）。leadingを決めるのに使う。
    @ObservationIgnored private var order: [UUID] = []
    /// 並べ方が変わったとき（1列↔2列、幅が変わったとき）に戻す先。
    /// 最初に触れたとき、または左の一覧で飛んだときに外す。
    @ObservationIgnored var anchor: UUID?
    /// 1列のときに見えているカード。帯には出さない（左の一覧が無いので）。
    /// 2列へ切り替えるときに、どこを読んでいたかを知るためだけに持つ。
    @ObservationIgnored private var stackShown: Set<UUID> = []

    /// カードが見え始めた・見えなくなった。**変わらないときは何も書かない。**
    /// `split`はそのカードが載っている並べ方。
    func set(_ id: UUID, visible: Bool, split: Bool) {
        guard split else {
            if visible { stackShown.insert(id) } else { stackShown.remove(id) }
            return
        }
        if visible {
            guard !onScreen.contains(id) else { return }
            onScreen.insert(id)
        } else {
            guard onScreen.contains(id) else { return }
            onScreen.remove(id)
        }
        updateLeading()
    }

    func setOrder(_ ids: [UUID]) {
        order = ids
        updateLeading()
    }

    /// 左の一覧で押された。戻す先の覚えは捨てる（押した先が新しい読む位置）。
    func request(_ id: UUID) {
        anchor = nil
        jump = ETJump(id: id, count: jump.count + 1)
    }

    /// いま読んでいる位置（見えているうちで一番上のカード）を戻す先として覚える。
    /// 見えているカードが無ければ何もしない（前に覚えたものを消さない）。
    ///
    /// **鎖の先頭のカードが見えているなら覚えない（覚えていたものも捨てる）。**一番上を
    /// 読んでいるので、そのカードを上端へ戻すと、上の帯（No audio yetなど）が画面の外へ出る。
    /// 回しただけで帯が消えていた。覚えなければ一番上に居たままになる。
    func arm(split: Bool) {
        let shown = split ? onScreen : stackShown
        guard let first = order.first(where: shown.contains) else { return }
        anchor = first == order.first ? nil : first
    }

    /// その並べ方の行が画面から外れた。次に出るときに新しく数え直す。
    func forget(split: Bool) {
        if split {
            if !onScreen.isEmpty { onScreen = [] }
            if leading != nil { leading = nil }
        } else {
            stackShown = []
        }
    }

    private func updateLeading() {
        let first = order.first(where: onScreen.contains)
        if first != leading { leading = first }
    }
}

/// 右の鎖の行の矩形。**観測しない箱に入れる。**
///
/// 矩形はScrollViewに付けた座標（"chain"）で測っているので、送るたびに変わる。
/// @Stateに置いていたころは、送る1コマごとにPipelineViewのbodyが走り直していた
/// （最後の帯の高さtailHeightがbodyで矩形を読んでいたため）。
/// 読むのは並べ替えの判定（settle / beginDrag / endDrag）と、足したカードが
/// 見えているかの確かめだけで、どれも描き直しを要らない。
@MainActor
final class ETRowGeometry {
    private(set) var rects: [UUID: CGRect] = [:]
    /// 高さの合計。**高さが変わったときだけ足し直す。**送るだけなら位置しか変わらない。
    private var heights: CGFloat = 0
    /// 足したばかりで、見えているかをまだ確かめていないカード。
    var pendingReveal: UUID?

    subscript(id: UUID) -> CGRect? { rects[id] }

    func record(_ id: UUID, _ rect: CGRect) {
        let old = rects[id]
        rects[id] = rect
        if old?.height != rect.height {
            heights = rects.values.reduce(0) { $0 + $1.height }
        }
    }

    /// 行の高さの合計に行の間を足したもの。最後の帯の高さ（tailHeight）が使う。
    /// 行が1つも測れていなければ0。
    var contentHeight: CGFloat {
        rects.isEmpty ? 0 : heights + CGFloat(rects.count) * 10   // 行の間
    }

    /// 並べ方を切り替えた。前の並べ方の矩形は座標が違うので捨てる。
    func reset() {
        rects = [:]
        heights = 0
        pendingReveal = nil
    }
}

/// 2列の右で、読んでいる位置を保つ。**上のカードの高さが変わっても、読んでいるカードを画面の同じ所に置いておく。**
///
/// 画面の外のカードは図の枠をほとんど受け取らない（ETLiveRow、ETTelemetryFeed）。
/// GateやCompressorのGRの棒は枠が来て初めて出るので、一度も画面に入っていないカードは
/// 短いまま並び、別の理由で描き直されたときに伸びる。左の一覧で電源を押すと鎖ぜんぶが
/// 描き直され、上の2枚が71ptずつ伸びて、読んでいたカードが142pt下へずれたまま戻らなかった。
/// AUの画面が遅れて大きさを決めるのも、上の帯（No audio yetなど）が出入りするのも同じ形。
///
/// 読んでいるカードの「中身の中での位置」を覚える。画面の中の位置に送った量を足したもので、
/// 送るだけなら変わらない。送っていないのに変わったら上で何かの高さが変わったので、
/// 同じ量だけ送り直して、画面の中の位置を元に戻す（PipelineView.keepReading）。
///
/// 送り直さないとき（覚え直すだけ）:
///   - 人が触っている、または慣性で流れている。送りを取り合わない
///   - 一番上に居る。上の帯が出たら見えるように、一番上に居たままにする
///   - 鎖の並びが変わった。足す・消す・並べ替えには、それぞれの見せ方がある（revealNewなど）
///   - 並べ方の切り替えや幅の変化で、覚えたカードを上端へ戻している最中（restoreAnchor）
///
/// **観測しない。**送るたびに書くので、@Stateに置くとbodyが走り直す。
@MainActor
final class ETReadingKeeper {
    /// 読んでいるカード。
    private(set) var id: UUID?
    /// そのカードの中身の中での位置。nilならまだ測っていない。
    private var position: CGFloat?
    /// 覚えたときの鎖の並び。
    private var order: [UUID] = []

    /// 読むカードを決め直す。
    ///   - top: そのカードのいまの上端（右の鎖の座標）。測れていなければnil
    ///   - offset: いまの送った量（UIScrollViewのcontentOffset.y）
    ///
    /// **位置はここで取る。**次に測れたときに取ると、止まったまま上が伸びた回の
    /// 位置を覚えることになり、最初のずれを直せない（電源を押したときがまさにそれ）。
    func follow(_ id: UUID?, top: CGFloat?, offset: CGFloat, order: [UUID]) {
        self.id = id
        position = top.map { $0 + offset }
        self.order = order
    }

    /// 読んでいるカードが測れた。送り直す量を返す（0なら送らない）。
    ///   - top: 画面の中での上端（右の鎖の座標）
    ///   - offset: その回の送った量
    ///   - order: いまの鎖の並び
    ///   - keeps: 送り直してよいか
    func measured(top: CGFloat, offset: CGFloat, order now: [UUID], keeps: Bool) -> CGFloat {
        let current = top + offset
        defer {
            position = current
            order = now
        }
        guard let position, keeps, now == order else { return 0 }
        let moved = current - position
        return abs(moved) < 0.5 ? 0 : moved
    }
}

/// 右の鎖の1行を包む。見えているかを左の一覧へ知らせ、見えていない図を止める。
///
/// **1列でも2列でも包む。**1列では図を止めない（etGraphLiveは常に真）。
/// 見えているかを覚えるのは、1列から2列へ切り替えたときに読んでいた位置へ戻すため。
struct ETLiveRow<Content: View>: View {
    let id: UUID
    /// 2列の右に載っているか。
    let split: Bool
    let viewport: ETChainViewport
    @ViewBuilder var content: Content

    @State private var live = true

    var body: some View {
        content
            .environment(\.etGraphLive, !split || live)
            // 1%でも見えたら画面に入っているとみなす。**入る・出るときだけ呼ばれる。**
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                viewport.set(id, visible: visible, split: split)
                if split, live != visible { live = visible }
            }
    }
}
