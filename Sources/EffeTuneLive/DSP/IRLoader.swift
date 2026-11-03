//  IRLoader.swift
//  取り込んだインパルス応答をカーネルへ渡す。
//
//  ここが無かったので、IR Reverb は素材を選んでも素通しのままだった
//  （IRLibrary は Documents/IR へ写すところで止まっていて、
//   AssetUpload.send の呼び手は FIR 系の designer だけだった）。
//
//  やることは3つ。
//    1. 音のファイルを float の面へ読む（AVAudioFile。WAV / FLAC / AIFF / CAF）
//    2. 上流の解決規則でtopologyとrate dividerを決める
//    3. 畳み込みのレートへ伸縮し、上流と同じ下ごしらえ（頭の無音・Direct Cut・正規化）を
//       かけ、32MiBに収まる長さへ切ってAssetUpload.sendへ渡す
//
//  1はIRDecode.swift、2と3の計算はIRPreparation.swift（どちらもFoundationだけで単体テストに入る。
//  IRPreparationは上流の答えと照合している）。
//  解決規則は js/ir-library/ir-plugin-contract.js:104-206
//  (resolveIrProcessingConfig) をそのまま写したもの。推測は入れていない。
//
//  **4ch の True Stereo が通るようにしてある。** BRIR（ダミーヘッドで測った
//  「部屋＋スピーカー」の応答。左右スピーカー → 左右両耳の 4 経路）を読ませると、
//  ヘッドホンでも目の前のスピーカーで鳴っているように聞こえる、という使い方が
//  上流で知られている。channelMode が auto のとき、4ch かつ処理幅 2ch なら
//  自動で True Stereo になる（同 :150-155）。

import Foundation
import os

// ETIRLoadErrorはIRPreparation.swiftにある（単体テストのバンドルからも見えるように）。

enum ETIRLoader {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "ir")

    /// プリセットに書く鍵の名前。上流に合わせて `ir`
    /// （plugins/reverb/ir_reverb.js:866 の `ir: entry.irId`）。
    static let presetKey = "ir"

    /// 鍵からライブラリを引いて入れ直す。開き直したときに呼ぶ。
    ///
    /// **入っていなければ黙って諦める。** 上流も、鍵が指す素材が手元に無ければ
    /// 素通しに落とすだけで、エラーは出さない（プリセットは中身を持たないので、
    /// 別の端末で作ったものを開けば普通に起きる）。
    @MainActor
    @discardableResult
    static func reload(irId: String,
                       nodeID: UUID,
                       engine: UInt32,
                       instance: UInt32,
                       processingRate: Double,
                       routedChannels: Int,
                       channelMode: String,
                       latency: String,
                       convolutionRate: String,
                       options: ETIRPreparation.Options) -> String? {
        guard !irId.isEmpty,
              let entry = IRLibrary.shared.entries.first(where: { $0.id == irId })
        else { return nil }
        return try? load(url: entry.url,
                         nodeID: nodeID,
                         engine: engine,
                         instance: instance,
                         processingRate: processingRate,
                         routedChannels: routedChannels,
                         channelMode: channelMode,
                         latency: latency,
                         convolutionRate: convolutionRate,
                         options: options)
    }

    /// 読み込んだ IR。面ごとに分かれた float と、その素材のレート（IRDecode.swift）。
    typealias Decoded = ETIRDecoded

    // MARK: - 読む

    /// ファイルを float の面へ読む。素材のレートのまま返す。
    /// 中身は IRDecode.swift（ETIRDecode.decode）。幅・長さ・レートの門と、非有限を 0 にする
    /// ところは単体テストで見ている（IRDecodeTests）。
    static func decode(_ url: URL) throws -> Decoded {
        try ETIRDecode.decode(url)
    }

    // MARK: - 送る

    /// 読んで、解決して、下ごしらえして、送る。**MainActor で呼ぶこと**（AssetUpload.swift 冒頭）。
    ///
    /// 同期のまま。呼び手（IRReverbView.apply、EffeTuneDSP.reloadAsset）は戻り値の1行と
    /// 成否をその場で使い、続けて組み直しや遅延の判定をする。非同期にすると送る順番が
    /// 入れ替わりうるので、重い伸縮は面ごとに別のコアへ散らすだけにしてある
    /// （ETIRPreparation.resampleChannels）。
    ///
    /// - Parameters:
    ///   - nodeID: 段の id。EDC グラフ（ETIRGraphStore）を段ごとに置くため。
    ///   - options: 下ごしらえのつまみ（dc / co / dt / tr）。段のNode.designから引く
    ///     （ETIRPreparation.Options(designParams:)）。
    /// - Returns: UI へ出す 1 行。「4ch True Stereo / 48000 Hz / 1.2 s」の形。
    @MainActor
    @discardableResult
    static func load(url: URL,
                     nodeID: UUID,
                     engine: UInt32,
                     instance: UInt32,
                     processingRate: Double,
                     routedChannels: Int,
                     channelMode: String,
                     latency: String,
                     convolutionRate: String,
                     options: ETIRPreparation.Options) throws -> String {
        let decoded = try decode(url)
        let resolved = try ETIRPreparation.resolve(sampleRate: processingRate,
                                                   channelCount: decoded.channels.count,
                                                   routedChannels: routedChannels,
                                                   channelMode: channelMode,
                                                   latency: latency,
                                                   convolutionRate: convolutionRate)

        // **ヘッダに書くのは「処理レート ÷ rate_divider」。素材のレートではない。**
        // カーネルの検算がそう書いてある（ir_reverb/kernel.cpp:486-496）:
        //     expected_rate = lround(sample_rate_ / rate_divider_)
        // `sample_rate_` はカーネルの処理レート。ここを素材のレートで書くと
        // commit が ET_ERR_ARGS(-1) で落ちる。
        //
        // だから中身もそのレート（resolved.convolutionRate）へ伸縮してから、上流と同じ
        // 下ごしらえをかけて、送る面を選ぶ（上流の_resamplePcm → prepareIr → emitPreparedIr）。
        // 正規化はfcで測るので、wetの大きさは素材のレートにもdividerにも依らない。
        let staged = try ETIRPreparation.stage(decoded.channels,
                                               sourceRate: decoded.sampleRate,
                                               resolved: resolved,
                                               options: options)

        // カーネルの32MiBに収まる長さへ切る（ir_reverb.js:530-548のmaximumIrFramesForKernel）。
        // 192kHzではフレーム数が倍になるので、48k/96kで入る長いIRでもここで切ることがある。
        // 以前は切らずにAssetUpload.sendがtooLargeで弾いていた。
        let isMatrix = resolved.topology == .matrix
        let limit = AssetUpload.maximumFrames(
            sourceFrames: staged.frames,
            assetChannels: resolved.assetChannels,
            topology: resolved.topology,
            processingChannels: Int(resolved.processingChannels),
            headBlock: Int(resolved.headBlock),
            pathCount: isMatrix ? resolved.paths.count : 0,
            inputCount: isMatrix ? Set(resolved.paths.map(\.inputSlot)).count : 0)
        let emitted = ETIRPreparation.truncate(staged.channels, maxFrames: limit)

        try AssetUpload.send(engine: engine,
                             instance: instance,
                             channels: emitted.channels,
                             sampleRate: resolved.convolutionRate,
                             topology: resolved.topology,
                             paths: resolved.paths,
                             headBlock: resolved.headBlock,
                             rateDivider: resolved.rateDivider,
                             processingChannels: resolved.processingChannels)

        // 送ったら組み直す。カーネルは資産が入って初めてその段を有効と数える。
        // 入れ直しのときは呼び手（reloadAssets）がまとめて 1 回呼ぶ。
        EffeTuneDSP.shared.republish()

        // EDC グラフ。**Current は今カーネルへ送った面そのもの、Original は decay・trim の前の面**
        // （上流の emit.analysis / prepare.analysis.original と同じ。IRAnalysis.swift の冒頭）。
        // 重いので解析は裏へ出し、送るところまでは同期のまま。キーが前と同じなら走らない。
        let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        ETIRGraphStore.shared.analyze(
            nodeID: nodeID,
            key: ETIRGraphStore.Key(path: url.path,
                                    modified: attributes?.contentModificationDate,
                                    fileSize: attributes?.fileSize,
                                    processingRate: processingRate,
                                    rateDivider: resolved.rateDivider,
                                    convolutionRate: resolved.convolutionRate,
                                    topology: resolved.topology.rawValue,
                                    assetChannels: resolved.assetChannels,
                                    directCut: options.directCut,
                                    cutOffsetMs: options.cutOffsetMs,
                                    decayPercent: options.decayPercent,
                                    trimPercent: options.trimPercent,
                                    emittedFrames: emitted.channels.first?.count ?? 0),
            source: ETIRGraphSource(originalChannels: staged.originalChannels,
                                    emittedChannels: emitted.channels,
                                    sampleRate: resolved.convolutionRate,
                                    onsetFrame: staged.onsetFrame,
                                    cutFrame: staged.cutFrame,
                                    sourceStartFrame: staged.sourceStartFrame))

        let frames = emitted.channels.first?.count ?? 0
        // 長さはふつう素材の長さ。カーネルに収めるために切ったときは、送った長さを出す
        // （以前はtooLargeで弾いていたので、切ったことが見えるのはここだけ）。
        let seconds = emitted.truncated
            ? Double(frames) / Double(resolved.convolutionRate)
            : Double(decoded.frames) / decoded.sampleRate
        let name = displayName(resolved.channelMode)
        // 出すのは素材のレート。送ったレートは中身の都合なので出さない。
        let line = String(format: "%dch %@ / %d Hz / %.2f s",
                          decoded.channels.count, name,
                          Int(decoded.sampleRate.rounded()), seconds)
        log.notice("IR 送り込み \(line, privacy: .public) divider=\(resolved.rateDivider) fc=\(resolved.convolutionRate) frames=\(frames) start=\(staged.sourceStartFrame) truncated=\(emitted.truncated)")
        return line
    }

    /// ir_reverb.js:1746-1756 の _channelModeName と同じ出し方（IRDecode.swift）。
    static func displayName(_ mode: String) -> String {
        ETIRDecode.displayName(mode)
    }
}
