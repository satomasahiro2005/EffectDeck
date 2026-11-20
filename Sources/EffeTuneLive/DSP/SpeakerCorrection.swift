// Portable part of upstream speaker_distortion_correction.js. Measurements are
// made in EffeTune and imported here; identification never runs on the audio thread.
import Foundation
import CoreFoundation

enum ETSpeakerCorrection {
    static let type = "SpeakerDistortionCorrectionPlugin"
    static let frames = 1247
    static let channels = 16
    static let byteCount = 32 + channels * frames * 4

    enum ModelError: Error, LocalizedError {
        case invalid
        var errorDescription: String? {
            "Import a measurement JSON exported by EffeTune 2.19 or later that includes a speaker distortion model."
        }
    }

    struct Channel: Codable, Sendable {
        var index: Int
        var label: String
        var weights: [String: [Float]]
        var on: [String: Bool]
        var reason: [String: String]
        var odd: Odd?
    }

    struct Odd: Codable, Sendable {
        var weights: [Float]
        var bounds: [Float]
        var on: [String: Bool]
        var fitReason: String?
    }

    struct Model: Codable, Sendable {
        var id: String
        var name: String
        var recommendedLength: String
        var checkedVolume: Double?
        var checkedAt: Double? = nil
        var channels: [Channel]

        var selectionParameters: [String: Any] {
            ["ms": id, "mn": name, "fl": recommendedLength == "long" ? "Long" : "Short",
             "cn": 0, "co": 0, "cn3": 0, "co3": 0, "mr": 0,
             "dc": checkedAt ?? 0, "dvs": checkedVolume == nil ? "" : "check"]
        }

        var usesSurround: Bool {
            channels.contains { channel in
                guard channel.index >= 2 else { return false }
                let fitted = ["short", "long"].contains {
                    channel.weights[$0] != nil && !["belowLimit", "noFit"].contains(channel.reason[$0] ?? "")
                }
                return fitted || (channel.odd?.fitReason == nil && channel.odd?.on["alone"] == true)
            }
        }
    }

    // The official measurement export wraps Float32Array bytes as {f32: base64}.
    static func importMeasurement(_ data: Data) throws -> Model {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["speakerModel"] as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty,
              let entries = model["channels"] as? [[String: Any]], !entries.isEmpty, entries.count <= channels,
              let length = model["recommendedLength"] as? String, ["short", "long"].contains(length) else {
            throw ModelError.invalid
        }
        var decoded: [Channel] = []
        for entry in entries {
            guard let number = entry["index"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let index = Int(exactly: number.doubleValue), (0..<channels).contains(index),
                  decoded.last.map({ $0.index < index }) ?? true,
                  let weights = entry["weights"] as? [String: Any],
                  let on = entry["on"] as? [String: Bool],
                  let reasons = entry["reason"] as? [String: Any] else { throw ModelError.invalid }
            var even: [String: [Float]] = [:]
            var reason: [String: String] = [:]
            for key in ["short", "long"] {
                guard on[key] != nil, let value = weights[key], let why = reasons[key] else { throw ModelError.invalid }
                if !(value is NSNull) { even[key] = try unpack(value, count: 1182, bound: false) }
                if let text = why as? String { reason[key] = text }
                else if !(why is NSNull) { throw ModelError.invalid }
            }
            var odd: Odd?
            if let block = entry["odd"] as? [String: Any], let weights = block["weights"], !(weights is NSNull) {
                guard let bounds = block["bounds"], let enabled = block["on"] as? [String: Bool],
                      ["short", "long", "alone"].allSatisfy({ enabled[$0] != nil }) else { throw ModelError.invalid }
                odd = Odd(weights: try unpack(weights, count: 32, bound: false),
                          bounds: try unpack(bounds, count: 32, bound: true),
                          on: enabled, fitReason: block["fitReason"] as? String)
            }
            decoded.append(Channel(index: index, label: entry["label"] as? String ?? "Ch \(index + 1)",
                                   weights: even, on: on, reason: reason, odd: odd))
        }
        let original = object["id"] as? String ?? ""
        let safeID = !original.isEmpty && original.count <= 128
            && original.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }
        var checkedVolume: Double?
        let check = model["lastCheck"] as? [String: Any]
        let checkedAt = (check?["at"] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let check,
           let outcome = check["outcome"] as? String, ["same", "lower", "louder"].contains(outcome),
           let volume = check["dv"] as? Double, volume.isFinite {
            checkedVolume = min(0, max(-24, (volume * 2).rounded() / 2))
        }
        return Model(id: safeID ? original : UUID().uuidString.lowercased(), name: name,
                     recommendedLength: length, checkedVolume: checkedVolume, checkedAt: checkedAt, channels: decoded)
    }

    private static func unpack(_ value: Any, count: Int, bound: Bool) throws -> [Float] {
        guard let tagged = value as? [String: Any], tagged.count == 1,
              let encoded = tagged["f32"] as? String, let bytes = Data(base64Encoded: encoded),
              bytes.count == count * 4 else { throw ModelError.invalid }
        let values: [Float] = bytes.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        guard values.allSatisfy({ $0.isFinite && (bound ? $0 > 0 : abs($0) < 1000) }) else { throw ModelError.invalid }
        return values
    }

    struct Settings: Sendable {
        var length: String
        var cn: Int
        var co: Int
        var cn3: Int
        var co3: Int
        init(_ design: [String: String]) {
            length = design["fl"] == "Long" ? "long" : "short"
            func mask(_ key: String) -> Int {
                guard let value = ETDesignParam.number(design, key), let n = Int(exactly: value),
                      (0...65535).contains(n) else { return 0 }
                return n
            }
            cn = mask("cn"); co = mask("co"); cn3 = mask("cn3"); co3 = mask("co3")
        }
        func position(_ index: Int, odd: Bool) -> String {
            if ((odd ? co3 : co) >> index) & 1 != 0 { return "off" }
            return ((odd ? cn3 : cn) >> index) & 1 != 0 ? "on" : "auto"
        }
        func plays(_ channel: Channel) -> (even: Bool, odd: Bool) {
            let evenPosition = position(channel.index, odd: false)
            let hasFit = channel.weights[length] != nil && !["belowLimit", "noFit"].contains(channel.reason[length] ?? "")
            let even = hasFit && (evenPosition == "on" || (evenPosition == "auto" && channel.on[length] == true))
            guard let odd = channel.odd else { return (even, false) }
            let oddPosition = position(channel.index, odd: true)
            let enabled = oddPosition == "on" || (oddPosition == "auto" && odd.fitReason == nil
                && odd.on[even ? length : "alone"] == true)
            return (even, enabled && oddPosition != "off")
        }
    }

    static func payload(_ model: Model, settings: Settings, outputChannels: Int) throws -> [UInt8] {
        guard (1...channels).contains(outputChannels) else { throw ModelError.invalid }
        guard model.channels.allSatisfy({ (0..<channels).contains($0.index) }),
              Set(model.channels.map(\.index)).count == model.channels.count else { throw ModelError.invalid }
        var data = Array(repeating: [Float](repeating: 0, count: frames), count: channels)
        for i in 0..<channels { data[i][1182] = settings.length == "long" ? 1 : 0 }
        for channel in model.channels where channel.index < outputChannels {
            let active = settings.plays(channel)
            if active.even, let weights = channel.weights[settings.length] {
                guard weights.count == 1182, weights.allSatisfy({ $0.isFinite && abs($0) < 1000 }) else { throw ModelError.invalid }
                data[channel.index].replaceSubrange(0..<1182, with: weights)
            }
            if active.odd, let odd = channel.odd {
                guard odd.weights.count == 32, odd.bounds.count == 32,
                      odd.weights.allSatisfy({ $0.isFinite && abs($0) < 1000 }),
                      odd.bounds.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ModelError.invalid }
                data[channel.index].replaceSubrange(1183..<1215, with: odd.weights)
                data[channel.index].replaceSubrange(1215..<1247, with: odd.bounds)
            }
        }
        var bytes = try AssetUpload.makePayload(channels: data, sampleRate: 48000, topology: .independent)
        // These are model weights; upstream's format has no coefficient sample rate.
        bytes.replaceSubrange(12..<16, with: [0, 0, 0, 0])
        return bytes
    }

    static func selection(spec: Int8, outputChannels: Int) -> (first: Int, count: Int) {
        let first = spec >= 16 ? Int(spec - 16) * 2 : max(0, Int(spec))
        return (first, ETChannel.processedWidth(spec: spec, engineChannels: outputChannels))
    }

    static func routedValues(_ node: ETChainNode, outputChannels: Int) -> [Float] {
        var values = node.values
        let selected = selection(spec: node.channelSpec, outputChannels: outputChannels)
        for (key, value) in [("_scf", selected.first), ("_scc", selected.count)] {
            if let p = node.spec.params.first(where: { $0.key == key }), values.indices.contains(p.offset) {
                values[p.offset] = Float(value)
            }
        }
        return values
    }

    static func selectionValues(_ node: ETChainNode, model: Model) -> [Float] {
        var values = node.values
        for (key, value) in [("dv", Float(model.checkedVolume ?? 0)), ("md", Float(0))] {
            if let p = node.spec.params.first(where: { $0.key == key }), values.indices.contains(p.offset) {
                values[p.offset] = value
            }
        }
        return values
    }
}
