//  SectionBracket.swift
//  Section の配下だと分かるようにする印。
//
//  **囲まない。**枠線で囲うのは Web の作法で、iOS の一覧の作法ではない。
//  行間も詰めない（詰めるとカードが切れて別の問題が出る）。
//  左に線を引いて内側へ寄せるだけ。ショートカットの「繰り返す」ブロックと同じ形。
//
//  借りているのは上流の**区切りの規則**だけ（Section から次の Section の手前まで。
//  js/audio/dsp-pipeline-descriptor.js:190-201。入れ子にはならない）。
//
//  色は tint を薄くしたもの。新しい色を定義しない。

import SwiftUI

struct ETSectionBracket<Content: View>: View {
    let active: Bool
    /// 上下の行へ線を伸ばすか。**行間を跨がせないと線が切れて点線に見える。**
    /// 組の先頭は下だけ、末尾は上だけ、途中は両方。
    var extendsUp: Bool = false
    var extendsDown: Bool = false
    @ViewBuilder var content: Content

    /// 線の幅と、線とカードのあいだ。
    ///
    /// **カードの幅を変えない。**線のぶんは行の外側の余白から取る
    /// （PipelineView が listRowInsets の leading を inset に落とす）。
    /// `inset + rule + gap` が普通の行の余白（14）と等しくなるようにしてあるので、
    /// Section の中と外でカードの左端が揃い、幅も同じになる。
    /// 変えると図もつまみも 2 通りの幅で確かめることになる。
    /// **ジェネリックな型に static let は置けない。**計算で返す。
    static var inset: CGFloat { 4 }
    /// 組の中の行で、カードの左端が来る位置（inset + rule + gap）。
    /// 普通の行の余白（14）と同じになるようにしてある。
    static var cardLeading: CGFloat { 14 }
    private static var rule: CGFloat { 3 }
    private static var gap: CGFloat { 7 }
    /// 行の上下に空いている量（PipelineView の listRowInsets と同じ値）。
    private static var rowGap: CGFloat { 5 }

    var body: some View {
        if active {
            HStack(spacing: Self.gap) {
                Capsule()
                    .fill(.tint.opacity(0.35))
                    .frame(width: Self.rule)
                    // 行の上下の余白（listRowInsets の 5）を打ち消して、
                    // 隣の行の線と繋げる。端は打ち消さないので丸いまま残る。
                    .padding(.top, extendsUp ? -Self.rowGap : 0)
                    .padding(.bottom, extendsDown ? -Self.rowGap : 0)
                content
            }
        } else {
            content
        }
    }
}
