//  BassManagementSettingsTests.swift
//  Bass Managementの89 floatの読み書きと判断（BassManagementSettings.swift）。**実機もエンジンも要らない。**
//
//  判断（設定の誤り・Subの入切・経路の要約・Linearの入力）は上流の画面のクラス
//  plugins/basics/bass_management.jsの同じメソッドに作らせた見本と照合する
//  （Tools/golden/designers_a_golden.mjs。読み方はDesignersAGolden.swift）。
//  保存形式（JSONの読み書き）はBassManagementTests.swiftが見ている。
//
//  壊れるとSubやLFEが無音になる、低域が二重に出る、設計がやり直され続ける。

import XCTest

final class BassManagementSettingsTests: XCTestCase {

    private typealias Settings = BassManagementSettings

    // MARK: - 並び

    /// riはparams.jsonの順ではなく末尾の73〜88に来る。位置はkeyから引く。
    func testLayoutRiAtOffsets73to88() throws {
        let spec = try catalogSpec()
        let layout = try XCTUnwrap(Settings.Layout(params: spec.params))
        let ri = try XCTUnwrap(spec.params.first { $0.key == "ri" })
        XCTAssertEqual(layout.inversions, 73)
        XCTAssertEqual(ri.offset, 73)
        XCTAssertEqual(ri.offset + ri.count - 1, 88)
        XCTAssertEqual(layout.floatCount, 89)
        XCTAssertEqual(layout.floatCount, spec.floatCount)

        let pairs: [(String, Int)] = [
            ("ph", layout.phase), ("tp", layout.taps), ("ro", layout.roles), ("fc", layout.frequencies),
            ("sl", layout.slopes), ("rt", layout.routes), ("ri", layout.inversions), ("su", layout.subs),
            ("lf", layout.lfeFrequency), ("ls", layout.lfeSlope), ("lo", layout.lfeLowpass),
            ("bg", layout.bassGain), ("lg", layout.lfeGain), ("hg", layout.headroom),
        ]
        for (key, offset) in pairs {
            XCTAssertEqual(spec.params.first { $0.key == key }?.offset, offset, key)
        }
        // 1つでも欠けたら作らない（画面もdesignerも動かせない）。
        XCTAssertNil(Settings.Layout(params: spec.params.filter { $0.key != "hg" }))
    }

    /// 読んで書き戻すと同じ89個に戻る。Layoutは89個全部を覆っている。
    func testValuesRoundTrip() throws {
        let spec = try catalogSpec()
        let layout = try XCTUnwrap(Settings.Layout(params: spec.params))
        var values = spec.defaults
        func put(_ offset: Int, _ items: [Float]) {
            for (index, item) in items.enumerated() { values[offset + index] = item }
        }
        put(layout.phase, [1])
        put(layout.taps, [2])
        put(layout.roles, [1, 1, 1, 2, 1, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 3])
        put(layout.frequencies, [80, 100.5, 60, 120, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80, 250])
        put(layout.slopes, [24, 48, 96, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 48])
        put(layout.routes, [8, 8, 8, 8, 8, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        put(layout.inversions, [0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        put(layout.subs, [8])
        put(layout.lfeFrequency, [110])
        put(layout.lfeSlope, [48])
        put(layout.lfeLowpass, [1])
        put(layout.bassGain, [-3.5])
        put(layout.lfeGain, [2])
        put(layout.headroom, [-6])

        let settings = Settings(values: values, layout: layout)
        XCTAssertTrue(settings.linear)
        XCTAssertEqual(settings.taps, 32768)
        XCTAssertEqual(settings.subs, 8)
        XCTAssertTrue(settings.lfeLowpass)

        var written = [Float](repeating: .nan, count: values.count)
        settings.write(into: &written, layout: layout)
        XCTAssertEqual(written, values)

        // 触っていない位置は元のまま（並びが長くても短くても落ちない）。
        var longer = [Float](repeating: 7, count: 100)
        settings.write(into: &longer, layout: layout)
        XCTAssertEqual(Array(longer[89...]), [Float](repeating: 7, count: 11))
        var shorter = [Float](repeating: 0, count: 10)
        settings.write(into: &shorter, layout: layout)
        XCTAssertEqual(shorter.count, 10)
    }

    /// 数でない値・範囲外の値を読んでも落ちず、寄せた値で書き戻す。
    func testValuesAreSanitizedOnRead() throws {
        let spec = try catalogSpec()
        let layout = try XCTUnwrap(Settings.Layout(params: spec.params))
        var values = spec.defaults
        values[layout.roles] = 1.4
        values[layout.frequencies] = .nan
        values[layout.routes] = -5
        values[layout.inversions] = 1e30
        values[layout.subs] = 70000
        values[layout.lfeLowpass] = 0.7
        values[layout.lfeFrequency] = .infinity
        values[layout.taps] = 1e20
        values[layout.headroom] = .nan

        let settings = Settings(values: values, layout: layout)
        XCTAssertEqual(settings.roles[0], 1)
        XCTAssertEqual(settings.frequencies[0], 80)
        XCTAssertEqual(settings.routes[0], 0)
        XCTAssertEqual(settings.inversions[0], 65535)
        XCTAssertEqual(settings.subs, 65535)
        XCTAssertTrue(settings.lfeLowpass)
        XCTAssertEqual(settings.lfeFrequency, 120)
        XCTAssertEqual(settings.tapsIndex, 65536)
        XCTAssertEqual(settings.taps, 16384)
        XCTAssertEqual(settings.headroom, 0)
        // 値が足りない並び（0個）でも既定の形で読める。
        XCTAssertEqual(Settings(values: [], layout: layout).roles, [Int](repeating: 0, count: 16))
    }

    // MARK: - 設定の誤り

    /// 8つの誤りを幅1・2・16で1つずつ作る（幅16では「幅の外」の2つは起こりえない）。
    func testConfigurationErrorAll8_width1_2_16() {
        typealias E = Settings.ConfigurationError
        func check(_ width: Int, all: Bool = true, _ expected: E?, line: UInt = #line,
                   _ edit: (inout Settings) -> Void) {
            var s = Settings()
            edit(&s)
            XCTAssertEqual(s.configurationError(allChannels: all, width: width), expected, line: line)
        }
        for width in [1, 2, 16] {
            check(width, all: false, .notAllChannels) { _ in }
        }
        check(0, .widthUnavailable) { _ in }
        check(17, .widthUnavailable) { _ in }

        check(1, .subOutsideWidth) { $0.subs = 0b10 }
        check(2, .subOutsideWidth) { $0.subs = 0b100 }

        check(1, .outsideWidth(1)) { $0.roles[1] = 1 }
        check(2, .outsideWidth(5)) { $0.roles[5] = 2 }
        check(2, .outsideWidth(9)) { $0.routes[9] = 4 }
        // Unusedと Full Rangeは幅の外に居てもよい。
        check(2, nil) { $0.roles[9] = 3; $0.roles[10] = 0 }

        check(1, .mainAndSub(0)) { $0.subs = 1 }
        check(2, .mainAndSub(1)) { $0.subs = 2; $0.roles[1] = 1; $0.roles[0] = 3 }
        // 前のChの誤りが先に出る（ch0のLFEに送り先が無い）。
        check(2, .noTarget(0)) { $0.subs = 2; $0.roles[1] = 1; $0.roles[0] = 2 }
        check(16, .mainAndSub(15)) { $0.subs = 1 << 15; $0.roles = [Int](repeating: 3, count: 16); $0.roles[15] = 0 }

        check(1, .inversionWithoutRoute(0)) { $0.subs = 1; $0.roles[0] = 2; $0.inversions[0] = 1 }
        check(2, .inversionWithoutRoute(0)) {
            $0.subs = 2; $0.roles = [1, 2] + [Int](repeating: 0, count: 14)
            $0.routes[0] = 2; $0.inversions[0] = 3; $0.routes[1] = 2
        }
        check(16, .inversionWithoutRoute(0)) {
            $0.subs = 8; $0.roles = [Int](repeating: 3, count: 16); $0.roles[3] = 2; $0.roles[0] = 1
            $0.routes[0] = 8; $0.inversions[0] = 1 << 14
        }

        check(1, .noTarget(0)) { $0.subs = 1; $0.roles[0] = 2 }
        check(2, .noTarget(0)) { $0.subs = 2; $0.roles = [1, 2] + [Int](repeating: 0, count: 14); $0.routes[1] = 2 }
        check(16, .noTarget(7)) {
            $0.subs = 8; $0.roles = [Int](repeating: 3, count: 16); $0.roles[3] = 2; $0.roles[7] = 1
            $0.routes[3] = 8
        }

        check(1, .unavailableTarget(0)) { $0.subs = 1; $0.roles[0] = 2; $0.routes[0] = 2 }
        check(2, .unavailableTarget(0)) {
            $0.subs = 2; $0.roles = [1, 2] + [Int](repeating: 0, count: 14); $0.routes[0] = 1; $0.routes[1] = 2
        }
        check(16, .unavailableTarget(0)) {
            $0.subs = 8; $0.roles = [Int](repeating: 3, count: 16); $0.roles[3] = 2; $0.roles[0] = 1
            $0.routes[3] = 8; $0.routes[0] = 8 | (1 << 15)
        }

        // 文言は上流のまま（Chは1から数える）。All以外の1文だけは画面が差し替える。
        XCTAssertEqual(E.outsideWidth(4).message, "Ch 5 is configured outside the current processing width.")
        XCTAssertEqual(E.mainAndSub(0).message, "Ch 1 cannot be both a Main input and a Sub output.")
        XCTAssertEqual(E.notAllChannels.message, "Set Ch to All.")
    }

    /// 誤りの有無と文言が上流の_configurationErrorと一致する（112通り。8種すべてと誤りなしを含む）。
    func testConfigurationErrorMatchesUpstream() throws {
        let cases = try DesignersAGolden.load().bassManagement.configurationError
        XCTAssertEqual(Set(cases.map { $0.message.replacingOccurrences(of: "[0-9]+", with: "#",
                                                                        options: .regularExpression) }).count,
                       8, "見本が7種の誤りと誤りなしを覆っていない")
        for (index, entry) in cases.enumerated() {
            let s = settings(roles: entry.roles, routes: entry.routes, inversions: entry.inversions, subs: entry.subs)
            let message = s.configurationError(allChannels: true, width: entry.width)?.message ?? ""
            XCTAssertEqual(message, entry.message, "[\(index)] 幅\(entry.width) su=\(entry.subs)")
        }
    }

    /// 誤りの無い形。Subが無いのも誤りではない（カーネルは素通し）。
    func testNoError() {
        XCTAssertNil(Settings().configurationError(allChannels: true, width: 2))
        XCTAssertNil(Settings().configurationError(allChannels: true, width: 16))

        // 7.1: L R C LFE Ls Rs Lb RbのうちLFE以外をManagedにしてSub（Ch4）へ送る。
        var s = Settings()
        s.roles = [1, 1, 1, 2, 1, 1, 1, 1] + [Int](repeating: 3, count: 8)
        s = s.settingSubOutput(3, enabled: true, width: 8)
        XCTAssertNil(s.configurationError(allChannels: true, width: 8))
        // 位相を返しても、入っている経路なら誤りではない。
        s = s.togglingInversion(input: 0, output: 3)
        XCTAssertNil(s.configurationError(allChannels: true, width: 8))
    }

    // MARK: - 直す

    /// 入れるとそのChをLFEにし、幅の全入力からそのSubへ送る（位相は戻す）。
    /// 切ると全入力の経路と位相からそのbitを落とし、Roleは触らない。
    func testSubOutputOnOff() {
        var s = Settings()
        s.roles = [1, 1, 0, 0] + [Int](repeating: 0, count: 12)
        s.inversions[1] = 4
        s.routes[1] = 4 | 1
        let on = s.settingSubOutput(2, enabled: true, width: 4)
        XCTAssertEqual(on.roles[2], Settings.Role.lfe.rawValue)
        XCTAssertEqual(on.subs, 4)
        XCTAssertEqual(Array(on.routes[0..<4]), [4, 5, 4, 4])
        XCTAssertEqual(Array(on.routes[4...]), [Int](repeating: 0, count: 12), "幅の外へは足さない")
        XCTAssertEqual(on.inversions[1], 0)

        let off = on.settingSubOutput(2, enabled: false, width: 4)
        XCTAssertEqual(off.subs, 0)
        XCTAssertEqual(Array(off.routes[0..<4]), [0, 1, 0, 0])
        XCTAssertEqual(off.roles[2], Settings.Role.lfe.rawValue, "切ってもRoleは戻さない")

        XCTAssertEqual(s.settingSubOutput(16, enabled: true, width: 4), s, "16以上のChは何もしない")
        XCTAssertEqual(s.settingSubOutput(-1, enabled: true, width: 4), s)
    }

    /// 上流の_setSubOutputEnabledがsetParametersへ渡す値と一致する。
    func testSubOutputMatchesUpstream() throws {
        for (index, entry) in try DesignersAGolden.load().bassManagement.subOutput.enumerated() {
            let before = settings(roles: entry.before.roles, routes: entry.before.routes,
                                  inversions: entry.before.inversions, subs: entry.before.subs)
            let after = before.settingSubOutput(entry.channel, enabled: entry.enabled, width: entry.width)
            let label = "[\(index)] Ch\(entry.channel + 1) \(entry.enabled ? "on" : "off") 幅\(entry.width)"
            XCTAssertEqual(after.roles, entry.after.roles, "\(label) roles")
            XCTAssertEqual(after.routes, entry.after.routes, "\(label) routes")
            XCTAssertEqual(after.inversions, entry.after.inversions, "\(label) inversions")
            XCTAssertEqual(after.subs, entry.after.subs, "\(label) subs")
        }
    }

    /// ONを切ると位相のbitも落ちる（bass_management.js:982-993）。
    func testTogglingRouteClearsInversion() {
        var s = Settings()
        s.routes[2] = 0b1010
        s.inversions[2] = 0b1000
        let off = s.togglingRoute(input: 2, output: 3)
        XCTAssertEqual(off.routes[2], 0b0010)
        XCTAssertEqual(off.inversions[2], 0)
        let on = off.togglingRoute(input: 2, output: 3)
        XCTAssertEqual(on.routes[2], 0b1010)
        XCTAssertEqual(on.inversions[2], 0, "入れ直しても位相は戻らない")
        XCTAssertEqual(s.togglingRoute(input: 16, output: 0), s)
        XCTAssertEqual(s.togglingRoute(input: 0, output: 16), s)
    }

    /// 入っていない経路の位相は返せない（bass_management.js:994-1000）。
    func testInversionNoopWhenRouteOff() {
        var s = Settings()
        s.routes[0] = 0b0100
        XCTAssertEqual(s.togglingInversion(input: 0, output: 1), s)
        let inverted = s.togglingInversion(input: 0, output: 2)
        XCTAssertEqual(inverted.inversions[0], 0b0100)
        XCTAssertEqual(inverted.togglingInversion(input: 0, output: 2).inversions[0], 0)
        XCTAssertEqual(s.togglingInversion(input: -1, output: 2), s)
    }

    // MARK: - 要約

    /// 経路の1行が上流の_renderConfigurationと一致する。
    /// **ManagedもLFEも無いときだけ短い。**上流は「All Full Range channels pass through.」を続けるが、
    /// 画面に説明の文を足さないので前半だけを出している（2.11.0の移植から）。
    func testRouteSummary() throws {
        let upstreamNoInputs = "No managed or LFE inputs. All Full Range channels pass through."
        var sawShort = false
        for (index, entry) in try DesignersAGolden.load().bassManagement.routeSummary.enumerated() {
            let s = settings(roles: entry.roles, routes: entry.routes,
                             inversions: [Int](repeating: 0, count: 16), subs: entry.subs)
            let expected = entry.text == upstreamNoInputs ? "No managed or LFE inputs." : entry.text
            sawShort = sawShort || entry.text == upstreamNoInputs
            XCTAssertEqual(s.routeSummary(width: entry.width), expected, "[\(index)] 幅\(entry.width)")
        }
        XCTAssertTrue(sawShort, "見本にManagedもLFEも無い形が無い")

        var s = Settings()
        XCTAssertEqual(s.routeSummary(width: 2), "No Sub outputs selected.")
        s.roles = [1, 2] + [Int](repeating: 0, count: 14)
        s.subs = 2
        s.routes[0] = 2
        XCTAssertEqual(s.routeSummary(width: 2), "Ch 1 Managed → Sub 2 · Ch 2 LFE → no Sub")
    }

    // MARK: - 設計の鍵

    /// LPの掛かる入力（Managedと、LFE Low-passが入っているときのLFE）が上流の_linearInputChannelsと同じ。
    func testLinearInputsMatchUpstream() throws {
        for (index, entry) in try DesignersAGolden.load().bassManagement.linearInputs.enumerated() {
            var s = settings(roles: entry.roles, routes: [Int](repeating: 0, count: 16),
                             inversions: [Int](repeating: 0, count: 16), subs: 0)
            s.lfeLowpass = entry.lfeLowpass
            let channels = s.designKey(sampleRate: 48000, width: entry.width).filters.map(\.channel)
            XCTAssertEqual(channels, entry.inputs, "[\(index)] 幅\(entry.width) lo=\(entry.lfeLowpass)")
        }
    }

    /// レートは8000〜768000に収めてから丸める（normalizeBassManagementDesignConfigと同じ）。
    func testDesignKeyRateRoundedClamped() throws {
        let s = Settings()
        for entry in try DesignersAGolden.load().bassManagement.designRates {
            XCTAssertEqual(s.designKey(sampleRate: entry.sampleRate, width: 2).sampleRate, entry.normalized,
                           "\(entry.sampleRate)")
        }
        XCTAssertEqual(s.designKey(sampleRate: 44100.5, width: 2).sampleRate, 44101)
        XCTAssertEqual(s.designKey(sampleRate: 1e300, width: 2).sampleRate, 768000)
    }

    /// 数でないレートは48000（上流のfiniteNumberは無限大も既定へ倒す）。
    func testDesignKeyNaNIs48000() {
        let s = Settings()
        XCTAssertEqual(s.designKey(sampleRate: .nan, width: 2).sampleRate, 48000)
        XCTAssertEqual(s.designKey(sampleRate: .infinity, width: 2).sampleRate, 48000)
        XCTAssertEqual(s.designKey(sampleRate: -.infinity, width: 2).sampleRate, 48000)
    }

    /// Full RangeのChのfcを動かしても鍵は変わらない（数秒の設計をやり直さない）。
    /// Managedのfc・LFE Low-passの入切とLFEのfcは鍵を変える。
    func testDesignKeyIgnoresFullRangeFreq() {
        var s = Settings()
        s.roles = [0, 1, 2] + [Int](repeating: 0, count: 13)
        s.linear = true
        let base = s.designKey(sampleRate: 48000, width: 3)
        XCTAssertEqual(base.filters.map(\.channel), [1])

        var fullRange = s
        fullRange.frequencies[0] = 150
        fullRange.slopes[0] = 96
        XCTAssertEqual(fullRange.designKey(sampleRate: 48000, width: 3), base)

        var lfeOff = s
        lfeOff.lfeFrequency = 200
        XCTAssertEqual(lfeOff.designKey(sampleRate: 48000, width: 3), base, "LFE Low-passが切れていれば効かない")

        var managed = s
        managed.frequencies[1] = 100
        XCTAssertNotEqual(managed.designKey(sampleRate: 48000, width: 3), base)

        var lfeOn = s
        lfeOn.lfeLowpass = true
        let withLFE = lfeOn.designKey(sampleRate: 48000, width: 3)
        XCTAssertEqual(withLFE.filters, [
            BassManagementDesignKey.Filter(channel: 1, cutoff: 80, slope: 24),
            BassManagementDesignKey.Filter(channel: 2, cutoff: 120, slope: 24),
        ])
        lfeOn.lfeFrequency = 90
        XCTAssertNotEqual(lfeOn.designKey(sampleRate: 48000, width: 3), withLFE)

        // 幅の外のManagedは鍵に入らない。幅とtapsは鍵に入る。
        XCTAssertEqual(s.designKey(sampleRate: 48000, width: 1).filters, [])
        XCTAssertNotEqual(s.designKey(sampleRate: 48000, width: 4), base)
        var taps = s
        taps.tapsIndex = 2
        XCTAssertNotEqual(taps.designKey(sampleRate: 48000, width: 3), base)
    }

    // MARK: - 丸め

    /// cutoffは20〜300（数でなければ既定）、slopeは24/48/96以外は24、幅は1〜16。
    func testCutoffSlopeClampWidth() {
        XCTAssertEqual(Settings.cutoff(5, fallback: 80), 20)
        XCTAssertEqual(Settings.cutoff(500, fallback: 80), 300)
        XCTAssertEqual(Settings.cutoff(85.5, fallback: 80), 85.5)
        XCTAssertEqual(Settings.cutoff(.nan, fallback: 120), 120)
        XCTAssertEqual(Settings.cutoff(.infinity, fallback: 80), 80)
        XCTAssertEqual(Settings.slope(48), 48)
        XCTAssertEqual(Settings.slope(96), 96)
        XCTAssertEqual(Settings.slope(72), 24)
        XCTAssertEqual(Settings.slope(-24), 24)
        XCTAssertEqual(Settings.clampWidth(0), 1)
        XCTAssertEqual(Settings.clampWidth(-3), 1)
        XCTAssertEqual(Settings.clampWidth(6), 6)
        XCTAssertEqual(Settings.clampWidth(17), 16)

        // filter(for:)は丸めた値を返す。
        var s = Settings()
        s.roles[0] = 1
        s.frequencies[0] = 1000
        s.slopes[0] = 30
        XCTAssertEqual(s.filter(for: 0)?.cutoff, 300)
        XCTAssertEqual(s.filter(for: 0)?.slope, 24)
        XCTAssertNil(s.filter(for: 16))
        XCTAssertNil(s.filter(for: -1))
    }

    /// tpの添字が外れていれば16384（kernel.cpp:35-37）。
    func testTaps16384Fallback() {
        var s = Settings()
        for (index, taps) in [(0, 8192), (1, 16384), (2, 32768), (-1, 16384), (3, 16384), (65536, 16384)] {
            s.tapsIndex = index
            XCTAssertEqual(s.taps, taps, "tp=\(index)")
        }
    }

    /// Linearはtaps/2＋頭ブロック128、IIRは0（bass_management.js:657）。
    /// 上流の設計が返す総遅延（design-core.jsのtotalDelaySamples）とも合う。
    func testLatencySamples() throws {
        var s = Settings()
        s.tapsIndex = 0
        XCTAssertEqual(s.latencySamples, 0)
        s.linear = true
        XCTAssertEqual(s.latencySamples, 4096 + 128)
        s.tapsIndex = 2
        XCTAssertEqual(s.latencySamples, 16384 + 128)
        for design in try DesignersAGolden.load().bassManagement.designs {
            s.tapsIndex = design.input.tapsIndex
            XCTAssertEqual(s.latencySamples, design.latencyInfo.totalDelaySamples, design.input.name)
            XCTAssertEqual(design.latencyInfo.blockDelaySamples, Settings.headBlock)
        }
    }

    // MARK: - 道具

    private func catalogSpec() throws -> ETEffect {
        try XCTUnwrap(ETCatalog.first { $0.type == "BassManagementPlugin" }, "BassManagementPlugin が catalog に無い")
    }

    private func settings(roles: [Int], routes: [Int], inversions: [Int], subs: Int) -> Settings {
        var s = Settings()
        s.roles = roles
        s.routes = routes
        s.inversions = inversions
        s.subs = subs
        return s
    }
}
