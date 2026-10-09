//  RhythmAnalyzerModel.swift
//  Rhythm Analyzer（RhythmAnalyzerPlugin、2.12.0 で増えた）の枠の読みと、画面が持つ履歴の計算。
//  画面（RhythmAnalyzerView）は描くだけ。**Foundation だけ**で、実機なしで試せる
//  （Tests/Unit/RhythmAnalyzerTests.swift）。
//
//  上流は plugins/analyzer/rhythm_analyzer.js。枠の読み（readSnapshot）、世代と時刻の柵
//  （handleTelemetry）、テンポグラムの列（writeTempogram）、拍の時計（advanceClock）、ビート LED
//  （updateBeatLed）、onset の置き方と揺れ（storeEvent・referenceDeviation・isNovel）、
//  ビートレンズ（lensSummary・displayedLensSummary）をそのまま写した。
//
//  テレメトリ: ETFrameType.rhythmAnalyzer = 28、formatVersion 4、1496 バイト（2.13.0。2.12.0 は版 1、1344 バイト）
//  （dsp/plugins/analyzer/rhythm_analyzer/kernel.cpp の kTelemetryType / kPayloadBytes、rhythm_analyzer.js:1-8）
//
//  ペイロードの並び（rhythm_analyzer.js:294-394 の readSnapshot）:
//      0   f32 sampleRate     4   u32 generation（Reset で増える。0 は無い）
//      8   u32 hop（包絡線の 1 歩のサンプル数）   12  u32 frameCount（包絡線の歩数）
//      16  f32 timeSeconds（ホストの時刻）        20  f32 latencySeconds
//      24  u32 droppedEvents   28 u32 eventCount（最大 16）
//      32  u32 trackerFlags（1 = 拍の音を鳴らしてよい。tickGateOpen）  36 u32 analysisEpoch
//      40  f32 confidence（0〜1）
//      44  f32 periodSeconds（0 = 解析した拍が無い）  48 u32 anchorFrame   52 f32 anchorFraction（0 以上 1 未満）
//      56  u32 anchorIndex   60 f32 strongestBpm
//      64  f32 × 192 テンポグラム（0〜1。30〜480 BPM を 1 オクターブ 48 本で）
//      832 + 32*k  項目 k: u32 frame（flags 5 は i32） / f32 fraction / u32 epoch / i32 index /
//                   f32 beatFraction / f32 period / f32 strength / u8 band / u8 flags / u16 0
//          flags: 0 確定した onset、1 拍に乗っていない onset、2 見せる先の拍、3 仮の onset、
//                 4 見せない先の拍、5 確定した拍。拍（2・4・5）は band 0・beatFraction 0・strength 0〜1
//      1344  u32 previewCount（12 まで）  1348 f32 previewPeriod
//      1352 + 12*i  先の拍の見込み: i32 frame / f32 fraction / i32 index（時刻も番号も 1 つずつ増える）
//
//  **枠 1 つは「前の枠から今まで」の onset を運ぶ。**最新だけ残す読み方では前の枠の onset が消えるので、
//  Telemetry は Rhythm Analyzer の枠だけ届いた順に全部取っておく（Telemetry.drainFrames）。
//
//  2.13.0 で上流の画面は書き直された。ここはそれを写している（上流 v2.13.0 の rhythm_analyzer.js）:
//    - 世代: 新しい世代の枠は前の世代の続きとして番号を付け直す（spliceGeneration・rebaseSnapshot）。
//      epoch に 2^32 ずつ足すので、epoch は UInt64。エンジンの作り直し（Telemetry.clearCount）は従来どおり捨てる。
//    - テンポグラム: 列は解析した時刻の原点から数え、採用したテンポは確定した anchor の時刻の列へ後から埋める。
//    - 拍の時計: 確定した拍（flags 5）が履歴、先の拍（flags 2・4）と先の拍の見込み（1344〜）が尾。
//      clockPosition が区間ごとに補間し、定数の周期は使わない。
//    - 表示: 枠が来たときの食い違いは 100 ms の指数で消す（displayClock・displayedEvent）。
//      止まっている間は最後の周期で流し続ける。
//    - onset: 札（identity）で同じ点を置き直し、仮の onset が確定しても動かさない。
//      先の拍の見込みが来るたびに、確定していない点を元の時刻のまま置き直す。
//    - 拍の格子の投票は確定した onset だけ。仮の点は置いて見せるが、レンズには入れない。
//
//  外したもの（EffectDeck に無い）: カーソルの読み値（plainCursor）、プレーヤーの曲の切れ目で解析を捨てる処理。

import Foundation

// MARK: - 範囲（Min / Max BPM）

enum ETRhythmBPMRange {
    static let minimumRange: ClosedRange<Double> = 40...192
    static let maximumRange: ClosedRange<Double> = 50...240
    /// テンポの探索は Max BPM ≥ 1.25 × Min BPM を要る（カーネルもライブラリの bindings も同じ。
    /// kernel.cpp:55 の kMinimumSpan）。
    static let minimumSpan = 1.25

    /// 上流の setParameters の Min / Max（rhythm_analyzer.js:167-178）。
    /// Max だけを範囲の中の値に直すと Min が下がり、そうでなければ Max が上がる。
    /// 数欄は打った先頭の字（180 の "1"）も送ってくるので、範囲の外へ寄せた Max は Min を下げない。
    /// 数でないものは前の値のまま。
    static func normalize(previousMin: Double, previousMax: Double,
                          requestedMin: Double?, requestedMax: Double?) -> (min: Double, max: Double) {
        func parse(_ raw: Double, _ range: ClosedRange<Double>, previous: Double) -> Double {
            raw.isFinite ? Swift.min(Swift.max(raw, range.lowerBound), range.upperBound) : previous
        }
        var mn = previousMin
        var mx = previousMax
        if let requestedMin { mn = parse(requestedMin, minimumRange, previous: mn) }
        if let requestedMax {
            mx = parse(requestedMax, maximumRange, previous: mx)
            let inRange = requestedMax >= maximumRange.lowerBound && requestedMax <= maximumRange.upperBound
            if requestedMin == nil && inRange && mx < mn * minimumSpan {
                mn = (mx / minimumSpan).rounded(.down)
            }
        }
        if mx < mn * minimumSpan { mx = (mn * minimumSpan).rounded(.up) }
        return (mn, mx)
    }
}

// MARK: - 定数と小道具

enum ETRhythm {
    static let version: UInt16 = 4
    static let payloadBytes = 1496
    static let tempogramBins = 192
    static let maxEvents = 16
    static let tempogramOffset = 64
    static let eventsOffset = 832
    static let eventBytes = 32
    static let previewOffset = 1344
    static let previewBeatsOffset = 1352
    static let previewBeatBytes = 12
    static let maxPreviewBeats = 12
    /// 1 行の拍の数（Span）。表示だけの設定 sp。
    static let spans = [4, 6, 8, 12, 16]
    static let defaultSpan = 8
    static let minimumBPM = 30.0
    static let octaves = 4.0
    static let bpmTicks: [Double] = [30, 60, 120, 240, 480, 90, 180]
    static let tempogramColumns = 160
    static let columnSeconds = 0.125
    static let scrollLimitColumns = 2.0
    static let clockCapacity = 512
    static let maxSegments = 64
    static let eventCapacity = 4096
    static let deviationMS = 30.0
    static let guideMS = 20.0
    static let referenceBeats = 16.0
    static let matchBeats = 0.08
    static let lensBeats = 32.0
    static let lensSmoothingMS = 200.0
    static let minimumEvents = 4
    static let labelMinimumMS = 3.0
    static let slotLabels = ["1", "e", "⅓", "&", "⅔", "a"]
    static let bandNames = ["Low", "Mid", "High"]
    /// 上から下へ（High が上）。
    static let bandOrder = [2, 1, 0]
    /// 帯域ごとの行（上が 0）。
    static let bandRows = [2, 1, 0]
    static let ledFadeSeconds = 0.09
    /// 表示の位置の補正を消す時定数（RHYTHM_ANALYZER_POSITION_SMOOTHING_MS = 100）。秒。
    static let positionSmoothing = 0.1
    /// レンズの帯域の名前が印の上に収まる行の高さ（フォントの倍数。RHYTHM_ANALYZER_LENS_LABEL_ROW）。
    static let lensLabelRow = 1.25 / 0.35
    static let minus = "−"
    static let dash = "—"

    struct Grid {
        var points: [Double]
        var slots: [Int]
    }
    static let straightGrid = Grid(points: [0, 0.25, 0.5, 0.75, 1], slots: [0, 1, 3, 5, 0])
    static let tripletGrid = Grid(points: [0, 1.0 / 3, 2.0 / 3, 1], slots: [0, 2, 4, 0])

    /// Span を 4/6/8/12/16 の最寄りへ（setParameters、rhythm_analyzer.js:179-187）。
    static func nearestSpan(_ requested: Double) -> Int {
        guard requested.isFinite else { return defaultSpan }
        var best = spans[0]
        for span in spans where abs(Double(span) - requested) < abs(Double(best) - requested) { best = span }
        return best
    }

    /// 30〜480 BPM の軸での位置。0（下）〜 1（上）。
    static func bpmPosition(_ bpm: Double) -> Double {
        let position = log2(bpm / minimumBPM) / octaves
        return position < 0 ? 0 : (position > 1 ? 1 : position)
    }

    /// 丸めた値に符号を付ける。0 に丸まるものは "+0"（rhythmAnalyzerSigned）。
    static func signed(_ value: Double, digits: Int) -> String {
        let text = String(format: "%.\(digits)f", abs(value))
        let negative = value < 0 && (Double(text) ?? 0) != 0
        return (negative ? minus : "+") + text
    }

    static func median(_ input: [Double]) -> Double {
        let values = input.sorted()
        let middle = values.count >> 1
        return values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2
    }

    /// 32 ビットの回り込みを見る「新しい」（isNewerRhythmAnalyzerCounter）。
    static func isNewerCounter(_ candidate: UInt32, than current: UInt32) -> Bool {
        let delta = candidate &- current
        return delta != 0 && delta < 0x8000_0000
    }
}

// MARK: - 枠

struct ETRhythmEvent: Equatable {
    /// 確定した onset（flags 0）。拍に乗っていない onset（flags 1）は false。
    var annotated: Bool
    /// 仮の onset（flags 3）。後で同じ onset が確定（flags 0）か拍に乗らない（flags 1）で来る。
    var provisional = false
    /// 解析した時刻（生成の始めからの秒）。
    var time: Double
    /// 同じ onset を見分ける札。仮のものが確定したら同じ札で来る（上流 identity）。
    var identity: String
    /// 拍の追跡の epoch。世代をまたぐと 2^32 ずつ足されるので UInt32 に収まらない。
    var epoch: UInt64
    var index: Int32
    var position: Double
    var beatFraction: Double
    var periodSeconds: Double
    var strength: Double
    var band: Int
}

/// 拍。枠の項目の flags 2・4・5 と、先の拍の見込み。
struct ETRhythmBeat: Equatable {
    var time: Double
    var index: Int32
    var epoch: UInt64
    var periodSeconds: Double
    var strength: Double
}

struct ETRhythmSnapshot: Equatable {
    var sampleRate: Double
    var generation: UInt32
    var hop: UInt32
    /// 世代をまたいで続く数（ETRhythmState.rebase が前の世代の分を足す）。
    var frameCount: UInt64
    var timeSeconds: Double
    var latencySeconds: Double
    var droppedEvents: UInt32
    var eventCount: Int
    /// trackerFlags が 1。拍の音（Metronome Click）を鳴らしてよく、ヘッダの LOCKED と点灯の元。
    var tickGateOpen: Bool
    var analysisEpoch: UInt64
    var confidence: Double
    var periodSeconds: Double
    /// 解析した拍（anchor）の位置。
    var anchorFrame: UInt64
    var anchorFraction: Double
    var anchorIndex: Int
    var strongestBpm: Double
    var tempogram: [Float]
    /// onset（flags 0・1・3）。
    var events: [ETRhythmEvent]
    /// 先の拍（flags 2・4）と、そのうち見せるもの（flags 2）。
    var forwardBeats: [ETRhythmBeat] = []
    var shownBeats: [ETRhythmBeat] = []
    /// 確定した拍（flags 5）。
    var analysisBeats: [ETRhythmBeat] = []
    /// 先の拍の見込み（1344 以降）。
    var previewBeats: [ETRhythmBeat] = []
    var previewPeriodSeconds: Double = 0
    var sequence: UInt32

    var hopSeconds: Double { Double(hop) / sampleRate }
    /// 解析した拍がある（上流 analysisValid）。周期が 0 なら無い。
    var analysisValid: Bool { periodSeconds > 0 }
    /// 解析できる標本率（48 / 96 / 192 kHz）。カーネルはそれ以外では解析しない（44.1 kHz の経路など）。
    var analysisAvailable: Bool { [48000.0, 96000.0, 192000.0].contains(sampleRate) }

    /// 枠を読む（readSnapshot の門）。読めなければ nil。
    static func parse(_ frame: ETFrame?) -> ETRhythmSnapshot? {
        guard let frame, frame.type == ETFrameType.rhythmAnalyzer.rawValue,
              frame.version == ETRhythm.version else { return nil }
        let p = ETPayload(frame)
        guard p.count == ETRhythm.payloadBytes,
              let rate = p.f32(at: 0), let generation = p.u32(at: 4), let hop = p.u32(at: 8),
              let frameCount = p.u32(at: 12), let time = p.f32(at: 16), let latency = p.f32(at: 20),
              let dropped = p.u32(at: 24), let eventCount = p.u32(at: 28),
              let flags = p.u32(at: 32), let epoch = p.u32(at: 36), let confidence = p.f32(at: 40),
              let period = p.f32(at: 44), let anchorFrame = p.u32(at: 48), let anchorFraction = p.f32(at: 52),
              let anchorIndex = p.u32(at: 56), let strongest = p.f32(at: 60) else { return nil }
        guard rate.isFinite, rate > 0, hop != 0, generation != 0, time.isFinite, time >= 0,
              latency.isFinite, latency >= 0, eventCount <= UInt32(ETRhythm.maxEvents), flags <= 1,
              confidence.isFinite, confidence >= 0, confidence <= 1, period.isFinite, period >= 0,
              anchorFraction >= 0, anchorFraction < 1, strongest.isFinite, strongest >= 0,
              let tempogram = p.floats(at: ETRhythm.tempogramOffset, count: ETRhythm.tempogramBins),
              !tempogram.contains(where: { !($0 >= 0 && $0 <= 1) }) else { return nil }
        let hopSeconds = Double(hop) / Double(rate)
        var snapshot = ETRhythmSnapshot(
            sampleRate: Double(rate), generation: generation, hop: hop, frameCount: UInt64(frameCount),
            timeSeconds: Double(time), latencySeconds: Double(latency), droppedEvents: dropped,
            eventCount: Int(eventCount), tickGateOpen: flags == 1, analysisEpoch: UInt64(epoch),
            confidence: Double(confidence), periodSeconds: Double(period), anchorFrame: UInt64(anchorFrame),
            anchorFraction: Double(anchorFraction), anchorIndex: Int(anchorIndex),
            strongestBpm: Double(strongest), tempogram: tempogram, events: [], sequence: frame.sequence)
        for slot in 0..<Int(eventCount) {
            let base = ETRhythm.eventsOffset + ETRhythm.eventBytes * slot
            guard let frameNumber = p.u32(at: base), let signedFrame = p.i32(at: base),
                  let fraction = p.f32(at: base + 4), let fractionBits = p.u32(at: base + 4),
                  let eventEpoch = p.u32(at: base + 8), let index = p.i32(at: base + 12),
                  let beatFraction = p.f32(at: base + 16), let eventPeriod = p.f32(at: base + 20),
                  let strength = p.f32(at: base + 24), let band = p.u8(at: base + 28),
                  let kind = p.u8(at: base + 29), let pad = p.u16(at: base + 30) else { return nil }
            let annotated = kind == 0
            let shownBeat = kind == 2
            let forwardBeat = shownBeat || kind == 4
            let analysisBeat = kind == 5
            let beatSlot = forwardBeat || analysisBeat
            guard beatSlot ? band == 0 : band <= 2, kind <= 5, pad == 0,
                  fraction >= 0, fraction < 1, beatFraction >= 0, beatFraction < 1,
                  eventPeriod.isFinite, eventPeriod >= 0,
                  !((annotated || kind == 3 || forwardBeat) && eventPeriod == 0),
                  !(beatSlot && beatFraction != 0), strength.isFinite, strength <= 1,
                  beatSlot ? strength >= 0 : strength > 0 else { return nil }
            let at = ((analysisBeat ? Double(signedFrame) : Double(frameNumber)) + Double(fraction)) * hopSeconds
            if beatSlot {
                let beat = ETRhythmBeat(time: at, index: index, epoch: UInt64(eventEpoch),
                                        periodSeconds: Double(eventPeriod), strength: Double(strength))
                if analysisBeat {
                    snapshot.analysisBeats.append(beat)
                } else {
                    snapshot.forwardBeats.append(beat)
                    if shownBeat { snapshot.shownBeats.append(beat) }
                }
                continue
            }
            snapshot.events.append(ETRhythmEvent(
                annotated: annotated,
                provisional: kind == 3,
                time: at,
                identity: "\(generation):\(frameNumber):\(fractionBits):\(band)",
                epoch: UInt64(eventEpoch),
                index: index,
                position: Double(index) + Double(beatFraction),
                beatFraction: Double(beatFraction),
                periodSeconds: Double(eventPeriod),
                strength: Double(strength),
                band: Int(band)))
        }
        guard let previewCount = p.u32(at: ETRhythm.previewOffset),
              let previewPeriod = p.f32(at: ETRhythm.previewOffset + 4),
              previewCount <= UInt32(ETRhythm.maxPreviewBeats), previewPeriod.isFinite, previewPeriod >= 0,
              !(previewCount > 0 && previewPeriod == 0) else { return nil }
        snapshot.previewPeriodSeconds = Double(previewPeriod)
        for i in 0..<Int(previewCount) {
            let base = ETRhythm.previewBeatsOffset + ETRhythm.previewBeatBytes * i
            guard let beatFrame = p.i32(at: base), let fraction = p.f32(at: base + 4),
                  let index = p.i32(at: base + 8), fraction >= 0, fraction < 1 else { return nil }
            let beat = ETRhythmBeat(time: (Double(beatFrame) + Double(fraction)) * hopSeconds, index: index,
                                    epoch: UInt64(epoch), periodSeconds: Double(previewPeriod), strength: 0)
            if let previous = snapshot.previewBeats.last,
               beat.time <= previous.time || Int64(beat.index) != Int64(previous.index) + 1 { return nil }
            snapshot.previewBeats.append(beat)
        }
        return snapshot
    }
}

// MARK: - 履歴

/// 拍の時計の区間。拍の追跡の epoch ごと（clock の offset・範囲・拍の格子の多数決）。
final class ETRhythmSegment {
    let epoch: UInt64
    var offset: Double
    var startU: Double
    var endU: Double
    var reanchor: Bool
    var straight = 0
    var triplet = 0
    /// 表示だけの補正（ETRhythmState.displayTimelineOffset を、その区間が開いている間に写す）。
    var displayOffset = 0.0

    init(epoch: UInt64, offset: Double, startU: Double, endU: Double, reanchor: Bool) {
        self.epoch = epoch
        self.offset = offset
        self.startU = startU
        self.endU = endU
        self.reanchor = reanchor
    }
}

struct ETRhythmLensRow {
    var band: Int
    var slot: Int
    var mean: Double
    var sd: Double
    var count: Int
    var offset: Double = 0
}

struct ETRhythmLens {
    var rows: [ETRhythmLensRow]
    var swing: Double
    var jitter: Double
}

/// 時計の基準になる拍（clockAnchor）。解析した拍（flags 5）か、枠の anchor から作る。
struct ETRhythmClockAnchor: Equatable {
    var time: Double
    var index: Int
    var epoch: UInt64
    var periodSeconds: Double
}

/// 先の拍。anchor の次から数えた位置（position）を持つ。
struct ETRhythmTailBeat: Equatable {
    var time: Double
    var periodSeconds: Double
    var position: Double
}

/// 画面が持つ履歴と、その計算。**参照型。**枠が来るたびに進め、描く側は読むだけ。
///
/// 時刻は 2 通り。「解析した時刻」（枠の frameCount × hopSeconds。生成の始めからの秒）と、
/// 「壁時計」（systemUptime の秒。`now` / `wall` と書く）。壁時計は枠が着いた時刻の記録と、表示のなめらかな補正にだけ使う。
final class ETRhythmState {

    // 表示だけの設定（sp）。変えたら refreshNovelty を呼ぶ。
    var span = ETRhythm.defaultSpan
    /// 上流の _powerUiEnabled。EffectDeck の電源の休みは音のほうで済むので、いつも true。
    var powerUiEnabled = true

    // 世代と時刻の柵。
    private(set) var activeGeneration: UInt32?
    private var generationFence: UInt32?
    private var timeFence: Double?
    private(set) var lastObservedTime: Double?
    /// 新しい世代が前の世代の続きとして来たとき、枠の番号と epoch に足す数（spliceGeneration）。
    private(set) var frameBase: UInt64 = 0
    private(set) var epochBase: UInt64 = 0

    // テンポグラム。列は 160、新しいものが head。
    private(set) var tempogram: [Float]
    private(set) var tempogramAdopted: [Float]
    private(set) var tempogramConfidence: [Float]
    private(set) var tempogramHead = ETRhythm.tempogramColumns - 1
    private(set) var columnPhase = 0.0
    private(set) var columnOriginTime: Double?
    private(set) var columnIndex = 0
    private(set) var columnFrameTime: Double?
    private var lastAdoptedAnchor: Double?
    private var adoptedEpoch: UInt64?
    private var lastFrameCount: UInt64?
    /// テンポグラムが書き変わったか（画像を作り直す印）。
    var tempogramDirty = true

    // 拍の時計。確定した拍は書き換えない履歴、先の拍は一番新しい区間を続ける。
    private(set) var beatClock = 0.0
    private(set) var heldPeriod: Double?
    private var clockTimes = [Double](repeating: 0, count: ETRhythm.clockCapacity)
    private var clockValues = [Double](repeating: 0, count: ETRhythm.clockCapacity)
    private var clockHead = ETRhythm.clockCapacity - 1
    private(set) var clockCount = 0
    private(set) var clockAnchor: ETRhythmClockAnchor?
    private(set) var forwardBeats: [ETRhythmBeat] = []
    private var forwardEpoch: UInt64?
    private(set) var forwardOffset = 0.0
    private(set) var forwardTail: [ETRhythmTailBeat] = []
    private(set) var previewEpoch: UInt64?
    private(set) var previewPeriod = 0.0
    private(set) var segments: [UInt64: ETRhythmSegment] = [:]
    /// segments の挿入順（古い順）。JS の Map の順。
    private(set) var segmentOrder: [UInt64] = []
    private(set) var openSegment: ETRhythmSegment?

    // 表示の時計（解析した時計に、壁時計でなめらかに消える補正を足したもの）。
    private(set) var displayU: Double?
    private var displayOffsetU = 0.0
    private var displayChangeTime = 0.0
    private(set) var displayPeriod = 0.0
    private var idleStartU = 0.0
    private(set) var displayTimelineOffset = 0.0
    private(set) var idleScroll = false
    private(set) var renderWallTime = 0.0

    // onset の環。
    private var eventU = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventTime = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventLocated = [Bool](repeating: false, count: ETRhythm.eventCapacity)
    private var eventOffsetU = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventTimelineOffset = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventOffsetDeviation = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventCorrectionTime = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventReference = [ReferenceCache?](repeating: nil, count: ETRhythm.eventCapacity)
    private var eventPreviewPeriod = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventPreviewTriplet = [Bool](repeating: false, count: ETRhythm.eventCapacity)
    private var eventKeys = [String?](repeating: nil, count: ETRhythm.eventCapacity)
    private var eventBand = [Int](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventStrength = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventEpoch = [UInt64](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventTimed = [Bool](repeating: false, count: ETRhythm.eventCapacity)
    private var eventNovel = [Bool](repeating: false, count: ETRhythm.eventCapacity)
    private var eventSlot = [Int](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventFraction = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventRawDeviation = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventDeviation = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private(set) var eventSerial = 0
    /// 同じ onset を見分ける札 → 通し番号。仮のものを確定で差し替えるのに使う。
    private var onsetIndices: [String: Int] = [:]
    /// まだ確定していない onset の通し番号。新しい先の拍の見込みが来るたびに置き直す。
    private(set) var pendingOnsets = Set<Int>()
    private var referenceRevision = 0

    private struct ReferenceCache {
        var serial: Int
        var epoch: UInt64
        var revision: Int
        var lower: Double
        var upper: Double
        var members: [Int]
        var median: Double
    }

    private var lensDisplay: (epoch: UInt64?, time: Double, cells: [ETRhythmLensRow?])?
    private(set) var snapshot: ETRhythmSnapshot?

    // ビート LED（見せる拍、flags 2）。
    private var pendingBeats: [(time: Double, strength: Double)] = []
    /// epoch ごとに、最後に受けた見せる拍の番号。挿入順も持つ（JS の Map の順）。
    private var shownBeatIndices: [UInt64: Int32] = [:]
    private var shownBeatOrder: [UInt64] = []
    private var ledBeat: Double?
    private var ledStrength = 0.0
    private(set) var ledLevel = 0.0

    init() {
        let columns = ETRhythm.tempogramColumns
        tempogram = [Float](repeating: 0, count: columns * ETRhythm.tempogramBins)
        tempogramAdopted = [Float](repeating: 0, count: columns)
        tempogramConfidence = [Float](repeating: 0, count: columns)
    }

    // MARK: 始めから

    /// 解析を捨てて、新しい世代の枠を待つ（beginTelemetryEpoch）。Reset と Min / Max の変更で呼ぶ。
    /// **柵は時刻でなく世代にする。**上流は audioContext の時刻を使うが、ここには無い。
    /// カーネルは Reset でも Min / Max の変更でも世代を進める（kernel.cpp:235-237 の reset、
    /// :495-527 の synchronize が reset を呼ぶ）ので、前の世代の取り残しの枠は受けず、新しい世代の枠から始める。
    func beginEpoch() {
        if let activeGeneration {
            generationFence = activeGeneration
            timeFence = .infinity
        }
        activeGeneration = nil
        clearHistory()
    }

    /// 枠の出どころが替わった（エンジンを作り直した）。世代の数え直しを新しい世代と取り違えない。
    /// 上流の `frame.source` の替わり目（handleTelemetry）に当たる。
    func resetSource() {
        activeGeneration = nil
        generationFence = nil
        timeFence = nil
        clearHistory()
    }

    func clearHistory() {
        let columns = ETRhythm.tempogramColumns
        tempogram = [Float](repeating: 0, count: columns * ETRhythm.tempogramBins)
        tempogramAdopted = [Float](repeating: 0, count: columns)
        tempogramConfidence = [Float](repeating: 0, count: columns)
        tempogramHead = columns - 1
        tempogramDirty = true
        columnPhase = 0
        columnOriginTime = nil
        columnIndex = 0
        columnFrameTime = nil
        lastAdoptedAnchor = nil
        adoptedEpoch = nil
        lastFrameCount = nil
        beatClock = 0
        heldPeriod = nil
        clockHead = ETRhythm.clockCapacity - 1
        clockCount = 0
        clockAnchor = nil
        forwardBeats = []
        forwardEpoch = nil
        forwardOffset = 0
        forwardTail = []
        previewEpoch = nil
        previewPeriod = 0
        displayU = nil
        displayOffsetU = 0
        displayChangeTime = 0
        displayPeriod = 0
        idleStartU = 0
        displayTimelineOffset = 0
        idleScroll = false
        onsetIndices = [:]
        pendingOnsets = []
        referenceRevision = 0
        for i in eventReference.indices { eventReference[i] = nil }
        segments = [:]
        segmentOrder = []
        openSegment = nil
        lensDisplay = nil
        eventSerial = 0
        snapshot = nil
        frameBase = 0
        epochBase = 0
        clearBeatLed()
    }

    /// 点灯を捨てる。Metronome Click を切ったときにも呼ぶ（setParameters）。
    func clearBeatLed() {
        pendingBeats = []
        shownBeatIndices = [:]
        shownBeatOrder = []
        ledBeat = nil
        ledStrength = 0
        ledLevel = 0
    }

    /// カーネルが解析を最初からやり直した（トラックの境目・電源の再開）が、表示は残す。
    /// 新しい世代の枠の番号と epoch は、前の世代のあとに続ける（spliceGeneration）。
    private func spliceGeneration(_ generation: UInt32) {
        pendingOnsets.removeAll()
        activeGeneration = generation
        if let lastFrameCount { frameBase = lastFrameCount }
        epochBase += 1 << 32
        lastFrameCount = nil
        openSegment = nil
        clockAnchor = nil
        forwardBeats = []
        forwardEpoch = nil
        forwardOffset = beatClock
        forwardTail = []
        clearBeatLed()
    }

    /// 世代の続きとして番号を付け直す（rebaseSnapshot）。
    private func rebase(_ snap: inout ETRhythmSnapshot) {
        snap.frameCount += frameBase
        snap.anchorFrame += frameBase
        snap.analysisEpoch += epochBase
        let shift = Double(frameBase) * snap.hopSeconds
        let epochShift = epochBase
        func shifted(_ beats: [ETRhythmBeat]) -> [ETRhythmBeat] {
            beats.map { var b = $0; b.time += shift; b.epoch += epochShift; return b }
        }
        snap.events = snap.events.map { var e = $0; e.time += shift; e.epoch += epochShift; return e }
        snap.forwardBeats = shifted(snap.forwardBeats)
        snap.shownBeats = shifted(snap.shownBeats)
        snap.analysisBeats = shifted(snap.analysisBeats)
        snap.previewBeats = shifted(snap.previewBeats)
    }

    // MARK: 枠を入れる

    /// 枠 1 つを入れる（handleTelemetry）。`now` は壁時計（秒）。
    func ingest(_ frame: ETFrame, now: Double) {
        guard let snap = ETRhythmSnapshot.parse(frame) else { return }
        ingest(snap, now: now)
    }

    func ingest(_ parsed: ETRhythmSnapshot, now: Double) {
        var snap = parsed
        let previousU = displayU == nil ? nil : displayClock(audioNow(now), wall: now)
        let generationChanged = activeGeneration != nil && snap.generation != activeGeneration
        if activeGeneration == nil {
            // 柵の後の枠だけ受ける。時刻の柵が無ければ最初の枠から。
            let afterTime = timeFence == nil || snap.timeSeconds > timeFence!
            let afterGeneration = generationFence.map {
                ETRhythm.isNewerCounter(snap.generation, than: $0)
            } ?? false
            if !afterTime && !afterGeneration { return }
            activeGeneration = snap.generation
            generationFence = nil
            timeFence = nil
        } else if snap.generation != activeGeneration {
            guard ETRhythm.isNewerCounter(snap.generation, than: activeGeneration!) else { return }
            spliceGeneration(snap.generation)
        }
        rebase(&snap)
        // 止まっていた生産者が古い枠の番号から再開しても、経った時間は表示に残す。
        // 普通の配信の揺れは、既にある 2 列ぶんの受け取りの余裕で吸う。
        var interrupted = idleScroll
        if let last = snapshot, let frameTime = columnFrameTime {
            let advanced = Double(snap.frameCount > last.frameCount ? snap.frameCount - last.frameCount : 0)
            interrupted = interrupted
                || now - frameTime - advanced * snap.hopSeconds
                    > ETRhythm.scrollLimitColumns * ETRhythm.columnSeconds
        }
        guard writeTempogram(snap, wall: now) else { return }
        // 確定した拍が先。この枠の onset が自分の epoch の区間を見つけられるように。
        advanceClock(snap)
        updateBeatLed(snap)
        let target = clockPosition(Double(snap.frameCount) * snap.hopSeconds)
        let period = target.period > 0 ? target.period : snap.periodSeconds
        if period > 0 { displayPeriod = period }
        let idle = (snap.confidence == 0 && snap.strongestBpm == 0) || !(period > 0) || !powerUiEnabled
        if let previousU, interrupted || generationChanged {
            displayTimelineOffset = previousU - target.position
        }
        for event in snap.events { storeEvent(event, now: now) }
        refreshProvisionalEvents(snap, now: now)
        snapshot = snap
        let position = target.position + displayTimelineOffset
        displayOffsetU = idle || previousU == nil ? 0 : previousU! - position
        displayChangeTime = now
        displayU = previousU ?? position
        idleStartU = displayU!
        idleScroll = idle
        if snap.analysisValid, let openSegment { openSegment.displayOffset = displayTimelineOffset }
        lastObservedTime = snap.timeSeconds
    }

    /// 描く直前に呼ぶ。点灯を壁時計まで進め、表示の時計を決める（drawGroove の頭）。
    func prepareRender(now: Double) {
        renderWallTime = now
        guard snapshot != nil else { return }
        let audio = audioNow(now)
        advanceBeatLed(audio)
        displayU = displayClock(audio, wall: now)
    }

    // MARK: テンポグラム

    private func writeTempogram(_ snap: ETRhythmSnapshot, wall: Double) -> Bool {
        let columns = ETRhythm.tempogramColumns
        let bins = ETRhythm.tempogramBins
        let now = Double(snap.frameCount) * snap.hopSeconds
        var advance = 1
        if let last = lastFrameCount {
            let delta = UInt32(truncatingIfNeeded: snap.frameCount &- last)
            if delta >= 0x8000_0000 { return false }
        }
        if let origin = columnOriginTime {
            // 列は解析した時刻で進む。最初の枠の時刻が原点。
            let position = (now - origin) / ETRhythm.columnSeconds
            let index = Int(position.rounded(.down))
            advance = max(0, index - columnIndex)
            columnPhase = position - Double(index)
            columnIndex = index
        } else {
            columnOriginTime = now
        }
        if advance >= columns {
            tempogram = [Float](repeating: 0, count: columns * bins)
            tempogramAdopted = [Float](repeating: 0, count: columns)
            tempogramConfidence = [Float](repeating: 0, count: columns)
            advance = 1
        }
        let first = advance == 0 ? 0 : 1
        for step in first...advance {
            let column = (tempogramHead + step) % columns
            for bin in 0..<bins { tempogram[column * bins + bin] = snap.tempogram[bin] }
            if advance > 0 { tempogramAdopted[column] = 0 }
            // 解析の確からしさは、新しい拍を見せているかと関わらず濃さを決める。
            tempogramConfidence[column] = Float(snap.confidence)
        }
        tempogramHead = (tempogramHead + advance) % columns
        if snap.analysisValid, let origin = columnOriginTime {
            let anchor = (Double(snap.anchorFrame) + snap.anchorFraction) * snap.hopSeconds
            if adoptedEpoch != snap.analysisEpoch { lastAdoptedAnchor = nil }
            if lastAdoptedAnchor == nil || anchor > lastAdoptedAnchor! {
                func bucket(_ time: Double) -> Int {
                    columnIndex - Int(((time - origin) / ETRhythm.columnSeconds).rounded(.down))
                }
                let age = bucket(anchor)
                let previousAge = lastAdoptedAnchor.map(bucket) ?? age
                // 新しく確定した履歴を、その解析した時刻の列へ埋める。前に確定した列には触らない。
                var distance = max(0, age)
                while distance <= previousAge && distance < columns {
                    let column = (tempogramHead + columns - distance) % columns
                    if !(tempogramAdopted[column] > 0) {
                        tempogramAdopted[column] = Float(60 / snap.periodSeconds)
                        tempogramConfidence[column] = Float(snap.confidence)
                    }
                    distance += 1
                }
                lastAdoptedAnchor = anchor
                adoptedEpoch = snap.analysisEpoch
            }
        }
        tempogramDirty = true
        columnFrameTime = wall
        lastFrameCount = snap.frameCount
        return true
    }

    /// テンポグラムを、枠の列より左へ何列ぶんずらして描くか。最新の列の解析上の年齢と、
    /// 枠が来てからの壁時計（2 列まで）。上流の tempogramScroll。
    func tempogramScroll(now: Double) -> Double {
        guard let columnFrameTime else { return columnPhase }
        let elapsed = (now - columnFrameTime) / ETRhythm.columnSeconds
        return columnPhase + (elapsed < ETRhythm.scrollLimitColumns ? elapsed : ETRhythm.scrollLimitColumns)
    }

    // MARK: 拍の時計

    /// 確定した拍は書き換えない履歴、先の拍はその一番新しい時計を続ける（advanceClock）。
    private func advanceClock(_ snap: ETRhythmSnapshot) {
        for beat in snap.forwardBeats {
            if forwardEpoch != beat.epoch {
                if forwardEpoch != nil { forwardOffset = beatClock }
                forwardEpoch = beat.epoch
                forwardBeats = []
                clockAnchor = nil
            }
            if !forwardBeats.contains(where: { $0.index == beat.index }) { forwardBeats.append(beat) }
        }
        forwardBeats.sort { $0.time != $1.time ? $0.time < $1.time : $0.index < $1.index }
        if forwardBeats.count > ETRhythm.clockCapacity {
            forwardBeats.removeFirst(forwardBeats.count - ETRhythm.clockCapacity)
        }
        for beat in snap.analysisBeats {
            let segment = analysisSegment(epoch: beat.epoch, index: Int(beat.index))
            if clockCount == 0 || beat.time > clockTimes[clockHead] {
                clockHead = (clockHead + 1) % ETRhythm.clockCapacity
                clockTimes[clockHead] = beat.time
                clockValues[clockHead] = Double(beat.index) + segment.offset
                if clockCount < ETRhythm.clockCapacity { clockCount += 1 }
            }
            if beat.epoch == snap.analysisEpoch,
               clockAnchor == nil || beat.epoch != clockAnchor!.epoch || beat.time > clockAnchor!.time {
                clockAnchor = ETRhythmClockAnchor(time: beat.time, index: Int(beat.index), epoch: beat.epoch,
                                                  periodSeconds: beat.periodSeconds)
            }
            segment.endU = Double(beat.index) + segment.offset
            beatClock = segment.endU
        }
        if snap.analysisValid {
            let time = (Double(snap.anchorFrame) + snap.anchorFraction) * snap.hopSeconds
            let segment = analysisSegment(epoch: snap.analysisEpoch, index: snap.anchorIndex)
            if clockAnchor == nil || time >= clockAnchor!.time {
                clockAnchor = ETRhythmClockAnchor(time: time, index: snap.anchorIndex, epoch: snap.analysisEpoch,
                                                  periodSeconds: snap.periodSeconds)
            }
            beatClock = Double(snap.anchorIndex) + segment.offset
            segment.endU = beatClock
            openSegment = segment
            heldPeriod = snap.periodSeconds
        } else {
            if let anchor = clockAnchor, anchor.epoch != snap.analysisEpoch {
                clockAnchor = nil
                forwardBeats = []
            }
            openSegment = nil
        }
        let anchor = clockAnchor
        // 先の拍のうち、anchor と同じ拍（半拍以内で一番近いもの）は anchor が持つので尾に入れない。
        var matched: Int?
        var distance = Double.infinity
        if let anchor {
            for (i, beat) in forwardBeats.enumerated() {
                let period = anchor.periodSeconds > 0 ? min(anchor.periodSeconds, beat.periodSeconds)
                    : beat.periodSeconds
                let delta = abs(beat.time - anchor.time)
                if delta <= 0.5 * period && delta < distance {
                    matched = i
                    distance = delta
                }
            }
        }
        forwardTail = []
        for (i, beat) in forwardBeats.enumerated() {
            if let anchor, beat.time <= anchor.time || i == matched { continue }
            if forwardTail.last?.time == beat.time { continue }
            let position = anchor.map { Double($0.index + 1 + forwardTail.count) }
                ?? Double(Int(forwardBeats[0].index) + forwardTail.count)
            forwardTail.append(ETRhythmTailBeat(time: beat.time, periodSeconds: beat.periodSeconds,
                                                position: position))
        }
        previewPeriod = snap.previewPeriodSeconds
        previewEpoch = snap.previewBeats.isEmpty ? nil : snap.analysisEpoch
        if let previewEpoch, let first = snap.previewBeats.first {
            let segment = analysisSegment(epoch: previewEpoch, index: Int(first.index))
            if anchor == nil { forwardOffset = segment.offset }
            forwardTail = snap.previewBeats.filter { anchor == nil || $0.time > anchor!.time }.map {
                ETRhythmTailBeat(time: $0.time, periodSeconds: $0.periodSeconds, position: Double($0.index))
            }
        }
    }

    private func analysisSegment(epoch: UInt64, index: Int) -> ETRhythmSegment {
        if let segment = segments[epoch] { return segment }
        let segment = ETRhythmSegment(epoch: epoch, offset: beatClock - Double(index), startU: beatClock,
                                      endU: beatClock, reanchor: openSegment != nil)
        segments[epoch] = segment
        segmentOrder.append(epoch)
        if segmentOrder.count > ETRhythm.maxSegments {
            let oldest = segmentOrder.removeFirst()
            segments[oldest] = nil
        }
        return segment
    }

    /// 解析した時刻での拍の位置と、そこでの拍の間隔（clockPosition）。履歴は anchor までを補間し、
    /// それより先は先の拍の尾をたどる。**表示の補正を足す前**の、生産者と同じ写し。
    func clockPosition(_ time: Double) -> (position: Double, period: Double) {
        let capacity = ETRhythm.clockCapacity
        let offset = clockAnchor.map { segments[$0.epoch]?.offset ?? 0 } ?? forwardOffset
        if let anchor = clockAnchor, time <= anchor.time, clockCount > 0 {
            var index = clockHead
            if time >= clockTimes[index] {
                let left = clockTimes[index]
                let period = anchor.time - left
                let position = period > 0
                    ? clockValues[index] + (time - left) / period * (Double(anchor.index) + offset - clockValues[index])
                    : Double(anchor.index) + offset
                return (position, period)
            }
            if clockCount > 1 {
                for _ in 1..<clockCount {
                    let older = (index + capacity - 1) % capacity
                    let period = clockTimes[index] - clockTimes[older]
                    if time >= clockTimes[older] {
                        return (clockValues[older] + (time - clockTimes[older]) / period
                                * (clockValues[index] - clockValues[older]), period)
                    }
                    index = older
                }
            }
            return (clockValues[index], 0)
        }
        var left: (time: Double, position: Double, period: Double)? = clockAnchor.map {
            ($0.time, Double($0.index) + offset, previewPeriod > 0 ? previewPeriod : $0.periodSeconds)
        }
        for beat in forwardTail {
            let right = (time: beat.time, position: beat.position + offset, period: beat.periodSeconds)
            if time <= right.time {
                guard let left else {
                    return (right.position + (time - right.time) / right.period, right.period)
                }
                let period = right.time - left.time
                return (left.position + (time - left.time) / period, period)
            }
            left = right
        }
        if let left, left.period > 0 {
            return (left.position + (time - left.time) / left.period, left.period)
        }
        return (left?.position ?? beatClock, 0)
    }

    func clockAt(_ time: Double) -> Double {
        clockPosition(time).position
    }

    // MARK: 表示の時計

    /// 壁時計 `wall` のときの、解析した時刻（最後の枠 + 経った時間）。
    func audioNow(_ wall: Double) -> Double {
        guard let snapshot else { return 0 }
        return Double(snapshot.frameCount) * snapshot.hopSeconds + max(0, wall - (columnFrameTime ?? wall))
    }

    /// 描く拍の位置。解析した時計に、枠が来たときの食い違いを 100 ms の指数で消す補正を足す。
    /// 止まっている間（無音・枠が来ない）は、最後の周期で流し続ける。
    func displayClock(_ audioTime: Double, wall: Double) -> Double {
        if idleScroll || !powerUiEnabled {
            return idleStartU + (displayPeriod > 0 ? max(0, wall - displayChangeTime) / displayPeriod : 0)
        }
        let weight = exp(-max(0, wall - displayChangeTime) / ETRhythm.positionSmoothing)
        return clockAt(audioTime) + displayTimelineOffset + displayOffsetU * weight
    }

    /// 描く onset の位置とずれ。確定や仮の置き直しの食い違いを、100 ms の指数で消す。
    func displayedEvent(_ index: Int, wall: Double) -> (u: Double, deviation: Double) {
        let weight = exp(-max(0, wall - eventCorrectionTime[index]) / ETRhythm.positionSmoothing)
        return (eventU[index] + eventTimelineOffset[index] + eventOffsetU[index] * weight,
                eventDeviation[index] + eventOffsetDeviation[index] * weight)
    }

    // MARK: ビート LED

    /// 見せる拍（flags 2）を、その時刻が来たら点ける（updateBeatLed）。
    /// 同じ epoch で番号が進んでいない拍は出し直しなので受けない。明るさは拍の強さ倍。
    /// 無音（確からしさも最強候補も 0）では、待っている拍も覚えている番号も捨てる。
    private func updateBeatLed(_ snap: ETRhythmSnapshot) {
        if snap.confidence == 0 && snap.strongestBpm == 0 { clearBeatLed() }
        let now = Double(snap.frameCount) * snap.hopSeconds
        for beat in snap.shownBeats {
            if let previous = shownBeatIndices[beat.epoch], beat.index <= previous { continue }
            if shownBeatIndices[beat.epoch] == nil { shownBeatOrder.append(beat.epoch) }
            shownBeatIndices[beat.epoch] = beat.index
            if shownBeatOrder.count > ETRhythm.maxSegments {
                shownBeatIndices[shownBeatOrder.removeFirst()] = nil
            }
            pendingBeats.append((time: beat.time > now ? beat.time : now, strength: beat.strength))
        }
        pendingBeats.sort { $0.time < $1.time }
        advanceBeatLed(now)
    }

    private func advanceBeatLed(_ now: Double) {
        while let first = pendingBeats.first, first.time <= now {
            pendingBeats.removeFirst()
            ledBeat = first.time
            ledStrength = first.strength
        }
        let level = ledBeat.map { 1 - (now - $0) / ETRhythm.ledFadeSeconds } ?? 0
        ledLevel = (level > 0 ? level : 0) * ledStrength
    }

    // MARK: onset

    /// onset を環に置く。仮のものは確定したら同じ札で来るので、同じ場所を置き直す（storeEvent）。
    /// 確定した点は動かさない。
    func storeEvent(_ event: ETRhythmEvent, now: Double) {
        let previousSerial = onsetIndices[event.identity]
        let serial: Int
        if let previousSerial {
            serial = previousSerial
        } else {
            serial = eventSerial
            eventSerial += 1
        }
        let index = serial % ETRhythm.eventCapacity
        if previousSerial != nil && eventTimed[index] { return }
        let previous = previousSerial == nil ? nil : displayedEvent(index, wall: now)
        if previousSerial == nil {
            pendingOnsets.remove(serial - ETRhythm.eventCapacity)
            eventReference[index] = nil
            if let old = eventKeys[index] { onsetIndices[old] = nil }
            eventKeys[index] = event.identity
            onsetIndices[event.identity] = serial
            eventTimelineOffset[index] = displayTimelineOffset
        }
        let segment = event.annotated || event.provisional ? segments[event.epoch] : nil
        let u = segment.map { event.position + $0.offset } ?? clockAt(event.time)
        eventU[index] = u
        eventTime[index] = event.time
        eventBand[index] = event.band
        eventStrength[index] = event.strength
        eventEpoch[index] = event.epoch
        let wasTimed = eventTimed[index]
        eventTimed[index] = event.annotated && segment != nil
        if wasTimed || eventTimed[index] { referenceRevision += 1 }
        if event.annotated || (previousSerial != nil && !event.provisional) {
            pendingOnsets.remove(serial)
        } else {
            pendingOnsets.insert(serial)
        }
        eventLocated[index] = event.annotated || event.provisional
        eventNovel[index] = false
        eventDeviation[index] = 0
        if event.annotated || event.provisional {
            annotateEvent(fraction: event.beatFraction, period: event.periodSeconds, epoch: event.epoch,
                          annotated: event.annotated, segment: segment, serial: serial, u: u)
        }
        eventOffsetU[index] = previous.map { $0.u - u - eventTimelineOffset[index] } ?? 0
        eventOffsetDeviation[index] = previous.map { $0.deviation - eventDeviation[index] } ?? 0
        eventCorrectionTime[index] = now
    }

    /// 新しい先の拍の見込みが来るたびに、まだ確定していない onset を元の解析した時刻のまま置き直す。
    private func refreshProvisionalEvents(_ snap: ETRhythmSnapshot, now: Double) {
        guard !snap.previewBeats.isEmpty, let segment = segments[snap.analysisEpoch] else { return }
        let epoch = snap.analysisEpoch
        for serial in pendingOnsets.sorted() {
            let index = serial % ETRhythm.eventCapacity
            if eventEpoch[index] != epochBase && eventEpoch[index] != epoch {
                pendingOnsets.remove(serial)
                continue
            }
            let target = clockPosition(eventTime[index])
            guard target.period > 0 else { continue }
            let position = target.position - segment.offset
            let fraction = position - position.rounded(.down)
            let triplet = segment.triplet > segment.straight
            if eventLocated[index], eventEpoch[index] == epoch, eventU[index] == target.position,
               eventPreviewPeriod[index] == target.period, eventPreviewTriplet[index] == triplet,
               eventReference[index]?.revision == referenceRevision { continue }
            let previous = displayedEvent(index, wall: now)
            eventPreviewPeriod[index] = target.period
            eventPreviewTriplet[index] = triplet
            eventU[index] = target.position
            eventEpoch[index] = epoch
            eventLocated[index] = true
            annotateEvent(fraction: fraction, period: target.period, epoch: epoch, annotated: false,
                          segment: segment, serial: serial, u: target.position)
            if previous.u != target.position + eventTimelineOffset[index]
                || previous.deviation != eventDeviation[index] {
                eventOffsetU[index] = previous.u - target.position - eventTimelineOffset[index]
                eventOffsetDeviation[index] = previous.deviation - eventDeviation[index]
                eventCorrectionTime[index] = now
            }
        }
    }

    /// 拍の中の位置を格子に吸わせて、ずれ（ms）を出す。格子（16 分の正拍か 3 連の 8 分か）は
    /// epoch ごとに、確定した onset の投票で決める（annotateEvent）。
    private func annotateEvent(fraction: Double, period: Double, epoch: UInt64, annotated: Bool,
                               segment: ETRhythmSegment?, serial: Int, u: Double) {
        let index = serial % ETRhythm.eventCapacity
        func nearest(_ grid: ETRhythm.Grid) -> Int {
            var best = 0
            for point in 1..<grid.points.count
            where abs(fraction - grid.points[point]) < abs(fraction - grid.points[best]) { best = point }
            return best
        }
        let straight = nearest(ETRhythm.straightGrid)
        let triplet = nearest(ETRhythm.tripletGrid)
        let straightError = abs(fraction - ETRhythm.straightGrid.points[straight])
        let tripletError = abs(fraction - ETRhythm.tripletGrid.points[triplet])
        if annotated, let segment {
            if straightError < tripletError { segment.straight += 1 }
            else if tripletError < straightError { segment.triplet += 1 }
        }
        let useTriplet = segment.map { $0.triplet > $0.straight } ?? false
        let grid = useTriplet ? ETRhythm.tripletGrid : ETRhythm.straightGrid
        let point = useTriplet ? triplet : straight
        let raw = (fraction - grid.points[point]) * period * 1000
        eventSlot[index] = grid.slots[point]
        eventFraction[index] = fraction
        eventRawDeviation[index] = raw
        // 相対の揺れ。epoch の直前 16 拍の中央値の差は共通の遅れで、グルーヴではない。
        eventDeviation[index] = raw - referenceDeviation(serial: serial, u: u, epoch: epoch)
        eventNovel[index] = eventTimed[index] && isNovel(serial: serial)
    }

    /// 環に残っている一番古い通し番号。
    var oldestSerial: Int {
        let oldest = eventSerial - ETRhythm.eventCapacity
        return oldest > 0 ? oldest : 0
    }

    /// from <= u <= to の onset を新しい順に見る。環は届いた順で、拍の時計の順にほぼ近いので、
    /// 補正前の位置で見るときは範囲の 1 拍下で打ち切る。`displayed` なら表示の位置で、全部を見る。
    func forEachEvent(from: Double, to: Double, before: Int? = nil, displayed: Bool = false,
                      _ visit: (Int) -> Void) {
        let oldest = oldestSerial
        var serial = (before ?? eventSerial) - 1
        while serial >= oldest {
            let index = serial % ETRhythm.eventCapacity
            let u = displayed ? displayedEvent(index, wall: renderWallTime).u : eventU[index]
            if !displayed && u < from - 1 { break }
            if u >= from && u <= to { visit(index) }
            serial -= 1
        }
    }

    /// 同じ epoch の直前 16 拍の、拍に乗った onset のずれの中央値（4 つ未満なら 0）。
    /// 入っている onset の集まりと、その座標の範囲を覚えておき、同じ集まりの間は中央値を使い回す。
    private func referenceDeviation(serial: Int, u: Double, epoch: UInt64) -> Double {
        let index = serial % ETRhythm.eventCapacity
        let cached = eventReference[index]
        let sameEvent = cached?.serial == serial && cached?.epoch == epoch
        if sameEvent, let cached, cached.revision == referenceRevision, u >= cached.lower, u < cached.upper {
            return cached.median
        }
        var values: [Double] = []
        var members: [Int] = []
        var lower = -Double.infinity
        var upper = Double.infinity
        var previous = serial - 1
        while previous >= oldestSerial {
            let other = previous % ETRhythm.eventCapacity
            previous -= 1
            guard eventTimed[other], eventEpoch[other] == epoch else { continue }
            let position = eventU[other]
            if position > u {
                upper = min(upper, position)
            } else if position <= u - ETRhythm.referenceBeats {
                lower = max(lower, position + ETRhythm.referenceBeats)
            } else {
                lower = max(lower, position)
                upper = min(upper, position + ETRhythm.referenceBeats)
                members.append(previous + 1)
                values.append(eventRawDeviation[other])
            }
        }
        let unchanged = sameEvent && cached?.members == members
        let median = unchanged ? cached!.median
            : (values.count >= ETRhythm.minimumEvents ? ETRhythm.median(values) : 0)
        eventReference[index] = ReferenceCache(serial: serial, epoch: epoch, revision: referenceRevision,
                                               lower: lower, upper: upper, members: members, median: median)
        return median
    }

    /// 拍に乗った onset が新しいのは、同じ帯域・同じ epoch で 1 Span か 2 Span 前に、拍に乗った onset が
    /// 無かったとき（isNovel）。
    private func isNovel(serial: Int) -> Bool {
        let index = serial % ETRhythm.eventCapacity
        guard let segment = segments[eventEpoch[index]] else { return false }
        let spanBeats = Double(span)
        let u = eventU[index]
        if u - spanBeats < segment.startU + 0.5 { return false }
        let band = eventBand[index]
        let epoch = eventEpoch[index]
        func matches(_ target: Double) -> Bool {
            var hit = false
            forEachEvent(from: target - ETRhythm.matchBeats, to: target + ETRhythm.matchBeats,
                         before: serial) { other in
                if eventTimed[other] && eventBand[other] == band && eventEpoch[other] == epoch
                    && eventU[other] > target - ETRhythm.matchBeats
                    && eventU[other] < target + ETRhythm.matchBeats { hit = true }
            }
            return hit
        }
        return !(matches(u - spanBeats)
                 || (u - 2 * spanBeats >= segment.startU && matches(u - 2 * spanBeats)))
    }

    /// Span を変えたあと、新規の印を付け直す。
    func refreshNovelty() {
        var serial = oldestSerial
        while serial < eventSerial {
            let index = serial % ETRhythm.eventCapacity
            eventNovel[index] = eventTimed[index] && isNovel(serial: serial)
            serial += 1
        }
    }

    /// 環に置いた onset の素の値（表示の補正を足す前）。試験が読む。
    func eventInfo(_ index: Int) -> (u: Double, time: Double, timed: Bool, located: Bool,
                                      deviation: Double, epoch: UInt64) {
        (eventU[index], eventTime[index], eventTimed[index], eventLocated[index], eventDeviation[index],
         eventEpoch[index])
    }

    // MARK: 描くための読み

    struct EventPoint {
        var x: Double
        var y: Double
        var radius: Double
        /// 拍の位置に置けている（確定、または仮で置いた）。置けていないものは輪で描く。
        var located: Bool
        var novel: Bool
        var band: Int
        var deviation: Double
        var index: Int
    }

    /// 窓（from..to）の中の onset を、描く点にして返す。`view` は 1 つの時計の窓。
    struct LaneView {
        var left: Double
        var top: Double
        var width: Double
        var height: Double
        var uRight: Double
        var span: Int
        var echo: Bool
    }

    func eventPoint(index: Int, view: LaneView) -> EventPoint {
        let strength = eventStrength[index] > 1 ? 1 : eventStrength[index]
        let displayed = displayedEvent(index, wall: renderWallTime)
        let x = view.left + (displayed.u - view.uRight + Double(view.span)) / Double(view.span) * view.width
        let band = eventBand[index]
        var y: Double
        var radius: Double
        if view.echo {
            y = view.top + (0.5 + (Double(ETRhythm.bandRows[band]) - 1) * 0.28) * view.height
            radius = (0.025 + 0.035 * strength) * view.height
        } else {
            let lane = view.height / 3
            let limit = ETRhythm.deviationMS
            let deviation = displayed.deviation
            let clipped = deviation < -limit ? -limit : (deviation > limit ? limit : deviation)
            y = view.top + (Double(ETRhythm.bandRows[band]) + 0.5) * lane
                - (eventLocated[index] ? clipped / limit * 0.45 * lane : 0)
            radius = (0.025 + 0.04 * strength) * lane
        }
        radius = min(max(radius, 1.5), 3.5)
        return EventPoint(x: x, y: y, radius: radius, located: eventLocated[index], novel: eventNovel[index],
                          band: band, deviation: displayed.deviation, index: index)
    }

    /// 窓の中の onset を、古い順に点にして返す。表示の位置で選ぶ（確定や置き直しの補正の途中でも窓から外れない）。
    func points(for view: LaneView) -> [EventPoint] {
        var out: [EventPoint] = []
        let from = view.uRight - Double(view.span)
        forEachEvent(from: from - 0.2, to: view.uRight + 0.2, displayed: true) { index in
            out.append(eventPoint(index: index, view: view))
        }
        // 古い順に描く（forEachEvent は新しい順）。
        return out.reversed()
    }

    // MARK: ビートレンズ

    /// いまの拍の追跡の epoch の直前 32 拍で、帯域ごと・スロットごとの、重み付き中央値からのずれとばらつき、
    /// それにスウィングとジッタ。解析した拍が無いあいだは nil。
    func lensSummary() -> ETRhythmLens? {
        guard snapshot?.analysisValid == true, let segment = openSegment else { return nil }
        var count = [Int](repeating: 0, count: 18)
        var sum = [Double](repeating: 0, count: 18)
        var squareSum = [Double](repeating: 0, count: 18)
        var fractions: [Double] = []
        forEachEvent(from: beatClock - ETRhythm.lensBeats, to: .infinity) { index in
            guard eventTimed[index], eventEpoch[index] == segment.epoch,
                  eventU[index] > beatClock - ETRhythm.lensBeats else { return }
            let cell = eventBand[index] * 6 + eventSlot[index]
            let deviation = eventDeviation[index]
            count[cell] += 1
            sum[cell] += deviation
            squareSum[cell] += deviation * deviation
            let fraction = eventFraction[index]
            if fraction > 0.4 && fraction < 0.8 { fractions.append(fraction) }
        }
        var rows: [ETRhythmLensRow] = []
        var total = 0
        var spread = 0.0
        for cell in 0..<18 where count[cell] >= ETRhythm.minimumEvents {
            let mean = sum[cell] / Double(count[cell])
            let variance = squareSum[cell] / Double(count[cell]) - mean * mean
            let sd = (variance > 0 ? variance : 0).squareRoot()
            rows.append(ETRhythmLensRow(band: cell / 6, slot: cell % 6, mean: mean, sd: sd, count: count[cell]))
            total += count[cell]
            spread += Double(count[cell]) * sd * sd
        }
        if !rows.isEmpty {
            let sorted = rows.sorted { $0.mean < $1.mean }
            var cumulative = 0
            var reference = sorted[sorted.count - 1].mean
            for row in sorted {
                cumulative += row.count
                if Double(cumulative) >= 0.5 * Double(total) { reference = row.mean; break }
            }
            for i in rows.indices { rows[i].offset = rows[i].mean - reference }
        }
        let swing = fractions.count >= ETRhythm.minimumEvents ? ETRhythm.median(fractions) : .nan
        return ETRhythmLens(rows: rows, swing: swing / (1 - swing),
                            jitter: rows.isEmpty ? .nan : (spread / Double(total)).squareRoot())
    }

    /// 帯域ごとに、壁時計で別々になめらかにする（解析は変えない）。
    func displayedLens(_ lens: ETRhythmLens?, now: Double) -> ETRhythmLens? {
        guard let lens else {
            lensDisplay = nil
            return nil
        }
        let epoch = openSegment?.epoch
        let previous = lensDisplay.flatMap { $0.epoch == epoch ? $0 : nil }
        let weight = previous.map { 1 - exp(-(now - $0.time) * 1000 / ETRhythm.lensSmoothingMS) } ?? 1
        var cells = [ETRhythmLensRow?](repeating: nil, count: 18)
        let rows = lens.rows.map { row -> ETRhythmLensRow in
            let cell = row.band * 6 + row.slot
            var displayed = row
            if let from = previous?.cells[cell] {
                displayed.offset = from.offset + weight * (row.offset - from.offset)
                displayed.sd = from.sd + weight * (row.sd - from.sd)
            }
            cells[cell] = displayed
            return displayed
        }
        lensDisplay = (epoch, now, cells)
        return ETRhythmLens(rows: rows, swing: lens.swing, jitter: lens.jitter)
    }
}
