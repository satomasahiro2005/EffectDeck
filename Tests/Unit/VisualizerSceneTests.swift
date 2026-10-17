//  VisualizerSceneTests.swift
//  Visualizer の場面（VisualizerScene）。保存の形・範囲の直し方・要素ごとの解析の頼み方。
//
//  壊れると: 保存した場面が起動で消える・欠ける、壊れた保存や範囲外の矩形が舞台の外に出る、
//  要素や JSFX の上限が効かない、縦横の並びを選び間違える、曲を使えない版で曲の要素が描かれる。

import XCTest

final class VisualizerSceneTests: XCTestCase {

    private func element(_ kind: ETVisualizerElementKind, rect: ETVisualizerRect = ETVisualizerRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5),
                         look: ETVisualizerStyle = .effetune) -> ETVisualizerElement {
        ETVisualizerElement(id: UUID(), kind: kind, rect: rect, look: look,
                            color: ETVisualizerElement.defaultColor(kind: kind, look: look),
                            jsfx: kind == .jsfx ? ETVisualizerJSFXElement(entryID: "jsfx:x", name: "X") : nil)
    }

    private func scene(portrait: [ETVisualizerElement] = [], landscape: [ETVisualizerElement] = []) -> ETVisualizerScene {
        ETVisualizerScene(name: "Test", background: ETVisualizerBackground(), portrait: portrait, landscape: landscape)
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: 保存

    func testRoundTripEveryPreset() {
        for preset in ETVisualizerPresets.all {
            XCTAssertEqual(ETVisualizerScene.decode(preset.scene.encoded()), preset.scene, preset.id)
        }
    }

    func testRoundTripEveryKindWithJSFXSliders() {
        var all = ETVisualizerElementKind.allCases.map { element($0) }
        all[all.count - 1].jsfx = ETVisualizerJSFXElement(entryID: "jsfx:abc", name: "Scope",
                                                          sliders: [0: 0.25, 3: -12.5], blend: .screen)
        all[0].look = .classic
        all[0].color = ETVisualizerColor(0x123456)
        all[0].card = true
        all[0].glow = true
        all[0].opacity = 0.6
        all[0].flipX = true
        all[0].flipY = true
        all[0].spectrumDisplay = .bar
        all[0].analogMode = .loudness
        all[0].font = .serif
        all[0].bold = true
        all[0].alignment = .trailing
        var s = scene(portrait: all, landscape: all.reversed().map { var e = $0; e.id = UUID(); return e })
        s.background = ETVisualizerBackground(kind: .gradient, color: ETVisualizerColor(0x112233),
                                              color2: ETVisualizerColor(0x445566), dim: 0.7,
                                              cardColor: ETVisualizerColor(0x010203),
                                              cardBorder: ETVisualizerColor(0x040506), cardOpacity: 0.4)
        XCTAssertEqual(s.normalized(), s)
        XCTAssertEqual(ETVisualizerScene.decode(s.encoded()), s)
    }

    func testEncodingIsStableAndHasWireShape() {
        let data = ETVisualizerPresets.studio.encoded()
        XCTAssertEqual(data, ETVisualizerPresets.studio.encoded())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"background\":{\"card\":\"#0E141E\",\"cardBorder\":\"#222C3B\",\"cardOpacity\":0.92,"), text)
        XCTAssertTrue(text.contains("\"v\":2"), text)
        XCTAssertTrue(text.contains("\"kind\":\"analog-meter\""), text)
        XCTAssertTrue(text.contains("\"rect\":[0.07,0.05,0.56,0.5]"), text)
    }

    func testGarbageNeverThrows() {
        XCTAssertNil(ETVisualizerScene.decode(nil))
        XCTAssertNil(ETVisualizerScene.decode(json("not json")))
        XCTAssertNil(ETVisualizerScene.decode(json("[1,2]")))
        XCTAssertNil(ETVisualizerScene.decode(json("{}")))
        XCTAssertNil(ETFloatingMetersScene.decode(nil))
        XCTAssertNil(ETFloatingMetersScene.decode(json("{}")))
        XCTAssertNil(ETFloatingMetersScene.decode(json("garbage")))
        XCTAssertEqual(ETVisualizerScene.decodeList(json("garbage")), [])
        XCTAssertEqual(ETVisualizerScene.decodeList(nil), [])
        // 並びが空の配列でも、キーがあれば場面。
        XCTAssertEqual(ETVisualizerScene.decode(json("{\"portrait\":[],\"landscape\":[]}"))?.portrait, [])
    }

    func testEveryFieldFallsBackIndividually() throws {
        let text = """
        {"v":2,"name":"X","background":{"kind":"nope","color":"zzz","dim":0.3},
         "landscape":[{"kind":"spectrum","look":"nope","color":"#12","rect":[0.1,0.1,0.5,0.5],
                       "display":"nope","meter":"nope","font":"nope","align":"nope","opacity":0.5,"card":true}]}
        """
        let decoded = try XCTUnwrap(ETVisualizerScene.decode(json(text)))
        XCTAssertEqual(decoded.background.kind, .solid)
        XCTAssertEqual(decoded.background.color, ETVisualizerColor(0x000000))
        XCTAssertEqual(decoded.background.dim, 0.3)
        XCTAssertEqual(decoded.portrait, [])
        let e = try XCTUnwrap(decoded.landscape.first)
        XCTAssertEqual(e.look, .effetune)
        XCTAssertEqual(e.color, ETVisualizerElement.defaultColor(kind: .spectrum, look: .effetune))
        XCTAssertEqual(e.spectrumDisplay, .line)
        XCTAssertEqual(e.analogMode, .vu)
        XCTAssertEqual(e.font, .system)
        XCTAssertEqual(e.alignment, .leading)
        XCTAssertEqual(e.opacity, 0.5)
        XCTAssertTrue(e.card)
    }

    func testUnknownKindIsDropped() throws {
        let text = """
        {"portrait":[{"kind":"hologram","rect":[0,0,1,1]},{"rect":[0,0,1,1]},{"kind":"waveform","rect":[0,0,1,1]}],"landscape":[]}
        """
        let decoded = try XCTUnwrap(ETVisualizerScene.decode(json(text)))
        XCTAssertEqual(decoded.portrait.map(\.kind), [.waveform])
    }

    func testJSFXWithoutPayloadOrEntryIsDropped() throws {
        let text = """
        {"portrait":[{"kind":"jsfx","rect":[0,0,1,1]},
                     {"kind":"jsfx","rect":[0,0,1,1],"jsfx":{"entry":"","name":"n"}},
                     {"kind":"jsfx","rect":[0,0,1,1],"jsfx":{"entry":"jsfx:a","name":"n","sliders":{"2":0.5,"x":1,"-1":2}}}],
         "landscape":[]}
        """
        let decoded = try XCTUnwrap(ETVisualizerScene.decode(json(text))).normalized()
        XCTAssertEqual(decoded.portrait.count, 1)
        XCTAssertEqual(decoded.portrait[0].jsfx?.entryID, "jsfx:a")
        XCTAssertEqual(decoded.portrait[0].jsfx?.sliders, [2: 0.5])
    }

    func testJSFXPayloadOnOtherKindIsCleared() {
        var e = element(.spectrum)
        e.jsfx = ETVisualizerJSFXElement(entryID: "x", name: "x")
        XCTAssertNil(scene(portrait: [e]).normalized().portrait[0].jsfx)
    }

    func testNonFiniteSlidersAreDropped() {
        var e = element(.jsfx)
        e.jsfx?.sliders = [0: .nan, 1: .infinity, 2: 0.5]
        XCTAssertEqual(scene(portrait: [e]).normalized().portrait[0].jsfx?.sliders, [2: 0.5])
    }

    // MARK: 範囲

    func testRectIsAlwaysInsideTheStage() {
        let rects = [
            ETVisualizerRect(x: .nan, y: 0, w: 0.5, h: 0.5),
            ETVisualizerRect(x: 0, y: 0, w: .infinity, h: 0.5),
            ETVisualizerRect(x: 0.2, y: 0.2, w: -3, h: 0),
            ETVisualizerRect(x: -4, y: 7, w: 0.5, h: 0.5),
            ETVisualizerRect(x: 0.9, y: 0.9, w: 0.5, h: 5),
        ]
        for r in rects {
            let fixed = scene(landscape: [element(.spectrum, rect: r)]).normalized().landscape[0].rect
            XCTAssertGreaterThanOrEqual(fixed.w, 0.02, "\(r)")
            XCTAssertGreaterThanOrEqual(fixed.h, 0.02, "\(r)")
            XCTAssertLessThanOrEqual(fixed.w, 1)
            XCTAssertLessThanOrEqual(fixed.h, 1)
            XCTAssertGreaterThanOrEqual(fixed.x, 0)
            XCTAssertGreaterThanOrEqual(fixed.y, 0)
            XCTAssertLessThanOrEqual(fixed.x + fixed.w, 1 + 1e-12)
            XCTAssertLessThanOrEqual(fixed.y + fixed.h, 1 + 1e-12)
        }
        XCTAssertEqual(scene(landscape: [element(.spectrum, rect: rects[0])]).normalized().landscape[0].rect,
                       ETVisualizerRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5))
        XCTAssertEqual(scene(landscape: [element(.spectrum, rect: rects[3])]).normalized().landscape[0].rect,
                       ETVisualizerRect(x: 0, y: 0.5, w: 0.5, h: 0.5))
    }

    func testOpacityAndBackgroundClamps() {
        var low = element(.spectrum); low.opacity = -2
        var high = element(.spectrum); high.opacity = 9
        var nan = element(.spectrum); nan.opacity = .nan
        let fixed = scene(portrait: [low, high, nan]).normalized().portrait
        XCTAssertEqual(fixed.map(\.opacity), [0.1, 1, 1])

        var s = scene()
        s.background.dim = 5
        s.background.cardOpacity = -1
        XCTAssertEqual(s.normalized().background.dim, 0.9)
        XCTAssertEqual(s.normalized().background.cardOpacity, 0.1)
        s.background.dim = .nan
        s.background.cardOpacity = .nan
        XCTAssertEqual(s.normalized().background.dim, 0.5)
        XCTAssertEqual(s.normalized().background.cardOpacity, 0.92)
    }

    func testDuplicateIDsAcrossLayoutsAreReissued() {
        let a = element(.spectrum)
        var b = element(.waveform)
        b.id = a.id
        var c = element(.stereo)
        c.id = a.id
        let fixed = scene(portrait: [a, b], landscape: [c]).normalized()
        XCTAssertEqual(fixed.portrait[0].id, a.id)
        XCTAssertNotEqual(fixed.portrait[1].id, a.id)
        XCTAssertNotEqual(fixed.landscape[0].id, a.id)
        XCTAssertNotEqual(fixed.portrait[1].id, fixed.landscape[0].id)
    }

    func testElementAndJSFXCaps() {
        let many = (0..<40).map { _ in element(.spectrum) }
        XCTAssertEqual(scene(portrait: many).normalized().portrait.count, 24)

        var mixed: [ETVisualizerElement] = []
        for i in 0..<10 { mixed.append(element(i % 2 == 0 ? .jsfx : .waveform)) }
        let fixed = scene(landscape: mixed).normalized().landscape
        XCTAssertEqual(fixed.filter { $0.kind == .jsfx }.count, 2)
        XCTAssertEqual(fixed.map(\.id), [mixed[0].id, mixed[1].id, mixed[2].id, mixed[3].id, mixed[5].id, mixed[7].id, mixed[9].id])
    }

    func testNameIsTrimmedCappedAndNeverEmpty() {
        var s = scene()
        s.name = "  Hello \n"
        XCTAssertEqual(s.normalized().name, "Hello")
        s.name = String(repeating: "a", count: 100)
        XCTAssertEqual(s.normalized().name.count, 64)
        s.name = "   "
        XCTAssertEqual(s.normalized().name, "Untitled")
    }

    // MARK: 規則

    func testLayoutKeyFollowsTheStageShape() {
        XCTAssertEqual(ETVisualizerLayoutKey.of(width: 393, height: 852), .portrait)
        XCTAssertEqual(ETVisualizerLayoutKey.of(width: 852, height: 393), .landscape)
        XCTAssertEqual(ETVisualizerLayoutKey.of(width: 500, height: 500), .landscape)
    }

    func testNeedsPerKindAndLook() {
        func needs(_ kind: ETVisualizerElementKind, _ look: ETVisualizerStyle,
                   mode: ETAnalogMeterChoice = .vu) -> ETVisualizerNeedsSet {
            var e = element(kind, look: look)
            e.analogMode = mode
            return scene(landscape: [e]).needs(.landscape, allowsSong: true)
        }
        XCTAssertEqual(needs(.spectrogram, .classic), .classicSpectrogram)
        XCTAssertEqual(needs(.spectrogram, .effetune), .effetuneSpectrogram)
        XCTAssertEqual(needs(.spectrum, .classic), .classicSpectrum)
        XCTAssertEqual(needs(.spectrum, .effetune), .effetuneSpectrum)
        XCTAssertEqual(needs(.levelMeter, .classic), .loudness)
        XCTAssertEqual(needs(.levelMeter, .effetune), [])
        XCTAssertEqual(needs(.analogMeter, .effetune, mode: .loudness), .loudness)
        XCTAssertEqual(needs(.analogMeter, .classic, mode: .vu), .vu)
        XCTAssertEqual(needs(.stereo, .classic), [])
        XCTAssertEqual(needs(.stereo, .effetune), .stereoEnvelope)
        for kind in [ETVisualizerElementKind.waveform, .oscilloscope, .artwork, .title, .artist, .jsfx] {
            XCTAssertEqual(needs(kind, .effetune), [], kind.rawValue)
        }
        XCTAssertEqual(scene(portrait: [element(.stereo)], landscape: [element(.spectrum)])
            .needs(.portrait, allowsSong: false), .stereoEnvelope)
    }

    func testSongElementsAreLeftOutWhenSongIsNotAllowed() {
        let s = scene(landscape: [element(.artwork), element(.title), element(.artist), element(.spectrum)])
        XCTAssertEqual(s.elements(.landscape, allowsSong: true).count, 4)
        XCTAssertEqual(s.elements(.landscape, allowsSong: false).map(\.kind), [.spectrum])
    }

    func testUsesSong() {
        for kind in [ETVisualizerElementKind.artwork, .title, .artist] {
            XCTAssertTrue(scene(landscape: [element(kind)]).usesSong(.landscape), kind.rawValue)
            XCTAssertFalse(scene(landscape: [element(kind)]).usesSong(.portrait), kind.rawValue)
        }
        XCTAssertFalse(scene(landscape: [element(.spectrum), element(.jsfx)]).usesSong(.landscape))
        var s = scene()
        s.background.kind = .artwork
        XCTAssertTrue(s.usesSong(.portrait))
        XCTAssertTrue(s.usesSong(.landscape))
    }

    func testSameLookIgnoresIDsAndName() {
        let a = ETVisualizerPresets.studio
        var b = a.withFreshIDs()
        b.name = "Other"
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.sameLook(as: b))
        b.landscape[0].glow = true
        XCTAssertFalse(a.sameLook(as: b))
        b = a
        b.background.color = ETVisualizerColor(0x111111)
        XCTAssertFalse(a.sameLook(as: b))
    }

    func testWithFreshIDsChangesEveryID() {
        let a = ETVisualizerPresets.neon
        let b = a.withFreshIDs()
        XCTAssertTrue(Set((a.portrait + a.landscape).map(\.id)).isDisjoint(with: (b.portrait + b.landscape).map(\.id)))
    }

    func testColorHex() {
        XCTAssertEqual(ETVisualizerColor(hex: "#4fd1ff")?.rgb, 0x4FD1FF)
        XCTAssertEqual(ETVisualizerColor(hex: "4FD1FF")?.rgb, 0x4FD1FF)
        XCTAssertEqual(ETVisualizerColor(0x0000FF).hex, "#0000FF")
        XCTAssertEqual(ETVisualizerColor(0xFF000000 | 0x123456).rgb, 0x123456)
        for bad in ["", "#", "#12345", "#1234567", "#GGGGGG", "red", "#12 456"] {
            XCTAssertNil(ETVisualizerColor(hex: bad), bad)
        }
        let c = ETVisualizerColor(0xFF8000).components
        XCTAssertEqual(c.r, 1, accuracy: 1e-12)
        XCTAssertEqual(c.g, 128.0 / 255, accuracy: 1e-12)
        XCTAssertEqual(c.b, 0, accuracy: 1e-12)
    }

    func testDefaultColor() {
        XCTAssertEqual(ETVisualizerElement.defaultColor(kind: .analogMeter, look: .classic).rgb, 0xACC0DE)
        XCTAssertEqual(ETVisualizerElement.defaultColor(kind: .analogMeter, look: .effetune).rgb, 0xF6F8FB)
        XCTAssertEqual(ETVisualizerElement.defaultColor(kind: .spectrum, look: .classic).rgb, 0xACC0DE)
        XCTAssertEqual(ETVisualizerElement.defaultColor(kind: .spectrum, look: .effetune).rgb, 0x40DFFF)
        for kind in [ETVisualizerElementKind.title, .artist, .artwork, .jsfx] {
            XCTAssertEqual(ETVisualizerElement.defaultColor(kind: kind, look: .effetune).rgb, 0xFFFFFF)
        }
    }

    func testKindClassification() {
        XCTAssertEqual(ETVisualizerElementKind.allCases.filter(\.isMeter).count, 7)
        XCTAssertEqual(ETVisualizerElementKind.allCases.filter(\.isSong).map(\.rawValue), ["artwork", "title", "artist"])
        XCTAssertEqual(ETVisualizerElementKind.allCases.filter(\.isText).map(\.rawValue), ["title", "artist"])
        XCTAssertEqual(ETVisualizerElementKind.levelMeter.rawValue, "level-meter")
        XCTAssertEqual(ETVisualizerElementKind.analogMeter.rawValue, "analog-meter")
        // 旧いパネルの種類と生の値が同じ（移行が恒等で写す）。
        for panel in ETVisualizerPanelKind.allCases {
            XCTAssertNotNil(ETVisualizerElementKind(rawValue: panel.rawValue), panel.rawValue)
        }
    }

    // MARK: Floating

    func testFloatingFitBecomesStrip() {
        let f = ETFloatingMetersScene(aspect: .fit, scene: scene()).normalized()
        XCTAssertEqual(f.aspect, .strip)
        let decoded = ETFloatingMetersScene.decode(json("{\"v\":2,\"aspect\":\"fit\",\"scene\":{\"portrait\":[],\"landscape\":[]}}"))
        XCTAssertEqual(decoded?.aspect, .strip)
    }

    func testFloatingLayoutPerAspect() {
        for aspect in ETVisualizerAspect.allCases where aspect != .fit {
            let expected: ETVisualizerLayoutKey = aspect == .tall ? .portrait : .landscape
            XCTAssertEqual(ETFloatingMetersScene(aspect: aspect, scene: scene()).layout, expected, aspect.rawValue)
        }
    }

    func testFloatingRoundTrip() {
        for aspect in ETVisualizerAspect.choices(for: .floating) {
            let f = ETFloatingMetersScene(aspect: aspect, scene: ETVisualizerPresets.classic)
            XCTAssertEqual(ETFloatingMetersScene.decode(f.encoded()), f)
        }
    }

    func testUserSceneListRoundTrip() {
        let list = [ETVisualizerPresets.studio, ETVisualizerPresets.neon]
        XCTAssertEqual(ETVisualizerScene.decodeList(ETVisualizerScene.encodeList(list)), list)
    }

    func testUnit() {
        XCTAssertEqual(ETVisualizerUnit.floating(pixelWidth: 1280, pixelHeight: 256), 1)
        XCTAssertEqual(ETVisualizerUnit.floating(pixelWidth: 720, pixelHeight: 1280), 1)
        XCTAssertEqual(ETVisualizerUnit.inApp(pixelWidth: 786, pixelHeight: 1704), 786.0 / 720, accuracy: 1e-12)
        XCTAssertEqual(ETVisualizerUnit.inApp(pixelWidth: 1704, pixelHeight: 786), 786.0 / 720, accuracy: 1e-12)
    }
}
