//  SFZLoaderSupport.swift
//  SFZLoader（SoundFont・SFZ の読み込みを JS に任せて、カーネルへ送る流れ）が使う、Foundation だけの部品。
//  Linux でも走る（SFZLoaderSupportTests）。AVFoundation・JavaScriptCore・エンジンを呼ぶ側は SFZLoader.swift。
//
//    ETSFZPayloadFill        JS が返した制御の部分と PCM の面を、カーネルの staging へ直に組む
//    ETSFZPreparedCache      直前に読んだバンクを (バンクの鍵, 束ねの sha) で覚える
//    ETSFZBundleIdentity     同梱の JS（effetune-sfz.js）の頭の行から sha を取る
//    ETSFZAudioSniff         音のファイルの頭のバイトから拡張子を決める（AVAudioFile は拡張子を手がかりにする）
//    ETSFZAssetWatch         commit の後に et_instance_asset_state を読んで、失敗を段の状態にする
//    ETSFZScriptBackendAdapter  置き場（ETSFZLibraryBackend）を JS の 6 つの操作にそろえる

import Foundation

// MARK: - staging へ組む

enum ETSFZPayloadFill {

    /// control（payload の頭から。標本の PCM の手前まで）を staging の先頭に写し、プールの各区間を ETSFZPoolFill で書く。
    /// staging は payload 全体の大きさ。
    /// **どの区間にも覆われない所（区間の間・末尾）だけを 0 にする**（staging の中身が不定なため。上流の
    /// `new Float32Array` は 0 で始まり、書かれなかった float はそのまま 0 のまま payload に入る）。
    /// 全体を先に 0 にしてから書くと、大きなバンクで同じ所を 2 度書くことになり、bypass が長引く。
    /// プールの区間が control の中へ食い込むとき（JS の payload と食い違った印）は書かずに止める。
    static func fill(staging: UnsafeMutableRawBufferPointer, control: Data, pool: [ETSFZPoolEntry]) throws {
        guard control.count >= ETSFZPoolFill.outerHeaderBytes, control.count <= staging.count,
              let base = staging.baseAddress
        else { throw ETSFZError.prepare(ETSFZPoolFill.invalidPayloadMessage) }
        // 先に区間を全部確かめる（途中で止めて staging を半端に書かない）。区間は staging の先頭からのバイトの範囲。
        var spans: [(start: Int, end: Int)] = []
        spans.reserveCapacity(pool.count)
        for entry in pool {
            let (offsetBytes, overflowOffset) = entry.floatOffset.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
            guard entry.floatOffset >= 0, !overflowOffset,
                  offsetBytes <= Int.max - ETSFZPoolFill.outerHeaderBytes,
                  offsetBytes + ETSFZPoolFill.outerHeaderBytes >= control.count
            else { throw ETSFZError.prepare(ETSFZPoolFill.invalidPayloadMessage) }
            let start = ETSFZPoolFill.outerHeaderBytes + offsetBytes
            let (words, overflowWords) = max(entry.frames, 0).multipliedReportingOverflow(by: entry.planes.count)
            let (lengthBytes, overflowLength) = words.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
            guard !overflowWords, !overflowLength, lengthBytes <= staging.count - start
            else { throw ETSFZError.prepare(ETSFZPoolFill.invalidPayloadMessage) }
            spans.append((start, start + lengthBytes))
        }
        control.withUnsafeBytes { source in
            if let from = source.baseAddress { base.copyMemory(from: from, byteCount: control.count) }
        }
        var cursor = control.count
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if span.start > cursor { memset(base + cursor, 0, span.start - cursor) }
            cursor = max(cursor, span.end)
        }
        if cursor < staging.count { memset(base + cursor, 0, staging.count - cursor) }
        let writer = ETSFZPoolFill(staging: staging)
        for entry in pool {
            try writer.write(floatOffset: entry.floatOffset, frames: entry.frames, planes: entry.planes.map(\.buffer))
        }
    }
}

// MARK: - 覚え

/// 直前に読んだバンク 1 つ。出力先の切り替えなどで instance が作り直されるたびに JS で読み直さないための覚え。
/// **覚えるのは payload の制御の部分とプールの面（PCM）だけ。footprint は覚えない**（幾何が変われば変わるので send のたびに出す）。
/// 鍵に束ねの sha を入れるのは、JS を差し替えた版が前の版の payload を返さないため。
struct ETSFZPreparedCache {

    struct Key: Hashable {
        var bankID: String
        var bundleSHA: String
    }

    /// 覚える上限（payload 全体のバイト数）。256 MiB 級のバンクは持たない（メモリを食う）。
    let limitBytes: Int
    private var held: (key: Key, prepared: ETSFZScriptPrepared)?

    init(limitBytes: Int = 64 * 1024 * 1024) {
        self.limitBytes = limitBytes
    }

    func get(_ key: Key) -> ETSFZScriptPrepared? {
        guard let held, held.key == key else { return nil }
        return held.prepared
    }

    /// 覚えられたら true。上限を越えるときは**前の覚えも捨てる**（古いバンクを残さない）。
    @discardableResult
    mutating func store(_ prepared: ETSFZScriptPrepared, for key: Key) -> Bool {
        guard prepared.payloadByteCount <= limitBytes else {
            held = nil
            return false
        }
        held = (key, prepared)
        return true
    }

    mutating func remove(bankID: String) {
        if held?.key.bankID == bankID { held = nil }
    }

    mutating func removeAll() { held = nil }
}

// MARK: - 束ねの印

enum ETSFZBundleIdentity {

    /// effetune-sfz.js の頭の「// sha256: <64 桁>」。Tools/sfzjs/build.mjs が書く。無ければ nil。
    static func sha(inHeader header: String) -> String? {
        for line in header.split(separator: "\n", omittingEmptySubsequences: true).prefix(12) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("// sha256:") else { continue }
            let value = text.dropFirst("// sha256:".count).trimmingCharacters(in: .whitespaces)
            let valid = value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
            return valid ? value : nil
        }
        return nil
    }

    /// ファイルの頭 1 KiB から。読めない・印が無いときは "unknown"（覚えは効かないが、動きは変わらない）。
    static func sha(ofBundleAt url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unknown" }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024) else { return "unknown" }
        return sha(inHeader: String(decoding: head, as: UTF8.self)) ?? "unknown"
    }
}

// MARK: - 音のファイルの型

enum ETSFZAudioSniff {

    /// 頭のバイトから拡張子。JS の decode は名前を渡さない（Web の decodeAudioData は中身で決める）ので、ここで中身を見る。
    /// 見分けられなければ wav。
    static func fileExtension(for data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        func tag(_ offset: Int, _ text: String) -> Bool {
            let bytes = Array(text.utf8)
            return head.count >= offset + bytes.count && Array(head[offset..<(offset + bytes.count)]) == bytes
        }
        if tag(0, "RIFF") || tag(0, "RF64") { return "wav" }
        if tag(0, "FORM") { return tag(8, "AIFC") ? "aifc" : "aif" }
        if tag(0, "fLaC") { return "flac" }
        if tag(0, "OggS") { return "ogg" }
        if tag(0, "caff") { return "caf" }
        if tag(4, "ftyp") { return "m4a" }
        if tag(0, "ID3") || (head.count >= 2 && head[0] == 0xFF && head[1] & 0xE0 == 0xE0) { return "mp3" }
        return "wav"
    }
}

// MARK: - commit の後の見張り

enum ETSFZAssetWatch {

    enum Verdict: Equatable {
        /// まだ（staged・preparing）。音が流れないと進まない。
        case waiting
        case active
        /// ERROR。確保できなかった（reason 2。footprint 不足を含む）は too-large、それ以外は prepare。
        case failed(ETSFZErrorCode)
        /// 資産が無い（instance が作り直された・外された）。見張りをやめる。
        case gone
    }

    static func verdict(_ status: ETAssetStatus) -> Verdict {
        switch status.state {
        case .active: return .active
        case .error: return .failed(status.reason == 2 ? .tooLarge : .prepare)
        case .none: return .gone
        case .staged, .preparing: return .waiting
        }
    }
}

// MARK: - 置き場を JS の口にそろえる

/// 上流の SfzLibraryService が頼む 6 つの操作を、ETSFZLibraryBackend で行う。**JS のスレッドで同期に呼ばれる。**
/// 失敗は ETSFZError にして投げる（JS には code と message が渡り、service が storage に包む）。
final class ETSFZScriptBackendAdapter: ETSFZScriptBackend, @unchecked Sendable {

    let backend: ETSFZLibraryBackend

    init(backend: ETSFZLibraryBackend) {
        self.backend = backend
    }

    static func map(_ error: Error) -> Error {
        if error is ETSFZError { return error }
        guard let error = error as? ETSFZBackendError else { return ETSFZError(code: .storage, message: String(describing: error)) }
        switch error {
        case .invalidItem: return ETSFZError(code: .storage, message: "Invalid SFZ library item.")
        case .tooLarge: return ETSFZError(code: .tooLarge, message: "The SFZ bank is too large to load.")
        case .cancelled: return ETSFZError(code: .cancelled, message: "SFZ import was cancelled.")
        case .io(let text): return ETSFZError(code: .storage, message: text)
        }
    }

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw Self.map(error) }
    }

    func cleanupTemporary() throws { try wrap { try backend.cleanupTemporary() } }

    func read(_ key: String) throws -> Data? { try wrap { try backend.read(key) } }

    func writeAtomic(_ key: String, _ data: Data) throws { try wrap { try backend.writeAtomic(key, data) } }

    func remove(_ key: String) throws { try wrap { try backend.remove(key) } }

    func readSfzBankFile(_ name: String) throws -> ETSFZScriptFile? {
        try wrap {
            guard let file = try backend.readSfzBankFile(name) else { return nil }
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate]) as? Date
            return ETSFZScriptFile(path: name, url: file.url, size: Int(clamping: file.size),
                                   lastModified: ((modified?.timeIntervalSince1970 ?? 0) * 1000).rounded(.down))
        }
    }

    func writeSfzBankFile(_ name: String, segments: [ETSFZScriptSegment], isCurrent: () -> Bool) throws {
        let parts: [ETSFZBackendPart] = segments.map { segment in
            switch segment {
            case .bytes(let data): return .bytes(data)
            case .fileRange(let url, let offset, let length): return .fileRange(url: url, offset: offset, length: length)
            }
        }
        // isCurrent は non-escaping。backend の引数は省略可の（= escaping の）型なので、包んで渡す。
        try wrap {
            try withoutActuallyEscaping(isCurrent) { current in
                try backend.writeSfzBankFile(name, parts: parts, isCurrent: current)
            }
        }
    }
}
