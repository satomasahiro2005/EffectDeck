//  MockSource.swift
//  撮影のときだけ流す、作り物の信号。
//
//  シミュレータには拡張が無いので音が来ない。そのままだと
//  「No audio yet」の画面しか撮れず、メーターも図も全部止まったものになる。
//  画面の半分が見られないので、-ETMock 1 のときだけここが音を作る。
//
//  作る音は「それらしく見える」ことだけを狙う。音楽である必要は無い。
//    - 低音（和音の根音）と、その倍音をいくつか
//    - 上を行き来する掃引。スペアナとスペクトログラムに斜めの筋が出る
//    - 薄い雑音。床が真っ平らにならないように
//    - ゆっくりした強弱。レベルメーターとコンプの GR が動く
//    - 左右で少しずらす。ステレオメーターが点にならない
//
//  実機では -ETMock が付かないので、この型は何もしない。

import Foundation

/// 撮影用の信号を作る。音のスレッドから呼ばれるので、確保も ObjC も使わない。
final class ETMockSource {

    /// 起動の引数で入っているか。
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "ETMock")
    }

    private let sampleRate: Double
    private var phase: Double = 0          // 通した標本の数。位相はここから出す

    init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
    }

    /// インターリーブ（L,R,L,R…）で frames ぶん書く。
    func fill(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let sr = sampleRate
        let twoPi = 2.0 * Double.pi

        for i in 0..<frames {
            let t = (phase + Double(i)) / sr

            // 和音。A2 を根にした長三和音。倍音は 1/n で落とす。
            var v = 0.0
            for (f, a) in [(110.0, 0.50), (138.6, 0.32), (164.8, 0.26),
                           (220.0, 0.18), (330.0, 0.10), (440.0, 0.06)] {
                v += a * sin(twoPi * f * t)
            }

            // 掃引。300Hz から 6kHz を 7 秒かけて往復する。
            // 位相は積分で出す（周波数をそのまま sin に入れると折り返す）。
            let sweepLo = 300.0, sweepHi = 6000.0, period = 7.0
            let u = (t.truncatingRemainder(dividingBy: period)) / period
            let tri = u < 0.5 ? u * 2 : (1 - u) * 2
            let f0 = sweepLo * pow(sweepHi / sweepLo, tri)
            v += 0.12 * sin(twoPi * f0 * t)

            // 薄い雑音。乱数は使わず、素数比の正弦を足して代わりにする。
            v += 0.02 * sin(twoPi * 7331.0 * t) * sin(twoPi * 1117.0 * t)

            // ゆっくりした強弱。0.35 〜 1.0 のあいだを 3.1 秒周期で。
            let env = 0.675 + 0.325 * sin(twoPi * t / 3.1)
            v *= env * 0.42

            // 左右をずらす。右は少し遅らせて、少し小さくする。
            let tR = t - 0.00035
            var vR = 0.0
            for (f, a) in [(110.0, 0.50), (138.6, 0.32), (164.8, 0.26),
                           (220.0, 0.18), (330.0, 0.10), (440.0, 0.06)] {
                vR += a * sin(twoPi * f * tR)
            }
            vR += 0.12 * sin(twoPi * f0 * tR)
            vR *= env * 0.42 * 0.88

            out[i * 2]     = Float(max(-1, min(1, v)))
            out[i * 2 + 1] = Float(max(-1, min(1, vR)))
        }
        phase += Double(frames)
        // 位相を戻す。倍精度でも丸めが効いてくるので、十分長い周期で折り返す。
        // 7 秒（掃引）と 3.1 秒（強弱）の公倍数に近い 217 秒ぶんで戻す。
        let wrap = sampleRate * 217.0
        if phase >= wrap { phase -= wrap }
    }
}
