//  ETChainText.swift
//  貼られた字から鎖を読む前の下ごしらえ。ChatGPTなどに組ませた鎖を受けるため（CHAIN.md）。
//
//  **ここはFoundationだけ。**PipelineStoreにもETShareLinkにもEffeTuneDSPにも触らない。
//  判断は全部ここに置き、Tests/Unit/ChainTextTests.swiftが実機なしで見張る
//  （ETParamCodingを切り出したのと同じ理由）。
//
//  やることは2つ:
//    1. 字からJSONを取り出す（json(from:)）。共有リンク・base64・JSONそのものに加えて、
//       返事ごとコピーしたもの（```jsonの囲いが残るものも外れたものも）、base64urlや
//       改行の入ったbase64、末尾の=が無いものも読む
//    2. 読む前に直す（prepare）。名前の綴り、範囲の外の数、選択肢に無い値、知らない鍵、
//       バスの番号、JSFXの名前での指定。直したもの・落としたものはReportに残して、
//       取り込んだあとに1行で見せる（黙って直さない）
//
//  **範囲へ寄せるだけで、整数へは丸めない。**isIntegerは刻みが1以上かどうかで決めた
//  画面の都合で（gen_catalog.py）、上流の出荷時の鎖にも5Band PEQの101.47Hzのような
//  端数がある。丸めると同梱の鎖の音が変わる。
//
//  形式そのもの（ショート形式・ロング形式）はPipelineStore.swiftの頭を読むこと。

import Foundation

/// ```囲いの中身。
/// JSFXの貼り付け（ETJSFXHost.importText）と鎖の取り込み（ETChainText.extract）が同じものを使う。
enum ETCodeBlock {
    /// 最初の囲いの中身。囲いが無ければnil。
    /// **囲いは外す。**返事ごとコピーすると付いてくる（「Copy code」なら付かない）。
    static func first(in text: String) -> String? {
        all(in: text).first?.body
    }

    /// 囲いを前から順に全部。`info`は開きの行の残り（```jsonなら"json"）。
    /// 閉じが無ければ、最後の囲いは字の終わりまで。
    static func all(in text: String) -> [(info: String, body: String)] {
        var blocks: [(info: String, body: String)] = []
        var rest = text[...]
        while let open = rest.range(of: "```"),
              let lineEnd = rest[open.upperBound...].firstIndex(of: "\n") {
            // 開きの行の残り（```jsfxなど）は飛ばす。
            let info = rest[open.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces)
            let body = rest[rest.index(after: lineEnd)...]
            guard let close = body.range(of: "```") else {
                blocks.append((info, String(body)))
                break
            }
            blocks.append((info, String(body[..<close.lowerBound])))
            rest = body[close.upperBound...]
        }
        return blocks
    }
}

enum ETChainText {

    // MARK: - 控え

    /// 取り込むときに直したもの・落としたもの。空なら何も言わない。
    struct Report: Equatable {
        /// 鎖に置けなかった段。エフェクト名、JSFXなら"JSFX <名前>"。
        var notFound: [String] = []
        /// 読まなかった鍵と値。"Saturation.xx"。
        var ignored: [String] = []
        /// 範囲の端へ寄せた値。"Volume.vl"。
        var limited: [String] = []

        var isEmpty: Bool { notFound.isEmpty && ignored.isEmpty && limited.isEmpty }

        /// 画面に出す1行。"Not found: Tape Warmth. Ignored: Saturation.xx. Limited: Volume.vl."
        var message: String {
            let parts: [(String, [String])] = [("Not found", notFound),
                                               ("Ignored", ignored),
                                               ("Limited", limited)]
            return parts.filter { !$0.1.isEmpty }
                .map { "\($0.0): \(Report.list($0.1))." }
                .joined(separator: " ")
        }

        /// 1つの項目に並べるのは4つまで。長い一覧は1行に収まらず、読まれない。
        private static func list(_ items: [String]) -> String {
            let shown = items.prefix(4).joined(separator: ", ")
            return items.count > 4 ? "\(shown) and \(items.count - 4) more" : shown
        }

        /// 同じものは1度だけ（同じ段が2本あると同じ鍵が2度来る）。
        fileprivate mutating func add(_ item: String, to list: WritableKeyPath<Report, [String]>) {
            if !self[keyPath: list].contains(item) { self[keyPath: list].append(item) }
        }
    }

    // MARK: - JSFXを名前で引く

    /// JSFXの`desc:`の名前 → 鎖に置く鍵（`jsfx:<sha256>`）と一覧に出る名前。無ければnil。
    /// 取り込んである一覧はアプリ側（ETJSFXHost.chainResolver）が持つので、閉包で受ける。
    typealias JSFXResolver = (String) -> (id: String, name: String)?

    /// 一覧から引く閉包を作る。**綴りが同じものを先に、次に大文字小文字を無視して。**
    /// 同じ名前が2本あれば先に並んでいるほう（並べ方は渡す側が決める）。
    static func jsfxResolver(_ library: [(id: String, name: String)]) -> JSFXResolver {
        return { wanted in
            let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            if let hit = library.first(where: { $0.name == name }) { return hit }
            return library.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    // MARK: - 字からJSONを取り出す

    /// 共有リンク・base64・JSONそのもの・返事ごと、のどれでも受ける。読めなければnil。
    ///
    /// 順番はETShareLink.parseが元から見ていた順（リンク → base64 → JSON）のままで、
    /// 最後に返事の中から探す段を足した。**前の段で読めたものは前と同じに読む。**
    static func json(from text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 1. リンク
        if let json = linkJSON(trimmed) { return json }
        // 2. base64そのもの（`p=`の中身だけを貼ったとき）
        if let json = base64JSON(trimmed) { return json }
        // 3. JSONそのもの（「Copy code」で取ったもの）
        if let json = object(trimmed) { return json }
        // 4. 返事ごとコピーしたもの
        return extract(trimmed)
    }

    /// 返事ごとコピーしたものから鎖を探す。ChatGPTの「Copy」は囲いを残すことも外すこともある。
    ///   1. ```囲いの中身。`json`の名札が付いたものを先に、残りは前から
    ///   2. 左から順に`[`か`{`を探し、対になる閉じ括弧までを切り出して読めたもの
    ///   3. 文中のリンク（`?p=`）
    /// **鎖の形のものだけを取る**（辞書の配列か、`pipeline`を持つ辞書）。
    /// 文中の`[1]`のような注記や、同じ返事に載ったJSFXの`buf[0]`を鎖と取り違えないため。
    /// **囲いは全部見る。**先にJSFXやPythonの囲いがあると、括弧を試す数の上限
    /// （balancedSlice）に届いて鎖まで行き着かないことがある。
    static func extract(_ text: String) -> Any? {
        let blocks = ETCodeBlock.all(in: text)
        let tagged = blocks.filter { $0.info.lowercased() == "json" }
        for block in tagged + blocks.filter({ $0.info.lowercased() != "json" }) {
            let body = block.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let json = object(body) ?? linkJSON(body) ?? base64JSON(body), isChain(json) {
                return json
            }
        }
        if let json = balancedSlice(text) { return json }
        return embeddedLink(text)
    }

    /// base64のJSON。素のbase64に加えて、base64url（`-` `_`）、改行の入ったもの、
    /// 末尾の`=`が無いもの、`%2B`のまま貼られたものも読む。
    /// **書くほうは素のbase64のまま**（ETShareLink.url(for:)）。web版が素のbase64しか読まない。
    static func base64JSON(_ raw: String) -> Any? {
        var s = raw
        if s.contains("%"), let decoded = s.removingPercentEncoding { s = decoded }
        // 改行やタブは折り返しなので外す。空白はURLSearchParamsが`+`を読み替えたものかも
        // しれないので、先に`+`へ戻して試し、だめなら外して試す。
        let compact = String(s.filter { !$0.isWhitespace || $0 == " " })
        for candidate in [compact.replacingOccurrences(of: " ", with: "+"),
                          compact.replacingOccurrences(of: " ", with: "")] {
            if let json = decodeBase64(candidate) { return json }
        }
        return nil
    }

    private static let base64Alphabet = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    private static func decodeBase64(_ s: String) -> Any? {
        var body = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // `=`は末尾にしか来ない。一度外して、長さから数え直す。
        while body.hasSuffix("=") { body.removeLast() }
        guard !body.isEmpty, body.unicodeScalars.allSatisfy({ base64Alphabet.contains($0) }) else {
            return nil
        }
        switch body.count % 4 {
        case 1: return nil
        case 2: body += "=="
        case 3: body += "="
        default: break
        }
        guard let data = Data(base64Encoded: body) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// `?p=`の付いたリンク。httpで始まるものは、途中の改行や空白（折り返して貼られたもの）を
    /// 詰めてからも読む。URLComponentsは空白があると読まない。
    private static func linkJSON(_ text: String) -> Any? {
        var candidates = [text]
        let lower = text.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            candidates.append(String(text.filter { !$0.isWhitespace }))
        }
        for candidate in candidates {
            if let comps = URLComponents(string: candidate),
               let p = comps.queryItems?.first(where: { $0.name == "p" })?.value,
               let json = base64JSON(p) {
                return json
            }
        }
        return nil
    }

    /// 字そのものがJSONなら読む。
    private static func object(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func isChain(_ json: Any) -> Bool {
        if let list = json as? [Any] {
            return !list.isEmpty && list.allSatisfy { $0 is [String: Any] }
        }
        if let dict = json as? [String: Any] { return dict["pipeline"] is [Any] }
        return false
    }

    /// 左から`[`か`{`ごとに、対になる閉じ括弧までを読んでみる。
    /// 外側が鎖でなくても内側が鎖のことがあるので、次の開き括弧から続ける。
    /// **試す数に上限を置く。**長い記事を丸ごと貼られても固まらないように。
    private static func balancedSlice(_ text: String) -> Any? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count <= 1 << 20 else { return nil }
        var tried = 0
        var start = 0
        while start < scalars.count, tried < 200 {
            let c = scalars[start]
            if c == "[" || c == "{" {
                tried += 1
                if let end = matchingClose(scalars, from: start) {
                    var slice = String.UnicodeScalarView()
                    slice.append(contentsOf: scalars[start...end])
                    if let json = object(String(slice)), isChain(json) { return json }
                }
            }
            start += 1
        }
        return nil
    }

    /// `start`の括弧と対になる閉じ括弧の位置。JSONの文字列の中の括弧は数えない。
    private static func matchingClose(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        var expected: [Unicode.Scalar] = []
        var inString = false
        var escaped = false
        var i = start
        while i < s.count {
            let c = s[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "[" {
                expected.append("]")
            } else if c == "{" {
                expected.append("}")
            } else if c == "]" || c == "}" {
                guard expected.last == c else { return nil }
                expected.removeLast()
                if expected.isEmpty { return i }
            }
            i += 1
        }
        return nil
    }

    /// 文中のリンク（`https://effectdeck.nemut.ai/?p=…`）。文の終わりの句読点は外す。
    private static func embeddedLink(_ text: String) -> Any? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'()\[\]]+"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let link = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if let json = linkJSON(link), isChain(json) { return json }
        }
        return nil
    }

    // MARK: - 読む前に直す

    /// 鎖のJSONを、PipelineStore.parseへ渡す前に直す。形（ショート・ロング）は変えない。
    ///
    /// - 名前: 綴りが同じもの → 大文字小文字と空白を無視 → 型名（`Plugin`の有無とも）。
    ///   当たれば正しい綴りへ書き換える。当たらない段は外してnotFoundへ
    /// - 数: 範囲の端へ寄せてlimitedへ。見た目と違う数で持つもの（scaled）は、上限を超えた
    ///   正の数を見た目の数（HzやErrorの割合）と見て保存する数へ直してから寄せる
    /// - 選択肢: 同じ綴りか同じ数の選択肢へ。数でそれが無ければ添字と見る。
    ///   無い綴りや範囲の外の添字は鍵ごと外してignoredへ（既定が残る）
    /// - 決まった値しか取らない数（ETAllowedValues）: 外れた値は外してignoredへ
    /// - バス（ib / ob / inputBus / outputBus）: 0...4へ寄せる。エンジンは5以上が1本でも
    ///   あると鎖ごと拒む（engine.cpp:674-678）
    /// - チャンネル（ch / channel）: ETChannelが知らない綴りは外してignoredへ
    /// - 知らない鍵: 残したまま（decodeが読まないだけ）ignoredへ
    /// - `{"jsfx":"<desc:の名前>"}`: 引けたら外部の段の形（`external: "jsfx:<id>"`）へ
    ///   書き換える。PipelineStore.parseがそのまま読む。引けなければ外してnotFoundへ
    ///
    /// **範囲の中の値には触らない。**同梱の鎖と出荷時プリセットを全部通して、
    /// 値が何も変わらないことをChainTextTestsが見張る。
    static func prepare(_ json: Any, catalog: [ETEffect],
                        jsfx: JSFXResolver? = nil) -> (json: Any, report: Report) {
        var report = Report()
        let list: [Any]
        var root: [String: Any]? = nil
        if let a = json as? [Any] {
            list = a
        } else if let d = json as? [String: Any], let a = d["pipeline"] as? [Any] {
            list = a
            root = d
        } else {
            return (json, report)
        }

        let names = Names(catalog)
        var out: [[String: Any]] = []
        for (i, item) in list.enumerated() {
            guard let entry = item as? [String: Any] else {
                report.add("item \(i + 1)", to: \.ignored)
                continue
            }
            if let stage = prepareStage(entry, names: names, jsfx: jsfx, report: &report) {
                out.append(stage)
            }
        }
        if var root {
            root["pipeline"] = out
            return (root, report)
        }
        return (out, report)
    }

    /// 大文字小文字と空白を無視した綴り。名前を引くときに使う。
    static func fold(_ s: String) -> String {
        String(s.lowercased().filter { !$0.isWhitespace })
    }

    /// バスの番号の上限。RoutingViewの0..<5とエンジンのkBusCountに合わせる。
    static let busLimit = 4

    /// バスとチャンネルの鍵。**どちらの形でも両方の綴りを見る。**PipelineStore.parseは
    /// ショートでもロングでも`entry["inputBus"] ?? entry["ib"]`のように両方を読む。
    private static let busKeys = ["inputBus", "ib", "outputBus", "ob"]
    private static let channelKeys = ["channel", "ch"]
    /// 段そのものが持つ鍵（PipelineStore.shortForm / longForm）。パラメータとは見ない。
    /// ショートとロングの綴りを両方入れる（busKeysと同じ理由）。
    private static let stageKeys: Set<String> = [
        "nm", "en", "enabled", "ib", "ob", "ch", "inputBus", "outputBus", "channel",
        "external", "externalInstance", "externalState",
    ]
    /// ロング形式の段の鍵。パラメータは`parameters`の中。ロングでは`name`が勝つので`nm`は読まれない。
    private static let longStageKeys: Set<String> =
        stageKeys.subtracting(["nm"]).union(["name", "parameters"])
    /// IR Reverbの素材の鍵。綴りはETIRLoader.presetKey（IRLoader.swiftはAVFoundationに触るので
    /// このファイルからは引けない）。PipelineStore.parseはどの段でも読む。
    /// PipelineForm.swiftも同じ理由でこれを引く。
    static let irKey = "ir"
    /// SFZ Note Player のバンクの鍵。綴りは上流のまま `sf`（plugins/others/sfz_note_player.js の getParameters）。
    /// 24 桁の小文字の 16 進。段の素材の鍵は ETChainNode.irId に載せ、どの綴りで書くかは型で決める（assetKey）。
    static let sfzKey = "sf"
    static let sfzType = "SFZNotePlayerPlugin"

    /// 段の素材の鍵（IR Reverb は `ir`、SFZ Note Player は `sf`）の綴り。
    static func assetKey(forType type: String) -> String {
        type == sfzType ? sfzKey : irKey
    }
    /// 上流が書くが音に効かないので、読まなくても言わない鍵。オブジェクト配列の行の中にも効く。
    /// - Modal Resonatorの`sr`は選択中のタブの添字（modal_resonator.js:30-32、
    ///   EffectPresetApply.matchingPresetIdの注記）
    /// - Multiband Compressorの`bands[].gr`はバンドごとの今の減衰量（メーターの値）。
    ///   上流の既定のバンドが持っていて、同梱の鎖（Processor/Fm Radio）にもそのまま載っている
    ///   （multiband_compressor.js:19-23）
    private static let quietKeys: [String: Set<String>] = [
        "ModalResonatorPlugin": ["sr"],
        "MultibandCompressorPlugin": ["gr"],
    ]
    /// どの型でも言わない鍵。Brickwall LimiterのgetParametersが`pluginType`を書き
    /// （brickwall_limiter.js:759）、上流のショート形式はid・type・enabledしか外さない
    /// （serialization-utils.jsのgetSerializablePluginStateShort）。EffeTuneの共有リンクに載ってくる。
    private static let quietEverywhere: Set<String> = ["pluginType"]
    /// ロング形式の`parameters`に上流が重ねて書く段の鍵。読むのは段のほう（PipelineStore.parse）。
    /// - `en`: Modal ResonatorのgetParametersが書く（modal_resonator.js:314-322）
    /// - `ib` `ob` `ch`: getSerializableParametersが段のバスとチャンネルを短い綴りで写す
    ///   （plugin-base.js:1117-1136）。段の`inputBus`などにも同じ値がある
    private static let longParameterStageKeys: Set<String> = ["en", "ib", "ob", "ch"]

    /// 保存する数が見た目の数と違うもの。印はgen_catalog.pyのCHAIN_SCALEDと同じ字。
    enum Scale: String {
        /// 周波数の自然対数（3.0 = 20Hz、6.91 = 1kHz）
        case lnHz = "ln(Hz)"
        /// 割合の10の指数（-6 = 10^-6）
        case pow10 = "10^x"
    }

    /// `型名.メンバ名` → Scale。**表で持つ。**ETParam.scaleはTilt EQしか持たない
    /// （Modal Resonatorの*Logは画面が生の数のまま見せている。EffectSpec.swiftの頭）。
    /// ChainTextTestsがchain/v<版>/effects.jsonの`scale`と突き合わせる。
    private static let scaled: [String: Scale] = [
        "TiltEQPlugin.pivotExponent": .lnHz,
        "ModalResonatorPlugin.frequencyLog": .lnHz,
        "ModalResonatorPlugin.lowPassLog": .lnHz,
        "ModalResonatorPlugin.highPassLog": .lnHz,
        "DigitalErrorEmulatorPlugin.bitErrorRateExponent": .pow10,
        "G726ADPCMSimulatorPlugin.radioBitErrorExponent": .pow10,
    ]

    static func scale(type: String, param: ETParam) -> Scale? {
        scaled[type + "." + param.name]
    }

    /// 名前からETEffectを引く表。
    private struct Names {
        let exact: [String: ETEffect]
        let loose: [String: ETEffect]

        init(_ catalog: [ETEffect]) {
            exact = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            var table: [String: ETEffect] = [:]
            // 表示名を先に入れる。型名が同じ綴りの別の表示名に場所を取られないように。
            for e in catalog where table[ETChainText.fold(e.name)] == nil {
                table[ETChainText.fold(e.name)] = e
            }
            for e in catalog {
                let bare = e.type.hasSuffix("Plugin") ? String(e.type.dropLast(6)) : e.type
                for t in [e.type, bare] where table[ETChainText.fold(t)] == nil {
                    table[ETChainText.fold(t)] = e
                }
            }
            loose = table
        }

        func find(_ name: String) -> ETEffect? {
            exact[name] ?? loose[ETChainText.fold(name)]
        }
    }

    private static func prepareStage(_ input: [String: Any], names: Names, jsfx: JSFXResolver?,
                                     report: inout Report) -> [String: Any]? {
        var entry = input
        let isLong = entry["name"] != nil
        let nameKey = isLong ? "name" : "nm"

        // JSFXをdesc:の名前で指したもの（CHAIN.md）。
        if let wanted = entry["jsfx"] as? String {
            return jsfxStage(entry, wanted: wanted, isLong: isLong, resolver: jsfx, report: &report)
        }

        let name = entry[nameKey] as? String ?? ""

        // 外から来た段（AU / JSFX）。EffectDeckどうしの共有リンクとバックアップに乗ってくる。
        // 鍵は取り込んだ側の一覧で引く（EffeTuneDSP.append）ので、ここではバスとチャンネルしか見ない。
        if let external = entry["external"] as? String, !external.isEmpty {
            clampBuses(&entry, label: name, report: &report)
            checkChannel(&entry, label: name, report: &report)
            return entry
        }

        // Section。カタログに載っていないので名前で拾う（PipelineStore.parseと同じ）。
        if fold(name) == fold(ETSection.name) {
            entry[nameKey] = ETSection.name
            let params = isLong ? (entry["parameters"] as? [String: Any] ?? [:]) : entry
            for key in params.keys.sorted() where key != ETSection.commentKey {
                if !isLong && stageKeys.contains(key) { continue }
                // 終端の印（EffectDeckどうしのリンクに乗ってくる）。どちらの形でも段の鍵に置く。
                if key == ETSection.rootResetKey && !isLong { continue }
                report.add("\(ETSection.name).\(key)", to: \.ignored)
            }
            if isLong {
                var stage = entry
                stage.removeValue(forKey: ETSection.rootResetKey)
                reportUnknownStageKeys(stage, label: ETSection.name, report: &report)
            }
            return entry
        }

        guard let spec = names.find(name) else {
            report.add(name.isEmpty ? "unnamed" : name, to: \.notFound)
            return nil
        }
        entry[nameKey] = spec.name
        clampBuses(&entry, label: spec.name, report: &report)
        checkChannel(&entry, label: spec.name, report: &report)

        if isLong {
            reportUnknownStageKeys(entry, label: spec.name, report: &report)
            if var params = entry["parameters"] as? [String: Any] {
                prepareParams(&params, spec: spec, skip: longParameterStageKeys, report: &report)
                entry["parameters"] = params
            }
        } else {
            prepareParams(&entry, spec: spec, skip: stageKeys, report: &report)
        }
        return entry
    }

    private static func reportUnknownStageKeys(_ entry: [String: Any], label: String,
                                               report: inout Report) {
        for key in entry.keys.sorted()
        where !longStageKeys.contains(key) && !quietEverywhere.contains(key) {
            report.add("\(label).\(key)", to: \.ignored)
        }
    }

    /// `{"jsfx":"<desc:の名前>"}`を、shortForm / longFormが外部の段に書くのと同じ鍵へ。
    /// externalInstanceは書かない（PipelineStore.parseが新しく振る）。状態も無いので
    /// スライダーはJSFXの既定から始まる。
    private static func jsfxStage(_ entry: [String: Any], wanted: String, isLong: Bool,
                                  resolver: JSFXResolver?, report: inout Report) -> [String: Any]? {
        let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hit = resolver?(name) else {
            report.add("JSFX \(name)", to: \.notFound)
            return nil
        }
        // 入切・バス・チャンネルは両方の綴りを持ち越す（PipelineStore.parseがどちらも読む）。
        let keep = ["en", "enabled"] + busKeys + channelKeys
        var stage: [String: Any] = ["external": hit.id]
        stage[isLong ? "name" : "nm"] = hit.name
        for key in keep {
            if let value = entry[key] { stage[key] = value }
        }
        clampBuses(&stage, label: hit.name, report: &report)
        checkChannel(&stage, label: hit.name, report: &report)
        let known = Set(keep + ["jsfx", "nm", "name"])
        for key in entry.keys.sorted() where !known.contains(key) {
            report.add("\(hit.name).\(key)", to: \.ignored)
        }
        return stage
    }

    /// チャンネルの綴り。大文字小文字だけ違う左右と全部（"left" "r" "all"）はETChannelの綴りへ直す。
    /// **ETChannelが知らない綴りは外してignoredへ。**PipelineStore.parseは黙ってStereoに落とす。
    /// nullと空の字は既定（Stereo）なので黙って通す。
    private static func checkChannel(_ entry: inout [String: Any], label: String,
                                     report: inout Report) {
        for key in channelKeys {
            guard let raw = entry[key], !(raw is NSNull) else { continue }
            if let s = raw as? String {
                if s.isEmpty || ETChannel.spec(from: s) != -1 { continue }
                let letters: [String: String] = ["a": "A", "all": "A", "l": "L", "left": "L",
                                                 "r": "R", "right": "R"]
                let folded = s.trimmingCharacters(in: .whitespaces).lowercased()
                if let fixed = letters[folded] {
                    entry[key] = fixed
                    continue
                }
            }
            entry.removeValue(forKey: key)
            report.add("\(label).\(key)", to: \.ignored)
        }
    }

    /// バスを0...busLimitへ。数でなければ外す（PipelineStore.parseは0と読む）。nullは既定なので黙って通す。
    private static func clampBuses(_ entry: inout [String: Any], label: String, report: inout Report) {
        for key in busKeys {
            guard let raw = entry[key], !(raw is NSNull) else { continue }
            guard let v = number(raw), v.isFinite else {
                entry.removeValue(forKey: key)
                report.add("\(label).\(key)", to: \.ignored)
                continue
            }
            let fixed = min(max(v.rounded(), 0), Double(busLimit))
            if fixed != v {
                entry[key] = Int(fixed)
                report.add("\(label).\(key)", to: \.limited)
            }
        }
    }

    private static func prepareParams(_ params: inout [String: Any], spec: ETEffect,
                                      skip: Set<String>, report: inout Report) {
        // decodeが見る場所と同じ数え方で、鍵 → ETParamの表を作る（ETParamCoding.decode）。
        var scalars: [String: ETParam] = [:]            // "vl"、添字付きの"f0"
        var lists: [String: ETParam] = [:]              // 平らな配列、平らに書いていた頃の"f"
        var objects: [String: [String: ETParam]] = [:]  // "bs" → "f" → ETParam
        for p in spec.params {
            if p.isObjectMember, let group = p.objectArrayKey, let member = p.memberKey {
                objects[group, default: [:]][member] = p
            } else if let key = p.flatArrayKey {
                lists[key] = p
            } else if p.isArray {
                for i in 0..<p.count { scalars[p.key + String(i)] = p }
                lists[p.key] = p
            } else {
                scalars[p.key] = p
            }
        }
        let display = ETDisplayParam.table(for: spec.type)
        // designerの材料も読む鍵（PipelineStore.parseがETDesignParam.readで拾う）。
        // 寄せるのはdesignerへ渡すとき（DesignParams.swift）なので、ここでは素通しする。
        let design = ETDesignParam.table(for: spec.type)
        let quiet = quietKeys[spec.type] ?? []

        for key in params.keys.sorted() where !skip.contains(key) {
            guard let raw = params[key] else { continue }
            let label = "\(spec.name).\(key)"
            if let p = scalars[key] {
                params[key] = fixValue(raw, p, type: spec.type, label: label, report: &report)
            } else if let members = objects[key] {
                params[key] = fixRows(raw, members: members, spec: spec, label: label, report: &report)
            } else if let p = lists[key] {
                params[key] = fixList(raw, p, spec: spec, label: label, report: &report)
            } else if display[key] != nil || design[key] != nil || quiet.contains(key)
                        || quietEverywhere.contains(key) || key == irKey || key == sfzKey {
                continue
            } else {
                report.add(label, to: \.ignored)
            }
        }
    }

    /// オブジェクト配列（`"bs": [{"f": …}, …]`）。行の数はETParam.countまで。
    private static func fixRows(_ raw: Any, members: [String: ETParam], spec: ETEffect,
                                label: String, report: inout Report) -> Any? {
        // decodeは`[[String: Any]]`で受けるので、辞書でない行が1つでもあると全部読まない。
        guard let list = raw as? [Any] else {
            report.add(label, to: \.ignored)
            return nil
        }
        var rows = list.compactMap { $0 as? [String: Any] }
        guard rows.count == list.count else {
            report.add(label, to: \.ignored)
            return nil
        }
        let count = members.values.map(\.count).max() ?? 0
        if rows.count > count { report.add(label, to: \.ignored) }
        for i in rows.indices where i < count {
            for key in rows[i].keys.sorted() {
                guard let value = rows[i][key] else { continue }
                if let p = members[key] {
                    rows[i][key] = fixValue(value, p, type: spec.type, label: "\(label).\(key)",
                                            report: &report)
                } else if !(quietKeys[spec.type] ?? []).contains(key) {
                    report.add("\(label).\(key)", to: \.ignored)
                }
            }
        }
        return rows
    }

    /// 平らな配列（`"dm": [...]`）。**外した要素は既定で埋める。**詰めると後ろの位置がずれる。
    private static func fixList(_ raw: Any, _ p: ETParam, spec: ETEffect, label: String,
                                report: inout Report) -> Any? {
        guard var list = raw as? [Any] else {
            report.add(label, to: \.ignored)
            return nil
        }
        if list.count > p.count { report.add(label, to: \.ignored) }
        for i in list.indices where i < p.count {
            let k = p.offset + i
            let fallback: Any = spec.defaults.indices.contains(k) ? Double(spec.defaults[k]) : 0
            list[i] = fixValue(list[i], p, type: spec.type, label: label, report: &report) ?? fallback
        }
        return list
    }

    /// 1つの値を直す。nilなら外す（decodeは既定を残す）。範囲の中なら元の値をそのまま返す。
    private static func fixValue(_ raw: Any, _ p: ETParam, type: String, label: String,
                                 report: inout Report) -> Any? {
        switch p.kind {
        case .toggle:
            if isBool(raw) { return raw }
            guard let v = number(raw), v.isFinite else {
                report.add(label, to: \.ignored)
                return nil
            }
            let fixed = min(max(v, 0), 1)
            if fixed != v {
                report.add(label, to: \.limited)
                return fixed
            }
            return raw

        case .enumeration(let options):
            if let s = raw as? String {
                if options.contains(s) { return raw }
            } else if let v = number(raw), v.isFinite {
                // **同じ数の選択肢を先に。**上流は数の値を`String(params.br)`のように
                // 綴りとして読む（mp3_codec_simulator.js:73、am_radio_simulator.js:1936）。
                // Digital Error Emulatorの8は"8"で、添字8の"5C"ではない。Tape Artifactsの7.5、
                // Tube Simulatorの8（"8.0"）、Bass Managementの8192もここで綴りへ直る。
                // 添字と綴りが同じ選択肢（"0"）はそのまま。
                if let i = options.firstIndex(where: { Double($0) == v }) {
                    if Double(i) == v { return raw }
                    return options[i]
                }
                // 同じ数の選択肢が無ければ添字（ETParamCoding.number）。
                if v == v.rounded(), v >= 0, v < Double(options.count) { return raw }
            }
            report.add(label, to: \.ignored)
            return nil

        case .number(let lo, let hi, _, _, _):
            var v: Double
            if let n = number(raw) {
                v = n
            } else if let s = raw as? String,
                      let n = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                v = n
            } else {
                report.add(label, to: \.ignored)
                return nil
            }
            guard v.isFinite else {
                report.add(label, to: \.ignored)
                return nil
            }
            // 見た目と違う数で持つもの（scaled）。**上限を超えた正の数は見た目の数と見る。**
            // Pivotに1000と書かれても約1kHzに、15と書かれても下の端（約20Hz）に着く。
            // 1e-6と書かれた割合は指数の-6に着く。直した先が範囲の外なら下で端へ寄せる。
            var converted = false
            if Float(v) > hi, v > 0, let written = scale(type: type, param: p) {
                v = written == .lnHz ? log(v) : log10(v)
                converted = true
            }
            // 比べるのはFloatで。範囲はFloatで持っていて、JSONの0.1はDoubleの0.1で来る。
            let fixed: Double
            if Float(v) < lo {
                fixed = Double(lo)
            } else if Float(v) > hi {
                fixed = Double(hi)
            } else {
                fixed = v
            }
            if let allowed = ETAllowedValues.upstream(type: type, key: p.key),
               !allowed.contains(Float(fixed)) {
                report.add(label, to: \.ignored)
                return nil
            }
            if fixed != v {
                report.add(label, to: \.limited)
                return fixed
            }
            if converted { return v }
            // 数の字（"-3"）は、ETParamCoding.numberがFloat(_:)で読めるならそのまま。
            // 前後に空白があると読めずに既定へ戻るので、数にして渡す。
            if let s = raw as? String, Float(s) == nil { return v }
            return raw
        }
    }

    /// JSONの真偽か。**Darwinでは0と1のNSNumberも`as? Bool`に通る**ので型で見分ける。
    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// JSONの数。真偽は数と見ない。
    private static func number(_ v: Any) -> Double? {
        guard !isBool(v), let n = v as? NSNumber else { return nil }
        return n.doubleValue
    }
}
