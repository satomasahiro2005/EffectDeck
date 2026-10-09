//  RemoteProtocol.swift
//  PC の EffeTune を LAN から操る PoC（remote-v1）の、通信に触らない部分。**Foundationだけ。**
//
//  RemoteMirror.swift（URLSession と画面）から出した。あちらは EffeTuneDSP と Preferences を
//  引くので単体テストに入れられない。こちらは判断だけを持つ（RemoteProtocolTests）:
//    - 手元の鎖を、上流（PC の EffeTune）が読める形へ写す。**写した段の番号の対応表も返す**
//    - 手元の 1 段のパラメータを、params メッセージの中身へ写す
//    - 画面で打たれた接続先の読み方（host:port/token・ws:// の URL）と、PC の QR のリンク
//    - v2: state の出どころ（origin / seq）で追うか捨てるか、プリセットと IR の足し合わせの決まり、
//      PC の変更を値だけで当てられるか（ETRemoteFollow）
//    - telemetry: PC のアナライザの枠を読み、手元の段の tapId に付け替える（ETRemoteTelemetry）
//    - つながっているか（ETRemoteStatus・ETRemoteIndicator）と、PC が生きているかの見回り（ETRemoteHeartbeat）
//
//  ---------------------------------------------------------------------------
//  **外部の段（AU / JSFX）は、符号化する前に振り分ける。**
//
//  ETShareLink.effeTuneForm は先に PipelineStore.shortForm を全段へ回すので、外部の段の
//  externalState が base64 になる（JSFX の @serialize は 16 MB まで来て、21 MB の文字列になる）。
//  そこで捨てるものを符号化するのは無駄で、つまみを動かすたびに走らせるには重い。
//  ここは外部の段を見た時点で、落とすか 0 dB の Volume に替えるかを決めて、符号化しない。
//  規則は effeTuneForm と同じ（同じバスの中の段は消す。バスを渡る段は入切とバスを残した
//  0 dB の Volume にする）。
//  ---------------------------------------------------------------------------
//
//  ---------------------------------------------------------------------------
//  **手元の段の番号と、PC へ送った段の番号はずれる。**
//
//  外部の段が落ちると PC の鎖のほうが短くなる。params メッセージは PC の鎖の番号で宛てるので、
//  写すときに「手元の i 番目 → PC の j 番目（落ちたら nil）」の表を一緒に作る。
//  表は鎖を送るたびに作り直す。params を送る側はその表で引く。
//  ---------------------------------------------------------------------------

import Foundation

enum ETRemoteProjection {

    /// 上流へ渡す鎖と、手元の番号から上流の番号への対応。
    struct Projected {
        /// PC へ送るショート形式（`[{"nm":"Volume","en":true,"vl":-3}, …]`）。
        var pipeline: [[String: Any]]
        /// `remoteIndex[手元の番号]` が PC の番号。落とした段は nil。
        var remoteIndex: [Int?]
    }

    /// 前に送った段の形から、新しい形で無くなった鍵。**`params` では鍵を消せない**（PC の setParameters は
    /// 渡された鍵だけを直す）ので、IR を外した（`ir`）・Room EQ の測定を消した（`ms0` / `mn0` など）・
    /// 図の見せ方や designer の材料が落ちた、というときは古い値が PC に残る。あれば呼び手は `params` でなく
    /// 鎖ごと送り直す。段の鍵（`nm` / `en` / バス / `ch` / 終端の印）は params の話ではないので数えない。
    static func removedKeys(sent: [String: Any]?, now: [String: Any]) -> [String] {
        guard let sent else { return [] }
        let structural: Set<String> = ["nm", "en", "ib", "ob", "ch", ETSection.rootResetKey]
        return sent.keys.filter { !structural.contains($0) && now[$0] == nil }.sorted()
    }

    static func project(_ chain: [ETChainNode], host: ETRemoteHostInfo? = nil) -> Projected {
        project(chain.map { PipelineStore.Loaded($0) }, host: host)
    }

    /// host を渡すと、**PC の EffeTune が持っていない効果の段も送らない**（番号の対応は nil）。
    /// PC は知らない効果を含む鎖を丸ごと断る（unknown effect）ので、送れば他の段まで届かない。
    /// host が nil のとき・PC が効果の一覧を出さない古い版のときは、何も落とさない。
    static func project(_ items: [PipelineStore.Loaded], host: ETRemoteHostInfo? = nil) -> Projected {
        var pipeline: [[String: Any]] = []
        var map: [Int?] = []
        for item in items {
            if item.externalID.isEmpty, host?.lacks(item.spec.name) == true {
                map.append(nil)
            } else if let entry = entry(for: item) {
                map.append(pipeline.count)
                pipeline.append(entry)
            } else {
                map.append(nil)
            }
        }
        return Projected(pipeline: pipeline, remoteIndex: map)
    }

    /// 1 段を上流の形へ。落とす段は nil。
    static func entry(for item: PipelineStore.Loaded) -> [String: Any]? {
        guard item.externalID.isEmpty else {
            // 同じバスの中なら、切ることは消すことと同じ。
            guard item.inputBus != item.outputBus else { return nil }
            // 切ってある段は音に何も足さないので、替えの段も切ったままにする。
            var o: [String: Any] = ["nm": "Volume", "en": item.enabled, "vl": 0.0]
            if item.inputBus != 0 { o["ib"] = Int(item.inputBus) }
            if item.outputBus != 0 { o["ob"] = Int(item.outputBus) }
            if let ch = ETChannel.channel(from: item.channelSpec) { o["ch"] = ch }
            return o
        }
        // 外部の段はここへ来ない。1 段だけ渡すので、ほかの段の状態は符号化されない。
        guard let entry = PipelineStore.shortForm([item]).first else { return nil }
        // 終端の印（rr）は上流に無い綴りなので外す。
        return PipelineStore.upstreamEntry(entry)
    }

    /// params メッセージの `params` に入れるもの。**段のショート形式から段の鍵を抜いたもの**
    /// （`nm` / `en` / バス / `ch` は入れない）。動かせるパラメータが無い段（Section・終端・外部）は nil。
    ///
    /// **float の値だけでなく、IR の鍵（`ir`）・図の見せ方・designer の材料（`pm` / `tp` など）も入れる。**
    /// params を送るたびに RemoteMirror は控えの鎖のその段を entry(for:) で書き換えるので、
    /// ここで材料を落とすと、材料だけ変わった段は後の persist() でも「もう送った」と見なされ、
    /// PC へ一度も届かない。
    static func params(for item: PipelineStore.Loaded) -> [String: Any]? {
        guard item.externalID.isEmpty, !item.isRootReset, !ETSection.isSection(item.spec),
              var o = PipelineStore.shortForm([item]).first else {
            return nil
        }
        for key in ["nm", "en", "ib", "ob", "ch", ETSection.rootResetKey] {
            o.removeValue(forKey: key)
        }
        return o.isEmpty ? nil : o
    }

    static func params(for node: ETChainNode) -> [String: Any]? {
        params(for: PipelineStore.Loaded(node))
    }
}

/// 画面で打たれた接続先。`host:port/token` が基本で、PC が QR とリンクに出す
/// `http://host:port/?t=token`（Web クライアントの URL）と、前の形の `ws://host:port/?t=token` も受ける。
struct ETRemoteAddress: Equatable {

    static let defaultPort = 47300

    let host: String
    let port: Int
    let token: String

    /// `ws://<host>:<port>/?t=<token>`。トークンは URLQueryItem に任せて符号化する。
    var url: URL? {
        var c = URLComponents()
        c.scheme = "ws"
        c.host = host
        c.port = port
        c.path = "/"
        c.queryItems = [URLQueryItem(name: "t", value: token)]
        return c.url
    }

    /// 読めなければ nil。空白は前後だけ落とす。
    ///
    /// 受ける形:
    ///   192.168.1.10:47300/ab12cd34
    ///   192.168.1.10/ab12cd34               （ポートは 47300）
    ///   ws://192.168.1.10:47300/?t=ab12cd34
    ///   ws://192.168.1.10:47300/ab12cd34
    ///   http://192.168.1.10:47300/?t=ab12cd34       （PC のリンク。/ か /remote.html。url は ws を作る）
    static func parse(_ text: String) -> ETRemoteAddress? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 完全な URL。scheme を見て、無ければ下の素の形へ回す。
        if let range = s.range(of: "://") {
            let scheme = s[s.startIndex..<range.lowerBound].lowercased()
            // wss と https は受けない。url は ws しか作らず、PC は暗号なしの http しか出さないので、
            // 受けると暗号なしへ黙って落ちる。
            guard scheme == "ws" || scheme == "http",
                  let c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
            let queryToken = c.queryItems?.first(where: { $0.name == "t" })?.value
            if scheme == "http" {
                // PC のリンクはトークンが t にある。行き先は / か /remote.html だけ（別の http の URL を受けない）。
                guard c.path.isEmpty || c.path == "/" || c.path == "/remote.html", let queryToken else { return nil }
                return make(host: host, port: c.port ?? defaultPort, token: queryToken)
            }
            let token = queryToken ?? c.path.split(separator: "/").last.map(String.init) ?? ""
            return make(host: host, port: c.port ?? defaultPort, token: token)
        }

        // 素の形。最初の `/` までが host[:port]、残りがトークン。
        let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let hostPort = String(parts[0])
        var token = parts.count > 1 ? String(parts[1]) : ""
        // `host:47300/?t=token` のように URL から scheme だけ抜いた貼り方も受ける。
        if token.hasPrefix("?t=") { token.removeFirst(3) }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var host = hostPort
        var port = defaultPort
        if let colon = hostPort.lastIndex(of: ":") {
            host = String(hostPort[hostPort.startIndex..<colon])
            guard let p = Int(hostPort[hostPort.index(after: colon)...]) else { return nil }
            port = p
        }
        return make(host: host, port: port, token: token)
    }

    private static func make(host: String, port: Int, token: String) -> ETRemoteAddress? {
        guard !host.isEmpty, (1...65535).contains(port), !token.isEmpty else { return nil }
        return ETRemoteAddress(host: host, port: port, token: token)
    }
}

// MARK: - v2（remote-v1 の足し分。"v" は 1 のまま）

extension ETRemoteAddress {

    /// Preferences.remoteAddress に書く字（`host:port/token`）。parse がそのまま読む。
    var text: String { "\(host):\(port)/\(token)" }

    /// PC が QR とリンクに出す接続先 `http://<IPv4>:47300/?t=<token>` を読む。
    /// **QR はクライアントの種類を問わず 1 つ**（2026-10-03 本人の決定。PC は何がつなぐかを知らない）。
    /// ブラウザならそのまま開き、EffectDeck は同じ host・port・t から ws:// を作る。
    /// 前の形の `ws://<IPv4>:47300/?t=<token>` も読む。
    /// http と ws 以外・t の無いもの・パスが / 以外のもの（http は /remote.html も）は nil（別の QR を受けない）。
    static func pairingLink(_ url: URL) -> ETRemoteAddress? {
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "http",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.path.isEmpty || c.path == "/" || (scheme == "http" && c.path == "/remote.html"),
              let t = c.queryItems?.first(where: { $0.name == "t" })?.value, !t.isEmpty else { return nil }
        return parse(url.absoluteString)
    }
}

/// state の push を手元へ入れるか（origin と seq）。
///
/// **"local" は PC の上で起きた変更**（PC の画面・取り消し・PC でのプリセット読み込み）なので追う。
/// **"remote" は誰かのコマンドの結果。**seq が自分の送ったものなら、手元はもうその形なので捨てる
/// （入れると、つまみを動かしている最中に 1 つ前の値へ引き戻される）。seq が無いか自分のものでなければ、
/// 同じ PC につないだ別の端末の変更なので追う。
/// origin が無いのは v1 の PC。どこから来たか分からないので、v1 のときと同じく読み捨てる。
enum ETRemoteStateFilter {
    static func follows(origin: String?, seq: Int?, ours: Set<Int>) -> Bool {
        switch origin {
        case "local":
            return true
        case "remote":
            guard let seq else { return true }
            return !ours.contains(seq)
        default:
            return false
        }
    }
}

/// EffectDeck → PC のプリセットの足し合わせ（つないだ瞬間に 1 回）。**消さない・上書きしない。**
/// PC → EffectDeck は足し合わせでなく、PC のホスト名のフォルダへの写し（ETRemotePresetMirror）。
///
/// 中身は canonical（ショート形式を鍵の順を固定した JSON）で比べる。両側とも同じ読み書き
/// （ETShareLink.parse → ETRemoteProjection.project）を通してから比べるので、
/// 数の表し方（0.1 と 0.10000000149）の違いでは「違う」にならない。
///
/// PC のプリセットにはフォルダが無いので、手元のフォルダの名前（`Rock/Heavy`）は PC では
/// そのまま 1 本の名前になる。名前が同じで中身が違えば、PC に `名前 (iPad)` で置く。空いていなければ
/// `名前 (iPad 2)` …。**何度つないでも増えない**ように、次の 2 つは送らない:
///   - PC に同じ名前・同じ中身が在る（付け足した名前のほうも含めて）
///   - 前に送った写し（`名前 (iPad)` が PC に在り、その中身が手元の `名前` と同じ）
enum ETRemotePresetSync {

    static let localTag = "iPad"
    /// 前の版が手元に作った `名前 (PC)`。もう作らないが、残っているものを PC へ送り返さないために読む。
    static let legacyPCTag = "PC"

    struct Copy: Equatable {
        /// 手元での名前。
        let source: String
        /// PC に置く名前。
        let target: String
    }

    static func canonical(_ pipeline: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: pipeline, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// `名前 (iPad)` / `名前 (iPad 3)` / `名前 (PC)` を（名前, タグ）へ分ける。付け足しが無ければ nil。
    static func split(_ name: String) -> (base: String, tag: String)? {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return nil }
        let inner = name[open.upperBound..<name.index(before: name.endIndex)]
        let words = inner.split(separator: " ")
        guard let first = words.first, [localTag, legacyPCTag].contains(String(first)),
              words.count <= 2 else { return nil }
        if words.count == 2 {
            guard let n = Int(words[1]), n >= 2 else { return nil }
        }
        return (String(name[name.startIndex..<open.lowerBound]), String(first))
    }

    /// PC へ送るもの。
    /// - Parameters:
    ///   - pc: PC のプリセット（手元の名前の整え方に寄せた名前 → canonical）
    ///   - local: 手元のプリセット（名前 → canonical）。**PC の写しのフォルダは入れない**（PC のものを返さない）
    ///   - localBlocked: PC へ送らない手元のプリセット（AU / JSFX の段を持つもの）
    static func plan(pc: [String: String], local: [String: String],
                     localBlocked: Set<String> = []) -> [Copy] {
        var copies: [Copy] = []
        var pcAfter = pc
        for name in local.keys.sorted() where !localBlocked.contains(name) {
            guard let content = local[name] else { continue }
            if let s = split(name), pc[s.base] == content { continue }
            if let target = place(name, content, in: &pcAfter) {
                copies.append(Copy(source: name, target: target))
            }
        }
        return copies
    }

    /// 置く名前。同じ中身がもう在れば nil。
    private static func place(_ name: String, _ content: String,
                              in existing: inout [String: String]) -> String? {
        var candidate = name
        var n = 1
        while let there = existing[candidate] {
            if there == content { return nil }
            candidate = n == 1 ? "\(name) (\(localTag))" : "\(name) (\(localTag) \(n))"
            n += 1
        }
        existing[candidate] = content
        return candidate
    }
}

/// PC → EffectDeck のプリセット。**PC のホスト名のフォルダを PC の写しにする。**
/// 中身は丸ごと入れ替える（そのフォルダの中だけ足す・上書き・消す。ほかのフォルダと直下には触らない）。
/// 入れ替えの本体は PresetStoreCore.mirrorFolder（PresetFolderMirror.plan）。ここはフォルダの名前だけ決める。
enum ETRemotePresetMirror {

    /// フォルダの名前の長さの上限（PC から来る字なので切っておく）。
    static let maxFolderName = 64

    /// フォルダの名前。PC のホスト名（state の host）、無ければつなぎ先の host。
    /// `/` と制御文字は落とし、長すぎれば切る（入れ子は作らない）。決まらなければ空（写さない）。
    /// これは元の名前で、同じ名前の人のフォルダが在れば実際は `名前 2` へ入る（PresetStoreCore.mirrorTarget）。
    static func folderName(hostName: String?, address: String) -> String {
        for candidate in [hostName, ETRemoteAddress.parse(address)?.host] {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: (candidate ?? "").unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            })
            let clean = ETUserPresetName.clean(String(String(scalars).prefix(maxFolderName)))
            if !clean.isEmpty { return clean }
        }
        return ""
    }

    /// PC が presetsChanged を送るのは hello に sync: 1 を載せた接続だけ。それを受けられる PC（sync1）か。
    static func isLive(_ info: ETRemoteHostInfo?) -> Bool {
        info?.supports("sync1") == true
    }
}

/// IR の受け渡し（listIRs / getIR / putIR）。鍵は IRLibraryFiles.key と同じ 24 桁。
enum ETRemoteIRSync {

    /// 1 回に送る生のバイト数（base64 にする前）。PC の枠の上限は 4 MB。
    static let chunkSize = 512 * 1024

    /// PC の枠の上限（IR 1 本）。これを超えるものは送っても断られるので、送らない。
    static let maxBytes = 64 * 1024 * 1024

    /// PC が irsChanged を送ってから、または手元の IR が増えてから、足し合わせ直すまで待つ時間。
    /// 続けて入れても（フォルダごとの取り込みなど）1 回で済ませる。
    static let liveDebounceNanoseconds: UInt64 = 1_000_000_000

    /// 取りに行く鍵と、送る鍵。どちらも並びを固定する。
    /// `skip` は、このつなぎの中ですでに失敗した鍵（鍵が合わない・音として開けない・PC が断った）。
    /// 変わるたびに同じものを取り直さないよう、ライブのときだけ渡す。
    static func plan(pc: [String], local: [String], skip: Set<String> = []) -> (download: [String], upload: [String]) {
        let p = Set(pc), l = Set(local)
        return (p.subtracting(l).subtracting(skip).sorted(), l.subtracting(p).subtracting(skip).sorted())
    }

    /// つないでいるあいだの足し合わせ直し。**前に見たときから増えた分だけ**を足す。
    /// `knownPC` は前に見た PC の一覧（と、そのあと送れた鍵）、`knownLocal` は前に見た手元の一覧
    /// （と、そのあと取れた鍵。手元で消した鍵は抜いておく）。
    /// 片方で消したものを、もう片方の写しから送り直す・取り直すと、消したことがすぐ打ち消される
    /// （PC で消した IR がつないでいるかぎり戻ってくる）。消したものはつなぎ直したとき
    /// （plan、足し合わせの決まりのまま）に戻る。nil は「まだ見ていない」で、その側は plan と同じに扱う。
    static func livePlan(pc: [String], local: [String], knownPC: Set<String>?, knownLocal: Set<String>?,
                         skip: Set<String>) -> (download: [String], upload: [String]) {
        let p = Set(pc), l = Set(local)
        var download = p.subtracting(l).subtracting(skip)
        var upload = l.subtracting(p).subtracting(skip)
        if let knownPC { download.subtract(knownPC) }
        if let knownLocal { upload.subtract(knownLocal) }
        return (download.sorted(), upload.sorted())
    }

    /// 手元の IR が増えたか。`known` は前の足し合わせの終わりに手元にあった鍵。
    /// 減っただけ（消した・足し合わせで自分が取り込んだ分）なら足し合わせ直さない。
    /// **消すことは PC へ伝えない**（足すだけ）ので、減ったことは見ない。
    static func hasAdditions(known: Set<String>, current: [String]) -> Bool {
        current.contains { !known.contains($0) }
    }

    /// PC へ送ってよい大きさか（1 バイト以上、枠の上限まで）。
    static func canUpload(bytes: Int) -> Bool {
        bytes > 0 && bytes <= maxBytes
    }

    /// `bytes` を size ごとに切った範囲。0 バイトでも空の塊を 1 つ返す（total が 0 にならない）。
    static func chunks(_ bytes: Int, size: Int = chunkSize) -> [Range<Int>] {
        guard bytes > 0 else { return [0..<0] }
        return stride(from: 0, to: bytes, by: size).map { $0..<min($0 + size, bytes) }
    }

    /// 受け取った IR を置き場へ入れるときのファイル名。IRLibrary.importFile は元の名前から
    /// 見出しと拡張子を取るので、ここで `名前.拡張子` にしておく。名前に拡張子が付いていても二重にしない。
    static func fileName(name: String, ext: String) -> String {
        let cleanExt = String(ext.filter { $0.isLetter || $0.isNumber })
        var base = String(name.map { "/\\:".contains($0) ? "-" : $0 })
        if !cleanExt.isEmpty, base.lowercased().hasSuffix("." + cleanExt.lowercased()) {
            base = String(base.dropLast(cleanExt.count + 1))
        }
        if base.trimmingCharacters(in: .whitespaces).isEmpty { base = "IR" }
        return cleanExt.isEmpty ? base : "\(base).\(cleanExt)"
    }

    /// 塊を順に継ぐ。**順が飛んだら失敗にする**（1 本の接続で順に来る決まり）。
    struct Assembly {
        private(set) var total = 0
        private(set) var next = 0
        private(set) var data = Data()
        private(set) var failed = false

        var isComplete: Bool { !failed && total > 0 && next == total }

        mutating func add(index: Int, total: Int, data chunk: Data) {
            guard !failed else { return }
            guard total > 0, index == next, self.total == 0 || self.total == total else {
                failed = true
                return
            }
            self.total = total
            data.append(chunk)
            next += 1
        }
    }
}

/// PC で起きた変更を手元の鎖へ入れる形。
enum ETRemoteFollow {
    /// 並び・入切・バス・材料・見せ方が同じで、違いうるのは値（values）だけか。
    /// そうなら段を作り直さず値だけ当てる（カードの開閉も音の途切れも起きない）。
    static func sameShape(_ a: [PipelineStore.Loaded], _ b: [PipelineStore.Loaded]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.spec.type == y.spec.type, x.enabled == y.enabled,
                  x.inputBus == y.inputBus, x.outputBus == y.outputBus,
                  x.channelSpec == y.channelSpec, x.sectionName == y.sectionName,
                  x.irId == y.irId, x.display == y.display, x.design == y.design,
                  x.isRootReset == y.isRootReset,
                  x.externalID.isEmpty, y.externalID.isEmpty,
                  x.values.count == y.values.count else { return false }
        }
        return true
    }
}

/// PC のアナライザの測定値（remote-v1 の telemetry）。**枠は両側で 1 バイトも違わない**ので、
/// PC が送ってきた 16 バイトのヘッダつきの枠をそのまま ETFrame へ戻す。
/// 違うのは tapId だけ（PC は plugin.id、手元は node.tapId）で、差し込む前に手元の値へ書き換える。
///
/// push の形（PC の remote-control-host.cjs の flushTelemetry）:
///     {"op":"telemetry","frames":[{"index":3,"nm":"Spectrum Analyzer","type":4,"data":"<base64>"}, …]}
/// `index` は PC の鎖の番号（params の index と同じ）。`type` はヘッダの写しで、見るのはヘッダのほう。
/// `data` は 16 + payloadBytes バイトちょうど（4 の倍数への切り上げは無い）。
///
/// **PEQ の重ね表示**（features の "overlays"、subscribe に `"overlays":true`）は同じ push に
/// `role` 付きで混ざる: `{"index":2,"nm":"5Band PEQ","type":4,"role":"after","data":…}`。
/// 中身は手元の探りと同じ Spectrum Analyzer の v1 枠（points 12・2049 本・平滑前の dB）。
/// before は段に入る音、after は段から出た音。手元の探りの tap（EffeTuneDSP.probeTaps）へ差し込む。
enum ETRemoteTelemetry {

    struct Entry {
        /// PC の鎖の番号。
        let index: Int
        /// PC の段の名前（state.pipeline[index].nm と同じ）。
        let nm: String
        /// frame.tapId は PC の plugin.id のまま。差し込む前に frame(_:tap:) で書き換える。
        let frame: ETFrame
        /// 重ね表示の枠なら "before" か "after"。アナライザの枠は nil。
        let role: String?
    }

    /// 重ね表示の枠を受ける手元の tap。nil はその向きの行き先が無い。
    struct OverlayTaps: Equatable {
        var before: UInt32?
        var after: UInt32?
    }

    /// 手元で探り（段の前後の Spectrum Analyzer）を付ける PEQ。EffeTuneDSP.probedTypes と同じ。
    static let overlayProbedTypes: Set<String> = ["FiveBandPEQPlugin", "FifteenBandPEQPlugin"]
    /// FIR PEQ は探りを持たず、図は段の tapId を読む。入口が無いので after だけ受ける。
    static let overlayFIRType = "FiveBandFIRPEQPlugin"

    /// 読めない項目は落とす（番号・名前が無い・base64 が解けない・長さがヘッダと合わない）。
    static func parse(_ message: [String: Any]) -> [Entry] {
        guard let list = message["frames"] as? [[String: Any]] else { return [] }
        var out: [Entry] = []
        out.reserveCapacity(list.count)
        for item in list {
            guard let index = item["index"] as? Int,
                  let nm = item["nm"] as? String,
                  let text = item["data"] as? String,
                  let data = Data(base64Encoded: text) else { continue }
            // role は無いか "before" / "after"。知らない向きは落とす（別の段へ差し込まない）。
            let role = item["role"] as? String
            if item["role"] != nil, role != "before", role != "after" { continue }
            let bytes = [UInt8](data)
            guard bytes.count >= 16, bytes.count == 16 + Int(u16(bytes, 12)) else { continue }
            let frame = ETFrame(type: u16(bytes, 0), version: u16(bytes, 2), tapId: u32(bytes, 4),
                                sequence: u32(bytes, 8), dropped: u16(bytes, 14) & 1 != 0,
                                payload: Array(bytes[16...]))
            out.append(Entry(index: index, nm: nm, frame: frame, role: role))
        }
        return out
    }

    /// 手元の段が重ね表示の枠を受ける tap。probes は EffeTuneDSP.probeTaps（無ければ nil）。
    /// PEQ でも探りが無い（バスを分けている・枠が足りない）なら受けない。手元でも図に重ならない段。
    static func overlayTaps(_ node: ETChainNode,
                            probes: (before: UInt32, after: UInt32)?) -> OverlayTaps {
        if overlayProbedTypes.contains(node.spec.type), let probes {
            return OverlayTaps(before: probes.before, after: probes.after)
        }
        if node.spec.type == overlayFIRType, node.tapId != 0 {
            return OverlayTaps(before: nil, after: node.tapId)
        }
        return OverlayTaps(before: nil, after: nil)
    }

    /// PC の枠を手元の段の tap へ付け替える。行き先が無い・映していない（mirrored に無い）枠は落とす。
    ///
    /// - sentMap: 手元の番号 → PC の番号（RemoteMirror の sentMap）。鎖と本数が違えば全部落とす
    ///   （手元で段を足し引きして、まだ PC へ鎖を送っていない）。
    /// - sent: PC へ送った鎖の形。**名前を比べる。**PC で鎖が変わってから手元が追うまでは、
    ///   同じ番号に別の段がいる。
    /// - probes: 手元の番号 → 探りの tap。
    static func route(_ entries: [Entry], chain: [ETChainNode], sentMap: [Int?],
                      sent: [[String: Any]], mirrored: Set<UInt32>,
                      probes: (Int) -> (before: UInt32, after: UInt32)?) -> [ETFrame] {
        guard chain.count == sentMap.count else { return [] }
        let local = inverse(sentMap)
        var frames: [ETFrame] = []
        for entry in entries {
            guard let i = local[entry.index], chain.indices.contains(i),
                  sent.indices.contains(entry.index),
                  sent[entry.index]["nm"] as? String == entry.nm else { continue }
            let node = chain[i]
            if let role = entry.role {
                // 重ね表示は Spectrum Analyzer の枠だけ。
                guard entry.frame.type == 4 else { continue }
                let taps = overlayTaps(node, probes: probes(i))
                guard let target = role == "after" ? taps.after : taps.before,
                      mirrored.contains(target) else { continue }
                frames.append(frame(entry, tap: target))
                continue
            }
            guard node.spec.isAnalyzer, mirrored.contains(node.tapId) else { continue }
            frames.append(frame(entry, tap: node.tapId))
        }
        return frames
    }

    /// `remoteIndex[手元の番号]` = PC の番号（RemoteMirror の sentMap）を裏返す。PC の番号 → 手元の番号。
    static func inverse(_ remoteIndex: [Int?]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (local, remote) in remoteIndex.enumerated() {
            if let remote { out[remote] = local }
        }
        return out
    }

    /// tapId だけ手元の段の値に替えた枠。
    static func frame(_ entry: Entry, tap: UInt32) -> ETFrame {
        let f = entry.frame
        return ETFrame(type: f.type, version: f.version, tapId: tap, sequence: f.sequence,
                       dropped: f.dropped, payload: f.payload)
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

/// つないだ PC の EffeTune（hello の返事の state）。版の見せ方と、PC が持つ機能の判定。
///
/// **何ができるかは features で決める。版の数字は比べない**（表示だけに使う）。
/// 古い PC は appName / build を出さない。その場合の名前は "EffeTune"、版は state の "app"。
///
/// **効果の有無は effects（PC が読み込める効果の名前）で決める。**出さない古い PC は nil で、
/// 何も断らない。dsp は PC の dsp/ の版。これも出さない PC がある（nil）。
struct ETRemoteHostInfo: Equatable {
    var name: String
    var version: String?
    var build: String?
    var features: Set<String>
    var dsp: String?
    var effects: Set<String>?
    /// PC のホスト名（state の host。sync1 の PC だけ。os.hostname()）。プリセットのフォルダの名前になる。
    var hostName: String?

    init(state: [String: Any]) {
        name = Self.text(state["appName"]) ?? "EffeTune"
        version = Self.text(state["app"])
        build = Self.text(state["build"])
        features = Set(state["features"] as? [String] ?? [])
        dsp = Self.text(state["dsp"])
        effects = (state["effects"] as? [String]).map(Set.init)
        hostName = Self.text(state["host"])
    }

    private static func text(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// "2.11.0 (db06db0e)" / "2.11.0" / "Unknown"
    var label: String {
        switch (version, build) {
        case let (v?, b?): return "\(v) (\(b))"
        case let (v?, nil): return v
        case let (nil, b?): return "(\(b))"
        case (nil, nil): return "Unknown"
        }
    }

    func supports(_ feature: String) -> Bool { features.contains(feature) }

    /// この効果を PC が持っていない。**一覧を出さない PC では偽**（分からないものは断らない）。
    func lacks(_ effect: String) -> Bool {
        guard let effects else { return false }
        return !effects.contains(effect)
    }

    /// 機能が無いときの一言。版が分からなければ版を省く。
    var unsupportedText: String {
        guard let version else { return "Not supported by \(name) on the PC" }
        return "Not supported by \(name) \(version) on the PC"
    }

    /// 手元が PC へ送れる効果の名前（カタログと Section）。
    static var localEffectNames: [String] { ETCatalog.map(\.name) + [ETSection.name] }

    /// 手元の EffeTune と PC の食い違い。無ければ nil。**表示だけ**（何ができるかは features と effects で決める）。
    ///
    /// - dsp を出す PC（dsp/ の版を出す EffectDeck 向けの版）: dsp の版の差と、効果の名前の差。
    /// - dsp を出さない PC（公式の EffeTune 2.13.0 以降は appName / app / features / effects だけ）:
    ///   アプリ全体の版（state の app）が、積んでいる上流の版（localApp）と違えば、それ。
    ///   上流の版が分からない（localApp が空）・PC が app を出さないときは比べない。
    /// - effects を出す PC: 効果の名前の差。出さない古い PC は効果を比べない。
    func mismatch(localDSP: String, localEffects: [String],
                  localApp: String = ETUpstreamAppVersion) -> ETRemoteMismatch? {
        let dspDiffers = dsp.map { $0 != localDSP } ?? false
        let appDiffers = dsp == nil && !localApp.isEmpty && (version.map { $0 != localApp } ?? false)
        var missingOnHost: [String] = []
        var missingHere: [String] = []
        if let effects {
            missingOnHost = Set(localEffects).subtracting(effects).sorted()
            missingHere = effects.subtracting(localEffects).sorted()
        }
        guard dspDiffers || appDiffers || !missingOnHost.isEmpty || !missingHere.isEmpty else { return nil }
        return ETRemoteMismatch(hostDSP: dsp, localDSP: localDSP,
                                missingOnHost: missingOnHost, missingHere: missingHere,
                                hostApp: appDiffers ? version : nil, localApp: appDiffers ? localApp : nil)
    }
}

/// 手元と PC の EffeTune の食い違い。Remote Control の設定に 1 行で出す。
struct ETRemoteMismatch: Equatable {
    var hostDSP: String?
    var localDSP: String
    /// 手元にあって PC に無い効果の名前（昇順）。
    var missingOnHost: [String]
    /// PC にあって手元に無い効果の名前（昇順）。
    var missingHere: [String]
    /// dsp の版を出さない PC（公式の EffeTune）のアプリ全体の版と、こちらが積んでいる上流の版。食い違うときだけ入る。
    var hostApp: String? = nil
    var localApp: String? = nil

    var dspDiffers: Bool { hostDSP != nil && hostDSP != localDSP }
    var appDiffers: Bool { hostApp != nil && localApp != nil && hostApp != localApp }

    /// "DSP 0.11.0 on the PC, 0.12.0 here" / "EffeTune 2.14.0 on the PC, 2.13.0 here" / "Effects differ"
    /// dsp の版を出す PC はそれを先に、出さない PC はアプリ全体の版を、どちらも同じなら効果の差を言う。
    var headline: String {
        if let hostDSP, dspDiffers { return "DSP \(hostDSP) on the PC, \(localDSP) here" }
        if let hostApp, let localApp, appDiffers { return "EffeTune \(hostApp) on the PC, \(localApp) here" }
        return "Effects differ"
    }

    /// "Not on the PC: Analog Meter, Rhythm Analyzer"。無ければ nil。
    var missingOnHostText: String? {
        missingOnHost.isEmpty ? nil : "Not on the PC: " + missingOnHost.joined(separator: ", ")
    }

    /// "Not here: Foo"。無ければ nil。
    var missingHereText: String? {
        missingHere.isEmpty ? nil : "Not here: " + missingHere.joined(separator: ", ")
    }
}

/// つないだ直後に送る hello。自分の名前と版を添える（PC の Remote Control の窓に出る）。
/// 版は Info.plist から。引数にしてあるのは、テストが plist を差し替えて呼べるように。
enum ETRemoteHello {
    /// dsp は積んでいる EffeTune の dsp/ の版（ETUpstreamVersion）。PC が食い違いを出せるように添える。
    static func message(info: [String: Any]?, dsp: String = ETUpstreamVersion) -> [String: Any] {
        // sync: 1 は「プリセットが変わったら presetsChanged を送って」の申し込み（remote-v1 の sync1）。
        // 古い PC は知らない字として読み捨てる。
        var m: [String: Any] = ["op": "hello", "v": 1, "app": "EffectDeck", "sync": 1]
        if !dsp.isEmpty { m["dsp"] = dsp }
        if let v = info?["CFBundleShortVersionString"] as? String, !v.isEmpty { m["version"] = v }
        if let b = info?["CFBundleVersion"] as? String, !b.isEmpty { m["build"] = b }
        return m
    }
}

// MARK: - つなぐ・切るの状態（入切を持たない）

/// 「つなぎたいか」と「つなぎ先を控えているか」だけで決まる状態。**入切のスイッチは無い。**
/// QR を読む（pair）か Connect でつなぎ、Disconnect で切る。切るまでは起動のたびにつなぎ直す。
///
/// 画面（layout）と起動（launch）と遷移を、通信や Preferences から離して 1 か所に置く。
/// RemoteMirror は Preferences から値を読んでこの遷移を通し、書き戻すだけ。
///
/// 遷移:
///   pair        控えを書き換え、すぐつなぐ。4401 の印は消す
///   connect     控えがあって 4401 でないときだけ、つなぐ
///   disconnect  つなぎたくない。控えは残す（Connect で戻れる）
///   forget      つなぎたくない。控えも消す
///   rejected    PC がトークンを断った（4401）。つなぎ直しても通らないので、つなぎたくない側へ倒す
///   launch      起動。控えが無いのに「つなぎたい」が残っていたら落とす
struct ETRemoteIntent: Equatable {

    var hasAddress: Bool
    var wantsConnection: Bool
    /// 最後のつなぎで 4401 を受けた。控えは残すが、同じ字ではつなげない。
    var tokenRejected = false

    /// シートの形。
    enum Layout: Equatable {
        /// 一度も組んでいない（控えが無い）。Scan QR Code だけ。
        case unpaired
        /// つなぎたい（つないでいる最中・つながった・つなぎ直しを待っている）。
        /// PC（読むだけ）・Options・Disconnect。
        case active
        /// 控えはあるが、つなぎたくない。PC・Connect・Scan QR Code・Forget。
        case idle
    }

    var layout: Layout {
        guard hasAddress else { return .unpaired }
        return wantsConnection ? .active : .idle
    }

    /// Connect を出せるか（idle で、同じ字でつなげる）。
    var canConnect: Bool { layout == .idle && !tokenRejected }

    mutating func pair() {
        hasAddress = true
        wantsConnection = true
        tokenRejected = false
    }

    /// つなげたか。
    @discardableResult
    mutating func connect() -> Bool {
        guard hasAddress, !tokenRejected else { return false }
        wantsConnection = true
        return true
    }

    mutating func disconnect() {
        wantsConnection = false
    }

    mutating func forget() {
        hasAddress = false
        wantsConnection = false
        tokenRejected = false
    }

    mutating func rejected() {
        wantsConnection = false
        tokenRejected = true
    }

    mutating func launch() {
        wantsConnection = wantsConnection && hasAddress
    }
}

// MARK: - つながっているか（控えとは別）

/// つなぎの「いま」。**Connected は hello の返事（state）を受けてから、切れる・応答が途絶えるまでだけ。**
/// ETRemoteIntent（控えと「つなぎたいか」）は起動をまたいで残るが、これは残さない（起動は disconnected から）。
enum ETRemoteStatus: Equatable {
    case disconnected
    /// ソケットを開いた・hello の返事を待っている・つなぎ直しを待っている
    case connecting
    /// hello の返事を受けた。応答が途絶えたら（ETRemoteHeartbeat）error へ落ちる
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disconnected:   return "Disconnected"
        case .connecting:     return "Connecting"
        case .connected:      return "Connected"
        case .error(let why): return "Error: \(why)"
        }
    }

    var isLive: Bool { self == .connected }
}

/// ツールバーのアイコンの見た目。**塗るのは本当につながっているあいだだけ。**
/// 前は控えの「つなぎたい」で塗っていた。それは起動をまたいで残るので、PC の EffeTune が
/// 居なくても起動した瞬間から青く、つながっているように見えた。
enum ETRemoteIndicator: Equatable {
    /// つなぎたくない。塗らない・脈を打たない
    case off
    /// つなぎたいが、つながっていない（つなぎ中・つなぎ直し待ち・応答なし）。脈を打つ。塗らない
    case connecting
    /// つながっている。青く塗る
    case live

    init(wantsConnection: Bool, status: ETRemoteStatus) {
        if status.isLive {
            self = .live
        } else {
            self = wantsConnection ? .connecting : .off
        }
    }
}

/// つないでいるあいだ、PC が生きているかを見る。
///
/// URLSession の WebSocket は、黙って消えた相手（PC が眠った・Wi-Fi が切り替わった・電源を落とした）を
/// 自分では見つけない。受け待ちは TCP が諦めるまで返らず、そのあいだ Connected のまま PC の鎖を出し続ける。
/// 開けない相手（居ない IP）も TCP が諦めるまで Connecting のまま。
/// そこで interval ごとに ping を送り、deadline のあいだ何も聞こえなければ切れたとみなす。
/// PC（Node の ws）は ping に自動で pong を返す。受けたメッセージも全部「聞こえた」に入れる。
///
/// **見回りそのものが止まっていたら数えない。**背景で止められていたあいだは聞こえなくて当たり前なので、
/// 戻ったら聞き直す（そこから deadline）。
struct ETRemoteHeartbeat: Equatable {
    static let interval: TimeInterval = 5
    /// IR の大きな枠（4 MiB）を送っているあいだは pong がその後ろに並ぶ。遅い Wi-Fi でも届く長さ。
    static let deadline: TimeInterval = 20

    enum Action: Equatable {
        case ping
        case dead
    }

    private(set) var lastHeard: Date
    private(set) var lastTick: Date

    init(now: Date) {
        lastHeard = now
        lastTick = now
    }

    mutating func heard(at now: Date) {
        if now > lastHeard { lastHeard = now }
    }

    /// interval ごとに呼ぶ。
    mutating func tick(at now: Date) -> Action {
        defer { lastTick = now }
        if now.timeIntervalSince(lastTick) > Self.deadline {
            // 見回りが止まっていた（背景）。止まっていたあいだは数えずに聞き直す。
            lastHeard = now
            return .ping
        }
        return now.timeIntervalSince(lastHeard) > Self.deadline ? .dead : .ping
    }
}

/// 最後につないだ PC の EffeTune の名前と版。切断中の Connect のボタンにホスト名を出す。
struct ETRemoteLastHost: Codable, Equatable {
    var name: String
    var label: String
    /// PC のホスト名（state の host）。切断中の Connect のボタンに出す。古い記録には無い。
    var hostName: String?

    init(name: String, label: String, hostName: String? = nil) {
        self.name = name
        self.label = label
        self.hostName = hostName
    }

    init(_ info: ETRemoteHostInfo) {
        self.init(name: info.name, label: info.label, hostName: info.hostName)
    }
}
