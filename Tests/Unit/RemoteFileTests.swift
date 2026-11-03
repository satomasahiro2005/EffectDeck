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

    /// 名指しの無いリンクも一覧から引く。`<gist>/raw`はこのgistでconvert.pyを返し、
    /// 画面の先頭（atmos_4ch_ffmpeg.wav）ではなかった。
    func testBareGistGoesThroughTheListing() {
        let url = ETRemoteFile.address(from: gist)
        XCTAssertEqual(url?.absoluteString, "https://api.github.com/gists/c542880fc52d3874404998b440e931b5")
        XCTAssertNil(url?.fragment)
        // ユーザー名の無い形も同じ。印でないfragmentは捨てる。
        XCTAssertEqual(ETRemoteFile.address(from: "https://gist.github.com/c542880fc52d3874404998b440e931b5#comments")?
                        .absoluteString,
                       "https://api.github.com/gists/c542880fc52d3874404998b440e931b5")
    }

    /// 名指しが無ければ名前の順で最初の1本（gistの画面の並び）。一覧の並びには頼らない。
    func testBareGistTakesTheFirstFileByName() {
        let listed = ["convert.py", "ssc_ny_4ch_plain.wav", "dh++_4ch_ffmpeg.wav", "atmos_4ch_plain.wav",
                      "atmos_4ch_ffmpeg.wav", "ssc_ny_4ch_ffmpeg.wav", "dh++_4ch_plain.wav"]
        XCTAssertEqual(ETRemoteFile.firstGistFile(among: listed), "atmos_4ch_ffmpeg.wav")
        XCTAssertNil(ETRemoteFile.firstGistFile(among: []))
    }

    /// 名前の順で先に来る添え物（README.md・convert.py）は飛ばす。全部が添え物なら先頭。
    func testBareGistSkipsFilesThatCannotBeImported() {
        XCTAssertEqual(ETRemoteFile.firstGistFile(among: ["effect.jsfx", "README.md", "convert.py"]), "effect.jsfx")
        XCTAssertEqual(ETRemoteFile.firstGistFile(among: ["LICENSE", "notes.txt"]), "notes.txt")
        XCTAssertEqual(ETRemoteFile.firstGistFile(among: ["b.py", "a.md"]), "a.md")
    }

    /// APIに断られたときは画面のRawの行き先から引く。字は実際のgistの画面から写したもの
    /// （同じファイルが相対と絶対の2通りで出る）。よそのgistを指す行き先は拾わない。
    func testRawLinksFromTheGistPage() {
        let id = "c542880fc52d3874404998b440e931b5"
        let sha = "52b1c7a1d78bcb32c87d9626e66c9fd6a77f4a09"
        let html = """
            <a href="/satomasahiro2005/\(id)/raw/\(sha)/atmos_4ch_ffmpeg.wav" data-view-component="true" class="Button--secondary Button--small Button">
            <a href="https://gist.github.com/satomasahiro2005/\(id)/raw/\(sha)/atmos_4ch_ffmpeg.wav">View raw</a>
            <a href="/satomasahiro2005/\(id)/raw/\(sha)/convert.py" data-view-component="true" class="Button--secondary Button--small Button">
            <a href="/satomasahiro2005/\(id)/raw/\(sha)/dh++_4ch_ffmpeg.wav" data-view-component="true" class="Button--secondary Button--small Button">
            <a href="/someone/0123456789abcdef/raw/\(sha)/other.wav">
            """
        let links = ETRemoteFile.gistRawLinks(inPage: html, id: id)
        let names = links.map { $0.name }
        XCTAssertEqual(names, ["atmos_4ch_ffmpeg.wav", "convert.py", "dh++_4ch_ffmpeg.wav"])
        XCTAssertEqual(links.first?.raw.absoluteString,
                       "https://gist.github.com/satomasahiro2005/\(id)/raw/\(sha)/atmos_4ch_ffmpeg.wav")
        XCTAssertEqual(ETRemoteFile.gistFile(named: "dh-_4ch_ffmpeg-wav", among: names), "dh++_4ch_ffmpeg.wav")
        XCTAssertEqual(ETRemoteFile.firstGistFile(among: names), "atmos_4ch_ffmpeg.wav")
    }

    /// 属性の中の字（`&amp;`と`%`）は戻してから名前にする。
    func testRawLinkNamesAreUnescaped() {
        let html = #"<a href="/u/abc123/raw/0f/my%20ir%20&amp;%20hall.wav">"#
        XCTAssertEqual(ETRemoteFile.gistRawLinks(inPage: html, id: "abc123").map { $0.name },
                       ["my ir & hall.wav"])
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
