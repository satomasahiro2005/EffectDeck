//  ETJSFXLoader.swift
//  JSFX のコンパイルと @init を回す専用スレッド。UIKit にも et_* にも触らないので、
//  テストのバンドルへそのまま入れてある（project.yml）。

import Foundation

enum ETJSFXLoader {
    /// **16 MB。協調プールのスレッドで回さない。**
    ///
    /// EEL2 のコンパイラは演算子 1 つにつき 1 段再帰する（nseel-compiler.c の
    /// optimizeOpcodes / compileOpcodes）。括弧を数える sourceWithinBudgets は
    /// `a+a+a+…` を素通しするので、Task.detached のスレッド（512 KB）では
    /// 約 2000 個で溢れてアプリごと落ちた（実測・4 KB のソース）。
    /// 16 MB なら約 6 万個まで通る。それより長いものを止めるのはソースの門の仕事。
    static let stackSize = 16 << 20

    /// 専用スレッドで `work` を回して結果を返す。
    ///
    /// **止まらないスクリプトはスレッドごと残る。**EEL の実行を途中で切る口が無い。
    /// 協調プールで回すと、その 1 本がプールの席を死ぬまで塞ぎ、
    /// 何本か溜まると Task.detached の仕事（状態保存・破棄）が全部止まる。
    /// 専用スレッドなら塞ぐのはそのスレッドだけで済む。
    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.name = "ai.nemut.effectdeck.jsfx.loader"
            thread.stackSize = stackSize
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// 列挙つまみの選択。**Int(Double) に NaN・無限・範囲外を渡さない。**
    ///
    /// 値はスクリプトが直に書ける（`slider1 = 0/0;`）。復元した状態も
    /// ysfx は検めずに書き戻す。そのまま Int() に渡すとメインスレッドで落ち、
    /// 開いたカードは次の起動でまた描かれるので、起動のたびに落ちる。
    /// 範囲は tag（0..<count）に寄せる。NaN は先頭。
    static func enumIndex(_ value: Double, count: Int) -> Int {
        guard count > 0, !value.isNaN else { return 0 }
        return Int(min(max(value.rounded(), 0), Double(count - 1)))
    }
}
