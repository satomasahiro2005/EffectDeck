//  ETChainNode.swift
//  鎖に並んでいる1個（元はEffeTuneDSP.Node）。
//
//  EffeTuneDSPの外へ出してあるのは、Foundationだけで試験のバンドルに入れるため。
//  EffeTuneDSPはosとet_*に触るので、Nodeが中にあるとNodeを使うものまで入れられない。
//  `EffeTuneDSP.Node` はこれの別名として残してあり、どちらで書いても同じ型。

import Foundation

/// 鎖に並んでいる 1 個。
struct ETChainNode: Identifiable {
    let id = UUID()
    let spec: ETEffect
    var values: [Float]
    var enabled: Bool = true
    /// Analyzer を図だけで見る。パラメータ行を畳む。
    var instance: UInt32 = 0
    /// 描画用の値がどのエフェクトから出たかを見分ける番号。
    var tapId: UInt32 = 0
    /// Section の名前（section.js の `cm`）。Section 以外では空。
    /// ETParam は float しか運べないので values には入れられない。
    var sectionName: String = ""
    /// IR Reverb が使っている素材の鍵（中身の sha256 先頭 24 桁）。
    /// IR Reverb 以外では空。sectionName と同じで、float に載らないので
    /// values ではなくここに持つ。上流のプリセットは `ir` という名前で書く
    /// （plugins/reverb/ir_reverb.js:866）。
    var irId: String = ""
    /// 音に関わらない表示の設定（上流の `cl` / `sc` など）。
    /// sectionName / irId と同じで float に載らないのでここに持つ。
    /// 綴りも値も上流のまま。DSP/DisplayParams.swift を読むこと。
    var display: [String: String] = [:]
    /// designerで作る型の設計の材料（上流の`pm` / `tp` / `f0`など）。
    /// displayと同じでfloatに載らないのでここに持つ。綴りも値も上流のまま。
    /// DSP/DesignParams.swiftを読むこと。
    var design: [String: String] = [:]
    /// 既定へ戻した回数（EffeTuneDSP.resetParams）。**保存しない。**
    /// 専用の画面は表示の設定（display）を現れたときにしか読まない（.etSaved）ので、
    /// カードはこれを画面の id に使い、戻したら作り直させる。
    var resetCount: Int = 0

    /// 音量に追従するカードの、キーフレームの一式（DSP/Automation.swift）。nil なら普通のカード。
    /// **持っている間は values が選んでいるキーフレームの値と同じ**で、画面が見せて直すのもそれ。
    /// 鳴らす値（キーフレームを音量で補間したもの）はここに入れない（EffeTuneDSP.pushParams が都度出す）。
    var automation: ETAutomation? = nil

    /// Native EffeTune nodeではない外部processor。instanceは持たず、
    /// publish時にexternal callback nodeへ変換する。
    var externalID: String? = nil
    /// AU component IDとは別の、チェーン上の1インスタンス固有ID。
    var externalInstanceID: String = ""
    /// AUAudioUnit.fullStateForDocument のアーカイブ。
    var externalState: Data? = nil
    var externalIndex: UInt8 = 0
    var isExternal: Bool { externalID != nil }

    // --- 鎖の形 ---
    // 普通の使い方では全部 0→0 の All なので、既定から外れたものだけ画面に出す。
    var inputBus: UInt8 = 0
    var outputBus: UInt8 = 0
    var channelSpec: Int8 = -1      // Stereo。EffeTune の既定に合わせてある
    var sectionGate: UInt8 = 1

    /// 上の Section で止められている。
    /// これは鎖の並びから publish のたびに引き直す値で、
    /// 人が触ったルーティングではない。だから isDefaultRouting とは別に持つ。
    var isGated: Bool { sectionGate == 0 }

    var isDefaultRouting: Bool {
        // sectionGate をここに入れない。
        // Section を切ると配下の gate が 0 になるので、
        // ルーティングを一切触っていない段にまで印が付き、
        // Routing に「Reset routing」が生えてしまう。
        // それを押しても gate は publish で引き直され、
        // 代わりに全段の bus / channel が既定へ戻る。
        inputBus == 0 && outputBus == 0 && channelSpec == -1
    }

    /// 音を触らない飾り。DSP の instance を持たない。
    var isSection: Bool { ETSection.isSection(spec) && !isRootReset }

    /// **組を抜けて root へ戻る印。**Section ではない。
    ///
    /// 名前も入切も持たず、行にも出ず、畳めもせず、DSP にも出ない。
    /// EffeTuneへ出す瞬間だけ`Section(cm: "")`に化ける（PipelineForm.swift）。
    /// こちらが書くものには印（ETSection.rootResetKey）を付け、読むときはそれだけを戻す。
    /// 外から来た空 Section をこれと推測してはいけない（PipelineAnalysis の頭）。
    var isRootReset: Bool = false

    /// 並びが持つ意味。派生値を出すのはこれだけを見る。
    var role: ETItemRole {
        if isRootReset { return .rootReset }
        return ETSection.isSection(spec) ? .section : .effect
    }

    /// 音が通る形になっているか。false のものは publish の filter で descriptor から
    /// 落ちるので、画面に並んでいても音は通らない。UI はこれを出して区別する。
    /// 保存せず instance から引くのは、片方だけ古くなるのを避けるため。
    ///
    /// Section は instance を持たないが死んでいるわけではない。カーネルが無いので
    /// et_instance_create は必ず 0 を返す（engine.cpp:314-365 の registry 引き）。
    /// 上流も Section を descriptor に入れない
    /// （js/audio/dsp-pipeline-descriptor.js:194-198 の continue）。
    var alive: Bool { isSection || instance != 0 }
}
