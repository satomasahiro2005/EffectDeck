//  AnalogMeterModel.swift
//  Analog Meter（AnalogMeterPlugin、2.12.0 で増えた）の値の計算。画面（AnalogMeterView）は描くだけ。
//
//  **Foundation だけ。**ETFrame と数だけで済むので、実機もシミュレータの描画もなしで試せる
//  （Tests/Unit/AnalogMeterTests.swift）。
//
//  上流は plugins/analyzer/analog_meter.js。針の目盛りへの写し方（analogMeterScale）、
//  ピークホールド（updateAnalogMeterHold）、枠の読み（parseAnalogMeterFrame）をそのまま写した。
//
//  テレメトリ: ETFrameType.analogMeter = 27、formatVersion 1
//  （dsp/plugins/analyzer/analog_meter/kernel.cpp:21-22 の kTelemetryType / kTelemetryVersion、
//    analog_meter.js:1-2）
//
//  ペイロードの並び（analog_meter.js:190-224、dsp/bindings/js/src/telemetry.js:409-461）:
//      0                u8  mode          0..6（ETAnalogMeter.modes の添字。6 = Custom は 2.14.0）
//      1                u8  channelCount  1..16
//      2                u16 flags         bit0 = Integrated が有効、bit1 = LRA が有効（Loudness の枠だけ）
//      4 + 8*ch         f32 needleDb      針の dBFS（バリスティクス済み）
//      8 + 8*ch         f32 maxDb         そのチャンネルの最大（ピークホールド用）
//      4 + 8*n          f32 × 6           Loudness のときだけ。M / S / I / LRA / max True Peak / 積算の秒
//  長さは 4 + 8n（Loudness は + 24）ちょうど。

import Foundation

enum ETAnalogMeter {

    // MARK: 定数（analog_meter.js:1-24）

    static let modes = ["VU", "PPM", "RMS", "Sample Peak", "True Peak", "Loudness", "Custom"]
    static let loudnessMode = 5
    static let customMode = 6
    static let ppmScales = ["DIN", "BBC", "dB"]
    /// Custom の検波（DSP の de）と目盛り（表示の dc）。2.14.0 の ANALOG_METER_DETECTORS / DIALS。
    static let detectors = ["Average Rectified", "RMS", "Sample Peak", "True Peak"]
    static let dials = ["VU", "DIN", "BBC", "dB", "dBFS"]
    static let ppmBBC = 1
    static let maxChannels = 16
    static let maxColumns = 4
    static let mobileColumns = 2
    /// -∞ とみなす下限（読み値の "-∞" と、ピークホールドの線を引く下限）。
    static let silenceDB: Double = -200
    /// ライブラリのデコーダが枠を捨てる下限（telemetry.js の ANALOG_METER_MIN_DB）。
    static let minimumDB: Double = -240
    /// 針の振れ角の片側（度）。
    static let arcDegrees: Double = 50

    // MARK: 設定（DSP の it / at / rt 以外。上流が getParameters に書く表示の設定）

    /// 表示の設定。**上流の既定は ANALOG_METER_DEFAULTS（analog_meter.js:15-17）。**
    struct Settings: Equatable {
        var mode = 0
        var reference: Double = -14     // rl
        var range: Double = 40          // rg
        var ppmScale = 0                // sc
        var peakHold: Double = 1        // ph
        var needle = 0                  // ln（0 = Momentary、1 = Short-term）
        var target: Double = -23        // tg
        var loudnessScale = 0           // ls（0 = EBU +9、1 = EBU +18）
        var detector = 0                // de（DSP。Custom の検波、detectors の添字）
        var dial = 0                    // dc（Custom の目盛り、dials の添字）

        /// 上流の setParameters と同じ寄せ方（analog_meter.js:326-336）。
        /// 数でないものは前の値のまま、範囲の外は端、列挙は決まった値だけ。
        static func clamped(_ raw: Double, _ low: Double, _ high: Double, previous: Double) -> Double {
            raw.isFinite ? min(max(raw, low), high) : previous
        }
    }

    /// 行ごとに、どのモードで効くか（ANALOG_METER_ACTIVE_MODES、analog_meter.js:46-57）。
    /// 効かない行は上流では隠れる（syncControlStates、:415-421）。
    private static let activeModes: [String: [String]] = [
        "it": ["RMS", "Custom"],
        "at": ["PPM"],
        "rt": ["PPM", "Sample Peak", "True Peak", "Custom"],
        "rl": ["VU", "PPM", "RMS", "Custom"],
        "rg": ["PPM", "RMS", "Sample Peak", "True Peak", "Custom"],
        "sc": ["PPM"],
        "ph": ["PPM", "RMS", "Sample Peak", "True Peak", "Custom"],
        "ln": ["Loudness"],
        "tg": ["Loudness"],
        "ls": ["Loudness"],
        "de": ["Custom"], "nr": ["Custom"], "os": ["Custom"], "dc": ["Custom"],
    ]

    /// その行がいまのモードで効くか（isAnalogMeterParameterActive）。
    /// Custom では検波と目盛りの選び方で、効かない行がある（RMS 以外の Integration など）。
    static func isActive(_ key: String, settings: Settings) -> Bool {
        let mode = modes.indices.contains(settings.mode) ? modes[settings.mode] : modes[0]
        if mode == "Custom" {
            let detector = detectors.indices.contains(settings.detector) ? detectors[settings.detector] : detectors[0]
            switch key {
            case "it": return detector == "RMS"
            case "rt": return detector == "Sample Peak" || detector == "True Peak"
            case "rl": return settings.dial != 4
            case "rg": return [1, 3, 4].contains(settings.dial)
            default: break
            }
        }
        // BBC の針は 1〜7 の固定の目盛りなので、Range は何も決めない。
        if key == "rg" && mode == "PPM" && settings.ppmScale == ppmBBC { return false }
        return activeModes[key]?.contains(mode) ?? false
    }

    /// 行を出すか（isAnalogMeterParameterVisible）。Custom は効く場面のある行を全部出したまま、
    /// 検波と目盛りの選び方で効かない行を薄くする（isActive が偽）。ほかのモードは効く行だけ出す。
    static func isVisible(_ key: String, settings: Settings) -> Bool {
        if settings.mode == customMode { return activeModes[key]?.contains("Custom") ?? false }
        return isActive(key, settings: settings)
    }

    /// ピークホールドを持つモード（ANALOG_METER_ACTIVE_MODES.ph）。
    static func holdsPeak(mode: Int) -> Bool {
        modes.indices.contains(mode) && activeModes["ph"]!.contains(modes[mode])
    }

    // MARK: 目盛り（analogMeterScale、analog_meter.js:75-165）

    struct Tick: Equatable {
        var value: Double
        var label: String
    }

    struct Scale {
        var unit: String
        var min: Double
        var max: Double
        var reference: Double?
        var redFrom: Double?
        /// dB の読みを、この針の目盛りの値にする。
        var toLabel: (Double) -> Double
        /// VU だけ電圧に比例（線形でない）。
        var positionOverride: ((Double) -> Double)?
        var ticks: [Tick]
        var format: (Double) -> String

        /// 目盛りの値 → 針の位置（0〜1。範囲の外は端）。
        func valuePosition(_ value: Double) -> Double {
            let raw = positionOverride?(value) ?? (value - min) / (max - min)
            return raw < 0 ? 0 : (raw > 1 ? 1 : raw)
        }

        func dbPosition(_ db: Double) -> Double { valuePosition(toLabel(db)) }

        func readout(_ db: Double) -> String {
            db <= ETAnalogMeter.silenceDB ? "-∞" : format(toLabel(db))
        }
    }

    /// JS の String(number) に当たる。整数はそのまま、-0 は 0。
    static func jsString(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        return String(v)
    }

    /// 符号つきの 1 桁（analogMeterSigned、:67-69）。
    static func signed(_ v: Double) -> String {
        (v > 0 ? "+" : "") + String(format: "%.1f", v)
    }

    /// analogMeterLinearTicks（:65-73）。
    static func linearTicks(_ min: Double, _ max: Double, _ step: Double,
                            extra: [Double] = [], unlabeled: [Double] = []) -> [Tick] {
        var values = Set(extra)
        var value = (min / step).rounded(.up) * step
        while value <= max + 1e-9 {
            values.insert(value)
            value += step
        }
        return values.filter { $0 >= min - 1e-9 && $0 <= max + 1e-9 }
            .sorted()
            .map { Tick(value: $0, label: unlabeled.contains($0) ? "" : jsString($0)) }
    }

    static func scale(mode: String, settings s: Settings) -> Scale {
        let rl = s.reference, rg = s.range
        // 目盛りの形。Custom は Dial で選ぶ（dB は RMS の目盛り、dBFS は検波が True Peak なら dBTP）。
        var style = mode == "PPM" ? "PPM \(ppmScales[ppmScales.indices.contains(s.ppmScale) ? s.ppmScale : 0])" : mode
        if mode == "Custom" {
            let peak = detectors.indices.contains(s.detector) && detectors[s.detector] == "True Peak"
                ? "True Peak" : "Sample Peak"
            let styles = ["VU", "PPM DIN", "PPM BBC", "RMS", peak]
            style = styles[styles.indices.contains(s.dial) ? s.dial : 0]
        }
        if style == "VU" {
            let full = pow(10, 3.0 / 20)
            return Scale(
                unit: "VU", min: -20, max: 3, reference: 0, redFrom: 0,
                toLabel: { $0 - rl },
                // VU の針は電圧に比例する。
                positionOverride: { pow(10, $0 / 20) / full },
                ticks: [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3].map {
                    Tick(value: $0, label: ($0 == -1 || $0 == 1) ? "" : jsString($0))
                },
                format: { "\(signed($0)) VU" })
        }
        if style == "PPM dB" {
            return Scale(
                unit: "dB", min: -rg, max: 5, reference: 0, redFrom: 0,
                toLabel: { $0 - rl }, positionOverride: nil,
                ticks: linearTicks(-rg, 5, rg > 30 ? 10 : 5, extra: [0, 5]),
                format: { "\(signed($0)) dB" })
        }
        if style == "PPM DIN" {
            return Scale(
                unit: "dB", min: -rg, max: 5, reference: -9, redFrom: 0,
                toLabel: { $0 - (rl + 9) }, positionOverride: nil,
                ticks: linearTicks(-rg, 5, 10, extra: [-9, -5, 0, 5], unlabeled: [-10]),
                format: { "\(signed($0)) dB" })
        }
        if style == "PPM BBC" {
            return Scale(
                unit: "", min: 1, max: 7, reference: 4, redFrom: 6,
                // 目盛り 2〜7 は 4 dB おき、1 は 2 の 6 dB 下。
                toLabel: { db in
                    let relative = db - rl
                    return relative >= -8 ? 4 + relative / 4 : 2 + (relative + 8) / 6
                },
                positionOverride: nil,
                ticks: (1...7).map { Tick(value: Double($0), label: String($0)) },
                format: { "Mark \($0 < 0 ? "0.0" : String(format: "%.1f", $0))" })
        }
        if style == "RMS" {
            return Scale(
                unit: "dB", min: -rg, max: -rl, reference: 0,
                redFrom: nil,
                toLabel: { $0 - rl }, positionOverride: nil,
                ticks: linearTicks(-rg, -rl, 10, extra: [0]),
                format: { "\(signed($0)) dB" })
        }
        if style == "Sample Peak" || style == "True Peak" {
            let unit = style == "True Peak" ? "dBTP" : "dBFS"
            return Scale(
                unit: unit, min: -rg, max: 0, reference: nil, redFrom: nil,
                toLabel: { $0 }, positionOverride: nil,
                ticks: linearTicks(-rg, 0, rg > 30 ? 10 : 5),
                format: { "\(signed($0)) \(unit)" })
        }
        // Loudness。Target を基準に目盛りを数える（隣の目盛りとぶつからないように）。
        let wide = s.loudnessScale == 1
        let tg = s.target
        let low: Double = wide ? -36 : -18
        let high: Double = wide ? 18 : 9
        return Scale(
            unit: "LUFS", min: tg + low, max: tg + high, reference: tg, redFrom: nil,
            toLabel: { $0 }, positionOverride: nil,
            ticks: linearTicks(low, high, wide ? 6 : 3).map {
                Tick(value: $0.value + tg, label: jsString($0.value + tg))
            },
            format: { String(format: "%.1f LUFS", $0) })
    }

    /// 目盛りが混むとき、基準から数えて 1 つおきに残す（analogMeterSparseLabels、:168-172）。
    static func sparseLabels(_ scale: Scale) -> Set<Double> {
        let labeled = scale.ticks.filter { !$0.label.isEmpty }
        let target = scale.reference ?? 0
        let anchor = max(0, labeled.firstIndex { $0.value == target } ?? 0)
        var kept = Set<Double>()
        for (index, tick) in labeled.enumerated() where (index - anchor) % 2 == 0 {
            kept.insert(tick.value)
        }
        return kept
    }

    // MARK: 並べ方（analogMeterGrid / analogMeterAspect、:174-186）

    struct Grid: Equatable {
        var cells: Int
        var columns: Int
        var rows: Int

        /// 針 1 つぶんを 4:3 に保つ。
        var aspect: Double { Double(columns * 4) / Double(rows * 3) }
    }

    /// 最後の行に空きの枠があるか（Loudness の針が 3 つで 2 列のとき、4 つ目の枠）。
    /// 統計の表（statRows）をそこへ置く。
    static func hasEmptySlot(_ grid: Grid) -> Bool { grid.cells < grid.columns * grid.rows }

    static func grid(cells: Int, maxColumns: Int = ETAnalogMeter.maxColumns) -> Grid {
        let n = cells < 1 ? 1 : cells
        let columns = n < maxColumns ? n : maxColumns
        return Grid(cells: n, columns: columns, rows: (n + columns - 1) / columns)
    }

    // MARK: 枠

    struct Channel: Equatable {
        var needleDB: Double
        var maxDB: Double
    }

    struct Program: Equatable {
        var momentary: Double
        var shortTerm: Double
        var integrated: Double
        var lra: Double
        var maxTruePeak: Double
        var integratedSeconds: Double
    }

    struct Reading: Equatable {
        var mode: Int
        var channelCount: Int
        var integratedValid: Bool
        var lraValid: Bool
        var channels: [Channel]
        var program: Program?
        var sequence: UInt32
    }

    /// 枠を読む（parseAnalogMeterFrame と decodeAnalogMeter の両方の門）。読めなければ nil。
    static func parse(_ frame: ETFrame?) -> Reading? {
        guard let frame, frame.type == ETFrameType.analogMeter.rawValue, frame.version == 1 else {
            return nil
        }
        let p = ETPayload(frame)
        guard p.count >= 4, let modeByte = p.u8(at: 0), let countByte = p.u8(at: 1),
              let flags = p.u16(at: 2) else { return nil }
        let mode = Int(modeByte), count = Int(countByte)
        let loudness = mode == loudnessMode
        guard mode < modes.count, count >= 1, count <= maxChannels,
              flags & ~(loudness ? 3 : 0) == 0,
              p.count == 4 + 8 * count + (loudness ? 24 : 0) else { return nil }

        func level(_ offset: Int) -> Double? {
            guard let v = p.f32(at: offset), v.isFinite, Double(v) >= minimumDB else { return nil }
            return Double(v)
        }
        var channels: [Channel] = []
        channels.reserveCapacity(count)
        for ch in 0..<count {
            guard let needle = level(4 + 8 * ch), let peak = level(8 + 8 * ch) else { return nil }
            channels.append(Channel(needleDB: needle, maxDB: peak))
        }
        let integratedValid = flags & 1 != 0
        let lraValid = flags & 2 != 0
        var program: Program?
        if loudness {
            let base = 4 + 8 * count
            guard let m = level(base), let s = level(base + 4), let tp = level(base + 16),
                  let integrated = p.f32(at: base + 8), let lra = p.f32(at: base + 12),
                  let seconds = p.f32(at: base + 20),
                  seconds.isFinite, seconds >= 0 else { return nil }
            // 無効の間は 0 で来る（telemetry.js:446-452）。有効なら範囲を見る。
            if integratedValid {
                guard integrated.isFinite, Double(integrated) >= minimumDB else { return nil }
            } else if integrated != 0 { return nil }
            if lraValid {
                guard lra.isFinite, lra >= 0 else { return nil }
            } else if lra != 0 { return nil }
            program = Program(momentary: m, shortTerm: s, integrated: Double(integrated),
                              lra: Double(lra), maxTruePeak: tp, integratedSeconds: Double(seconds))
        }
        return Reading(mode: mode, channelCount: count, integratedValid: integratedValid,
                       lraValid: lraValid, channels: channels, program: program,
                       sequence: frame.sequence)
    }

    // MARK: ピークホールド（updateAnalogMeterHold / isAnalogMeterOverLit、:174-196）

    struct Hold: Equatable {
        var db: Double = .nan
        var time: Double = 0
        var overTime: Double?
    }

    /// 最高の読みを holdSeconds だけ持ち、過ぎたら検出器に付いていく。
    /// 0 dBFS を越えた時刻は Peak Hold が 0 でも覚える（ランプのため）。
    static func updateHold(_ hold: Hold, db: Double, now: Double, holdSeconds: Double) -> Hold {
        var next = hold
        if !(holdSeconds > 0) || !hold.db.isFinite || db >= hold.db
            || now - hold.time >= holdSeconds {
            next.db = db
            next.time = now
        }
        if db > 0 { next.overTime = now }
        return next
    }

    /// ランプは Peak Hold の間（0 のときは 1 秒）点く。
    static func isOverLit(_ hold: Hold?, now: Double, holdSeconds: Double) -> Bool {
        guard let over = hold?.overTime else { return false }
        return now - over < (holdSeconds > 0 ? holdSeconds : 1)
    }

    /// 数値欄の小数点以下の末尾の 0 を落とす（5.00 → 5、1.50 → 1.5、10.0 → 10）。
    /// 上流の number 入力は値をそのまま出す。Attack / Release / Peak Hold の欄がこれを使う。
    static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = Substring(s)
        while t.last == "0" { t = t.dropLast() }
        if t.last == "." { t = t.dropLast() }
        return t.isEmpty || t == "-" || t == "-0" ? "0" : String(t)
    }

    /// 積算時間の表示（formatAnalogMeterDuration、:198-205）。
    static func duration(_ seconds: Double) -> String {
        // Float の枠は 3e38 まで運べる。Int(_:) は範囲の外で落ちるので、100 年で止める。
        let total = Int(seconds > 0 ? min(seconds.rounded(.down), 3.2e9) : 0)
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let rest = String(format: "%02d", total % 60)
        return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(rest)" : "\(minutes):\(rest)"
    }

    /// 1 つの針の読み（cellReading、:536-546）。channel < 0 は Program（Loudness の先頭の針）。
    static func cellReading(channel: Int, reading: Reading?, mode: Int, needle: Int) -> Double? {
        guard let reading else { return nil }
        if channel < 0 {
            guard let program = reading.program else { return nil }
            return needle == 1 ? program.shortTerm : program.momentary
        }
        guard reading.channels.indices.contains(channel) else { return nil }
        let values = reading.channels[channel]
        return (mode == loudnessMode && needle == 1) ? values.maxDB : values.needleDB
    }

    /// Program の統計 6 行（drawProgramStats、:722-766 の表を縦に並べた順）。
    /// 上流は M / S / I と LRA / TP / Time の 2 つの表。上の 3 行と下の 3 行がそれに当たる。
    static func statRows(program: Program, integratedValid: Bool, lraValid: Bool) -> [(label: String, value: String)] {
        func lufs(_ v: Double) -> String { v <= silenceDB ? "-∞" : String(format: "%.1f", v) }
        return [
            ("M", "\(lufs(program.momentary)) LUFS"),
            ("S", "\(lufs(program.shortTerm)) LUFS"),
            ("I", "\(integratedValid ? lufs(program.integrated) : "---") LUFS"),
            ("LRA", "\(lraValid ? String(format: "%.1f", program.lra) : "---") LU"),
            ("TP", "\(lufs(program.maxTruePeak)) dBTP"),
            ("Time", duration(program.integratedSeconds)),
        ]
    }

    /// Program の読みがまだ無いときの表（上流の無効値の字。M・S・I は "---"、Time は 0:00）。
    /// 表を消さずに出しておくので、読みが来ても帯の大きさは変わらない。
    static let emptyStatRows: [(label: String, value: String)] = [
        ("M", "--- LUFS"), ("S", "--- LUFS"), ("I", "--- LUFS"),
        ("LRA", "--- LU"), ("TP", "--- dBTP"), ("Time", "0:00"),
    ]

    /// 目盛りの字の色と線（2 px）を強調するか。上流（analog_meter.js:759-772）どおり基準の目盛りだけ。
    /// 字の太さは変えない。赤い帯の始まりは強調しない。
    static func isEmphasized(_ value: Double, in scale: Scale) -> Bool {
        value == scale.reference
    }

    /// 針の見出し（cellTitle、:548-557）。
    static func cellTitle(channel: Int, mode: Int, channelCount: Int) -> String {
        if channel >= 0 {
            return mode == loudnessMode ? "Ch \(channel + 1) (reference)" : "Ch \(channel + 1)"
        }
        // BS.1770 がチャンネルの重みを決めているのはモノラル・ステレオ・5.1 だけ。
        let standard = channelCount == 1 || channelCount == 2 || channelCount == 6
        return standard ? "Program" : "Program (reference)"
    }

    /// 針の数。Loudness は先頭に Program の針が 1 つ増える（cellCount、:362-364）。
    static func cellCount(mode: Int, channelCount: Int) -> Int {
        channelCount + (mode == loudnessMode ? 1 : 0)
    }
}
