//  IRDecodeTests.swift
//  IR のファイルを読むところ（ETIRDecode）。
//
//  門（幅・長さ・レート）、非有限を 0 にすること、表示名は Foundation だけで、Linux でも走る。
//  AVAudioFile で実際に書いた WAV を読ませる試験（`#if canImport(AVFoundation)`）は Mac だけ。

import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif

final class IRDecodeTests: XCTestCase {

    /// 投げたものを 1 語にする（ETIRLoadError は Equatable でない）。
    private func verdict(_ body: () throws -> Void) -> String {
        do {
            try body()
            return "ok"
        } catch let error as ETIRLoadError {
            switch error {
            case .cannotOpen: return "cannotOpen"
            case .emptyFile: return "emptyFile"
            case .tooManyChannels(let n): return "tooManyChannels(\(n))"
            case .unsupportedRate(let r): return r.isNaN ? "unsupportedRate(nan)" : "unsupportedRate(\(r))"
            case .rejected(let why): return "rejected(\(why))"
            }
        } catch {
            return "other(\(error))"
        }
    }

    private func check(_ channels: Int, _ frames: Int, _ rate: Double) -> String {
        verdict { try ETIRDecode.checkFormat(channelCount: channels, frames: frames, sampleRate: rate) }
    }

    // MARK: - 表示名

    /// ir_reverb.js の _channelModeName と同じ。知らない名前はそのまま出す。
    func testDisplayNameTable() {
        XCTAssertEqual(ETIRDecode.displayName("mono"), "Mono")
        XCTAssertEqual(ETIRDecode.displayName("indep"), "Independent")
        XCTAssertEqual(ETIRDecode.displayName("true"), "True Stereo")
        XCTAssertEqual(ETIRDecode.displayName("multi"), "Multi-channel")
        XCTAssertEqual(ETIRDecode.displayName("auto"), "auto")
        XCTAssertEqual(ETIRDecode.displayName(""), "")
    }

    // MARK: - 門

    func testOneToSixteenChannelsPass() {
        XCTAssertEqual(check(1, 1, 48000), "ok")
        XCTAssertEqual(check(2, 480, 44100), "ok")
        XCTAssertEqual(check(16, 10, 192000), "ok")
    }

    func testMoreThanSixteenChannelsAreRejected() {
        XCTAssertEqual(check(17, 480, 48000), "tooManyChannels(17)")
        XCTAssertEqual(check(64, 480, 48000), "tooManyChannels(64)")
    }

    /// 幅 0 も同じ字で断る（前からそう出している）。
    func testZeroChannelsAreReportedAsTooMany() {
        XCTAssertEqual(check(0, 480, 48000), "tooManyChannels(0)")
    }

    func testEmptyFileIsRejected() {
        XCTAssertEqual(check(2, 0, 48000), "emptyFile")
    }

    func testRateZeroNegativeAndNaNAreRejected() {
        XCTAssertEqual(check(2, 480, 0), "unsupportedRate(0.0)")
        XCTAssertEqual(check(2, 480, -44100), "unsupportedRate(-44100.0)")
        XCTAssertEqual(check(2, 480, .nan), "unsupportedRate(nan)")
    }

    /// 門の順番は幅 → 長さ → レート。どの字が出るかはこの順で決まる。
    func testChecksRunWidthThenLengthThenRate() {
        XCTAssertEqual(check(17, 0, 0), "tooManyChannels(17)")
        XCTAssertEqual(check(2, 0, 0), "emptyFile")
    }

    // MARK: - 非有限

    /// 1 つでもあると AssetUpload.makePayload が弾くので、読んだところで 0 にする。
    func testNonFiniteSamplesBecomeZero() {
        let plane: [Float] = [1, .nan, .infinity, -.infinity, -0.5, .greatestFiniteMagnitude, -.nan]
        let out = plane.withUnsafeBufferPointer { ETIRDecode.sanitized($0) }
        XCTAssertEqual(out, [1, 0, 0, 0, -0.5, .greatestFiniteMagnitude, 0])
    }

    func testEmptyPlaneStaysEmpty() {
        let out = [Float]().withUnsafeBufferPointer { ETIRDecode.sanitized($0) }
        XCTAssertEqual(out, [])
    }

    #if canImport(AVFoundation)
    // MARK: - 実際のファイル（Mac だけ）

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IRDecodeTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// float32 の WAV を面ごとに書く。
    private func writeWAV(_ planes: [[Float]], rate: Double, name: String = "ir.wav") throws -> URL {
        let url = folder.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: planes.count,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = planes.first?.count ?? 0
        if frames > 0 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                        frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for (ch, plane) in planes.enumerated() {
                for i in 0..<frames { data[ch][i] = plane[i] }
            }
            try file.write(from: buffer)
        }
        return url
    }

    func testDecodeReadsAWrittenStereoWAVAndZeroesNaN() throws {
        let left: [Float] = [0.5, -0.25, .nan, 0.125]
        let right: [Float] = [0, 1, -1, .infinity]
        let url = try writeWAV([left, right], rate: 44100)
        let decoded = try ETIRDecode.decode(url)
        XCTAssertEqual(decoded.sampleRate, 44100)
        XCTAssertEqual(decoded.frames, 4)
        XCTAssertEqual(decoded.channels, [[0.5, -0.25, 0, 0.125], [0, 1, -1, 0]])
    }

    func testDecodeOfAWAVWithNoFramesIsEmptyFile() throws {
        let url = try writeWAV([[], []], rate: 48000, name: "empty.wav")
        XCTAssertEqual(verdict { _ = try ETIRDecode.decode(url) }, "emptyFile")
    }

    func testDecodeOfTextIsCannotOpen() throws {
        let url = folder.appendingPathComponent("a.jsfx")
        try Data("desc:x\n@sample\nspl0=spl0;\n".utf8).write(to: url)
        XCTAssertEqual(verdict { _ = try ETIRDecode.decode(url) }, "cannotOpen")
    }

    /// IRLibrary.looksLikeAudio が訊く相手。読めるものは音、JSFX の字は音ではない。
    func testCanOpenAudioButNotJSFXText() throws {
        let wav = try writeWAV([[0.1, 0.2]], rate: 48000)
        XCTAssertTrue(ETIRDecode.canOpen(wav))
        let jsfx = folder.appendingPathComponent("b.jsfx")
        try Data("desc:x\n@sample\n".utf8).write(to: jsfx)
        XCTAssertFalse(ETIRDecode.canOpen(jsfx))
    }
    #endif
}
