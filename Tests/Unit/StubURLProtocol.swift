//  StubURLProtocol.swift
//  網へ出ずに URLSession を通すための代役（RemoteFileDownloadTests・ShareModelTests）。
//
//  URL ごとに返事（状態・本文・ヘッダ・飛ばされた先）を決めておき、来た頼みを順に覚える。
//  **決めていない URL は失敗で返す**（試験が知らないうちに網へ出ない）。fragment は送られないので、
//  突き合わせるときは落とす。Mac の URLSession と Linux の FoundationNetworking のどちらでも
//  protocolClasses に差せば使われる。
//
//  `holdOpen` を付けると本文を送り終えても閉じず、取り消されるのを待つ（終わりの無い本文の代わり）。
//  待ちきれなければ URLError(.timedOut) で閉じる。**本文を読み切ってから断る作りだと、そこで止まる。**

import Foundation

final class StubURLProtocol: URLProtocol {

    struct Reply {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        /// 応答に載せる URL（飛ばされた先）。nil なら頼まれた URL のまま。
        var finalURL: URL?
        /// 本文を送った後、閉じずに取り消しを待つ秒数。nil なら送ってすぐ閉じる。
        var holdOpen: TimeInterval?
    }

    private static let lock = NSLock()
    private static var routes: [String: Reply] = [:]
    private static var seen: [URLRequest] = []

    /// この代役だけを通す session。試験ごとに作り、終わったら invalidateAndCancel する。
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]
        seen = []
    }

    static func route(_ url: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        routes[key(URL(string: url)!)] = reply
    }

    /// 来た頼み（来た順）。
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static func key(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        comps.fragment = nil
        return comps.string ?? url.absoluteString
    }

    private static func take(_ request: URLRequest) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        seen.append(request)
        return request.url.flatMap { routes[key($0)] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.take(request),
              let response = HTTPURLResponse(url: reply.finalURL ?? url, statusCode: reply.status,
                                             httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        guard let wait = reply.holdOpen else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let me = Unchecked(value: self)
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
            let stub = me.value
            guard !stub.stopped else { return }
            stub.client?.urlProtocol(stub, didFailWithError: URLError(.timedOut))
        }
    }

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    /// 取り消された（task.cancel か session の片付け）。holdOpen の待ちはこれで閉じずに終わる。
    private let stopLock = NSLock()
    private var stopFlag = false
    private var stopped: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopFlag
    }

    override func stopLoading() {
        stopLock.lock(); defer { stopLock.unlock() }
        stopFlag = true
    }
}
