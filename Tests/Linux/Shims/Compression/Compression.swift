//  Compression.swift（Linuxの代役）
//  `import Compression` でAppleと同じ名前が見えるようにする。**製品には入らない。**
//  - compression_stream_* とcompression_*_buffer: CCompression（zlibで書いたC）をそのまま出す
//  - NSData.compressed(using:) / decompressed(using:): DarwinのFoundationにあってLinuxに無い。
//    .zlibだけ（素のDEFLATE、強さ5）。他のアルゴリズムは投げる

@_exported import CCompression
import Foundation

extension NSData {
    public enum CompressionAlgorithm: Int {
        case lzfse = 0
        case lz4 = 1
        case lzma = 2
        case zlib = 3
    }

    public func compressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        try Self.run(Data(referencing: self), algorithm, COMPRESSION_STREAM_ENCODE)
    }

    public func decompressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        try Self.run(Data(referencing: self), algorithm, COMPRESSION_STREAM_DECODE)
    }

    private static func run(_ input: Data, _ algorithm: CompressionAlgorithm,
                            _ operation: compression_stream_operation) throws -> NSData {
        guard algorithm == .zlib else { throw CocoaError(.featureUnsupported) }
        var stream = compression_stream(dst_ptr: nil, dst_size: 0, src_ptr: nil, src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw CocoaError(.coderInvalidValue)
        }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        let status: compression_status = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress
            stream.src_size = src.count
            while true {
                let st: compression_status = buffer.withUnsafeMutableBufferPointer { dst in
                    stream.dst_ptr = dst.baseAddress
                    stream.dst_size = chunk
                    let st = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    output.append(dst.baseAddress!, count: chunk - stream.dst_size)
                    return st
                }
                if st == COMPRESSION_STATUS_END || st == COMPRESSION_STATUS_ERROR { return st }
                if stream.dst_size != 0 && stream.src_size == 0 && operation == COMPRESSION_STREAM_DECODE {
                    return COMPRESSION_STATUS_ERROR  // 入力が尽きたのに終わりの印が無い
                }
            }
        }
        guard status == COMPRESSION_STATUS_END else { throw CocoaError(.coderReadCorrupt) }
        return output as NSData
    }
}
