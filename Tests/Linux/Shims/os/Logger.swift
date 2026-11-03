//  Logger.swift（Linuxの代役）
//  Appleのos / OSLogモジュールのLoggerを、Tests/Linux/run.shの中だけで置き換える。
//  **製品には入らない。**project.ymlはTests/Linuxを知らない。
//
//  補間はAppleと同じ口だけを受ける: 文字列・整数（format:）・浮動小数（format:）・Bool・
//  CustomStringConvertible・NSObject・型。どれもalign:とprivacy:を取る。
//  Appleで建たない書き方（Optionalをそのまま渡すなど）はここでも建たないようにしてある。
//  中身は捨てる。ET_LINUX_LOG=1 を付けたときだけstderrへ出す。

import Foundation

public struct OSLogType: Equatable, Hashable, RawRepresentable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public init(_ rawValue: UInt8) { self.rawValue = rawValue }
    public static let `default` = OSLogType(rawValue: 0x00)
    public static let info = OSLogType(rawValue: 0x01)
    public static let debug = OSLogType(rawValue: 0x02)
    public static let error = OSLogType(rawValue: 0x10)
    public static let fault = OSLogType(rawValue: 0x11)
}

public struct OSLogPrivacy: Equatable, Sendable {
    public enum Mask: Equatable, Sendable { case hash, none }
    let kind: Int
    let mask: Mask
    public static let `public` = OSLogPrivacy(kind: 0, mask: .none)
    public static let `private` = OSLogPrivacy(kind: 1, mask: .none)
    public static let sensitive = OSLogPrivacy(kind: 2, mask: .none)
    public static let auto = OSLogPrivacy(kind: 3, mask: .none)
    public static func `private`(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: 1, mask: mask) }
    public static func sensitive(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: 2, mask: mask) }
    public static func auto(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: 3, mask: mask) }
}

public struct OSLogStringAlignment: Sendable {
    let columns: Int
    public static let none = OSLogStringAlignment(columns: 0)
    public static func right(columns: @autoclosure @escaping () -> Int) -> OSLogStringAlignment {
        OSLogStringAlignment(columns: columns())
    }
    public static func left(columns: @autoclosure @escaping () -> Int) -> OSLogStringAlignment {
        OSLogStringAlignment(columns: -columns())
    }
    func apply(_ s: String) -> String {
        let pad = abs(columns) - s.count
        guard pad > 0 else { return s }
        let fill = String(repeating: " ", count: pad)
        return columns > 0 ? fill + s : s + fill
    }
}

public struct OSLogIntegerFormatting: Sendable {
    enum Radix: Sendable { case decimal, hex, octal }
    let radix: Radix
    let plus: Bool
    let prefix: Bool
    let upper: Bool
    let minDigits: Int?

    public static var decimal: OSLogIntegerFormatting { decimal(explicitPositiveSign: false) }
    public static var hex: OSLogIntegerFormatting { hex(explicitPositiveSign: false) }
    public static var octal: OSLogIntegerFormatting { octal(explicitPositiveSign: false) }
    public static func decimal(explicitPositiveSign: Bool = false) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: .decimal, plus: explicitPositiveSign, prefix: false, upper: false, minDigits: nil)
    }
    public static func decimal(explicitPositiveSign: Bool = false,
                               minDigits: @autoclosure @escaping () -> Int) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: .decimal, plus: explicitPositiveSign, prefix: false, upper: false,
                               minDigits: minDigits())
    }
    public static func hex(explicitPositiveSign: Bool = false, includePrefix: Bool = false,
                           uppercase: Bool = false) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: .hex, plus: explicitPositiveSign, prefix: includePrefix, upper: uppercase,
                               minDigits: nil)
    }
    public static func hex(explicitPositiveSign: Bool = false, includePrefix: Bool = false,
                           uppercase: Bool = false,
                           minDigits: @autoclosure @escaping () -> Int) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: .hex, plus: explicitPositiveSign, prefix: includePrefix, upper: uppercase,
                               minDigits: minDigits())
    }
    public static func octal(explicitPositiveSign: Bool = false,
                             includePrefix: Bool = false) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: .octal, plus: explicitPositiveSign, prefix: includePrefix, upper: false,
                               minDigits: nil)
    }
    public static func octal(explicitPositiveSign: Bool = false, includePrefix: Bool = false,
                             minDigits: @autoclosure @escaping () -> Int) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: .octal, plus: explicitPositiveSign, prefix: includePrefix, upper: false,
                               minDigits: minDigits())
    }

    func render<T: BinaryInteger>(_ v: T) -> String {
        var digits: String
        switch radix {
        case .decimal: digits = String(v.magnitude)
        case .hex: digits = String(v.magnitude, radix: 16, uppercase: upper)
        case .octal: digits = String(v.magnitude, radix: 8)
        }
        if let minDigits, digits.count < minDigits {
            digits = String(repeating: "0", count: minDigits - digits.count) + digits
        }
        let sign = v < 0 ? "-" : plus ? "+" : ""
        let lead = !prefix ? "" : radix == .hex ? "0x" : radix == .octal ? "0" : ""
        return sign + lead + digits
    }
}

public struct OSLogFloatFormatting: Sendable {
    let conversion: String
    let precision: Int?
    let plus: Bool

    private static func make(_ c: String, _ precision: Int?, _ plus: Bool, _ upper: Bool) -> OSLogFloatFormatting {
        OSLogFloatFormatting(conversion: upper ? c.uppercased() : c, precision: precision, plus: plus)
    }

    public static var fixed: OSLogFloatFormatting { fixed(explicitPositiveSign: false) }
    public static var hex: OSLogFloatFormatting { hex(explicitPositiveSign: false) }
    public static var exponential: OSLogFloatFormatting { exponential(explicitPositiveSign: false) }
    public static var hybrid: OSLogFloatFormatting { hybrid(explicitPositiveSign: false) }
    public static func fixed(explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        make("f", nil, explicitPositiveSign, uppercase)
    }
    public static func fixed(precision: @autoclosure @escaping () -> Int, explicitPositiveSign: Bool = false,
                             uppercase: Bool = false) -> OSLogFloatFormatting {
        make("f", precision(), explicitPositiveSign, uppercase)
    }
    public static func hex(explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        make("a", nil, explicitPositiveSign, uppercase)
    }
    public static func exponential(explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        make("e", nil, explicitPositiveSign, uppercase)
    }
    public static func exponential(precision: @autoclosure @escaping () -> Int, explicitPositiveSign: Bool = false,
                                   uppercase: Bool = false) -> OSLogFloatFormatting {
        make("e", precision(), explicitPositiveSign, uppercase)
    }
    public static func hybrid(explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        make("g", nil, explicitPositiveSign, uppercase)
    }
    public static func hybrid(precision: @autoclosure @escaping () -> Int, explicitPositiveSign: Bool = false,
                              uppercase: Bool = false) -> OSLogFloatFormatting {
        make("g", precision(), explicitPositiveSign, uppercase)
    }

    func render(_ v: Double) -> String {
        let p = precision.map { ".\($0)" } ?? ""
        return String(format: "%" + (plus ? "+" : "") + p + conversion, v)
    }
}

public enum OSLogBoolFormat: Sendable { case truth, answer }

public enum OSLogPointerFormat: Sendable { case none, ipv4Address, ipv6Address, sockaddr }

public struct OSLogInterpolation: StringInterpolationProtocol {
    var text = ""

    public init(literalCapacity: Int, interpolationCount: Int) {
        text.reserveCapacity(literalCapacity)
    }

    public mutating func appendLiteral(_ literal: String) { text += literal }

    public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> String,
                                             align: OSLogStringAlignment = .none,
                                             privacy: OSLogPrivacy = .auto) {
        text += align.apply(value())
    }

    public mutating func appendInterpolation<T: CustomStringConvertible>(
        _ value: @autoclosure @escaping () -> T,
        align: OSLogStringAlignment = .none,
        privacy: OSLogPrivacy = .auto) {
        text += align.apply(value().description)
    }

    public mutating func appendInterpolation<T: FixedWidthInteger>(
        _ number: @autoclosure @escaping () -> T,
        format: OSLogIntegerFormatting = .decimal,
        align: OSLogStringAlignment = .none,
        privacy: OSLogPrivacy = .auto) {
        text += align.apply(format.render(number()))
    }

    public mutating func appendInterpolation(_ number: @autoclosure @escaping () -> Double,
                                             format: OSLogFloatFormatting = .fixed,
                                             align: OSLogStringAlignment = .none,
                                             privacy: OSLogPrivacy = .auto) {
        text += align.apply(format.render(number()))
    }

    public mutating func appendInterpolation(_ number: @autoclosure @escaping () -> Float,
                                             format: OSLogFloatFormatting = .fixed,
                                             align: OSLogStringAlignment = .none,
                                             privacy: OSLogPrivacy = .auto) {
        text += align.apply(format.render(Double(number())))
    }

    public mutating func appendInterpolation(_ boolean: @autoclosure @escaping () -> Bool,
                                             format: OSLogBoolFormat = .truth,
                                             privacy: OSLogPrivacy = .auto) {
        let b = boolean()
        text += format == .truth ? (b ? "true" : "false") : (b ? "YES" : "NO")
    }

    public mutating func appendInterpolation(_ argumentObject: @autoclosure @escaping () -> NSObject,
                                             privacy: OSLogPrivacy = .auto) {
        text += argumentObject().description
    }

    public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Any.Type,
                                             align: OSLogStringAlignment = .none,
                                             privacy: OSLogPrivacy = .auto) {
        text += align.apply(String(describing: value()))
    }

    public mutating func appendInterpolation(_ pointer: @autoclosure @escaping () -> UnsafeRawPointer,
                                             format: OSLogPointerFormat = .none,
                                             privacy: OSLogPrivacy = .auto) {
        text += String(describing: pointer())
    }
}

public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    let text: String
    public init(stringInterpolation: OSLogInterpolation) { text = stringInterpolation.text }
    public init(stringLiteral value: String) { text = value }
}

public struct Logger: @unchecked Sendable {
    let subsystem: String
    let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public init() { self.init(subsystem: "", category: "") }

    public init(_ log: OSLog) { self.init(subsystem: log.subsystem, category: log.category) }

    private static let echo = ProcessInfo.processInfo.environment["ET_LINUX_LOG"] == "1"

    public func log(level: OSLogType, _ message: OSLogMessage) {
        guard Logger.echo else { return }
        FileHandle.standardError.write(Data("[\(subsystem):\(category)] \(message.text)\n".utf8))
    }

    public func log(_ message: OSLogMessage) { log(level: .default, message) }
    public func trace(_ message: OSLogMessage) { log(level: .debug, message) }
    public func debug(_ message: OSLogMessage) { log(level: .debug, message) }
    public func info(_ message: OSLogMessage) { log(level: .info, message) }
    public func notice(_ message: OSLogMessage) { log(level: .default, message) }
    public func warning(_ message: OSLogMessage) { log(level: .error, message) }
    public func error(_ message: OSLogMessage) { log(level: .error, message) }
    public func critical(_ message: OSLogMessage) { log(level: .fault, message) }
    public func fault(_ message: OSLogMessage) { log(level: .fault, message) }
}

public final class OSLog: @unchecked Sendable {
    public let subsystem: String
    public let category: String
    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }
    public static let disabled = OSLog(subsystem: "", category: "disabled")
    public static let `default` = OSLog(subsystem: "", category: "default")
}

// swiftcはosという名前のモジュールを特別に扱い、この変数が無いと建てるたびに警告を出す
// （中身はAppleと同じ区画の名前。代役では使わない）。
public let osLogStringSectionName = "__TEXT,__oslogstring,cstring_literals"
