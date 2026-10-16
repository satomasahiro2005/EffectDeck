//  VisualizerTap.swift
//  音の輪（ETMeterTap）をどこに向けるか。画面と Floating Meters が同じ輪を分け合うので、
//  誰かが使っているあいだだけ向け、全員が離れたら切る。ETMeterTap_SetPoint を呼ぶのはここだけ。
//
//  測る所（鎖の入口か出口）は ETVisualizerSettings.source で、変えると使っている全員が同時に切り替わる。
//  向け直したら解析（ETVisualizerAnalysis）の溜めを捨てる（前の所の音を流さない）。

import Combine
import Foundation
import os

@MainActor
final class ETVisualizerTap {

    static let shared = ETVisualizerTap()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "visualizer")
    private var holders = Set<ObjectIdentifier>()
    private var sourceSink: AnyCancellable?
    /// いま輪を向けている所。同じ所への向け直しで解析を白紙にしないために覚える。
    private var point = Int32(ET_METER_TAP_OFF)

    private init() {
        // 発行されるのは変わる前（willSet）なので、読み直さず渡された値を使う。
        sourceSink = ETVisualizerSettings.shared.$source.dropFirst().removeDuplicates().sink { [weak self] source in
            MainActor.assumeIsolated { self?.apply(source: source) }
        }
    }

    /// 使い始める。最初の 1 人で輪を向け、解析を白紙にする。
    func acquire(_ holder: AnyObject) {
        let wasEmpty = holders.isEmpty
        holders.insert(ObjectIdentifier(holder))
        // 空から増えたとき。apply が輪を向け、解析を白紙にする。
        if wasEmpty { apply(source: ETVisualizerSettings.shared.source) }
    }

    /// 使い終わる。最後の 1 人が離れたら輪を切る。
    func release(_ holder: AnyObject) {
        guard holders.remove(ObjectIdentifier(holder)) != nil, holders.isEmpty else { return }
        apply(source: ETVisualizerSettings.shared.source)
    }

    private func apply(source: ETVisualizerSource) {
        let wanted = holders.isEmpty ? Int32(ET_METER_TAP_OFF)
            : (source == .input ? Int32(ET_METER_TAP_INPUT) : Int32(ET_METER_TAP_OUTPUT))
        guard wanted != point else { return }
        point = wanted
        ETMeterTap_SetPoint(wanted)
        log.notice("meter tap point=\(wanted, privacy: .public) holders=\(self.holders.count, privacy: .public)")
        // 使っている最中に所が替わったら、前の所の音を捨てる。
        if !holders.isEmpty { ETVisualizerAnalysis.shared.reset() }
    }
}
