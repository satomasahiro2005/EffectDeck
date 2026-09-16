//  SpectrumSmoothing.swift
//  スペクトラムを 1/12 オクターブ幅で均す。
//
//  上流 Vendor/effetune/plugins/spectrum-overlay.js:86-93, 128-142 の移植。
//  あちらは main スレッドで自前の 4096 点 FFT を回し、電力の並びを持ったまま均している:
//
//      smoothingFirst[i] = Math.ceil(i / SMOOTHING_EDGE_RATIO);
//      const end = Math.floor(i * SMOOTHING_EDGE_RATIO) + 1;
//      smoothingEnd[i]   = end < power.length ? end : power.length;
//      ...
//      const average = sum / (targetEnd - targetFirst);
//      spectrum[i] = 10 * Math.log10(average > POWER_FLOOR ? average : POWER_FLOOR);
//
//  こちらに来るのは Spectrum Analyzer カーネルが出した **dB の並び**なので、
//  先に電力へ戻す。戻した数が上流の power[] と同じになることは式で確かめられる:
//
//      kernel.cpp:450  level = 10*log10(raw + 1e-24) + correction(dB)
//      10^(level/10) = (raw + 1e-24) * 10^(correction/10)
//      overlay.js:122-126  power[i] = (raw + 1e-24) * correction(linear)
//
//  10^(12.041199826559248/10) = 16 = POWER_CORRECTION_AC、
//  10^(6.020599913279624/10) = 4 = POWER_CORRECTION_DC（kernel.cpp:43-44 と
//  spectrum-overlay.js:7-8）。補正が同じ数なので、dB→電力→移動平均→dB で
//  上流と同じ列が出る。
//
//  **ピーク保持には掛けない。** 上流のオーバーレイにピークの線は無い
//  （spectrum-overlay.js:391-421 は levels 1 本しか引かない）。
//
//  ここに SwiftUI を入れない。単体テスト（Tests/Unit/SpectrumSmoothingTests.swift）が
//  この 1 本だけをコンパイルして数で照合する。

import Foundation

enum ETSpectrumSmoothing {

    /// spectrum-overlay.js:9 の SMOOTHING_EDGE_RATIO。
    /// 上下に 2^(1/24) ずつ広げるので、窓の幅は合わせて 1/12 オクターブ。
    static let edgeRatio = pow(2.0, 1.0 / 24.0)

    /// spectrum-overlay.js:5 の POWER_FLOOR。
    static let powerFloor = 1.0e-24

    /// spectrum-overlay.js:6 の NUMERIC_FLOOR_DB。10*log10(1e-24) = -240。
    static let floorDB = 10 * log10(powerFloor)

    /// dB の並びを 1/12 オクターブ幅の矩形窓で均す。入出力とも dB。
    ///
    /// 窓の端は bin 番号だけで決まる（周波数も標本化周波数も要らない）。
    /// bin 0 は first = 0, end = 1 で自分だけになるが、描く側は bin 0 を使わない
    /// （spectrum-overlay.js:398 の `for (let i = 1; ...)`）。
    static func twelfthOctave(decibels: [Float]) -> [Float] {
        let n = decibels.count
        guard n > 1 else { return decibels }

        // dB → 電力。読めない値は床に落とす（0 にすると log で -inf が出る）。
        var power = [Double](repeating: powerFloor, count: n)
        for i in 0..<n {
            let db = Double(decibels[i])
            guard db.isFinite else { continue }
            let p = pow(10, db * 0.1)
            power[i] = p.isFinite && p > powerFloor ? p : powerFloor
        }

        // 移動和。窓の両端は i について単調に増えるので、1 度なめれば足りる
        // （上流のコメント "A moving sum keeps smoothing linear"、同 :129-130）。
        var out = [Float](repeating: Float(floorDB), count: n)
        var first = 0
        var end = 0
        var sum = 0.0
        for i in 0..<n {
            let targetEnd = min(Int((Double(i) * edgeRatio).rounded(.down)) + 1, n)
            while end < targetEnd {
                sum += power[end]
                end += 1
            }
            let targetFirst = Int((Double(i) / edgeRatio).rounded(.up))
            while first < targetFirst {
                sum -= power[first]
                first += 1
            }
            // targetFirst <= i < targetEnd なので幅は必ず 1 以上になるが、
            // 0 で割ると図が丸ごと消えるので念のため見る。
            let width = targetEnd - targetFirst
            guard width > 0 else { continue }
            let average = sum / Double(width)
            out[i] = Float(10 * log10(average > powerFloor ? average : powerFloor))
        }
        return out
    }
}
