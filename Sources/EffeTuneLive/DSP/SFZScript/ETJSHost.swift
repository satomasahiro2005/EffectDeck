//  ETJSHost.swift
//  上流 js/sfz・js/sf2 の束ね（Resources/SFZ/effetune-sfz.js）を動かす JavaScriptCore の入れ物。
//
//  **公開の C API だけ**を使う（JSGlobalContextCreate・JSEvaluateScript・JSObjectMake*・JSObjectMakeTypedArrayWithBytesNoCopy・
//  JSObjectGetTypedArrayBytesPtr）。Objective-C の JSContext・JSScript・モジュールの読み込みは使わない
//  （モジュールの読み込みは公開 API でないので、束ねはクラシックスクリプト 1 本）。
//
//  - 文脈は 1 つ、専用のスレッド 1 本。JS に触るのはそのスレッドだけ（ETJSContext はスレッドを越えて渡さない）。
//  - 文脈は最初の仕事で建て、仕事のたびに JSGarbageCollect、しばらく仕事が来なければ捨てる（idleSeconds）。
//    256 MiB 級の取り込みのあとで、JS のヒープを抱えたまま居座らない。
//  - Promise は JSEvaluateScript が戻るときにマイクロタスクが掃かれる。await はそれと setTimeout の疑似（timer）を回して、
//    解決を待つ。何も動かせないのに解決しないときは「永久に待つ」代わりに誤りで返す。
//  - JS から Swift を呼ぶ関数は ETJSContext.makeFunction。呼ばれるのは同期で、同じスレッドの上。
//
//  SFZ の中身（取り込み・読み直し・バックエンド）はここに無い。ETSFZScriptService.swift。

#if canImport(JavaScriptCore)

import Foundation
import JavaScriptCore

// MARK: - 誤り

/// JS の例外。`code` は上流の sfzError が付ける綴り。主なものは prepare / too-large / no-regions / storage / cancelled。
/// ETSFZErrorCode に無い綴り（sample-integrity・script-invalid・source-changed・sample-lookup-limit・sample-format・invalid-sf2）は
/// 上に載せる側が prepare にし、文は上流のまま残す。
struct ETJSError: Error, CustomStringConvertible {
    var name: String
    var message: String
    var code: String?
    var stack: String?
    var description: String { code.map { "\(name)(\($0)): \(message)" } ?? "\(name): \(message)" }

    init(name: String = "Error", message: String, code: String? = nil, stack: String? = nil) {
        self.name = name
        self.message = message
        self.code = code
        self.stack = stack
    }
}

// MARK: - 文脈

/// JS から呼ばれる Swift の関数 1 本ぶん（JSClass の private データに入れる）。
private final class ETJSFunctionBox {
    weak var context: ETJSContext?
    let body: (ETJSContext, [JSValueRef]) throws -> JSValueRef?
    init(context: ETJSContext, body: @escaping (ETJSContext, [JSValueRef]) throws -> JSValueRef?) {
        self.context = context
        self.body = body
    }
}

private let etHostCall: JSObjectCallAsFunctionCallback = { ctx, function, _, argumentCount, arguments, exception in
    guard let function, let raw = JSObjectGetPrivate(function) else { return JSValueMakeUndefined(ctx) }
    let box = Unmanaged<ETJSFunctionBox>.fromOpaque(raw).takeUnretainedValue()
    guard let context = box.context else { return JSValueMakeUndefined(ctx) }
    var list: [JSValueRef] = []
    list.reserveCapacity(argumentCount)
    for index in 0..<argumentCount { if let value = arguments?[index] { list.append(value) } }
    do {
        return try box.body(context, list) ?? JSValueMakeUndefined(ctx)
    } catch {
        exception?.pointee = context.makeError(error)
        return JSValueMakeUndefined(ctx)
    }
}

private let etHostFinalize: JSObjectFinalizeCallback = { object in
    guard let object, let raw = JSObjectGetPrivate(object) else { return }
    Unmanaged<ETJSFunctionBox>.fromOpaque(raw).release()
}

/// 型付き配列の裏の領域を解放する口。JS の GC が呼ぶ（別のスレッドのことがある）ので、持ち物は retain で渡す。
private let etReleaseOwner: JSTypedArrayBytesDeallocator = { _, owner in
    if let owner { Unmanaged<AnyObject>.fromOpaque(owner).release() }
}

/// JS の 1 文脈。**建てたスレッドの上でだけ使う。**
final class ETJSContext {

    let ref: JSGlobalContextRef
    let global: JSObjectRef
    /// 上に載せる側（ETSFZScriptService）の持ち物。文脈と同じ寿命。
    var state: AnyObject?

    private var hostClass: JSClassRef?
    private var functionPrototype: JSValueRef?
    /// 仕事の終わりまで GC から守る値（await で受け取った解決値など）。
    private var retained: [JSValueRef] = []
    private var timers: [Int: (due: TimeInterval, function: JSObjectRef)] = [:]
    private var timerSerial = 0
    private var closed = false

    init() throws {
        guard let created = JSGlobalContextCreate(nil) else {
            throw ETJSError(message: "JavaScriptCore could not create a context.")
        }
        ref = created
        global = JSContextGetGlobalObject(created)
        var definition = kJSClassDefinitionEmpty
        definition.className = nil
        definition.callAsFunction = etHostCall
        definition.finalize = etHostFinalize
        hostClass = JSClassCreate(&definition)
        // 関数に call・bind も使えるよう、Function.prototype を継ぐ
        if let function = property(global, "Function"), let object = asObject(function) {
            functionPrototype = property(object, "prototype")
        }
    }

    /// 文脈を捨てる。待っていた timer と守っていた値も手放す。
    func close() {
        guard !closed else { return }
        closed = true
        endJob()
        for (_, timer) in timers { JSValueUnprotect(ref, timer.function) }
        timers.removeAll()
        state = nil
        JSGlobalContextRelease(ref)
        if let hostClass { JSClassRelease(hostClass) }
        hostClass = nil
    }

    deinit { close() }

    // MARK: 値の出し入れ

    func string(_ text: String) -> JSValueRef {
        let value = JSStringCreateWithUTF8CString(text)
        defer { JSStringRelease(value) }
        return JSValueMakeString(ref, value)
    }

    func number(_ value: Double) -> JSValueRef { JSValueMakeNumber(ref, value) }
    func boolean(_ value: Bool) -> JSValueRef { JSValueMakeBoolean(ref, value) }
    var undefined: JSValueRef { JSValueMakeUndefined(ref) }
    var null: JSValueRef { JSValueMakeNull(ref) }

    /// 値を文字列にする（JS の String(value)）。
    func text(of value: JSValueRef) -> String {
        guard let copy = JSValueToStringCopy(ref, value, nil) else { return "" }
        defer { JSStringRelease(copy) }
        let size = JSStringGetMaximumUTF8CStringSize(copy)
        var buffer = [CChar](repeating: 0, count: size)
        JSStringGetUTF8CString(copy, &buffer, size)
        return String(cString: buffer)
    }

    /// 数でなければ nil。
    func double(of value: JSValueRef) -> Double? {
        guard JSValueIsNumber(ref, value) else { return nil }
        return JSValueToNumber(ref, value, nil)
    }

    func int(of value: JSValueRef) -> Int? {
        guard let number = double(of: value), number.isFinite else { return nil }
        return Int(exactly: number.rounded(.towardZero))
    }

    func isNullish(_ value: JSValueRef) -> Bool { JSValueIsUndefined(ref, value) || JSValueIsNull(ref, value) }

    func asObject(_ value: JSValueRef) -> JSObjectRef? {
        guard JSValueIsObject(ref, value) else { return nil }
        return JSValueToObject(ref, value, nil)
    }

    func property(_ object: JSObjectRef, _ name: String) -> JSValueRef? {
        let key = JSStringCreateWithUTF8CString(name)
        defer { JSStringRelease(key) }
        var exception: JSValueRef?
        let value = JSObjectGetProperty(ref, object, key, &exception)
        return exception == nil ? value : nil
    }

    func setProperty(_ object: JSObjectRef, _ name: String, _ value: JSValueRef) {
        let key = JSStringCreateWithUTF8CString(name)
        defer { JSStringRelease(key) }
        JSObjectSetProperty(ref, object, key, value, JSPropertyAttributes(kJSPropertyAttributeNone), nil)
    }

    func element(_ array: JSObjectRef, _ index: Int) -> JSValueRef? {
        var exception: JSValueRef?
        let value = JSObjectGetPropertyAtIndex(ref, array, UInt32(index), &exception)
        return exception == nil ? value : nil
    }

    func makeObject() -> JSObjectRef { JSObjectMake(ref, nil, nil) }

    /// 値を仕事の終わりまで GC から守って、そのまま返す。
    /// **Swift の配列などヒープに置く値は、JSC の GC が（スタックとレジスタしか見ないので）見つけられない。**
    /// 次の JS の確保より前に、これで守る。
    /// JSObjectRef も Swift では同じ OpaquePointer なので、この一つで両方を受ける。
    @discardableResult
    func keep(_ value: JSValueRef) -> JSValueRef {
        JSValueProtect(ref, value)
        retained.append(value)
        return value
    }

    /// 守られた文字列。引数の配列に入れて呼ぶ前に作る値に使う。
    func keptString(_ text: String) -> JSValueRef { keep(string(text)) }

    func makeArray(_ values: [JSValueRef]) -> JSObjectRef {
        let optional: [JSValueRef?] = values
        return optional.withUnsafeBufferPointer { JSObjectMakeArray(ref, optional.count, $0.baseAddress, nil) }
    }

    /// JS の Error。code を持つ（上流の sfzError と同じ形）。
    func makeError(message: String, code: String? = nil, name: String? = nil) -> JSObjectRef {
        let arguments: [JSValueRef?] = [string(message)]
        let error = arguments.withUnsafeBufferPointer { JSObjectMakeError(ref, 1, $0.baseAddress, nil) }
        guard let error else { return makeObject() }
        if let code { setProperty(error, "code", string(code)) }
        if let name { setProperty(error, "name", string(name)) }
        return error
    }

    /// Swift の誤りを JS の例外にする。ETJSError は code ごと、それ以外は message だけ。
    func makeError(_ error: Error) -> JSValueRef {
        if let error = error as? ETJSError { return makeError(message: error.message, code: error.code, name: error.name) }
        if let error = error as? ETJSCodedError { return makeError(message: error.jsMessage, code: error.jsCode) }
        return makeError(message: String(describing: error))
    }

    /// 例外の値から ETJSError を作る。
    func error(from exception: JSValueRef) -> ETJSError {
        guard let object = asObject(exception) else { return ETJSError(message: text(of: exception)) }
        func field(_ name: String) -> String? {
            guard let value = property(object, name), JSValueIsString(ref, value) else { return nil }
            return text(of: value)
        }
        return ETJSError(name: field("name") ?? "Error", message: field("message") ?? text(of: exception),
                         code: field("code"), stack: field("stack"))
    }

    // MARK: 関数

    /// JS から呼べる関数。body は呼ばれたスレッド（= この文脈のスレッド）で同期に走る。
    /// body が throw すると、その誤りが JS の例外になる。
    func makeFunction(_ body: @escaping (ETJSContext, [JSValueRef]) throws -> JSValueRef?) -> JSObjectRef {
        let box = ETJSFunctionBox(context: self, body: body)
        let object = JSObjectMake(ref, hostClass, Unmanaged.passRetained(box).toOpaque())!
        if let functionPrototype { JSObjectSetPrototype(ref, object, functionPrototype) }
        return object
    }

    func install(_ name: String, on object: JSObjectRef, _ body: @escaping (ETJSContext, [JSValueRef]) throws -> JSValueRef?) {
        setProperty(object, name, makeFunction(body))
    }

    /// 関数を呼ぶ。JS の例外は ETJSError で投げる。
    @discardableResult
    func call(_ function: JSObjectRef, this: JSObjectRef? = nil, _ arguments: [JSValueRef] = []) throws -> JSValueRef {
        var exception: JSValueRef?
        let optional: [JSValueRef?] = arguments
        let result = optional.withUnsafeBufferPointer {
            JSObjectCallAsFunction(ref, function, this, optional.count, $0.baseAddress, &exception)
        }
        if let exception { throw error(from: exception) }
        return result ?? undefined
    }

    /// global の名前の関数を呼ぶ（`__etSfz.prepare` のように、object の下の関数は method で）。
    func callMethod(_ object: JSObjectRef, _ name: String, _ arguments: [JSValueRef] = []) throws -> JSValueRef {
        guard let value = property(object, name), let function = asObject(value), JSObjectIsFunction(ref, function) else {
            throw ETJSError(name: "TypeError", message: "\(name) is not a function")
        }
        return try call(function, this: object, arguments)
    }

    /// スクリプトを評価する。url はスタックの表示用。
    @discardableResult
    func evaluate(_ source: String, url: String) throws -> JSValueRef {
        var exception: JSValueRef?
        let script = JSStringCreateWithUTF8CString(source)
        let name = JSStringCreateWithUTF8CString(url)
        defer { JSStringRelease(script); JSStringRelease(name) }
        let result = JSEvaluateScript(ref, script, nil, name, 1, &exception)
        if let exception { throw error(from: exception) }
        return result ?? undefined
    }

    // MARK: 型付き配列

    /// 新しい Uint8Array（JS のヒープの上）。書き込み先の領域も返す。
    func makeUint8Array(length: Int) throws -> (array: JSObjectRef, bytes: UnsafeMutableRawBufferPointer) {
        var exception: JSValueRef?
        guard let array = JSObjectMakeTypedArray(ref, kJSTypedArrayTypeUint8Array, length, &exception), exception == nil else {
            throw ETJSError(name: "RangeError", message: "A byte array of \(length) bytes could not be allocated.")
        }
        return (array, UnsafeMutableRawBufferPointer(start: bytesStart(of: array), count: length))
    }

    func makeUint8Array(copying data: Data) throws -> JSObjectRef {
        let made = try makeUint8Array(length: data.count)
        if let base = made.bytes.baseAddress, !data.isEmpty { data.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), count: data.count) }
        return made.array
    }

    /// 複写せず、owner の持つ領域を Float32Array として見せる。JS が手放すまで owner を retain する。
    func makeFloat32Array(pointer: UnsafeMutablePointer<Float>, count: Int, owner: AnyObject) throws -> JSObjectRef {
        var exception: JSValueRef?
        let retainedOwner = Unmanaged.passRetained(owner).toOpaque()
        guard let array = JSObjectMakeTypedArrayWithBytesNoCopy(ref, kJSTypedArrayTypeFloat32Array, pointer,
                                                                count * MemoryLayout<Float>.stride, etReleaseOwner,
                                                                retainedOwner, &exception), exception == nil else {
            Unmanaged<AnyObject>.fromOpaque(retainedOwner).release()
            throw ETJSError(name: "RangeError", message: "A float array could not be created.")
        }
        return array
    }

    func makeArrayBuffer(copying data: Data) throws -> JSObjectRef {
        let array = try makeUint8Array(copying: data)
        guard let buffer = property(array, "buffer"), let object = asObject(buffer) else {
            throw ETJSError(message: "An ArrayBuffer could not be created.")
        }
        return object
    }

    /// 型付き配列の、見ている範囲の先頭（byteOffset を足した位置）。
    private func bytesStart(of array: JSObjectRef) -> UnsafeMutableRawPointer? {
        guard let base = JSObjectGetTypedArrayBytesPtr(ref, array, nil) else { return nil }
        return base + JSObjectGetTypedArrayByteOffset(ref, array, nil)
    }

    /// ArrayBuffer か型付き配列（DataView は含まない）の、見ている範囲。**GC が走るまでの一時的な窓。**
    func byteWindow(of value: JSValueRef) -> UnsafeMutableRawBufferPointer? {
        guard let object = asObject(value) else { return nil }
        let type = JSValueGetTypedArrayType(ref, value, nil)
        if type == kJSTypedArrayTypeNone { return nil }
        if type == kJSTypedArrayTypeArrayBuffer {
            let count = JSObjectGetArrayBufferByteLength(ref, object, nil)
            return UnsafeMutableRawBufferPointer(start: JSObjectGetArrayBufferBytesPtr(ref, object, nil), count: count)
        }
        return UnsafeMutableRawBufferPointer(start: bytesStart(of: object), count: JSObjectGetTypedArrayByteLength(ref, object, nil))
    }

    func isFloat32Array(_ value: JSValueRef) -> Bool { JSValueGetTypedArrayType(ref, value, nil) == kJSTypedArrayTypeFloat32Array }

    // MARK: タイマーと Promise

    /// setTimeout の代わり（prelude の __et.timer / __et.cancelTimer）。待つのは await の中だけ。
    func installTimers(on host: JSObjectRef) {
        install("timer", on: host) { context, arguments in
            guard let first = arguments.first, let function = context.asObject(first), JSObjectIsFunction(context.ref, function) else {
                throw ETJSError(name: "TypeError", message: "The timer callback must be a function.")
            }
            let delay = max(arguments.count > 1 ? (context.double(of: arguments[1]) ?? 0) : 0, 0) / 1000
            JSValueProtect(context.ref, function)
            context.timerSerial += 1
            context.timers[context.timerSerial] = (ProcessInfo.processInfo.systemUptime + delay, function)
            return context.number(Double(context.timerSerial))
        }
        install("cancelTimer", on: host) { context, arguments in
            if let id = arguments.first.flatMap({ context.int(of: $0) }), let timer = context.timers.removeValue(forKey: id) {
                JSValueUnprotect(context.ref, timer.function)
            }
            return nil
        }
    }

    /// マイクロタスクを掃く。評価を 1 回通せば、積まれた Promise の続きは全部走る。
    func drainMicrotasks() {
        var exception: JSValueRef?
        let script = JSStringCreateWithUTF8CString("0")
        defer { JSStringRelease(script) }
        _ = JSEvaluateScript(ref, script, nil, nil, 1, &exception)
    }

    /// done が真になるまで、マイクロタスクと timer を回す。動かすものが無いのに終わらなければ投げる。
    func pump(until done: () -> Bool) throws {
        while true {
            drainMicrotasks()
            if done() { return }
            guard let next = timers.min(by: { $0.value.due < $1.value.due }) else {
                throw ETJSError(message: "The script is waiting for an event that never arrives.")
            }
            let wait = next.value.due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            timers.removeValue(forKey: next.key)
            defer { JSValueUnprotect(ref, next.value.function) }
            // timer の中の誤りは、そのタイマーを待っていた側が見る（ここでは先へ進める）
            _ = try? call(next.value.function)
        }
    }

    /// Promise（then を持つ値）が解決するまで待ち、解決値を返す。拒否されたら ETJSError。then を持たなければそのまま返す。
    func awaitPromise(_ value: JSValueRef) throws -> JSValueRef {
        guard let object = asObject(value), let then = property(object, "then"), let thenFunction = asObject(then),
              JSObjectIsFunction(ref, thenFunction) else { return value }
        final class Outcome { var done = false; var value: JSValueRef?; var rejected = false }
        let outcome = Outcome()
        let settle: (Bool) -> (ETJSContext, [JSValueRef]) throws -> JSValueRef? = { rejected in
            { context, arguments in
                outcome.done = true
                outcome.rejected = rejected
                if let first = arguments.first {
                    JSValueProtect(context.ref, first)
                    context.retained.append(first)
                    outcome.value = first
                }
                return nil
            }
        }
        try call(thenFunction, this: object, [keep(makeFunction(settle(false))), keep(makeFunction(settle(true)))])
        try pump { outcome.done }
        let result = outcome.value ?? undefined
        if outcome.rejected { throw error(from: result) }
        return result
    }

    /// 仕事の終わり。守っていた値を手放して GC する。
    func endJob() {
        for value in retained { JSValueUnprotect(ref, value) }
        retained.removeAll()
        if !closed { JSGarbageCollect(ref) }
    }
}

/// message と code を JS の例外へそのまま渡したい Swift の誤り（ETSFZError など）が従う。
protocol ETJSCodedError: Error {
    var jsMessage: String { get }
    var jsCode: String? { get }
}

// MARK: - スレッドと文脈の持ち主

/// 仕事を 1 本ずつ順に走らせる専用スレッド。JSC は自分の再帰の深さを見て止まるので、
/// 既定より大きいスタックを取る（上流の取り込みの再帰が、素のスレッドで先に尽きないように）。
private final class ETJSThread: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var idleDeadline: Date?
    private var onIdle: (() -> Void)?
    private var stopping = false

    init(name: String, stackSize: Int = 16 << 20) {
        let thread = Thread { [self] in self.loop() }
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        idleDeadline = nil
        condition.signal()
        condition.unlock()
    }

    /// 次の仕事が来ないまま at を過ぎたら handler を 1 回呼ぶ（スレッドの上で）。
    func armIdle(at date: Date, handler: @escaping () -> Void) {
        condition.lock()
        idleDeadline = date
        onIdle = handler
        condition.signal()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopping = true
        condition.signal()
        condition.unlock()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty && !stopping {
                if let deadline = idleDeadline {
                    if !condition.wait(until: deadline) || Date() >= deadline {
                        let handler = onIdle
                        idleDeadline = nil
                        onIdle = nil
                        condition.unlock()
                        handler?()
                        condition.lock()
                    }
                } else {
                    condition.wait()
                }
            }
            if jobs.isEmpty && stopping { condition.unlock(); return }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}

/// 文脈を遅く建て、仕事の合間に捨てる持ち主。
final class ETJSHost: @unchecked Sendable {

    private let thread: ETJSThread
    private let setup: (ETJSContext) throws -> Void
    private let idleSeconds: TimeInterval
    /// JS のスレッドの上でだけ触る。
    private var context: ETJSContext?
    /// 文脈を建てた回数（試験が「捨てて建て直した」ことを見る）。
    private(set) var contextCount = 0

    /// setup は文脈を建てた直後に呼ぶ（ホストの関数を置き、プレリュードと束ねを評価する）。
    /// 投げたら文脈は捨てて、その仕事が失敗する。
    init(name: String = "ai.nemut.effetune.sfzjs", idleSeconds: TimeInterval = 30,
         setup: @escaping (ETJSContext) throws -> Void) {
        thread = ETJSThread(name: name)
        self.idleSeconds = idleSeconds
        self.setup = setup
    }

    deinit { thread.stop() }

    /// 仕事を JS のスレッドで走らせて、結果を待つ。仕事の中で ETJSContext を使う。
    func run<T>(_ work: @escaping (ETJSContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            thread.enqueue { [self] in
                do {
                    let context = try acquire()
                    defer { context.endJob() }
                    continuation.resume(returning: try work(context))
                } catch {
                    continuation.resume(throwing: error)
                }
                if idleSeconds >= 0 {
                    thread.armIdle(at: Date().addingTimeInterval(idleSeconds)) { [weak self] in self?.dropContext() }
                }
            }
        }
    }

    /// 文脈を今すぐ捨てる（メモリ警告など）。走っている仕事があればその後で。
    func drop() {
        thread.enqueue { [self] in dropContext() }
    }

    private func acquire() throws -> ETJSContext {
        if let context { return context }
        let created = try ETJSContext()
        contextCount += 1
        do { try setup(created) } catch {
            created.close()
            throw error
        }
        context = created
        return created
    }

    private func dropContext() {
        context?.close()
        context = nil
    }
}

#endif
