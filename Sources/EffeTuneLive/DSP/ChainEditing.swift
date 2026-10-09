//  ChainEditing.swift
//  鎖をいじるときの決まりごと。**Foundationだけ。**
//
//  EffeTuneDSPから出した。あちらはosとet_*とAU/JSFXのhostに触るので、単体テストのバンドルに
//  入れられない。判断だけをここへ置き、EffeTuneDSPは並びを渡して答えを受け、Cやhostへ渡す
//  （PipelineAnalysis.swiftと同じ分け方）。試すのはTests/Unit/ChainEditingTests.swift。
//
//  持っているもの:
//    - 既定の鎖（Level Meter 1本）と、それを残さない決まり
//    - プリセットを足すときの組み立て（上流 preset-manager.js addPresetToPipeline）
//    - 外部の段（AU/JSFX）の身元がぶつかったときの付け直し
//    - 上流が受けないChに置かれた段（descriptorでは切で渡す）
//    - 選択肢の値の読み方と、資産を送り直さないと効かない値の位置
//    - descriptorの中身（Cの型へ写すのはEffeTuneDSPの1か所だけ）
//    - 鎖の段（ETChainNode）から渡す形（PipelineStore.Loaded）への写し

import Foundation

enum ETChainEditing {

    // MARK: - 既定の鎖

    /// 何も無いときに置く1本。restore()の既定とresetToDefault()が同じものを指すように、
    /// 型名はここだけに書く。
    static let defaultType = "LevelMeterPlugin"

    /// いま並んでいるのが既定そのもの（Level Meter 1本）か。
    static func isDefaultChain(types: [String]) -> Bool {
        types.count == 1 && types[0] == defaultType
    }

    /// 端末（pipeline.lastとiCloud）へ残してよいか。
    ///
    /// **restore()が置いた既定の1本は残さない。**「まだ何も残していない（hasSavedが偽）」かつ
    /// 「並んでいるのが既定そのもの」は、人が組んだ鎖ではなくrestore()の第二の枝が置いたものしか
    /// ありえない。これを書くと2つ壊れる:
    ///   - iCloud側の鎖がLevel Meter 1本で上書きされる（CloudMirror）
    ///   - "pipeline.last"が埋まるので、遅れて降りてくる鎖を受ける口
    ///     （CloudMirror.seedの「手元が空の鍵だけ」）が閉じる
    /// 人が消して既定に戻した場合はhasSavedが真なので残す。
    static func shouldPersist(types: [String], hasSaved: Bool) -> Bool {
        !(isDefaultChain(types: types) && !hasSaved)
    }

    // MARK: - プリセットを足す

    /// プリセットを足すときに、どこへ何を差し込むか。
    struct PresetInsertion {
        /// 差し込む位置（鎖の添字）。
        let target: Int
        /// 差し込むもの。先頭のSection・中身・要るときだけ閉じる名前の無いSection。
        let items: [PipelineStore.Loaded]
    }

    /// プリセットを**いまの鎖へ足す**ときの組み立て。置き換えない。
    ///
    /// 上流 preset-manager.js:78 addPresetToPipeline と同じ:
    ///   1. 先頭にSectionを1本。名前（cm）はプリセット名（:95-105）
    ///   2. その後ろにプリセットの中身（:165）
    ///   3. **挿入先の次がSectionでなく、末尾でもないなら**、終端用の名前の無いSectionを
    ///      もう1本（:149-160, :166-168）。後ろにあった鎖がこのプリセットの組に巻き込まれない
    ///      ように切る
    ///
    /// - Parameters:
    ///   - roles: いまの鎖の役目（ETChainNode.role）。
    ///   - index: 差し込む位置。nilなら末尾（上流のinsertionIndex = nullと同じ）。範囲の外は寄せる。
    ///   - makeID: 外部の段に付ける新しい身元。
    static func presetInsertion(named name: String,
                                items: [PipelineStore.Loaded],
                                at index: Int?,
                                roles: [ETItemRole],
                                makeID: () -> String = { UUID().uuidString }) -> PresetInsertion {
        let target = min(max(index ?? roles.count, 0), roles.count)

        // **channelSpecは-1（Stereo）。**0はLeftで、ここに0を入れていたせいでプリセットを
        // 読むだけでRoutingが既定から外れ、触っていないのに「Reset routing」が生えていた。
        var out: [PipelineStore.Loaded] = [section("")]
        out[0].sectionName = name

        for var item in items {
            if !item.externalID.isEmpty {
                // プリセットを足すと新しいprocessorを作る。プリセットに入っていた身元を使い回すと、
                // 2枚のカードが1つのAU・1つのパラメータの木・1つの外部の席を取り合う。
                item.externalInstanceID = makeID()
            }
            out.append(item)
        }

        // 末尾に足すなら閉じる必要が無い（その先に何も無い）。
        // 次が既にSectionならそれが区切りになるので、重ねない。
        // **終端（rootReset）も区切り。**見ないと名前の無いSectionが配下を持たないまま終端の前に
        // 残り、終端を保存するようになってからは再起動しても消えない。上流の終端は名前の無い
        // Sectionそのものなので、上流の「次がSectionなら」に当たる。
        if target < roles.count && roles[target] == .effect {
            out.append(section(""))
        }
        return PresetInsertion(target: target, items: out)
    }

    /// 素のSection。入っていて、鎖の形は既定（0→0、Stereo）。
    private static func section(_ name: String) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                             inputBus: 0, outputBus: 0, channelSpec: -1,
                             sectionName: name)
    }

    // MARK: - 外部の段の身元

    /// 保存した鎖・共有リンクから外部の段を戻すときの身元。
    ///
    /// 入っていた身元をそのまま使う（host側の状態と結び付いている）。ただし空か、
    /// **既に鎖に居る外部の段と同じなら新しく作る。**同じ身元の段が2つあると、
    /// 1つのAU・1つの外部の席を2枚のカードが取り合う。
    static func externalInstanceID(requested: String,
                                   taken: Set<String>,
                                   makeID: () -> String = { UUID().uuidString }) -> String {
        guard !requested.isEmpty, !taken.contains(requested) else { return makeID() }
        return requested
    }

    // MARK: - 上流が受けないCh

    static let bassExtenderType = "BassExtenderPlugin"
    /// BassManagementDesigners.typeと同じ字（あちらはSwiftUIを連れてくるのでここからは引けない）。
    static let bassManagementType = "BassManagementPlugin"
    static let adaptivePredictionType = "AdaptivePredictionEffectPlugin"

    /// 上流が受けないChに置かれた段。**descriptorではenabled 0で渡す**
    /// （カーネルを回さず、遅延もengineの合計に入らない）。
    ///
    /// 上流は plugin-execution-capabilities.js:37-89 でChをmodeに直し、
    /// supportedChannelModesに無ければbypassする（:91-110）。
    ///   Bass Extender   mono / stereo-pair（bass_extender.js:15-19）
    ///     → 既定（-1）と対（16以降）だけ。Allは幅によらず外す
    ///   Bass Management all（bass_management.js:15-19）→ All（-2）だけ
    ///   Adaptive Prediction mono / single / stereo-pair（adaptive_prediction_effect.js:21-24）
    ///     → All（-2）だけ外す。幅によらない（カーネルも 3ch 以上は素通し。kernel.cpp の process）
    /// 上流のbypassは入力をそのまま出力busへ渡す（offline-processor.js:878-879）。
    /// enabled 0はbusを移さないので、**入力と出力のbusが違う段だけ**音が食い違う。
    static func isChannelBypassed(type: String, channelSpec: Int8) -> Bool {
        switch type {
        case bassExtenderType:
            return !(channelSpec == -1 || channelSpec >= 16)
        case bassManagementType:
            return channelSpec != -2
        case adaptivePredictionType:
            return channelSpec == -2
        default:
            return false
        }
    }

    /// 無音を入れても音を出し続ける段か（上流の temporalCapability 'must-process'）。
    /// いまは Adaptive Prediction だけ。Autonomy が高いか Hold のとき、入力が無くても鳴り続ける。
    static func mustProcessWhileSilent(type: String) -> Bool {
        type == adaptivePredictionType
    }

    /// 鎖に、無音でも回し続けなければならない段があるか。入れていて、受けるチャンネルに居る段だけ。
    /// PowerGate.idleSeconds(mustProcess:) へ渡す。
    static func chainMustProcess(_ nodes: [ETChainNode]) -> Bool {
        nodes.contains {
            $0.enabled && mustProcessWhileSilent(type: $0.spec.type)
                && !isChannelBypassed(type: $0.spec.type, channelSpec: $0.channelSpec)
        }
    }

    // MARK: - 選択肢と資産

    /// 選択肢のparamから、いま選ばれている綴りを引く。読めなければ"auto"。
    ///
    /// **値は`param.offset`の位置から読む。**並びの何番目か（paramsの添字）ではない。
    /// 配列のparamが前にあると、並びの位置とfloatの並びの位置はずれる。
    /// enumerationの値は選択肢の添字なので、そこから戻す。
    static func choice(_ key: String, params: [ETParam], values: [Float]) -> String {
        guard let p = params.first(where: { $0.key == key }),
              case .enumeration(let options) = p.kind,
              values.indices.contains(p.offset) else { return "auto" }
        let v = values[p.offset]
        // Int(_:) は NaN と無限で落ちる。
        guard v.isFinite else { return "auto" }
        let n = Int(v.rounded())
        return options.indices.contains(n) ? options[n] : "auto"
    }

    /// 資産を送り直さないと効かない値の鍵（IR Reverb）。
    ///
    /// カーネルはこの3つを読まない（ir_reverb/kernel.cppがparams_から読むのはpreDelayと
    /// wetLevelとdryだけ）。畳み込みの形はbeginAssetに渡すAssetBeginInfoで決まるので、
    /// 選び直したら送り直す。
    static let assetConfigKeys: Set<String> = ["cm", "lt", "cr"]

    /// その段で、資産を送り直さないと効かない値の位置。素材を持っていない段は空。
    static func assetConfigOffsets(params: [ETParam], irId: String) -> Set<Int> {
        guard !irId.isEmpty else { return [] }
        return Set(params.filter { assetConfigKeys.contains($0.key) }.map(\.offset))
    }

    /// engineが回さない段（processedWidthが0）へIRを送ろうとしたときに出す1行。
    /// ETIRPreparation.resolveが幅0を断る文と同じ（カードから入れたときに赤字で出るもの）。
    static let unroutedAssetLine = "The selected audio channels are not available."

    /// 送り直した（EffeTuneDSP.reloadAsset）あと、カードに残す1行（assetInfo）。
    ///
    /// - 送れた: その1行
    /// - **engineが回さない段（幅0）: 理由の1行。前の行は残さない。**入れ直しはinstanceを作り直した後
    ///   （出力先の切り替え）に走り、資産はinstanceと一緒に消えている。nilにするとカードは「Loaded」と出す
    /// - 幅はあるのに送れなかった: 前のまま（選び直しをresolveが断った回は、送る前に止まるので
    ///   前の資産がカーネルに残って鳴っている）
    static func assetLineAfterReload(sent: String?, previous: String?, processedWidth: Int) -> String? {
        if let sent { return sent }
        if processedWidth < 1 { return unroutedAssetLine }
        return previous
    }

    // MARK: - descriptor

    /// 音のスレッドへ渡す1段。ETPipeline.hのETPipeNodeと同じ並び。
    /// **Cの型へ写すのはEffeTuneDSP.pipeNodesの1か所だけ。**
    struct Descriptor: Equatable {
        enum Kind: Equatable {
            case native
            case external
        }
        var instance: UInt32
        /// 0 = 切、1 = 入、**2 = 入だが数に入れない**（図に重ねるための探り）。
        var enabled: UInt8
        var inputBus: UInt8
        var outputBus: UInt8
        var channelSpec: Int8
        var sectionGate: UInt8
        var kind: Kind
        var externalIndex: UInt8
    }

    /// 鎖を、音のスレッドへ渡す並びにする。publish()とrepublish()が同じものを出す。
    ///
    /// - instanceを持たない段（Section・rootReset・作れなかった段）は落ちる。外部の段は
    ///   instanceを持たないが落とさない（external callback nodeになる）。上流もSectionを
    ///   descriptorに入れない（dsp-pipeline-descriptor.js:194-198）
    /// - 探り（`probes`、段のid → 探りのinstance）は相手の**直前**に置く。engine.cpp:917は
    ///   descriptorの順に回すので、直前の段が見ている音 = その段に入る音。入口のbusに置き、
    ///   enabled 2（人が置いた段ではないので「動いている数」に入れない）
    /// - 出口の探り（`afterProbes`）は相手の**直後**に置く。直後の段が見ている音 = その段から
    ///   出た音。上流のオーバーレイが段の前後で横取りするのと同じ位置
    ///   （plugins/audio-processor.js:5142-5157 が入口、:5275-5307 が出口）。出口のbusに置き、
    ///   enabled 2。探りを付けるのは入口と出口が同じbusの段だけ（EffeTuneDSP.syncProbes）
    /// - 上流が受けないChの段は切で渡す（isChannelBypassed）
    static func descriptors(chain: [ETChainNode], probes: [UUID: UInt32],
                            afterProbes: [UUID: UInt32] = [:]) -> [Descriptor] {
        var out: [Descriptor] = []
        out.reserveCapacity(chain.count * 3)
        for n in chain where n.instance != 0 || n.isExternal {
            if let probe = probes[n.id] {
                out.append(Descriptor(instance: probe,
                                      enabled: 2,
                                      inputBus: n.inputBus,
                                      outputBus: n.inputBus,
                                      channelSpec: n.channelSpec,
                                      sectionGate: n.sectionGate,
                                      kind: .native,
                                      externalIndex: 0))
            }
            let bypassed = isChannelBypassed(type: n.spec.type, channelSpec: n.channelSpec)
            out.append(Descriptor(instance: n.isExternal ? 0 : n.instance,
                                  enabled: n.enabled && !bypassed ? 1 : 0,
                                  inputBus: n.inputBus,
                                  outputBus: n.outputBus,
                                  channelSpec: n.channelSpec,
                                  sectionGate: n.sectionGate,
                                  kind: n.isExternal ? .external : .native,
                                  externalIndex: n.externalIndex))
            if let probe = afterProbes[n.id] {
                out.append(Descriptor(instance: probe,
                                      enabled: 2,
                                      inputBus: n.outputBus,
                                      outputBus: n.outputBus,
                                      channelSpec: n.channelSpec,
                                      sectionGate: n.sectionGate,
                                      kind: .native,
                                      externalIndex: 0))
            }
        }
        return out
    }
}

// MARK: - 鎖の段から渡す形へ

extension PipelineStore.Loaded {
    /// 鎖の1段を、書く手前の形へ写す。**書くのはLoadedの側だけ**（PipelineForm.swift）。
    init(_ node: ETChainNode) {
        self.init(spec: node.spec,
                  values: node.values,
                  enabled: node.enabled,
                  inputBus: node.inputBus,
                  outputBus: node.outputBus,
                  channelSpec: node.channelSpec,
                  sectionName: node.sectionName,
                  irId: node.irId,
                  display: node.display,
                  design: node.design,
                  externalID: node.externalID ?? "",
                  externalInstanceID: node.externalInstanceID,
                  externalState: node.externalState,
                  isRootReset: node.isRootReset)
    }
}

extension PipelineStore {
    /// ショート形式。共有リンクとプリセットに使う。中身はPipelineForm.swiftのLoaded版が書く。
    static func shortForm(_ chain: [ETChainNode]) -> [[String: Any]] {
        shortForm(chain.map { Loaded($0) })
    }

    /// ロング形式。ファイルに書き出すときに使う。
    static func longForm(_ chain: [ETChainNode]) -> [String: Any] {
        longForm(chain.map { Loaded($0) })
    }
}
