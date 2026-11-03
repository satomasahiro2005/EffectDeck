//  Entry.swift（Tests/Fuzz）
//  libFuzzer の入口。**1 本の実行ファイルに的を全部入れ、ET_FUZZ_TARGET で 1 つ選ぶ。**
//  アプリのファイルを的ごとに建て直さない（EffectCatalog だけで数分かかる）。
//
//  的は外から来る字を読むところだけ（Tests/Fuzz/run.sh の頭に一覧）。
//  落ちたら libFuzzer が入力を crash-* に残す。**落ちるのは次のどれか:**
//    - Swift の実行時の止め（配列の外・Int(_:) の溢れ・力ずくの unwrap）
//    - ASan（メモリの外）
//    - 下の `oracle` が見張る約束が破れたとき（NaN/inf が出てくる・書き戻せない JSON など）
//
//  `oracle` は fatalError で止める。libFuzzer はそれも crash として入力を残す。

import Foundation

typealias FuzzTarget = (UnsafeRawBufferPointer) -> Void

enum Fuzz {
    /// 名前 → 的。run.sh の一覧と同じ綴り。
    static let targets: [String: FuzzTarget] = [
        "chaintext": ChainTextFuzz.run,
        "sharelink": ShareLinkFuzz.run,
        "fxdlink": FXDLinkFuzz.run,
        "pipelineform": PipelineFormFuzz.run,
        "peqtext": PEQTextFuzz.run,
        "remotefile": RemoteFileFuzz.run,
        "jsfxtext": JSFXTextFuzz.run,
        "irprep": IRPrepFuzz.run,
    ]

    static var current: FuzzTarget?

    /// 約束が破れた。**libFuzzer に入力を残させるため必ず止める。**
    static func oracle(_ ok: @autoclosure () -> Bool, _ message: @autoclosure () -> String,
                       file: StaticString = #fileID, line: UInt = #line) {
        if !ok() { fatalError("fuzz oracle: " + message(), file: file, line: line) }
    }

    /// 貼られた字は String で来る（クリップボード・共有シート）。壊れたバイトは U+FFFD にする。
    static func text(_ data: UnsafeRawBufferPointer) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

@_cdecl("LLVMFuzzerInitialize")
public func etFuzzInitialize(_ argc: UnsafeMutablePointer<CInt>,
                             _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>) -> CInt {
    let name = ProcessInfo.processInfo.environment["ET_FUZZ_TARGET"] ?? ""
    guard let target = Fuzz.targets[name] else {
        let known = Fuzz.targets.keys.sorted().joined(separator: " ")
        FileHandle.standardError.write(Data("ET_FUZZ_TARGET=\(name) は無い（\(known)）\n".utf8))
        exit(2)
    }
    // 種を書くだけの起動（run.sh）。libFuzzer の本体へは進まない。
    if let out = ProcessInfo.processInfo.environment["ET_FUZZ_SEEDS_OUT"], !out.isEmpty {
        do {
            let n = try Seeds.write(target: name, to: URL(fileURLWithPath: out, isDirectory: true))
            print("seeds \(name): \(n)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("種を書けない: \(error)\n".utf8))
            exit(2)
        }
    }
    Fuzz.current = target
    return 0
}

@_cdecl("LLVMFuzzerTestOneInput")
public func etFuzzTestOneInput(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
    let bytes = UnsafeRawBufferPointer(start: size > 0 ? data : nil, count: size)
    Fuzz.current?(bytes)
    return 0
}
