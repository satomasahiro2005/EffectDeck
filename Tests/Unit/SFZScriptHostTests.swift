//  SFZScriptHostTests.swift
//  上流 js/sfz・js/sf2 の束ね（Resources/SFZ/effetune-sfz.js）を JavaScriptCore で動かす入れ物（DSP/SFZScript/）。
//
//  前半は Foundation だけ（誤りの対応・面・取り消しの旗・資源の探し方）で、Linux でも走る。
//  後半は JavaScriptCore が要る（#if canImport(JavaScriptCore)）:
//    1. ETJSContext / ETJSHost の振る舞い（C API だけで組んだ文脈・Promise と timer・型付き配列・遅く建てて捨てる）
//    2. **見本（sfz-golden.json・sf2-golden.json）の全件を、本物の JavaScriptCore で束ねに通し、上流の答えと一致を見る。**
//       走らせ方は Node の試験（Tools/sfzjs/bundle.test.mjs）と同じ Tools/golden/sfz_runner.mjs・sf2_runner.mjs。
//    3. ETSFZScriptService を通した取り込み・読み直し（鍵・バンクのバイト・payload のバイト・見積り・誤り）。
//       PCM の書き手を差し込む道（.host）は、受けた面を staging の位置へ書き戻して見本の payload と同じバイトになること。

import XCTest

// MARK: - 資源の探し方

private enum SFZScriptTestResources {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/Unit
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリの根
    }

    /// バンドルの資源を先に、無ければリポジトリの中の元の場所から。
    static func url(_ name: String, _ ext: String, fallback: String) throws -> URL {
        if let url = TestResource.url(name, ext) { return url }
        let candidate = root.appendingPathComponent(fallback)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw XCTSkip("\(name).\(ext) が見つからない（\(fallback)）")
        }
        return candidate
    }

    static func sources() throws -> ETSFZScriptSources {
        ETSFZScriptSources(
            prelude: try url("effetune-sfz-prelude", "js", fallback: "Sources/EffeTuneLive/Resources/SFZ/effetune-sfz-prelude.js"),
            bundle: try url("effetune-sfz", "js", fallback: "Sources/EffeTuneLive/Resources/SFZ/effetune-sfz.js"))
    }
}

// MARK: - Foundation だけ

final class SFZScriptValueTests: XCTestCase {

    func testErrorMappingKeepsKnownUpstreamCodes() {
        let codes: [(String, ETSFZErrorCode)] = [
            ("prepare", .prepare), ("too-large", .tooLarge), ("no-regions", .noRegions),
            ("storage", .storage), ("cancelled", .cancelled), ("unsupported-runtime", .unsupportedRuntime),
        ]
        for (raw, expected) in codes {
            let error = ETSFZScriptErrors.map(code: raw, message: "上流の文 \(raw)", cancelled: false)
            XCTAssertEqual(error.code, expected, raw)
            XCTAssertEqual(error.message, "上流の文 \(raw)")
        }
        // 取り消しの旗が立っていても、JS が付けた綴りが先
        XCTAssertEqual(ETSFZScriptErrors.map(code: "too-large", message: "m", cancelled: true).code, .tooLarge)
    }

    func testErrorMappingFallsBackToPrepareOrCancelled() {
        // 上流には ETSFZErrorCode に無い綴り（sample-integrity・script-invalid）がある。文は上流のまま、種類は prepare
        let integrity = ETSFZScriptErrors.map(code: "sample-integrity", message: "An instrument sample does not match", cancelled: false)
        XCTAssertEqual(integrity.code, .prepare)
        XCTAssertEqual(integrity.message, "An instrument sample does not match")
        XCTAssertEqual(ETSFZScriptErrors.map(code: "script-invalid", message: "NKSP line 1", cancelled: false).code, .prepare)
        // code の無い誤りは、旗が立っていれば取り消し
        XCTAssertEqual(ETSFZScriptErrors.map(code: nil, message: "x", cancelled: true).code, .cancelled)
        XCTAssertEqual(ETSFZScriptErrors.map(code: nil, message: "x", cancelled: false).code, .prepare)
    }

    func testPlaneIsZeroFilledAndCopiesValues() {
        let empty = ETSFZPlane(count: 4)
        XCTAssertEqual(Array(empty.buffer), [0, 0, 0, 0])
        let plane = ETSFZPlane([0.5, -0.25, 1])
        XCTAssertEqual(plane.count, 3)
        XCTAssertEqual(Array(plane.buffer), [0.5, -0.25, 1])
        // 長さ 0 でも指す先を持つ（JS へ渡す型付き配列が空でも壊れない）
        let none = ETSFZPlane(count: 0)
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(none.buffer.count, 0)
    }

    func testCancelTokenIsStickyAndShared() {
        let token = ETSFZCancelToken()
        XCTAssertFalse(token.isCancelled)
        token.cancel()
        XCTAssertTrue(token.isCancelled)
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }

    func testBundledSourcesMissingReportsPrepareError() throws {
        let empty = try XCTUnwrap(Bundle(path: NSTemporaryDirectory()))
        XCTAssertThrowsError(try ETSFZScriptSources.bundled(empty)) { error in
            XCTAssertEqual((error as? ETSFZError)?.code, .prepare)
        }
    }
}

#if canImport(JavaScriptCore)

import CryptoKit
import JavaScriptCore

// MARK: - 文脈（ETJSContext）

final class ETJSContextTests: XCTestCase {

    private func makeContext() throws -> ETJSContext {
        let context = try ETJSContext()
        let host = context.makeObject()
        context.installTimers(on: host)
        context.setProperty(context.global, "__et", host)
        return context
    }

    func testEvaluateReturnsValues() throws {
        let context = try makeContext()
        defer { context.close() }
        XCTAssertEqual(context.double(of: try context.evaluate("1 + 2", url: "t.js")), 3)
        XCTAssertEqual(context.text(of: try context.evaluate("'日本' + 'ab'", url: "t.js")), "日本ab")
        XCTAssertEqual(context.int(of: try context.evaluate("7.9", url: "t.js")), 7)
        XCTAssertNil(context.int(of: try context.evaluate("NaN", url: "t.js")))
        XCTAssertNil(context.double(of: try context.evaluate("'x'", url: "t.js")))
    }

    func testJSExceptionKeepsNameMessageAndCode() throws {
        let context = try makeContext()
        defer { context.close() }
        XCTAssertThrowsError(try context.evaluate("throw Object.assign(new RangeError('boom'), { code: 'too-large' })", url: "t.js")) { error in
            let thrown = error as? ETJSError
            XCTAssertEqual(thrown?.name, "RangeError")
            XCTAssertEqual(thrown?.message, "boom")
            XCTAssertEqual(thrown?.code, "too-large")
        }
        XCTAssertThrowsError(try context.evaluate("let = ;", url: "bad.js")) { error in
            XCTAssertEqual((error as? ETJSError)?.name, "SyntaxError")
        }
        // 文字列を投げても読める
        XCTAssertThrowsError(try context.evaluate("throw 'plain'", url: "t.js")) { error in
            XCTAssertEqual((error as? ETJSError)?.message, "plain")
        }
    }

    func testHostFunctionCallsBackAndThrowsIntoJS() throws {
        let context = try makeContext()
        defer { context.close() }
        context.install("add", on: context.global) { context, arguments in
            let sum = arguments.reduce(0.0) { $0 + (context.double(of: $1) ?? 0) }
            return context.number(sum)
        }
        context.install("fail", on: context.global) { _, _ in
            throw ETJSError(name: "Error", message: "ホストの失敗", code: "storage")
        }
        context.install("failSFZ", on: context.global) { _, _ in
            throw ETSFZError(code: .tooLarge, message: "too big")
        }
        XCTAssertEqual(context.double(of: try context.evaluate("add(1, 2, 3.5)", url: "t.js")), 6.5)
        let caught = try context.evaluate("(function () { try { fail(); } catch (e) { return e.code + ':' + e.message; } })()", url: "t.js")
        XCTAssertEqual(context.text(of: caught), "storage:ホストの失敗")
        let coded = try context.evaluate("(function () { try { failSFZ(); } catch (e) { return e.code + ':' + e.message; } })()", url: "t.js")
        XCTAssertEqual(context.text(of: coded), "too-large:too big")
        // 捕まえなければ Swift 側へ ETJSError で戻る
        XCTAssertThrowsError(try context.evaluate("fail()", url: "t.js")) { error in
            XCTAssertEqual((error as? ETJSError)?.code, "storage")
        }
        // 関数として扱える（call・bind・typeof）
        XCTAssertEqual(context.text(of: try context.evaluate("typeof add", url: "t.js")), "function")
        XCTAssertEqual(context.double(of: try context.evaluate("add.call(null, 4, 5)", url: "t.js")), 9)
        XCTAssertEqual(context.double(of: try context.evaluate("add.bind(null, 10)(5)", url: "t.js")), 15)
    }

    func testTypedArrayBytesRoundTrip() throws {
        let context = try makeContext()
        defer { context.close() }
        let sent = try context.makeUint8Array(copying: Data([1, 2, 3, 250]))
        context.setProperty(context.global, "sent", sent)
        XCTAssertEqual(context.double(of: try context.evaluate("sent.length * 1000 + sent[3]", url: "t.js")), 4250)

        var received: [UInt8] = []
        context.install("take", on: context.global) { context, arguments in
            let window = arguments.first.flatMap { context.byteWindow(of: $0) }
            received = window.map { Array($0) } ?? []
            return nil
        }
        // 範囲を見ている型付き配列は、見ている範囲だけを渡す
        _ = try context.evaluate("take(new Uint8Array([9, 8, 7, 6, 5]).subarray(1, 4))", url: "t.js")
        XCTAssertEqual(received, [8, 7, 6])
        _ = try context.evaluate("take(new Uint8Array([4, 3, 2]).buffer)", url: "t.js")
        XCTAssertEqual(received, [4, 3, 2])
        _ = try context.evaluate("take(new Float32Array([1]))", url: "t.js")
        XCTAssertEqual(received.count, 4)
        // 型付き配列でも ArrayBuffer でもない値は窓を持たない
        _ = try context.evaluate("take({ length: 3 })", url: "t.js")
        XCTAssertEqual(received, [])
        _ = try context.evaluate("take(new DataView(new ArrayBuffer(4)))", url: "t.js")
        XCTAssertEqual(received, [])
    }

    func testWritableUint8ArrayIsSharedWithJS() throws {
        let context = try makeContext()
        defer { context.close() }
        let made = try context.makeUint8Array(length: 4)
        for index in 0..<4 { made.bytes[index] = UInt8(index + 10) }
        context.setProperty(context.global, "shared", made.array)
        XCTAssertEqual(context.double(of: try context.evaluate("shared[0] + shared[1] + shared[2] + shared[3]", url: "t.js")), 46)
        _ = try context.evaluate("shared[2] = 99", url: "t.js")
        XCTAssertEqual(made.bytes[2], 99)
    }

    func testFloat32ArrayWindowIsNotCopiedAndOwnerIsReleased() throws {
        weak var weakPlane: ETSFZPlane?
        do {
            let context = try makeContext()
            defer { context.close() }
            let plane = ETSFZPlane([0.25, 0.5, -1])
            weakPlane = plane
            let array = try context.makeFloat32Array(pointer: plane.pointer, count: plane.count, owner: plane)
            context.setProperty(context.global, "pcm", array)
            XCTAssertEqual(context.double(of: try context.evaluate("pcm.length", url: "t.js")), 3)
            // JS の書き込みが Swift の領域に見える（複写していない）
            _ = try context.evaluate("pcm[1] = 0.75", url: "t.js")
            XCTAssertEqual(plane.buffer[1], 0.75)
            // Swift の書き込みが JS に見える
            plane.pointer[2] = 2
            XCTAssertEqual(context.double(of: try context.evaluate("pcm[2]", url: "t.js")), 2)
            let window = try XCTUnwrap(context.byteWindow(of: array))
            XCTAssertEqual(window.count, 12)
            XCTAssertTrue(context.isFloat32Array(array))
            XCTAssertFalse(context.isFloat32Array(sentinel(context)))
        }
        // 文脈を閉じれば JS のヒープごと消え、型付き配列の解放口が持ち物を手放す
        let deadline = Date().addingTimeInterval(3)
        while weakPlane != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertNil(weakPlane, "Float32Array の持ち物が文脈を閉じても残っている")
    }

    private func sentinel(_ context: ETJSContext) -> JSValueRef { context.number(1) }

    func testAwaitPromiseResolvesRejectsAndPassesThroughPlainValues() throws {
        let context = try makeContext()
        defer { context.close() }
        let resolved = try context.evaluate("Promise.resolve(5).then(v => v * 2)", url: "t.js")
        XCTAssertEqual(context.double(of: try context.awaitPromise(resolved)), 10)

        let rejected = try context.evaluate("Promise.reject(Object.assign(new Error('no'), { code: 'storage' }))", url: "t.js")
        XCTAssertThrowsError(try context.awaitPromise(rejected)) { error in
            XCTAssertEqual((error as? ETJSError)?.code, "storage")
            XCTAssertEqual((error as? ETJSError)?.message, "no")
        }

        let plain = try context.evaluate("42", url: "t.js")
        XCTAssertEqual(context.double(of: try context.awaitPromise(plain)), 42)

        // async 関数の連鎖（await を何段重ねても、掃けば続きが全部走る）
        let chain = try context.evaluate("(async () => { let n = 0; for (let i = 0; i < 50; i++) n += await Promise.resolve(i); return n; })()", url: "t.js")
        XCTAssertEqual(context.double(of: try context.awaitPromise(chain)), 1225)
    }

    func testTimersFireInOrderAndCancelledOnesDoNot() throws {
        let context = try makeContext()
        defer { context.close() }
        let value = try context.evaluate("""
        new Promise(resolve => {
          const order = [];
          __et.timer(() => { order.push('b'); resolve(order.join('')); }, 40);
          __et.timer(() => order.push('a'), 5);
          const dropped = __et.timer(() => order.push('x'), 10);
          __et.cancelTimer(dropped);
        })
        """, url: "t.js")
        XCTAssertEqual(context.text(of: try context.awaitPromise(value)), "ab")
    }

    func testAwaitingSomethingThatNeverArrivesThrowsInsteadOfHanging() throws {
        let context = try makeContext()
        defer { context.close() }
        let pending = try context.evaluate("new Promise(() => {})", url: "t.js")
        XCTAssertThrowsError(try context.awaitPromise(pending)) { error in
            XCTAssertTrue(String(describing: error).contains("never arrives"))
        }
    }

    func testErrorFromRejectedAsyncFunctionInsideTimerCallback() throws {
        let context = try makeContext()
        defer { context.close() }
        // timer の中の例外は握りつぶされず、待っていた Promise が拒否で返る
        let value = try context.evaluate("""
        new Promise((resolve, reject) => {
          __et.timer(() => { try { throw new Error('late'); } catch (e) { reject(e); } }, 5);
        })
        """, url: "t.js")
        XCTAssertThrowsError(try context.awaitPromise(value)) { error in
            XCTAssertEqual((error as? ETJSError)?.message, "late")
        }
    }
}

// MARK: - 文脈の持ち主（ETJSHost）

final class ETJSHostTests: XCTestCase {

    func testContextIsBuiltLazilyAndReused() async throws {
        let host = ETJSHost(idleSeconds: -1) { context in
            _ = try context.evaluate("globalThis.counter = 0", url: "setup.js")
        }
        XCTAssertEqual(host.contextCount, 0)
        let first = try await host.run { context -> Double in
            _ = try context.evaluate("counter += 1", url: "t.js")
            return context.double(of: try context.evaluate("counter", url: "t.js")) ?? -1
        }
        let second = try await host.run { context -> Double in
            _ = try context.evaluate("counter += 1", url: "t.js")
            return context.double(of: try context.evaluate("counter", url: "t.js")) ?? -1
        }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(host.contextCount, 1)
    }

    func testJobsRunOneByOneOnOneDedicatedThread() async throws {
        let host = ETJSHost(idleSeconds: -1) { _ in }
        let names = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<8 {
                group.addTask { try await host.run { _ in Thread.current.name ?? "" } }
            }
            var all: [String] = []
            for try await name in group { all.append(name) }
            return all
        }
        XCTAssertEqual(Set(names), ["ai.nemut.effetune.sfzjs"])
        XCTAssertEqual(host.contextCount, 1)
    }

    func testContextIsDroppedWhenIdleAndRebuilt() async throws {
        let host = ETJSHost(idleSeconds: 0.15) { context in
            _ = try context.evaluate("globalThis.marker = 'built'", url: "setup.js")
        }
        _ = try await host.run { context in
            _ = try context.evaluate("marker = 'used'", url: "t.js")
        }
        XCTAssertEqual(host.contextCount, 1)
        try await Task.sleep(nanoseconds: 700_000_000)
        let marker = try await host.run { context in context.text(of: try context.evaluate("marker", url: "t.js")) }
        XCTAssertEqual(marker, "built", "idle のあとは建て直した文脈（使った跡が残らない）")
        XCTAssertEqual(host.contextCount, 2)
    }

    func testContextSurvivesBackToBackJobs() async throws {
        let host = ETJSHost(idleSeconds: 5) { context in
            _ = try context.evaluate("globalThis.keep = 1", url: "setup.js")
        }
        for _ in 0..<3 { _ = try await host.run { _ in } }
        XCTAssertEqual(host.contextCount, 1)
    }

    func testDropDiscardsContext() async throws {
        let host = ETJSHost(idleSeconds: -1) { _ in }
        _ = try await host.run { _ in }
        host.drop()
        _ = try await host.run { _ in }
        XCTAssertEqual(host.contextCount, 2)
    }

    func testSetupFailureFailsTheJobAndTheNextJobRetries() async throws {
        let host = ETJSHost(idleSeconds: -1) { _ in throw ETJSError(message: "setup failed", code: "prepare") }
        do {
            _ = try await host.run { _ in 1 }
            XCTFail("setup の失敗で仕事が通った")
        } catch {
            XCTAssertEqual((error as? ETJSError)?.message, "setup failed")
        }
        do {
            _ = try await host.run { _ in 1 }
            XCTFail("setup の失敗で仕事が通った")
        } catch {
            XCTAssertEqual((error as? ETJSError)?.code, "prepare")
        }
        XCTAssertEqual(host.contextCount, 2)
    }

    func testWorkErrorPropagatesAndKeepsContext() async throws {
        let host = ETJSHost(idleSeconds: -1) { context in
            _ = try context.evaluate("globalThis.alive = true", url: "setup.js")
        }
        do {
            _ = try await host.run { context in try context.evaluate("throw new Error('inside')", url: "t.js") }
            XCTFail("仕事の誤りが伝わらない")
        } catch {
            XCTAssertEqual((error as? ETJSError)?.message, "inside")
        }
        let alive = try await host.run { context in context.text(of: try context.evaluate("String(alive)", url: "t.js")) }
        XCTAssertEqual(alive, "true")
        XCTAssertEqual(host.contextCount, 1)
    }
}

// MARK: - 見本の全件を本物の JavaScriptCore で

/// 見本の走らせ方（Tools/golden/*.mjs）を、import・export を外して JavaScriptCore の素の文脈で評価し、
/// 全件を同じ答えかどうか比べる。比べるのは JS の中（鍵の順に依らない深い比較）で、違えば最初の違う場所を返す。
final class SFZGoldenThroughJSCTests: XCTestCase {

    private struct Fixture {
        var prelude: String
        var bundle: String
        var sfzRunner: String
        var sf2Runner: String
        var golden: String
        var sf2Golden: String
    }

    private static var cachedFixture: Fixture?

    private func fixture() throws -> Fixture {
        if let cached = Self.cachedFixture { return cached }
        func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        let sources = try SFZScriptTestResources.sources()
        let loaded = Fixture(
            prelude: try text(sources.prelude), bundle: try text(sources.bundle),
            sfzRunner: try text(try SFZScriptTestResources.url("sfz_runner", "mjs", fallback: "Tools/golden/sfz_runner.mjs")),
            sf2Runner: try text(try SFZScriptTestResources.url("sf2_runner", "mjs", fallback: "Tools/golden/sf2_runner.mjs")),
            golden: try text(try SFZScriptTestResources.url("sfz-golden", "json", fallback: "Tests/Fixtures/SFZ/sfz-golden.json")),
            sf2Golden: try text(try SFZScriptTestResources.url("sf2-golden", "json", fallback: "Tests/Fixtures/SFZ/sf2-golden.json")))
        Self.cachedFixture = loaded
        return loaded
    }

    /// export を外し、関数 1 つの中に閉じ込める（2 つの runner が同じ名前の const を持つので、同じ層に並べない）。
    private static func wrap(_ source: String, name: String, exports: [String], imports: String = "") -> String {
        var body = source.replacingOccurrences(of: "(?m)^export\\s+", with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: "(?m)^import\\s*\\{([^}]*)\\}\\s*from\\s*'[^']*';[^\\n]*$",
                                         with: "const {$1} = globalThis.__sfzRunner;", options: .regularExpression)
        return "globalThis.\(name) = (function () {\n\(imports)\(body)\nreturn { \(exports.joined(separator: ", ")) };\n})();"
    }

    private static let driver = #"""
    (function () {
      'use strict';
      const G = globalThis, runner = G.__sfzRunner, sf2 = G.__sf2Runner, api = G.ETSFZ;
      const golden = JSON.parse(G.__goldenText), sf2Golden = JSON.parse(G.__sf2GoldenText);
      const audio = Object.fromEntries(Object.entries(golden.audio).map(([name, text]) => [name, runner.fromB64(text)]));
      const ctx = { U8: Uint8Array, F32: Float32Array, F64: Float64Array, Blob, File };
      // 鍵の順に依らない深い比較。違えば最初の違う場所の道を返す
      function diff(a, b, path) {
        if (a === b) return null;
        if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') {
          return path + ': ' + JSON.stringify(a).slice(0, 80) + ' != ' + JSON.stringify(b).slice(0, 80);
        }
        if (Array.isArray(a) !== Array.isArray(b)) return path + ': array/object';
        if (Array.isArray(a) && a.length !== b.length) return path + ': length ' + a.length + ' != ' + b.length;
        const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
        for (const key of keys) {
          const found = diff(a[key], b[key], path + '/' + key);
          if (found) return found;
        }
        return null;
      }
      const sections = {
        sf2: { count: () => sf2Golden.cases.length, name: i => sf2Golden.cases[i].name,
          run: async i => { const item = sf2Golden.cases[i]; return [await sf2.runSf2Case(api, ctx, item), item.expected]; } },
        budget: { count: () => golden.budget.cases.length, name: i => 'maxBytes ' + golden.budget.cases[i].maxBytes,
          run: async i => { const item = golden.budget.cases[i];
            return [await runner.expectedFor('budget', api, ctx, item, audio, { budget: golden.budget }), item.expected]; } },
        folder: { count: () => 1, name: () => 'folder',
          run: async () => [await runner.expectedFor('folder', api, ctx, golden.folder, audio, {}), golden.folder.expected] },
        merged: { count: () => 1, name: () => 'merged',
          run: async () => [runner.encoded(runner.mergedWarnings(api)), golden.merged] },
        regionFields: { count: () => 1, name: () => 'regionFields',
          run: async () => [runner.encoded(api.SFZ_REGION_FIELDS), golden.regionFields] },
      };
      for (const name of ['parser', 'bank', 'badBanks', 'asset', 'imports', 'streamedImports', 'migration', 'normalize']) {
        sections[name] = { count: () => golden[name].length, name: i => golden[name][i].name ?? golden[name][i].input ?? golden[name][i].selectedPath ?? String(i),
          run: async i => { const item = golden[name][i];
            return [await runner.expectedFor(name, api, ctx, item, audio, {}), item.expected]; } };
      }
      // 取り込みの乱数（流し込みの id）を見本と同じ値にする。呼ぶのは prelude の crypto.getRandomValues
      G.__et.random = bytes => runner.fixedRandom(bytes);
      G.__goldenCount = section => sections[section].count();
      G.__goldenName = (section, index) => String(sections[section].name(index));
      G.__goldenRun = async (section, index) => {
        const [actual, expected] = await sections[section].run(index);
        const found = diff(JSON.parse(JSON.stringify(actual)), JSON.parse(JSON.stringify(expected)), '');
        return found === null ? 'ok' : found;
      };
    })();
    """#

    /// 見本用の文脈。ホストの SHA-256（CryptoKit）・タイマー・見本の文字列を入れ、2 つの runner と束ねを評価する。
    private func makeContext() throws -> ETJSContext {
        let fixture = try fixture()
        let context = try ETJSContext()
        let host = context.makeObject()
        context.installTimers(on: host)
        context.install("sha256", on: host) { context, arguments in
            guard let first = arguments.first, let window = context.byteWindow(of: first) else {
                throw ETJSError(name: "TypeError", message: "sha256 needs bytes.")
            }
            let data = window.baseAddress.map { Data(bytes: $0, count: window.count) } ?? Data()
            return try context.makeUint8Array(copying: Data(SHA256.hash(data: data)))
        }
        context.setProperty(context.global, "__et", host)
        context.setProperty(context.global, "__goldenText", context.string(fixture.golden))
        context.setProperty(context.global, "__sf2GoldenText", context.string(fixture.sf2Golden))
        try context.evaluate(fixture.prelude, url: "effetune-sfz-prelude.js")
        try context.evaluate(fixture.bundle, url: "effetune-sfz.js")
        try context.evaluate(Self.wrap(fixture.sfzRunner, name: "__sfzRunner",
                                       exports: ["expectedFor", "fixedRandom", "fromB64", "encoded", "mergedWarnings", "decodeWav"]),
                             url: "sfz_runner.mjs")
        try context.evaluate(Self.wrap(fixture.sf2Runner, name: "__sf2Runner", exports: ["runSf2Case"],
                                       imports: ""), url: "sf2_runner.mjs")
        try context.evaluate(Self.driver, url: "driver.js")
        return context
    }

    private func runSection(_ section: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let context = try makeContext()
        defer { context.close() }
        let count = try XCTUnwrap(context.int(of: try context.callMethod(context.global, "__goldenCount", [context.string(section)])))
        XCTAssertGreaterThan(count, 0, section, file: file, line: line)
        var failures: [String] = []
        for index in 0..<count {
            let name = context.text(of: try context.callMethod(context.global, "__goldenName", [context.string(section), context.number(Double(index))]))
            let promise = try context.callMethod(context.global, "__goldenRun", [context.string(section), context.number(Double(index))])
            let verdict = context.text(of: try context.awaitPromise(promise))
            if verdict != "ok" { failures.append("\(section)[\(index)] \(name): \(verdict)") }
        }
        XCTAssertTrue(failures.isEmpty, "見本と違う \(failures.count)/\(count) 件:\n" + failures.joined(separator: "\n"), file: file, line: line)
    }

    func testParser() throws { try runSection("parser") }
    func testBank() throws { try runSection("bank") }
    func testBadBanks() throws { try runSection("badBanks") }
    func testAsset() throws { try runSection("asset") }
    func testImports() throws { try runSection("imports") }
    func testStreamedImports() throws { try runSection("streamedImports") }
    func testMigration() throws { try runSection("migration") }
    func testNormalize() throws { try runSection("normalize") }
    func testBudget() throws { try runSection("budget") }
    func testFolder() throws { try runSection("folder") }
    func testMerged() throws { try runSection("merged") }
    func testRegionFields() throws { try runSection("regionFields") }
    func testSoundFont() throws { try runSection("sf2") }
}

// MARK: - ETSFZScriptService

/// 置き場の代わり（メモリ）。呼ばれるのは JS のスレッドなので、鍵つき。
private final class MemoryBackend: ETSFZScriptBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private(set) var cleanups = 0

    func cleanupTemporary() throws { lock.lock(); cleanups += 1; lock.unlock() }
    func read(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return store[key] }
    func writeAtomic(_ key: String, _ data: Data) throws { lock.lock(); store[key] = data; lock.unlock() }
    func remove(_ key: String) throws { lock.lock(); store[key] = nil; lock.unlock() }
    func readSfzBankFile(_ name: String) throws -> ETSFZScriptFile? { nil }
    func writeSfzBankFile(_ name: String, segments: [ETSFZScriptSegment], isCurrent: () -> Bool) throws {
        throw ETSFZError(code: .storage, message: "streaming is not part of this test")
    }

    func snapshot() -> [String: Data] { lock.lock(); defer { lock.unlock() }; return store }
    func seed(_ key: String, _ data: Data) { lock.lock(); store[key] = data; lock.unlock() }
}

/// 見積りに渡ったものを残す。見本の固定の見積り（sfz_runner.mjs の fixedEstimate）と同じ式。
private final class EstimateLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(control: Data, payloadBytes: Int, geometry: ETSFZGeometry, formatTag: Int)] = []

    func record(_ control: Data, _ payloadBytes: Int, _ geometry: ETSFZGeometry, _ formatTag: Int) -> Int {
        lock.lock()
        calls.append((control, payloadBytes, geometry, formatTag))
        lock.unlock()
        return 4096 + 64 * geometry.processingChannels + geometry.maxFrames + (formatTag == 1 ? 0 : 1)
    }
}

final class ETSFZScriptServiceTests: XCTestCase {

    private static var cachedGolden: [String: Any]?
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for url in temporaryRoots { try? FileManager.default.removeItem(at: url) }
        temporaryRoots = []
        super.tearDown()
    }

    // MARK: 道具

    private func golden() throws -> [String: Any] {
        if let cached = Self.cachedGolden { return cached }
        let url = try SFZScriptTestResources.url("sfz-golden", "json", fallback: "Tests/Fixtures/SFZ/sfz-golden.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        Self.cachedGolden = object
        return object
    }

    private func importCases() throws -> [[String: Any]] {
        try XCTUnwrap(try golden()["imports"] as? [[String: Any]])
    }

    private func audio(_ name: String) throws -> Data {
        let all = try XCTUnwrap(try golden()["audio"] as? [String: String])
        return try XCTUnwrap(all[name].flatMap { Data(base64Encoded: $0) }, name)
    }

    /// 見本の folder（{ path: { text } | { b64 } }）をディスクへ書き、ETSFZScriptFile の並びにする。
    private func writeFolder(_ folder: [String: Any]) throws -> [ETSFZScriptFile] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sfzscript-\(UUID().uuidString)", isDirectory: true)
        temporaryRoots.append(root)
        var files: [ETSFZScriptFile] = []
        for path in folder.keys.sorted() {
            let body = try XCTUnwrap(folder[path] as? [String: Any])
            let data: Data
            if let text = body["text"] as? String { data = Data(text.utf8) }
            else { data = try XCTUnwrap((body["b64"] as? String).flatMap { Data(base64Encoded: $0) }, path) }
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            files.append(ETSFZScriptFile(path: path, url: url, size: data.count, lastModified: 0))
        }
        return files
    }

    /// 見本の decode と同じ読み（16 bit PCM の WAV を / 32768）。
    private static let decodeWAV: ETSFZScriptDecode = { data in
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 44 else { throw ETSFZError(code: .prepare, message: "not a WAV") }
        let channels = u16(22), rate = u32(24)
        let frames = u32(40) / (channels * 2)
        var planes: [ETSFZPlane] = []
        for c in 0..<channels {
            let plane = ETSFZPlane(count: frames)
            for f in 0..<frames {
                plane.pointer[f] = Float(Int16(truncatingIfNeeded: u16(44 + (f * channels + c) * 2))) / 32768
            }
            planes.append(plane)
        }
        return ETSFZScriptPCM(channels: planes, sampleRate: rate)
    }

    private let geometry = ETSFZGeometry(sampleRate: 48000, processingChannels: 2, maxFrames: 512, minimumPhysicalBpm: 0, playerKind: 0)

    private func makeService(backend: MemoryBackend = MemoryBackend(), maxBytes: Int = 256 * 1024 * 1024, poolMode: ETSFZPoolMode,
                             estimate: ETSFZScriptEstimate? = nil, idleSeconds: TimeInterval = 30,
                             decode: ETSFZScriptDecode? = nil) throws -> ETSFZScriptService {
        ETSFZScriptService(backend: backend, decode: decode ?? Self.decodeWAV, estimate: estimate,
                           sources: try SFZScriptTestResources.sources(), maxBytes: maxBytes, poolMode: poolMode,
                           idleSeconds: idleSeconds, log: { _, _ in })
    }

    private func b64(_ data: Data) -> String { data.base64EncodedString() }

    /// .host の道: 制御部 + 0 のプールへ、受けた面を staging の位置（payload の 32 バイト目から数える float の位置）へ
    /// インターリーブで書き戻す。見本の payload と同じバイトになるはず。
    private func reassemble(_ prepared: ETSFZScriptPrepared) throws -> Data {
        var payload = prepared.control
        XCTAssertLessThanOrEqual(payload.count, prepared.payloadByteCount)
        payload.append(Data(count: prepared.payloadByteCount - payload.count))
        try payload.withUnsafeMutableBytes { raw in
            for entry in prepared.poolEntries {
                let channels = entry.planes.count
                for frame in 0..<entry.frames {
                    for (c, plane) in entry.planes.enumerated() {
                        let byte = 32 + 4 * (entry.floatOffset + frame * channels + c)
                        guard byte + 4 <= raw.count else { throw ETSFZError(code: .prepare, message: "pool write out of range") }
                        raw.storeBytes(of: plane.pointer[frame].bitPattern.littleEndian, toByteOffset: byte, as: UInt32.self)
                    }
                }
            }
        }
        return payload
    }

    private func expectedPayload(_ item: [String: Any]) throws -> String {
        let expected = try XCTUnwrap(item["expected"] as? [String: Any])
        let prepared = try XCTUnwrap(expected["prepared"] as? [String: Any])
        let payload = try XCTUnwrap(prepared["payload"] as? [String: Any])
        return try XCTUnwrap(payload["b64"] as? String)
    }

    private func warnings(_ value: Any?) -> [ETSFZScriptWarning] {
        ((value as? [[String: Any]]) ?? []).compactMap { entry in
            guard let code = entry["code"] as? String, let count = (entry["count"] as? NSNumber)?.intValue else { return nil }
            return ETSFZScriptWarning(code: code, count: count)
        }
    }

    // MARK: 見本の取り込み・読み直し

    /// 見本の imports（流し込みの道を要るものと SoundFont を除く）を、取り込み → 読み直しまで通して見本と比べる。
    private func runImports(poolMode: ETSFZPoolMode) async throws {
        var failures: [String] = []
        var compared = 0
        for item in try importCases() {
            let name = (item["name"] as? String) ?? "?"
            let selected = try XCTUnwrap(item["selected"] as? String)
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])
            // 流し込みと SoundFont は B6 以降・D2（ここでは SoundFont を一覧にも取り込みにも出さない）
            if selected.lowercased().hasSuffix(".sf2") || selected.lowercased().hasSuffix(".sf3") { continue }
            if (item["streamHost"] as? Bool) == true { continue }
            let backend = MemoryBackend()
            let estimates = EstimateLog()
            let service = try makeService(backend: backend, maxBytes: (item["maxBytes"] as? NSNumber)?.intValue ?? 256 * 1024 * 1024,
                                          poolMode: poolMode, estimate: estimates.record, idleSeconds: -1)
            let files = try writeFolder(try XCTUnwrap(item["folder"] as? [String: Any]))
            do {
                let entry = try await service.importFolder(files: files, selectedPath: selected)
                if let code = expected["error"] as? String {
                    failures.append("\(name): 失敗するはずが通った（\(code)）")
                    continue
                }
                let want = try XCTUnwrap(expected["entry"] as? [String: Any])
                if entry.id != want["id"] as? String { failures.append("\(name): id \(entry.id) != \(String(describing: want["id"]))") }
                if entry.name != want["name"] as? String { failures.append("\(name): name") }
                if entry.regionCount != (want["regionCount"] as? NSNumber)?.intValue { failures.append("\(name): regionCount") }
                if entry.size != (want["size"] as? NSNumber)?.intValue { failures.append("\(name): size") }
                if entry.fileCount != (want["fileCount"] as? NSNumber)?.intValue { failures.append("\(name): fileCount") }
                // 置き場に入ったバンクのバイト（上流が組んだ入れ物）
                let bank = try XCTUnwrap(expected["bank"] as? [String: Any])
                let stored = backend.snapshot()["\(entry.id).sfzbank"]
                if stored.map(b64) != bank["b64"] as? String { failures.append("\(name): bank のバイトが違う") }
                // index.json は上流の書き方のまま（version 1・entries）
                if let index = backend.snapshot()["index.json"],
                   let object = try JSONSerialization.jsonObject(with: index) as? [String: Any] {
                    if (object["version"] as? NSNumber)?.intValue != 1 { failures.append("\(name): index version") }
                } else { failures.append("\(name): index.json が無い") }

                // 一覧
                let listed = try await service.list()
                if listed.map(\.id) != [entry.id] { failures.append("\(name): list \(listed.map(\.id))") }

                // 読み直し（取り込みの payload とは別に、置き場から作り直す）。
                // 見本は取り込みの上限と別に、上限 256 MiB の新しいサービスで開き直している（sfz_runner.mjs の reprepare）
                let reopened = try XCTUnwrap(expected["reopened"] as? [String: Any])
                let reopenService = try makeService(backend: backend, maxBytes: 256 * 1024 * 1024,
                                                    poolMode: poolMode, estimate: estimates.record, idleSeconds: -1)
                if let code = reopened["error"] as? String {
                    do {
                        _ = try await reopenService.prepare(id: entry.id, geometry: geometry)
                        failures.append("\(name): 読み直しが失敗するはずが通った（\(code)）")
                    } catch let error as ETSFZError {
                        if error.code.rawValue != code && !["sample-integrity", "script-invalid"].contains(code) {
                            failures.append("\(name): 読み直しの code \(error.code.rawValue) != \(code)")
                        }
                    }
                    compared += 1
                    continue
                }
                let maybePrepared = try await reopenService.prepare(id: entry.id, geometry: geometry)
                let prepared = try XCTUnwrap(maybePrepared, "\(name): prepare が nil")
                let payloadB64 = try ((reopened["payload"] as? [String: Any])?["b64"] as? String) ?? expectedPayload(item)
                let bytes: Data
                switch poolMode {
                case .js:
                    bytes = prepared.control
                    if !prepared.poolEntries.isEmpty { failures.append("\(name): .js の道に書き手の面が出た") }
                case .host:
                    bytes = try reassemble(prepared)
                    // 制御部はプールの手前まで（payload 全体を JS から複写しない）
                    if prepared.control.count > prepared.payloadByteCount { failures.append("\(name): control が payload より長い") }
                }
                if b64(bytes) != payloadB64 { failures.append("\(name): payload のバイトが違う（\(poolMode)）") }
                if prepared.payloadByteCount != Data(base64Encoded: payloadB64)?.count { failures.append("\(name): payloadByteCount") }
                if prepared.tableVersion != (reopened["tableVersion"] as? NSNumber)?.intValue { failures.append("\(name): tableVersion") }
                if prepared.formatTag != (reopened["formatTag"] as? NSNumber)?.intValue { failures.append("\(name): formatTag") }
                if prepared.regionCount != (reopened["regionCount"] as? NSNumber)?.intValue { failures.append("\(name): regionCount(prepare)") }
                if prepared.sampleCount != (reopened["sampleCount"] as? NSNumber)?.intValue { failures.append("\(name): sampleCount") }
                if prepared.warnings != warnings(reopened["warnings"]) { failures.append("\(name): warnings \(prepared.warnings)") }
                if prepared.unsupportedOpcodes != (reopened["unsupportedOpcodes"] as? [String] ?? []) { failures.append("\(name): unsupportedOpcodes") }
                if prepared.unsupportedRuntime != (reopened["unsupportedRuntime"] as? [String] ?? []) { failures.append("\(name): unsupportedRuntime") }
                if prepared.incomplete != (reopened["incomplete"] as? Bool ?? false) { failures.append("\(name): incomplete") }
                if prepared.warmupSamples != (reopened["warmupSamples"] as? NSNumber)?.intValue { failures.append("\(name): warmupSamples") }
                if prepared.tailSeconds != (reopened["tailSeconds"] as? NSNumber)?.doubleValue { failures.append("\(name): tailSeconds") }
                if prepared.nativePreparationBytes != (reopened["nativePreparationBytes"] as? NSNumber)?.intValue { failures.append("\(name): nativePreparationBytes") }
                if prepared.footprintBytes != (reopened["footprintBytes"] as? NSNumber)?.intValue { failures.append("\(name): footprintBytes") }
                if prepared.processingChannels != (reopened["processingChannels"] as? NSNumber)?.intValue { failures.append("\(name): processingChannels") }
                // 見積りに渡った制御部は payload の頭（ETA1）と、payload 全体の大きさ
                if let call = estimates.calls.last {
                    if call.payloadBytes != prepared.payloadByteCount { failures.append("\(name): 見積りの payloadBytes") }
                    if call.control.prefix(4) != Data("ETA1".utf8) { failures.append("\(name): 見積りの制御部の頭") }
                    if call.geometry != geometry { failures.append("\(name): 見積りの geometry \(call.geometry)") }
                } else { failures.append("\(name): 見積りが呼ばれない") }
                // 画像
                if let presentation = reopened["presentation"] as? [String: Any],
                   let imageBytes = (presentation["imageBytes"] as? NSNumber)?.intValue {
                    if prepared.presentation?.imageData?.count != imageBytes { failures.append("\(name): imageBytes") }
                }
                compared += 1
            } catch let error as ETSFZError {
                guard let code = expected["error"] as? String else {
                    failures.append("\(name): 見本は通るのに \(error.code.rawValue): \(error.message)")
                    continue
                }
                let message = expected["message"] as? String
                // 上流の綴りのうち ETSFZErrorCode にあるものはそのまま、無いものは prepare（文は上流のまま）
                let mapped = ETSFZErrorCode(rawValue: code) ?? .prepare
                if error.code != mapped { failures.append("\(name): code \(error.code.rawValue) != \(mapped.rawValue)") }
                if let message, error.message != message { failures.append("\(name): message「\(error.message)」!=「\(message)」") }
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 20)
        XCTAssertTrue(failures.isEmpty, "見本と違う \(failures.count) 件:\n" + failures.joined(separator: "\n"))
    }

    func testImportsAndReopenMatchGoldenWithJSFilledPayload() async throws {
        try await runImports(poolMode: .js)
    }

    func testImportsAndReopenMatchGoldenWithHostPoolWriter() async throws {
        try await runImports(poolMode: .host)
    }

    // MARK: 操作

    private func pianoFolder() throws -> (files: [ETSFZScriptFile], entryID: String) {
        let item = try XCTUnwrap(try importCases().first { ($0["name"] as? String) == "plain" })
        let expected = try XCTUnwrap(item["expected"] as? [String: Any])
        let entry = try XCTUnwrap(expected["entry"] as? [String: Any])
        return (try writeFolder(try XCTUnwrap(item["folder"] as? [String: Any])), try XCTUnwrap(entry["id"] as? String))
    }

    func testListPrepareRemoveRoundTrip() async throws {
        let backend = MemoryBackend()
        let service = try makeService(backend: backend, poolMode: .js, idleSeconds: -1)
        let empty = try await service.list()
        XCTAssertEqual(empty, [])
        XCTAssertEqual(backend.cleanups, 1, "開くときに一時ファイルの掃除が 1 回")
        let folder = try pianoFolder()
        let entry = try await service.importFolder(files: folder.files, selectedPath: "piano.sfz")
        XCTAssertEqual(entry.id, folder.entryID)
        XCTAssertFalse(entry.streamedSource)
        XCTAssertNil(entry.format)
        let listed = try await service.list()
        XCTAssertEqual(listed.map(\.id), [entry.id])

        // 知らない id と形の違う id は nil
        let unknown = try await service.prepare(id: String(repeating: "0", count: 24))
        XCTAssertNil(unknown)
        let malformed = try await service.prepare(id: "../etc")
        XCTAssertNil(malformed)

        // geometry なしでも読める（カーネルの見積りは要らない）
        let plain = try await service.prepare(id: entry.id)
        XCTAssertNotNil(plain)
        XCTAssertNil(plain?.nativePreparationBytes)

        try await service.remove(id: entry.id)
        let after = try await service.list()
        XCTAssertEqual(after, [])
        XCTAssertNil(backend.snapshot()["\(entry.id).sfzbank"])
        let gone = try await service.prepare(id: entry.id)
        XCTAssertNil(gone)
    }

    func testResetReopensIndexWrittenOutsideJS() async throws {
        let backend = MemoryBackend()
        let service = try makeService(backend: backend, poolMode: .js, idleSeconds: -1)
        let folder = try pianoFolder()
        let entry = try await service.importFolder(files: folder.files, selectedPath: "piano.sfz")
        // 別の道具が index.json から件を消した（置き場を JS の外から書き換えた）
        backend.seed("index.json", Data(#"{"version":1,"entries":[]}"#.utf8))
        let stale = try await service.list()
        XCTAssertEqual(stale.map(\.id), [entry.id], "reset するまで JS は自分の一覧を見ている")
        try await service.reset()
        let fresh = try await service.list()
        XCTAssertEqual(fresh, [])
    }

    func testBrokenIndexReportsStorageError() async throws {
        let backend = MemoryBackend()
        backend.seed("index.json", Data("not json".utf8))
        let service = try makeService(backend: backend, poolMode: .js, idleSeconds: -1)
        do {
            _ = try await service.list()
            XCTFail("壊れた index.json が通った")
        } catch let error as ETSFZError {
            XCTAssertEqual(error.code, .storage)
            XCTAssertEqual(error.message, "The SFZ library could not be opened.")
        }
    }

    func testListInstrumentsKeepsOnlySFZ() async throws {
        let service = try makeService(poolMode: .js, idleSeconds: -1)
        let dummy = URL(fileURLWithPath: "/nonexistent")
        let files = ["a.sfz", "b/c.SFZ", "d.wav", "b/e.sfz", "f.sf2", "g/h.SF3", "i.sf2.txt"].map {
            ETSFZScriptFile(path: $0, url: dummy, size: 1)
        }
        let listed = try await service.listInstruments(in: files)
        // SoundFont は D2 まで出さない。上流の並べ替え（正規化済み）のまま
        XCTAssertEqual(listed, ["a.sfz", "b/c.SFZ", "b/e.sfz"])
    }

    func testSoundFontImportIsRefusedWithoutStartingJS() async throws {
        let service = try makeService(poolMode: .js, idleSeconds: -1)
        let dummy = URL(fileURLWithPath: "/nonexistent")
        for path in ["x.sf2", "dir/X.SF3"] {
            do {
                _ = try await service.importFolder(files: [ETSFZScriptFile(path: path, url: dummy, size: 1)], selectedPath: path)
                XCTFail("SoundFont の取り込みが通った")
            } catch let error as ETSFZError {
                XCTAssertEqual(error.code, .prepare)
            }
        }
        XCTAssertEqual(service.contextCount, 0, "断る前に JS の文脈を建てない")
    }

    func testContextIsLazyAndRebuiltAfterIdle() async throws {
        let service = try makeService(poolMode: .js, idleSeconds: 0.15)
        XCTAssertEqual(service.contextCount, 0)
        _ = try await service.list()
        XCTAssertEqual(service.contextCount, 1)
        try await Task.sleep(nanoseconds: 700_000_000)
        _ = try await service.list()
        XCTAssertEqual(service.contextCount, 2)
        service.shutdown()
        _ = try await service.list()
        XCTAssertEqual(service.contextCount, 3)
    }

    func testCancelledTokenStopsBeforeAnyWork() async throws {
        let service = try makeService(poolMode: .js, idleSeconds: -1)
        let token = ETSFZCancelToken()
        token.cancel()
        let folder = try pianoFolder()
        do {
            _ = try await service.importFolder(files: folder.files, selectedPath: "piano.sfz", cancel: token)
            XCTFail("取り消し済みの旗で取り込みが通った")
        } catch let error as ETSFZError {
            XCTAssertEqual(error.code, .cancelled)
        }
        let listed = try await service.list()
        XCTAssertEqual(listed, [], "取り消した取り込みは置き場に残らない")
    }

    func testCancellingTheTaskReachesTheScript() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        // 復号で止めて、その間に Task を取り消す。次に JS が isCurrent / requireCurrent を見て cancelled で終わる
        let decode: ETSFZScriptDecode = { data in
            started.signal()
            _ = gate.wait(timeout: .now() + 5)
            return try Self.decodeWAV(data)
        }
        let service = try makeService(poolMode: .js, idleSeconds: -1, decode: decode)
        let folder = try pianoFolder()
        let task = Task { try await service.importFolder(files: folder.files, selectedPath: "piano.sfz") }
        _ = started.wait(timeout: .now() + 5)
        task.cancel()
        gate.signal()
        do {
            _ = try await task.value
            // 上流が最後まで走り切ってしまった場合は、置き場に入って終わる。取り消しは「間に合えば」止める
        } catch let error as ETSFZError {
            XCTAssertEqual(error.code, .cancelled)
            let listed = try await service.list()
            XCTAssertEqual(listed, [])
        }
        gate.signal()
    }

    func testEstimateFailureKeepsUpstreamCodeAndText() async throws {
        let estimate: ETSFZScriptEstimate = { _, _, _, _ in
            throw ETSFZError(code: .tooLarge, message: "The instrument effects need more memory.")
        }
        let service = try makeService(poolMode: .js, estimate: estimate, idleSeconds: -1)
        let folder = try pianoFolder()
        let entry = try await service.importFolder(files: folder.files, selectedPath: "piano.sfz")
        do {
            _ = try await service.prepare(id: entry.id, geometry: geometry)
            XCTFail("見積りの失敗が伝わらない")
        } catch let error as ETSFZError {
            XCTAssertEqual(error.code, .tooLarge)
            XCTAssertEqual(error.message, "The instrument effects need more memory.")
        }
    }

    func testMissingEstimateHostFunctionFailsPrepareWithGeometry() async throws {
        let service = try makeService(poolMode: .js, estimate: nil, idleSeconds: -1)
        let folder = try pianoFolder()
        let entry = try await service.importFolder(files: folder.files, selectedPath: "piano.sfz")
        do {
            _ = try await service.prepare(id: entry.id, geometry: geometry)
            XCTFail("見積りの口が無いのに通った")
        } catch let error as ETSFZError {
            XCTAssertEqual(error.code, .prepare)
        }
        // geometry を渡さなければ見積りは要らない
        let bare = try await service.prepare(id: entry.id)
        XCTAssertNotNil(bare)
    }

    func testMissingScriptResourcesReportPrepareError() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/effetune-sfz.js")
        let service = ETSFZScriptService(backend: MemoryBackend(), decode: Self.decodeWAV,
                                         sources: ETSFZScriptSources(prelude: missing, bundle: missing), idleSeconds: -1, log: { _, _ in })
        do {
            _ = try await service.list()
            XCTFail("束ねが無いのに通った")
        } catch let error as ETSFZError {
            XCTAssertEqual(error.code, .prepare)
        }
    }

    func testDecodedPlanesAreReleasedAfterShutdown() async throws {
        final class Registry: @unchecked Sendable {
            private let lock = NSLock()
            private var planes: [Weak] = []
            struct Weak { weak var plane: ETSFZPlane? }
            func add(_ plane: ETSFZPlane) { lock.lock(); planes.append(Weak(plane: plane)); lock.unlock() }
            var alive: Int { lock.lock(); defer { lock.unlock() }; return planes.filter { $0.plane != nil }.count }
            var total: Int { lock.lock(); defer { lock.unlock() }; return planes.count }
        }
        let registry = Registry()
        let decode: ETSFZScriptDecode = { data in
            let pcm = try Self.decodeWAV(data)
            for plane in pcm.channels { registry.add(plane) }
            return pcm
        }
        let service = try makeService(poolMode: .host, idleSeconds: -1, decode: decode)
        let folder = try pianoFolder()
        // 取り込みの間は書き手が面を受けない（state.pool が nil）ので、結果は面を抱えない
        _ = try await service.importFolder(files: folder.files, selectedPath: "piano.sfz")
        XCTAssertGreaterThan(registry.total, 0)
        service.shutdown()
        let deadline = Date().addingTimeInterval(5)
        while registry.alive > 0 && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(registry.alive, 0, "復号した面が文脈を捨てても残っている")
    }

    func testHostPoolWriterDeliversPlanesWithoutCopyingIntoControl() async throws {
        let service = try makeService(poolMode: .host, estimate: EstimateLog().record, idleSeconds: -1)
        let folder = try pianoFolder()
        let entry = try await service.importFolder(files: folder.files, selectedPath: "piano.sfz")
        let maybePrepared = try await service.prepare(id: entry.id, geometry: geometry)
        let prepared = try XCTUnwrap(maybePrepared)
        // 常駐の bank（版 6・7）: 制御部はプールの手前まで、標本ごとに 1 区間
        XCTAssertTrue([6, 7].contains(prepared.tableVersion))
        XCTAssertLessThan(prepared.control.count, prepared.payloadByteCount)
        XCTAssertGreaterThan(prepared.poolEntries.count, 0)
        XCTAssertLessThanOrEqual(prepared.poolEntries.count, prepared.sampleCount ?? 0)
        for entry in prepared.poolEntries {
            XCTAssertGreaterThan(entry.frames, 0)
            XCTAssertTrue(entry.planes.allSatisfy { $0.count >= entry.frames })
            XCTAssertTrue((1...2).contains(entry.planes.count))
        }
        // 区間は重ならない（インターリーブ後の float の範囲）
        let ranges = prepared.poolEntries.map { $0.floatOffset..<($0.floatOffset + $0.frames * $0.planes.count) }
            .sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(ranges, ranges.dropFirst()) { XCTAssertLessThanOrEqual(a.upperBound, b.lowerBound) }
    }

    func testRepeatedPrepareStartsFromAFreshPoolEachTime() async throws {
        let service = try makeService(poolMode: .host, estimate: EstimateLog().record, idleSeconds: -1)
        let folder = try pianoFolder()
        let entry = try await service.importFolder(files: folder.files, selectedPath: "piano.sfz")
        let firstResult = try await service.prepare(id: entry.id, geometry: geometry)
        let secondResult = try await service.prepare(id: entry.id, geometry: geometry)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        // 上流の cache に当たると書き手が呼ばれず、プールの空の payload が返る。いつも作り直すので、区間は毎回出る
        XCTAssertEqual(first.poolEntries.count, second.poolEntries.count)
        XCTAssertGreaterThan(second.poolEntries.count, 0)
        XCTAssertEqual(first.control, second.control)
    }

    func testJapaneseAndEmbeddedNamesSurviveTheBoundary() async throws {
        // 名前・道は UTF-8 で JS を往復する。見本の windows-1252 の件が通っていることに加え、日本語の道でも取り込める
        let sfz = Data("<region> sample=音/ド.wav lokey=60 hikey=60 pitch_keycenter=60\n".utf8)
        let folderEntries: [String: Any] = [
            "楽器.sfz": ["text": String(decoding: sfz, as: UTF8.self)],
            "音/ド.wav": ["b64": try audio("a.wav").base64EncodedString()],
        ]
        let files = try writeFolder(folderEntries)
        let service = try makeService(poolMode: .js, idleSeconds: -1)
        let entry = try await service.importFolder(files: files, selectedPath: "楽器.sfz")
        XCTAssertEqual(entry.name, "楽器.sfz")
        XCTAssertEqual(entry.regionCount, 1)
        let prepared = try await service.prepare(id: entry.id)
        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.regionCount, 1)
    }
}

#endif
