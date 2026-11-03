//  CrosstalkMeasurementTests.swift
//  耳もとの測定を組む側（CrosstalkMeasurementCore.swift の ETCrosstalkLoader.ear）。
//  ファイルの復号は通さず、復号し終えたチャンネルを渡す。**実機もエンジンも要らない。**
//
//  約束は 3 つ。
//    1. 0 本目が左スピーカー、1 本目が右スピーカー。id は `<鍵>::ch=left` / `::ch=right`。
//    2. 記録の中身は上流のファイル取り込みと同じ（頭 0・基準 1・時刻は file・onset は onset.js）。
//    3. 2 本の耳を CrosstalkStore と同じ並べ方で 4 枠へ入れると designer の検査を通り、
//       同じファイルを両耳に入れると重複で落ちる。

import XCTest
import Foundation

final class CrosstalkMeasurementTests: XCTestCase {

    private let left: [Float] = [0, 0, 0.9, -0.3, 0.1, 0]
    private let right: [Float] = [0, 0, 0, 0.35, -0.1, 0.02]

    /// 0 本目（下のチャンネル）が左スピーカーの枠、1 本目が右スピーカーの枠。
    func testChannel0IsLeft() throws {
        let ear = try ETCrosstalkLoader.ear(channels: [left, right], sampleRate: 48000, frames: 6,
                                            id: "k", name: "Left ear")
        XCTAssertEqual(ear.leftSpeaker.data, left.map { Double($0) })
        XCTAssertEqual(ear.rightSpeaker.data, right.map { Double($0) })
        // 3 本目より後ろは使わない。
        let wide = try ETCrosstalkLoader.ear(channels: [left, right, [1, 1, 1, 1, 1, 1]], sampleRate: 48000,
                                             frames: 6, id: "k", name: "")
        XCTAssertEqual(wide.leftSpeaker.data, ear.leftSpeaker.data)
        XCTAssertEqual(wide.rightSpeaker.data, ear.rightSpeaker.data)
    }

    /// id は鍵に `::ch=left` / `::ch=right` を付けたもの。designer はその前を測定の id として読む。
    func testIdsSuffix() throws {
        let ear = try ETCrosstalkLoader.ear(channels: [left, right], sampleRate: 48000, frames: 6,
                                            id: "e3b0c44298fc1c149afbf4c8", name: "")
        XCTAssertEqual(ear.id, "e3b0c44298fc1c149afbf4c8")
        XCTAssertEqual(ear.leftSpeaker.id, "e3b0c44298fc1c149afbf4c8::ch=left")
        XCTAssertEqual(ear.rightSpeaker.id, "e3b0c44298fc1c149afbf4c8::ch=right")
        XCTAssertEqual(CrosstalkCancellationDesigner.baseMeasurementId(ear.leftSpeaker.id), ear.id)
        XCTAssertEqual(CrosstalkCancellationDesigner.baseMeasurementId(ear.rightSpeaker.id), ear.id)
    }

    /// 1 本以下のファイルは測定にならない。文面は数に合わせて単数・複数を変える。
    func testFewerThan2ChannelsError() {
        for count in [0, 1] {
            let channels = [[Float]](repeating: left, count: count)
            XCTAssertThrowsError(try ETCrosstalkLoader.ear(channels: channels, sampleRate: 48000, frames: 6,
                                                           id: "k", name: "")) { error in
                guard case ETCrosstalkLoadError.notEnoughChannels(let got) = error else {
                    return XCTFail("\(error)")
                }
                XCTAssertEqual(got, count)
                let text = (error as? LocalizedError)?.errorDescription ?? ""
                XCTAssertTrue(text.hasPrefix(count == 1 ? "This file has 1 channel. " : "This file has 0 channels. "),
                              text)
                XCTAssertTrue(text.hasSuffix("so it needs at least two channels."), text)
            }
        }
    }

    /// 上流の createImpulseResponseMeasurement と同じ記録: 頭 0・基準 1・時刻は file・レートは整数へ丸める。
    func testRecordFields() throws {
        let ear = try ETCrosstalkLoader.ear(channels: [left, right], sampleRate: 44099.6, frames: 1234,
                                            id: "k", name: "Right ear")
        XCTAssertEqual(ear.sampleRate, 44100)
        XCTAssertEqual(ear.frames, 1234)
        XCTAssertEqual(ear.name, "Right ear")
        for measurement in [ear.leftSpeaker, ear.rightSpeaker] {
            XCTAssertEqual(measurement.sampleRate, 44100)
            XCTAssertEqual(measurement.trimStartSamples, 0)
            XCTAssertEqual(measurement.referenceScale, 1)
            XCTAssertEqual(measurement.timeReference, .file)
        }
        XCTAssertEqual(ear.leftSpeaker.onsetIndex, ETCrosstalkLoader.detectOnset(left, sampleRate: 44100))
        XCTAssertEqual(ear.rightSpeaker.onsetIndex, ETCrosstalkLoader.detectOnset(right, sampleRate: 44100))
    }

    /// 上流の onset.js の detectOnset と同じ位置（無音の床・8 未満の窓・全部 0・空・遅い山）。
    func testDetectOnsetMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.onset.count, 6)
        for entry in golden.onset {
            XCTAssertEqual(ETCrosstalkLoader.detectOnset(entry.samples.floats, sampleRate: entry.sampleRate),
                           entry.expected, entry.name)
        }
    }

    /// CrosstalkStore と同じ並べ方（ll = 左耳の左、lr = 右耳の左、rl = 左耳の右、rr = 右耳の右）なら
    /// designer の検査を通る。同じファイル（同じ鍵）を両耳に入れると重複で落ちる。
    func testEarsFitDesignerSlots() throws {
        let leftEar = try ETCrosstalkLoader.ear(channels: [left, right], sampleRate: 48000, frames: 6,
                                                id: "left-key", name: "")
        let rightEar = try ETCrosstalkLoader.ear(channels: [right, left], sampleRate: 48000, frames: 6,
                                                 id: "right-key", name: "")
        func slots(_ l: ETCrosstalkLoader.Ear, _ r: ETCrosstalkLoader.Ear) -> CrosstalkCancellationDesigner.Sources {
            CrosstalkCancellationDesigner.Sources(ll: l.leftSpeaker, lr: r.leftSpeaker,
                                                  rl: l.rightSpeaker, rr: r.rightSpeaker)
        }
        XCTAssertEqual(try CrosstalkCancellationDesigner.validate(slots(leftEar, rightEar)).sampleRate, 48000)
        XCTAssertThrowsError(try CrosstalkCancellationDesigner.validate(slots(leftEar, leftEar))) {
            XCTAssertEqual(($0 as? CrosstalkCancellationDesigner.DesignError)?.code,
                           "duplicate-measurement-assignment")
        }
    }
}
