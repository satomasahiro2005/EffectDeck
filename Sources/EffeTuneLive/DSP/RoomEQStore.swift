//  RoomEQStore.swift
//  Room EQ の測定・設計の設定・送り込む係を、段ごとに持つ。
//
//  ビューの @State では持てない。カードを畳むと RoomEQView は
//  「開いたとき」とは別の枝で組み立てられるので（EffectCardView.swift:54 と :65）、
//  畳むたびに作り直されて測定が消える。資産はカーネルに残ったままなのに
//  画面だけ「入っていない」に戻る、という食い違いが出る。
//
//  鍵は EffeTuneDSP.Node の id。instance ではない。
//  instance は prepare（出力先の切り替え・レート変更）で作り直されるが
//  （EffeTuneDSP.swift:577-586 の rebuildAll。Engine::prepare が
//   destroyAllInstances を通る）、id はそのまま残る。測定は id に付けておいて、
//  instance が変わったら送り直す、という分け方にしてある。
//
//  IRLibrary（DSP/IRLibrary.swift）と違って端末には残さない。
//  測定は数 MB あり、プリセットの保存形式（lt/fd/dy/gn の 4 float）にも
//  居場所が無い。アプリを畳んで戻るまでの間だけ持つ。

import Combine
import Foundation

@MainActor
final class RoomEQStore: ObservableObject {

    static let shared = RoomEQStore()

    /// 1 段ぶんの持ち物。
    @MainActor
    final class Session {
        /// 設計の設定。DSP のパラメータではないので、ここにしか居場所が無い
        /// （params.json:5-13 が DSP へ渡すのは lt/fd/dy/gn の 4 つだけ）。
        var config = RoomEQConfig()
        /// チャンネルの並び。nil の枠は素通し（単位インパルス）。
        /// **要素数が topology を決める。** 1 なら mono、2 以上は independent。
        var sources: [RoomEQSource?] = []
        /// 読み込んだ測定の 1 行。画面に出すだけ。
        var measurement: String = ""
        /// 設計して送り込む係。150ms まとめと世代破棄はこれが持っている。
        let correction = RoomEQCorrection()
    }

    private var sessions: [UUID: Session] = [:]
    /// RoomEQCorrection は自前の ObservableObject なので、入れ子のままでは
    /// 画面に届かない。自分の変更として流し直す。
    private var relays: [UUID: AnyCancellable] = [:]

    private init() {}

    func session(for id: UUID) -> Session {
        if let existing = sessions[id] { return existing }
        // 鎖から消えた段の測定を抱えたままにしない。数 MB が段の数だけ積む。
        prune()
        let created = Session()
        sessions[id] = created
        relays[id] = created.correction.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return created
    }

    /// 中身を書き換える。Session は class なので、触っただけでは画面に飛ばない。
    func update(_ id: UUID, _ body: (Session) -> Void) {
        objectWillChange.send()
        body(session(for: id))
    }

    /// 鎖に居ない段を落とす。
    private func prune() {
        let live = Set(EffeTuneDSP.shared.chain.map(\.id))
        // 回しながら消すので、鍵は先に控える。
        for id in Array(sessions.keys) where !live.contains(id) {
            sessions[id] = nil
            relays[id] = nil
        }
    }
}
