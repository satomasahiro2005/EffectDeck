import XCTest
import Foundation

final class Upstream219Tests: XCTestCase {
    func testCurrentCatalogAndSoundFontLayout() throws {
        XCTAssertEqual(ETUpstreamVersion, "0.19.0")
        XCTAssertEqual(ETUpstreamAppVersion, "2.19.0")
        XCTAssertEqual(ETCatalog.count, 117)
        XCTAssertEqual(ETCatalog.reduce(0) { $0 + $1.params.count }, 742)
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == "SoundFontPlayerPlugin" })
        XCTAssertEqual(spec.paramsHash, 0x25427170)
        XCTAssertEqual(spec.floatCount, 13)
        XCTAssertEqual(spec.params.sorted { $0.offset < $1.offset }.map(\.key),
                       ["mc", "pl", "og", "sq", "af", "pm", "pc", "sc", "rg", "rs", "rx", "tr", "mco"])
        XCTAssertEqual(spec.defaults, [0, 256, 0, 1, 1, -1, 0, 0, 1, 1, 1, 0, 0])
        for type in [ETHeadphoneEQ.type, ETSpeakerCorrection.type] {
            XCTAssertFalse(ETAutomation.isAutomatable(try XCTUnwrap(ETCatalog.first { $0.type == type })))
        }
    }

    private func contracts() throws -> [String: Any] {
        let url = try XCTUnwrap(TestResource.url("contracts", "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testResponseImportsMatchUpstream() throws {
        let cases = try XCTUnwrap(try contracts()["responses"] as? [[String: Any]])
        for entry in cases {
            let text = try XCTUnwrap(entry["text"] as? String)
            if let expected = entry["expected"] as? [String: Any] {
                let got = try ETHeadphoneEQ.parseResponse(text, target: entry["target"] as? Bool ?? false)
                // libm and V8 can fall on opposite sides of a half-tenth dB
                // after log interpolation; at those ties allow one stored quantum.
                let response = try XCTUnwrap(expected["response"] as? [Double])
                XCTAssertEqual(got.response.count, response.count)
                XCTAssertLessThanOrEqual(DesignersBGolden.maxAbsDiff(got.response, response), 0.100000000001)
                let target = expected["target"] as? [Double]
                XCTAssertEqual(got.target == nil, target == nil)
                if let a = got.target, let b = target {
                    XCTAssertLessThanOrEqual(DesignersBGolden.maxAbsDiff(a, b), 0.100000000001)
                }
            } else {
                XCTAssertThrowsError(try ETHeadphoneEQ.parseResponse(text))
            }
        }
    }

    func testCurvesSurviveSerializationWithoutStringifyingArrays() throws {
        let curve = (0..<241).map { Double($0) / 10 }
        let params: [String: Any] = ["mr": curve, "mt": curve, "mn": "Headphones", "tn": "Target",
                                     "ca": -100, "ah": true, "tp": 8192, "pm": "lin", "ta0": "ls", "qa0": 10]
        let design = ETDesignParam.read(params, type: ETHeadphoneEQ.type)
        var written: [String: Any] = [:]
        ETDesignParam.write(design, type: ETHeadphoneEQ.type, into: &written)
        XCTAssertEqual(written["mr"] as? [Double], curve)
        XCTAssertEqual(written["mt"] as? [Double], curve)
        XCTAssertEqual(written["mn"] as? String, "Headphones")
        let settings = ETHeadphoneEQ.Settings(design, sampleRate: 44100)
        XCTAssertTrue(settings.hasCorrection)
        XCTAssertEqual(settings.config.correctionAmount, -1)
        XCTAssertEqual(settings.config.taps, 8192)
        XCTAssertEqual(settings.config.phase, .linear)
        XCTAssertEqual(settings.config.bands[0].q, 2)
        XCTAssertTrue(settings.config.limitPeakGain)
        XCTAssertNil(ETHeadphoneEQ.validCurve(Array(repeating: true, count: 241)))
        XCTAssertNil(ETHeadphoneEQ.validCurve(Array(repeating: 0, count: 240)))
        XCTAssertNil(ETHeadphoneEQ.validCurve(Array(repeating: Double.nan, count: 241)))
        XCTAssertEqual(ETHeadphoneEQ.validCurve([]), [])
    }

    func testAutoEQIndexAndGitHubURLs() throws {
        let index = """
        - [Model (2026)](./oratory1990/over-ear/Model%20(2026)) by oratory1990 on Rig
        - [Model (2026)](./duplicate) by oratory1990 on Rig
        - [Excluded](./crinacle/Excluded) by crinacle
        """
        let entries = ETHeadphoneEQ.parseAutoEQIndex(index)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].label, "Model (2026) — oratory1990 on Rig")
        XCTAssertTrue(entries[0].url.absoluteString.hasSuffix("/Model%20%282026%29.csv"))
        let folder = URL(string: "https://github.com/jaakkopasanen/AutoEq/tree/master/results/Model%20A")!
        XCTAssertEqual(ETHeadphoneEQ.rawURL(folder).absoluteString,
                       "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/Model%20A/Model%20A.csv")
    }

    func testSpeakerAssetsMatchUpstreamByteForByte() throws {
        let fixture = try contracts()
        let measurement = try XCTUnwrap(fixture["measurement"] as? [String: Any])
        let model = try ETSpeakerCorrection.importMeasurement(JSONSerialization.data(withJSONObject: measurement))
        XCTAssertTrue(model.usesSurround)
        XCTAssertEqual(model.selectionParameters["dvs"] as? String, "")
        XCTAssertEqual(model.selectionParameters["dc"] as? Double, 0)
        let cases = try XCTUnwrap(fixture["speakerAssets"] as? [[String: Any]])
        for entry in cases {
            let settings = ETSpeakerCorrection.Settings(try XCTUnwrap(entry["settings"] as? [String: String]))
            let width = try XCTUnwrap(entry["outputChannels"] as? Int)
            let expected = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(entry["payload"] as? String)))
            let payload = try ETSpeakerCorrection.payload(model, settings: settings, outputChannels: width)
            XCTAssertEqual(Data(payload), expected)
            XCTAssertEqual(payload.count, ETSpeakerCorrection.byteCount)
            let info = AssetUpload.BeginInfo(headBlock: 0, processingChannels: UInt32(width),
                                             footprintBytes: UInt32(payload.count))
            let request = try AssetUpload.beginRequest(engine: 1, instance: 1, payload: payload, info: info)
            XCTAssertEqual(request.channels, 16)
            XCTAssertEqual(request.frames, 1247)
        }
    }

    func testSpeakerRoutingTracksPhysicalChannelsAndStaysOutOfPresets() throws {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == ETSpeakerCorrection.type })
        let first = try XCTUnwrap(spec.params.first { $0.key == "_scf" })
        let count = try XCTUnwrap(spec.params.first { $0.key == "_scc" })
        XCTAssertTrue(first.runtimeOnly); XCTAssertTrue(count.runtimeOnly)
        for (channel, offset, width): (Int8, Int, Int) in [(-2, 0, 8), (-1, 0, 2), (1, 1, 1), (17, 2, 2), (18, 4, 2), (23, 14, 0)] {
            var node = ETChainNode(spec: spec, values: spec.defaults)
            node.channelSpec = channel
            let values = ETSpeakerCorrection.routedValues(node, outputChannels: 8)
            XCTAssertEqual(values[first.offset], Float(offset))
            XCTAssertEqual(values[count.offset], Float(width))
        }
        XCTAssertThrowsError(try ETSpeakerCorrection.importMeasurement(Data("{}".utf8)))
    }

    func testInvalidSpeakerWeightsAreRejectedBeforeStaging() throws {
        var measurement = try XCTUnwrap(try contracts()["measurement"] as? [String: Any])
        var model = try XCTUnwrap(measurement["speakerModel"] as? [String: Any])
        var channels = try XCTUnwrap(model["channels"] as? [[String: Any]])
        var weights = try XCTUnwrap(channels[0]["weights"] as? [String: Any])
        weights["short"] = ["f32": Data([0, 0, 0, 0]).base64EncodedString()]
        channels[0]["weights"] = weights
        model["channels"] = channels; measurement["speakerModel"] = model
        XCTAssertThrowsError(try ETSpeakerCorrection.importMeasurement(JSONSerialization.data(withJSONObject: measurement)))

        measurement = try XCTUnwrap(try contracts()["measurement"] as? [String: Any])
        model = try XCTUnwrap(measurement["speakerModel"] as? [String: Any])
        channels = try XCTUnwrap(model["channels"] as? [[String: Any]])
        var odd = try XCTUnwrap(channels[0]["odd"] as? [String: Any])
        odd["bounds"] = ["f32": Data(repeating: 0, count: 32 * 4).base64EncodedString()]
        channels[0]["odd"] = odd
        model["channels"] = channels; measurement["speakerModel"] = model
        XCTAssertThrowsError(try ETSpeakerCorrection.importMeasurement(JSONSerialization.data(withJSONObject: measurement)))
    }

    func testSelectingMeasurementResetsModeAndAdoptsOnlyItsOwnAmplifierCheck() throws {
        let fixture = try contracts()
        var measurement = try XCTUnwrap(fixture["measurement"] as? [String: Any])
        var model = try ETSpeakerCorrection.importMeasurement(JSONSerialization.data(withJSONObject: measurement))
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == ETSpeakerCorrection.type })
        let dv = try XCTUnwrap(spec.params.first { $0.key == "dv" }).offset
        let md = try XCTUnwrap(spec.params.first { $0.key == "md" }).offset
        var node = ETChainNode(spec: spec, values: spec.defaults)
        node.values[dv] = -12; node.values[md] = 1
        var selected = ETSpeakerCorrection.selectionValues(node, model: model)
        XCTAssertEqual(selected[dv], 0); XCTAssertEqual(selected[md], 0)

        var raw = try XCTUnwrap(measurement["speakerModel"] as? [String: Any])
        raw["lastCheck"] = ["at": 1234, "outcome": "lower", "dv": -6.0] as [String: Any]
        measurement["speakerModel"] = raw
        model = try ETSpeakerCorrection.importMeasurement(JSONSerialization.data(withJSONObject: measurement))
        selected = ETSpeakerCorrection.selectionValues(node, model: model)
        XCTAssertEqual(selected[dv], -6); XCTAssertEqual(selected[md], 0)
        XCTAssertEqual(model.selectionParameters["dvs"] as? String, "check")
        XCTAssertEqual(model.selectionParameters["dc"] as? Double, 1234)
    }

    func testPEQMasterGainIsWeightedOnceAcrossCompanions() throws {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == "FifteenBandPEQPlugin" })
        let layout = try XCTUnwrap(ETPEQBlend.Layout(spec))
        let mg = try XCTUnwrap(layout.masterGain)
        var a = spec.defaults, b = spec.defaults
        a[mg] = -12; b[mg] = 4
        let automation = try XCTUnwrap(ETAutomation(source: .outputVolume,
            keyframes: [.init(position: 0, values: a), .init(position: 100, values: b)], spec: spec))
        let voices = ETPEQBlend.voices(automation, at: 25)
        let lower = ETPEQBlend.values(voices.lower, in: automation, layout: layout)
        let upper = ETPEQBlend.values(voices.upper, in: automation, layout: layout)
        XCTAssertEqual(lower[mg] + upper[mg], -8)
        XCTAssertEqual(ETPEQBlend.silenced(a, layout: layout)[mg], 0)
        XCTAssertFalse(ETPEQBlend.isSilent(a, layout: layout))
        XCTAssertEqual(ETPEQTextImport.parse("Preamp: -6.0 dB").masterGain, -6)
        XCTAssertEqual(ETPEQTextImport.parse("PREAMP: +100 dB").masterGain, 20)
        XCTAssertNil(ETPEQTextImport.parse("Preamp: nope dB").masterGain)
    }
}
