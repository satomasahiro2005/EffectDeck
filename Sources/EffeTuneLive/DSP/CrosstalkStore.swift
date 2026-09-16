//  CrosstalkStore.swift
//  Crosstalk Cancellation の測定・設計の指示・送り込む係を、段ごとに持つ。
//
//  ビューの @State では持てない。カードを畳むと CrosstalkCancellationView は
//  「開いたとき」とは別の枝で組み立てられるので（EffectCardView.swift の
//  `if isExpanded && hasBody`）、畳むたびに作り直されて測定が消える。
//  資産はカーネルに残ったままなのに画面だけ「入っていない」に戻り、
//  そこから指示を 1 つ触ると既定値で設計し直されて音が変わる。
//
//  置き方は RoomEQStore と同じ。鍵は EffeTuneDSP.Node の id で、instance ではない。
//  instance は prepare（出力先の切り替え・レート変更）で作り直されるが、id は残る。
//
//  IRLibrary と違って端末には残さない。測定は数 MB あり、段のパラメータは
//  float の並びしか持てない（ETParam）ので、プリセットに書く口が無い。

import Combine
import Foundation

@MainActor
final class CrosstalkStore: ObservableObject {

    static let shared = CrosstalkStore()

    /// 1 段ぶんの持ち物。
    @MainActor
    final class Session {
        /// 左耳・右耳の測定。両方揃って初めて設計する
        /// （crosstalk_cancellation.js:281-287）。
        var leftEar: ETCrosstalkLoader.Ear?
        var rightEar: ETCrosstalkLoader.Ear?

        // 設計の指示。**DSP のパラメータではない。**
        // カーネルへ行くのは st / og / lt / fd の 4 つだけ
        // （Generated/EffectCatalog.swift の CrosstalkCancellationPlugin）。
        // 既定は上流の初期値（crosstalk_cancellation.js:50-59）。
        var taps = 4096
        var regularization = 50.0
        var maxGainDb = 12.0
        var lowFrequency = 200.0
        var highFrequency = 6000.0
        var directWindowMs = 8.0

        /// 設計して送り込む係。150ms まとめと同一注文の抑止はこれが持っている。
        let controller = CrosstalkCancellationController()

        /// 最後に送った instance。作り直されたら送り直すための控え。
        var sentInstance: UInt32 = 0

        var hasMeasurements: Bool { leftEar != nil && rightEar != nil }
    }

    private var sessions: [UUID: Session] = [:]
    /// controller は自前の ObservableObject なので、入れ子のままでは画面に届かない。
    /// 自分の変更として流し直す（RoomEQStore と同じ）。
    private var relays: [UUID: AnyCancellable] = [:]

    private init() {}

    func session(for id: UUID) -> Session {
        if let existing = sessions[id] { return existing }
        // 鎖から消えた段の測定を抱えたままにしない。数 MB が段の数だけ積む。
        prune()
        let created = Session()
        sessions[id] = created
        relays[id] = created.controller.objectWillChange.sink { [weak self] _ in
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
        for id in Array(sessions.keys) where !live.contains(id) {
            sessions[id] = nil
            relays[id] = nil
        }
    }

    // MARK: - 設計して送る

    /// 4 枠が揃っていれば設計して送る。
    ///
    /// **ビューから切り出してここに置いてある。** instance が作り直されるのは
    /// prepare のときで、そのときこのカードが組み立てられているとは限らない。
    /// 畳んだまま出力先を切り替えると、ビュー側の onChange は一度も来ない。
    ///
    /// MainActor で呼ぶこと（AssetUpload.send がそれを求めている）。
    func design(node: EffeTuneDSP.Node) {
        let dsp = EffeTuneDSP.shared
        let session = session(for: node.id)

        guard let left = session.leftEar, let right = session.rightEar else {
            // 上流も全枠が埋まるまで設計しない（crosstalk_cancellation.js:281-287）。
            if session.controller.phase != .idle {
                session.controller.clear(instance: node.instance)
            }
            return
        }
        guard dsp.ready, dsp.engine != 0, node.instance != 0 else { return }

        // 枠の割り当ては crosstalk_cancellation.js:20-31。
        // 同じ耳の 2 本は 1 つの測定の 2 チャンネルで、左スピーカーが下のチャンネル。
        let sources = CrosstalkCancellationController.Sources(ll: left.leftSpeaker,
                                                             lr: right.leftSpeaker,
                                                             rl: left.rightSpeaker,
                                                             rr: right.rightSpeaker)
        let config = CrosstalkCancellationController.Config(
            sampleRate: Int(dsp.sampleRate.rounded()),
            taps: session.taps,
            regularization: session.regularization,
            maxGainDb: session.maxGainDb,
            lowFrequency: session.lowFrequency,
            highFrequency: session.highFrequency,
            directWindowMs: session.directWindowMs)

        let instance = node.instance
        session.sentInstance = instance

        session.controller.apply(
            engine: dsp.engine,
            instance: instance,
            headBlock: Self.headBlock(of: node),
            config: config,
            sources: sources,
            beforeSend: { built in
                // 設計が置いた山の位置を dry 側の遅延にも入れる。
                // beginAsset は applyPendingParameters() を先に通るので、
                // 送る直前に書けば同じ begin で効く（kernel.cpp:156）。
                //
                // 並べ替えを跨ぐので、位置は instance から引き直す。
                guard let at = dsp.chain.firstIndex(where: { $0.instance == instance }),
                      let param = node.spec.params.first(where: { $0.key == "fd" }) else { return }
                dsp.setValue(Float(built.config.filterDelaySamples), at: at, offset: param.offset)
            },
            afterSend: {
                // commit で instance の遅延が変わるので、鎖を組み直させる。
                // setRouting は何も変えずに呼んでも publish まで進む。
                guard let at = dsp.chain.firstIndex(where: { $0.instance == instance }) else { return }
                dsp.setRouting(at: at)
            })
    }

    /// カーネルから資産が消えていたら送り直す。
    ///
    /// instance が作り直されたかどうかだけを見る。番号は使い回されることがあるので
    /// 本当は tapId で見たいが、controller 側が instance で注文を突き合わせている
    /// （同じ注文なら送らない）ので、ここは番号の比較で足りる。
    func resend(node: EffeTuneDSP.Node) {
        let session = session(for: node.id)
        guard session.hasMeasurements, node.instance != 0 else { return }
        guard session.sentInstance != node.instance else { return }
        design(node: node)
    }

    /// latencyMode（lt）の添字を begin の headBlock へ。
    static func headBlock(of node: EffeTuneDSP.Node) -> UInt32 {
        guard let param = node.spec.params.first(where: { $0.key == "lt" }),
              node.values.indices.contains(param.offset) else { return 128 }
        return CrosstalkCancellationDesigner.headBlock(forLatencyMode: node.values[param.offset])
    }
}
