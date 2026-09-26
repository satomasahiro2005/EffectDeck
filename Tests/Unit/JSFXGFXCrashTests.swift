//  JSFXGFXCrashTests.swift
//  @gfx から CoreText / LICE へ届く壊れた値。**アプリごと落ちないこと**を見る。
//
//  どれも 1 行で gfx のキューを trap か範囲外の読み書きで落としていた。
//  連鎖は保存されていて、カードは起動のたびに開き直るので、一度落ちると起動のたびに落ちる。
//  値は監査で再現に使ったものをそのまま使う。落ちたらテストのプロセスごと死ぬので、
//  **最後まで走ったことは slider1 で確かめる**（@gfx の最後の行で 1 を入れる）。

import XCTest
import Foundation

final class JSFXGFXCrashTests: XCTestCase {

    private static let width: UInt32 = 320
    private static let height: UInt32 = 240
    private static let header = "desc:gfx crash\nslider1:0<0,1000,1>probe\n@gfx 320 240\n"

    /// バイト列のまま一時ファイルへ書いて開く。CP932 や CP1252 をそのまま通すため Data で受ける。
    private func load(_ source: Data) throws -> JSFXHost {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gfx-crash-\(UUID().uuidString).jsfx")
        try source.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let result = JSFX.open(path: url.path)
        guard let raw = result.raw else {
            throw JSFXFixtureError.compileFailed(name: url.lastPathComponent, message: result.message)
        }
        return JSFXHost(raw)
    }

    private func load(gfx body: String) throws -> JSFXHost {
        try load(Data((Self.header + body + "\n").utf8))
    }

    /// 書体名の部分だけ生のバイトで差し込む。
    private func load(fontName: [UInt8], flags: String = "") throws -> JSFXHost {
        var source = Data((Self.header + "gfx_setfont(1,\"").utf8)
        source.append(contentsOf: fontName)
        source.append(Data("\",14\(flags));\nslider1=gfx_texth;\ngfx_x=10; gfx_y=10; gfx_drawstr(\"hello\");\n".utf8))
        return try load(source)
    }

    /// 2 フレーム描く。2 フレーム目は 1 フレーム目が残した状態（書体や画像）を踏む。
    private func draw(_ host: JSFXHost) {
        for _ in 0..<2 { _ = ETJSFX_RunGFX(host.raw, Self.width, Self.height, 1) }
    }

    private func redPixels(_ host: JSFXHost) -> Int {
        var bytes = [UInt8](repeating: 0, count: Int(Self.width * Self.height * 4))
        var width: UInt32 = 0, height: UInt32 = 0, stride: UInt32 = 0
        guard ETJSFX_CopyGFX(host.raw, &bytes, bytes.count, &width, &height, &stride) else { return -1 }
        var count = 0
        for y in 0..<Int(height) {
            for x in 0..<Int(width) {
                let p = y * Int(stride) + x * 4   // BGRA
                if bytes[p + 2] > 200 && bytes[p + 1] < 50 && bytes[p] < 50 { count += 1 }
            }
        }
        return count
    }

    // MARK: - 書体名（ETLICEFont.mm）

    /// **CP932 の書体名。**日本語版 Windows の REAPER で書かれた JSFX はこのまま届く。
    /// UTF-8 として読めないと CFRelease(NULL) で trap していた。
    func testShiftJISFontName() throws {
        let host = try load(fontName: [0x83, 0x81, 0x83, 0x43, 0x83, 0x8A, 0x83, 0x49])   // メイリオ
        draw(host)
        XCTAssertGreaterThan(host.get(0), 8, "既定の 8 px ではなく、この番号の書体の行の高さ")
    }

    /// CP1252 の書体名（Café）。
    func testLatin1FontName() throws {
        let host = try load(fontName: Array("Caf".utf8) + [0xE9])
        draw(host)
        XCTAssertGreaterThan(host.get(0), 8)
    }

    /// ファイルは ASCII でも、EEL の `\xNN` は生のバイトになる。
    func testEscapedByteFontName() throws {
        let host = try load(fontName: Array(#"Caf\xe9"#.utf8))
        draw(host)
        XCTAssertGreaterThan(host.get(0), 8)
    }

    /// 正しい UTF-8 でも 128 バイト目で切られると字の途中で終わる（last_fontname は 128）。
    func testFontNameCutInsideACharacter() throws {
        let host = try load(fontName: Array(String(repeating: "a", count: 126).utf8) + [0xC3, 0xA9])
        draw(host)
        XCTAssertGreaterThan(host.get(0), 8)
    }

    /// 実行中に組み立てた名前。
    func testFontNameBuiltAtRuntime() throws {
        let host = try load(gfx: """
            #f = "Arial";
            str_setchar(#f, 0, 0xE9);
            gfx_setfont(1, #f, 14);
            slider1 = gfx_texth;
            gfx_x = 10; gfx_y = 10; gfx_drawstr("hello");
            """)
        draw(host)
        XCTAssertGreaterThan(host.get(0), 8)
    }

    /// 太字や斜体を持たない書体に 'bi'。CTFontCreateCopyWithSymbolicTraits は NULL を返す。
    func testBoldItalicOnFaceWithoutThem() throws {
        for face in ["Zapfino", "Chalkduster", "Papyrus"] {
            let host = try load(fontName: Array(face.utf8), flags: ",'bi'")
            draw(host)
            XCTAssertGreaterThan(host.get(0), 8, face)
        }
    }

    // MARK: - LICE（Patches/ysfx-effectdeck-ios.diff）

    /// 裏返しの blit は今までどおり描ける。上流 WDL 0e7e5bfd0 が触った所なので、壊していないことを見る。
    func testMirroredBlitStillDraws() throws {
        let host = try load(gfx: """
            gfx_setimgdim(0, 100, 100);
            gfx_dest = 0; gfx_set(1, 0, 0, 1); gfx_rect(0, 0, 100, 100);
            gfx_dest = -1;
            gfx_blit(0, 1, 0, 0, 0, 100, 100, 150, 20, -100, 100);
            """)
        draw(host)
        XCTAssertGreaterThanOrEqual(redPixels(host), 9000, "100x100 の赤がほぼ全部写る")
    }

    /// 元の範囲が画像の外。LICE_ScaledBlit が元画像より手前を読んでいた（上流 WDL f9d7b1b3f）。
    /// 裏返し（幅か高さが負）か、元の幅がほぼ 0 のときに起きる。
    func testBlitSourceOutsideTheImage() throws {
        let host = try load(gfx: """
            gfx_setimgdim(0, 100, 100);
            gfx_blit(0, 1, 0, -500, 0, 100, 100, 150, 150, -100, 100);
            gfx_blit(0, 1, 0, 0, -1000000, 100, 100, 150, 150, 100, -100);
            gfx_blit(0, 1, 0, -10000000, 0, 0.00001, 64, 0, 0, 320, 64);
            gfx_blit(0, 1, 0, 5, 0, -100000, 10, 0, 0, 10, 10);
            slider1 = 1;
            """)
        draw(host)
        XCTAssertEqual(host.get(0), 1)
    }

    /// int に収まらない座標の blur。-INT_MIN と 0-INT_MIN で LICE_Blur の検査が -Os で消えていた。
    func testBlurWithHugeCoordinates() throws {
        let host = try load(gfx: """
            gfx_x = -6000000000; gfx_y = 3000000000; gfx_blurto(-3000000000, 0);
            gfx_x = 0; gfx_y = 0; gfx_blurto(1/0, -1/0);
            slider1 = 1;
            """)
        draw(host)
        XCTAssertEqual(host.get(0), 1)
    }

    /// 頂点が INT_MAX。x1b++ と cnt=x2-x1 が折り返して、行の外へ約 2^31 画素書いていた。
    func testTriangleWithHugeVertices() throws {
        let host = try load(gfx: """
            gfx_a = 0.5;
            gfx_triangle(-1000000, 2147483647, 2048, 0, 2147483647, 0);
            gfx_triangle(-1000000, 3000000000, 2048, 0, 3000000000, 0);
            gfx_triangle(-1000000, 3000000000, 2048, 0, 3000000000, 0, 5, 5);
            slider1 = 1;
            """)
        draw(host)
        XCTAssertEqual(host.get(0), 1)
    }

    /// divw*divh*2 が int で折り返す表（46341x46341 → 9266 個）。RAM の外を読んでいた。
    func testTransformBlitTableSizeOverflow() throws {
        let host = try load(gfx: """
            gfx_setimgdim(0, 64, 64);
            gfx_transformblit(0, 0, 0, 30000, 30000, 46341, 46341, 0);
            slider1 = 1;
            """)
        draw(host)
        XCTAssertEqual(host.get(0), 1)
    }

    /// 正しい大きさの表は今までどおり描ける。
    func testTransformBlitStillDraws() throws {
        let host = try load(gfx: """
            gfx_setimgdim(0, 100, 100);
            gfx_dest = 0; gfx_set(1, 0, 0, 1); gfx_rect(0, 0, 100, 100);
            gfx_dest = -1;
            0[0] = 0; 0[1] = 0;   0[2] = 100; 0[3] = 0;
            0[4] = 0; 0[5] = 100; 0[6] = 100; 0[7] = 100;
            gfx_transformblit(0, 10, 10, 100, 100, 2, 2, 0);
            """)
        draw(host)
        XCTAssertGreaterThanOrEqual(redPixels(host), 5000, "端の丸めは問わない。描けていること")
    }

    // MARK: - コンパイル（nseel-compiler.c）

    /// 引数の数を間違えた組み込み関数。表の最後の項目だと 1 つ先を読んでいた（上流 WDL f31b13bfc）。
    /// **普通のコンパイルエラーになる。**
    func testWrongArityOnLastBuiltinIsACompileError() throws {
        for call in ["tan(1,2)", "tan(1,2,3)", "time_precise(1,2)"] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("arity-\(UUID().uuidString).jsfx")
            try Data("desc:arity\n@init\nx = \(call);\n".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = JSFX.open(path: url.path)
            XCTAssertNil(result.raw, call)
            XCTAssertFalse(result.message.isEmpty, call)
        }
    }
}
