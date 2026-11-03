//  AlertQueue.swift
//  警告を出す順番と、鎖を取り込んだ後に何を出すか。**Foundationだけで書く。**
//  判断をここに出してあるので、Logicのテスト（Linuxのswift testでも）から直接呼べる（AlertQueueTests）。
//
//  **警告のボタンの中で次の1枚を立てると出ない。**SwiftUIは.alertを閉じるとき、
//  isPresentedのset(false)で状態を書き戻す。ボタンの中で同じ状態に次の1枚を入れても、
//  同じ回のこの書き戻しがnilで消す。Presets → Import from clipboardの控え
//  （"Not found: Tape Warmth. …"）と、From Linkの"That does not look like a link."が
//  これで出ていなかった（シミュレータで確かめた）。
//
//  出し方はこう分ける:
//    1. 出したいものは`present`で頼むだけ。その場では出さない
//    2. .alertの書き戻しは`closed`。.alertを組んだときの`ticket`を添える
//    3. 画面は`canAdvance`を.onChangeで見て、真になったら次の回に`advance`を呼ぶ
//  .onChangeは出ていた1枚が消えた回に鳴り、`advance`はその次の回なので、.alertは
//  「閉じた」と「次の1枚」を別の回で受け取る。書き戻しとボタンのどちらが先に来ても同じになる。
//  決め打ちの時間では待たない（速い端末では余計に待たせ、遅い端末では足りない）。
//
//  **書き戻しは出している1枚の番号と合うときだけ効かせる。**前の1枚の書き戻しが次の1枚を
//  出した後に遅れて来ても（閉じ終わりでもう1度書くなど）、次の1枚を消さない。

import Foundation

/// 警告を1枚ずつ、前の1枚が閉じてから出す。
struct ETAlertQueue<Item> {
    /// いま出している1枚。.alertはこれを見る。
    private(set) var current: Item?
    /// いま出している1枚の番号。出すたびに増える。何も出ていなければnil。
    /// .alertのisPresentedを組むときに控え、書き戻しに添える（`closed`）。
    private(set) var ticket: Int?
    /// 出している1枚が閉じたら出すもの。**1つだけ持つ。**後から頼んだものが勝つ。
    private var waiting: Item?
    private var issued = 0

    /// 出すものを頼む。**その場では出さない**（頭の注記）。
    /// 何も出ていなければ次の回に、出ていればそれが閉じた後に出る。
    mutating func present(_ item: Item) {
        waiting = item
    }

    /// .alertが閉じた（isPresentedの書き戻し）。`ticket`はその.alertを組んだときの番号。
    /// **いま出している1枚の番号と違えば何もしない。**前の1枚の書き戻しが遅れて来ても、
    /// 次に出した1枚を消さない。待っているものは消さない。
    mutating func closed(_ ticket: Int?) {
        guard let ticket, ticket == self.ticket else { return }
        dismissed()
    }

    /// 出している1枚を下ろす（ボタンの中で自分から閉じるとき）。待っているものは消さない。
    mutating func dismissed() {
        current = nil
        ticket = nil
    }

    /// 待っているものを出せる状態か。画面はこれが真になったら次の回にadvanceを呼ぶ。
    var canAdvance: Bool {
        current == nil && waiting != nil
    }

    /// 待っているものを出す。まだ何か出ていれば何もしない（閉じてからもう一度来る）。
    mutating func advance() {
        guard current == nil, let next = waiting else { return }
        issued &+= 1
        current = next
        ticket = issued
        waiting = nil
    }
}

/// 貼られた鎖を取り込んだ後に出すもの（Presets → Import from clipboard）。
enum ETChainImportResult: Equatable {
    /// 鎖は入れ替えた。直したものも落としたものも無いので、黙って閉じる。
    case done
    /// 鎖は入れ替えた。直したもの・落としたものを1行で見せる（ETChainText.Report.message）。
    case imported(String)
    /// 1本も置けなかった。鎖はそのまま。
    case failed(String)

    /// `loaded`は置けた段の数。`unreadable`は字から鎖が読めなかったときの断り。
    ///
    /// **1本も置けなかったときも控えを出す。**段が全部知らない名前や取り込んでいない
    /// JSFXだったときに「読めない」とだけ言うと、何を直せばよいのか分からない
    /// （"Not found: JSFX tape wobble."）。控えに置けなかった段が無いなら、
    /// 字から鎖が見つからなかったということなので`unreadable`を出す。
    static func of(loaded: Int, report: ETChainText.Report, unreadable: String) -> ETChainImportResult {
        if loaded == 0 {
            return .failed(report.notFound.isEmpty ? unreadable : report.message)
        }
        return report.isEmpty ? .done : .imported(report.message)
    }
}
