// Headphone EQ's portable curves and settings. Matches upstream headphone_eq.js;
// FIR synthesis uses the same Room EQ designer as upstream.
import Foundation
import CoreFoundation

enum ETHeadphoneEQ {
    static let type = "HeadphoneEQPlugin"
    static let grid = (0...240).map { 20 * pow(2, Double($0) / 240 * log2(1000)) }

    enum ImportError: Error, LocalizedError {
        case invalidResponse
        var errorDescription: String? {
            "Use an AutoEQ CSV or a text file with frequency and level columns spanning at least one octave."
        }
    }

    static func validCurve(_ value: Any?) -> [Double]? {
        guard let values = value as? [Any], values.isEmpty || values.count == grid.count else { return nil }
        var out: [Double] = []
        for value in values {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            out.append(number.doubleValue)
        }
        return out
    }

    static func curve(_ raw: String) -> [Double]? {
        guard let bytes = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: bytes) else { return nil }
        return validCurve(value)
    }

    static func encodeCurve(_ curve: [Double]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: curve) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    struct Response {
        var response: [Double]
        var target: [Double]?
    }

    static func parseResponse(_ text: String, target: Bool = false) throws -> Response {
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { throw ImportError.invalidResponse }
        func cells(_ line: String) -> [String] {
            line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\s*[,;\\t]\\s*|\\s+", with: "\u{1F}", options: .regularExpression)
                .components(separatedBy: "\u{1F}")
        }
        let header = cells(first).map { $0.lowercased() }
        let hasHeader = header.contains("frequency")
        let rows = (hasHeader ? Array(lines.dropFirst()) : lines).map(cells)
        let frequency = hasHeader ? header.firstIndex(of: "frequency")! : 0
        func read(_ column: Int?) throws -> [Double] {
            guard let column else { throw ImportError.invalidResponse }
            var points: [RoomEQResponsePoint] = []
            for row in rows where row.indices.contains(frequency) && row.indices.contains(column) {
                if let hz = Double(row[frequency]), let db = Double(row[column]),
                   hz > 0, hz.isFinite, db.isFinite {
                    points.append(RoomEQResponsePoint(frequency: hz, decibels: db))
                }
            }
            points.sort { $0.frequency < $1.frequency }
            var unique: [RoomEQResponsePoint] = []
            for point in points where unique.last?.frequency != point.frequency { unique.append(point) }
            guard unique.count >= 2, unique.last!.frequency / unique[0].frequency >= 2 else {
                throw ImportError.invalidResponse
            }
            return RoomEQDesigner.interpolateLogResponse(response: unique, frequencies: grid)
                .map { floor($0 * 10 + 0.5) / 10 + 0 }
        }
        if !hasHeader { return Response(response: try read(1), target: nil) }
        if target {
            return Response(response: try read(header.firstIndex(of: "target") ?? header.firstIndex(of: "raw")), target: nil)
        }
        return Response(response: try read(header.firstIndex(of: "raw")),
                        target: try header.firstIndex(of: "target").map { try read($0) })
    }

    struct AutoEQEntry: Identifiable, Equatable {
        let label: String
        let name: String
        let url: URL
        var id: String { url.absoluteString }
    }

    static let autoEQRoot = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results"
    static let autoEQIndexURL = URL(string: autoEQRoot + "/INDEX.md")!

    static func parseAutoEQIndex(_ text: String) -> [AutoEQEntry] {
        let expression = try! NSRegularExpression(pattern: #"^- \[(.+?)\]\(\./(.+)\) by (.+?)(?: on (.+))?$"#)
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            func group(_ i: Int) -> String { match.range(at: i).location == NSNotFound ? "" : ns.substring(with: match.range(at: i)) }
            let model = group(1), path = group(2), source = group(3), rig = group(4)
            guard source != "crinacle" else { return nil }
            let label = model + " — " + source + (rig.isEmpty ? "" : " on " + rig)
            guard seen.insert(label).inserted,
                  let encoded = model.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let url = URL(string: autoEQRoot + "/" + path + "/" + encoded + ".csv") else { return nil }
            return AutoEQEntry(label: label, name: model + " (" + source + ")", url: url)
        }
    }

    static func rawURL(_ url: URL) -> URL {
        guard url.host?.lowercased() == "github.com" else { return url }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, ["blob", "tree"].contains(parts[2]) else { return url }
        let path = ([parts[0], parts[1]] + Array(parts.dropFirst(3))).joined(separator: "/")
        let suffix = parts[2] == "tree" ? "/" + parts.last! + ".csv" : ""
        return URL(string: "https://raw.githubusercontent.com/" + path + suffix) ?? url
    }

    struct Settings: Sendable, Equatable {
        var config: RoomEQConfig
        var measurement: [Double]
        var target: [Double]
        var measurementName: String
        var targetName: String
        var hasCorrection: Bool { !measurement.isEmpty && !target.isEmpty }

        init(_ design: [String: String], sampleRate: Int) {
            var c = RoomEQConfig()
            c.sampleRate = sampleRate
            c.lowFrequency = 20
            c.highFrequency = ETDesignParam.finite(design, "uf", 1000, 20000, previous: 10000)
            c.maxBoostDb = ETDesignParam.finite(design, "mb", 0, 18, previous: 6)
            c.smoothing = ETDesignParam.finite(design, "sm", 0.02, 1, previous: 0.17)
            c.correctionAmount = ETDesignParam.finite(design, "ca", -100, 100, previous: 100) / 100
            c.limitPeakGain = ETDesignParam.flag(design, "ah") ?? true
            c.phase = design["pm"] == "lin" ? .linear : .minimum
            c.taps = ETDesignParam.choice(design, "tp", in: RoomEQConfig.allowedTaps) ?? 32768
            c.bands = RoomEQBand.defaults.enumerated().map { i, initial in
                var b = initial
                b.enabled = ETDesignParam.flag(design, "ea\(i)") ?? true
                b.type = RoomEQBandType(rawValue: design["ta\(i)"] ?? "") ?? .peaking
                b.frequency = ETDesignParam.finite(design, "fa\(i)", 20, 20000, previous: b.frequency)
                b.gain = ETDesignParam.finite(design, "ga\(i)", -20, 20, previous: 0)
                b.q = ETDesignParam.finite(design, "qa\(i)", 0.1, b.type == .peaking ? 10 : 2, previous: 1)
                return b
            }
            config = c
            measurement = design["mr"].flatMap(ETHeadphoneEQ.curve) ?? []
            target = design["mt"].flatMap(ETHeadphoneEQ.curve) ?? []
            measurementName = design["mn"] ?? ""
            targetName = design["tn"] ?? ""
        }

        func design() -> RoomEQDesign {
            let source: RoomEQSource? = hasCorrection ? RoomEQSource(frequencyResponse: zip(grid, zip(measurement, target)).map {
                RoomEQResponsePoint(frequency: $0.0, decibels: $0.1.0 - $0.1.1)
            }) : nil
            return RoomEQDesigner.design(config: config, sources: [source])
        }
    }
}
