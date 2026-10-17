//  RealFFT.swift
//  実数列の FFT。Swift だけの基数 2（Accelerate に頼らないので Linux でも測れる。Tests/Unit/RealFFTTests.swift）。
//
//  使うのは NCS の帯（2048 点）と Skip 検出器（1024 点）。どちらも読み手のキューの上で 1 秒に数十回。
//  速さより「正しいこと」を取る。作業用の領域は自分で持つので、**1 つのインスタンスは 1 人だけが使う**
//  （スレッドを跨いで共有しない）。

import Foundation

final class ETRealFFT {
    let size: Int
    /// ビット反転の並べ替え。
    private let reversed: [Int]
    /// cos(2πk/N)・sin(2πk/N)（k = 0..<N/2）。
    private let cosTable: [Double]
    private let sinTable: [Double]
    private var re: [Double]
    private var im: [Double]

    /// size は 2 のべき乗（2 以上）。
    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "size must be a power of two")
        self.size = size
        let bits = size.trailingZeroBitCount
        var table = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var x = i, r = 0
            for _ in 0..<bits {
                r = (r << 1) | (x & 1)
                x >>= 1
            }
            table[i] = r
        }
        reversed = table
        cosTable = (0..<size / 2).map { cos(2 * Double.pi * Double($0) / Double(size)) }
        sinTable = (0..<size / 2).map { sin(2 * Double.pi * Double($0) / Double(size)) }
        re = [Double](repeating: 0, count: size)
        im = [Double](repeating: 0, count: size)
    }

    /// 窓をかけて並べ替えながら読み込み、変換する。足りない分は 0。window が空なら窓なし。
    private func transform(_ input: UnsafeBufferPointer<Float>, window: [Float]) {
        let n = size
        let count = min(input.count, n)
        let windowed = window.count >= n
        for i in 0..<n {
            let v = i < count ? Double(input[i]) * (windowed ? Double(window[i]) : 1) : 0
            let j = reversed[i]
            re[j] = v
            im[j] = 0
        }
        var length = 2
        while length <= n {
            let half = length / 2
            let step = n / length
            var start = 0
            while start < n {
                for j in 0..<half {
                    let wr = cosTable[j * step], wi = -sinTable[j * step]
                    let a = start + j, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += length
            }
            length <<= 1
        }
    }

    /// |X_k|（k = 0...N/2。N/2 + 1 個）。大きさは掛け直さない。
    func magnitudes(_ input: UnsafeBufferPointer<Float>, window: [Float], into out: inout [Float]) {
        transform(input, window: window)
        let bins = size / 2 + 1
        if out.count != bins { out = [Float](repeating: 0, count: bins) }
        for k in 0..<bins { out[k] = Float((re[k] * re[k] + im[k] * im[k]).squareRoot()) }
    }

    /// |X_k|²（k = 0...N/2）。
    func power(_ input: UnsafeBufferPointer<Float>, window: [Float], into out: inout [Float]) {
        transform(input, window: window)
        let bins = size / 2 + 1
        if out.count != bins { out = [Float](repeating: 0, count: bins) }
        for k in 0..<bins { out[k] = Float(re[k] * re[k] + im[k] * im[k]) }
    }
}
