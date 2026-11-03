//  InboxTests.swift
//  外から来たファイルの振り分け（ETInbox.route）。取り込みの 2 つは偽物を渡す。
//
//  見張るのは 3 つ:
//    - 音を先に試す。音として受けたら JSFX は試さない
//    - JSFX の「JSFX ではない」（ETJSFX の 10）だけは .unsupported（音でも JSFX でもない）
//    - それ以外の断りは .failed で理由を持って返す（黙ると「押しても何も起きない」になる）

import XCTest

final class InboxTests: XCTestCase {

    private let file = URL(fileURLWithPath: "/tmp/inbox-tests/thing")

    private struct Plain: Error, LocalizedError {
        var errorDescription: String? { "plain failure" }
    }

    func testAudioIsTriedFirstAndWins() {
        var calls: [String] = []
        let got = ETInbox.route(file,
                                importIR: { calls.append("ir \($0.lastPathComponent)"); return "abc123" },
                                importJSFX: { _ in calls.append("jsfx"); return "never" })
        XCTAssertEqual(got, .ir("abc123"))
        XCTAssertEqual(calls, ["ir thing"])
    }

    func testNotAudioFallsThroughToJSFX() {
        var calls: [String] = []
        let got = ETInbox.route(file,
                                importIR: { _ in calls.append("ir"); return nil },
                                importJSFX: { calls.append("jsfx \($0.lastPathComponent)"); return "fx1" })
        XCTAssertEqual(got, .jsfx("fx1"))
        XCTAssertEqual(calls, ["ir", "jsfx thing"])
    }

    /// ETJSFXHost.importFile が looksLikeJSFX で外したときの印。
    func testNotJSFXCode10IsUnsupported() {
        let got = ETInbox.route(file, importIR: { _ in nil }, importJSFX: { _ in
            throw NSError(domain: "ETJSFX", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "That file does not look like a JSFX source."])
        })
        XCTAssertEqual(got, .unsupported)
    }

    /// 同じ印でも JSFX 以外の場所から来たものは理由として出す。
    func testCode10FromAnotherDomainIsFailed() {
        let got = ETInbox.route(file, importIR: { _ in nil }, importJSFX: { _ in
            throw NSError(domain: "Other", code: 10, userInfo: [NSLocalizedDescriptionKey: "other ten"])
        })
        XCTAssertEqual(got, .failed("other ten"))
    }

    /// JSFX らしいが受けられなかった（大きすぎる、字に起こせない、閉じた版）。
    func testOtherJSFXErrorsAreFailedWithTheReason() {
        for (code, reason) in [(11, "The JSFX source is not text."), (12, "JSFX is not available in this build.")] {
            let got = ETInbox.route(file, importIR: { _ in nil }, importJSFX: { _ in
                throw NSError(domain: "ETJSFX", code: code, userInfo: [NSLocalizedDescriptionKey: reason])
            })
            XCTAssertEqual(got, .failed(reason), "code \(code)")
        }
    }

    func testNonNSErrorIsFailedWithItsDescription() {
        let got = ETInbox.route(file, importIR: { _ in nil }, importJSFX: { _ in throw Plain() })
        XCTAssertEqual(got, .failed("plain failure"))
    }

    func testTooLargeFromFoundationIsFailed() {
        let got = ETInbox.route(file, importIR: { _ in nil }, importJSFX: { _ in
            throw CocoaError(.fileReadTooLarge)
        })
        guard case .failed(let reason) = got else { return XCTFail("\(got)") }
        XCTAssertFalse(reason.isEmpty)
    }
}
