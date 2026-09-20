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
    /// 専用の画面はあるが、**図は描かないもの**。
    /// 畳んだときに「図だけ」の段を作れないので、開く↔畳むの 2 つになる。
    /// 増えたらここに足す。
    private static let withoutGraph: Set<String> = [
        "SpatialMapperPlugin",
        // 取り込む口と状態行だけ。曲線は IR が無いと描けない
        // （IRReverbView.swift の冒頭に理由がある）。
        "IRReverbPlugin",
        // 資産を送り込む 6 種。操作するのは設計の設定で、描く材料
        // （測定や設計した応答）はテレメトリでは来ない。
        "CrosstalkCancellationPlugin",
        "FIRCrossoverPlugin",
        "FiveBandFIRPEQPlugin",
        "GroupDelayEqPlugin",
        "GroupDelayPEQPlugin",
        "RoomEqPlugin",
        // 図を持たないのに「図だけ」の段を持たされていた 2 種。
        // その段は EffectCardView が allowsHitTesting(false) を丸ごと被せるので、
        // 升目もボタンも押せない板が全面に出るだけになる（しかも起動直後は
        // collapsedFully が空なので、一度も操作しなくてもその状態から始まる）。
        "MatrixPlugin",
        "OscillatorPlugin",
    ]

    /// 畳んだときに図だけを出せるか。
    static func hasGraph(_ type: String) -> Bool {
        has(type) && !withoutGraph.contains(type)
    }

    static func has(_ type: String) -> Bool { types.contains(type) }

    private static let types: Set<String> = [
        "PitchMeterPlugin",
        "SpatialMapperPlugin",
        "AutoLevelerPlugin",
        "ChannelDividerPlugin",
        "CompressorPlugin",
        "CrosstalkCancellationPlugin",
        "DynamicSaturationPlugin",
        "EarphoneCableSimPlugin",
        "ExpanderPlugin",
        "FifteenBandGEQPlugin",
        "FifteenBandPEQPlugin",
        "FIRCrossoverPlugin",
        "FiveBandDynamicEQ",
        "FiveBandFIRPEQPlugin",
        "FiveBandPEQPlugin",
        "GatePlugin",
        "GroupDelayEqPlugin",
        "GroupDelayPEQPlugin",
        "HardClippingPlugin",
        "HarmonicDistortionPlugin",
        "IRReverbPlugin",
        "LevelMeterPlugin",
        "MatrixPlugin",
        "MultibandSaturationPlugin",
        "ModalResonatorPlugin",
        "MultiChannelPanelPlugin",
        "MultibandTransientPlugin",
        "MultibandExpanderPlugin",
        "MultibandCompressorPlugin",
        "NoteSpectrogramPlugin",
        "OscillatorPlugin",
        "OscilloscopePlugin",
        "PhaseSelectEqPlugin",
        "PowerAmpSagPlugin",
        "RoomEqPlugin",
        "SaturationPlugin",
        "SpectrogramPlugin",
        "SpectrumAnalyzerPlugin",
        "StereoMeterPlugin",
        "SubSynthPlugin",
        "SWRadioSimulatorPlugin",
        "TubeSimulatorPlugin",
    ]

    /// 専用の画面を組み立てる。無ければ nil。
    @ViewBuilder
    static func view(index: Int, node: EffeTuneDSP.Node,
                     dsp: EffeTuneDSP) -> some View {
        switch node.spec.type {
        case "PitchMeterPlugin":
            PitchMeterView(index: index, node: node, dsp: dsp)
        case "SpatialMapperPlugin":
            SpatialMapperView(index: index, node: node, dsp: dsp)
        case "AutoLevelerPlugin":
            AutoLevelerView(index: index, node: node, dsp: dsp)
        case "ChannelDividerPlugin":
            ChannelDividerView(index: index, node: node, dsp: dsp)
        case "CompressorPlugin":
            CompressorView(index: index, node: node, dsp: dsp)
        case "CrosstalkCancellationPlugin":
            CrosstalkCancellationView(index: index, node: node, dsp: dsp)
        case "DynamicSaturationPlugin":
            DynamicSaturationView(index: index, node: node, dsp: dsp)
        case "EarphoneCableSimPlugin":
            EarphoneCableSimView(index: index, node: node, dsp: dsp)
        case "ExpanderPlugin":
            ExpanderView(index: index, node: node, dsp: dsp)
        case "FifteenBandGEQPlugin":
            FifteenBandGEQView(index: index, node: node, dsp: dsp)
        case "FifteenBandPEQPlugin":
            FifteenBandPEQView(index: index, node: node, dsp: dsp)
        case "FIRCrossoverPlugin":
            FIRCrossoverView(index: index, node: node, dsp: dsp)
        case "FiveBandDynamicEQ":
            FiveBandDynamicEQView(index: index, node: node, dsp: dsp)
        case "FiveBandFIRPEQPlugin":
            FiveBandFIRPEQView(index: index, node: node, dsp: dsp)
        case "FiveBandPEQPlugin":
            FiveBandPEQView(index: index, node: node, dsp: dsp)
        case "GatePlugin":
            GateView(index: index, node: node, dsp: dsp)
        case "GroupDelayEqPlugin":
            GroupDelayEQView(index: index, node: node, dsp: dsp)
        case "GroupDelayPEQPlugin":
            GroupDelayPEQView(index: index, node: node, dsp: dsp)
        case "HardClippingPlugin":
            HardClippingView(index: index, node: node, dsp: dsp)
        case "HarmonicDistortionPlugin":
            HarmonicDistortionView(index: index, node: node, dsp: dsp)
        case "IRReverbPlugin":
            IRReverbView(index: index, node: node, dsp: dsp)
        case "LevelMeterPlugin":
            LevelMeterView(index: index, node: node, dsp: dsp)
        case "MatrixPlugin":
            MatrixView(index: index, node: node, dsp: dsp)
        case "MultibandSaturationPlugin":
            MultibandSaturationView(index: index, node: node, dsp: dsp)
        case "ModalResonatorPlugin":
            ModalResonatorView(index: index, node: node, dsp: dsp)
        case "MultiChannelPanelPlugin":
            MultiChannelPanelView(index: index, node: node, dsp: dsp)
        case "MultibandTransientPlugin":
            MultibandTransientView(index: index, node: node, dsp: dsp)
        case "MultibandExpanderPlugin":
            MultibandExpanderView(index: index, node: node, dsp: dsp)
        case "MultibandCompressorPlugin":
            MultibandCompressorView(index: index, node: node, dsp: dsp)
        case "NoteSpectrogramPlugin":
            NoteSpectrogramView(index: index, node: node, dsp: dsp)
        case "OscillatorPlugin":
            OscillatorView(index: index, node: node, dsp: dsp)
        case "OscilloscopePlugin":
            OscilloscopeView(index: index, node: node, dsp: dsp)
        case "PhaseSelectEqPlugin":
            PhaseSelectEqView(index: index, node: node, dsp: dsp)
        case "PowerAmpSagPlugin":
            PowerAmpSagView(index: index, node: node, dsp: dsp)
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
        case "SubSynthPlugin":
            SubSynthView(index: index, node: node, dsp: dsp)
        case "SWRadioSimulatorPlugin":
            SWRadioSimulatorView(index: index, node: node, dsp: dsp)
        case "TubeSimulatorPlugin":
            TubeSimulatorView(index: index, node: node, dsp: dsp)
        default:
            EmptyView()
        }
    }
}
