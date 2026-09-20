//  JSFXHostSupport.swift
//  JSFX Host（Sources/Shared/ETJSFXHost.cpp）を Swift から叩くための足場。
//
//  **C++ の独立した native テストは作らない。**Tests/Native/CMakeLists.txt は
//  ysfx を知らず、Vendor/ysfx は submodule なので、あちらへ足すとビルド系の
//  持ち主が 2 つになる。代わりに project.yml の EffeTuneLiveUnitTests へ
//  ETJSFXHost.cpp と YSFX を足し、ここから public C API を直接呼ぶ。
//  設計は docs/jsfx-host-test-design.md（L1 = §4〜§15）。
//
//  ここで決めている前提が 2 つある。どちらも測り方の話なので先に書いておく。
//
//  1. **ブロックを大きく取る（512 フレーム = 10.6 ms）。**
//     自動バイパスの締切は process に渡した frames / sampleRate を持ち時間に
//     するので、64 フレーム（1.33 ms）だと実行機のちょっとした詰まりでも
//     超える。締切を試す所（JSFXDeadlineTests）以外で自動バイパスへ落ちると、
//     落ちた理由が分からないまま別のテストが赤くなる。
//
//  2. **bit-exact を要求しない。**ysfx は @sample へ渡す前に 1e-16 の
//     非正規化対策を足す（ysfx.cpp: denorm_value）。入力 0 がそのまま 0 で
//     出てこないので、比較は accuracy 付きで行う。

import XCTest
import Foundation

/// バンドルを引くためだけの目印。
private final class JSFXProbe {}

enum JSFXFixtureError: Error, CustomStringConvertible {
    case notFound(String)
    case compileFailed(name: String, message: String)

    var description: String {
        switch self {
        case .notFound(let name): return "JSFX fixture not found: \(name).jsfx"
        case .compileFailed(let name, let message): return "\(name).jsfx failed to load: \(message)"
        }
    }
}

/// `ETJSFX_Create` の結果。失敗したときの文面も一緒に持つ。
struct JSFXOpenResult {
    let raw: OpaquePointer?
    let message: String
}

enum JSFX {
    /// 試験の既定値。理由はこのファイルの頭。
    static let sampleRate: Double = 48000
    static let maxFrames: UInt32 = 512

    /// fixture の在り処。まずバンドル（project.yml が resources へ入れている）、
    /// 見つからなければソースの隣を見る。テストはビルドした Mac の上で走るので、
    /// 後者も読める。**どちらで引けたかでテストの意味は変わらない。**
    static func path(_ name: String) throws -> String {
        let bundle = Bundle(for: JSFXProbe.self)
        if let url = bundle.url(forResource: name, withExtension: "jsfx") { return url.path }
        if let url = bundle.url(forResource: name, withExtension: "jsfx", subdirectory: "JSFX") {
            return url.path
        }
        let source = URL(fileURLWithPath: #filePath)   // Tests/Unit/JSFXHostSupport.swift
            .deletingLastPathComponent()               // Tests/Unit
            .deletingLastPathComponent()               // Tests
            .appendingPathComponent("Fixtures/JSFX/\(name).jsfx")
        if FileManager.default.fileExists(atPath: source.path) { return source.path }
        throw JSFXFixtureError.notFound(name)
    }

    /// 通っても落ちても結果を返す。異常系のテストはこちらを使う。
    static func open(_ name: String,
                     sampleRate: Double = JSFX.sampleRate,
                     maxFrames: UInt32 = JSFX.maxFrames) throws -> JSFXOpenResult {
        try open(path: path(name), sampleRate: sampleRate, maxFrames: maxFrames)
    }

    static func open(path: String?,
                     sampleRate: Double = JSFX.sampleRate,
                     maxFrames: UInt32 = JSFX.maxFrames) -> JSFXOpenResult {
        var buffer = [CChar](repeating: 0, count: 1024)
        let raw: OpaquePointer? = buffer.withUnsafeMutableBufferPointer { error -> OpaquePointer? in
            guard let path else {
                return ETJSFX_Create(nil, sampleRate, maxFrames, error.baseAddress, error.count)
            }
            return path.withCString {
                ETJSFX_Create($0, sampleRate, maxFrames, error.baseAddress, error.count)
            }
        }
        let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return JSFXOpenResult(raw: raw, message: message)
    }

    /// 通る前提で開く。落ちたら理由付きで投げる。
    static func load(_ name: String,
                     sampleRate: Double = JSFX.sampleRate,
                     maxFrames: UInt32 = JSFX.maxFrames) throws -> JSFXHost {
        let result = try open(name, sampleRate: sampleRate, maxFrames: maxFrames)
        guard let raw = result.raw else {
            throw JSFXFixtureError.compileFailed(name: name, message: result.message)
        }
        return JSFXHost(raw)
    }

    /// planar な試験信号。**チャンネルごとに形を変える**（入れ替わりが見えるように）。
    /// 0 を避けてあるのは、上の 2 の理由で 0 だけ挙動が違うと読みにくいから。
    static func signal(channels: UInt32, frames: UInt32) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(Int(channels) * Int(frames))
        for channel in 0..<Int(channels) {
            let base = Double(channel + 1) * 0.1
            for frame in 0..<Int(frames) {
                out.append(Float(base + Double(frame % 17) * 0.01 + 0.005))
            }
        }
        return out
    }

    /// planar の 1 チャンネルぶんを切り出す。
    static func channel(_ index: Int, of planar: [Float], frames: UInt32) -> ArraySlice<Float> {
        let start = index * Int(frames)
        return planar[start..<(start + Int(frames))]
    }

    // MARK: - 締切を超えさせるための道具

    /// 締切を試すときのブロック長。128 フレーム = 2.67 ms。
    /// **ここだけ短くする。**持ち時間を小さくしないと、超えるのに要る仕事が
    /// 増えてテストが遅くなる。2.67 ms は、普通のブロックが偶然超えるには
    /// 十分に長い。
    static let deadlineFrames: UInt32 = 128

    /// slow.jsfx の回す数の上限（fixture の slider1 の max）。
    /// 1 サンプルあたり 20000 回の EEL ループは、持ち時間 20.8 µs/サンプルの
    /// 10 倍以上掛かる。通訳実行（EEL_TARGET_PORTABLE）なのでここは詰まらない。
    static let spin: Double = 20000

    /// slow.jsfx を自動バイパスまで追い込む。追い込めたかは呼び手が見る。
    static func exhaustedSlowHost(limit: Int = 12) throws -> JSFXHost {
        let host = try load("slow", maxFrames: deadlineFrames)
        host.set(0, spin)
        var planar = signal(channels: 2, frames: deadlineFrames)
        for _ in 0..<limit {
            guard host.isRunning else { break }
            _ = host.process(&planar, channels: 2, frames: deadlineFrames)
        }
        return host
    }
}

/// `ETJSFX *` の持ち主。**deinit で必ず Destroy する**ので、
/// テストの途中で XCTUnwrap が投げても取り残さない。
final class JSFXHost {
    let raw: OpaquePointer

    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { ETJSFX_Destroy(raw) }

    // MARK: - 音

    var processor: ETExternalProcessor { ETJSFX_Processor(raw) }

    /// 1 ブロック通す。戻り値は descriptor の process と同じ（0 = 成功）。
    @discardableResult
    func process(_ planar: inout [Float],
                 channels: UInt32,
                 frames: UInt32,
                 sampleRate: Double = JSFX.sampleRate) -> Int32 {
        let descriptor = processor
        return planar.withUnsafeMutableBufferPointer { buffer in
            descriptor.process!(descriptor.context, buffer.baseAddress, channels, frames,
                                sampleRate, 0)
        }
    }

    /// 中身を見ないで 1 ブロックだけ回す。@block / @slider を進めるためのもの。
    @discardableResult
    func run(blocks: Int = 1,
             channels: UInt32 = 2,
             frames: UInt32 = JSFX.maxFrames,
             sampleRate: Double = JSFX.sampleRate) -> Int32 {
        var planar = JSFX.signal(channels: channels, frames: frames)
        var code: Int32 = 0
        for _ in 0..<blocks {
            code = process(&planar, channels: channels, frames: frames, sampleRate: sampleRate)
        }
        return code
    }

    // MARK: - つまみ

    struct SliderInfo {
        let ordinal: UInt32
        let index: UInt32
        let name: String
        let value: Double
        let minimum: Double
        let maximum: Double
        let step: Double
        let shape: UInt8
        let visible: Bool
    }

    /// shape の値は ysfx の並び（ysfx.cpp: ysfx_normalized_to_ysfx_value）。
    enum Shape: UInt8 { case linear = 0, log = 1, square = 2 }

    var sliderCount: UInt32 { ETJSFX_SliderCount(raw) }

    func sliders() -> [SliderInfo] {
        (0..<sliderCount).compactMap { ordinal in
            var index: UInt32 = 0, shape: UInt8 = 0
            var name: UnsafePointer<CChar>?
            var value = 0.0, minimum = 0.0, maximum = 0.0, step = 0.0
            var visible = false
            guard ETJSFX_SliderInfo(raw, ordinal, &index, &name, &value, &minimum,
                                    &maximum, &step, &shape, &visible) else { return nil }
            return SliderInfo(ordinal: ordinal, index: index,
                              name: name.map { String(cString: $0) } ?? "",
                              value: value, minimum: minimum, maximum: maximum,
                              step: step, shape: shape, visible: visible)
        }
    }

    func enumNames(index: UInt32) -> [String] {
        (0..<ETJSFX_SliderEnumCount(raw, index)).compactMap { ordinal in
            ETJSFX_SliderEnumName(raw, index, ordinal).map { String(cString: $0) }
        }
    }

    func set(_ index: UInt32, _ value: Double) { ETJSFX_SetSlider(raw, index, value) }
    func get(_ index: UInt32) -> Double { ETJSFX_GetSlider(raw, index) }

    // MARK: - 状態

    /// 保存した中身を Data で返す。**ETJSFX_FreeBytes はここで呼ぶ**ので、
    /// 呼び手は解放を持ち回らない。
    func save() -> Data? {
        var bytes: UnsafeMutablePointer<UInt8>?
        var size = 0
        guard ETJSFX_SaveState(raw, &bytes, &size), let bytes else { return nil }
        defer { ETJSFX_FreeBytes(UnsafeMutableRawPointer(bytes)) }
        return Data(bytes: bytes, count: size)
    }

    @discardableResult
    func load(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            ETJSFX_LoadState(raw, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
        }
    }

    // MARK: - 見るだけ

    var isRunning: Bool { ETJSFX_IsRunning(raw) }
    var diagnostic: String { String(cString: ETJSFX_Diagnostic(raw)) }
    var deadlineTrips: UInt32 { ETJSFX_DeadlineTrips(raw) }
    var latency: UInt32 { processor.latency!(processor.context) }
}
