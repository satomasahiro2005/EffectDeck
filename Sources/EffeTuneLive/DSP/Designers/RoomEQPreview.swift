//  RoomEQPreview.swift
//  Room EQ の画面に出す曲線（design-core.js の previews）。**Foundation と FIRDesign だけ。**
//
//  上流は設計のついでに、チャンネルごとに次のものを作って画面へ渡す
//  （Vendor/effetune/js/room-eq/design-core.js:2810-2830）:
//      周波数特性   measuredDb / baseCorrectionDb / predictedBaseDb（と referenceLevelDb）
//      位相         phaseResponse.before / after（度、±180 に畳んだもの）
//      群遅延       groupDelayResponse.minimum / excess の before / after（ms）
//      インパルス   impulseResponse（補正の前後の時間波形）
//  材料は設計と同じ測定の解析で、音には効かない。設計（RoomEQDesigner.design）が
//  同じ Task.detached の中で一緒に作るので、MainActor には乗らない。
//
//  写した元:
//      design-core.js:474-495      previewWindowSamples / dspWindowSamples
//      design-core.js:497-551      alignedAverageAnalysis
//      design-core.js:2099-2252    interpolatePhaseOnGrid / phaseComponentsOnGrid /
//                                  wrapPhaseDegrees / createPhasePreviews
//      design-core.js:2254-2315    createImpulseResponsePreview
//      design-core.js:2733-2746    predictResponse（predictedBaseDb）
//      group-delay-analysis.js     analyzeRoomEqGroupDelay ほか（群遅延の解析そのもの）
//
//  --- 上流と違えたところ ---
//  - phaseComponentsOnGrid の minimum は作らない。createPhasePreviews が読むのは total だけ
//    （:2203-2204）。
//  - 補正の FIR のスペクトル（上流の actualSpectrum）は使い回さず、その場で変換し直す。
//    上流が使い回すのは長さが合うときだけで、中身は同じ変換（taps を 0 で伸ばしたもの）。
//    位相の側は「ずらしてから変換」と「変換してから回す」の違いになるが、±π の畳み方が
//    違うだけで、下で unwrap して度へ畳み直すので同じ曲線になる。
//  - **長すぎる測定では位相・群遅延・インパルスを作らない**（previewSampleLimit）。
//    上流の測定は取り込みの時点で 1.5 秒・2^18 点に切られている（onset.js:43-44）。
//    こちらは WAV を切らずに読むので、群遅延の 4 倍詰めの変換が何百 MB にもなりうる。
//    周波数特性の図は作る。

import Foundation

// MARK: - 出来上がり

/// 画面に出す曲線の 1 チャンネルぶん。
struct RoomEQPreview: Sendable {

    /// 補正の前と後。格子は frequencies と同じ並び。値の無い所は NaN。
    struct Curves: Sendable {
        var before: [Double]
        var after: [Double]
    }

    /// 補正の前と後の時間波形（design-core.js:2308-2315）。
    struct Impulse: Sendable {
        var sampleRate: Int
        /// 先頭の時刻（ms）。立ち上がりより 2ms 前なので負。
        var startMs: Double
        /// 立ち上がりから末尾までの長さ（ms）。
        var durationMs: Double
        var before: [Float]
        var after: [Float]
    }

    var channel: Int
    /// 帯域内の平均レベル（補正の狙い）。周波数特性の図はこれを 0 dB に合わせて描く。
    var referenceLevelDb: Double
    /// 対数の格子（design-core.js:2498）。
    var frequencies: [Double]
    /// 測った特性を平滑化したもの（displaySmoothed）。
    var measuredDb: [Double]
    /// 自動の補正（Additional EQ を含まない）。
    var baseCorrectionDb: [Double]
    /// 測定に自動の補正を足して平滑化したもの（Additional EQ を含まない）。
    var predictedBaseDb: [Double]
    /// Additional EQ（design-core.js:2499 の eqDb）。上流の画面は同じものを自前で引き直している
    /// （room_eq.js:722-735）。こちらは設計と同じ値を持ち回る。
    var equalizerDb: [Double]
    /// インパルス応答の無い測定・長すぎる測定では nil。
    var phase: Curves?
    var minimumGroupDelay: Curves?
    var excessGroupDelay: Curves?
    var impulse: Impulse?
}

/// 測ったインパルス応答 1 本を解析したもの（design-core.js:332-346 の analysis）。
struct RoomEQImpulseAnalysis: Sendable {
    /// 処理レートへ直し、基準の大きさで割った時間波形。
    var samples: [Float]
    /// 立ち上がり（処理レートでの位置）。
    var onsetIndex: Int
    /// 対数の格子での振幅。合意の平均（alignedAverageAnalysis）では空。
    var magnitude: [Double]
    /// インパルスの図だけが読む、長めの時間波形（design-core.js:544）。合意の平均だけが持つ。
    var previewSamples: [Float]? = nil
}

// MARK: - 組み立て

extension RoomEQDesigner {

    /// 位相・群遅延・インパルスの図を作る測定の長さの上限（処理レートでの点の数）。
    /// 上流の測定は 2^18 点までに切られている（onset.js:43-44）ので、同じ数で止める。
    /// 2^18 点なら群遅延の変換は 2^20 点（1 本 8MB）で済む。
    static let previewSampleLimit = 1 << 18

    /// 1 チャンネルぶんの曲線。design-core.js:2733-2746 と :2755-2830。
    static func preview(channel: Int,
                        config: RoomEQConfig,
                        frequencies: [Double],
                        levelDb: Double,
                        displayMeasuredDb: [Double],
                        displaySmoothed: [Double],
                        baseCorrectionDb: [Double],
                        equalizerDb: [Double],
                        taps: [Float],
                        referenceAnalysis: RoomEQImpulseAnalysis?,
                        groupDelaySources: [RoomEQImpulseAnalysis]) -> RoomEQPreview {
        // design-core.js:2733-2746。補正を平滑化前の測定に足してから 1 回だけ平滑化する。
        var applied = [Double](repeating: 0, count: frequencies.count)
        for index in 0..<frequencies.count {
            applied[index] = displayMeasuredDb[index] + baseCorrectionDb[index]
        }
        let predictedBaseDb = smoothFrequencyResponse(frequencies: frequencies,
                                                      magnitudes: applied,
                                                      sigma: config.smoothing)
        var preview = RoomEQPreview(channel: channel,
                                    referenceLevelDb: levelDb,
                                    frequencies: frequencies,
                                    measuredDb: displaySmoothed,
                                    baseCorrectionDb: baseCorrectionDb,
                                    predictedBaseDb: predictedBaseDb,
                                    equalizerDb: equalizerDb)

        guard let reference = referenceAnalysis,
              !taps.isEmpty,
              reference.samples.count <= previewSampleLimit,
              groupDelaySources.allSatisfy({ $0.samples.count <= previewSampleLimit })
        else { return preview }

        if let phase = phasePreviews(reference,
                                     taps: taps,
                                     config: config,
                                     frequencies: frequencies,
                                     groupDelaySources: groupDelaySources) {
            preview.phase = phase.phase
            preview.minimumGroupDelay = phase.minimum
            preview.excessGroupDelay = phase.excess
        }
        preview.impulse = impulseResponsePreview(reference, taps: taps, config: config)
        return preview
    }

    // MARK: 窓の長さ

    /// design-core.js:474-481 の previewWindowSamples。インパルスの図の長さ。
    static func previewWindowSamples(_ config: RoomEQConfig) -> Int {
        let durationMs = max(5,
                             config.directWindowMs,
                             config.reverbAmount > 0 ? min(config.reverbWindowMs, 50) : 0)
        return max(2, jsRound(Double(config.sampleRate) * durationMs / 1000))
    }

    /// design-core.js:491-495 の dspWindowSamples。合意の平均が解析に使う長さ。
    static func dspWindowSamples(_ config: RoomEQConfig) -> Int {
        max(2, jsRound(Double(config.sampleRate) * max(5, config.directWindowMs) / 1000))
    }

    // MARK: 合意の平均

    /// design-core.js:497-551 の alignedAverageAnalysis。立ち上がりで揃えて平均した 1 本。
    /// 1 本しか無ければそのまま返す。群遅延の分（groupDelaySamples）は作らない。
    /// createPhasePreviews が群遅延に使うのは平均ではなく元の測定の並び（:2565, :2762）。
    static func alignedAverageAnalysis(_ analyses: [RoomEQImpulseAnalysis],
                                       config: RoomEQConfig) -> RoomEQImpulseAnalysis? {
        guard let first = analyses.first else { return nil }
        if analyses.count == 1 { return first }
        let preroll = max(1, jsRound(Double(config.sampleRate) * 0.005))
        let dspLength = preroll + config.taps / 2 + dspWindowSamples(config)
        let displayLength = preroll + config.taps / 2 + previewWindowSamples(config)
        var samples = [Float](repeating: 0, count: max(dspLength, displayLength))
        for index in 0..<samples.count {
            let relative = index - preroll
            var sum = 0.0
            var count = 0
            for analysis in analyses {
                let source = analysis.onsetIndex + relative
                if source < 0 || source >= analysis.samples.count { continue }
                sum += Double(analysis.samples[source])
                count += 1
            }
            if count > 0 { samples[index] = Float(sum / Double(count)) }
        }
        return RoomEQImpulseAnalysis(samples: Array(samples.prefix(dspLength)),
                                     onsetIndex: preroll,
                                     magnitude: [],
                                     previewSamples: Array(samples.prefix(displayLength)))
    }

    // MARK: 位相と群遅延

    /// design-core.js:2178-2252 の createPhasePreviews。
    static func phasePreviews(_ analysis: RoomEQImpulseAnalysis,
                              taps: [Float],
                              config: RoomEQConfig,
                              frequencies: [Double],
                              groupDelaySources: [RoomEQImpulseAnalysis])
        -> (phase: RoomEQPreview.Curves,
            minimum: RoomEQPreview.Curves,
            excess: RoomEQPreview.Curves)? {
        let rate = config.sampleRate
        let filterDelay = config.phase == .minimum ? 0 : taps.count / 2
        let tapValues = taps.map { Double($0) }
        guard let before = totalPhaseOnGrid(analysis.samples.map { Double($0) },
                                            alignment: analysis.onsetIndex,
                                            sampleRate: rate,
                                            frequencies: frequencies),
              let filter = totalPhaseOnGrid(tapValues,
                                            alignment: filterDelay,
                                            sampleRate: rate,
                                            frequencies: frequencies,
                                            minimumFftSize: taps.count * 2)
        else { return nil }
        var after = [Double](repeating: 0, count: frequencies.count)
        for index in 0..<frequencies.count { after[index] = before[index] + filter[index] }

        // :2207-2223。群遅延は元の測定から解析し、2 本以上なら平均する。
        var sourceDelays = [GroupDelayAnalysis]()
        for source in groupDelaySources {
            guard let delay = analyzeGroupDelay(source.samples.map { Double($0) },
                                                alignment: source.onsetIndex,
                                                sampleRate: rate,
                                                frequencies: frequencies) else { return nil }
            sourceDelays.append(delay)
        }
        guard let beforeDelay = sourceDelays.count == 1
                ? sourceDelays.first
                : averageGroupDelay(sourceDelays),
              let filterDelayAnalysis = analyzeGroupDelay(tapValues,
                                                          alignment: filterDelay,
                                                          sampleRate: rate,
                                                          frequencies: frequencies,
                                                          minimumFftSize: taps.count * 2)
        else { return nil }
        let afterDelay = combineGroupDelay(beforeDelay, filterDelayAnalysis)
        let beforeDisplay = smoothGroupDelay(beforeDelay, frequencies: frequencies,
                                             smoothing: config.smoothing)
        let afterDisplay = smoothGroupDelay(afterDelay, frequencies: frequencies,
                                            smoothing: config.smoothing)
        return (RoomEQPreview.Curves(before: before.map(wrapPhaseDegrees),
                                     after: after.map(wrapPhaseDegrees)),
                RoomEQPreview.Curves(before: beforeDisplay.minimum, after: afterDisplay.minimum),
                RoomEQPreview.Curves(before: beforeDisplay.excess, after: afterDisplay.excess))
    }

    /// design-core.js:2126-2169 の phaseComponentsOnGrid のうち total だけ。
    /// alignment だけ前へ回してから変換し、格子へ unwrap して写す。
    static func totalPhaseOnGrid(_ samples: [Double],
                                 alignment: Int,
                                 sampleRate: Int,
                                 frequencies: [Double],
                                 minimumFftSize: Int = 0) -> [Double]? {
        let fftSize = max(4, FIRDesign.nextPowerOfTwo(max(samples.count, minimumFftSize)))
        guard let fft = FIRDesign.fft(size: fftSize) else { return nil }
        var input = [Double](repeating: 0, count: fftSize)
        for index in 0..<samples.count {
            var aligned = index - alignment
            if aligned < 0 { aligned += fftSize }
            // 型付き配列は範囲の外への書き込みを捨てる（JS と同じにする）。
            guard aligned >= 0, aligned < fftSize else { continue }
            input[aligned] = samples[index]
        }
        let spectrum = fft.realTransform(input)
        var phases = [Double](repeating: 0, count: spectrum.real.count)
        for bin in 0..<phases.count {
            phases[bin] = atan2(spectrum.imag[bin], spectrum.real[bin])
        }
        return interpolatePhaseOnGrid(phases, sampleRate: sampleRate, fftSize: fftSize,
                                      frequencies: frequencies)
    }

    /// design-core.js:2099-2124 の interpolatePhaseOnGrid。DC を除いて unwrap し、線形の周波数で補間する。
    static func interpolatePhaseOnGrid(_ phases: [Double],
                                       sampleRate: Int,
                                       fftSize: Int,
                                       frequencies: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: frequencies.count)
        guard phases.count >= 2 else { return result }
        var sourceFrequencies = [Double](repeating: 0, count: phases.count - 1)
        for bin in 1..<phases.count {
            sourceFrequencies[bin - 1] = Double(bin) * Double(sampleRate) / Double(fftSize)
        }
        let unwrapped = unwrapPhase(Array(phases[1...]))
        var upper = 1
        for index in 0..<frequencies.count {
            let frequency = frequencies[index]
            while upper < sourceFrequencies.count && sourceFrequencies[upper] < frequency {
                upper += 1
            }
            if frequency <= sourceFrequencies[0] {
                result[index] = unwrapped[0]
            } else if upper >= sourceFrequencies.count {
                result[index] = unwrapped[unwrapped.count - 1]
            } else {
                let low = sourceFrequencies[upper - 1]
                let high = sourceFrequencies[upper]
                let fraction = (frequency - low) / (high - low)
                result[index] = unwrapped[upper - 1] + fraction * (unwrapped[upper] - unwrapped[upper - 1])
            }
        }
        return result
    }

    /// design-core.js:104-115 の unwrapPhase。
    static func unwrapPhase(_ phases: [Double]) -> [Double] {
        var output = phases
        var offset = 0.0
        guard output.count > 1 else { return output }
        for index in 1..<output.count {
            let current = output[index] + offset
            let difference = current - output[index - 1]
            if difference > Double.pi {
                offset -= 2 * Double.pi
            } else if difference < -Double.pi {
                offset += 2 * Double.pi
            }
            output[index] += offset
        }
        return output
    }

    /// design-core.js:2171-2176 の wrapPhaseDegrees。-180 以上 180 未満へ畳んで度へ。
    static func wrapPhaseDegrees(_ radians: Double) -> Double {
        var wrapped = radians.truncatingRemainder(dividingBy: 2 * Double.pi)
        if wrapped >= Double.pi {
            wrapped -= 2 * Double.pi
        } else if wrapped < -Double.pi {
            wrapped += 2 * Double.pi
        }
        return wrapped * 180 / Double.pi
    }

    // MARK: インパルス

    /// design-core.js:2254-2315 の createImpulseResponsePreview。
    /// 前の波形は 20kHz より上を落とした測定、後はそれに補正の FIR を掛けたもの。
    static func impulseResponsePreview(_ analysis: RoomEQImpulseAnalysis,
                                       taps: [Float],
                                       config: RoomEQConfig) -> RoomEQPreview.Impulse? {
        let rate = config.sampleRate
        let sampleCount = previewWindowSamples(config)
        let source = analysis.previewSamples ?? analysis.samples
        let preroll = max(1, jsRound(Double(rate) * 2 / 1000))
        let displayCount = preroll + sampleCount
        let filterDelay = config.phase == .minimum ? 0 : taps.count / 2
        let correctedCount = filterDelay + displayCount
        let fftSize = max(4, FIRDesign.nextPowerOfTwo(taps.count + correctedCount - 1))
        guard let fft = FIRDesign.fft(size: fftSize) else { return nil }

        let correctedStart = analysis.onsetIndex - preroll
        let inputStart = correctedStart - (taps.count - 1)
        var input = [Double](repeating: 0, count: fftSize)
        for index in 0..<fftSize {
            let at = inputStart + index
            // `source[i] || 0`。範囲の外と NaN は 0。
            if at >= 0 && at < source.count && !source[at].isNaN { input[index] = Double(source[at]) }
        }
        var inputSpectrum = fft.realTransform(input)
        // design-core.js:80-88。20kHz から上を落とす。
        let firstFiltered = Int((20000 * Double(fftSize) / Double(rate)).rounded(.up))
        if firstFiltered < inputSpectrum.real.count {
            for bin in max(0, firstFiltered)..<inputSpectrum.real.count {
                inputSpectrum.real[bin] = 0
                inputSpectrum.imag[bin] = 0
            }
        }
        let filteredInputTime = fft.inverseRealTransform(real: inputSpectrum.real,
                                                         imag: inputSpectrum.imag)
        let filterSpectrum = fft.realTransform(taps.map { Double($0) })
        var correctedReal = [Double](repeating: 0, count: inputSpectrum.real.count)
        var correctedImag = [Double](repeating: 0, count: inputSpectrum.imag.count)
        for bin in 0..<correctedReal.count {
            correctedReal[bin] = inputSpectrum.real[bin] * filterSpectrum.real[bin]
                - inputSpectrum.imag[bin] * filterSpectrum.imag[bin]
            correctedImag[bin] = inputSpectrum.real[bin] * filterSpectrum.imag[bin]
                + inputSpectrum.imag[bin] * filterSpectrum.real[bin]
        }
        let correctedTime = fft.inverseRealTransform(real: correctedReal, imag: correctedImag)

        let firstValid = taps.count - 1
        let afterStart = firstValid + filterDelay
        var before = [Float](repeating: 0, count: displayCount)
        var after = [Float](repeating: 0, count: displayCount)
        for index in 0..<displayCount {
            let b = firstValid + index
            let a = afterStart + index
            if b < filteredInputTime.count { before[index] = Float(filteredInputTime[b]) }
            if a < correctedTime.count { after[index] = Float(correctedTime[a]) }
        }
        return RoomEQPreview.Impulse(sampleRate: rate,
                                     startMs: -Double(preroll) * 1000 / Double(rate),
                                     durationMs: Double(sampleCount) * 1000 / Double(rate),
                                     before: before,
                                     after: after)
    }
}

// MARK: - 群遅延（js/room-eq/group-delay-analysis.js）

extension RoomEQDesigner {

    /// group-delay-analysis.js:237-245 が返すもの。格子は frequencies と同じ並び。
    struct GroupDelayAnalysis {
        var valid: [Bool]
        var totalMs: [Double]
        var minimumMs: [Double]
        var excessMs: [Double]
    }

    /// 平滑化した後の群遅延（group-delay-analysis.js:288-293）。
    struct SmoothedGroupDelay {
        var total: [Double]
        var minimum: [Double]
        var excess: [Double]
    }

    /// group-delay-analysis.js:4-6。
    static let groupDelayMagnitudeFloor = 1e-6
    static let cepstralPaddingFactor = 4

    /// group-delay-analysis.js:156-246 の analyzeRoomEqGroupDelay。
    /// 全体の遅延は H と n·h[n] の変換から直接出す（位相を unwrap しない）。
    /// 最小位相の分は 4 倍に詰めた実ケプストラムから。
    static func analyzeGroupDelay(_ samples: [Double],
                                  alignment: Int,
                                  sampleRate: Int,
                                  frequencies: [Double],
                                  minimumFftSize: Int = 0) -> GroupDelayAnalysis? {
        let fftSize = FIRDesign.nextPowerOfTwo(max(samples.count * cepstralPaddingFactor,
                                                   minimumFftSize, 4))
        guard let fft = FIRDesign.fft(size: fftSize) else { return nil }
        let spectrum = fft.realTransform(samples)
        var ramped = [Double](repeating: 0, count: samples.count)
        for index in 0..<samples.count { ramped[index] = samples[index] * Double(index) }
        let rampedSpectrum = fft.realTransform(ramped)

        let binCount = spectrum.real.count
        var magnitudes = [Double](repeating: 0, count: binCount)
        var peak = 0.0
        for bin in 0..<binCount {
            let magnitude = hypot(spectrum.real[bin], spectrum.imag[bin])
            magnitudes[bin] = magnitude
            if magnitude > peak { peak = magnitude }
        }
        let magnitudeFloor = max(Double.leastNonzeroMagnitude, peak * groupDelayMagnitudeFloor)
        var spectrumValid = [Bool](repeating: false, count: binCount)
        var totalSamples = [Double](repeating: .nan, count: binCount)
        for bin in 0..<binCount {
            guard magnitudes[bin] > magnitudeFloor else { continue }
            let power = spectrum.real[bin] * spectrum.real[bin] + spectrum.imag[bin] * spectrum.imag[bin]
            guard power > 0 else { continue }
            spectrumValid[bin] = true
            totalSamples[bin] = (rampedSpectrum.real[bin] * spectrum.real[bin]
                                 + rampedSpectrum.imag[bin] * spectrum.imag[bin]) / power
                - Double(alignment)
        }
        let minimumSamples = minimumPhaseGroupDelaySamples(magnitudes, fft: fft,
                                                           magnitudeFloor: magnitudeFloor)
        let totalGrid = interpolateLinear(totalSamples, sampleRate: sampleRate, fftSize: fftSize,
                                          frequencies: frequencies, valid: spectrumValid)
        let minimumGrid = interpolateLinear(minimumSamples, sampleRate: sampleRate, fftSize: fftSize,
                                            frequencies: frequencies, valid: spectrumValid)

        let count = frequencies.count
        var valid = [Bool](repeating: false, count: count)
        var totalMs = [Double](repeating: .nan, count: count)
        var minimumMs = [Double](repeating: .nan, count: count)
        var excessMs = [Double](repeating: .nan, count: count)
        let scale = 1000 / Double(sampleRate)
        for index in 0..<count where totalGrid.valid[index] && minimumGrid.valid[index] {
            valid[index] = true
            totalMs[index] = totalGrid.values[index] * scale
            minimumMs[index] = minimumGrid.values[index] * scale
            excessMs[index] = totalMs[index] - minimumMs[index]
        }
        return GroupDelayAnalysis(valid: valid, totalMs: totalMs,
                                  minimumMs: minimumMs, excessMs: excessMs)
    }

    /// group-delay-analysis.js:50-67 の minimumPhaseGroupDelaySamples。
    /// 実ケプストラムを折り返し、n·c[n] の変換の実部が最小位相の群遅延（標本）。
    static func minimumPhaseGroupDelaySamples(_ magnitudes: [Double],
                                              fft: FIRDesign.RealFFT,
                                              magnitudeFloor: Double) -> [Double] {
        let size = fft.size
        let half = size / 2
        var logMagnitude = [Double](repeating: 0, count: magnitudes.count)
        for bin in 0..<magnitudes.count {
            logMagnitude[bin] = log(magnitudes[bin] > magnitudeFloor ? magnitudes[bin] : magnitudeFloor)
        }
        var cepstrum = fft.inverseRealTransform(real: logMagnitude,
                                                imag: [Double](repeating: 0, count: logMagnitude.count))
        if half > 1 { for index in 1..<half { cepstrum[index] *= 2 } }
        if half + 1 < size { for index in (half + 1)..<size { cepstrum[index] = 0 } }
        var derivative = [Double](repeating: 0, count: size)
        for index in 0..<size { derivative[index] = cepstrum[index] * Double(index) }
        return fft.realTransform(derivative).real
    }

    /// group-delay-analysis.js:14-48 の interpolateLinear。bin の並びから格子へ線形に写す。
    /// 端の bin が無効なら NaN にして無効と印を付ける。
    static func interpolateLinear(_ values: [Double],
                                  sampleRate: Int,
                                  fftSize: Int,
                                  frequencies: [Double],
                                  valid: [Bool]?) -> (values: [Double], valid: [Bool]) {
        var result = [Double](repeating: 0, count: frequencies.count)
        var resultValid = [Bool](repeating: false, count: frequencies.count)
        guard !values.isEmpty else { return (result, resultValid) }
        for index in 0..<frequencies.count {
            let position = frequencies[index] * Double(fftSize) / Double(sampleRate)
            var lower = position.isFinite ? Int(position.rounded(.down)) : 0
            if lower < 0 { lower = 0 }
            if lower >= values.count - 1 { lower = values.count - 1 }
            let upper = lower < values.count - 1 ? lower + 1 : lower
            let fraction = upper == lower ? 0 : position - Double(lower)
            let lowerValid = valid.map { $0[lower] } ?? true
            let upperValid = valid.map { $0[upper] } ?? true
            let exactLower = abs(fraction) < 1e-10
            let exactUpper = abs(1 - fraction) < 1e-10
            if exactUpper {
                if !upperValid || !values[upper].isFinite {
                    result[index] = .nan
                    continue
                }
                result[index] = values[upper]
                resultValid[index] = true
                continue
            }
            if !lowerValid || !values[lower].isFinite
                || (!exactLower && (!upperValid || !values[upper].isFinite)) {
                result[index] = .nan
                continue
            }
            result[index] = exactLower
                ? values[lower]
                : values[lower] + fraction * (values[upper] - values[lower])
            resultValid[index] = true
        }
        return (result, resultValid)
    }

    /// group-delay-analysis.js:271-294 の smoothRoomEqGroupDelay。
    static func smoothGroupDelay(_ analysis: GroupDelayAnalysis,
                                 frequencies: [Double],
                                 smoothing: Double) -> SmoothedGroupDelay {
        let total = smoothGroupDelayRuns(frequencies: frequencies, values: analysis.totalMs,
                                         valid: analysis.valid, smoothing: smoothing)
        let minimum = smoothGroupDelayRuns(frequencies: frequencies, values: analysis.minimumMs,
                                           valid: analysis.valid, smoothing: smoothing)
        var excess = [Double](repeating: .nan, count: frequencies.count)
        for index in 0..<excess.count where analysis.valid[index] {
            excess[index] = total[index] - minimum[index]
        }
        return SmoothedGroupDelay(total: total, minimum: minimum, excess: excess)
    }

    /// group-delay-analysis.js:110-133 の smoothRoomEqGroupDelayRuns。
    /// 有効な区間ごとに平滑化し、無効な所は NaN のまま残す（曲線はそこで切れる）。
    static func smoothGroupDelayRuns(frequencies: [Double],
                                     values: [Double],
                                     valid: [Bool],
                                     smoothing: Double) -> [Double] {
        var output = values
        var first = 0
        while first < output.count {
            while first < output.count && !(valid[first] && output[first].isFinite) {
                output[first] = .nan
                first += 1
            }
            var last = first
            while last < output.count && valid[last] && output[last].isFinite { last += 1 }
            if last > first {
                let smoothed = smoothFrequencyResponse(frequencies: Array(frequencies[first..<last]),
                                                       magnitudes: Array(output[first..<last]),
                                                       sigma: smoothing)
                for index in first..<last { output[index] = smoothed[index - first] }
            }
            first = last
        }
        return output
    }

    /// group-delay-analysis.js:296-317 の combineRoomEqGroupDelay。補正の前に FIR の分を足す。
    static func combineGroupDelay(_ first: GroupDelayAnalysis,
                                  _ second: GroupDelayAnalysis) -> GroupDelayAnalysis {
        let count = min(first.valid.count, second.valid.count)
        var result = GroupDelayAnalysis(valid: [Bool](repeating: false, count: count),
                                        totalMs: [Double](repeating: .nan, count: count),
                                        minimumMs: [Double](repeating: .nan, count: count),
                                        excessMs: [Double](repeating: .nan, count: count))
        for index in 0..<count where first.valid[index] && second.valid[index] {
            result.valid[index] = true
            result.totalMs[index] = first.totalMs[index] + second.totalMs[index]
            result.minimumMs[index] = first.minimumMs[index] + second.minimumMs[index]
            result.excessMs[index] = result.totalMs[index] - result.minimumMs[index]
        }
        return result
    }

    /// group-delay-analysis.js:319-353 の averageRoomEqGroupDelay。有効なものだけで平均する。
    static func averageGroupDelay(_ analyses: [GroupDelayAnalysis]) -> GroupDelayAnalysis? {
        guard let count = analyses.first?.valid.count,
              analyses.allSatisfy({ $0.valid.count == count }) else { return nil }
        var result = GroupDelayAnalysis(valid: [Bool](repeating: false, count: count),
                                        totalMs: [Double](repeating: .nan, count: count),
                                        minimumMs: [Double](repeating: .nan, count: count),
                                        excessMs: [Double](repeating: .nan, count: count))
        for index in 0..<count {
            var total = 0.0
            var minimum = 0.0
            var used = 0
            for analysis in analyses where analysis.valid[index] {
                total += analysis.totalMs[index]
                minimum += analysis.minimumMs[index]
                used += 1
            }
            guard used > 0 else { continue }
            result.valid[index] = true
            result.totalMs[index] = total / Double(used)
            result.minimumMs[index] = minimum / Double(used)
            result.excessMs[index] = result.totalMs[index] - result.minimumMs[index]
        }
        return result
    }
}
