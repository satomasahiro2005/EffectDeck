//  RemoteMirror.swift
//  PC の EffeTune（fork）を LAN から操る PoC。EffectDeck が操作する側（remote-v1 と v2 の足し分）。
//
//  **つないでいるあいだ、EffectDeck は PC の鎖の編集画面になる。**
//    1. つないだ瞬間に手元の鎖を退避する（UserDefaults の remote.stash）
//    2. PC の鎖（hello の返事の state）を画面へ入れる
//    3. 以後の手元の編集は PC へ送る。PC の上での編集（state の origin "local"）は追って画面へ入れる
//    4. 切ったら・切れたら、退避した鎖を戻す
//  編集しているあいだ persist() は端末へ書かない（EffeTuneDSP.persist の門）。pipeline.last と
//  iCloud は手元の鎖のまま残るので、途中でアプリが落ちても次の起動は手元の鎖から始まる。
//  退避が残ったまま起動したら、つながっていなくても戻して消す（start）。
//
//  つないだ直後に、IR を両方向へ足し合わせる（syncAll）。消さない・上書きしない。
//  決まりは RemoteProtocol.swift（ETRemoteIRSync）。
//  **つないでいるあいだも足し合わせ直す**（syncIRsLive）。PC が irsChanged を送ってきたとき（hello の
//  sync: 1。PC が sync1 のとき）と、手元の IR が増えたとき（IRLibrary.entries）。どちらも 1 秒まとめてから、
//  PC の一覧（listIRs）と見比べて、足りない分だけ取る・送る。消さない。切れたら捨てる。
//  **前に見たときから増えた分だけ**。片方で消したものを、もう片方の写しから戻さない（ETRemoteIRSync.livePlan）。
//
//  **プリセットは向きで扱いが違う。**
//    PC → EffectDeck  PC のホスト名のフォルダが PC の写し。つないだ直後と、PC が presetsChanged を
//                     送るたび（hello の sync: 1。PC が sync1 のとき）に丸ごと入れ替える。
//                     フォルダの中だけ足す・上書き・消す（PresetStoreCore.mirrorFolder）。
//                     フォルダの中を手元で直しても次の入れ替えで PC のものに戻る
//    EffectDeck → PC  足すだけ。同じ名前で中身が違えば `名前 (iPad)`（ETRemotePresetSync）。PC にはフォルダが無い。
//                     PC の写しのフォルダは送り返さない
//  **写しのフォルダは写したことがあるものだけ入れ替える**（PresetStoreCore.remoteFoldersKey）。
//  ホスト名と同じ名前の人のフォルダが前から在れば触らず、`名前 2` へ写す。
//  iCloud へは今までどおり PresetStoreCore が触った名前だけ当てる（鎖の persist() の門とは別）。
//
//  つなぎ先: ws://<host>:47300/?t=<token>（ETRemoteAddress）。トークンが違うと PC は
//  コード 4401 で閉じるので、その場合は再接続しない（繰り返しても通らない）。
//  PC の画面の QR（http://host:port/?t=…。ws:// も読む）をアプリの中の読み取り（RemoteScannerView）で読んだら
//  pair(_:) が控えてつなぐ（入口はツールバーのアイコン・帯・設定画面の Remote の面）。
//
//  **入切のスイッチは無い。**QR を読む（pair）か Connect でつなぎ、Disconnect で切る。
//  Disconnect しなければ、起動のたびに控えた PC へつなぎ直す（Preferences.remoteWantsConnection）。
//  遷移は ETRemoteIntent（RemoteProtocol.swift）。ここはそれを Preferences へ書いて apply() を呼ぶだけ。
//
//  **控え（intent）とつながっているか（status・isRemote）は別。**控えの「つなぎたい」は起動をまたいで残るが、
//  Connected は hello の返事を受けてから、切れる・応答が途絶えるまでだけ。PC が黙って消えても（眠った・
//  Wi-Fi が替わった）URLSession は気づかないので、ping で見回って切る（ETRemoteHeartbeat）。
//  hello に返事が無いときも Connecting で止めずに切ってつなぎ直す。
//
//  ---------------------------------------------------------------------------
//  **何を送るか（メッセージの一覧は remote-v1 と v2）**
//    hello       つないだ直後に 1 回。返事の state で PC の鎖を入れ、Connected にする
//    chain       鎖ごと入れ替え。並び・入切・バス・段の中身が変わったとき
//    params      1 段のパラメータ。つまみ操作。30 Hz でまとめ、段ごとに最後の値だけ送る
//    bypass      全体のバイパス
//    listPresets / getPreset / savePreset   PC のプリセットの写し（presetsChanged でも）と、PC への足し込み
//    listIRs / getIR / putIR               同じく IR（irsChanged でも）。512 KiB ずつ base64 で
//    telemetry   PC のアナライザの測定値を受ける入切（Mirror Analyzers）。受けた枠は Telemetry へ差し込む
//                PC が overlays を持てば PEQ の重ね表示の前後も受け、手元の探りの tap へ差し込む
//
//  **返事は seq で待つ**（request）。データの返事（presets・preset・state）は ack の後に同じ seq で来る。
//  getIR だけは塊（irChunk）が先で ack が最後。
//
//  **PC から来た state は origin で振る**（ETRemoteStateFilter）。自分のコマンドの結果（origin
//  "remote" で seq が自分のもの）は捨てる。手元のコマンドが ack を待っているあいだの "local" も捨てる
//  （そのコマンドより前の PC の形かもしれず、入れるとつまみが 1 つ前の値へ戻る）。
//  捨てたら、ack が出揃ったところで get で今の形を取り直す（resyncIfSettled）。
//
//  **鎖は persist() の入口で受ける**（EffeTuneDSP.persist）。鎖を触る経路は全部ここへ来る。
//
//  **同じ中身は送らない。**つまみを動かした後の 0.5 秒遅れの persist() が、もう params で
//  送った値の鎖をもう一度送らないように、params を送るたびに「最後に送った鎖」の
//  その段も書き換えておく。PC から入れた鎖も「送った」ことにしておく。
//
//  **外部の段（AU / JSFX）は PC へ渡らない**（RemoteProtocol.swift）。編集中に足しても送らない
//  だけで、足すこと自体は止めない。段の番号がずれるので、params は最後に送った鎖の対応表で
//  PC の番号へ直して送る。
//
//  **PC のアナライザの測定値を映す（telemetry。PC が hello の features に "telemetry" を出すときだけ）。**
//  編集しているあいだ鳴っているのは PC なので、Analyzer の図は PC の枠で描く。
//  PC は段ごと・種類ごとに最新の枠だけを 15 fps で送ってくる（index は PC の鎖の番号）。
//  sentMap を裏返して手元の段を引き、名前が合う Analyzer の段だけ tapId を付け替えて
//  Telemetry.inject へ入れる。映している tap は Telemetry.setMirrored で知らせ、手元の枠は捨てる。
//  背景に回ったら止める（setAppActive）。PC は誰も受けていなければ枠を作らない。
//
//  音のスレッドには触らない。ここは全部メインで、通信は URLSession が別のスレッドで持つ。
//  IR のファイルの読み書きと鍵の計算はメインの外（Task.detached）。
//  ---------------------------------------------------------------------------

import Combine
import Foundation
import os

@MainActor
final class RemoteMirror: ObservableObject {

    static let shared = RemoteMirror()

    typealias Status = ETRemoteStatus

    /// **つながっているか（live）。**hello の返事を受けたら connected、切れた・応答が途絶えたら（ETRemoteHeartbeat）
    /// error。起動は disconnected から始まり、控えの「つなぎたい」（intent）からは決めない。
    /// 「Connected」と言う・アイコンを塗る（ETRemoteIndicator）のはこれだけを見る。
    @Published private(set) var status: Status = .disconnected
    /// つないだ直後の足し合わせの進み（"Syncing 3/7"）。済んだら nil。
    @Published private(set) var progress: String?
    /// PC の鎖を編集しているか。**手元の鎖は退避してあり、persist() は端末へ書かない。**
    /// 立つのは hello の返事を受けて PC の鎖を入れたとき（enterRemote）、下りるのは接続を落としたとき（leaveRemote）。
    /// **控え（intent）ではなく、いまのつなぎに付いていく。**「リモート中」で振る舞いを変える所
    /// （persist と iCloud の門・Plugins を隠す・出力補正を外す・出力先の切り替えを見送る・帯と中央の札）は
    /// 全部これを見る。画面に出ているのが PC の鎖のあいだだけ、の話なので。
    /// 控えで振ると、PC が居ないのに手元の編集が端末にも iCloud にも残らず、Plugins も補正も消えたままになる。
    @Published private(set) var isRemote = false

    /// Status の行に出す字。
    var statusText: String {
        if status == .connected, let progress { return progress }
        return status.label
    }

    /// 控え・つなぎたいか・4401 から決まる状態。シートの形（layout）と Connect を出すかはここから読む。
    /// Preferences（remoteAddress・remoteWantsConnection）と tokenRejected が変われば、
    /// どちらも観測しているビューが読み直す。
    var intent: ETRemoteIntent {
        ETRemoteIntent(hasAddress: ETRemoteAddress.parse(Preferences.shared.remoteAddress) != nil,
                       wantsConnection: Preferences.shared.remoteWantsConnection,
                       tokenRejected: tokenRejected)
    }
    /// 最後のつなぎで 4401 を受けた。読み直す（pair）か、つながれば戻す。
    @Published private(set) var tokenRejected = false
    /// 最後につないだ PC の EffeTune の名前と版。切断中の Connect のボタンにホスト名を出す。
    /// 版は出さない（つながっていないのに並べると、つながっているように読める）。
    /// つないだら書き換え、別の PC を読んだ・Forget したら消す。
    @Published private(set) var lastHost: ETRemoteLastHost? = RemoteMirror.loadLastHost()
    /// PC の測定値を映している段の tapId。ETRemoteMeasurementDim はここに入った段を沈めない。
    @Published private(set) var mirroredTaps: Set<UInt32> = []

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "remote")
    private let session = URLSession(configuration: .default)

    private var task: URLSessionWebSocketTask?
    /// つなぎ直すたびに進める。古い receive の結果が新しいつなぎを壊さないため。
    private var generation = 0
    private var seq = 0
    private var backoff: TimeInterval = 1
    private var reconnectTask: Task<Void, Never>?
    /// PC が生きているかの見回り（ETRemoteHeartbeat）。ソケットを開いてから落とすまで。
    private var heartbeat: ETRemoteHeartbeat?
    private var heartbeatTask: Task<Void, Never>?

    /// 最後に PC へ送った鎖と、手元の番号 → PC の番号の対応。
    private var sentForm: [[String: Any]]?
    private var sentMap: [Int?] = []

    /// params を送りたい段（手元の番号）。30 Hz でまとめて送る。
    private var pendingParams: Set<Int> = []
    private var flushTask: Task<Void, Never>?

    /// PC から来た鎖を入れているあいだ。入れた結果の persist() や params を PC へ送り返さない。
    private var applyingRemote = false
    /// persist() が 1 度でも来たか（= restore() が済んだ）。待たせていたものを片付ける合図。
    private var localChainReady = false

    // MARK: 返事の待ち合わせ

    /// seq ごとの待ち手。届いたものを渡し、true を返したら外す。nil は切れた・時間切れ。
    private typealias Waiter = ([String: Any]?) -> Bool
    private var waiters: [Int: Waiter] = [:]
    /// 鎖を変えるコマンド（chain・params・bypass）の seq。自分の結果の state を見分ける。
    private var ours: Set<Int> = []
    /// 鎖を変えるコマンドのうち、まだ ack が来ていないもの（送った時刻）。
    /// ack が落ちても追うのが止まりっぱなしにならないよう、2 秒で見なくなる。
    private var inFlight: [Int: Date] = [:]
    private var waitingForAck: Bool {
        inFlight.values.contains { $0.timeIntervalSinceNow > -2 }
    }
    /// chain（段の並びを変えるコマンド）のうち、まだ ack が来ていないもの。inFlight と同じく 2 秒で見なくなる。
    /// PC の測定値の番号が手元の番号と食い違いうるのはこのあいだだけ（params と bypass では番号は動かない）。
    private var chainInFlight: [Int: Date] = [:]
    private var chainSettling: Bool {
        chainInFlight.values.contains { $0.timeIntervalSinceNow > -2 }
    }
    /// 手元の変更がまだ PC に着いていない（送る前のつまみ・ack 待ち）。PC の形を入れると値が戻る。
    private var busy: Bool { waitingForAck || !pendingParams.isEmpty }
    /// busy のあいだに PC の変更を捨てた。ack が出揃ったら get で今の形を取り直す。
    private var resyncWanted = false

    // MARK: 追う・退避

    /// PC で起きた変更の最後の state。150 ms まとめてから入れる。
    private var pendingFollow: [String: Any]?
    private var followTask: Task<Void, Never>?
    /// hello の返事が restore() より先に来たとき、済むまで取っておく。
    private var pendingHello: [String: Any]?
    /// 起動したときに退避が残っていた。restore() が済んだら戻す。
    private var pendingRestore = false
    private var syncTask: Task<Void, Never>?
    /// IR を足し合わせ直す前の待ち。PC の irsChanged と手元の IR の増加から。待ち終えて走り出したら nil に戻す
    /// （走っている足し合わせは待ち直しで止めない。頼まれ直したら irSyncAgain で見直す）。
    private var irSyncTask: Task<Void, Never>?
    /// IR の足し合わせが走っている（つないだ直後の syncAll の IR も含む）。重ねて走らせない。
    private var irSyncBusy = false
    /// 走っているあいだにまた頼まれた。終わったら見直す。
    private var irSyncAgain = false
    /// 前に見た PC の IR の一覧（と、そのあと送れた鍵）。ライブではこれに無い PC の鍵だけ取る
    /// （手元で消した IR を取り直さない）。nil はまだ見ていない（ETRemoteIRSync.livePlan）。
    private var irKnownPC: Set<String>?
    /// 前に見た手元の IR の一覧（と、そのあと取れた鍵。手元で消した鍵は抜く）。これに無い鍵が出たら
    /// 手元で増えたとみなし、それだけ送る（PC で消した IR を送り直さない）。
    private var irKnownLocal: Set<String>?
    /// このつなぎの中で失敗した IR の鍵。変わるたびに同じものを取り直さない。
    private var irFailed: Set<String> = []
    private var irSink: AnyCancellable?
    /// PC が presetsChanged を送ってから写し直すまで少し待つ（続けて保存されても 1 回で済ませる）。
    private var presetMirrorTask: Task<Void, Never>?
    /// 写しの取得を始めるたびに進める番号と、入れ替えに使った一番新しい番号。
    /// 先に始めた取得が後から終わっても、新しい取得の結果を古いもので上書きしない。
    private var mirrorTicket = 0
    private var mirroredTicket = 0

    // MARK: PC のアナライザの測定値

    /// つないでいる PC の EffeTune（hello の返事から）。つながっていないときは nil。
    @Published private(set) var host: ETRemoteHostInfo?
    /// つながっていて、PC が telemetry を持っていない（古い EffeTune）。Mirror Analyzers を無効にして理由を出す。
    var telemetryUnsupported: Bool { isRemote && (host.map { !$0.supports("telemetry") } ?? false) }
    /// 手元と PC の EffeTune の食い違い（効果の差と dsp の版）。つながっていない・食い違いが無いときは nil。
    var mismatch: ETRemoteMismatch? {
        guard isRemote else { return nil }
        return host?.mismatch(localDSP: ETUpstreamVersion, localEffects: ETRemoteHostInfo.localEffectNames)
    }
    /// この効果を PC が持っていない（つながっているあいだだけ）。カードの印と、鎖に載せない段の判定。
    func hostLacks(_ effect: String) -> Bool { isRemote && host?.lacks(effect) == true }
    /// PC が hello の features に "telemetry" を出した。
    private var serverTelemetry = false
    /// PC が hello の features に "overlays" を出した（PEQ の重ね表示の前後の枠を送れる）。
    private var serverOverlays = false
    /// 最後に送った telemetry の入切。
    private var telemetryWanted = false
    /// 最後に送った telemetry の seq。古い ack の ok:false で今の入切を倒さない。
    private var telemetrySeq: Int?
    /// 前にいるか。背景（.background）では PC に枠を作らせない。
    private var appActive = true
    /// 鎖の組み直し（tapId が変わる）を拾って映す段を決め直す。
    private var chainSink: AnyCancellable?
    private static let telemetryFPS = 15

    private static let lastHostKey = "remote.lastHost"
    private static let stashKey = "remote.stash"
    private static let stashBypassKey = "remote.stashBypass"

    private init() {}

    // MARK: - 設定

    /// 起動で 1 回。**App の init から呼ぶ**（EffeTuneLiveApp.swift）。
    /// Disconnect していなければ（つなぎたいが残っていて控えもあれば）、控えた PC へつなぐ。
    func start() {
        // 編集中に落ちた。pipeline.last は手元の鎖のままだが、書き切る前だった分も含めて退避から戻す。
        // **閉じた版（ETFeatures.remoteControl）でも戻す。**ベータで編集中に落ちて店の版へ上げた人の手元の鎖。
        pendingRestore = UserDefaults.standard.data(forKey: Self.stashKey) != nil
        // 閉じた版では控えに触らず、つながない（上流が API を出して開けたら、控えからそのままつなぎ直せる）。
        guard ETFeatures.remoteControl else { return }
        transition { $0.launch() }
        apply()
    }

    /// 控えた PC へつなぎ直す（Connect）。控えが無い・4401 だったときは何もしない。
    /// 手元の鎖を退避して PC の鎖を入れる流れは、つながったとき（enterRemote）にいつもどおり走る。
    func connectToSaved() {
        var ok = false
        transition { ok = $0.connect() }
        guard ok else { return }
        backoff = 1
        apply()
    }

    /// 切る（Disconnect）。控えは残す。apply() が接続を落とし、退避した手元の鎖を戻す（leaveRemote）。
    /// 起動してもつなぎ直さない。
    func disconnectByUser() {
        transition { $0.disconnect() }
        backoff = 1
        apply()
    }

    /// PC の QR の接続先（http://host:port/?t=…。前の形の ws:// も）。読めたら控えてつなぐ。
    /// アプリの中の読み取り（RemoteScannerView）から。
    /// つないでいる最中でも、新しい PC へつなぎ直す（apply が先に切って手元の鎖を戻す）。
    @discardableResult
    func pair(_ url: URL) -> Bool {
        guard let address = ETRemoteAddress.pairingLink(url) else { return false }
        Preferences.shared.remoteAddress = address.text
        setLastHost(nil)
        transition { $0.pair() }
        backoff = 1
        apply()
        return true
    }

    /// 控えを消して切る。
    func forget() {
        Preferences.shared.remoteAddress = ""
        setLastHost(nil)
        transition { $0.forget() }
        backoff = 1
        apply()
    }

    /// 遷移（ETRemoteIntent）を通して Preferences と tokenRejected へ書き戻す。
    /// 控えの字は pair が先に書く。控えが無くなる遷移（forget）では字を空にする。
    private func transition(_ change: (inout ETRemoteIntent) -> Void) {
        var next = intent
        change(&next)
        let prefs = Preferences.shared
        if prefs.remoteWantsConnection != next.wantsConnection { prefs.remoteWantsConnection = next.wantsConnection }
        if tokenRejected != next.tokenRejected { tokenRejected = next.tokenRejected }
        if !next.hasAddress, !prefs.remoteAddress.isEmpty { prefs.remoteAddress = "" }
    }

    private func setLastHost(_ host: ETRemoteLastHost?) {
        guard lastHost != host else { return }
        lastHost = host
        if let host, let data = try? JSONEncoder().encode(host) {
            UserDefaults.standard.set(data, forKey: Self.lastHostKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastHostKey)
        }
    }

    private static func loadLastHost() -> ETRemoteLastHost? {
        UserDefaults.standard.data(forKey: lastHostKey)
            .flatMap { try? JSONDecoder().decode(ETRemoteLastHost.self, from: $0) }
    }

    /// 接続を落として、つなぎたいなら張り直す。つなぎたくなければ Disconnected。
    private func apply() {
        disconnect()
        // 閉じた版では入口が無いので来ないが、来てもつながない。
        guard ETFeatures.remoteControl, intent.wantsConnection else {
            status = .disconnected
            return
        }
        connect()
    }

    // MARK: - 手元の変更を写す（EffeTuneDSP から 1 行で呼ぶ）

    /// 鎖の並び・入切・バス・中身が変わったとき。persist() の入口から。
    func chainChanged(_ chain: [ETChainNode]) {
        if !localChainReady {
            // 1 度でも来たら restore() は済んでいる。待たせていたものをここで片付ける。
            // persist() の最中なので、鎖の入れ替えは次の回へ回す。
            localChainReady = true
            Task { @MainActor [weak self] in self?.localChainDidBecomeReady() }
        }
        guard isRemote, task != nil, !applyingRemote else { return }
        sendChain(chain)
    }

    /// つまみが動いたとき。setValue / setValues / resetParams から。
    func paramsChanged(at index: Int) {
        guard isRemote, task != nil, !applyingRemote else { return }
        pendingParams.insert(index)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            if Task.isCancelled { return }
            self?.flushParams()
        }
    }

    /// 保存しない実行時の値を PC の同じ段へ渡す（Adaptive Prediction の Reset = resetToken）。
    /// 鎖の短い形に載らない値なので、つまみ用の paramsChanged には乗らない。PC の setParameters が受ける。
    func sendRuntimeParams(at index: Int, _ params: [String: Any]) {
        guard isRemote, task != nil, !applyingRemote, sentMap.indices.contains(index),
              let remote = sentMap[index] else { return }
        sendEdit(["op": "params", "index": remote, "params": params])
    }

    /// 全体のバイパス。NowPlaying が切り替えたものも来る（PoC なので区別しない）。
    func bypassChanged(_ on: Bool) {
        guard isRemote, task != nil, !applyingRemote else { return }
        sendEdit(["op": "bypass", "on": on])
    }

    private func localChainDidBecomeReady() {
        if pendingRestore {
            pendingRestore = false
            if !isRemote { restoreStash() }
        }
        if let hello = pendingHello {
            pendingHello = nil
            enterRemote(hello)
        }
    }

    // MARK: - 接続

    private func connect() {
        guard let address = ETRemoteAddress.parse(Preferences.shared.remoteAddress),
              let url = address.url else {
            status = .error("Invalid address")
            return
        }
        status = .connecting
        generation += 1
        let gen = generation
        let t = session.webSocketTask(with: url)
        // 既定は 1 MiB。PC の枠の上限（4 MB）に合わせる。irChunk は base64 で 700 KB 弱。
        t.maximumMessageSize = 4 * 1024 * 1024
        task = t
        t.resume()
        listen(t, generation: gen)
        // 開けない相手（居ない IP）も、つないだ後で黙った相手も、TCP が諦めるまで何も返らない。見回りで切る。
        startHeartbeat(t, generation: gen)

        // hello の返事（state）が PC の鎖。それを入れて編集を始める。
        // 送りの順は保たれる。open を待たずに積んでよい（URLSession が開いてから流す）。
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await self.request(ETRemoteHello.message(info: Bundle.main.infoDictionary),
                                           reply: "state", timeout: 20)
            guard gen == self.generation else { return }
            // 返事が来ない（開いたが EffeTune のリモートではない・止まっている）。Connecting のまま待たせない。
            guard let state else {
                self.lost(reason: "hello に返事が無い")
                return
            }
            self.status = .connected
            self.tokenRejected = false
            self.backoff = 1
            let info = ETRemoteHostInfo(state: state)
            self.host = info
            self.setLastHost(ETRemoteLastHost(info))
            self.serverTelemetry = info.supports("telemetry")
            self.serverOverlays = info.supports("overlays")
            self.enterRemote(state)
        }
    }

    private func disconnect() {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeat = nil
        flushTask?.cancel()
        flushTask = nil
        followTask?.cancel()
        followTask = nil
        syncTask?.cancel()
        syncTask = nil
        presetMirrorTask?.cancel()
        presetMirrorTask = nil
        irSyncTask?.cancel()
        irSyncTask = nil
        irSink = nil
        irSyncBusy = false
        irSyncAgain = false
        irKnownPC = nil
        irKnownLocal = nil
        irFailed.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        sentForm = nil
        sentMap = []
        pendingParams.removeAll()
        pendingFollow = nil
        pendingHello = nil
        ours.removeAll()
        inFlight.removeAll()
        chainInFlight.removeAll()
        resyncWanted = false
        progress = nil
        // 接続ごと消えたので PC へは送らない（送れない）。映していた段は手元の枠へ戻す。
        // 退避を戻す（leaveRemote）より先に外す。戻した鎖で refreshMirrored が走らないように。
        host = nil
        serverTelemetry = false
        serverOverlays = false
        telemetryWanted = false
        telemetrySeq = nil
        chainSink = nil
        setMirrored([])
        // 待っている request を全部終わらせる（nil で返る）。
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { _ = waiter(nil) }
        leaveRemote()
    }

    private func listen(_ t: URLSessionWebSocketTask, generation gen: Int) {
        Task { @MainActor [weak self] in
            while let self, gen == self.generation {
                do {
                    let message = try await t.receive()
                    guard gen == self.generation else { return }
                    self.heartbeat?.heard(at: Date())
                    self.handle(message)
                } catch {
                    self.failed(t, generation: gen, error: error)
                    return
                }
            }
        }
    }

    private func failed(_ t: URLSessionWebSocketTask, generation gen: Int, error: Error) {
        guard gen == generation else { return }
        // 閉じ方のコードは、閉じ終えてから task に載る。
        let code = t.closeCode.rawValue
        disconnect()
        if code == 4401 {
            // トークンが違う。同じ字で繰り返しても通らないので、つなぎ直さない。
            // つなぎたくない側へ倒す（控えは残す。Scan QR Code で読み直すか Forget）。
            transition { $0.rejected() }
            status = .error("Wrong token")
            log.notice("remote: 4401 トークンが違う")
            return
        }
        log.notice("remote: 切れた code=\(code) \(error.localizedDescription, privacy: .public)")
        status = .error("Can't connect")
        scheduleReconnect()
    }

    /// 応答が途絶えた・hello に返事が無い。ソケットは開いたままかもしれないが、もう話せないので切ってつなぎ直す。
    private func lost(reason: String) {
        disconnect()
        log.notice("remote: 応答が無い \(reason, privacy: .public)")
        status = .error("Can't connect")
        scheduleReconnect()
    }

    // MARK: 見回り

    private func startHeartbeat(_ t: URLSessionWebSocketTask, generation gen: Int) {
        heartbeat = ETRemoteHeartbeat(now: Date())
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ETRemoteHeartbeat.interval * 1_000_000_000))
                guard let self, !Task.isCancelled, gen == self.generation, var beat = self.heartbeat else { return }
                let action = beat.tick(at: Date())
                self.heartbeat = beat
                switch action {
                case .ping: self.ping(t, generation: gen)
                case .dead:
                    self.lost(reason: "見回りに \(Int(ETRemoteHeartbeat.deadline)) 秒返事が無い")
                    return
                }
            }
        }
    }

    /// PC（ws）は ping に自動で pong を返す。返ってきたら聞こえたことにする。失敗は receive 側が拾う。
    private func ping(_ t: URLSessionWebSocketTask, generation gen: Int) {
        t.sendPing { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                self.heartbeat?.heard(at: Date())
            }
        }
    }

    /// 1, 2, 4 … 15 秒。Disconnect するまで続ける。つながったら 1 秒へ戻す。
    private func scheduleReconnect() {
        guard intent.wantsConnection else { return }
        let delay = backoff
        backoff = min(backoff * 2, 15)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            self?.connect()
        }
    }

    // MARK: - 退避と、PC の鎖の編集

    /// hello の返事が来た。手元の鎖を退避して PC の鎖を入れる。
    private func enterRemote(_ state: [String: Any]) {
        let dsp = EffeTuneDSP.shared
        // restore() の前に入れ替えると、後から restore() が手元の鎖を並べ直す。済むまで待つ。
        // ready は prepare() の中で restore() の直前に立つ（同じ回で続けて走る）ので、立っていれば済んでいる。
        guard dsp.ready else {
            pendingHello = state
            return
        }
        guard !isRemote else { return }
        // 前の起動の退避が残っている。先に戻して消してから退避し直す。
        if pendingRestore {
            pendingRestore = false
            restoreStash()
        }
        let form = dsp.remoteStashForm()
        guard let data = try? JSONSerialization.data(withJSONObject: form, options: [.sortedKeys]) else {
            log.error("remote: 鎖を退避できない")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.stashKey)
        UserDefaults.standard.set(dsp.bypass, forKey: Self.stashBypassKey)
        // 出力補正は手元の出力先の話なので、PC の鎖を編集している間は外す。
        // **isRemote を立てる前に呼ぶ。**外すときの publish → persist() → chainChanged が
        // isRemote を見て手元の鎖を PC へ送らないように。
        OutputCorrection.shared.setRemote(true)
        // 先に立てる。入れ替えの persist() が端末へ書かないように。
        isRemote = true
        adopt(state, rebuild: true)
        let gen = generation
        syncTask = Task { @MainActor [weak self] in
            await self?.syncAll(generation: gen)
        }
        watchLocalIRs()
        updateTelemetry()
    }

    /// 切った・切れた。退避した鎖を戻す。
    private func leaveRemote() {
        guard isRemote else { return }
        applyingRemote = true
        restoreStash()
        applyingRemote = false
        isRemote = false
        // 編集中に iCloud から降りてきた鎖は、adoptSeededChain が isRemote で素通りしている。
        // 戻した手元の鎖が既定（Level Meter 1 本）のままならここで入れる。入れないと、次の setRemote(false) の
        // persist() が既定の鎖を pipeline.last と iCloud へ書き、降りてきたばかりの鎖を消す
        // （降りてきた時点で pipeline.last が埋まり hasSaved が真なので、shouldPersist では止まらない）。
        // 手元の鎖が既定でなければ（isDefaultChain が偽）、降りてきた鎖が無ければ（loadLast が空）何もしない。
        EffeTuneDSP.shared.adoptSeededChain()
        // いまの出力先の補正を戻す。isRemote を下ろした後なので、入れ直しの persist() は PC へ送らない。
        OutputCorrection.shared.setRemote(false)
    }

    /// 退避した鎖を画面へ戻して、退避を消す。いまの鎖と同じなら作り直さない。
    private func restoreStash() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.stashKey) else { return }
        let dsp = EffeTuneDSP.shared
        if let json = try? JSONSerialization.jsonObject(with: data) {
            let items = PipelineStore.parse(json, catalog: ETCatalog)
            let now = try? JSONSerialization.data(withJSONObject: dsp.remoteStashForm(),
                                                  options: [.sortedKeys])
            if now != data {
                dsp.replaceChain(with: items)
                // 手元の鎖の開閉は、編集中は書いていないので前のまま残っている。
                let open = PipelineStore.loadExpanded().filter { dsp.chain.indices.contains($0) }
                dsp.expanded = Set(open.map { dsp.chain[$0].id })
            }
        }
        if defaults.object(forKey: Self.stashBypassKey) != nil {
            let bypass = defaults.bool(forKey: Self.stashBypassKey)
            if dsp.bypass != bypass { dsp.bypass = bypass }
        }
        defaults.removeObject(forKey: Self.stashKey)
        defaults.removeObject(forKey: Self.stashBypassKey)
    }

    /// PC の state を画面へ入れる。
    ///
    /// rebuild が偽（PC で起きた変更を追うとき）は、形が同じなら値だけ当てて段を作り直さない
    /// （ETRemoteFollow.sameShape）。形が違えば入れ替えて、開いていた位置を開き直す。
    private func adopt(_ state: [String: Any], rebuild: Bool) {
        let dsp = EffeTuneDSP.shared
        let loaded = items(from: state["pipeline"])
        let current = dsp.chain.map { PipelineStore.Loaded($0) }
        let incoming = ETRemoteProjection.project(loaded, host: host).pipeline
        let same = !rebuild && ETRemotePresetSync.canonical(incoming)
            == ETRemotePresetSync.canonical(ETRemoteProjection.project(current, host: host).pipeline)

        // 前の鎖の番号で積んだ params は、入れた後の鎖では別の段を指しうる。
        flushTask?.cancel()
        flushTask = nil
        pendingParams.removeAll()

        applyingRemote = true
        if !same {
            if !rebuild && ETRemoteFollow.sameShape(current, loaded) {
                for i in loaded.indices where loaded[i].values != current[i].values {
                    dsp.setValues(loaded[i].values, at: i)
                }
            } else {
                let open = rebuild ? [] : dsp.chain.indices.filter { dsp.expanded.contains(dsp.chain[$0].id) }
                dsp.replaceChain(with: loaded)
                if !open.isEmpty {
                    dsp.expanded = Set(open.filter { dsp.chain.indices.contains($0) }.map { dsp.chain[$0].id })
                }
            }
        }
        if let bypass = state["masterBypass"] as? Bool, dsp.bypass != bypass {
            dsp.bypass = bypass
        }
        applyingRemote = false
        // いま入れた鎖は PC と同じなので、送ったことにして控えを合わせる。
        let projected = ETRemoteProjection.project(dsp.chain, host: host)
        sentForm = projected.pipeline
        sentMap = projected.remoteIndex
        refreshMirrored()
    }

    /// PC で起きた変更。150 ms まとめて入れる。手元のコマンドの返事を待っているあいだは入れない。
    private func follow(_ state: [String: Any]) {
        pendingFollow = state
        guard followTask == nil else { return }
        followTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            self.followTask = nil
            guard self.isRemote, let state = self.pendingFollow else { return }
            self.pendingFollow = nil
            // 待つあいだに手元が動いた。この state はその前の形かもしれない。済んでから取り直す。
            guard !self.busy else {
                self.resyncWanted = true
                return
            }
            self.adopt(state, rebuild: false)
        }
    }

    /// 捨てた PC の変更を取り直す。手元の変更が全部 PC に着いてから（ack が出揃ってから）。
    private func resyncIfSettled() {
        guard resyncWanted, isRemote, !busy else { return }
        resyncWanted = false
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await self.request(["op": "get"], reply: "state", timeout: 10)
            guard gen == self.generation, self.isRemote, let state else { return }
            self.follow(state)
        }
    }

    // MARK: - 送る

    /// 1 通送る。返事を待つなら waiter を渡す。送れなければ nil。
    @discardableResult
    private func send(_ message: [String: Any], waiter: Waiter? = nil) -> Int? {
        guard let t = task else { return nil }
        seq += 1
        let n = seq
        var m = message
        m["seq"] = n
        guard let data = try? JSONSerialization.data(withJSONObject: m),
              let text = String(data: data, encoding: .utf8) else { return nil }
        if let waiter { waiters[n] = waiter }
        let log = self.log
        t.send(.string(text)) { error in
            // 送れなかったときは receive 側も失敗して、つなぎ直しに入る。ここは記録だけ。
            if let error { log.notice("remote: 送れない \(error.localizedDescription, privacy: .public)") }
        }
        return n
    }

    /// 鎖を変えるコマンド。自分の結果の state を見分けるために seq を控える。
    @discardableResult
    private func sendEdit(_ message: [String: Any]) -> Int? {
        guard let n = send(message) else { return nil }
        ours.insert(n)
        // ack が落ちたものは 2 秒で見なくなる（waitingForAck）。ここで捨てて溜めない。
        inFlight = inFlight.filter { $0.value.timeIntervalSinceNow > -2 }
        inFlight[n] = Date()
        if ours.count > 4096 {
            let floor = n - 2048
            ours = ours.filter { $0 > floor }
        }
        return n
    }

    /// 返事を待つ。reply が "ack" なら ok の ack を、ほかは同じ seq のその op を返す。
    /// ok:false の ack・切れた・時間切れは nil。
    private func request(_ message: [String: Any], reply: String,
                         timeout seconds: Double = 30) async -> [String: Any]? {
        await withCheckedContinuation { (c: CheckedContinuation<[String: Any]?, Never>) in
            var finished = false
            let finish: ([String: Any]?) -> Void = { result in
                guard !finished else { return }
                finished = true
                c.resume(returning: result)
            }
            let n = send(message) { m in
                guard let m else { finish(nil); return true }
                let op = m["op"] as? String
                if op == "ack" {
                    if m["ok"] as? Bool == false { finish(nil); return true }
                    if reply == "ack" { finish(m); return true }
                    return false
                }
                if op == reply { finish(m); return true }
                return false
            }
            guard let n else { finish(nil); return }
            armTimeout(n, seconds: seconds)
        }
    }

    private func armTimeout(_ n: Int, seconds: Double) {
        let gen = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, gen == self.generation,
                  let waiter = self.waiters.removeValue(forKey: n) else { return }
            self.log.notice("remote: 返事が来ない seq=\(n)")
            _ = waiter(nil)
        }
    }

    private func sendChain(_ chain: [ETChainNode]) {
        let projected = ETRemoteProjection.project(chain, host: host)
        sentMap = projected.remoteIndex
        // 外部の段を足し引きすると、PC の番号の無い段が変わる。
        refreshMirrored()
        if let sent = sentForm, (sent as NSArray).isEqual(to: projected.pipeline) { return }
        sentForm = projected.pipeline
        if let n = sendEdit(["op": "chain", "pipeline": projected.pipeline]) {
            chainInFlight = chainInFlight.filter { $0.value.timeIntervalSinceNow > -2 }
            chainInFlight[n] = Date()
        }
    }

    private func flushParams() {
        flushTask = nil
        let chain = EffeTuneDSP.shared.chain
        let pending = pendingParams.sorted()
        pendingParams.removeAll()
        // 並びが変わって、まだ鎖を送っていない。鎖のほうが新しい値ごと送るので、ここは捨てる。
        guard chain.count == sentMap.count else { return }
        for index in pending {
            guard chain.indices.contains(index), let remote = sentMap[index],
                  let params = ETRemoteProjection.params(for: chain[index]) else { continue }
            sendEdit(["op": "params", "index": remote, "params": params])
            // 後から来る persist() の鎖と食い違わないよう、送ったぶんを控えへ写す。
            if sentForm?.indices.contains(remote) == true,
               let entry = ETRemoteProjection.entry(for: PipelineStore.Loaded(chain[index])) {
                sentForm?[remote] = entry
            }
        }
    }

    // MARK: - 受ける

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d):   data = d
        @unknown default:    return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String else { return }
        let n = object["seq"] as? Int

        if op == "ack", let n {
            chainInFlight.removeValue(forKey: n)
            if inFlight.removeValue(forKey: n) != nil { resyncIfSettled() }
            if object["ok"] as? Bool == false {
                let why = object["error"] as? String ?? ""
                log.notice("remote: 拒否 seq=\(n) \(why, privacy: .public)")
            }
        }
        // 待っている返事なら待ち手へ。
        if let n, let waiter = waiters[n] {
            if waiter(object) { waiters.removeValue(forKey: n) }
            return
        }
        if op == "telemetry" {
            receiveTelemetry(object)
            return
        }
        if op == "presetsChanged" {
            presetsChangedOnPC()
            return
        }
        if op == "irsChanged" {
            irsChangedOnPC()
            return
        }
        guard op == "state", isRemote else { return }
        guard ETRemoteStateFilter.follows(origin: object["origin"] as? String, seq: n, ours: ours) else { return }
        // 手元のコマンドが PC に着く前の形かもしれない。着いた後の state（自分の seq）は上で捨てる。
        // 捨てた分は、ack が出揃ったところで get で取り直す（resyncIfSettled）。
        guard !busy else {
            resyncWanted = true
            return
        }
        follow(object)
    }

    // MARK: - PC のアナライザの測定値

    /// Mirror Analyzers の入切が変わった（Preferences の didSet）。
    func telemetryPreferenceChanged() {
        updateTelemetry()
    }

    /// 前に出た・背景に回った。PipelineView の scenePhase から
    /// （.background だけを背景とする。ETDisplayPump を止める条件と同じ）。
    func setAppActive(_ on: Bool) {
        guard appActive != on else { return }
        appActive = on
        // 前に戻った。背景のあいだに PC が消えていたら、次の見回りを待たずに確かめ始める。
        if on, let t = task { ping(t, generation: generation) }
        updateTelemetry()
    }

    /// 受けるかを決め直し、変わったら PC へ送る。受けるあいだは鎖の組み直しを見張る。
    private func updateTelemetry() {
        let want = isRemote && serverTelemetry && Preferences.shared.remoteMirrorAnalyzers && appActive
        if want != telemetryWanted {
            telemetryWanted = want
            sendTelemetry(want)
        }
        if want {
            if chainSink == nil {
                // $chain は書き換わる前に流れる。書き換わった後の鎖で決め直すため、一度メインへ回す。
                // 探り（重ね表示の tap）は publish() で作るので $chain より後になりうる。探りの足し引きも見る。
                let dsp = EffeTuneDSP.shared
                chainSink = dsp.$chain.map { _ in () }
                    .merge(with: dsp.$probeRevision.map { _ in () })
                    .sink { [weak self] _ in
                        Task { @MainActor [weak self] in self?.refreshMirrored() }
                    }
            }
            refreshMirrored()
        } else {
            chainSink = nil
            setMirrored([])
        }
    }

    private func sendTelemetry(_ on: Bool) {
        var message: [String: Any] = ["op": "telemetry", "on": on, "fps": Self.telemetryFPS]
        // PEQ の重ね表示の前後も受ける。古い PC は overlays を知らないので送らない。
        if on && serverOverlays { message["overlays"] = true }
        let n = send(message) { [weak self] reply in
            guard let reply else { return true }
            guard reply["op"] as? String == "ack" else { return false }
            if reply["ok"] as? Bool == false {
                self?.telemetryRejected(seq: reply["seq"] as? Int)
            }
            return true
        }
        telemetrySeq = n
        if let n { armTimeout(n, seconds: 10) }
    }

    /// 断られた。切ったものとして扱う（次に入切が変われば送り直す）。
    private func telemetryRejected(seq n: Int?) {
        guard let n, n == telemetrySeq, telemetryWanted else { return }
        log.notice("remote: telemetry を断られた seq=\(n)")
        telemetryWanted = false
        chainSink = nil
        setMirrored([])
    }

    /// PC の番号が付いている Analyzer の段を映す。外部の段（PC へ渡らない）は番号が無い。
    /// PC が重ね表示を送れるなら、PEQ の探りの tap も映す（ETRemoteOverlayGate はここに入った tap だけ描く）。
    private func refreshMirrored() {
        guard telemetryWanted, isRemote else {
            setMirrored([])
            return
        }
        let chain = EffeTuneDSP.shared.chain
        var taps = Set<UInt32>()
        for i in chain.indices where chain[i].spec.isAnalyzer && chain[i].tapId != 0
            && sentMap.indices.contains(i) && sentMap[i] != nil {
            taps.insert(chain[i].tapId)
        }
        if serverOverlays {
            for i in chain.indices where sentMap.indices.contains(i) && sentMap[i] != nil {
                let t = overlayTaps(at: i)
                if let before = t.before { taps.insert(before) }
                if let after = t.after { taps.insert(after) }
            }
        }
        setMirrored(taps)
    }

    /// 手元の番号 i の段が重ね表示の枠を受ける tap。
    private func overlayTaps(at i: Int) -> ETRemoteTelemetry.OverlayTaps {
        let dsp = EffeTuneDSP.shared
        guard dsp.chain.indices.contains(i) else { return ETRemoteTelemetry.OverlayTaps() }
        return ETRemoteTelemetry.overlayTaps(dsp.chain[i], probes: Self.probeTuple(dsp.probeTaps(at: i)))
    }

    private static func probeTuple(_ t: EffeTuneDSP.ProbeTaps?) -> (before: UInt32, after: UInt32)? {
        t.map { (before: $0.before, after: $0.after) }
    }

    private func setMirrored(_ taps: Set<UInt32>) {
        if mirroredTaps != taps { mirroredTaps = taps }
        Telemetry.shared.setMirrored(taps)
    }

    /// PC の枠を手元の段へ付け替えて差し込む。
    ///
    /// **手元の鎖の変更（chain）が PC に着く前は捨てる。**PC の番号と手元の番号が食い違いうる。
    /// つまみ（params）の ack 待ちでは捨てない。番号は動かないうえ、つまみを動かしながら
    /// スペアナを見るのがこの機能の使いどころで、busy で捨てると動かしているあいだ図が止まる。
    /// **名前も比べる。**PC で鎖が変わってから手元が追う（follow の 150 ms）までは、
    /// 同じ番号に別の段がいる。同じ種類のアナライザ 2 本の入れ替えだけは 1 回ぶん取り違えうる（PoC では受ける）。
    /// 重ね表示の枠（role 付き）は、その段の探りの tap（FIR PEQ は after だけ段の tapId）へ差し込む。
    /// 振り分けは ETRemoteTelemetry.route（段の本数の門 = flushParams と同じ、名前の照合も中）。
    private func receiveTelemetry(_ message: [String: Any]) {
        guard telemetryWanted, isRemote, !chainSettling else { return }
        let entries = ETRemoteTelemetry.parse(message)
        guard !entries.isEmpty, let sent = sentForm else { return }
        let dsp = EffeTuneDSP.shared
        let frames = ETRemoteTelemetry.route(entries, chain: dsp.chain, sentMap: sentMap, sent: sent,
                                             mirrored: mirroredTaps) { Self.probeTuple(dsp.probeTaps(at: $0)) }
        if !frames.isEmpty { Telemetry.shared.inject(frames) }
    }

    /// ショート形式の配列を段の並びへ。読めない値は寄せ、知らない段は落ちる（ETShareLink.parse）。
    private func items(from pipeline: Any?) -> [PipelineStore.Loaded] {
        guard let list = pipeline as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: list),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return ETShareLink.parse(text, catalog: ETCatalog)
    }

    // MARK: - プリセット（PC の写し・PC への足し込み）と IR の足し合わせ

    /// 取れた PC のプリセット。
    private struct PCPresets {
        /// PC の名前 → 段（手元で読めたもの）。
        var items: [String: [PipelineStore.Loaded]] = [:]
        /// 一覧には在ったが取れなかった（切れた・時間切れ・断られた）。写しの今ある分は消さない。
        var unreadable: Set<String> = []
        /// 取れたが手元の効果で 1 段も読めなかった。写しには入れない。
        var unrepresentable: Set<String> = []

        /// 中身が分からない PC の名前。同じ名前で送って上書きしないよう、PC に在る扱いにする。
        var opaque: Set<String> { unreadable.union(unrepresentable) }
    }

    /// 中身が分からない PC のプリセットの canonical の代わり（どの手元の中身とも違う）。
    private static let opaqueCanon = "\u{0}opaque"

    private func remoteAlive(_ gen: Int) -> Bool {
        gen == generation && isRemote && !Task.isCancelled
    }

    /// PC のプリセットの写しのフォルダ。決まらなければ空。
    private func presetMirrorFolder() -> String {
        ETRemotePresetMirror.folderName(hostName: host?.hostName, address: Preferences.shared.remoteAddress)
    }

    /// listPresets → getPreset で全部取る。**一覧が取れなければ nil**（写しを消さないため。空の一覧とは別）。
    private func fetchPCPresets(generation gen: Int) async -> PCPresets? {
        guard let list = await request(["op": "listPresets"], reply: "presets"),
              let names = list["names"] as? [String] else { return nil }
        var result = PCPresets()
        for name in names {
            guard remoteAlive(gen) else { return nil }
            guard let reply = await request(["op": "getPreset", "name": name], reply: "preset") else {
                result.unreadable.insert(name)
                continue
            }
            let loaded = items(from: reply["pipeline"])
            if loaded.isEmpty {
                result.unrepresentable.insert(name)
            } else {
                result.items[name] = loaded
            }
        }
        return remoteAlive(gen) ? result : nil
    }

    /// PC のプリセットを取って、ホスト名のフォルダを丸ごとその写しにする。取れたものを返す（取れなければ nil）。
    /// 取得の途中で別の取得が先に入れ替えていたら、古いほうは入れ替えずに取れたものだけ返す。
    private func fetchAndMirrorPresets(generation gen: Int) async -> PCPresets? {
        mirrorTicket += 1
        let ticket = mirrorTicket
        guard let pc = await fetchPCPresets(generation: gen) else { return nil }
        let base = presetMirrorFolder()
        if ticket > mirroredTicket, !base.isEmpty {
            mirroredTicket = ticket
            var forms: [String: [[String: Any]]] = [:]
            for (name, loaded) in pc.items { forms[name] = PipelineStore.shortForm(loaded) }
            // 同じ名前の人のフォルダが在れば `名前 2` へ入る（PresetStoreCore.mirrorTarget）。
            let changed = PresetStore.shared.mirrorFolder(base, incoming: forms, unreadable: pc.unreadable)
            if changed.written > 0 || changed.deleted > 0 {
                log.notice("remote: プリセットの写し \(changed.folder, privacy: .public) +\(changed.written)/-\(changed.deleted)")
            }
        }
        return pc
    }

    /// PC が presetsChanged を送ってきた（hello の sync: 1 を受けた PC だけ）。少し待って写し直す。
    private func presetsChangedOnPC() {
        guard isRemote, ETRemotePresetMirror.isLive(host) else { return }
        presetMirrorTask?.cancel()
        let gen = generation
        presetMirrorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.remoteAlive(gen) else { return }
            _ = await self.fetchAndMirrorPresets(generation: gen)
        }
    }

    private func syncAll(generation gen: Int) async {
        func alive() -> Bool { remoteAlive(gen) }
        progress = "Syncing"
        defer { if gen == generation { progress = nil } }

        // --- プリセット ---
        // PC → EffectDeck は写し（ホスト名のフォルダ）。EffectDeck → PC は足すだけ。
        let store = PresetStore.shared
        var pcCanon: [String: String] = [:]
        var pcRead = false
        if let pc = await fetchAndMirrorPresets(generation: gen) {
            pcRead = true
            for (name, loaded) in pc.items {
                // 手元の保存と同じ整え方の名前で比べる。整えると空になる名前は受けない。
                guard let key = store.savedName(for: name) else { continue }
                pcCanon[key] = ETRemotePresetSync.canonical(ETRemoteProjection.project(loaded, host: host).pipeline)
            }
            for name in pc.opaque {
                if let key = store.savedName(for: name) { pcCanon[key] = Self.opaqueCanon }
            }
        }
        guard alive() else { return }
        var localItems: [String: [PipelineStore.Loaded]] = [:]
        var localCanon: [String: String] = [:]
        var blocked: Set<String> = []
        for name in store.names {
            // PC の写しのフォルダ（どの PC のものも）は送らない。名前でなく、写したことがあるかで見る。
            // 同じ名前の人のフォルダは人のものとして送る。
            if store.isRemoteFolder(ETUserPresetName.folder(name)) { continue }
            let loaded = store.load(name)
            guard !loaded.isEmpty else { continue }
            localItems[name] = loaded
            localCanon[name] = ETRemotePresetSync.canonical(ETRemoteProjection.project(loaded, host: host).pipeline)
            // 外部の段と、PC に無い効果を含むものは送らない（段を落とすと別のプリセットになる）。
            if loaded.contains(where: { !$0.externalID.isEmpty || host?.lacks($0.spec.name) == true }) {
                blocked.insert(name)
            }
        }
        // PC の一覧が取れなかったときは何も送らない（空の一覧と取り違えて全部送らない）。
        let toPC = pcRead ? ETRemotePresetSync.plan(pc: pcCanon, local: localCanon, localBlocked: blocked) : []

        // --- IR ---
        // 走っているあいだは、PC の irsChanged や手元の増加による足し合わせ直しを待たせる（終わったら見直す）。
        irSyncBusy = true
        defer { finishIRSync(generation: gen) }
        // PC の一覧が取れなかったときは何も足さない（空の一覧と取り違えて全部送らない）。
        // 見た一覧は覚えておく（ライブの足し合わせ直しは、これより増えた分だけ）。取れなければ nil のまま。
        var irPlan: (download: [String], upload: [String]) = ([], [])
        if let lists = await fetchIRLists(generation: gen) {
            irPlan = ETRemoteIRSync.plan(pc: lists.pc, local: lists.local)
            irKnownPC = Set(lists.pc)
            irKnownLocal = Set(lists.local)
        }
        guard alive() else { return }

        let total = toPC.count + irPlan.download.count + irPlan.upload.count
        var done = 0
        func step() {
            done += 1
            progress = "Syncing \(done)/\(total)"
        }
        if total > 0 { progress = "Syncing 0/\(total)" }

        for copy in toPC {
            guard alive() else { return }
            if let loaded = localItems[copy.source] {
                let pipeline = ETRemoteProjection.project(loaded, host: host).pipeline
                if await request(["op": "savePreset", "name": copy.target, "pipeline": pipeline],
                                 reply: "ack") == nil {
                    log.notice("remote: プリセットを PC へ置けない \(copy.target, privacy: .public)")
                }
            }
            step()
        }

        await applyIRPlan(irPlan, generation: gen, step: step)
        guard alive() else { return }
        log.notice("remote: 足し合わせ済み プリセット →\(toPC.count) IR +\(irPlan.download.count)/→\(irPlan.upload.count)")
    }

    /// PC の IR の一覧と、そのときの手元の一覧。PC の一覧が取れなければ nil（空と取り違えない）。
    private func fetchIRLists(generation gen: Int) async -> (pc: [String], local: [String])? {
        guard let list = await request(["op": "listIRs"], reply: "irs"),
              let entries = list["items"] as? [[String: Any]] else { return nil }
        guard remoteAlive(gen) else { return nil }
        return (entries.compactMap { $0["id"] as? String }, IRLibrary.shared.entries.map(\.id))
    }

    /// 取る・送るを順に 1 本ずつ。失敗した鍵は覚えておく（このつなぎの中では取り直さない）。
    /// 取れた鍵は手元の既知へ、送れた鍵は PC の既知へすぐ入れる（取り込みで手元が増えたのを
    /// 「手元で増えた」と取り違えない・あとで PC で消されても送り直さない）。
    private func applyIRPlan(_ plan: (download: [String], upload: [String]), generation gen: Int,
                             step: () -> Void) async {
        var fetched: Set<String> = []
        for id in plan.download {
            guard remoteAlive(gen) else { return }
            if await download(id) {
                fetched.insert(id)
                irKnownLocal?.insert(id)
            } else {
                irFailed.insert(id)
            }
            step()
        }
        // PC の鎖の IR Reverb が指していた素材が、いま手元に来た。来た鍵を指す段だけ入れ直す
        // （鳴っている最中に、ほかの IR の段まで組み直さない）。
        if !fetched.isEmpty, remoteAlive(gen) { EffeTuneDSP.shared.reloadAssets(ids: fetched) }
        for id in plan.upload {
            guard remoteAlive(gen) else { return }
            if await upload(id, generation: gen) {
                irKnownPC?.insert(id)
            } else {
                irFailed.insert(id)
            }
            step()
        }
    }

    /// IR の足し合わせが終わった。走っているあいだに頼まれていたら、見直す。
    private func finishIRSync(generation gen: Int) {
        guard gen == generation else { return }
        irSyncBusy = false
        if irSyncAgain {
            irSyncAgain = false
            if isRemote { scheduleIRSync() }
        }
    }

    // MARK: IR のライブ（つないでいるあいだ）

    /// 手元の IR の増減を見張る。$entries は書き換わる前に流れるので、一度メインへ回してから読む。
    private func watchLocalIRs() {
        irSink = IRLibrary.shared.$entries.dropFirst().map { _ in () }.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.localIRsChanged() }
        }
    }

    /// 手元の IR が変わった。増えたときだけ PC へ足す（消したことは伝えない）。
    /// 消した鍵は既知から抜く（あとで入れ直したら、また増えた分として送る）。
    private func localIRsChanged() {
        guard isRemote else { return }
        let current = IRLibrary.shared.entries.map(\.id)
        irKnownLocal?.formIntersection(current)
        guard ETRemoteIRSync.hasAdditions(known: irKnownLocal ?? [], current: current) else { return }
        scheduleIRSync()
    }

    /// PC が irsChanged を送ってきた（hello の sync: 1 を受けた PC だけ）。
    private func irsChangedOnPC() {
        guard isRemote, ETRemotePresetMirror.isLive(host) else { return }
        scheduleIRSync()
    }

    /// 少し待ってから足し合わせ直す。待っているあいだにまた来たら待ち直す（続けて入れても 1 回で済む）。
    /// 切れたら待ちは捨てる（disconnect）。走り出した足し合わせは世代で止まる（remoteAlive）。
    private func scheduleIRSync() {
        irSyncTask?.cancel()
        let gen = generation
        irSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: ETRemoteIRSync.liveDebounceNanoseconds)
            guard let self, self.remoteAlive(gen) else { return }
            self.irSyncTask = nil
            await self.syncIRsLive(generation: gen)
        }
    }

    /// IR だけ、PC と手元の差を足す（syncAll の IR と同じ決まり。消さない・上書きしない）。
    private func syncIRsLive(generation gen: Int) async {
        // つないだ直後の足し合わせ（プリセットも含む）が済むのを待つ。同じ IR を二重に取らない。
        if let first = syncTask { await first.value }
        guard remoteAlive(gen) else { return }
        guard !irSyncBusy else {
            irSyncAgain = true
            return
        }
        irSyncBusy = true
        defer { finishIRSync(generation: gen) }
        guard let lists = await fetchIRLists(generation: gen), remoteAlive(gen) else { return }
        // 前に見たときから増えた分だけ（片方で消したものを、もう片方から戻さない）。
        let plan = ETRemoteIRSync.livePlan(pc: lists.pc, local: lists.local,
                                           knownPC: irKnownPC, knownLocal: irKnownLocal, skip: irFailed)
        // 一覧を見た時点を既知にする。このあと手元で入れたものは既知に無いので、次の見直しで送る。
        irKnownPC = Set(lists.pc)
        irKnownLocal = Set(lists.local)
        if !plan.download.isEmpty || !plan.upload.isEmpty {
            let total = plan.download.count + plan.upload.count
            var done = 0
            progress = "Syncing 0/\(total)"
            defer { if gen == generation { progress = nil } }
            await applyIRPlan(plan, generation: gen) {
                done += 1
                progress = "Syncing \(done)/\(total)"
            }
            guard remoteAlive(gen) else { return }
            log.notice("remote: IR 足し合わせ直し +\(plan.download.count)/→\(plan.upload.count)")
        }
    }

    /// PC の IR を 1 本取って置き場へ入れる。**鍵が合わなければ入れない。**
    private func download(_ id: String) async -> Bool {
        guard let file = await fetchIR(id) else { return false }
        let name = ETRemoteIRSync.fileName(name: file.name, ext: file.ext)
        // 鍵の計算と一時ファイルはメインの外で。
        let temp: URL? = await Task.detached(priority: .utility) { () -> URL? in
            guard IRLibraryFiles.key(for: file.data) == id else { return nil }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("remote-ir-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(name)
                try file.data.write(to: url)
                return url
            } catch {
                return nil
            }
        }.value
        guard let temp else {
            log.notice("remote: IR の鍵が合わない \(id, privacy: .public)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
        // 取り込みは画面で選んだときと同じ口（音として開けないものはここで落ちる）。
        let imported = IRLibrary.shared.importFile(at: temp)
        if imported != id {
            log.notice("remote: IR を取り込めない \(id, privacy: .public)")
            return false
        }
        return true
    }

    /// getIR。塊を順に継いで、ack で閉じる。
    private func fetchIR(_ id: String) async -> (name: String, ext: String, data: Data)? {
        await withCheckedContinuation { (c: CheckedContinuation<(name: String, ext: String, data: Data)?, Never>) in
            var finished = false
            let finish: ((name: String, ext: String, data: Data)?) -> Void = { result in
                guard !finished else { return }
                finished = true
                c.resume(returning: result)
            }
            var assembly = ETRemoteIRSync.Assembly()
            var name = ""
            var ext = ""
            let n = send(["op": "getIR", "id": id]) { m in
                guard let m else { finish(nil); return true }
                switch m["op"] as? String {
                case "irChunk":
                    name = m["name"] as? String ?? name
                    ext = m["ext"] as? String ?? ext
                    // 読めない塊は順が飛んだのと同じ扱いにする（index -1）。
                    let chunk = (m["data"] as? String).flatMap { Data(base64Encoded: $0) }
                    assembly.add(index: chunk == nil ? -1 : (m["index"] as? Int ?? -1),
                                 total: m["total"] as? Int ?? 0, data: chunk ?? Data())
                    return false
                case "ack":
                    if m["ok"] as? Bool == true, assembly.isComplete {
                        finish((name: name, ext: ext, data: assembly.data))
                    } else {
                        finish(nil)
                    }
                    return true
                default:
                    return false
                }
            }
            guard let n else { finish(nil); return }
            armTimeout(n, seconds: 300)
        }
    }

    /// 手元の IR を 1 本 PC へ送る。塊ごとに ack を待つ（詰め込みすぎない）。
    @discardableResult
    private func upload(_ id: String, generation gen: Int) async -> Bool {
        guard let entry = IRLibrary.shared.entry(id: id) else { return false }
        let url = entry.url
        // 読むのと鍵の確かめはメインの外で。置き場のファイルが差し替えられていたら送らない。
        let data: Data? = await Task.detached(priority: .utility) { () -> Data? in
            guard let data = try? Data(contentsOf: url), IRLibraryFiles.key(for: data) == id else { return nil }
            return data
        }.value
        guard let data else {
            log.notice("remote: IR を読めない・鍵が合わない \(id, privacy: .public)")
            return false
        }
        // PC の枠の上限を超えるものは送っても断られる。
        guard ETRemoteIRSync.canUpload(bytes: data.count) else {
            log.notice("remote: IR が大きすぎて PC へ置けない \(id, privacy: .public) \(data.count)")
            return false
        }
        let name = (entry.name as NSString).deletingPathExtension
        let ext = url.pathExtension
        let ranges = ETRemoteIRSync.chunks(data.count)
        for (index, range) in ranges.enumerated() {
            // つなぎ直した先へ、前のつなぎの途中の塊を流さない。
            guard remoteAlive(gen), task != nil else { return false }
            let message: [String: Any] = [
                "op": "putIR", "id": id, "name": name, "ext": ext,
                "index": index, "total": ranges.count, "bytes": data.count,
                "data": data.subdata(in: range).base64EncodedString(),
            ]
            if await request(message, reply: "ack", timeout: 60) == nil {
                log.notice("remote: IR を PC へ置けない \(id, privacy: .public) \(index)/\(ranges.count)")
                return false
            }
        }
        return true
    }
}
