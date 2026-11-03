//  BassManagementDesign.swift
//  Bass ManagementのLinear位相の設計の半分（Foundationだけ）。入力ごとの低域FIRと、
//  送り込める形（ETA1のペイロード）までを作る。
//
//  上流のVendor/effetune/js/bass-management/design-core.js（designBassManagement）と
//  design-worker.js（経路と資産の組み立て）を移したもの。設計の本体はFIRCrossoverDesignCoreを
//  そのまま呼ぶ。カーネルへ送り込む半分（@MainActorのBassManagementDesigner）は
//  BassManagementDesigner.swiftに残してある。資産の条件はそちらの頭に書いてある。
//
//  ここはEffeTuneDSPにもet_*にも触らないので、Logicのテストへそのまま入れられる
//  （BassManagementDesignTests。見本はTools/golden/designers_a_golden.mjsが上流に作らせる）。
//  使うのはFIRCrossoverDesign.swift・FIRDesign・AssetUpload.makePayload（AssetPayload.swift）・
//  BassManagementDesignKey（BassManagementSettings.swift）。

import Foundation

// MARK: - 設計の結果

/// 設計して、送り込める形まで畳んだもの。応答は図に使う。
struct BassManagementDesign: Sendable {
    let key: BassManagementDesignKey
    let payload: [UInt8]
    /// 資産の経路の順（＝ key.filters の順）。
    let inputChannels: [Int]
    /// 入力ごとの |H|。responseFrequencies の点で取ったもの（design-core.js:84-88）。
    let responses: [[Float]]
    let responseFrequencies: [Double]

    /// この入力の応答。設計したときの (cutoff, slope) が今と同じときだけ返す。
    func response(channel: Int, cutoff: Double, slope: Int, sampleRate: Int) -> [Float]? {
        guard key.sampleRate == sampleRate,
              let index = key.filters.firstIndex(where: { $0.channel == channel }),
              key.filters[index].cutoff == cutoff, key.filters[index].slope == slope,
              responses.indices.contains(index) else { return nil }
        return responses[index]
    }
}

// MARK: - 設計そのもの（design-core.js の移植）

/// 状態を持たない。重いので必ず UI スレッドの外で呼ぶこと。
enum BassManagementDesignCore {

    /// design-core.js:51-57。10Hz から min(20k, 0.48·sr) までの対数 160 点。
    static func responseFrequencies(sampleRate: Int, count: Int = 160) -> [Double] {
        let maximum = min(20000, Double(sampleRate) * 0.48)
        let minimumLog = log(10.0)
        let span = log(maximum) - minimumLog
        return (0..<count).map { index in
            exp(minimumLog + span * Double(index) / Double(max(1, count - 1)))
        }
    }

    /// design-core.js:59-118 と design-worker.js:34-45。
    static func design(_ key: BassManagementDesignKey) throws -> BassManagementDesign {
        let frequencies = responseFrequencies(sampleRate: key.sampleRate)
        var designs: [String: (impulse: [Float], response: [Float])] = [:]
        var channels: [[Float]] = []
        var responses: [[Float]] = []

        for filter in key.filters {
            // design-core.js:73。JS は `${cutoff}:${slope}` で引く。
            let cacheKey = "\(filter.cutoff):\(filter.slope)"
            if designs[cacheKey] == nil {
                // design-core.js:76-83。designFIRCrossover の normalizeConfig も通す。
                let config = FIRCrossoverDesignCore.normalize(
                    sampleRate: Double(key.sampleRate),
                    taps: key.taps,
                    phase: .linear,
                    bandCount: 2,
                    frequencies: [filter.cutoff, filter.cutoff, filter.cutoff],
                    slopes: [filter.slope, filter.slope, filter.slope])
                let impulse = try FIRCrossoverDesignCore.design(config).channels[0]
                let response = try FIRCrossoverDesignCore.analyzeFIR(
                    impulse, sampleRate: Double(key.sampleRate), frequencies: frequencies)
                designs[cacheKey] = (impulse, response)
            }
            if let designed = designs[cacheKey] {
                channels.append(designed.impulse)
                responses.append(designed.response)
            }
        }

        // design-worker.js:34-38。入力 ch をそのまま出力 ch へ、IR は設計した順。
        let paths = key.filters.enumerated().map { index, filter in
            ETAssetPath(inputSlot: UInt32(filter.channel),
                        outputSlot: UInt32(filter.channel),
                        irChannel: UInt32(index))
        }
        let payload = try AssetUpload.makePayload(channels: channels,
                                                  sampleRate: key.sampleRate,
                                                  topology: .matrix,
                                                  paths: paths)
        return BassManagementDesign(key: key,
                                    payload: payload,
                                    inputChannels: key.filters.map(\.channel),
                                    responses: responses,
                                    responseFrequencies: frequencies)
    }
}

extension FIRCrossoverDesignCore {

    /// fir-crossover/design-core.js:82-106 の analyzeFIRAtFrequencies（2.11.0 で増えた）。
    /// 長さの 2 倍に 0 を詰めて変換し、各周波数の |H| を隣の bin と線形に補う。
    static func analyzeFIR(_ channel: [Float],
                           sampleRate: Double,
                           frequencies: [Double]) throws -> [Float] {
        let fftSize = channel.count * 2
        guard let fft = FIRDesign.fft(size: fftSize) else {
            throw FIRCrossoverDesignError.fftUnavailable(size: fftSize)
        }
        let spectrum = fft.realTransform(channel.map { Double($0) })
        let last = spectrum.real.count - 1
        return frequencies.map { frequency in
            let position = max(0, min(Double(last), frequency * Double(fftSize) / sampleRate))
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, last)
            let fraction = position - Double(lower)
            let lowerMagnitude = hypot(spectrum.real[lower], spectrum.imag[lower])
            if upper == lower { return Float(lowerMagnitude) }
            let upperMagnitude = hypot(spectrum.real[upper], spectrum.imag[upper])
            return Float(lowerMagnitude + (upperMagnitude - lowerMagnitude) * fraction)
        }
    }
}
