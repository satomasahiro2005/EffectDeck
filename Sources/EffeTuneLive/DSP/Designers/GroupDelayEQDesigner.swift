//  GroupDelayEQDesigner.swift
//  Group Delay EQ の係数設計。
//
//  カーネル（dsp/plugins/eq/group_delay_eq/kernel.cpp）は出来上がった FIR を
//  受け取って畳み込むだけで、係数の設計は JS 側にある。その設計を移したもの。
//
//  元:
//    Vendor/effetune/js/group-delay-eq/design-core.js（266 行。全部移した）
//    Vendor/effetune/js/group-delay-eq/design-worker.js（設計→ペイロードの流れ）
//    Vendor/effetune/plugins/eq/group_delay_eq.js（既定値・繋ぎ方・警告の文言）
//
//  何をする設計か:
//    振幅が平らなまま群遅延だけを帯ごとにずらす全域通過 FIR を作る。
//    無限長の理想全域通過を、長さの制約（taps 個で打ち切る）と
//    振幅 1 の制約とのあいだで交互に射影して、有限長へ落とす
//    （design-core.js:4-8 の説明どおり。反復は 12 回）。
//
//  --- カーネルが資産として何を期待しているか ---
//  読み取り側は kernel.cpp の 3 か所。
//
//  validateBegin（kernel.cpp:266-280）:
//    slot == 0 / channels == 1（モノ 1 本だけ）/ frames は 1〜131072 /
//    topology == 1（mono）/ headBlock は 0,128,256,512,1024 のどれか /
//    rateDivider == 1 / pathCount == 0 / inputCount == 0 /
//    processingChannels は 1〜maxChannels /
//    byteSize == 32 + channels * frames * 4 /
//    footprintBytes は byteSize 以上 32MiB 以下 /
//    さらに **params の filterDelaySamples が 0〜65536 であること**。
//    beginAsset は冒頭で applyPendingParameters() を呼ぶ（kernel.cpp:171）ので、
//    資産を送る前に params を入れておかないとここで弾かれる。
//
//  validatePayload（kernel.cpp:282-289）:
//    +0  u32 0x31415445
//    +4  u32 channels（= 1）
//    +8  u32 frames（= taps）
//    +12 u32 (uint32)(sample_rate + 0.5) つまり engine の整数サンプルレート
//    +16 u32 1（mono）
//    +20 u32 0 / +24 u32 0 / +28 u32 0
//    +32 以降 float32 が frames 個
//  この並びは AssetUpload.makePayload がそのまま作る。
//
//  commitAsset（kernel.cpp:214-241）:
//    formatTag は ET_ASSET_F32_MULTICH（1）。resident_latency_ は
//    headBlock + filterDelaySamples になる（kernel.cpp:207, 231）。
//    つまり **fd = taps/2 を入れておかないと遅延補正がずれる**。
//    JS も同じ値を入れている（group_delay_eq.js:113-114 の `fd: this.tp / 2`）。
//
//  --- 重さ ---
//  taps が 32768 のとき FFT の大きさは 65536、反復は最大 12 回で
//  1 回につき前進と逆の 2 回。JS が Worker へ出しているのはこれが理由なので
//  （design-worker.js）、こちらも Task.detached へ出して main から外す。
//
//  --- 移していないもの ---
//  画面（スライダ・グラフ・状態表示）と、書き出し時のオフライン経路
//  （group_delay_eq.js:340-480 の _externalAssetSignature / offlineDspAsset）は
//  移していない。設計と送り込みだけ。

import Combine
import Foundation
import os

// MARK: - 設計そのもの（スレッドに縛られない）

enum GroupDelayEQDesignError: Error, LocalizedError, Sendable {
    case unsupportedTaps
    case invalidSampleRate
    case fftUnavailable
    case cancelled
    case designFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedTaps:
            return "Group Delay EQ tap count is unsupported."
        case .invalidSampleRate:
            return "Group Delay EQ sample rate is invalid."
        case .fftUnavailable:
            return "The transform for this tap count could not be created."
        case .cancelled:
            return "The filter design was cancelled."
        case .designFailed:
            return "The filter could not be designed. Try a different Taps setting."
        }
    }
}

/// design-core.js の中身。状態を持たないので、どのスレッドから呼んでもよい。
enum GroupDelayEQDesign {

    // MARK: 定数（design-core.js:12-23、group_delay_eq.js:19-24）

    /// 帯の中心周波数。design-core.js:12-14。
    static let bands: [Double] = [
        25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000
    ]
    /// design-core.js:15。
    static let tapsChoices: [Int] = [4096, 8192, 16384, 32768]
    /// params.json:9 の latencyMode。値は頭ブロックの大きさそのもの。
    static let headBlockChoices: [UInt32] = [0, 128, 256, 512, 1024]
    /// group_delay_eq.js:23。これを超えたら「追従できていない」と出す。
    static let rippleWarningDb: Double = 0.3

    /// DESIGN_ITERATIONS。design の既定引数から参照するので private にしない。
    static let designIterations = 12
    private static let spectrumOversampling = 2    // SPECTRUM_OVERSAMPLING
    private static let guardDivisor: Double = 16   // GUARD_DIVISOR
    private static let responsePoints = 128        // RESPONSE_POINTS
    private static let responseLowFrequency: Double = 20      // RESPONSE_LOW_FREQUENCY
    private static let responseHighFrequency: Double = 20000  // RESPONSE_HIGH_FREQUENCY
    private static let magnitudeEpsilon: Double = 1e-12       // MAGNITUDE_EPSILON

    // MARK: 出来上がるもの

    /// 設計の結果。designGroupDelayFilter（design-core.js:175-215）の戻り値。
    struct Filter: Sendable {
        /// カーネルへ渡す係数。長さは taps。
        let ir: [Float]
        /// 全体にかかる遅延（サンプル）。taps / 2。
        let bulkDelaySamples: Double
        /// 要求した遅延が長すぎて切り詰めたか。
        let clamped: Bool
        /// この taps で出せる遅延の上限（ms）。
        let limitMs: Double
        /// 実際に出た振幅のうねり（dB）。平らなはずなので 0 に近いほどよい。
        let rippleDb: Double
        /// 画面のグラフ用。
        let response: Response
        let taps: Int
        let sampleRate: Double
    }

    struct Response: Sendable {
        let frequencies: [Double]
        let targetMs: [Double]
        let realizedMs: [Double]
    }

    /// clampDelays（design-core.js:51-64）の戻り値。
    struct ClampedDelays: Sendable {
        let valuesMs: [Double]
        let clamped: Bool
        let limitMs: Double
    }

    /// buildTargetSpectrum（design-core.js:138-162）の戻り値。
    struct TargetSpectrum {
        var real: [Double]
        var imag: [Double]
        let clampedMs: [Double]
        let clamped: Bool
        let limitMs: Double
        let bulkDelaySamples: Double
        let curve: TargetCurve
    }

    // MARK: 単調性を保つ傾き

    /// Fritsch-Carlson の傾き。design-core.js:29-49 をそのまま。
    /// 形を保つ選び方なので、スライダのあいだで遅延曲線が行き過ぎない。
    static func monotoneSlopes(positions: [Double], values: [Double]) -> [Double] {
        let count = positions.count
        guard count >= 2 else { return [Double](repeating: 0, count: count) }
        var slopes = [Double](repeating: 0, count: count)
        var secants = [Double](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            secants[index] =
                (values[index + 1] - values[index]) / (positions[index + 1] - positions[index])
        }
        slopes[0] = secants[0]
        slopes[count - 1] = secants[count - 2]
        guard count > 2 else { return slopes }
        for index in 1..<(count - 1) {
            let previous = secants[index - 1]
            let next = secants[index]
            // 符号が変わる所（山や谷）は傾き 0 のまま。JS の continue と同じ。
            if previous * next <= 0 { continue }
            let leftWidth = positions[index] - positions[index - 1]
            let rightWidth = positions[index + 1] - positions[index]
            let leftWeight = 2 * rightWidth + leftWidth
            let rightWeight = rightWidth + 2 * leftWidth
            slopes[index] = (leftWeight + rightWeight) / (leftWeight / previous + rightWeight / next)
        }
        return slopes
    }

    // MARK: 遅延の頭打ち

    /// design-core.js:51-64。taps の半分から guard（taps/16）を引いた分までしか出せない。
    static func clampDelays(_ delaysMs: [Double], taps: Int, sampleRate: Double) -> ClampedDelays {
        let tapCount = Double(taps)
        let limitSamples = tapCount / 2 - tapCount / guardDivisor
        let limitMs = limitSamples * 1000 / sampleRate
        var values = [Double](repeating: 0, count: bands.count)
        var clamped = false
        for band in 0..<bands.count {
            // JS は Number(delaysMs?.[band]) で、無いか NaN なら 0 に落とす。
            let requested = band < delaysMs.count ? delaysMs[band] : Double.nan
            let value = requested.isFinite ? requested : 0
            let bounded = value > limitMs ? limitMs : (value < -limitMs ? -limitMs : value)
            if bounded != value { clamped = true }
            values[band] = bounded
        }
        return ClampedDelays(valuesMs: values, clamped: clamped, limitMs: limitMs)
    }

    /// 画面のスライダが使う上限。小数 1 桁に切り捨てる。
    /// group_delay_eq.js:94 の _delayLimitMs。設計側の limitMs より少しだけ狭い。
    static func uiDelayLimitMs(taps: Int, sampleRate: Double) -> Double {
        let tapCount = Double(taps)
        return ((tapCount / 2 - tapCount / guardDivisor) * 1000 / sampleRate * 10).rounded(.down) / 10
    }

    // MARK: 目標の群遅延

    /// 周波数から目標の群遅延（ms）を返す曲線。design-core.js:71-108。
    /// いちばん下の帯より下は値を保ち、Nyquist の手前で 0 へ落とす
    /// （実数のインパルス応答と辻褄が合うように）。
    ///
    /// JS は closure を返すが、bin ごとに何万回も呼ぶので struct にした。
    struct TargetCurve {
        let positions: [Double]
        let values: [Double]
        let slopes: [Double]
        let fadeStart: Double
        let fadeEnd: Double

        func value(at frequency: Double) -> Double {
            if frequency >= fadeEnd { return 0 }
            let bandCount = GroupDelayEQDesign.bands.count
            var result: Double
            if frequency <= GroupDelayEQDesign.bands[0] {
                result = values[0]
            } else if frequency >= GroupDelayEQDesign.bands[bandCount - 1] {
                result = values[bandCount - 1]
            } else {
                let position = log10(frequency)
                var segment = 0
                while segment < bandCount - 2 && position > positions[segment + 1] {
                    segment += 1
                }
                let width = positions[segment + 1] - positions[segment]
                let ratio = (position - positions[segment]) / width
                let squared = ratio * ratio
                let cubed = squared * ratio
                result = (2 * cubed - 3 * squared + 1) * values[segment]
                    + (cubed - 2 * squared + ratio) * width * slopes[segment]
                    + (-2 * cubed + 3 * squared) * values[segment + 1]
                    + (cubed - squared) * width * slopes[segment + 1]
            }
            if frequency > fadeStart {
                result *= 0.5 + 0.5 * cos(Double.pi * (frequency - fadeStart) / (fadeEnd - fadeStart))
            }
            return result
        }
    }

    /// design-core.js:71-108 の createTargetCurve。
    static func makeTargetCurve(delaysMs: [Double], sampleRate: Double) -> TargetCurve {
        let bandCount = bands.count
        var positions = [Double](repeating: 0, count: bandCount)
        var values = [Double](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            positions[band] = log10(bands[band])
            values[band] = band < delaysMs.count ? delaysMs[band] : 0
        }
        let slopes = monotoneSlopes(positions: positions, values: values)
        let nyquist = sampleRate / 2
        let fadeEnd = min(responseHighFrequency, nyquist * 0.9)
        let fadeStart = min(bands[bandCount - 1], fadeEnd * 0.9)
        return TargetCurve(positions: positions,
                           values: values,
                           slopes: slopes,
                           fadeStart: fadeStart,
                           fadeEnd: fadeEnd)
    }

    /// グラフと設計で共有する周波数の並び。design-core.js:113-121。
    /// 中身は FIRDesign.logFrequencies と同じ式（対数で等間隔）。
    static func responseFrequencies(sampleRate: Double) -> [Double] {
        let highest = min(responseHighFrequency, sampleRate * 0.45)
        return FIRDesign.logFrequencies(low: responseLowFrequency,
                                        high: highest,
                                        count: responsePoints)
    }

    /// いまの設定の目標群遅延（ms）。design-core.js:126-133 の groupDelayTargetMs。
    /// 設計を回さずにグラフの目標線だけ引きたいときに使う。
    static func targetMs(delaysMs: [Double],
                         taps: Int,
                         sampleRate: Double,
                         frequencies: [Double]? = nil) -> [Double] {
        let clamped = clampDelays(delaysMs, taps: taps, sampleRate: sampleRate)
        let curve = makeTargetCurve(delaysMs: clamped.valuesMs, sampleRate: sampleRate)
        let grid = frequencies ?? responseFrequencies(sampleRate: sampleRate)
        return grid.map { curve.value(at: $0) }
    }

    // MARK: 理想の全域通過スペクトル

    /// 一定の全体遅延に、要求されたぶんの偏差を足したもの。design-core.js:138-162。
    /// 偏差の位相は群遅延を台形則で積み上げて作る。
    static func buildTargetSpectrum(delaysMs: [Double],
                                    taps: Int,
                                    sampleRate: Double,
                                    size: Int) -> TargetSpectrum {
        let clamped = clampDelays(delaysMs, taps: taps, sampleRate: sampleRate)
        let bulkDelaySamples = Double(taps) / 2
        let curve = makeTargetCurve(delaysMs: clamped.valuesMs, sampleRate: sampleRate)
        let samplesPerMillisecond = sampleRate / 1000
        let bins = size / 2 + 1
        var real = [Double](repeating: 0, count: bins)
        var imag = [Double](repeating: 0, count: bins)
        let step = 2 * Double.pi / Double(size)
        var deviationPhase = 0.0
        var previous = curve.value(at: 0) * samplesPerMillisecond
        real[0] = 1
        for bin in 1..<bins {
            let deviation =
                curve.value(at: Double(bin) * sampleRate / Double(size)) * samplesPerMillisecond
            deviationPhase += 0.5 * (previous + deviation) * step
            previous = deviation
            let phase = -(step * Double(bin) * bulkDelaySamples + deviationPhase)
            real[bin] = cos(phase)
            imag[bin] = sin(phase)
        }
        // 実数列の Nyquist bin に虚部は無い（design-core.js:158-160）。
        real[bins - 1] = real[bins - 1] < 0 ? -1 : 1
        imag[bins - 1] = 0
        return TargetSpectrum(real: real,
                              imag: imag,
                              clampedMs: clamped.valuesMs,
                              clamped: clamped.clamped,
                              limitMs: clamped.limitMs,
                              bulkDelaySamples: bulkDelaySamples,
                              curve: curve)
    }

    // MARK: 設計

    /// 全域通過 FIR を設計して、有限の taps で実際に何が出たかを測る。
    /// design-core.js:175-215 の designGroupDelayFilter。
    ///
    /// - Parameter isCancelled: 反復ごとに見る。重いので途中で降りられるようにした。
    static func design(delaysMs: [Double],
                       taps: Int = 16384,
                       sampleRate: Double = 48000,
                       iterations: Int = GroupDelayEQDesign.designIterations,
                       isCancelled: () -> Bool = { false }) throws -> Filter {
        guard tapsChoices.contains(taps) else { throw GroupDelayEQDesignError.unsupportedTaps }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw GroupDelayEQDesignError.invalidSampleRate
        }
        let size = taps * spectrumOversampling
        guard let fft = FIRDesign.fft(size: size) else {
            throw GroupDelayEQDesignError.fftUnavailable
        }
        let target = buildTargetSpectrum(delaysMs: delaysMs,
                                         taps: taps,
                                         sampleRate: sampleRate,
                                         size: size)

        // 理想のスペクトルから始めて、
        //   (1) taps より後ろを 0 にする（長さの制約）
        //   (2) 各 bin の振幅を 1 に戻す（全域通過の制約）
        // を交互に射影する。どちらの制約も満たせば収束。
        var impulse = fft.inverseRealTransform(real: target.real, imag: target.imag)
        for _ in 0..<iterations {
            if isCancelled() { throw GroupDelayEQDesignError.cancelled }
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

        // ここで Float へ落とす。以降の測定も Float に落ちた値で行う
        // （JS も Float32Array に入れてから測っている。design-core.js:211-214）。
        var ir = [Float](repeating: 0, count: taps)
        for index in 0..<taps { ir[index] = Float(impulse[index]) }

        let measured = measureResponse(ir: ir,
                                       target: target,
                                       size: size,
                                       sampleRate: sampleRate,
                                       fft: fft)
        return Filter(ir: ir,
                      bulkDelaySamples: target.bulkDelaySamples,
                      clamped: target.clamped,
                      limitMs: target.limitMs,
                      rippleDb: measured.rippleDb,
                      response: measured.response,
                      taps: taps,
                      sampleRate: sampleRate)
    }

    // MARK: 測る

    /// 出来上がった FIR の振幅のうねりと群遅延。design-core.js:222-266。
    /// 群遅延は「傾斜をかけた変換との比」で出すので、位相をほどく必要がない。
    private static func measureResponse(ir: [Float],
                                        target: TargetSpectrum,
                                        size: Int,
                                        sampleRate: Double,
                                        fft: FIRDesign.RealFFT)
        -> (rippleDb: Double, response: Response) {
        var impulse = [Double](repeating: 0, count: size)
        var ramped = [Double](repeating: 0, count: size)
        for index in 0..<ir.count {
            impulse[index] = Double(ir[index])
            ramped[index] = Double(ir[index]) * Double(index)
        }
        let spectrum = fft.realTransform(impulse)
        let rampedSpectrum = fft.realTransform(ramped)
        let bins = spectrum.real.count
        var magnitudeDb = [Double](repeating: 0, count: bins)
        var delaySamples = [Double](repeating: 0, count: bins)
        for bin in 0..<bins {
            let real = spectrum.real[bin]
            let imag = spectrum.imag[bin]
            let power = real * real + imag * imag
            magnitudeDb[bin] = FIRDesign.decibels(fromPower: power, floor: magnitudeEpsilon)
            delaySamples[bin] = power > magnitudeEpsilon
                ? (rampedSpectrum.real[bin] * real + rampedSpectrum.imag[bin] * imag) / power
                : target.bulkDelaySamples
        }

        let frequencies = responseFrequencies(sampleRate: sampleRate)
        var targetMs = [Double](repeating: 0, count: frequencies.count)
        var realizedMs = [Double](repeating: 0, count: frequencies.count)
        let millisecondsPerSample = 1000 / sampleRate
        var rippleDb = 0.0
        for point in 0..<frequencies.count {
            let frequency = frequencies[point]
            targetMs[point] = target.curve.value(at: frequency)
            realizedMs[point] = (sampleAtFrequency(delaySamples, frequency, size, sampleRate)
                - target.bulkDelaySamples) * millisecondsPerSample
            let deviation = sampleAtFrequency(magnitudeDb, frequency, size, sampleRate)
            let absolute = deviation < 0 ? -deviation : deviation
            if absolute > rippleDb { rippleDb = absolute }
        }
        return (rippleDb, Response(frequencies: frequencies,
                                   targetMs: targetMs,
                                   realizedMs: realizedMs))
    }

    /// bin の並びを周波数で線形に読む。design-core.js:164-170。
    private static func sampleAtFrequency(_ values: [Double],
                                          _ frequency: Double,
                                          _ size: Int,
                                          _ sampleRate: Double) -> Double {
        let position = frequency * Double(size) / sampleRate
        let lower = Int(position.rounded(.down))
        let upper = lower + 1
        if upper >= values.count { return values[values.count - 1] }
        if lower < 0 { return values[0] }
        return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
    }

    /// JS の TypedArray.fill(0, from) と同じ。
    private static func zeroTail(_ values: inout [Double], from index: Int) {
        guard index < values.count else { return }
        for position in index..<values.count { values[position] = 0 }
    }
}

// MARK: - instance へ送り込む側

/// Group Delay EQ 1 個ぶんの設計係。
///
/// 画面から帯の遅延・taps・latency を受け取り、重い設計を main の外で回して、
/// 出来たら AssetUpload でカーネルへ送る。
///
/// 帯の遅延（15 個）は**カーネルのパラメータではない**（params.json の
/// フィールドは latencyMode と filterDelaySamples の 2 つだけ）。
/// だからこの値はここが持つ。鎖と一緒に保存する口はまだ無い。
@MainActor
final class GroupDelayEQDesigner: ObservableObject {

    /// いまどの段にいるか。画面に出す文言は英語。
    enum Stage: Equatable {
        /// 全部 0 ms。素通し。group_delay_eq.js:238-239。
        case flat
        case designing
        case staging
        case active
        case failed(String)

        var message: String {
            switch self {
            case .flat:
                return "All bands are at 0 ms."
            case .designing:
                return "Designing filter…"
            case .staging:
                return "Loading the filter…"
            case .active:
                return "The filter is running."
            case .failed(let text):
                return text
            }
        }
    }

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "groupDelayEq")
    private static let kernelType = "GroupDelayEqPlugin"

    // MARK: 設定

    /// 帯ごとの遅延（ms）。長さは GroupDelayEQDesign.bands と同じ 15。
    @Published private(set) var delaysMs: [Double]
    /// 4096 / 8192 / 16384 / 32768。
    @Published private(set) var taps: Int
    /// 頭ブロック。0 / 128 / 256 / 512 / 1024。
    @Published private(set) var headBlock: UInt32
    /// engine のサンプルレート。ペイロードの +12 に入るので、
    /// **et_engine_prepare へ渡した値と同じでないとカーネルに弾かれる**
    /// （kernel.cpp:286）。
    @Published private(set) var sampleRate: Double
    /// engine の最大チャンネル数。EffeTuneDSP.prepare の maxChannels。
    @Published private(set) var engineChannels: UInt32

    // MARK: 出来たもの

    @Published private(set) var stage: Stage = .flat
    /// 品質の注意書き。無ければ nil。group_delay_eq.js:280-291。
    @Published private(set) var warning: String?
    /// 直近の設計。グラフはここから引く。
    @Published private(set) var filter: GroupDelayEQDesign.Filter?

    /// 送り込みが効いているときの遅延（サンプル）。group_delay_eq.js:522。
    var latencySamples: Int {
        stage == .active ? Int(headBlock) + taps / 2 : 0
    }

    /// スライダの上限（ms）。
    var delayLimitMs: Double {
        GroupDelayEQDesign.uiDelayLimitMs(taps: taps, sampleRate: sampleRate)
    }

    // MARK: 繋ぎ先

    private var instance: UInt32 = 0
    private var engine: UInt32 { EffeTuneDSP.shared.engine }

    // MARK: 進行中のもの

    private typealias Outcome = Swift.Result<GroupDelayEQDesign.Filter, GroupDelayEQDesignError>
    private var schedule: Task<Void, Never>?
    private var work: Task<Outcome, Never>?
    private var generation: UInt64 = 0

    init(instance: UInt32 = 0,
         sampleRate: Double = 48000,
         engineChannels: UInt32 = 2,
         taps: Int = 16384,
         headBlock: UInt32 = 128,
         delaysMs: [Double]? = nil) {
        self.instance = instance
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
        self.engineChannels = engineChannels
        self.taps = GroupDelayEQDesign.tapsChoices.contains(taps) ? taps : 16384
        self.headBlock = GroupDelayEQDesign.headBlockChoices.contains(headBlock) ? headBlock : 128
        let count = GroupDelayEQDesign.bands.count
        var initial = [Double](repeating: 0, count: count)
        if let given = delaysMs {
            for band in 0..<min(count, given.count) where given[band].isFinite {
                initial[band] = given[band]
            }
        }
        self.delaysMs = initial
    }

    // MARK: - 繋ぐ

    /// 面倒を見る instance を決める。engine を作り直した後にも呼ぶ。
    func attach(instance: UInt32) {
        guard self.instance != instance else { return }
        self.instance = instance
        filter = nil
        refresh(debounce: 0)
    }

    func detach() {
        schedule?.cancel()
        work?.cancel()
        if instance != 0 { AssetUpload.clear(engine: engine, instance: instance) }
        instance = 0
        filter = nil
        stage = .flat
        warning = nil
    }

    // MARK: - 値を変える

    func setDelay(_ milliseconds: Double, band: Int) {
        guard delaysMs.indices.contains(band) else { return }
        let limit = delayLimitMs
        let value = milliseconds.isFinite ? min(max(milliseconds, -limit), limit) : 0
        guard delaysMs[band] != value else { return }
        delaysMs[band] = value
        refresh()
    }

    func setDelays(_ values: [Double]) {
        let limit = delayLimitMs
        var next = [Double](repeating: 0, count: GroupDelayEQDesign.bands.count)
        for band in 0..<min(next.count, values.count) where values[band].isFinite {
            next[band] = min(max(values[band], -limit), limit)
        }
        guard next != delaysMs else { return }
        delaysMs = next
        refresh()
    }

    /// 全部 0 ms へ。group_delay_eq.js:169-173。
    func reset() {
        setDelays([Double](repeating: 0, count: GroupDelayEQDesign.bands.count))
    }

    func setTaps(_ value: Int) {
        guard GroupDelayEQDesign.tapsChoices.contains(value), value != taps else { return }
        taps = value
        // taps を減らすと出せる遅延も縮むので、しまってある値を詰め直す
        // （group_delay_eq.js:96-102 の _clampDelaysToLimit）。
        clampDelaysToLimit()
        refresh(debounce: 0)
    }

    /// latency だけの変更は設計し直さない。出来ている係数をもう一度送るだけ
    /// （group_delay_eq.js:166 が同じことをしている）。
    func setHeadBlock(_ value: UInt32) {
        guard GroupDelayEQDesign.headBlockChoices.contains(value), value != headBlock else { return }
        headBlock = value
        guard let filter else { return }
        guard hasDelay() else { return }
        schedule?.cancel()
        generation &+= 1
        let generation = self.generation
        schedule = Task { [weak self] in
            guard let self else { return }
            await self.stageFilter(filter, generation: generation)
        }
    }

    func setSampleRate(_ value: Double) {
        guard value.isFinite, value > 0, value != sampleRate else { return }
        sampleRate = value
        clampDelaysToLimit()
        refresh(debounce: 0)
    }

    func setEngineChannels(_ value: UInt32) {
        guard value >= 1, value <= 16, value != engineChannels else { return }
        engineChannels = value
        refresh(debounce: 0)
    }

    private func clampDelaysToLimit() {
        let limit = delayLimitMs
        for band in delaysMs.indices {
            delaysMs[band] = min(max(delaysMs[band], -limit), limit)
        }
    }

    private func hasDelay() -> Bool {
        delaysMs.contains { $0 != 0 }
    }

    // MARK: - 設計して送る

    /// 設計し直して送り込む。既定の 150ms は JS の待ち（group_delay_eq.js:164）と同じで、
    /// スライダを動かしているあいだ何度も設計しないため。
    func refresh(debounce: TimeInterval = 0.15) {
        schedule?.cancel()
        work?.cancel()
        generation &+= 1
        let generation = self.generation

        guard instance != 0, engine != 0 else {
            stage = .failed(ETAssetUploadError.engineNotReady.errorDescription ?? "Not ready.")
            return
        }

        // 全部 0 ms なら設計しない。資産を外して素通しへ戻す
        // （group_delay_eq.js:227-241 の _settleFlat）。
        guard hasDelay() else {
            AssetUpload.clear(engine: engine, instance: instance)
            filter = nil
            warning = nil
            stage = .flat
            return
        }

        stage = .designing
        warning = nil

        let delays = delaysMs
        let taps = self.taps
        let sampleRate = self.sampleRate

        schedule = Task { [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            guard self.isCurrent(generation) else { return }

            // 重いところ。main から外す（JS が Worker へ出しているのと同じ理由）。
            let work = Task.detached(priority: .userInitiated) { () -> Outcome in
                do {
                    let designed = try GroupDelayEQDesign.design(delaysMs: delays,
                                                                 taps: taps,
                                                                 sampleRate: sampleRate,
                                                                 isCancelled: { Task.isCancelled })
                    return .success(designed)
                } catch let error as GroupDelayEQDesignError {
                    return .failure(error)
                } catch {
                    return .failure(.designFailed)
                }
            }
            self.remember(work: work)
            let outcome = await work.value
            await self.finish(outcome, generation: generation)
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        self.generation == generation && instance != 0
    }

    private func remember(work: Task<Outcome, Never>) {
        self.work = work
    }

    private func finish(_ outcome: Outcome, generation: UInt64) async {
        guard isCurrent(generation) else { return }
        switch outcome {
        case .failure(let error):
            if case .cancelled = error { return }
            Self.log.error("設計に失敗 \(String(describing: error))")
            filter = nil
            stage = .failed(GroupDelayEQDesignError.designFailed.errorDescription ?? "Failed.")
        case .success(let designed):
            // 送る前にグラフへ出す。カーネルが受け取るのを待たせない
            // （group_delay_eq.js:265-268 と同じ順番）。
            filter = designed
            warning = Self.qualityWarning(for: designed)
            await stageFilter(designed, generation: generation)
        }
    }

    /// 出来た係数をカーネルへ。
    private func stageFilter(_ designed: GroupDelayEQDesign.Filter, generation: UInt64) async {
        guard isCurrent(generation) else { return }
        let engine = self.engine
        let instance = self.instance
        guard engine != 0, instance != 0 else {
            stage = .failed(ETAssetUploadError.engineNotReady.errorDescription ?? "Not ready.")
            return
        }
        guard AssetUpload.canStage else {
            stage = .failed(ETAssetUploadError.stagingAddressUnavailable.errorDescription
                            ?? "Cannot stage.")
            return
        }
        let channels = processingChannels()
        guard channels >= 1 else {
            stage = .failed("The selected audio channels are not available.")
            return
        }

        stage = .staging

        // **params が先。** beginAsset は冒頭で applyPendingParameters() を呼び、
        // filterDelaySamples を見て候補の遅延を決める（kernel.cpp:171, 207）。
        pushKernelParameters(instance: instance)

        do {
            try AssetUpload.send(engine: engine,
                                 instance: instance,
                                 slot: 0,
                                 channels: [designed.ir],
                                 sampleRate: Int(sampleRate.rounded()),
                                 topology: .mono,
                                 headBlock: headBlock,
                                 rateDivider: 1,
                                 processingChannels: channels)
        } catch {
            Self.log.error("送り込みに失敗 \(String(describing: error))")
            let text = (error as? LocalizedError)?.errorDescription
            stage = .failed(text ?? "The filter could not be loaded.")
            return
        }

        // commit が通ると instance の遅延が変わる。鎖を publish し直して
        // et_pipeline_configure に読み直させる（AssetUpload.swift:64-68）。
        republishForLatencyChange()

        let status = await AssetUpload.waitForActive(engine: engine, instance: instance, slot: 0)
        guard isCurrent(generation) else { return }
        switch status.state {
        case .active:
            stage = .active
        case .error:
            stage = .failed(Self.failureText(reason: status.reason))
        default:
            // 無音のあいだは preparing のまま進まない。音が来れば active になる。
            stage = .staging
        }
    }

    // MARK: - カーネルのパラメータ

    /// latencyMode は選択肢の**添字**、filterDelaySamples は taps/2。
    /// 添字であることの出典は js/audio/dsp-params.generated.js:666-671
    /// （`["0","128",…].indexOf(params["lt"])` を packed[0] に入れている）。
    /// taps/2 の出典は plugins/eq/group_delay_eq.js:113-114。
    private func pushKernelParameters(instance: UInt32) {
        let latencyIndex = Float(GroupDelayEQDesign.headBlockChoices.firstIndex(of: headBlock) ?? 1)
        let filterDelay = Float(taps / 2)

        // 鎖に並んでいるなら、そちらの控えも一緒に直す。
        if let index = chainIndex(for: instance) {
            EffeTuneDSP.shared.setValue(latencyIndex, at: index, offset: 0)
            EffeTuneDSP.shared.setValue(filterDelay, at: index, offset: 1)
            return
        }
        guard let spec = ETCatalog.first(where: { $0.type == Self.kernelType }) else { return }
        let packed: [Float] = [latencyIndex, filterDelay]
        _ = packed.withUnsafeBufferPointer {
            et_instance_set_params(engine, instance, $0.baseAddress,
                                   UInt32(spec.floatCount), spec.paramsHash, 0)
        }
    }

    private func chainIndex(for instance: UInt32) -> Int? {
        EffeTuneDSP.shared.chain.firstIndex { $0.instance == instance }
    }

    /// 鎖の中身は変えずに publish だけやり直す。
    /// EffeTuneDSP.publish は private なので、何も渡さない setRouting を通す
    /// （中で publish を呼ぶ。EffeTuneDSP.swift:282-290）。
    private func republishForLatencyChange() {
        guard let index = chainIndex(for: instance) else { return }
        EffeTuneDSP.shared.setRouting(at: index)
    }

    /// この instance が何チャンネルを受け持つか。
    /// ir-plugin-contract.js:26-39 の selectedIrChannelCount を、
    /// こちらの channelSpec（ETPipeline.h の値）へ読み替えたもの。
    private func processingChannels() -> UInt32 {
        let spec = chainIndex(for: instance).map { EffeTuneDSP.shared.chain[$0].channelSpec } ?? -1
        switch spec {
        case -2:                       // All
            return engineChannels
        case -1:                       // Stereo（既定）
            return engineChannels >= 2 ? 2 : 1
        case 0...15:                   // 1 本だけ
            return UInt32(spec) < engineChannels ? 1 : 0
        case 16...23:                  // ステレオ対
            let pair = UInt32(spec - 16)
            return engineChannels >= (pair + 1) * 2 ? 2 : 0
        default:
            return 0
        }
    }

    // MARK: - 文言（英語）

    /// group_delay_eq.js:280-291 の _qualityWarning。
    private static func qualityWarning(for filter: GroupDelayEQDesign.Filter) -> String? {
        if filter.clamped {
            let limit = String(format: "%.1f", filter.limitMs)
            return "This Taps setting cannot reach the requested delay. "
                + "The filter uses up to \(limit) ms."
        }
        if filter.rippleDb > GroupDelayEQDesign.rippleWarningDb {
            return "The filter cannot follow these settings closely. "
                + "Increase Taps or reduce the difference between neighbouring bands."
        }
        return nil
    }

    /// assetState の理由。ETAssetStatus.reason の値は five_band_fir_peq/kernel.cpp:259-263、
    /// 意味は group_delay_eq/kernel.cpp:203/217-221/225-228。
    private static func failureText(reason: UInt32) -> String {
        switch reason {
        case 2:
            return "The filter needs more memory than the effect accepts. Try fewer taps."
        case 3:
            return "The effect could not take the filter. Try fewer taps or a higher latency."
        default:
            return "The filter could not be prepared. Try fewer taps or a higher latency."
        }
    }
}
