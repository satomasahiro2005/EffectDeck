//  LocalEndpoint.swift
//  MediaOutputDevice が要求する requiredNetworkEndpoints を本物で埋めるための小さな listener。
//
//  なぜ要るか:
//    MediaOutputDevice.init? は requiredNetworkEndpoints が必須引数で、
//    init 自体が failable。txtRecords が NWTXTRecord（Bonjour）で、
//    DeviceType も hifiSpeaker / tv / mediaStick … と全部「外部の機器」。
//    つまりこの API はネットワーク上の受信機を想定していて、
//    ローカル完結のデバイスは想定外の可能性が高い。
//
//  そこで、ダミーのループバックではなく**実際に listen しているソケット**を用意し、
//  その実エンドポイントを渡す。音はここを通さない（AudioServerPlugIn 経由で来る）。
//  システムの帳簿上「実在して到達可能な受信機」に見せるためだけのもの。
//
//  これでも弾かれるなら、この API がローカルを明示的に拒否しているということ。

import Foundation
import Network
import os

@available(iOS 27.0, *)
final class LocalEndpoint {

    static let shared = LocalEndpoint()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "endpoint")
    private var listener: NWListener?
    private(set) var port: NWEndpoint.Port?

    private init() {}

    /// listener を立てて、実際に割り当てられたポートを返す。
    /// 立てられなければ nil。
    @discardableResult
    func start() -> NWEndpoint.Port? {
        if let p = port { return p }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // ローカルのみで待つ。外から繋がれる必要は無い。
            params.requiredInterfaceType = .loopback
            let l = try NWListener(using: params, on: .any)
            l.newConnectionHandler = { conn in
                // 誰も繋いでこない前提。来ても即切る。
                conn.cancel()
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = l.port
                    self.log.info("listener ready port=\(l.port?.rawValue ?? 0)")
                case .failed(let e):
                    self.log.error("listener failed: \(e.localizedDescription)")
                default:
                    break
                }
            }
            l.start(queue: .global(qos: .utility))
            listener = l

            // ポートが確定するまで少しだけ待つ。
            let deadline = Date().addingTimeInterval(1.0)
            while port == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if port == nil { log.error("ポートが確定しなかった") }
            return port
        } catch {
            log.error("NWListener を作れない: \(error.localizedDescription)")
            return nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    /// MediaOutputDevice に渡すエンドポイント。
    /// 実 listener が立っていればそのポート、駄目ならループバックの 0 番で最後の望みを賭ける。
    func endpoints() -> [NWEndpoint] {
        if let p = start() {
            return [.hostPort(host: .ipv4(.loopback), port: p)]
        }
        return [.hostPort(host: .ipv4(.loopback), port: .any)]
    }
}
