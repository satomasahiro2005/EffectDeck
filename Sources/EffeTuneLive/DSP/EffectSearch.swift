//  EffectSearch.swift
//  エフェクトピッカーの検索の順位。Foundationだけ（EffectSearchTests）。
//
//  以前は「名前への当たり方 → 名前順」だけだった。すると "EQ" で
//  5Band Dynamic EQ や Group Delay EQ が 15Band PEQ より上に出た。
//  名前順は「よく使われる順」とは関係が無い。
//
//  **よく使われる順は計算で出さず、手で決めた表（curated）で持つ。**
//  使用回数を取る手もあるが、このアプリは計測を持たない方針で、
//  初めて使う人にこそ定番が上に要る。
//  あわせて、名前に無い呼び名（"snail"・"verb"・"echo"）でも見つかるよう、
//  エフェクトごとの別名（aliases）も手で持つ。
//
//  どちらも鍵は ETEffect.type。カタログに無い型を書いても落ちないが、
//  EffectSearchTests が「全部カタログに居ること」を見るので、
//  上流で型が消えたり名前が替わったら、そこで気づく。

import Foundation

enum ETEffectSearch {

    // MARK: - 当たり方

    /// 当たり方。**強い順**。生の値の小ささがそのまま強さになる。
    enum Hit: Int, Comparable {
        /// 名前がそのもの。
        case exact = 0
        /// 名前の頭から。
        case prefix = 1
        /// 名前の中の、語の頭から（"Band" が "5Band PEQ" に当たる）。
        /// "EQ" が "PEQ"・"GEQ" に当たるのもここ（略語の規則）。
        case word = 2
        /// 別名から。名前の語の頭と同じくらい確かなので、名前の「どこか」より上に置く。
        case alias = 3
        /// 名前のどこか。
        case inside = 4
        /// 名前ではない所（作者・分類・説明）。
        case elsewhere = 5

        static func < (a: Hit, b: Hit) -> Bool { a.rawValue < b.rawValue }
    }

    /// 打った字の整え方。前後の空白を落として小文字にする。
    /// 空白が付いたままだと "eq " が何にも当たらなくなる。
    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 名前を語に割る。区切りは空白と括弧・ハイフンなど名前に出るもの。
    /// **数字から字に変わる所でも割る**（"15Band" の Band を語の頭にする）。
    /// 大文字小文字は残す（略語の判定が要る）。
    static func words(_ name: String) -> [String] {
        let separators = CharacterSet(charactersIn: " -_/()[]")
        var out: [String] = []
        var cur = ""
        var prevDigit = false
        for ch in name {
            let scalarIsSeparator = ch.unicodeScalars.allSatisfy { separators.contains($0) }
            if scalarIsSeparator {
                if !cur.isEmpty { out.append(cur); cur = "" }
                prevDigit = false
                continue
            }
            let isDigit = ch.isNumber
            if prevDigit && !isDigit && !cur.isEmpty {
                out.append(cur); cur = ""
            }
            cur.append(ch)
            prevDigit = isDigit
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 略語の語が、打った字で終わるか。"PEQ"・"GEQ" に "eq" が当たる。
    /// **余る頭が 1 字のときだけ**。"GSM" に "sm" が当たるような偶然を入れない。
    /// 略語は全部大文字の 3 字以上の語（"FIR"・"PEQ"）。
    private static func acronymEnds(_ word: String, with q: String) -> Bool {
        guard q.count >= 2, word.count == q.count + 1, word.count >= 3 else { return false }
        guard word.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return false }
        return word.lowercased().hasSuffix(q)
    }

    /// 名前に対する当たり方。当たらなければ nil。q は normalize 済み。
    /// 別名は見ない（エフェクト以外にも使うため）。
    static func nameHit(_ name: String, _ q: String) -> Hit? {
        let n = name.lowercased()
        guard !q.isEmpty else { return .inside }
        if n == q { return .exact }
        if n.hasPrefix(q) { return .prefix }

        let ws = words(name)
        // 語の頭か。打った字が複数の語にまたがっても（"band peq"）当たるよう、
        // 語を 1 つの空白で繋ぎ直した形に対して、頭か「空白の直後」を見る。
        let joined = ws.map { $0.lowercased() }.joined(separator: " ")
        let qJoined = words(q).joined(separator: " ")
        if !qJoined.isEmpty, joined.hasPrefix(qJoined) || joined.contains(" " + qJoined) {
            return .word
        }
        if ws.contains(where: { acronymEnds($0, with: q) }) { return .word }
        return n.contains(q) ? .inside : nil
    }

    /// エフェクトへの当たり方。名前・別名・説明と分類を見て、一番強いもの。
    static func effectHit(_ e: ETEffect, _ q: String) -> Hit? {
        let byName = nameHit(e.name, q)
        // 別名は名前より強いときだけ採る。名前が語の頭以上で当たっていれば名前のまま。
        if !q.isEmpty, let byAlias = aliasHit(e.type, q), byName.map({ byAlias < $0 }) ?? true {
            return byAlias
        }
        if let byName { return byName }
        if e.about.lowercased().contains(q) || e.category.lowercased().contains(q) {
            return .elsewhere
        }
        return nil
    }

    /// 別名への当たり方。別名の「どこか」には当てない（ノイズになる）。
    /// - 別名そのもの、または別名の 1 語と一致（"pan"・"noise" が "noise gate" に）: .word。
    ///   同義語を打った人は、名前の一部がたまたま似た別のエフェクト
    ///   （"pan" に "Panel"）より、その同義語の持ち主を探している。
    /// - 別名の頭・語の頭から: .alias。
    private static func aliasHit(_ type: String, _ q: String) -> Hit? {
        var best: Hit?
        for a in aliases[type] ?? [] {
            if a == q || words(a).contains(q) { return .word }
            if let h = nameHit(a, q), h <= .word { best = .alias }
        }
        return best
    }

    // MARK: - 順位

    /// 並べ替えの鍵。当たり方 → 定番の順 → 名前順。
    struct Key: Comparable {
        let hit: Hit
        let rank: Int
        let name: String

        static func < (a: Key, b: Key) -> Bool {
            if a.hit != b.hit { return a.hit < b.hit }
            if a.rank != b.rank { return a.rank < b.rank }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        static func == (a: Key, b: Key) -> Bool {
            a.hit == b.hit && a.rank == b.rank
                && a.name.localizedCaseInsensitiveCompare(b.name) == .orderedSame
        }
    }

    /// 並べ替えの鍵を作る。
    /// - type: 組み込みエフェクトなら ETEffect.type。AU・JSFX・プリセットは nil。
    ///   同じ当たり方の中では、定番 → 定番でない組み込み → それ以外（名前順）の順。
    ///   組み込みを先にするのは、探しているのがこのアプリの標準のエフェクトであることが多いため。
    /// - q: 空のときは順位を付けない（全部 .inside で、名前順のまま）。
    static func key(hit: Hit, type: String?, name: String, query q: String) -> Key {
        Key(hit: hit, rank: q.isEmpty ? 0 : rank(of: type), name: name)
    }

    /// 定番の順位。小さいほど上。
    static func rank(of type: String?) -> Int {
        guard let type else { return curated.count + 1 }
        return curatedIndex[type] ?? curated.count
    }

    /// 組み込みエフェクトだけを探して並べる（テストと、他の画面で使うとき用）。
    static func search(_ effects: [ETEffect], query: String) -> [ETEffect] {
        let q = normalize(query)
        return effects
            .compactMap { e in effectHit(e, q).map { (key(hit: $0, type: e.type, name: e.name, query: q), e) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    // MARK: - 見出しごとの束

    /// 検索結果の見出し。**宣言の順がそのまま画面の順。**
    enum Bucket: Int, CaseIterable, Comparable {
        /// 組み込みのエフェクト。
        case effects = 0
        /// AUv3 と JSFX。
        case plugins = 1
        /// 自分のプリセットと同梱のプリセット。
        case presets = 2

        var title: String {
            switch self {
            case .effects: return "Effects"
            case .plugins: return "Plugins"
            case .presets: return "Presets"
            }
        }

        static func < (a: Bucket, b: Bucket) -> Bool { a.rawValue < b.rawValue }
    }

    /// 並べ終えた結果を見出しごとに分ける。
    /// **束の中の順は渡された順のまま**（順位を付け直さない）。
    /// 空の束は返さない。画面に空の見出しだけが残らないようにする。
    static func grouped<T>(_ ranked: [(Bucket, T)]) -> [Grouped<T>] {
        Bucket.allCases.compactMap { b in
            let items = ranked.filter { $0.0 == b }.map(\.1)
            return items.isEmpty ? nil : Grouped(bucket: b, items: items)
        }
    }

    /// 見出し 1 つ分。ForEach の鍵に見出しをそのまま使えるよう Identifiable にする。
    struct Grouped<T>: Identifiable {
        let bucket: Bucket
        let items: [T]
        var id: Int { bucket.rawValue }
    }

    // MARK: - 手で決めた表

    /// **定番の組み込みエフェクト。上ほど先に出す。**
    /// 「EQ を探す人はまず 15 バンドの PEQ」のように、使う人の多い順に手で並べる。
    /// 載せていないものは、当たり方が同じなら名前順でこの後ろに続く。
    static let curated: [String] = [
        // EQ。"eq" で最初に見たいのは、細かく詰められる PEQ とグラフィック EQ。
        "FifteenBandPEQPlugin",
        "FifteenBandGEQPlugin",
        "FiveBandPEQPlugin",
        "ToneControlPlugin",
        // ダイナミクス
        "CompressorPlugin",
        "BrickwallLimiterPlugin",
        // 空間系
        "DattorroPlateReverbPlugin",
        "FDNReverbPlugin",
        "IRReverbPlugin",
        "DelayPlugin",
        // 基本
        "VolumePlugin",
        "HiPassFilterPlugin",
        "LoPassFilterPlugin",
        // 定番の次。使う人は多いが、まず名前を知っている人が探す。
        "FiveBandDynamicEQ",
        "MultibandCompressorPlugin",
        "GatePlugin",
        "ChorusPlugin",
        "PhaserPlugin",
        "SaturationPlugin",
        // ステレオ・ヘッドホン
        "StereoBalancePlugin",
        "CrossfeedFilterPlugin",
        "PitchShifterPlugin",
        // 見る道具
        "LevelMeterPlugin",
        "SpectrumAnalyzerPlugin",
    ]

    private static let curatedIndex: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, t) in curated.enumerated() where m[t] == nil { m[t] = i }
        return m
    }()

    /// **別名。**そのエフェクトが世の中で呼ばれている名前を、エフェクトごとに置く。
    /// 同じ種類のものの一般的な呼び名・略称・有名な同類の名前（snail・goniometer・transient designer）。
    /// 「やりたいこと」の言葉（louder など）は置かない。小文字の英語で書く。
    /// 当たるのは別名の頭か語の頭だけ（途中の字では当てない）。名前にすでに入っている語は書かない（探せるので）。
    static let aliases: [String: [String]] = [
        // 解析
        "AnalogMeterPlugin": ["vu meter", "needle meter", "ppm", "loudness meter", "lufs"],
        "ChromaSpiralPlugin": ["snail", "chromagram", "pitch class"],
        "LevelMeterPlugin": ["peak meter", "volume meter"],
        "NoteSpectrogramPlugin": ["piano roll", "pitch tracker", "polyphonic"],
        "OscilloscopePlugin": ["scope", "waveform"],
        "PitchMeterPlugin": ["tuner", "pitch detector"],
        "RhythmAnalyzerPlugin": ["bpm", "tempo", "beat detector"],
        "SpectrogramPlugin": ["sonogram", "waterfall"],
        "SpectrumAnalyzerPlugin": ["fft", "analyser", "rta", "frequency analyzer"],
        "StereoMeterPlugin": ["goniometer", "vectorscope", "phase scope", "correlation meter"],

        // 基本
        "BassManagementPlugin": ["subwoofer", "bass redirection", "lfe"],
        "ChannelDividerPlugin": ["crossover", "bi-amp", "multi-amp"],
        "FIRCrossoverPlugin": ["linear phase crossover", "bi-amp", "multi-amp"],
        "MatrixPlugin": ["router", "channel mixer", "downmix"],
        "MultiChannelPanelPlugin": ["surround", "speaker level"],
        "MutePlugin": ["silence"],
        "PolarityInversionPlugin": ["phase invert", "phase flip", "invert"],
        "StereoBalancePlugin": ["pan", "panning", "panner"],
        "VolumePlugin": ["gain", "fader", "trim"],

        // 遅延
        "DelayPlugin": ["echo"],
        "TimeAlignmentPlugin": ["speaker delay", "delay compensation", "speaker alignment"],

        // ダイナミクス
        "AttackTonalBalancePlugin": ["transient"],
        "AutoLevelerPlugin": ["agc", "leveller", "volume leveler", "normalizer"],
        "BrickwallLimiterPlugin": ["maximizer", "peak limiter", "true peak limiter"],
        "CompressorPlugin": ["compression", "dynamics"],
        "ExpanderPlugin": ["downward expander", "dynamics"],
        "GatePlugin": ["noise gate"],
        "MultibandCompressorPlugin": ["mb comp", "compression"],
        "MultibandExpanderPlugin": ["mb expander"],
        "PowerAmpSagPlugin": ["amplifier"],
        "TransientShaperPlugin": ["transient designer", "attack sustain"],

        // EQ
        "BandPassFilterPlugin": ["bandpass", "bpf"],
        "CombFilterPlugin": ["flanger"],
        "EarphoneCableSimPlugin": ["output impedance", "iem"],
        "FifteenBandGEQPlugin": ["graphic eq", "graphic equalizer", "equalizer"],
        "FifteenBandPEQPlugin": ["parametric eq", "parametric equalizer", "equalizer", "autoeq"],
        "FiveBandDynamicEQ": ["dyn eq", "dynamic equalizer", "de-esser", "deesser"],
        "FiveBandFIRPEQPlugin": ["linear phase eq", "fir eq", "parametric eq"],
        "FiveBandPEQPlugin": ["parametric eq", "parametric equalizer", "equalizer"],
        "GroupDelayEqPlugin": ["all-pass", "phase eq"],
        "GroupDelayPEQPlugin": ["all-pass", "phase eq"],
        "HiPassFilterPlugin": ["high pass", "highpass", "hpf", "low cut"],
        "LoPassFilterPlugin": ["low pass", "lowpass", "lpf", "high cut"],
        "LoudnessEqualizerPlugin": ["loudness compensation", "equal loudness", "fletcher munson", "contour"],
        "NarrowRangePlugin": ["bandpass", "band limit"],
        "RoomEqPlugin": ["room correction", "acoustic correction", "speaker correction"],
        "TiltEQPlugin": ["tone tilt"],
        "TonalBalanceEQPlugin": ["match eq", "target curve"],
        "ToneControlPlugin": ["bass treble", "treble", "baxandall"],

        // Lo-fi
        "AMRadioSimulatorPlugin": ["old radio"],
        "BitCrusherPlugin": ["bitcrush", "decimator", "lofi", "lo-fi"],
        "BluetoothSBCSimulatorPlugin": ["bluetooth", "a2dp"],
        "CassetteArtifactsPlugin": ["tape"],
        "DSD64IMDSimulatorPlugin": ["sacd"],
        "DigitalErrorEmulatorPlugin": ["glitch", "bit error"],
        "FMRadioSimulatorPlugin": ["broadcast"],
        "G726ADPCMSimulatorPlugin": ["adpcm", "telephone"],
        "GSMFullRateSimulatorPlugin": ["mobile phone", "cell phone", "telephone"],
        "HumGeneratorPlugin": ["mains hum"],
        "MDSimulatorPlugin": ["minidisc", "atrac"],
        "MP3CodecSimulatorPlugin": ["lossy", "low bitrate"],
        "NoiseBlenderPlugin": ["white noise", "pink noise"],
        "SWRadioSimulatorPlugin": ["shortwave", "ham radio"],
        "SimpleJitterPlugin": ["clock jitter"],
        "TVAudioSimulatorPlugin": ["television", "nicam"],
        "TapeArtifactsPlugin": ["reel to reel", "tape machine"],
        "VinylArtifactsPlugin": ["vinyl noise", "crackle"],
        "VinylSimulatorPlugin": ["record", "turntable", "phono"],

        // モジュレーション
        "AutoFilterPlugin": ["auto-wah", "wah", "envelope filter"],
        "AutoPanPlugin": ["panner", "8d audio"],
        "ChorusPlugin": ["ensemble", "flanger", "vibrato"],
        "DopplerDistortionPlugin": ["speaker doppler"],
        "FrequencyShifterPlugin": ["ring modulator", "ring mod", "bode shifter"],
        "PhaserPlugin": ["phase shifter"],
        "PitchShifterHQPlugin": ["transpose", "key change"],
        "PitchShifterPlugin": ["transpose", "key change"],
        "RotarySpeakerPlugin": ["leslie"],
        "TremoloPlugin": ["amplitude modulation"],
        "WowFlutterPlugin": ["tape wobble", "warble"],

        // その他
        "OscillatorPlugin": ["signal generator", "tone generator", "sine", "test tone", "sweep"],
        "SFZNotePlayerPlugin": ["sampler"],

        // 共鳴
        "AdaptivePredictionEffectPlugin": ["linear prediction", "lpc"],
        "HornResonatorPlugin": ["horn speaker", "horn loaded"],
        "HornResonatorPlusPlugin": ["horn speaker", "horn loaded"],
        "ModalResonatorPlugin": ["resonator bank"],

        // 修復
        "ClickRemoverPlugin": ["declick", "decrackle"],
        "ClipRestorerPlugin": ["declip", "declipper"],
        "HumRemoverPlugin": ["dehum"],
        "NoiseReductionPlugin": ["denoise", "denoiser"],

        // リバーブ
        "DattorroPlateReverbPlugin": ["verb"],
        "FDNReverbPlugin": ["verb", "hall reverb", "algorithmic reverb"],
        "IRReverbPlugin": ["verb", "convolution", "convolver", "impulse response", "brir", "hrir", "binaural", "cabinet ir"],
        "RSReverbPlugin": ["verb", "algorithmic reverb"],

        // サチュレーション
        "BandwidthExtenderPlugin": ["spectral band replication", "sbr", "upscaler"],
        "BassExtenderPlugin": ["virtual bass", "psychoacoustic bass"],
        "DynamicSaturationPlugin": ["speaker distortion"],
        "ExciterPlugin": ["enhancer", "aural exciter"],
        "HardClippingPlugin": ["clipper"],
        "HarmonicDistortionPlugin": ["harmonics"],
        "MultibandSaturationPlugin": ["mb saturation"],
        "SaturationPlugin": ["drive", "overdrive", "distortion", "soft clip"],
        "SubSynthPlugin": ["subharmonic synthesizer", "sub bass"],
        "TubeSimulatorPlugin": ["valve", "tube amp", "vacuum tube"],

        // 空間
        "CrossfeedFilterPlugin": ["bs2b", "headphone crossfeed"],
        "CrosstalkCancellationPlugin": ["xtc", "binaural speakers"],
        "MSMatrixPlugin": ["mid side", "mid-side", "mid/side"],
        "MultibandBalancePlugin": ["multiband stereo"],
        "PhaseSelectEqPlugin": ["center extraction", "vocal remover"],
        "SpatialMapperPlugin": ["upmix", "ambience extraction"],
        "StereoBlendPlugin": ["stereo width", "stereo widener", "stereo imager"],
    ]
}
