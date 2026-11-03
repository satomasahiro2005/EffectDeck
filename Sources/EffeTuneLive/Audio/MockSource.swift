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

    /// 信号の種類。`-ETMockMode` で選ぶ（`-ETMock 1` と一緒に渡す）。
    ///   - tone（既定）: 下の「それらしい」信号。
    ///   - clip: 同じ信号を 0 dBFS を越えるまで持ち上げる（Analog Meter の over ランプと
    ///     ピークホールドを撮るため。出力は ±1 で打ち切る）。
    ///   - silence: 無音（"-∞" の読みを撮るため）。
    ///   - music: 120 BPM のキック・スネア・ハット・ベース・和音（Rhythm Analyzer と
    ///     VU の針の動きを撮るため）。ゆっくりした強弱（1〜2Hz のアクセント ±6〜10 dB と、
    ///     2 秒の静かな区間）が付き、VU のバリスティクスが見える。
    enum Mode: String {
        case tone, clip, silence, music
    }

    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: "ETMockMode") ?? "") ?? .tone
    }

    /// 和音。A2 を根にした長三和音。倍音は 1/n で落とす。（周波数, 振幅）
    static let chord: [(frequency: Double, amplitude: Double)] = [
        (110.0, 0.50), (138.6, 0.32), (164.8, 0.26),
        (220.0, 0.18), (330.0, 0.10), (440.0, 0.06),
    ]

    /// 掃引。300Hz から 6kHz を 7 秒かけて往復する。
    static let sweepLow = 300.0, sweepHigh = 6000.0, sweepPeriod = 7.0

    /// 右を遅らせる秒数。
    static let rightDelay = 0.00035

    /// 位相を戻す周期（秒）。倍精度でも丸めが効いてくるので、十分長い周期で折り返す。
    ///
    /// **戻した先で全部の成分がちょうど元の位相に居る長さにする。** 7 秒（掃引の往復）、
    /// 3.1 秒（強弱）、それに 138.6Hz と 164.8Hz（どちらも 1/5Hz 刻みなので 5 秒）の
    /// 公倍数で 1085 秒。前は 217 秒（7 と 3.1 の公倍数）で、138.6Hz と 164.8Hz が
    /// 0.2 と 0.6 周期の半端で切れ、217 秒ごとに波形が跳んでいた。
    static let wrapSeconds = 1085.0

    private let sampleRate: Double
    /// 通した標本の数（wrapSeconds で戻る）。位相はここから出す。
    private(set) var phase: Double = 0
    /// 掃引の位相（周期の数、0..<1）。**周波数を積分して出す。**
    /// 周波数に t を掛けて sin に入れると、瞬時周波数が f0 + t·f0' になって秒を追うごとに
    /// 上へ散る（10 秒で数十 kHz、折り返して帯域全体に撒かれる）。
    private var sweepPhase: Double = 0

    private let mode: Mode
    /// music の持ち上げ（倍率）。`-ETMockGainDB <dB>` で選ぶ。既定は 0 dB。
    private let musicBoost: Float

    init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
        self.mode = Self.mode
        let db = UserDefaults.standard.double(forKey: "ETMockGainDB")
        self.musicBoost = Float(pow(10.0, db / 20.0))
    }

    // MARK: music

    static let musicBPM = 120.0
    /// 出力の大きさ。0.8 から -12 dB。実際の曲に近い -23 LUFS 前後・True Peak -1 dBTP 未満で、
    /// 針の目盛り（Reference -14・Target -23）を確かめられる。撮影用の道具で、製品の音ではない。
    static let musicGain = 0.8 * 0.251188643150958

    /// music の強弱の周期（秒）。各成分（1Hz・2Hz・0.25Hz）の周期の公倍数。
    static let envelopePeriod = 16.0
    /// 静かな区間（周期の中の秒）と、その深さ（dB）、出入りの傾き（秒）。
    static let quietStart = 10.0, quietLength = 2.0, quietDepthDB = -12.0, quietRamp = 0.25

    /// t 秒での強弱（dB、正規化前）。1Hz と 2Hz のアクセントの重ね合わせで ±8 dB ほど、
    /// その振れ幅を 4 秒周期で ±25% 動かして ±6〜10 dB にする。静かな区間では全体を下げる。
    static func envelopeRawDB(at t: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        let swing = 5.0 * sin(twoPi * t) + 3.0 * sin(twoPi * 2 * t + 1.0)
        let depth = 1.0 + 0.25 * sin(twoPi * t / 4)
        let u = t.truncatingRemainder(dividingBy: envelopePeriod)
        func smooth(_ x: Double) -> Double { let c = max(0, min(1, x)); return c * c * (3 - 2 * c) }
        let quiet = smooth((u - quietStart) / quietRamp) * (1 - smooth((u - quietStart - quietLength) / quietRamp))
        return swing * depth + quietDepthDB * quiet
    }

    /// 強弱の振幅の倍率。1 周期の平均パワーが 1 になるよう正規化し、さらに -0.73 dB 下げてある
    /// （BS.1770 で測ると統合 -23.0 LUFS。静かな区間がゲートで落ちるぶん正規化だけだと +0.7 LU 高い）。
    /// 強弱を付けてもサンプルピークは約 -7.4 dBFS で、True Peak は -1 dBTP を十分下回る。
    static let envelopeNorm: Double = {
        let steps = 1600
        var power = 0.0
        for i in 0..<steps {
            let db = envelopeRawDB(at: envelopePeriod * Double(i) / Double(steps))
            power += pow(10.0, db / 10.0)
        }
        return envelopeTrim / (power / Double(steps)).squareRoot()
    }()
    private static let envelopeTrim = pow(10.0, -0.73 / 20.0)

    @inline(__always)
    static func envelope(at t: Double) -> Double {
        pow(10.0, envelopeRawDB(at: t) / 20.0) * envelopeNorm
    }

    /// 決まった乱数。標本の番号から作る（確保も状態も要らない）。
    @inline(__always)
    private static func noise(_ n: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: n) &* 0x9E3779B97F4A7C15
        x ^= x >> 29
        x = x &* 0xBF58476D1CE4E5B9
        x ^= x >> 32
        return Double(x & 0xFFFFFF) / Double(0x7FFFFF) - 1.0
    }

    /// 1 標本ぶんの音楽。4 つ打ちのキック、2・4 拍のスネア、裏のハット、
    /// 8 分のベース、2 小節ごとに変わる和音。右は左と少しだけ違う（ハットを振る）。
    static func music(sample n: Int, sampleRate sr: Double) -> (left: Float, right: Float) {
        let twoPi = 2.0 * Double.pi
        let t = Double(n) / sr
        let beat = 60.0 / musicBPM
        let step = beat / 2                       // 8 分
        let inBeat = t.truncatingRemainder(dividingBy: beat)
        let beatIndex = Int(t / beat)
        let inStep = t.truncatingRemainder(dividingBy: step)
        let stepIndex = Int(t / step)

        // キック。120Hz から 48Hz へ落とす正弦。
        let kickPhase = twoPi * (48.0 * inBeat + 72.0 * 0.045 * (1 - exp(-inBeat / 0.045)))
        let kick = sin(kickPhase) * exp(-inBeat / 0.16) * 0.85

        // スネア（2・4 拍）。雑音と 190Hz の胴。
        var snare = 0.0
        if beatIndex % 2 == 1 {
            snare = (noise(n) * 0.5 + sin(twoPi * 190 * inBeat) * 0.35) * exp(-inBeat / 0.09) * 0.55
        }

        // ハット（裏の 8 分）。高域だけの短い雑音（隣の標本との差で高域を取る）。
        var hat = 0.0
        if stepIndex % 2 == 1 {
            hat = (noise(n) - noise(n - 1)) * 0.5 * exp(-inStep / 0.025) * 0.28
        }

        // ベース。8 分ごとに根音（A2 / F2 / C2 / G2）を鳴らす。
        let roots: [Double] = [110.0, 87.31, 65.41, 98.0]
        let bar = Int(t / (beat * 4))
        let root = roots[(bar / 2) % roots.count]
        let bassEnv = exp(-inStep / 0.22)
        let bass = sin(twoPi * root * t) * bassEnv * 0.34

        // 和音（根音の長三和音を 2 小節ごとに）。
        let pad = (sin(twoPi * root * 2 * t) + 0.8 * sin(twoPi * root * 2 * 1.2599 * t)
                   + 0.7 * sin(twoPi * root * 2 * 1.4983 * t)) * 0.07

        let l = kick + snare + hat * 0.8 + bass + pad
        let r = kick + snare * 0.95 + hat * 1.2 + bass + pad * 0.9
        let g = musicGain * envelope(at: t)
        return (Float(max(-1, min(1, l * g))), Float(max(-1, min(1, r * g))))
    }

    /// t 秒での掃引の周波数。下と上を指数で往復する。
    static func sweepFrequency(at t: Double) -> Double {
        let u = (t.truncatingRemainder(dividingBy: sweepPeriod)) / sweepPeriod
        let tri = u < 0.5 ? u * 2 : (1 - u) * 2
        return sweepLow * pow(sweepHigh / sweepLow, tri)
    }

    /// 1 標本。
    /// - Parameters:
    ///   - t: 秒。
    ///   - sweep: 掃引の位相（周期の数）。
    ///   - f0: いまの掃引の周波数（右の遅れを位相に直すのに使う）。
    static func frame(t: Double, sweep: Double, sweepFrequency f0: Double) -> (left: Float, right: Float) {
        let twoPi = 2.0 * Double.pi

        var v = 0.0
        for c in chord { v += c.amplitude * sin(twoPi * c.frequency * t) }
        v += 0.12 * sin(twoPi * sweep)
        // 薄い雑音。乱数は使わず、素数比の正弦を掛けて代わりにする。
        v += 0.02 * sin(twoPi * 7331.0 * t) * sin(twoPi * 1117.0 * t)

        // ゆっくりした強弱。0.35 〜 1.0 のあいだを 3.1 秒周期で。
        let env = 0.675 + 0.325 * sin(twoPi * t / 3.1)
        v *= env * 0.42

        // 左右をずらす。右は少し遅らせて、少し小さくする。
        let tR = t - rightDelay
        var vR = 0.0
        for c in chord { vR += c.amplitude * sin(twoPi * c.frequency * tR) }
        vR += 0.12 * sin(twoPi * (sweep - f0 * rightDelay))
        vR *= env * 0.42 * 0.88

        return (Float(max(-1, min(1, v))), Float(max(-1, min(1, vR))))
    }

    /// インターリーブ（L,R,L,R…）で frames ぶん書く。
    func fill(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let sr = sampleRate
        switch mode {
        case .silence:
            for i in 0..<max(0, frames * 2) { out[i] = 0 }
            return
        case .music:
            // 位相は整数の標本番号で持つ（折り返しは 1085 秒だと拍が合わないので、2 時間で戻す）。
            let base = Int(phase)
            for i in 0..<max(0, frames) {
                let s = Self.music(sample: base + i, sampleRate: sr)
                out[i * 2] = max(-1, min(1, s.left * musicBoost))
                out[i * 2 + 1] = max(-1, min(1, s.right * musicBoost))
            }
            phase += Double(max(0, frames))
            if phase >= sr * 7200 { phase -= sr * 7200 }
            return
        case .tone, .clip:
            break
        }
        let gain: Float = mode == .clip ? 4.0 : 1
        for i in 0..<max(0, frames) {
            let t = (phase + Double(i)) / sr
            let f0 = Self.sweepFrequency(at: t)
            let s = Self.frame(t: t, sweep: sweepPhase, sweepFrequency: f0)
            out[i * 2]     = max(-1, min(1, s.left * gain))
            out[i * 2 + 1] = max(-1, min(1, s.right * gain))
            sweepPhase += f0 / sr
            sweepPhase -= sweepPhase.rounded(.down)
        }
        phase += Double(max(0, frames))
        let wrap = sr * Self.wrapSeconds
        if phase >= wrap { phase -= wrap }
    }
}
