//  IRLibraryKeyTests.swift
//  IR の置き場の鍵（IRLibraryFiles.key）。**上流の ir-library-id.js が作った見本と照合する。**
//
//  プリセットは IR の中身を持たず鍵だけを書くので、鍵がずれると web 版で作ったプリセットの IR が
//  こちらで「Missing from the library」になる。見本は Tools/golden/ir_library_id_golden.mjs が
//  上流の identifySingleIr / identifyPairedIr に作らせたもの（Tests/Fixtures/IR/ir-library-id-golden.json）。
//  長さに SHA-256 の詰め物の境目を含めてあるので、Linux の代役（Tests/Linux/Shims/CryptoKit）もここで試される。

import XCTest

final class IRLibraryKeyTests: XCTestCase {

    private struct Golden: Decodable {
        struct Single: Decodable { let input: String; let irId: String; let sha256: String }
        struct Paired: Decodable { let left: String; let right: String; let irId: String }
        let inputs: [String: String]
        let single: [Single]
        let paired: [Paired]
    }

    private func golden() throws -> Golden {
        let file = try XCTUnwrap(TestResource.url("ir-library-id-golden", "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: file))
    }

    private func bytes(_ name: String, in golden: Golden) throws -> Data {
        try XCTUnwrap(golden.inputs[name].flatMap { Data(base64Encoded: $0) }, name)
    }

    func testEmptyInputKey() {
        XCTAssertEqual(IRLibraryFiles.key(for: Data()), "e3b0c44298fc1c149afbf4c8")
    }

    func testKeyIsTheFirst24LowercaseHexDigits() {
        let key = IRLibraryFiles.key(for: Data("abc".utf8))
        XCTAssertEqual(key, "ba7816bf8f01cfea414140de")
        XCTAssertEqual(key.count, IRLibraryFiles.keyLength)
    }

    func testSingleKeysMatchUpstream() throws {
        let golden = try golden()
        XCTAssertGreaterThanOrEqual(golden.single.count, 11)
        for entry in golden.single {
            let data = try bytes(entry.input, in: golden)
            XCTAssertEqual(IRLibraryFiles.key(for: data), entry.irId, entry.input)
            XCTAssertEqual(String(entry.sha256.prefix(24)), entry.irId, entry.input)
        }
    }

    func testPairedKeysMatchUpstream() throws {
        let golden = try golden()
        XCTAssertFalse(golden.paired.isEmpty)
        for entry in golden.paired {
            let left = try bytes(entry.left, in: golden)
            let right = try bytes(entry.right, in: golden)
            XCTAssertEqual(IRLibraryFiles.key(left: left, right: right), entry.irId,
                           "\(entry.left) + \(entry.right)")
        }
    }

    /// 左右を入れ替えると別の IR。
    func testPairKeyDependsOnOrder() {
        let l = Data("left".utf8), r = Data("right".utf8)
        XCTAssertNotEqual(IRLibraryFiles.key(left: l, right: r), IRLibraryFiles.key(left: r, right: l))
        // 対の鍵は中身を連結した鍵とは違う（digest を連結している）。
        XCTAssertNotEqual(IRLibraryFiles.key(left: l, right: r), IRLibraryFiles.key(for: l + r))
    }
}
