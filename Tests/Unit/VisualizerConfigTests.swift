//  VisualizerConfigTests.swift
//  Visualizer の設定（VisualizerConfig）。
//
//  壊れると: 保存した並びや縦横比が起動で消える、壊れた保存でパネルが欠ける・重なる、
//  Floating Meters の既定が今の帯から変わる、PiP が Fit で開こうとして縦横比が決まらない。

import XCTest

final class VisualizerConfigTests: XCTestCase {

    private func kinds(_ config: ETVisualizerConfig) -> [ETVisualizerPanelKind] { config.panels.map(\.kind) }
    private func on(_ config: ETVisualizerConfig) -> [ETVisualizerPanelKind] { config.panels.filter(\.isOn).map(\.kind) }

    func testFloatingDefault() {
        let c = ETVisualizerConfig.defaults(for: .floating)
        XCTAssertEqual(c.aspect, .strip)
        XCTAssertEqual(c.style, .classic)
        XCTAssertEqual(kinds(c), [.spectrogram, .waveform, .spectrum, .stereo, .levelMeter,
                                  .oscilloscope, .analogMeter, .artwork])
        XCTAssertEqual(on(c), [.spectrogram, .waveform, .spectrum, .stereo, .levelMeter])
        XCTAssertEqual(c.spectrumDisplay, .line)
        XCTAssertEqual(c.analogMode, .vu)
    }

    func testInAppDefault() {
        let c = ETVisualizerConfig.defaults(for: .inApp)
        XCTAssertEqual(c.aspect, .fit)
        XCTAssertEqual(c.style, .effetune)
        XCTAssertEqual(kinds(c), [.artwork, .spectrum, .spectrogram, .stereo, .analogMeter, .levelMeter,
                                  .waveform, .oscilloscope])
        XCTAssertEqual(on(c), [.artwork, .spectrum, .spectrogram, .stereo, .analogMeter, .levelMeter])
    }

    func testRoundTrip() {
        for surface in ETVisualizerSurface.allCases {
            var c = ETVisualizerConfig.defaults(for: surface)
            c.aspect = .wide
            c.style = surface == .inApp ? .classic : .effetune
            c.spectrumDisplay = .bar
            c.analogMode = .loudness
            c.panels.swapAt(0, 3)
            c.panels[2].isOn.toggle()
            XCTAssertEqual(ETVisualizerConfig.decode(c.encoded(), surface: surface), c)
        }
    }

    func testEncodingIsStableAndHasWireShape() {
        let c = ETVisualizerConfig.defaults(for: .floating)
        XCTAssertEqual(c.encoded(), c.encoded())
        let text = String(decoding: c.encoded(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"analog\":\"VU\",\"aspect\":\"5:1\",\"panels\":[{\"kind\":\"spectrogram\",\"on\":true}"), text)
        XCTAssertTrue(text.hasSuffix("\"spectrum\":\"line\",\"style\":\"classic\",\"v\":1}"), text)
    }

    func testGarbageAndNilGiveDefaults() {
        for surface in ETVisualizerSurface.allCases {
            let d = ETVisualizerConfig.defaults(for: surface)
            XCTAssertEqual(ETVisualizerConfig.decode(nil, surface: surface), d)
            XCTAssertEqual(ETVisualizerConfig.decode(Data("not json".utf8), surface: surface), d)
            XCTAssertEqual(ETVisualizerConfig.decode(Data("[1,2]".utf8), surface: surface), d)
            XCTAssertEqual(ETVisualizerConfig.decode(Data("{\"aspect\":5}".utf8), surface: surface), d)
        }
    }

    func testUnknownDuplicateAndMissingPanels() {
        let json = """
        {"v":1,"panels":[{"kind":"stereo","on":true},{"kind":"nope","on":true},{"kind":"stereo","on":false},
        {"kind":"spectrum","on":true}]}
        """
        let c = ETVisualizerConfig.decode(Data(json.utf8), surface: .floating)
        // 先に出た stereo だけ残り、知らない種類は消え、足りない 6 種は切ったまま allCases の順で後ろに付く。
        XCTAssertEqual(kinds(c), [.stereo, .spectrum, .spectrogram, .waveform, .oscilloscope, .levelMeter,
                                  .analogMeter, .artwork])
        XCTAssertEqual(on(c), [.stereo, .spectrum])
    }

    func testNoVisiblePanelFallsBack() {
        for json in ["{\"panels\":[]}", "{\"panels\":[{\"kind\":\"stereo\",\"on\":false}]}"] {
            let c = ETVisualizerConfig.decode(Data(json.utf8), surface: .floating)
            XCTAssertEqual(c.panels, ETVisualizerConfig.defaults(for: .floating).panels)
        }
        // Beta でアートワークだけ入れた保存を、聞き取りの無い版で読んでも何かは出る。
        var c = ETVisualizerConfig.defaults(for: .floating)
        for i in c.panels.indices { c.panels[i].isOn = c.panels[i].kind == .artwork }
        XCTAssertEqual(c.visibleKinds(allowsArtwork: true), [.artwork])
        XCTAssertEqual(c.visibleKinds(allowsArtwork: false), [c.panels.first { $0.kind != .artwork }!.kind])
    }

    func testFloatingFitBecomesStrip() {
        let json = "{\"aspect\":\"fit\"}"
        XCTAssertEqual(ETVisualizerConfig.decode(Data(json.utf8), surface: .floating).aspect, .strip)
        XCTAssertEqual(ETVisualizerConfig.decode(Data(json.utf8), surface: .inApp).aspect, .fit)
        var c = ETVisualizerConfig.defaults(for: .floating)
        c.aspect = .fit
        XCTAssertEqual(c.normalized(for: .floating).aspect, .strip)
    }

    func testUnknownValuesFallBackToTheSurfaceDefault() {
        let json = "{\"aspect\":\"2:1\",\"style\":\"neon\",\"spectrum\":\"dots\",\"analog\":\"PPM\"}"
        XCTAssertEqual(ETVisualizerConfig.decode(Data(json.utf8), surface: .floating),
                       ETVisualizerConfig.defaults(for: .floating))
        let inApp = ETVisualizerConfig.decode(Data(json.utf8), surface: .inApp)
        XCTAssertEqual(inApp.aspect, .fit)
        XCTAssertEqual(inApp.style, .effetune)
    }

    func testAspectChoicesAndRatios() {
        XCTAssertEqual(ETVisualizerAspect.choices(for: .inApp).map(\.label),
                       ["Fit", "5:1", "21:9", "16:9", "4:3", "1:1", "9:16"])
        XCTAssertEqual(ETVisualizerAspect.choices(for: .floating).map(\.label),
                       ["5:1", "21:9", "16:9", "4:3", "1:1", "9:16"])
        XCTAssertNil(ETVisualizerAspect.fit.ratio)
        XCTAssertEqual(ETVisualizerAspect.strip.ratio, 5)
        XCTAssertEqual(ETVisualizerAspect.tall.ratio!, 9.0 / 16.0, accuracy: 1e-12)
    }

    func testVisibleKindsDropsArtworkWhenNotAllowed() {
        let c = ETVisualizerConfig.defaults(for: .inApp)
        XCTAssertEqual(c.visibleKinds(allowsArtwork: true),
                       [.artwork, .spectrum, .spectrogram, .stereo, .analogMeter, .levelMeter])
        XCTAssertEqual(c.visibleKinds(allowsArtwork: false),
                       [.spectrum, .spectrogram, .stereo, .analogMeter, .levelMeter])
    }

    func testNeedsForTheDefaults() {
        let floating = ETVisualizerConfig.defaults(for: .floating)
        XCTAssertEqual(floating.needs(allowsArtwork: false),
                       [.classicSpectrogram, .classicSpectrum, .loudness])
        XCTAssertEqual(floating.needs(allowsArtwork: true), floating.needs(allowsArtwork: false))
        let inApp = ETVisualizerConfig.defaults(for: .inApp)
        XCTAssertEqual(inApp.needs(allowsArtwork: true),
                       [.effetuneSpectrogram, .effetuneSpectrum, .stereoEnvelope, .vu])
        var loud = inApp
        loud.analogMode = .loudness
        XCTAssertEqual(loud.needs(allowsArtwork: true),
                       [.effetuneSpectrogram, .effetuneSpectrum, .stereoEnvelope, .loudness])
    }
}
