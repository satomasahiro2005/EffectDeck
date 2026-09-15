//  EffectViews.swift
//  型名から専用の画面へ繋ぐ一覧。
//
//  ここに載っていないエフェクトは、params.json から生成した汎用の
//  スライダーがそのまま出る。専用の画面があるのは、web 版が
//  グラフや図で操作させているものだけ。

import SwiftUI

@MainActor
enum ETEffectViews {

    /// 専用の画面を持っているか。
    static func has(_ type: String) -> Bool { types.contains(type) }

    private static let types: Set<String> = [
        "CompressorPlugin",
        "DynamicSaturationPlugin",
        "EarphoneCableSimPlugin",
        "ExpanderPlugin",
        "FifteenBandPEQPlugin",
        "FiveBandDynamicEQ",
        "FiveBandFIRPEQPlugin",
        "FiveBandPEQPlugin",
        "GatePlugin",
        "GroupDelayPEQPlugin",
        "HardClippingPlugin",
        "HarmonicDistortionPlugin",
        "LevelMeterPlugin",
        "MultiChannelPanelPlugin",
        "NoteSpectrogramPlugin",
        "OscilloscopePlugin",
        "PhaseSelectEqPlugin",
        "RoomEqPlugin",
        "SaturationPlugin",
        "SpectrogramPlugin",
        "SpectrumAnalyzerPlugin",
        "StereoMeterPlugin",
        "TubeSimulatorPlugin",
    ]

    /// 専用の画面を組み立てる。無ければ nil。
    @ViewBuilder
    static func view(index: Int, node: EffeTuneDSP.Node,
                     dsp: EffeTuneDSP) -> some View {
        switch node.spec.type {
        case "CompressorPlugin":
            CompressorView(index: index, node: node, dsp: dsp)
        case "DynamicSaturationPlugin":
            DynamicSaturationView(index: index, node: node, dsp: dsp)
        case "EarphoneCableSimPlugin":
            EarphoneCableSimView(index: index, node: node, dsp: dsp)
        case "ExpanderPlugin":
            ExpanderView(index: index, node: node, dsp: dsp)
        case "FifteenBandPEQPlugin":
            FifteenBandPEQView(index: index, node: node, dsp: dsp)
        case "FiveBandDynamicEQ":
            FiveBandDynamicEQView(index: index, node: node, dsp: dsp)
        case "FiveBandFIRPEQPlugin":
            FiveBandFIRPEQView(index: index, node: node, dsp: dsp)
        case "FiveBandPEQPlugin":
            FiveBandPEQView(index: index, node: node, dsp: dsp)
        case "GatePlugin":
            GateView(index: index, node: node, dsp: dsp)
        case "GroupDelayPEQPlugin":
            GroupDelayPEQView(index: index, node: node, dsp: dsp)
        case "HardClippingPlugin":
            HardClippingView(index: index, node: node, dsp: dsp)
        case "HarmonicDistortionPlugin":
            HarmonicDistortionView(index: index, node: node, dsp: dsp)
        case "LevelMeterPlugin":
            LevelMeterView(index: index, node: node, dsp: dsp)
        case "MultiChannelPanelPlugin":
            MultiChannelPanelView(index: index, node: node, dsp: dsp)
        case "NoteSpectrogramPlugin":
            NoteSpectrogramView(index: index, node: node, dsp: dsp)
        case "OscilloscopePlugin":
            OscilloscopeView(index: index, node: node, dsp: dsp)
        case "PhaseSelectEqPlugin":
            PhaseSelectEqView(index: index, node: node, dsp: dsp)
        case "RoomEqPlugin":
            RoomEQView(index: index, node: node, dsp: dsp)
        case "SaturationPlugin":
            SaturationView(index: index, node: node, dsp: dsp)
        case "SpectrogramPlugin":
            SpectrogramView(index: index, node: node, dsp: dsp)
        case "SpectrumAnalyzerPlugin":
            SpectrumAnalyzerView(index: index, node: node, dsp: dsp)
        case "StereoMeterPlugin":
            StereoMeterView(index: index, node: node, dsp: dsp)
        case "TubeSimulatorPlugin":
            TubeSimulatorView(index: index, node: node, dsp: dsp)
        default:
            EmptyView()
        }
    }
}
