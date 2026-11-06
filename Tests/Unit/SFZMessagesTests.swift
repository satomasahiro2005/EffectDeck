//  SFZMessagesTests.swift
//  SoundFont Note Player の Preset（sp0）の読みと、SoundFont の文面（ETSFZMessages）の見張り。**Foundation だけ。**
//
//  壊れると: sp0 が範囲の外・小数のまま段に入ってカーネルへ渡る（bank × 128 + program でなくなる）、
//  Float の丸めで上限 8388607 が 8388608 に繰り上がる、
//  画面の文が上流 2.17.0（sfzNotePlayer.*・sfzLibrary.*）とずれる、
//  読み込みの知らせが warnings に現れた順でなくなる。

import XCTest

final class SFZMessagesTests: XCTestCase {

    private func spec() throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == "SFZNotePlayerPlugin" }, "カタログに無い")
    }

    private func load(_ s: ETEffect, _ dict: [String: Any], current: [Float]? = nil) -> [Float] {
        ETParamCoding.decode(params: s.params, defaults: current ?? s.defaults, from: dict, type: s.type)
    }

    // MARK: sp0

    /// sfz_note_player.js:83。範囲 -1…8388607 へ寄せ、Math.round で丸める。
    func testPresetIsClampedAndRoundedLikeUpstream() throws {
        let s = try spec()
        let sp0 = try XCTUnwrap(s.params.first { $0.key == "sp0" }).offset
        XCTAssertEqual(load(s, [:])[sp0], -1, "書いていない鎖は音源の先頭")
        XCTAssertEqual(load(s, ["sp0": 4_194_305])[sp0], 4_194_305, "bank 32768 × 128 + 1 は崩さない")
        XCTAssertEqual(load(s, ["sp0": 0])[sp0], 0)
        XCTAssertEqual(load(s, ["sp0": 128])[sp0], 128)
        XCTAssertEqual(load(s, ["sp0": -5])[sp0], -1, "下は -1 に寄る")
        XCTAssertEqual(load(s, ["sp0": -1.4])[sp0], -1)
        XCTAssertEqual(load(s, ["sp0": 1e30])[sp0], 8_388_607, "上は 8388607 に寄る（Int にすると落ちる大きさ）")
        XCTAssertEqual(load(s, ["sp0": 8_388_608])[sp0], 8_388_607)
        XCTAssertEqual(load(s, ["sp0": 8_388_607])[sp0], 8_388_607, "上限そのものは繰り上がらない")
        XCTAssertEqual(load(s, ["sp0": 5.5])[sp0], 6, "Math.round は .5 を +∞ 側へ")
        XCTAssertEqual(load(s, ["sp0": 5.4])[sp0], 5)
        XCTAssertEqual(load(s, ["sp0": -0.5])[sp0], 0, "Math.round(-0.5) は -0")
        XCTAssertEqual(load(s, ["sp0": "x"])[sp0], -1, "数でない文字は既定のまま")
        var current = s.defaults
        current[sp0] = 77
        XCTAssertEqual(load(s, [:], current: current)[sp0], 77, "書いていなければ触らない")
    }

    /// sp0 の丸めは Highest / Lowest Note・Velocity の規則（mn ≤ mx、vc ≥ vf + 1）に巻き込まれない。
    func testPresetDoesNotTakePartInCrossRules() throws {
        let s = try spec()
        let sp0 = try XCTUnwrap(s.params.first { $0.key == "sp0" }).offset
        let mn = try XCTUnwrap(s.params.first { $0.key == "mn" }).offset
        let mx = try XCTUnwrap(s.params.first { $0.key == "mx" }).offset
        let v = load(s, ["sp0": 300, "mn": 80, "mx": 60])
        XCTAssertEqual(v[sp0], 300)
        XCTAssertEqual(v[mn], 80)
        XCTAssertEqual(v[mx], 80)
    }

    /// 上流は Sample Shift も Math.round で整数にする（['mn','mx','pl','os','ss']）。
    func testSampleShiftIsRounded() throws {
        let s = try spec()
        let ss = try XCTUnwrap(s.params.first { $0.key == "ss" }).offset
        XCTAssertEqual(load(s, ["ss": 2.6])[ss], 3)
        XCTAssertEqual(load(s, ["ss": -1.5])[ss], -1)
        XCTAssertEqual(load(s, ["ss": 99])[ss], 6)
    }

    // MARK: 文面

    func testNamesFollowUpstream217() {
        XCTAssertEqual(ETSFZMessages.playerTitle, "SoundFont Note Player")
        XCTAssertEqual(ETSFZMessages.bankLabel, "SoundFont:")
        XCTAssertEqual(ETSFZMessages.libraryButton, "SoundFont Library…")
        XCTAssertEqual(ETSFZMessages.noBankName, "None")
        XCTAssertEqual(ETSFZMessages.missingBankName, "Missing SoundFont")
        XCTAssertEqual(ETSFZMessages.libraryTitle, "SoundFont Library")
        XCTAssertEqual(ETSFZMessages.libraryEmpty, "No matching SoundFont instruments.")
        XCTAssertEqual(ETSFZMessages.librarySearchPrompt, "Search SoundFont instruments")
        XCTAssertEqual(ETSFZMessages.libraryInUse,
                       "This SoundFont is in use by an effect pipeline and cannot be deleted.")
        XCTAssertEqual(ETSFZMessages.libraryDeleted, "SoundFont deleted.")
        XCTAssertEqual(ETSFZMessages.libraryDeleteFailed, "The SoundFont could not be deleted.")
        XCTAssertEqual(ETSFZMessages.libraryConfirmDelete("Piano"), "Delete “Piano” from the library?")
    }

    func testErrorsFollowUpstreamWithoutDeadAdvice() {
        XCTAssertEqual(ETSFZMessages.error("no-regions"), "No playable samples were found. Choose another SoundFont.")
        XCTAssertEqual(ETSFZMessages.error("noRegions"), ETSFZMessages.error("no-regions"), "段の状態の綴りでも引ける")
        XCTAssertEqual(ETSFZMessages.error("playback"),
                       "The instrument stopped because it could not continue playing. Load it again or choose another instrument.")
        XCTAssertEqual(ETSFZMessages.error("unsupported-runtime"),
                       "This instrument uses features that are not available in this version. Choose another SoundFont.")
        XCTAssertEqual(ETSFZMessages.error("missing"),
                       "The selected SoundFont could not be found. Choose it again or choose another SoundFont.")
        XCTAssertTrue(ETSFZMessages.error("sample-read").hasPrefix("Instrument playback stopped because sample data"))
        XCTAssertEqual(ETSFZMessages.error("sampleRead"), ETSFZMessages.error("sample-read"))
        XCTAssertEqual(ETSFZMessages.error("prepare"),
                       "The SoundFont could not be loaded. Check that its sample files are available, or choose another SoundFont.")
        XCTAssertEqual(ETSFZMessages.error("sample-integrity"), ETSFZMessages.error("prepare"), "知らない綴りは prepare")
        XCTAssertEqual(ETSFZMessages.error("cancelled"), "", "取り消しは文を出さない")
        // 設定の画面も、ブラウザも無い。
        for code in ["too-large", "storage", "sample-codec-unavailable", "prepare", "sample-read"] {
            let text = ETSFZMessages.error(code)
            XCTAssertFalse(text.contains("Config"), code)
            XCTAssertFalse(text.contains("browser"), code)
            XCTAssertFalse(text.contains("SFZ "), code)
            XCTAssertFalse(text.contains("size limit in"), code)
        }
    }

    func testWarningsAreOnceEachInTheOrderTheyAppear() {
        XCTAssertNil(ETSFZMessages.warning([]))
        XCTAssertNil(ETSFZMessages.warning(["unknown-code"]), "知らない code は黙って飛ばす")
        let text = ETSFZMessages.warning(["reduced-bank", "invalid-regions", "reduced-bank", "nope", "loop-points-ignored"])
        XCTAssertEqual(text, [
            "A smaller selection of sounds was loaded to fit the size limit while keeping every note.",
            "Some sounds had invalid settings and were skipped.",
            "Unused loop settings were adjusted so this SoundFont could be loaded.",
        ].joined(separator: "\n\n"))
        XCTAssertEqual(ETSFZMessages.warning(["envelope-times-adjusted"]),
                       "Some sound fade times were invalid and were adjusted so this SoundFont could be loaded.")
        XCTAssertEqual(ETSFZMessages.warning(["missing-samples"]),
                       "Some sample files could not be found. The available sounds were loaded.")
    }

    func testLibraryBadge() {
        XCTAssertEqual(ETSFZMessages.libraryBadge(size: 2_621_440, fileCount: 12, regionCount: 88),
                       "2.5 MiB · Files: 12 · Regions: 88")
        XCTAssertEqual(ETSFZMessages.libraryBadge(size: 1536, fileCount: nil, regionCount: 3), "1.5 KiB · Regions: 3")
        XCTAssertEqual(ETSFZMessages.libraryBadge(size: 900, fileCount: 1, regionCount: 1), "900 B · Files: 1 · Regions: 1")
        XCTAssertEqual(ETSFZMessages.libraryBadge(size: nil, fileCount: nil, regionCount: 5), "size unknown · Regions: 5",
                       "2.13.0 で入れたものは大きさも Files も無い")
        XCTAssertEqual(ETSFZMessages.libraryBadge(size: 1_048_576, format: "sf2", fileCount: 1, regionCount: nil),
                       "1.0 MiB · SF2 · Files: 1")
        XCTAssertEqual(ETSFZMessages.libraryBadge(size: 1_048_576, format: "sfz", fileCount: 1, regionCount: nil),
                       "1.0 MiB · Files: 1", "SFZ は形式を出さない")
    }
}
