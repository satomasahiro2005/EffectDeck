//  RemoteFileTests.swift
//  貼られたリンクの読み替え。**通信はしない。**
//
//  gist の印（`#file-…`）はファイル名ではない。以前は印をそのまま /raw/ の後ろに
//  付けていて、`.` を含む名前は全部 404 だった。印の期待値は、実際の gist の
//  ページが振っていた `id="file-…"` を写したもので、こちらの実装から出したものではない。

import XCTest
import Foundation

final class RemoteFileTests: XCTestCase {

    private let gist = "https://gist.github.com/satomasahiro2005/c542880fc52d3874404998b440e931b5"

    func testGistAnchorMatchesWhatGitHubPrints() {
        XCTAssertEqual(ETRemoteFile.gistAnchor(for: "dh++_4ch_ffmpeg.wav"), "dh-_4ch_ffmpeg-wav")
        XCTAssertEqual(ETRemoteFile.gistAnchor(for: "atmos_4ch_plain.wav"), "atmos_4ch_plain-wav")
        XCTAssertEqual(ETRemoteFile.gistAnchor(for: "convert.py"), "convert-py")
    }

    func testNamedGistFileGoesThroughTheListing() {
        let url = ETRemoteFile.address(from: gist + "#file-dh-_4ch_ffmpeg-wav")
        XCTAssertEqual(url?.host, "api.github.com")
        XCTAssertEqual(url?.path, "/gists/c542880fc52d3874404998b440e931b5")
        XCTAssertEqual(url?.fragment, "file-dh-_4ch_ffmpeg-wav")
    }

    func testPickingTheFileFromTheListing() {
        let names = ["atmos_4ch_ffmpeg.wav", "atmos_4ch_plain.wav", "convert.py",
                     "dh++_4ch_ffmpeg.wav", "dh++_4ch_plain.wav"]
        XCTAssertEqual(ETRemoteFile.gistFile(named: "dh-_4ch_ffmpeg-wav", among: names), "dh++_4ch_ffmpeg.wav")
        XCTAssertEqual(ETRemoteFile.gistFile(named: "convert-py", among: names), "convert.py")
        XCTAssertNil(ETRemoteFile.gistFile(named: "missing-wav", among: names))
    }

    /// 2 本に当たるなら選ばない。違うファイルを黙って入れるよりは断る。
    func testAmbiguousAnchorPicksNothing() {
        XCTAssertNil(ETRemoteFile.gistFile(named: "a-b", among: ["a.b", "a-b"]))
    }

    func testBareGistStillTakesTheFirstFile() {
        XCTAssertEqual(ETRemoteFile.address(from: gist)?.absoluteString, gist + "/raw")
    }

    /// Raw を押した先を貼られたら、そのまま取りに行く（/raw を足さない）。
    func testRawGistLinkIsLeftAlone() {
        let raw = gist + "/raw/130e3a95c65f7f49749631d3f6ec846805141629/dh%2B%2B_4ch_ffmpeg.wav"
        XCTAssertEqual(ETRemoteFile.address(from: raw)?.absoluteString, raw)
    }

    func testGitHubBlobBecomesRaw() {
        XCTAssertEqual(ETRemoteFile.address(from: "https://github.com/u/r/blob/main/fx/a.jsfx?plain=1")?.absoluteString,
                       "https://raw.githubusercontent.com/u/r/main/fx/a.jsfx")
    }
}
