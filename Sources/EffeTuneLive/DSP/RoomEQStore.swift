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

    // MARK: - 設計して送る

    /// 設計し直して送り直す。schedule が 150ms まとめて 1 回にするので、
    /// つまみを動かし続けても設計は 1 回で済む（RoomEQDesigner.swift:1265-1276）。
    ///
    /// **ビューから切り出してここに置いてある。** instance が作り直されるのは
    /// prepare のときで、そのときこのカードが組み立てられているとは限らない。
    /// 畳んだまま出力先を切り替えると、ビュー側の onChange は一度も来ない。
    ///
    /// - Returns: 画面に出す失敗の文。頼めたときは nil。
    @discardableResult
    func design(node: EffeTuneDSP.Node) -> String? {
        let dsp = EffeTuneDSP.shared
        let session = session(for: node.id)
        guard !session.sources.isEmpty else { return nil }
        guard dsp.engine != 0, node.instance != 0 else { return nil }

        let width = Self.processingChannels(of: node)
        guard width > 0 else { return Self.notRouted }

        var config = session.config
        // **ヘッダ +12 は処理レート。割らない。** RoomEQ の rateDivider は 1 固定で、
        // カーネルは readU32(bytes+12) == lround(sample_rate_) を見る
        // （dsp/plugins/eq/room_eq/kernel.cpp の validatePayload）。
        // 処理レートは 48000 とは限らない（AudioIO.swift:157/383 の factor）。
        config.sampleRate = Int(dsp.sampleRate.rounded())

        // **要素数が topology を決める。** 1 なら mono（1 本を全チャンネルへ）、
        // 2 以上は independent で、処理幅と一致していないと send が
        // channelCountMismatch で弾く（RoomEQDesigner.swift:437-442）。
        var sources = session.sources
        if sources.count > width { sources = Array(sources.prefix(width)) }

        let mode = Self.latencyMode(of: node)
        let instance = node.instance
        session.correction.schedule(config: config,
                                    sources: sources,
                                    engine: dsp.engine,
                                    instance: instance,
                                    processingChannels: UInt32(width),
                                    latencyMode: mode) { design in
            // 設計が終わって、送る直前。ここが fd を書ける唯一の隙間。
            // カーネルは begin の時点の fd で遅延を決める
            // （kernel.cpp beginAsset の candidate_latency_）ので、
            // 後から書いても遅延だけ前の設計のまま残る。
            //
            // 並べ替えを跨ぐので、位置は instance から引き直す。
            guard let at = dsp.chain.firstIndex(where: { $0.instance == instance }) else { return }
            // lt は普通そのまま戻る値なので、外れているときだけ直す。
            // 毎回書くと node.values が変わり、それを見張っている onChange が
            // もう一度送り直しに来る。
            let offset = RoomEQDesigner.ParameterOffset.latencyMode
            let want = RoomEQDesigner.parameterValue(forLatencyMode: mode)
            if dsp.chain[at].values.indices.contains(offset),
               dsp.chain[at].values[offset] != want {
                dsp.setValue(want, at: at, offset: offset)
            }
            dsp.setValue(Float(design.filterDelaySamples),
                         at: at, offset: RoomEQDesigner.ParameterOffset.filterDelaySamples)
        }
        return nil
    }

    /// カーネルから資産が消えていたら送り直す。
    @discardableResult
    func resendIfGone(node: EffeTuneDSP.Node) -> String? {
        let dsp = EffeTuneDSP.shared
        let session = session(for: node.id)
        guard !session.sources.isEmpty, dsp.engine != 0, node.instance != 0 else { return nil }
        // 送っている最中は触らない。送っているあいだ鎖全体が素通しになるので
        // （AssetUpload.swift:48-60）、重ねて頼まない。
        switch session.correction.state {
        case .designing, .sending: return nil
        default: break
        }
        let state = AssetUpload.status(engine: dsp.engine, instance: node.instance).state
        guard state == ETAssetState.none || state == ETAssetState.error else { return nil }
        return design(node: node)
    }

    static let notRouted =
        "This effect is not routed to any channel. Change Routing first."

    /// この段が処理する幅。All は接続中の出力IFの本数。
    static func processingChannels(of node: EffeTuneDSP.Node) -> Int {
        BandFIRPEQDesigner.processingChannels(channelSpec: node.channelSpec,
                                              engineChannels: Int(EffeTuneDSP.shared.maxChannels))
    }

    /// lt の保存値（列挙の番号）を headBlock へ読み替える。
    static func latencyMode(of node: EffeTuneDSP.Node) -> UInt32 {
        let offset = RoomEQDesigner.ParameterOffset.latencyMode
        let raw = node.values.indices.contains(offset) ? node.values[offset] : 1
        return RoomEQDesigner.latencyMode(fromParameterValue: raw)
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
