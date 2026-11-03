//  ETFXDLink.swift
//  EffectDeck の共有リンク（effectdeck.nemut.ai）を読み書きする。
//
//  **作るのも associated domain も effectdeck.nemut.ai だけ。**
//  fxd.nemut.ai は人がプロフィールや投稿に打つための短い別名で、AASA も含めて
//  全部を effectdeck の同じパスとクエリへ 301 する（site/src/worker.js）。
//  アプリは fxd を作らないが、来たら読む（コピペやバナー経由で届くことがある）。
//
//  鎖は `/?p=<base64>`。形は ETShareLink と同じで、読むのも ETShareLink.parse。
//  JSFX 1 本は `/j#<payload>`。payload は UTF-8 のソースを raw DEFLATE（RFC 1951）に
//  かけて base64url（`=` なし）にしたもの。
//
//  **ソースは `#` の後ろに置く。**ブラウザは `#` 以降をサーバーへ送らない。
//  アプリの無い人がページを開いても、ソースは Worker にもログにも届かない。
//  戻すのはページの JS（DecompressionStream('deflate-raw')）。
//
//  **両側の約束は site/test-vector.json。**同じ payload を同じソースへ戻せることを
//  Tests/Unit/FXDLinkTests.swift と site/test.mjs の両方が確かめる。
//  書く側のバイト列は一致しなくてよい（圧縮器ごとに違う）。
//
//  UI には触らない。Foundation と Compression だけなので単体テストへ直接入れてある。

import Compression
import Foundation

enum ETFXDLink {

    /// 送る側の宛先。**リンクは必ずこちらで作る。**associated domain はここ 1 つ。
    /// fxd.nemut.ai は作らない。fxd は 301 しか返さず AASA も持たないので、
    /// fxd のリンクは Universal Link にならずブラウザで effectdeck へ転送される。
    static let host = "effectdeck.nemut.ai"

    /// 鎖を受ける宛先。Universal Link で来るのは effectdeck だけ。
    /// fxd と effetune.frieve.com は Universal Link では来ないが、
    /// ほかの口（コピペなど）から来たら同じ道で読む。
    static let chainHosts: Set<String> = ["fxd.nemut.ai", "effectdeck.nemut.ai", "effetune.frieve.com"]

    /// JSFX を受ける宛先。こちらの 2 つだけ（fxd は受けるだけで作らない）。
    static let jsfxHosts: Set<String> = ["fxd.nemut.ai", "effectdeck.nemut.ai"]

    /// 共有するソースの上限。**64 KB。**
    /// ETJSFXHost.importFile の 1 MB とは別の枠。長い URL はメッセージアプリや QR で切れる。
    static let sourceLimit = 64 * 1024

    /// 受ける payload の文字数の上限。**戻す前に切る。**
    /// 64 KB を圧縮できずに運んでも（stored block）base64url で 88 KB に届かない。
    static let payloadLimit = 96 * 1024

    enum Failure: LocalizedError, Equatable {
        case tooLarge
        /// 送る側。置き場のファイルが読めない。
        case unreadableSource
        /// 受ける側。payload が戻せない。
        case unreadableLink

        var errorDescription: String? {
            switch self {
            case .tooLarge:         return "This JSFX is too large to share as a link."
            case .unreadableSource: return "This JSFX could not be read."
            case .unreadableLink:   return "That link had no JSFX in it."
            }
        }
    }

    // MARK: - 書く

    /// `https://effectdeck.nemut.ai/j#<payload>`
    static func jsfxURL(source: String) throws -> URL {
        let payload = try encode(source)
        guard let url = URL(string: "https://\(host)/j#\(payload)") else { throw Failure.unreadableSource }
        return url
    }

    static func encode(_ source: String) throws -> String {
        let raw = Data(source.utf8)
        guard !raw.isEmpty else { throw Failure.unreadableSource }
        guard raw.count <= sourceLimit else { throw Failure.tooLarge }
        guard let packed = deflate(raw) else { throw Failure.unreadableSource }
        return base64url(packed)
    }

    // MARK: - 読む

    enum Route: Equatable {
        /// ETShareLink.parse に渡す文字列。
        case chain(String)
        /// 戻したソース。
        case jsfx(String)
        case failed(Failure)
        /// こちらのドメインだが読むものが無い（公式ページそのものなど）。
        case ignored
    }

    /// 開かれた URL の行き先。**こちらのリンクでなければ nil。**
    /// nil のときだけ呼び出し側がファイルとして扱う。
    static func route(_ url: URL) -> Route? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              chainHosts.contains(host) || jsfxHosts.contains(host),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        if jsfxHosts.contains(host), comps.path == "/j" || comps.path == "/j/" {
            guard let payload = comps.percentEncodedFragment,
                  let source = try? decode(payload) else { return .failed(.unreadableLink) }
            return .jsfx(source)
        }
        if chainHosts.contains(host), comps.queryItems?.contains(where: { $0.name == "p" }) == true {
            return .chain(url.absoluteString)
        }
        return .ignored
    }

    static func decode(_ payload: String) throws -> String {
        guard !payload.isEmpty, payload.count <= payloadLimit,
              let packed = data(base64url: payload),
              let raw = inflate(packed, limit: sourceLimit) else { throw Failure.unreadableLink }
        guard let text = String(data: raw, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.unreadableLink }
        return text
    }

    // MARK: - base64url

    static func base64url(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// **URL-safe の字しか受けない。**素の base64（`+` `/` `=`）が混じったら落とす。
    /// 両方を受けると、同じ中身に 2 通りの綴りができる。
    static func data(base64url s: String) -> Data? {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !s.isEmpty, s.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              s.count % 4 != 1 else { return nil }
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }

    // MARK: - raw DEFLATE

    /// COMPRESSION_ZLIB は zlib の枠（ヘッダとチェックサム）を付けない素の DEFLATE。
    /// ブラウザの 'deflate-raw' と同じもの。
    static func deflate(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    /// 戻す。**出力が limit を超えたら nil。**
    ///
    /// NSData.decompressed は上限を取らないので使わない。数 KB の payload が
    /// 何百 MB にも膨らむ（DEFLATE の比は最大で約 1000 倍）。
    /// **終わりの印（COMPRESSION_STATUS_END）まで読めたものだけ受ける。**
    /// 途中で切れた payload は、途中までの字を返すことがある。
    static func inflate(_ data: Data, limit: Int) -> Data? {
        guard !data.isEmpty, limit > 0 else { return nil }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }

        // 1 バイト多く取る。そこまで埋まったら上限を超えている。
        var out = Data(count: limit + 1)
        let produced: Int? = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int? in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int? in
                guard let s = src.bindMemory(to: UInt8.self).baseAddress,
                      let d = dst.bindMemory(to: UInt8.self).baseAddress else { return nil }
                stream.pointee.src_ptr = s
                stream.pointee.src_size = src.count
                stream.pointee.dst_ptr = d
                stream.pointee.dst_size = dst.count
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_END else { return nil }
                return dst.count - stream.pointee.dst_size
            }
        }
        guard let n = produced, n <= limit else { return nil }
        return out.prefix(n)
    }
}
