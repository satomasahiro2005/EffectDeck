//  vDSP.swift（Linuxの代役）
//  FIRDesign.RealFFTが使うvDSPのDouble版だけを、Tests/Linux/run.shの中で置き換える。
//  **製品には入らない。**
//
//  vDSP_create_fftsetupD / vDSP_destroy_fftsetupD / vDSP_ctozD / vDSP_ztocD / vDSP_fft_zripD と、
//  それが取る型・定数。詰め方はAppleの文書（vDSP.hの疑似コードとvDSP Programming Guideの
//  "Data Packing for Real FFTs"・"Scaling Fourier Transforms"）どおり:
//    - 前進: realp[0]=2·X[0]、imagp[0]=2·X[N/2]、k=1…N/2-1はrealp[k]+i·imagp[k]=2·X[k]
//      （X[k]=Σx[n]·e^(-2πikn/N)）
//    - 逆: 同じ詰め方の入力Sを共役で全帯域へ広げ、y[n]=ΣS[k]·e^(+2πikn/N)（1/Nを掛けない）。
//      前進→逆で2N倍になる
//  **代役なので、詰め方そのものを確かめるテストはMacでしか意味が無い。**
//  ここで通るのは「この代役とFIRDesignの約束が合っている」ことまで。

import Foundation

public typealias vDSP_Length = UInt
public typealias vDSP_Stride = Int
public typealias FFTDirection = Int32
public typealias FFTRadix = Int32
public typealias FFTSetupD = OpaquePointer

// Appleでは名前の無いenumなのでIntで入ってくる。
public var kFFTDirection_Forward: Int { 1 }
public var kFFTDirection_Inverse: Int { -1 }
public var kFFTRadix2: Int { 0 }
public var kFFTRadix3: Int { 1 }
public var kFFTRadix5: Int { 2 }

public struct DSPDoubleComplex {
    public var real: Double
    public var imag: Double
    public init() { real = 0; imag = 0 }
    public init(real: Double, imag: Double) {
        self.real = real
        self.imag = imag
    }
}

public struct DSPDoubleSplitComplex {
    public var realp: UnsafeMutablePointer<Double>
    public var imagp: UnsafeMutablePointer<Double>
    public init(realp: UnsafeMutablePointer<Double>, imagp: UnsafeMutablePointer<Double>) {
        self.realp = realp
        self.imagp = imagp
    }
}

private final class FFTSetupBox {
    let log2n: Int
    /// cos(2πt/N)とsin(2πt/N)、t=0…N/2-1（Nはsetupで作った最大の長さ）。
    let cosTable: [Double]
    let sinTable: [Double]

    init(log2n: Int) {
        self.log2n = log2n
        let n = 1 << log2n
        var c = [Double](repeating: 0, count: max(n / 2, 1))
        var s = [Double](repeating: 0, count: max(n / 2, 1))
        for t in 0..<(n / 2) {
            let angle = 2 * Double.pi * Double(t) / Double(n)
            c[t] = cos(angle)
            s[t] = sin(angle)
        }
        cosTable = c
        sinTable = s
    }

    /// 長さ2^log2nの複素DFT（その場で）。inverseのときe^(+)、どちらも正規化しない。
    func transform(_ re: inout [Double], _ im: inout [Double], log2n bits: Int, inverse: Bool) {
        let n = 1 << bits
        var j = 0
        for i in 0..<(n - 1) {
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
            var m = n >> 1
            while m >= 1 && j & m != 0 {
                j ^= m
                m >>= 1
            }
            j |= m
        }
        let full = 1 << log2n
        var len = 2
        while len <= n {
            let halfLen = len / 2
            let step = full / len
            var start = 0
            while start < n {
                for k in 0..<halfLen {
                    let wr = cosTable[k * step]
                    let wi = inverse ? sinTable[k * step] : -sinTable[k * step]
                    let a = start + k
                    let b = a + halfLen
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
    }
}

public func vDSP_create_fftsetupD(_ log2n: vDSP_Length, _ radix: FFTRadix) -> FFTSetupD? {
    guard radix == FFTRadix(kFFTRadix2), log2n >= 1, log2n <= 30 else { return nil }
    return OpaquePointer(Unmanaged.passRetained(FFTSetupBox(log2n: Int(log2n))).toOpaque())
}

public func vDSP_destroy_fftsetupD(_ setup: FFTSetupD?) {
    guard let setup else { return }
    Unmanaged<FFTSetupBox>.fromOpaque(UnsafeRawPointer(setup)).release()
}

/// Z->realp[n*IZ] = C[n*IC/2].real、Z->imagp[n*IZ] = C[n*IC/2].imag（ICはDouble単位）。
public func vDSP_ctozD(_ c: UnsafePointer<DSPDoubleComplex>, _ ic: vDSP_Stride,
                       _ z: UnsafePointer<DSPDoubleSplitComplex>, _ iz: vDSP_Stride,
                       _ count: vDSP_Length) {
    let split = z.pointee
    for n in 0..<Int(count) {
        let value = c[n * ic / 2]
        split.realp[n * iz] = value.real
        split.imagp[n * iz] = value.imag
    }
}

/// C[n*IC/2].real = Z->realp[n*IZ]、C[n*IC/2].imag = Z->imagp[n*IZ]（ICはDouble単位）。
public func vDSP_ztocD(_ z: UnsafePointer<DSPDoubleSplitComplex>, _ iz: vDSP_Stride,
                       _ c: UnsafeMutablePointer<DSPDoubleComplex>, _ ic: vDSP_Stride,
                       _ count: vDSP_Length) {
    let split = z.pointee
    for n in 0..<Int(count) {
        c[n * ic / 2] = DSPDoubleComplex(real: split.realp[n * iz], imag: split.imagp[n * iz])
    }
}

public func vDSP_fft_zripD(_ setup: FFTSetupD, _ c: UnsafePointer<DSPDoubleSplitComplex>,
                           _ stride: vDSP_Stride, _ log2n: vDSP_Length, _ direction: FFTDirection) {
    let box = Unmanaged<FFTSetupBox>.fromOpaque(UnsafeRawPointer(setup)).takeUnretainedValue()
    let bits = Int(log2n)
    precondition(bits >= 1 && bits <= box.log2n, "vDSP_fft_zripD: log2n \(bits) > setup \(box.log2n)")
    let n = 1 << bits
    let half = n / 2
    let split = c.pointee
    var re = [Double](repeating: 0, count: n)
    var im = [Double](repeating: 0, count: n)

    if direction > 0 {
        for k in 0..<half {
            re[2 * k] = split.realp[k * stride]
            re[2 * k + 1] = split.imagp[k * stride]
        }
        box.transform(&re, &im, log2n: bits, inverse: false)
        split.realp[0] = 2 * re[0]
        split.imagp[0] = 2 * re[half]
        for k in 1..<max(half, 1) {
            split.realp[k * stride] = 2 * re[k]
            split.imagp[k * stride] = 2 * im[k]
        }
    } else {
        re[0] = split.realp[0]
        re[half] = split.imagp[0]
        for k in 1..<max(half, 1) {
            re[k] = split.realp[k * stride]
            im[k] = split.imagp[k * stride]
            re[n - k] = re[k]
            im[n - k] = -im[k]
        }
        box.transform(&re, &im, log2n: bits, inverse: true)
        for k in 0..<half {
            split.realp[k * stride] = re[2 * k]
            split.imagp[k * stride] = re[2 * k + 1]
        }
    }
}
