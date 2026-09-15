//  GroupDelayPEQDesigner.swift
//  Group Delay PEQ（GroupDelayPEQPlugin）の係数を Swift で設計して instance へ送る。
//
//  カーネルは出来上がった FIR 係数を受け取るだけで、係数の設計は JS 側にある。
//  移したのは Vendor/effetune/js/group-delay-peq/design-core.js（368 行）で、
//  中身は「群遅延だけを目標の形にする有限長オールパス FIR」の設計。
//  振幅は平らなまま、位相だけを曲げる。
//
//  --- カーネルが資産として何を期待しているか ---
//  読み取り側は dsp/plugins/eq/group_delay_peq/kernel.cpp。
//
//    assetCapacity      kernel.cpp:49-51    slot 0 だけ。上限 32MiB（同 17 行）
//    beginAsset         kernel.cpp:170-212  staging を確保して番地を返す
//    validateBegin      kernel.cpp:266-280  channels=1 / topology=1(mono) /
//                                           frames は 1〜131072 /
//                                           headBlock は 0,128,256,512,1024 のどれか /
//                                           rateDivider=1 / pathCount=0 / inputCount=0 /
//                                           byteSize == 32 + channels*frames*4 /
//                                           footprintBytes >= byteSize かつ <= 32MiB /
//                                           params_.filterDelaySamples が 0〜65536
//    commitAsset        kernel.cpp:214-241  formatTag は ET_ASSET_F32_MULTICH(1) だけ。
//                                           係数の本体は staging の +32 バイトから読む（同 223）
//    validatePayload    kernel.cpp:282-289  ペイロードの頭 32 バイトを 1 語ずつ検める
//
//  --- ペイロードの並び（頭 32 バイト＋係数）---
//  書き手 js/ir-library/ir-asset-payload.js:76-95 と
//  読み手 kernel.cpp:282-289 が同じことを言っている。リトルエンディアン。
//
//    +0   u32  0x31415445
//    +4   u32  channels        → この効果は必ず 1（kernel.cpp:267）
//    +8   u32  frames          → タップ数（4096 / 8192 / 16384 / 32768）
//    +12  u32  sampleRate      → engine の sample_rate_ を丸めた整数（kernel.cpp:286）
//    +16  u32  topology        → 1 = mono（kernel.cpp:287）
//    +20  u32  0               → matrix ではないので path は無い
//    +24  u32  0
//    +28  u32  0
//    +32  f32 × frames         → 係数（1 チャンネルなので channel-major は自明）
//
//  組み立てと送り込みは AssetUpload に全部ある。ここでは係数を作って渡すだけ。
//
//  --- パラメータ（params.json）---
//  dsp/plugins/eq/group_delay_peq/params.json:8-11 の fields は 2 つしか無い。
//  バンドの形（t/f/d/q/e）とタップ数は DSP へ渡らない。渡るのは資産だけ。
//
//    latencyMode        lt  enum ["0","128","256","512","1024"]  → 添字を float で渡す
//                           （js/audio/dsp-params.generated.js:676 が indexOf を取っている）
//    filterDelaySamples fd  int 0〜65536 → **タップ数の半分**
//                           （plugins/eq/group_delay_peq.js:161-167 の _packedParameters）
//
//  fd は遅延の申告にしか使われない（kernel.cpp:207 candidate_latency_ =
//  headBlock + filterDelaySamples）。オールパスの山が taps/2 にあるので、
//  そこを「遅れ」として鎖に申告し、他のエフェクトと頭を揃える。
//  beginAsset は入口で applyPendingParameters を呼ぶ（kernel.cpp:171）ので、
//  **資産より先にパラメータを入れる**。逆にすると遅延の申告が 1 回ぶんずれる。
//
//  --- 重さ ---
//  JS は Worker でやっている（js/group-delay-peq/design-worker.js）。理由は重いから。
//  32768 タップだと 65536 点の実数 FFT を、投影 12 回ぶんで最大 25 回まわす。
//  ここも同じ扱いにして Task.detached へ出す。音のスレッドでは絶対にやらない。
//
//  --- 数の扱い ---
//  JS の Number は double。途中は Double で回して、カーネルへ渡す直前に Float へ落とす。

import Foundation
import os

// MARK: - バンド

/// バンド 1 本。JS は t/f/d/q/e の 5 つを持つ（plugins/eq/group_delay_peq.js:125-133）。
struct GroupDelayPEQBand: Equatable, Sendable {

    /// 形。design-core.js:17 の GROUP_DELAY_PEQ_TYPES と同じ並び。
    enum Shape: String, CaseIterable, Sendable {
        case peak = "pk"
        case lowShelf = "ls"
        case highShelf = "hs"
        case filterGD = "fl"

        /// 画面に出す名前。group_delay_peq.js:22-27 の 8 文字の名前をそのまま写した。
        var label: String {
            switch self {
            case .peak: return "Peak"
            case .lowShelf: return "LowShelv"
            case .highShelf: return "HighShel"
            case .filterGD: return "FilterGD"
            }
        }
    }

    var shape: Shape
    /// Hz。20〜20000 に収められる。
    var frequency: Double
    /// ms。正で遅らせ、負で早める。タップ数から決まる限界で切られる。
    var delayMs: Double
    var q: Double
    var enabled: Bool

    init(shape: Shape = .peak,
         frequency: Double,
         delayMs: Double = 0,
         q: Double = 0.7,
         enabled: Bool = true) {
        self.shape = shape
        self.frequency = frequency
        self.delayMs = delayMs
        self.q = q
        self.enabled = enabled
    }
}

// MARK: - 設計の入力

/// 係数を作るのに要るもの一式。
struct GroupDelayPEQSettings: Equatable, Sendable {

    /// 既定の 5 本。group_delay_peq.js:9-15 の BANDS。
    static let defaultFrequencies: [Double] = [100, 316, 1000, 3160, 10000]

    static var defaultBands: [GroupDelayPEQBand] {
        defaultFrequencies.map { GroupDelayPEQBand(frequency: $0) }
    }

    var bands: [GroupDelayPEQBand]
    /// 4096 / 8192 / 16384 / 32768 のどれか。
    var taps: Int
    /// lt。0 / 128 / 256 / 512 / 1024。資産の headBlock にもそのまま渡る。
    var latencySamples: Int
    /// engine に渡したレート。AudioIO.shared.processingRate と同じ値でないと
    /// カーネルの validatePayload（kernel.cpp:286）で弾かれる。
    var sampleRate: Double
    /// この効果が処理するチャンネル数。鎖の channelSpec から決まる。
    var processingChannels: Int

    init(bands: [GroupDelayPEQBand] = GroupDelayPEQSettings.defaultBands,
         taps: Int = 16384,
         latencySamples: Int = 128,
         sampleRate: Double = 48000,
         processingChannels: Int = 2) {
        self.bands = bands
        self.taps = taps
        self.latencySamples = latencySamples
        self.sampleRate = sampleRate
        self.processingChannels = processingChannels
    }

    /// 1 本でも遅延を頼んでいるか。全部 0 なら素通しでよい（group_delay_peq.js:157-159）。
    var hasDelay: Bool {
        bands.contains { $0.enabled && $0.delayMs != 0 }
    }

    /// タップ数から決まる遅延の限界（ms）。group_delay_peq.js:139-141 と
    /// design-core.js:134-137 が同じ式を書いている。0.1ms 刻みに切り下げる。
    var delayLimitMs: Double {
        let limitSamples = Double(taps) / 2 - Double(taps) / 16
        return (limitSamples * 1000 / sampleRate * 10).rounded(.down) / 10
    }

    /// 鎖に申告される遅延（サンプル）。kernel.cpp:207 と同じ足し算。
    var reportedLatencySamples: Int {
        latencySamples + taps / 2
    }

    /// 限界を超えている遅延を切る。タップ数やレートを変えたときに呼ぶ
    /// （group_delay_peq.js:147-154 の _clampDelaysToLimit）。
    func clampingDelaysToLimit() -> GroupDelayPEQSettings {
        let limit = delayLimitMs
        var copy = self
        for index in copy.bands.indices {
            if copy.bands[index].delayMs > limit {
                copy.bands[index].delayMs = limit
            } else if copy.bands[index].delayMs < -limit {
                copy.bands[index].delayMs = -limit
            }
        }
        return copy
    }

    /// 係数を作り直さないといけない変化か。
    /// JS は _designSignature（group_delay_peq.js:262-266）で見ていて、そこには
    /// チャンネル数も入っている。ただし係数はチャンネル数に依らないので、
    /// こちらは送り直しだけで済ませる。出てくる係数は同じ。
    func requiresRedesign(comparedTo other: GroupDelayPEQSettings) -> Bool {
        bands != other.bands || taps != other.taps || sampleRate != other.sampleRate
    }

    /// 鎖の channelSpec から、この効果が触るチャンネル数を出す。
    /// engine.cpp:759-766 の routed_channels と同じ場合分け
    /// （js の selectedIrChannelCount, ir-plugin-contract.js:26-39 に当たる）。
    ///   -2 = All → engine のチャンネル数 / -1 = Stereo → 2
    ///   0〜15 = 1 本だけ → 1 / 16〜23 = 対 → 2
    static func processingChannels(channelSpec: Int8, engineChannels: Int = 2) -> Int {
        switch channelSpec {
        case -2: return engineChannels
        case -1: return 2
        case 16...23: return 2
        default: return 1
        }
    }
}

// MARK: - 設計の結果

/// 設計して測ったもの。design-worker.js:14-28 が Worker から返しているのと同じ中身。
struct GroupDelayPEQDesign: Sendable {

    /// 目標と実現の曲線。128 点（design-core.js:25 RESPONSE_POINTS）。
    struct Response: Sendable {
        let frequencies: [Double]
        let targetMs: [Double]
        let realizedMs: [Double]
    }

    /// 係数。長さはタップ数。
    let ir: [Float]
    /// オールパスの山の位置。taps/2。
    let bulkDelaySamples: Int
    /// 頼まれた遅延が限界で切られたか。
    let clamped: Bool
    let limitMs: Double
    /// 実現した振幅の暴れ（dB）。平らなはずのものがどれだけ暴れたか。
    let rippleDb: Double
    let response: Response
}

enum GroupDelayPEQDesignError: Error, LocalizedError {
    case unsupportedTaps(Int)
    case invalidSampleRate(Double)
    case fftUnavailable(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedTaps:
            return "This tap count is not supported."
        case .invalidSampleRate:
            return "The sample rate is not valid."
        case .fftUnavailable:
            return "The filter length is too large for this device."
        case .cancelled:
            return "The filter design was replaced by a newer one."
        }
    }
}

// MARK: - 目標の曲線

/// 目標の群遅延（ms）を周波数から返すもの。design-core.js:178-199 createTargetCurve。
///
/// JS は clipState を外から渡して、評価した後に読んでいる。同じことをするために
/// 値型ではなく class にしてある（`clamped` は評価した後に読む）。
final class GroupDelayPEQTargetCurve {

    fileprivate let bands: [PreparedBand]
    let limitMs: Double
    private let fadeStart: Double
    private let fadeEnd: Double

    /// ±limitMs で切られたか。
    private(set) var clamped: Bool

    fileprivate init(bands: [PreparedBand], sampleRate: Double, limitMs: Double, clamped: Bool) {
        self.bands = bands
        self.limitMs = limitMs
        self.clamped = clamped
        let nyquist = sampleRate / 2
        let end = min(GroupDelayPEQDesignCore.responseHighFrequency, nyquist * 0.9)
        self.fadeEnd = end
        self.fadeStart = end * 0.9
    }

    /// design-core.js:182-198。
    /// 20Hz より下は 20Hz の値で止める（曲線が bin 0 から始まるので、そこを有限にする）。
    func value(at frequency: Double) -> Double {
        if frequency >= fadeEnd { return 0 }
        let low = GroupDelayPEQDesignCore.responseLowFrequency
        let held = frequency > low ? frequency : low
        var value = 0.0
        for band in bands {
            value += GroupDelayPEQDesignCore.shape(held, band)
        }
        if value > limitMs {
            value = limitMs
            clamped = true
        } else if value < -limitMs {
            value = -limitMs
            clamped = true
        }
        if frequency > fadeStart {
            value *= 0.5 + 0.5 * cos(Double.pi * (frequency - fadeStart) / (fadeEnd - fadeStart))
        }
        return value
    }
}

/// 型ごとの定数を先に作り込んだバンド。design-core.js:75-118 の prepare が入れるもの。
fileprivate struct PreparedBand {
    let shape: GroupDelayPEQBand.Shape
    let frequency: Double
    let delayMs: Double
    let q: Double
    let logFrequency: Double
    var bellScale: Double = 0
    var shelfSlope: Double = 0
    var angularFrequency: Double = 0
    var filterGdNormalization: Double = 0
}

// MARK: - 設計そのもの

/// design-core.js をそのまま移したもの。状態を持たないので、どのスレッドから呼んでもよい。
enum GroupDelayPEQDesignCore {

    // --- design-core.js:16-38 の定数。値をそのまま写した ---

    static let bandCount = 5
    static let tapsChoices: [Int] = [4096, 8192, 16384, 32768]
    /// lt の選択肢。group_delay_peq.js:30、params.json:9。**添字がそのまま渡る値**。
    static let latencyChoices: [Int] = [0, 128, 256, 512, 1024]
    static let minimumFrequency = 20.0
    static let maximumFrequency = 20000.0
    static let minimumQ = 0.1
    static let maximumQ = 100.0

    static let designIterations = 12
    static let spectrumOversampling = 2
    static let guardDivisor = 16.0
    static let responsePoints = 128
    static let responseLowFrequency = 20.0
    static let responseHighFrequency = 20000.0
    /// 図の横軸。design-core.js:29-30。
    static let responseGridLowFrequency = 10.0
    static let responseGridHighFrequency = 40000.0
    static let magnitudeEpsilon = 1e-12
    /// これより Q が低いと 2 次の群遅延は単調で、極値は DC の平らな所にある。
    /// u^2 + 2u + (1/Q^2 - 3) = 0 が実解を持つ境目（design-core.js:32-37）。
    static let filterGdMonotonicQ = 1.0 / sqrt(3.0)
    /// Math.LN2。
    static let lnTwo = 0.6931471805599453
    /// Math.log(4)。design-core.js:38 の LOG_OF_FOUR。
    static let logOfFour = 1.3862943611198906
    /// 暴れがこれを超えたら注意を出す。group_delay_peq.js:34。
    static let rippleWarningDb = 0.3

    // MARK: 2 次の群遅延

    /// 分母が s^2 + (w0/Q)s + w0^2 の 2 次の群遅延（秒）。design-core.js:45-54。
    /// 分子（LPF/HPF/BPF）は効かない。DC では 1/(Q*w0) になり、場合分けは要らない。
    fileprivate static func secondOrderGroupDelay(_ frequency: Double, _ band: PreparedBand) -> Double {
        let omega = 2 * Double.pi * frequency
        let omegaSquared = omega * omega
        let centre = band.angularFrequency
        let centreSquared = centre * centre
        let difference = centreSquared - omegaSquared
        let damping = centre * omega / band.q
        return (centre / band.q) * (omegaSquared + centreSquared) /
            (difference * difference + damping * damping)
    }

    /// 2 次の群遅延が極値を取る周波数。閉じた形で出す（design-core.js:62-67）。
    /// 走査で探してはいけない。Q が高いと山はどんな刻みより狭く、見落とすと
    /// |曲線| <= |d| が崩れる。
    fileprivate static func filterGdExtremumFrequency(_ band: PreparedBand, nyquist: Double) -> Double {
        if band.q <= filterGdMonotonicQ { return 0 }
        let extremum = sqrt(4 - 1 / (band.q * band.q)) - 1
        let frequency = band.frequency * sqrt(extremum)
        return frequency > nyquist ? nyquist : frequency
    }

    // MARK: 型ごとの形

    /// design-core.js:75-118 の BAND_SHAPES の prepare。
    fileprivate static func prepare(_ band: inout PreparedBand, nyquist: Double) {
        switch band.shape {
        case .peak:
            // 半値全幅が BW になる log2 軸のガウス。
            let bandwidth = (2 / lnTwo) * asinh(1 / (2 * band.q))
            band.bellScale = 2 / bandwidth
        case .lowShelf, .highShelf:
            band.shelfSlope = band.q * logOfFour
        case .filterGD:
            band.angularFrequency = 2 * Double.pi * band.frequency
            let extremum = filterGdExtremumFrequency(band, nyquist: nyquist)
            let normalization = 1 / secondOrderGroupDelay(extremum, band)
            band.filterGdNormalization = normalization
        }
    }

    /// design-core.js:75-118 の BAND_SHAPES の shape。返すのは ms。
    fileprivate static func shape(_ frequency: Double, _ band: PreparedBand) -> Double {
        switch band.shape {
        case .peak:
            let position = band.bellScale * (log2(frequency) - band.logFrequency)
            return band.delayMs * exp(-lnTwo * position * position)
        case .lowShelf:
            // d / (1 + 4^(Q*x))。低い所で d、band の周波数で d/2、高い所で 0。
            let position = log2(frequency) - band.logFrequency
            return band.delayMs / (1 + exp(band.shelfSlope * position))
        case .highShelf:
            // Low Shelf の鏡像。
            let position = band.logFrequency - log2(frequency)
            return band.delayMs / (1 + exp(band.shelfSlope * position))
        case .filterGD:
            // 極値が d になるように正規化した 2 次の群遅延。
            return band.delayMs * secondOrderGroupDelay(frequency, band) * band.filterGdNormalization
        }
    }

    // MARK: バンドを整える

    fileprivate struct Normalized {
        let bands: [PreparedBand]
        let clamped: Bool
        let limitMs: Double
    }

    /// design-core.js:133-167 normalizeBands。
    /// 切ってあるバンドは何にも寄与しない。有効でも遅延 0 のものは和から落ちるだけで、
    /// 限界との比較はその前に済んでいる。
    fileprivate static func normalizeBands(_ bands: [GroupDelayPEQBand],
                                           taps: Int,
                                           sampleRate: Double) -> Normalized {
        let limitSamples = Double(taps) / 2 - Double(taps) / guardDivisor
        // 0.1ms 刻みに切り下げる。設計が言う限界と、画面の入力欄の最大値を揃えるため。
        let limitMs = (limitSamples * 1000 / sampleRate * 10).rounded(.down) / 10
        let nyquist = sampleRate / 2
        var prepared = [PreparedBand]()
        var clamped = false
        for entry in bands {
            if !entry.enabled { continue }
            let requestedFrequency = entry.frequency.isFinite ? entry.frequency : minimumFrequency
            let frequency = clamp(requestedFrequency, minimumFrequency, maximumFrequency)
            let requestedQ = entry.q.isFinite ? entry.q : 0.7
            let q = clamp(requestedQ, minimumQ, maximumQ)
            let delay = entry.delayMs.isFinite ? entry.delayMs : 0
            let bounded = clamp(delay, -limitMs, limitMs)
            if bounded != delay { clamped = true }
            if bounded == 0 { continue }
            var band = PreparedBand(shape: entry.shape,
                                    frequency: frequency,
                                    delayMs: bounded,
                                    q: q,
                                    logFrequency: log2(frequency))
            prepare(&band, nyquist: nyquist)
            prepared.append(band)
        }
        return Normalized(bands: prepared, clamped: clamped, limitMs: limitMs)
    }

    fileprivate static func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        if value < minimum { return minimum }
        if value > maximum { return maximum }
        return value
    }

    // MARK: 図と測定の周波数

    /// 図と同じ横軸。design-core.js:209-217。
    /// 上は 0.45fs で頭打ちにする。そこから上は測るものが無い。
    static func responseFrequencies(sampleRate: Double) -> [Double] {
        let highest = min(responseGridHighFrequency, sampleRate * 0.45)
        let ratio = log10(highest / responseGridLowFrequency) / Double(responsePoints - 1)
        var frequencies = [Double](repeating: 0, count: responsePoints)
        for point in 0..<responsePoints {
            frequencies[point] = responseGridLowFrequency * pow(10, ratio * Double(point))
        }
        return frequencies
    }

    /// 目標の群遅延（ms）。図を描くのに使う。design-core.js:223-230。
    /// frequencies を渡さなければ上の 128 点を使う。
    static func targetMs(bands: [GroupDelayPEQBand],
                         taps: Int = 16384,
                         sampleRate: Double = 48000,
                         frequencies: [Double]? = nil) -> [Double] {
        let normalized = normalizeBands(bands, taps: taps, sampleRate: sampleRate)
        let curve = GroupDelayPEQTargetCurve(bands: normalized.bands,
                                             sampleRate: sampleRate,
                                             limitMs: normalized.limitMs,
                                             clamped: false)
        let grid = frequencies ?? responseFrequencies(sampleRate: sampleRate)
        return grid.map { curve.value(at: $0) }
    }

    // MARK: 目標のスペクトル

    fileprivate struct TargetSpectrum {
        let real: [Double]
        let imag: [Double]
        let curve: GroupDelayPEQTargetCurve
        let limitMs: Double
        let bulkDelaySamples: Int
    }

    /// 理想のオールパス。一定の山（taps/2）＋頼まれたぶんのずれ。
    /// design-core.js:236-261 buildTargetSpectrum。
    fileprivate static func buildTargetSpectrum(bands: [GroupDelayPEQBand],
                                                taps: Int,
                                                sampleRate: Double,
                                                size: Int) -> TargetSpectrum {
        let normalized = normalizeBands(bands, taps: taps, sampleRate: sampleRate)
        let curve = GroupDelayPEQTargetCurve(bands: normalized.bands,
                                             sampleRate: sampleRate,
                                             limitMs: normalized.limitMs,
                                             clamped: normalized.clamped)
        let bulkDelaySamples = taps / 2
        let samplesPerMillisecond = sampleRate / 1000
        let bins = size / 2 + 1
        var real = [Double](repeating: 0, count: bins)
        var imag = [Double](repeating: 0, count: bins)
        let step = 2 * Double.pi / Double(size)
        var deviationPhase = 0.0
        var previous = curve.value(at: 0) * samplesPerMillisecond
        real[0] = 1
        for bin in 1..<bins {
            let frequency = Double(bin) * sampleRate / Double(size)
            let deviation = curve.value(at: frequency) * samplesPerMillisecond
            // 群遅延を台形で積んで位相にする。
            deviationPhase += 0.5 * (previous + deviation) * step
            previous = deviation
            let phase = -(step * Double(bin) * Double(bulkDelaySamples) + deviationPhase)
            real[bin] = cos(phase)
            imag[bin] = sin(phase)
        }
        // 実数列のナイキストの bin に虚部は無い。
        real[bins - 1] = real[bins - 1] < 0 ? -1 : 1
        imag[bins - 1] = 0
        return TargetSpectrum(real: real,
                              imag: imag,
                              curve: curve,
                              limitMs: normalized.limitMs,
                              bulkDelaySamples: bulkDelaySamples)
    }

    // MARK: 設計

    /// オールパス FIR を設計して、有限のタップ数で実際に何が出たかを測る。
    /// design-core.js:274-314 designGroupDelayPeqFilter。
    ///
    /// 長さの条件（taps より後ろは 0）と振幅の条件（絶対値 1）を交互に当てて、
    /// 無限に長い理想のオールパスを頼まれた長さへ畳み込む。
    ///
    /// - Parameter shouldStop: 途中で捨ててよいか。呼ぶ側が新しい設計を始めたときに true。
    static func design(settings: GroupDelayPEQSettings,
                       iterations: Int = designIterations,
                       shouldStop: () -> Bool = { false }) throws -> GroupDelayPEQDesign {
        let taps = settings.taps
        guard tapsChoices.contains(taps) else {
            throw GroupDelayPEQDesignError.unsupportedTaps(taps)
        }
        let sampleRate = settings.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw GroupDelayPEQDesignError.invalidSampleRate(sampleRate)
        }
        let size = taps * spectrumOversampling
        guard let fft = FIRDesign.fft(size: size) else {
            throw GroupDelayPEQDesignError.fftUnavailable(size)
        }

        let target = buildTargetSpectrum(bands: settings.bands,
                                         taps: taps,
                                         sampleRate: sampleRate,
                                         size: size)

        var impulse = fft.inverseRealTransform(real: target.real, imag: target.imag)
        for _ in 0..<iterations {
            if shouldStop() { throw GroupDelayPEQDesignError.cancelled }
            zeroTail(&impulse, from: taps)
            var spectrum = fft.realTransform(impulse)
            var converged = true
            for bin in 0..<spectrum.real.count {
                let real = spectrum.real[bin]
                let imag = spectrum.imag[bin]
                let magnitude = (real * real + imag * imag).squareRoot()
                if magnitude < magnitudeEpsilon { continue }
                if magnitude > 1.0001 || magnitude < 0.9999 { converged = false }
                spectrum.real[bin] = real / magnitude
                spectrum.imag[bin] = imag / magnitude
            }
            if converged { break }
            impulse = fft.inverseRealTransform(real: spectrum.real, imag: spectrum.imag)
        }
        zeroTail(&impulse, from: taps)

        var ir = [Float](repeating: 0, count: taps)
        for index in 0..<taps {
            ir[index] = Float(impulse[index])
        }

        let measured = measureResponse(ir: ir,
                                       target: target,
                                       size: size,
                                       sampleRate: sampleRate,
                                       fft: fft)
        // clamped は測り終えてから読む。図の格子の上でも切られることがあるので、
        // JS も measureResponse の後で clampState を読んでいる（design-core.js:363）。
        return GroupDelayPEQDesign(ir: ir,
                                   bulkDelaySamples: target.bulkDelaySamples,
                                   clamped: target.curve.clamped,
                                   limitMs: target.limitMs,
                                   rippleDb: measured.rippleDb,
                                   response: measured.response)
    }

    private static func zeroTail(_ values: inout [Double], from index: Int) {
        guard index < values.count else { return }
        for position in index..<values.count {
            values[position] = 0
        }
    }

    // MARK: 測る

    fileprivate struct Measured {
        let rippleDb: Double
        let response: GroupDelayPEQDesign.Response
    }

    /// 出来上がった係数の振幅の暴れと群遅延。design-core.js:321-368 measureResponse。
    /// 群遅延は「傾斜をかけた変換との比」で出す。位相をほどかなくて済む。
    fileprivate static func measureResponse(ir: [Float],
                                            target: TargetSpectrum,
                                            size: Int,
                                            sampleRate: Double,
                                            fft: FIRDesign.RealFFT) -> Measured {
        var impulse = [Double](repeating: 0, count: size)
        var ramped = [Double](repeating: 0, count: size)
        for index in 0..<ir.count {
            let value = Double(ir[index])
            impulse[index] = value
            ramped[index] = value * Double(index)
        }
        let spectrum = fft.realTransform(impulse)
        let rampedSpectrum = fft.realTransform(ramped)
        let bins = spectrum.real.count
        let bulkDelaySamples = Double(target.bulkDelaySamples)
        var magnitudeDb = [Double](repeating: 0, count: bins)
        var delaySamples = [Double](repeating: 0, count: bins)
        for bin in 0..<bins {
            let real = spectrum.real[bin]
            let imag = spectrum.imag[bin]
            let power = real * real + imag * imag
            magnitudeDb[bin] = 10 * log10(power > magnitudeEpsilon ? power : magnitudeEpsilon)
            delaySamples[bin] = power > magnitudeEpsilon
                ? (rampedSpectrum.real[bin] * real + rampedSpectrum.imag[bin] * imag) / power
                : bulkDelaySamples
        }

        let frequencies = responseFrequencies(sampleRate: sampleRate)
        var targetMs = [Double](repeating: 0, count: frequencies.count)
        var realizedMs = [Double](repeating: 0, count: frequencies.count)
        let millisecondsPerSample = 1000 / sampleRate
        var rippleDb = 0.0
        for point in 0..<frequencies.count {
            let frequency = frequencies[point]
            targetMs[point] = target.curve.value(at: frequency)
            let realized = sampleAtFrequency(delaySamples,
                                             frequency: frequency,
                                             size: size,
                                             sampleRate: sampleRate)
            realizedMs[point] = (realized - bulkDelaySamples) * millisecondsPerSample
            // 暴れは設計の帯についての言い分なので、図のために足した外側の点は
            // 描くだけで数えない。
            if frequency < responseLowFrequency || frequency > responseHighFrequency { continue }
            let deviation = sampleAtFrequency(magnitudeDb,
                                              frequency: frequency,
                                              size: size,
                                              sampleRate: sampleRate)
            let absolute = deviation < 0 ? -deviation : deviation
            if absolute > rippleDb { rippleDb = absolute }
        }

        let response = GroupDelayPEQDesign.Response(frequencies: frequencies,
                                                    targetMs: targetMs,
                                                    realizedMs: realizedMs)
        return Measured(rippleDb: rippleDb, response: response)
    }

    /// bin の間を線で結んで読む。design-core.js:263-269。
    fileprivate static func sampleAtFrequency(_ values: [Double],
                                              frequency: Double,
                                              size: Int,
                                              sampleRate: Double) -> Double {
        guard let last = values.last else { return 0 }
        let position = frequency * Double(size) / sampleRate
        let lowerIndex = Int(position.rounded(.down))
        // JS は添字が外れると undefined を返して NaN になる。ここでは端で止める。
        guard lowerIndex >= 0 else { return values[0] }
        let upperIndex = lowerIndex + 1
        if upperIndex >= values.count { return last }
        let lower = values[lowerIndex]
        return lower + (values[upperIndex] - lower) * (position - Double(lowerIndex))
    }
}

// MARK: - 設計して送り込む

/// 設計した結果を detached から持ち帰るための入れ物。
private enum GroupDelayPEQOutcome: Sendable {
    case designed(GroupDelayPEQDesign)
    case cancelled
    case failed(String)
}

/// パラメータを受け取り、係数を作って instance へ送るところまでを持つ。
///
/// **設計は音のスレッドでやらない。** Task.detached へ出して、出来上がってから送る
/// （送り込みは AssetUpload が bypass を上げて UI スレッドで行う）。
@MainActor
final class GroupDelayPEQDesigner: ObservableObject {

    /// 画面に出す状態。文言は英語。
    enum Status: Equatable {
        /// まだ instance に繋がっていない。
        case detached
        /// 全部 0 ms。素通し。
        case flat
        case designing
        case staging
        /// 送り込んだが、まだ音が通っていないので効き始めていない。
        case staged
        case ready(warning: String?)
        case failed(String)

        var message: String {
            switch self {
            case .detached:
                return "Not connected to the audio engine."
            case .flat:
                return "All bands are at 0 ms, so audio passes through unchanged."
            case .designing:
                return "Designing filter…"
            case .staging:
                return "Loading the filter…"
            case .staged:
                return "The filter starts once audio is playing."
            case .ready(let warning):
                return warning ?? "The filter is ready."
            case .failed(let message):
                return message
            }
        }

        var isWarning: Bool {
            if case .ready(let warning) = self { return warning != nil }
            return false
        }

        var isError: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .detached
    /// いちばん新しく出来上がった設計。図を描くのに使える。
    @Published private(set) var design: GroupDelayPEQDesign?
    @Published private(set) var settings: GroupDelayPEQSettings

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "gdpeq")
    private let slot: UInt32 = 0

    private var engine: UInt32 = 0
    private var instance: UInt32 = 0
    /// 鎖での位置。パラメータを入れるのと、送った後に publish し直すのに要る。
    private var nodeIndex: Int?

    /// いま走っている仕事。新しい設定が来たら捨てる。
    private var work: Task<Void, Never>?
    private var designWork: Task<GroupDelayPEQOutcome, Never>?
    private var generation = 0
    /// 送り込んだときの設定。
    private var stagedSettings: GroupDelayPEQSettings?

    init(settings: GroupDelayPEQSettings = GroupDelayPEQSettings()) {
        self.settings = settings
    }

    // MARK: 繋ぐ

    /// instance に繋ぐ。鎖に足した直後と、engine を用意し直した後に呼ぶ。
    func attach(engine: UInt32, instance: UInt32, nodeIndex: Int?) {
        self.engine = engine
        self.instance = instance
        self.nodeIndex = nodeIndex
        guard engine != 0, instance != 0 else {
            status = .detached
            return
        }
        // 繋ぎ直したら資産は残っていないものとして送り直す。
        stagedSettings = nil
        start(debounce: 0)
    }

    func detach() {
        work?.cancel()
        designWork?.cancel()
        work = nil
        designWork = nil
        engine = 0
        instance = 0
        nodeIndex = nil
        stagedSettings = nil
        status = .detached
    }

    // MARK: 設定を変える

    /// 設定を入れ替える。要るときだけ設計し直して、送り直す。
    /// 触るたびに呼んでよい（150ms 待ってから走る。JS の _scheduleDesign と同じ）。
    func update(_ next: GroupDelayPEQSettings, debounce: TimeInterval = 0.15) {
        let previous = settings
        settings = next
        if design != nil && next.requiresRedesign(comparedTo: previous) {
            design = nil
        }
        start(debounce: design == nil ? debounce : 0)
    }

    /// バンド 1 本だけ差し替える。
    func setBand(_ index: Int, _ band: GroupDelayPEQBand, debounce: TimeInterval = 0.15) {
        guard settings.bands.indices.contains(index) else { return }
        var next = settings
        next.bands[index] = band
        update(next, debounce: debounce)
    }

    /// タップ数を変える。入りきらない遅延はその場で切る（group_delay_peq.js:235-236）。
    func setTaps(_ taps: Int) {
        guard GroupDelayPEQDesignCore.tapsChoices.contains(taps) else { return }
        var next = settings
        next.taps = taps
        update(next.clampingDelaysToLimit(), debounce: 0)
    }

    /// lt を変える。係数は変わらないので送り直すだけ（group_delay_peq.js:240）。
    func setLatencySamples(_ samples: Int) {
        guard GroupDelayPEQDesignCore.latencyChoices.contains(samples) else { return }
        var next = settings
        next.latencySamples = samples
        update(next, debounce: 0)
    }

    /// engine のレートが変わったとき。AudioIO.shared.processingRate を渡す。
    func setSampleRate(_ sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate != settings.sampleRate else { return }
        var next = settings
        next.sampleRate = sampleRate
        update(next.clampingDelaysToLimit(), debounce: 0)
    }

    // MARK: 画面に出す文字

    /// JS の details 行（group_delay_peq.js:616-629）と同じもの。
    var detailText: String {
        let active = design != nil && settings.hasDelay
        let samples = active ? settings.reportedLatencySamples : 0
        let milliseconds = String(format: "%.1f", Double(samples) * 1000 / settings.sampleRate)
        let ripple = String(format: "%.2f", active ? (design?.rippleDb ?? 0) : 0)
        return "Latency \(samples) samples / \(milliseconds) ms · Ripple \(ripple) dB"
    }

    // MARK: 中身

    private func start(debounce: TimeInterval) {
        work?.cancel()
        designWork?.cancel()
        work = nil
        designWork = nil
        generation += 1
        let generation = self.generation
        let settings = self.settings

        guard engine != 0, instance != 0 else {
            status = .detached
            return
        }
        guard settings.hasDelay else {
            // 全部 0 ms。資産を外して素通しに戻す（group_delay_peq.js:309-326 _settleFlat）。
            design = nil
            stagedSettings = nil
            AssetUpload.clear(engine: engine, instance: instance, slot: slot)
            pushParameters(settings)
            republishChain()
            status = .flat
            return
        }

        status = design == nil ? .designing : .staging
        work = Task { [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
                if Task.isCancelled { return }
            }
            await self?.run(settings: settings, generation: generation)
        }
    }

    private func run(settings: GroupDelayPEQSettings, generation: Int) async {
        guard self.generation == generation else { return }

        var designed = design
        if designed == nil {
            // 重いので外へ出す。design-worker.js が Worker でやっているのと同じ意味。
            let task = Task.detached(priority: .userInitiated) { () -> GroupDelayPEQOutcome in
                do {
                    let result = try GroupDelayPEQDesignCore.design(settings: settings,
                                                                    shouldStop: { Task.isCancelled })
                    return .designed(result)
                } catch GroupDelayPEQDesignError.cancelled {
                    return .cancelled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            designWork = task
            let outcome = await task.value
            guard self.generation == generation else { return }
            designWork = nil
            switch outcome {
            case .designed(let result):
                design = result
                designed = result
            case .cancelled:
                return
            case .failed(let message):
                log.error("設計できない \(message, privacy: .public)")
                status = .failed("The filter could not be designed. Try a different tap count.")
                return
            }
        }
        guard let result = designed, self.generation == generation else { return }
        await stage(result, settings: settings, generation: generation)
    }

    private func stage(_ design: GroupDelayPEQDesign,
                       settings: GroupDelayPEQSettings,
                       generation: Int) async {
        guard engine != 0, instance != 0 else { return }
        status = .staging

        // beginAsset は入口で applyPendingParameters を呼ぶ（kernel.cpp:171）。
        // fd（＝タップ数の半分）を先に入れておかないと、遅延の申告が 1 回ぶんずれる。
        pushParameters(settings)

        do {
            try AssetUpload.send(engine: engine,
                                 instance: instance,
                                 slot: slot,
                                 channels: [design.ir],
                                 sampleRate: Int(settings.sampleRate.rounded()),
                                 topology: .mono,
                                 headBlock: UInt32(settings.latencySamples),
                                 rateDivider: 1,
                                 processingChannels: UInt32(settings.processingChannels))
        } catch {
            guard self.generation == generation else { return }
            log.error("送り込めない \(String(describing: error), privacy: .public)")
            status = .failed(error.localizedDescription)
            return
        }
        guard self.generation == generation else { return }
        stagedSettings = settings

        // 資産が入ると instance の遅延が変わる。鎖の遅延合わせは
        // et_pipeline_configure が instanceLatency を数え直して作るので
        // （engine.cpp:648-711 configurePipeline）、ここで publish し直す。
        republishChain()

        // commit の直後は preparing。畳み込み器が分割を積み終えるのは process の中なので、
        // 音が鳴っていないあいだは進まない。期限を切って待つ。
        let state = await AssetUpload.waitForActive(engine: engine,
                                                   instance: instance,
                                                   slot: slot,
                                                   timeout: 2.0)
        guard self.generation == generation else { return }
        if state.isActive {
            status = .ready(warning: warning(for: design))
        } else if state.state == .error {
            log.error("資産が拒まれた reason=\(state.reason)")
            status = .failed("The filter could not be prepared. Try fewer taps or a higher latency.")
        } else {
            status = .staged
        }
    }

    /// group_delay_peq.js:366-377 の _qualityWarning。
    private func warning(for design: GroupDelayPEQDesign) -> String? {
        if design.clamped {
            let limit = String(format: "%.1f", design.limitMs)
            return "This tap count cannot reach the requested delay. "
                + "The filter uses up to \(limit) ms."
        }
        if design.rippleDb > GroupDelayPEQDesignCore.rippleWarningDb {
            return "The filter cannot follow these settings closely. "
                + "Increase the tap count or reduce Q."
        }
        return nil
    }

    /// lt と fd を instance へ入れる。
    /// lt は選択肢の添字（dsp-params.generated.js:676 が indexOf を取っている）、
    /// fd はタップ数の半分（group_delay_peq.js:161-167）。
    private func pushParameters(_ settings: GroupDelayPEQSettings) {
        guard let index = nodeIndex else { return }
        let dsp = EffeTuneDSP.shared
        if let latency = GroupDelayPEQDesignCore.latencyChoices.firstIndex(of: settings.latencySamples) {
            dsp.setValue(Float(latency), at: index, offset: 0)
        }
        dsp.setValue(Float(settings.taps / 2), at: index, offset: 1)
    }

    /// 鎖を publish し直す。EffeTuneDSP に publish だけを呼ぶ口が無いので、
    /// 何も変えない setRouting で代えている（中で publish している）。
    private func republishChain() {
        guard let index = nodeIndex else { return }
        EffeTuneDSP.shared.setRouting(at: index)
    }
}
