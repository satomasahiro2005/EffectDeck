//  IRPreparation.swift
//  IRをカーネルへ渡す前の下ごしらえ。OSに触らない計算だけを置く（Foundationのみ）。
//
//  上流は素材をそのままカーネルへ渡していない。畳み込みのレートfc = round(処理レート ÷ rate_divider)
//  へ伸縮したあと、js/ir-library/ir-preparation.js:340-442のprepareIrで
//    1. 頭の無音を落とす（utils/measurement-dsp/onset.js:1-23）
//    2. Direct Cut（既定で入）。直接音の次のフレームから始め、頭64フレームを立ち上げる
//    3. エネルギーで正規化する（各面1/√E、True Stereoは4面まとめて√(4/ΣE)）
//    4. 減衰の整形（dt）と切り詰め（tr）。既定の100では何もしない
//    5. 最後にもう一度正規化する
//  をかけ、emitPreparedIr（:444-521）で送る面を選んでカーネルの32MiBに収まる長さへ切る。
//
//  **ここが無かった。** そのためEffectDeckのwetは上流より10·log10(Σh²)だけ大きく、
//  しかもΣh²は畳み込みのレートで数えるので、192kHz（Autoでhalf、96kHzで畳み込む）だけ
//  上流の+6dBに対して+9dBになって割れていた。
//
//  **正規化は伸縮の後、fcで測る。** 伸縮は標本の値を保つので、素材のレートで測ると
//  fc/f0の分が戻ってくる。カーネルのrate_gain（kernel.cpp:634）はfcで正規化した
//  IRを前提にしているので、そちらには手を入れない。上流と同じく、処理レートが倍になるごとに
//  wetは+3dBずつ上がる（上流の設計のまま。プリセットが両方で同じに鳴るように合わせてある）。
//
//  単体テストのバンドルへこのファイルを直接入れ、上流のJSが吐いた見本
//  （Tests/Fixtures/IR/prepare-golden.json、Tools/ir_prepare_golden.mjs）と照合している。
//  ファイルを読むのと送るのはIRLoader.swift。

import Foundation

// MARK: - 資産の形

/// ETA1 の topology。ir-asset-payload.js:5-11 と kernel.h の値が一致している。
enum ETAssetTopology: UInt32 {
    case unspecified = 0
    case mono = 1
    case independent = 2
    case trueStereo = 3
    case matrix = 4
}

/// matrix topology のときだけ要る経路。1 本 12 バイト。
struct ETAssetPath {
    var inputSlot: UInt32
    var outputSlot: UInt32
    var irChannel: UInt32

    init(inputSlot: UInt32, outputSlot: UInt32, irChannel: UInt32) {
        self.inputSlot = inputSlot
        self.outputSlot = outputSlot
        self.irChannel = irChannel
    }
}

// MARK: - 失敗の種類

enum ETIRLoadError: LocalizedError {
    case cannotOpen(String)
    case emptyFile
    case tooManyChannels(Int)
    case unsupportedRate(Double)
    /// 上流の resolveIrProcessingConfig が返す拒否の文。そのまま出す。
    case rejected(String)

    var errorDescription: String? {
        switch self {
        // 理由（AVFoundationの番号つきの文）は画面に出さない。Crosstalkの字と揃える。
        case .cannotOpen: return "Could not read that file."
        case .emptyFile: return "The file contains no audio."
        case .tooManyChannels(let n): return "This impulse response has \(n) channels; up to 16 are supported."
        case .unsupportedRate(let r):
            // 壊れたヘッダは桁外れの値やNaNを持ちうる。Int(_:)は範囲外で落ちるので、そのときは数のまま出す。
            let shown = r.isFinite && abs(r) < 1e15 ? String(Int(r)) : "\(r)"
            return "Unsupported sample rate \(shown)."
        case .rejected(let message): return message
        }
    }
}

enum ETIRPreparation {

    // MARK: - 解決

    /// 上流 resolveIrProcessingConfig の答え。
    struct Resolved {
        var topology: ETAssetTopology
        /// 送る面の数。mono は 1、indep は処理幅、true は 4、matrix は素材のまま。
        var assetChannels: Int
        var processingChannels: UInt32
        var paths: [ETAssetPath]
        var headBlock: UInt32
        var rateDivider: UInt32
        /// 処理レート（engineのレート）。resolveに渡した値そのまま。伸縮で帯域を切るかどうかに使う。
        var processingRate: Double
        /// 畳み込みのレート。ETA1のヘッダに書く値で、下ごしらえもこのレートでやる。
        /// 上流の`sampleRate: Math.round(sampleRate / rateDivider)`（ir-plugin-contract.js:205）。
        var convolutionRate: Int
        /// auto を解いた結果。UI に出す用。
        var channelMode: String
        var rateMode: String
    }

    /// ir-plugin-contract.js:104-206 をそのまま写したもの。
    ///
    /// - Parameters:
    ///   - sampleRate: **処理レート**（engine のレート）。素材のレートではない
    ///   - channelCount: 素材の面の数
    ///   - routedChannels: このエフェクトが処理する幅
    ///   - channelMode: "auto" / "mono" / "indep" / "true" / "multi"
    ///   - latency: "0" / "128" / "256" / "512" / "1024"
    ///   - convolutionRate: "auto" / "full" / "half" / "quarter"
    static func resolve(sampleRate: Double,
                        channelCount: Int,
                        routedChannels: Int,
                        channelMode: String,
                        latency: String,
                        convolutionRate: String) throws -> Resolved {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ETIRLoadError.rejected("The current audio sample rate is unavailable.")
        }
        guard channelCount >= 1, channelCount <= 16 else {
            throw ETIRLoadError.rejected("This impulse response has an unsupported channel count.")
        }
        guard routedChannels >= 1, routedChannels <= 16 else {
            throw ETIRLoadError.rejected("The selected audio channels are not available.")
        }
        guard ["auto", "mono", "indep", "true", "multi"].contains(channelMode) else {
            throw ETIRLoadError.rejected("Choose a supported channel mode.")
        }

        guard let headBlock = UInt32(latency),
              [0, 128, 256, 512, 1024].contains(headBlock) else {
            throw ETIRLoadError.rejected("Choose a supported latency setting.")
        }

        var rateMode = convolutionRate
        if headBlock == 0 { rateMode = "full" }
        if rateMode == "auto" { rateMode = sampleRate >= 88200 ? "half" : "full" }
        guard ["full", "half", "quarter"].contains(rateMode) else {
            throw ETIRLoadError.rejected("Choose a supported convolution rate.")
        }
        if rateMode == "quarter" && sampleRate < 176400 {
            throw ETIRLoadError.rejected(
                "Quarter rate is available at sample rates of 176.4 kHz or higher.")
        }
        let rateDivider: UInt32 = rateMode == "quarter" ? 4 : (rateMode == "half" ? 2 : 1)

        var resolvedMode = channelMode
        if resolvedMode == "auto" {
            if channelCount == 1 {
                resolvedMode = "mono"
            } else if channelCount == 4 && routedChannels == 2 {
                resolvedMode = "true"
            } else if channelCount == routedChannels {
                resolvedMode = "indep"
            } else {
                resolvedMode = "multi"
            }
        }

        let topology: ETAssetTopology
        let assetChannels: Int
        var paths = [ETAssetPath]()
        switch resolvedMode {
        case "mono":
            topology = .mono
            assetChannels = 1
        case "true":
            guard channelCount == 4, routedChannels == 2 else {
                throw ETIRLoadError.rejected(
                    "True Stereo requires a four-channel IR and a stereo channel selection.")
            }
            topology = .trueStereo
            assetChannels = 4
        case "indep":
            guard channelCount >= routedChannels else {
                throw ETIRLoadError.rejected(
                    "Independent mode requires one IR channel for each selected audio channel.")
            }
            topology = .independent
            assetChannels = routedChannels
        default:
            // diagonalPaths（同 :41-52）。素材と処理幅の小さい方まで、1 対 1 で結ぶ。
            let count = min(channelCount, routedChannels, 16)
            guard count > 0 else {
                throw ETIRLoadError.rejected("Matrix mode could not create a valid channel route.")
            }
            for i in 0..<count {
                paths.append(ETAssetPath(inputSlot: UInt32(i),
                                         outputSlot: UInt32(i),
                                         irChannel: UInt32(i)))
            }
            topology = .matrix
            assetChannels = channelCount
        }

        return Resolved(topology: topology,
                        assetChannels: assetChannels,
                        processingChannels: UInt32(routedChannels),
                        paths: paths,
                        headBlock: headBlock,
                        rateDivider: rateDivider,
                        processingRate: sampleRate,
                        convolutionRate: Int(jsRound(sampleRate / Double(rateDivider))),
                        channelMode: resolvedMode,
                        rateMode: rateMode)
    }

    // MARK: - 下ごしらえの設定

    /// 上流のホスト側の4つのつまみ（ir_reverb.js:37-40）。既定は上流と同じ。
    /// 値は段のNode.designに上流の綴り（dc / co / dt / tr）で持ち、
    /// ETIRPreparation.Options(designParams:)（DesignParams.swift）でここへ入れる。
    struct Options {
        /// dc。直接音を落とす。
        var directCut = true
        /// co。切る位置をonsetからずらすms。-20〜50。
        var cutOffsetMs = 0.0
        /// dt。減衰の長さを何%にするか。10〜400。100で何もしない。
        var decayPercent = 100.0
        /// tr。長さを何%に切り詰めるか。1〜100。100で何もしない。
        var trimPercent = 100.0

        static let upstreamDefaults = Options()
    }

    /// 下ごしらえの結果。上流のprepareIrが返すanalysisのうち、送るのに要る分と照合に使う分。
    struct Prepared {
        var channels: [[Float]]
        var sampleRate: Int
        var leadingSilenceFrames: Int
        var onsetFrame: Int
        /// Direct Cutが切った位置。切っていなければnil。負にもなる（上流のまま）。
        var cutFrame: Int?
        /// 素材の何フレーム目から始めたか。
        var sourceStartFrame: Int
        /// trで切り詰めたか。32MiBに収めるための切り詰め（truncate）は含まない。
        var truncated: Bool
        var initialGains: [Float]
        var finalGains: [Float]
        /// 上流の analysis.original（ir-preparation.js:367-373）の材料。全部の面を、頭の無音と
        /// Direct Cut とフェードインと最初の利得まで済ませた形で、**decay（dt）・trim（tr）・最後の利得の前**に
        /// 控えたもの。EDC の図の点線（Original）がこれ。画面の図のためだけに持つ（IRAnalysis.swift）。
        /// 選んだ面（selectChannels）の後も変えない。送る面は `channels` の方。
        var originalChannels: [[Float]]

        var frames: Int { channels.first?.count ?? 0 }
    }

    /// ir-preparation.js:9-10。
    static let directCutFadeFrames = 64
    static let trimFadeFrames = 2048

    /// 素材のレートと畳み込みのレートとして受け付ける幅。上流のrequireBoundedDecodedIrShape
    /// （ir-library-limits.js:29-40）と同じで、上流は読んだ面にも伸縮した面にもこれをかける
    /// （js/ir-library/service.js:337, :340）。
    /// ヘッダが壊れて何GHzと書いてあるファイルを通すと、伸縮の係数の表が何十GBにもなって落ちる。
    /// 起動時の入れ直しでも読むので、そのまま通すと開くたびに落ちることになる。
    static let supportedRates: ClosedRange<Double> = 1000...999_999

    /// 上流が準備に失敗したときに出す文（ir_reverb.jsのirReverb.error.prepare）。
    private static var prepareFailure: ETIRLoadError {
        .rejected("The impulse response could not be prepared. Try a shorter audio file.")
    }

    // MARK: - 読んだ面から送る面まで

    /// 伸縮 → 下ごしらえ → 面を選ぶ。IRLoader.loadが呼ぶ。
    ///
    /// 上流の_resamplePcm → prepareIr → emitPreparedIrの順（ir_reverb.js:440-446, :530-548）。
    /// **32MiBに収める切り詰めはここでしない。** 上限はAssetUpload.maximumFramesが出すもので、
    /// それを持ってからtruncateを呼ぶ。
    ///
    /// 返す`channels`は送る面だけ（topologyに合わせて選んだ後）。gainsは全部の面のもの。
    ///
    /// **伸縮は上流と同じ形にする。帯域は素材と処理レートで決まり、dividerでは変わらない。**
    /// 上流は素材をdecodeAudioDataでengineのレートfsへ変換し（帯域はmin(f0, fs)のナイキストで切れる）、
    /// そこからOfflineAudioContextでd個おきに拾う（ir_reverb.js:1480-1529）。fc/2より上に残った分は
    /// 折り返るが、エネルギーは残るので、fcで正規化した後の帯域内の大きさはdによらない。
    ///   - 素材がfsそのもの: dが1なら触らない。2・4ならd個おきに拾うだけ（上流と同じ面になる）
    ///   - それ以外: 帯域をmin(f0, fs)で切る窓付きsincで、fcの位置の値を直接求める
    ///     （fsへ変換してから拾うのと同じ値を、1回で出す）
    ///
    /// 以前は帯域をmin(f0, fc)で切り、素材とfcが同じなら触らずに渡していた。するとdividerごとに
    /// 正規化に入る上の帯域のエネルギーが変わり、明るいIRほど帯域内のwetがdividerで動いた
    /// （SerumのCrystal Hallで、176.4kHzのquarterだけfull・halfより0.38dB小さい。48kHzの平らな
    /// 雑音のIRを88.2kHzのAuto（half、fcは44.1kHz）で読むと、fullより0.41dB大きい）。
    static func stage(_ channels: [[Float]],
                      sourceRate: Double,
                      resolved: Resolved,
                      options: Options = .upstreamDefaults) throws -> Prepared {
        let fc = resolved.convolutionRate
        guard supportedRates.contains(sourceRate) else { throw ETIRLoadError.unsupportedRate(sourceRate) }
        guard supportedRates.contains(Double(fc)) else { throw ETIRLoadError.unsupportedRate(Double(fc)) }
        // 下ごしらえは全部の面でやる（上流もonsetを全部の面のエネルギーで見る）。
        // 選ぶのはその後（ir-preparation.js:462-474）。
        let resampled: [[Float]]
        if jsRound(sourceRate) == jsRound(resolved.processingRate) {
            resampled = resolved.rateDivider == 1
                ? channels
                : pick(channels, from: sourceRate, to: Double(fc))
        } else {
            resampled = resampleChannels(channels, from: sourceRate, to: Double(fc),
                                         bandRate: resolved.processingRate)
        }
        var prepared = try prepare(resampled, sampleRate: fc, topology: resolved.topology, options: options)
        prepared.channels = try selectChannels(prepared.channels,
                                               topology: resolved.topology,
                                               assetChannels: resolved.assetChannels)
        return prepared
    }

    /// 送る面を選ぶ。emitPreparedIr（ir-preparation.js:462-474）。
    ///   mono   先頭1面だけ
    ///   indep  先頭から処理幅ぶん
    ///   true   4面そのまま
    ///   matrix 素材のまま
    static func selectChannels(_ channels: [[Float]],
                               topology: ETAssetTopology,
                               assetChannels: Int) throws -> [[Float]] {
        switch topology {
        case .mono where channels.count > 1:
            return [channels[0]]
        case .independent:
            guard assetChannels >= 1, assetChannels <= channels.count else {
                throw ETIRLoadError.rejected(
                    "This impulse response does not have enough channels for the selected mode.")
            }
            return Array(channels.prefix(assetChannels))
        default:
            return channels
        }
    }

    /// カーネルに収まる長さへ切る。emitPreparedIr（ir-preparation.js:476-481）。
    ///
    /// 末尾min(2048, 残す長さ)フレームを0.5 + 0.5·cosで落とす。**正規化はし直さない。**
    /// 上流も切った後の面をそのまま送っていて、切った分だけwetが小さくなる。
    static func truncate(_ channels: [[Float]], maxFrames: Int) -> (channels: [[Float]], truncated: Bool) {
        guard let frames = channels.first?.count else { return (channels, false) }
        let outputFrames = min(max(1, maxFrames), frames)
        guard outputFrames < frames else { return (channels, false) }
        var out = channels.map { Array($0[0..<outputFrames]) }
        applyFadeOut(&out)
        return (out, true)
    }

    // MARK: - prepareIr

    /// ir-preparation.js:340-397のprepareIrを写したもの。
    ///
    /// 上流と同じ順に、同じ精度で計算する。エネルギーはFloat64Array（Double）、
    /// 利得はFloat32Array（Float）、面はFloat32Array（Float）。掛け算は上流と同じく
    /// Doubleで掛けてからFloatへ丸める。Float同士の積はDoubleで正確に表せるので、
    /// `x * gain`をFloatで計算しても結果は同じになる。
    ///
    /// 上流が返すanalysis（包絡・EDC・L1の上限）は画面の図の材料で、送る面には効かない。
    /// ここでは計算しない。図の分は IRAnalysis.swift が、`originalChannels`（上流の analysis.original の
    /// 材料）と送った面から別に計算する（重いので呼び手が裏で回す）。L1の上限とpeakDbは図が使わないので
    /// どこでも計算しない。rt60も、dtが100のときは使われないのでここでは測らない。
    ///
    /// - Parameters:
    ///   - source: 面。長さは全部同じ。1〜16面
    ///   - sampleRate: この面のレート。**畳み込みのレート（fc）**で渡す
    ///   - topology: 解決したtopology。True Stereoは4面が要る
    static func prepare(_ source: [[Float]],
                        sampleRate: Int,
                        topology: ETAssetTopology,
                        options: Options = .upstreamDefaults) throws -> Prepared {
        // validateRequest（:12-32）
        guard source.count >= 1, source.count <= 16 else { throw prepareFailure }
        let frames = source[0].count
        guard frames > 0 else { throw prepareFailure }
        for channel in source {
            guard channel.count == frames else { throw prepareFailure }
            for sample in channel where !sample.isFinite { throw prepareFailure }
        }
        guard sampleRate > 0, sampleRate <= 0xFFFF_FFFF else { throw prepareFailure }

        // resolveOptions（:40-78）
        guard options.cutOffsetMs.isFinite, options.decayPercent.isFinite, options.trimPercent.isFinite,
              options.cutOffsetMs >= -20, options.cutOffsetMs <= 50,
              options.decayPercent >= 10, options.decayPercent <= 400,
              options.trimPercent >= 1, options.trimPercent <= 100,
              topology != .unspecified else { throw prepareFailure }
        if topology == .trueStereo && source.count != 4 { throw prepareFailure }
        // 上流はmaxFramesに面の長さを渡している（ir_reverb.js:545）。trの上限にしか効かない。
        let maxFrames = frames
        let fs = Double(sampleRate)

        let detected = detectOnset(frameEnergies(source, from: 0, gains: nil), sampleRate: sampleRate)
        let lead = detected.leadingSilenceFrames
        let onsetFrame = detected.onsetFrame
        let cutOffsetFrames = Int(jsRound(options.cutOffsetMs * fs / 1000))
        var startFrame = lead
        var cutFrame: Int?
        if options.directCut {
            let cut = onsetFrame + cutOffsetFrames
            cutFrame = cut
            let afterCut = cut + 1
            if afterCut > startFrame { startFrame = afterCut }
        }
        if startFrame >= frames { startFrame = frames - 1 }

        // Direct Cutのときは、切る前の面（頭の無音だけ落としたもの）で利得を測る（:355-361）。
        let reference = options.directCut
            ? normalizationReference(source, from: lead, sampleRate: fs,
                                     topology: topology, options: options, maxFrames: maxFrames)
            : nil

        var channels = source.map { Array($0[startFrame...]) }
        if options.directCut { applyFadeIn(&channels) }
        let initialGains = reference?.initialGains
            ?? normalizationGains(channelEnergies(channels, from: 0), topology: topology)
        applyGains(&channels, initialGains)
        // 上流の originalAnalysis を取る点（:367-373）。decay・trim・最後の利得の前。
        // 後ろの工程が channels を書き換えるとき（既定のままなら最後の利得だけ）に1回写しが取られる。
        // 解析が終われば呼び手が手放すので、Prepared には持たせっぱなしにしない。
        let original = channels

        let shape: DecayShape?
        if let reference {
            shape = reference.shape
        } else {
            // 上流はここでanalyze()を回してrt60を取る（:367-381）。使うのはdecayShapeだけ。
            let rt60 = options.decayPercent == 100
                ? nil
                : estimateRt60(channels, from: 0, sampleRate: fs, gains: nil)
            shape = decayShape(frames: channels[0].count, sampleRate: fs,
                               decayPercent: options.decayPercent, rt60Seconds: rt60)
        }
        let decayFrameOffset = reference != nil ? startFrame - lead : 0
        shapeDecay(&channels, sampleRate: fs, shape: shape, frameOffset: decayFrameOffset)

        let outputFrames = outputFrameCount(channels[0].count,
                                            trimPercent: options.trimPercent,
                                            maxFrames: maxFrames)
        let truncated = outputFrames < channels[0].count
        if truncated {
            channels = channels.map { Array($0[0..<outputFrames]) }
            applyFadeOut(&channels)
        }
        let finalGains = reference?.finalGains
            ?? normalizationGains(channelEnergies(channels, from: 0), topology: topology)
        applyGains(&channels, finalGains)
        // 上流はここでbuildIrAssetPayloadを通し、非有限が1つでもあれば投げる（ir-asset-payload.js:28）。
        // 測った範囲が非正規化数だけだと、利得がFloatを溢れてinfになる。全部の面で見る
        // （送る面だけ見ると、monoで選ばない面が壊れていても通ってしまう）。
        for channel in channels {
            for sample in channel where !sample.isFinite { throw prepareFailure }
        }

        return Prepared(channels: channels,
                        sampleRate: sampleRate,
                        leadingSilenceFrames: lead,
                        onsetFrame: onsetFrame,
                        cutFrame: cutFrame,
                        sourceStartFrame: startFrame,
                        truncated: truncated,
                        initialGains: initialGains,
                        finalGains: finalGains,
                        originalChannels: original)
    }

    /// onset.js:1-23のdetectOnsetFromEnergies。
    ///
    /// 頭の無音は「フレームのエネルギーが1e-20以下」が続くところ。全部が無音なら両方0。
    /// onsetは、1ms（最低8フレーム）の窓のエネルギーが最大の1%に届いた最初のフレーム。
    /// 窓の和は上流と同じく足してから引く順で持つ（同じフレームを選ぶため）。
    static func detectOnset(_ energies: [Double], sampleRate: Int) -> (onsetFrame: Int, leadingSilenceFrames: Int) {
        var lead = 0
        while lead < energies.count && energies[lead] <= 1e-20 { lead += 1 }
        if lead == energies.count { return (0, 0) }
        let roundedWindow = Int(jsRound(Double(sampleRate) * 0.001))
        let windowFrames = roundedWindow < 8 ? 8 : roundedWindow
        var windowEnergy = [Double](repeating: 0, count: energies.count)
        var running = 0.0
        var peak = 0.0
        for frame in 0..<energies.count {
            running += energies[frame]
            if frame >= windowFrames { running -= energies[frame - windowFrames] }
            windowEnergy[frame] = running
            if running > peak { peak = running }
        }
        let threshold = peak * 0.01
        var onset = lead
        while onset < windowEnergy.count && windowEnergy[onset] < threshold { onset += 1 }
        if onset == windowEnergy.count { onset = lead }
        return (onset, lead)
    }

    // MARK: - prepareIrの部品

    private struct DecayShape {
        let extraSlope: Double
        let offsetDb: Double
    }

    private struct Reference {
        let initialGains: [Float]
        let finalGains: [Float]
        let shape: DecayShape?
    }

    /// Math.round。0.5ちょうどは+∞側へ丸める（Swiftのrounded()は0から遠い側なので、負で食い違う）。
    static func jsRound(_ x: Double) -> Double {
        let down = x.rounded(.down)
        return x - down >= 0.5 ? down + 1 : down
    }

    /// frameEnergies（:80-91）。`from`より前は見ない（上流のsubarrayと同じ）。
    /// IRAnalysis.swift も使う（EDC を1か所にしか持たないため private にしない）。
    static func frameEnergies(_ channels: [[Float]], from offset: Int, gains: [Float]?) -> [Double] {
        let length = channels[0].count - offset
        var energies = [Double](repeating: 0, count: length)
        for c in channels.indices {
            let gain = gains.map { Double($0[c]) } ?? 1
            channels[c].withUnsafeBufferPointer { x in
                for frame in 0..<length {
                    let sample = Double(x[offset + frame]) * gain
                    energies[frame] += sample * sample
                }
            }
        }
        return energies
    }

    /// channelEnergies（:93-101）。
    private static func channelEnergies(_ channels: [[Float]], from offset: Int) -> [Double] {
        channels.map { channel in
            var energy = 0.0
            for i in offset..<channel.count {
                let sample = Double(channel[i])
                energy += sample * sample
            }
            return energy
        }
    }

    /// normalizationGainsFromEnergies（:103-116）。True Stereoは4面で1つの利得。
    private static func normalizationGains(_ energies: [Double], topology: ETAssetTopology) -> [Float] {
        if topology == .trueStereo {
            var energy = 0.0
            for channelEnergy in energies { energy += channelEnergy }
            let gain = energy > 0 ? (Double(energies.count) / energy).squareRoot() : 1
            return [Float](repeating: Float(gain), count: energies.count)
        }
        return energies.map { energy in Float(energy > 0 ? 1 / energy.squareRoot() : 1) }
    }

    /// applyNormalizationGains（:122-129）。
    private static func applyGains(_ channels: inout [[Float]], _ gains: [Float]) {
        for c in channels.indices {
            let gain = gains[c]
            if gain == 1 { continue }
            channels[c].withUnsafeMutableBufferPointer { x in
                for i in x.indices { x[i] *= gain }
            }
        }
    }

    /// applyFadeIn（:131-139）。Direct Cutの立ち上がり。
    private static func applyFadeIn(_ channels: inout [[Float]]) {
        let available = channels[0].count
        let fadeFrames = available < directCutFadeFrames ? available : directCutFadeFrames
        for frame in 0..<fadeFrames {
            let phase = fadeFrames == 1 ? 1 : Double(frame) / Double(fadeFrames - 1)
            let gain = 0.5 - 0.5 * cos(Double.pi * phase)
            for c in channels.indices {
                channels[c][frame] = Float(Double(channels[c][frame]) * gain)
            }
        }
    }

    /// applyFadeOut（:141-149）。
    private static func applyFadeOut(_ channels: inout [[Float]]) {
        let available = channels[0].count
        let fadeFrames = available < trimFadeFrames ? available : trimFadeFrames
        let start = available - fadeFrames
        for index in 0..<fadeFrames {
            let gain = fadeOutGain(index, fadeFrames)
            for c in channels.indices {
                channels[c][start + index] = Float(Double(channels[c][start + index]) * gain)
            }
        }
    }

    /// fadeOutGain（:151-154）。
    private static func fadeOutGain(_ index: Int, _ fadeFrames: Int) -> Double {
        let phase = fadeFrames == 1 ? 1 : Double(index) / Double(fadeFrames - 1)
        return 0.5 + 0.5 * cos(Double.pi * phase)
    }

    /// estimateRt60（:167-189）。computeEdc（:156-165）を含む。
    /// IRAnalysis.swift も使う（RT60 の推定を1か所にしか持たないため private にしない）。
    static func estimateRt60(_ channels: [[Float]], from offset: Int,
                                     sampleRate: Double, gains: [Float]?) -> Double? {
        let energies = frameEnergies(channels, from: offset, gains: gains)
        var accumulated = [Double](repeating: 0, count: energies.count)
        var total = 0.0
        for frame in stride(from: energies.count - 1, through: 0, by: -1) {
            total += energies[frame]
            accumulated[frame] = total
        }
        guard total > 0 else { return nil }
        var count = 0
        var sumTime = 0.0
        var sumDb = 0.0
        var sumTimeDb = 0.0
        var sumTimeSquared = 0.0
        for frame in 0..<accumulated.count {
            let db = 10 * log10(accumulated[frame] / total)
            if db > -5 || db < -35 { continue }
            let time = Double(frame) / sampleRate
            count += 1
            sumTime += time
            sumDb += db
            sumTimeDb += time * db
            sumTimeSquared += time * time
        }
        let n = Double(count)
        let denominator = n * sumTimeSquared - sumTime * sumTime
        if count < 8 || denominator == 0 { return nil }
        let slope = (n * sumTimeDb - sumTime * sumDb) / denominator
        return slope < 0 ? -60 / slope : nil
    }

    /// decayShape（:191-198）。
    private static func decayShape(frames: Int, sampleRate: Double,
                                   decayPercent: Double, rt60Seconds: Double?) -> DecayShape? {
        guard decayPercent != 100, let rt60 = rt60Seconds, rt60 > 0 else { return nil }
        let originalSlopeDbPerSecond = -60 / rt60
        let extraSlope = originalSlopeDbPerSecond * (100 / decayPercent - 1)
        let endDb = extraSlope * Double(frames - 1) / sampleRate
        let offsetDb = endDb > 0 ? endDb : 0
        return DecayShape(extraSlope: extraSlope, offsetDb: offsetDb)
    }

    /// decayGain（:200-202）。
    private static func decayGain(_ shape: DecayShape?, _ frame: Int, _ sampleRate: Double) -> Double {
        guard let shape else { return 1 }
        return pow(10, (shape.extraSlope * Double(frame) / sampleRate - shape.offsetDb) / 20)
    }

    /// shapeDecay（:204-210）。
    private static func shapeDecay(_ channels: inout [[Float]], sampleRate: Double,
                                   shape: DecayShape?, frameOffset: Int) {
        guard shape != nil else { return }
        let length = channels[0].count
        var gains = [Double](repeating: 1, count: length)
        for frame in 0..<length { gains[frame] = decayGain(shape, frame + frameOffset, sampleRate) }
        for c in channels.indices {
            channels[c].withUnsafeMutableBufferPointer { x in
                for frame in 0..<length { x[frame] = Float(Double(x[frame]) * gains[frame]) }
            }
        }
    }

    /// outputFrameCount（:212-217）。
    private static func outputFrameCount(_ frames: Int, trimPercent: Double, maxFrames: Int) -> Int {
        let requestedFrames = Int(jsRound(Double(frames) * trimPercent / 100))
        var outputFrames = requestedFrames < 1 ? 1 : requestedFrames
        if outputFrames > maxFrames { outputFrames = maxFrames }
        return outputFrames
    }

    /// normalizationReference（:219-259）。`from`より前（頭の無音）は見ない。
    private static func normalizationReference(_ source: [[Float]], from lead: Int,
                                               sampleRate: Double, topology: ETAssetTopology,
                                               options: Options, maxFrames: Int) -> Reference {
        let initialGains = normalizationGains(channelEnergies(source, from: lead), topology: topology)
        let length = source[0].count - lead
        let rt60 = options.decayPercent == 100
            ? nil
            : estimateRt60(source, from: lead, sampleRate: sampleRate, gains: initialGains)
        let outputFrames = outputFrameCount(length, trimPercent: options.trimPercent, maxFrames: maxFrames)
        let truncated = outputFrames < length
        let shape = decayShape(frames: length, sampleRate: sampleRate,
                               decayPercent: options.decayPercent, rt60Seconds: rt60)

        var energies = [Double](repeating: 0, count: source.count)
        let fadeFrames = truncated ? (outputFrames < trimFadeFrames ? outputFrames : trimFadeFrames) : 0
        let fadeStart = outputFrames - fadeFrames
        let gains = initialGains.map(Double.init)
        for frame in 0..<outputFrames {
            let frameDecayGain = decayGain(shape, frame, sampleRate)
            var fadeGain = 1.0
            if truncated && frame >= fadeStart {
                fadeGain = fadeOutGain(frame - fadeStart, fadeFrames)
            }
            for c in source.indices {
                let sample = Double(source[c][lead + frame]) * gains[c] * frameDecayGain * fadeGain
                energies[c] += sample * sample
            }
        }
        return Reference(initialGains: initialGains,
                         finalGains: normalizationGains(energies, topology: topology),
                         shape: shape)
    }

    // MARK: - 伸縮

    /// 窓付きsincの形。遮断は低い方のレートのナイキストの0.95倍、Kaiser β=9、片側48回の零交差。
    ///
    /// 44.1kHzの素材で18kHzまで±0.01dB、20kHzで-0.06dB。ナイキストで-58dB、
    /// その2%上から先は-90dBより下。片側32回だとナイキストで-29dBにしかならない。
    static let resamplerCutoff = 0.95
    static let resamplerBeta = 9.0
    static let resamplerZeroCrossings = 48

    /// 1面を伸縮する。中身はresampleChannels。
    static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        resampleChannels([input], from: sourceRate, to: targetRate)[0]
    }

    /// 帯域を切らずに間引く。上流のOfflineAudioContextの再生と同じく、位置i·f0/fcの値を
    /// 線形補間で取る（ir_reverb.js:1507-1529）。整数比（96k→48k、192k→48kなど）なら
    /// 標本をそのまま拾うだけになる。長さはround(n·fc/f0)、端の外は0。
    /// stageが、素材が処理レートそのものでdividerが2・4のときに使う。
    static func pick(_ channels: [[Float]], from sourceRate: Double, to targetRate: Double) -> [[Float]] {
        guard sourceRate.isFinite, targetRate.isFinite, sourceRate > 0, targetRate > 0,
              let frames = channels.first?.count, frames > 0 else { return channels }
        let count = max(1, Int(jsRound(Double(frames) * targetRate / sourceRate)))
        let step = sourceRate / targetRate
        return channels.map { x in
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let position = Double(i) * step
                let k = Int(position.rounded(.down))
                if k >= frames { break }
                let fraction = position - Double(k)
                if fraction == 0 {
                    out[i] = x[k]
                } else {
                    let next = k + 1 < frames ? Double(x[k + 1]) : 0
                    out[i] = Float(Double(x[k]) + (next - Double(x[k])) * fraction)
                }
            }
            return out
        }
    }

    /// 素材のレートから畳み込みのレートへ伸縮する。
    ///
    /// 上流はファイルをdecodeAudioDataでengineのレートへ読み（Chromiumの窓付きsincで変換される）、
    /// そこからOfflineAudioContextでfs/dへ落とす（ir_reverb.js:1480-1529）。落とす方は整数比の
    /// 線形補間なので、標本を拾うだけ。こちらは素材のレートからfcへ1回で行く。
    /// どのdividerでも同じ帯域になるように切り方を決めているのはstage。
    ///
    /// **標本の値を保つ（振幅を保つ）。スケールしない。** 帯域内の音の大きさは変わらず、
    /// Σh²はfc/f0倍になる。それを戻すのは後のprepareの正規化で、fcで測るので
    /// 素材のレートにもdividerにも依らなくなる。先に正規化するとfc/f0が戻ってくる。
    ///
    /// フレーム数は上流と同じround(n·fc/f0)。レートが同じ（丸めて等しい）なら何もしない
    /// （ir_reverb.js:1508）。端の外は0とみなす。
    ///
    /// 帯域はふつう行き先のナイキストで切る（遮断はmin(f0, 行き先)の0.95倍の半分）。
    /// `bandRate`を渡すと、行き先の代わりにそのレートで切る。行き先のナイキストより上に残った分は
    /// 折り返る。stageが上流の「fsへ変換してからd個おきに拾う」を1回でやるのに使う
    /// （bandRateにfsを渡す）。渡したときは、レートが同じでも長さを変えずに帯域を切る。
    static func resampleChannels(_ channels: [[Float]], from sourceRate: Double, to targetRate: Double,
                                 bandRate: Double? = nil) -> [[Float]] {
        guard sourceRate.isFinite, targetRate.isFinite, sourceRate > 0, targetRate > 0,
              let frames = channels.first?.count, frames > 0 else { return channels }
        let sameRate = jsRound(sourceRate) == jsRound(targetRate)
        if sameRate && bandRate == nil { return channels }
        let count = sameRate ? frames : max(1, Int(jsRound(Double(frames) * targetRate / sourceRate)))
        let from = sameRate ? targetRate : sourceRate
        let bank = SincBank(from: from, to: targetRate, band: min(from, bandRate ?? targetRate))
        let slots = Slots(count: channels.count)
        // 面ごとに別のコアで回す。4chを伸縮すると10^8回ほどの積和になる。
        DispatchQueue.concurrentPerform(iterations: channels.count) { c in
            slots.store(bank.run(channels[c], count: count), at: c)
        }
        return slots.values
    }

    /// 面ごとの結果を別々のスレッドから書く置き場。1つの枠に書くのは1つのスレッドだけ。
    /// 配列のバッファをそのまま閉包へ渡すとSwift 6の並行性の検査が通らないので、枠を自前で持つ。
    private final class Slots: @unchecked Sendable {
        private let base: UnsafeMutablePointer<[Float]>
        private let count: Int

        init(count: Int) {
            self.count = count
            base = .allocate(capacity: count)
            base.initialize(repeating: [], count: count)
        }

        deinit {
            base.deinitialize(count: count)
            base.deallocate()
        }

        func store(_ value: [Float], at index: Int) { base[index] = value }

        var values: [[Float]] { Array(UnsafeBufferPointer(start: base, count: count)) }
    }

    /// 位相ごとに係数を先に作っておく。
    ///
    /// 両方のレートが整数なら、比を既約分数L/MにしてL個の位相を正確に持つ
    /// （44.1k→48kでL=160、44.1k→96kでL=320、48k→96kでL=2）。
    /// そうでないときは位相を2048に量子化する（ずれは1/4096標本以下）。
    ///
    /// 表は位相×係数の数で、係数の数は落とす比に比例する。表が`maximumTableEntries`を超えるときは
    /// 位相を減らして量子化する（最低16）。そうなるのは大きく落とすときだけで、そのときは入力の
    /// 標本が出力から見て細かいので、位相を減らしてもずれは出力の標本の1万分の1より小さい。
    private struct SincBank {
        /// 表の上限（Floatの数、4MB）。192kHzまでの素材を44.1kHz以上へ変えるあいだは超えない
        /// （一番大きいのは非整数のレートを4.35倍落とすときの2048×440）。
        static let maximumTableEntries = 1 << 20

        let phases: Int
        let taps: Int
        /// 出力iの最初の係数が掛かる入力の位置はbase - (half - 1)。
        let half: Int
        let coefficients: [Float]
        /// 有理数のとき、出力iの位置はi·down/up（入力の標本）。
        let up: Int
        let down: Int
        let rational: Bool
        /// 有理数でないとき、出力1つで進む入力の標本数。
        let step: Double

        /// `band`は帯域を決めるレート（呼び手がmin(素材, 行き先かfs)を渡す）。
        init(from sourceRate: Double, to targetRate: Double, band: Double) {
            // 遮断（入力の標本あたりの周期）と、片側の長さ（入力の標本）。
            let cutoff = 0.5 * ETIRPreparation.resamplerCutoff * min(sourceRate, band) / sourceRate
            let span = Double(ETIRPreparation.resamplerZeroCrossings) / (2 * cutoff)
            half = Int(span.rounded(.up))
            taps = 2 * half
            step = sourceRate / targetRate

            let phaseBudget = max(16, SincBank.maximumTableEntries / taps)
            if let ratio = SincBank.integerRatio(sourceRate, targetRate), ratio.up <= min(4096, phaseBudget) {
                up = ratio.up
                down = ratio.down
                rational = true
                phases = ratio.up
            } else {
                up = 1
                down = 1
                rational = false
                phases = min(2048, phaseBudget)
            }

            let beta = ETIRPreparation.resamplerBeta
            let window0 = SincBank.besselI0(beta)
            var table = [Float](repeating: 0, count: phases * taps)
            var row = [Double](repeating: 0, count: taps)
            for phase in 0..<phases {
                let fraction = Double(phase) / Double(phases)
                var sum = 0.0
                for m in 0..<taps {
                    // 出力の位置から見た、この係数が掛かる入力の標本の距離。
                    let t = fraction + Double(half - 1 - m)
                    let u = t / span
                    var value = 0.0
                    if abs(u) < 1 {
                        let x = 2 * cutoff * t
                        let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                        value = 2 * cutoff * sinc * SincBank.besselI0(beta * (1 - u * u).squareRoot()) / window0
                    }
                    row[m] = value
                    sum += value
                }
                // 位相ごとに和を1へ揃える。直流が位相によらずそのまま通る。
                for m in 0..<taps { table[phase * taps + m] = Float(row[m] / sum) }
            }
            coefficients = table
        }

        func run(_ input: [Float], count: Int) -> [Float] {
            // 前にhalf-1、後ろにtaps+2の0を足しておくと、係数の窓がはみ出さない。
            let pad = half - 1
            var padded = [Float](repeating: 0, count: input.count + taps + 2 + pad)
            padded.withUnsafeMutableBufferPointer { dst in
                input.withUnsafeBufferPointer { src in
                    if let d = dst.baseAddress, let s = src.baseAddress {
                        (d + pad).update(from: s, count: input.count)
                    }
                }
            }
            var out = [Float](repeating: 0, count: count)
            coefficients.withUnsafeBufferPointer { h in
                padded.withUnsafeBufferPointer { x in
                    out.withUnsafeMutableBufferPointer { y in
                        guard let hp = h.baseAddress, let xp = x.baseAddress else { return }
                        let limit = x.count - taps
                        for i in 0..<count {
                            var base: Int
                            var phase: Int
                            if rational {
                                let position = i * down
                                base = position / up
                                phase = position % up
                            } else {
                                let position = Double(i) * step
                                base = Int(position.rounded(.down))
                                phase = Int(((position - Double(base)) * Double(phases)).rounded())
                                if phase == phases { phase = 0; base += 1 }
                            }
                            if base > limit { base = limit }
                            y[i] = SincBank.dot(xp + base, hp + phase * taps, taps)
                        }
                    }
                }
            }
            return out
        }

        /// 4本に分けて足す（1本だと足し算の待ちで詰まる）。
        @inline(__always)
        private static func dot(_ x: UnsafePointer<Float>, _ h: UnsafePointer<Float>, _ n: Int) -> Float {
            var a0: Float = 0, a1: Float = 0, a2: Float = 0, a3: Float = 0
            var k = 0
            while k + 4 <= n {
                a0 += x[k] * h[k]
                a1 += x[k + 1] * h[k + 1]
                a2 += x[k + 2] * h[k + 2]
                a3 += x[k + 3] * h[k + 3]
                k += 4
            }
            while k < n {
                a0 += x[k] * h[k]
                k += 1
            }
            return (a0 + a1) + (a2 + a3)
        }

        /// 両方が整数のレートなら、target/sourceを既約分数up/downで返す。
        private static func integerRatio(_ source: Double, _ target: Double) -> (up: Int, down: Int)? {
            let s = source.rounded()
            let t = target.rounded()
            guard abs(source - s) < 1e-9, abs(target - t) < 1e-9,
                  s >= 1, t >= 1, s < 1e9, t < 1e9 else { return nil }
            let sourceRate = Int(s)
            let targetRate = Int(t)
            var a = sourceRate
            var b = targetRate
            while b != 0 { (a, b) = (b, a % b) }
            return (targetRate / a, sourceRate / a)
        }

        /// 第1種変形ベッセル関数I0。Kaiser窓に使う。
        private static func besselI0(_ x: Double) -> Double {
            let quarter = x * x / 4
            var sum = 1.0
            var term = 1.0
            var k = 1.0
            while term > 1e-17 * sum {
                term *= quarter / (k * k)
                sum += term
                k += 1
            }
            return sum
        }
    }
}
