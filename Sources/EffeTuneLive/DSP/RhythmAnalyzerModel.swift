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
//  Telemetry は Rhythm Analyzer の枠だけ届いた順に全部取っておく（Telemetry.drainRhythmFrames）。
//
//  2.13.0 で上流の画面は大きく書き直された（先の拍の見込み・確定した拍の時計・仮の onset の差し替え）。
//  ここは枠を版 4 として読み、今までの画面の計算に当てはめるところまで。拍の時計は anchor（解析した拍）
//  から、LED は見せる拍（flags 2）から進める。仮の onset（flags 3）は後で確定した onset が来るので入れない。

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
    static let defaultPeriod = 0.5
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
    var locked: Bool
    /// 仮の onset（flags 3）。後で同じ onset が確定して来る。
    var provisional = false
    /// 解析した時刻（生成の始めからの秒）。
    var time: Double
    var epoch: UInt32
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
    var epoch: UInt32
    var periodSeconds: Double
    var strength: Double
}

struct ETRhythmSnapshot: Equatable {
    var sampleRate: Double
    var generation: UInt32
    var hop: UInt32
    var frameCount: UInt32
    var timeSeconds: Double
    var latencySeconds: Double
    var droppedEvents: UInt32
    var eventCount: Int
    /// trackerFlags が 1。拍の音（Metronome Click）を鳴らしてよい。
    var tickGateOpen: Bool
    var analysisEpoch: UInt32
    var confidence: Double
    var periodSeconds: Double
    /// 解析した拍（anchor）の位置。
    var anchorFrame: UInt32
    var anchorFraction: Double
    var anchorIndex: UInt32
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
            sampleRate: Double(rate), generation: generation, hop: hop, frameCount: frameCount,
            timeSeconds: Double(time), latencySeconds: Double(latency), droppedEvents: dropped,
            eventCount: Int(eventCount), tickGateOpen: flags == 1, analysisEpoch: epoch,
            confidence: Double(confidence), periodSeconds: Double(period), anchorFrame: anchorFrame,
            anchorFraction: Double(anchorFraction), anchorIndex: anchorIndex,
            strongestBpm: Double(strongest), tempogram: tempogram, events: [], sequence: frame.sequence)
        for slot in 0..<Int(eventCount) {
            let base = ETRhythm.eventsOffset + ETRhythm.eventBytes * slot
            guard let frameNumber = p.u32(at: base), let signedFrame = p.i32(at: base),
                  let fraction = p.f32(at: base + 4),
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
                let beat = ETRhythmBeat(time: at, index: index, epoch: eventEpoch,
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
                locked: annotated,
                provisional: kind == 3,
                time: at,
                epoch: eventEpoch,
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
                                    epoch: epoch, periodSeconds: Double(previewPeriod), strength: 0)
            if let previous = snapshot.previewBeats.last,
               beat.time <= previous.time || Int64(beat.index) != Int64(previous.index) + 1 { return nil }
            snapshot.previewBeats.append(beat)
        }
        return snapshot
    }
}

// MARK: - 履歴

/// 拍の時計の区間。ロックの epoch ごと（clock の offset・範囲・拍の格子の多数決）。
final class ETRhythmSegment {
    let epoch: UInt32
    var offset: Double
    var startU: Double
    var endU: Double
    var reanchor: Bool
    var straight = 0
    var triplet = 0

    init(epoch: UInt32, offset: Double, startU: Double, endU: Double, reanchor: Bool) {
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

/// 画面が持つ履歴と、その計算。**参照型。**枠が来るたびに進め、描く側は読むだけ。
final class ETRhythmState {

    // 表示だけの設定（sp）。変えたら refreshNovelty を呼ぶ。
    var span = ETRhythm.defaultSpan

    // 世代と時刻の柵。
    private(set) var activeGeneration: UInt32?
    private var generationFence: UInt32?
    private var timeFence: Double?
    private(set) var lastObservedTime: Double?

    // テンポグラム。列は 160、新しいものが head。
    private(set) var tempogram: [Float]
    private(set) var tempogramAdopted: [Float]
    private(set) var tempogramConfidence: [Float]
    private(set) var tempogramHead = ETRhythm.tempogramColumns - 1
    private(set) var columnPhase = 0.0
    private(set) var columnFrameTime: Double?
    private var lastFrameCount: UInt32?
    /// テンポグラムが書き変わったか（画像を作り直す印）。
    var tempogramDirty = true

    // 拍の時計。
    private(set) var beatClock = 0.0
    private(set) var heldPeriod: Double?
    private var clockTimes = [Double](repeating: 0, count: ETRhythm.clockCapacity)
    private var clockValues = [Double](repeating: 0, count: ETRhythm.clockCapacity)
    private var clockHead = ETRhythm.clockCapacity - 1
    private var clockCount = 0
    private(set) var segments: [UInt32: ETRhythmSegment] = [:]
    /// segments の挿入順（古い順）。JS の Map の順。
    private(set) var segmentOrder: [UInt32] = []
    private(set) var openSegment: ETRhythmSegment?

    // onset の環。
    private var eventU = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventBand = [Int](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventStrength = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventEpoch = [UInt32](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventTimed = [Bool](repeating: false, count: ETRhythm.eventCapacity)
    private var eventNovel = [Bool](repeating: false, count: ETRhythm.eventCapacity)
    private var eventSlot = [Int](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventFraction = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventRawDeviation = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private var eventDeviation = [Double](repeating: 0, count: ETRhythm.eventCapacity)
    private(set) var eventSerial = 0

    private var lensDisplay: (epoch: UInt32?, time: Double, cells: [ETRhythmLensRow?])?
    private(set) var snapshot: ETRhythmSnapshot?

    // ビート LED（見せる拍、flags 2）。
    private var pendingBeats: [(time: Double, strength: Double)] = []
    /// epoch ごとに、最後に受けた見せる拍の番号。挿入順も持つ（JS の Map の順）。
    private var shownBeatIndices: [UInt32: Int32] = [:]
    private var shownBeatOrder: [UInt32] = []
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
    /// 上流の `frame.source` の替わり目（handleTelemetry、:424-431）に当たる。
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
        columnFrameTime = nil
        lastFrameCount = nil
        beatClock = 0
        heldPeriod = nil
        clockHead = ETRhythm.clockCapacity - 1
        clockCount = 0
        segments = [:]
        segmentOrder = []
        openSegment = nil
        lensDisplay = nil
        eventSerial = 0
        snapshot = nil
        clearBeatLed()
    }

    private func clearBeatLed() {
        pendingBeats = []
        shownBeatIndices = [:]
        shownBeatOrder = []
        ledBeat = nil
        ledStrength = 0
        ledLevel = 0
    }

    // MARK: 枠を入れる

    /// 枠 1 つを入れる（handleTelemetry、rhythm_analyzer.js:421-451）。`now` は壁時計（秒）。
    func ingest(_ frame: ETFrame, now: Double) {
        guard let snap = ETRhythmSnapshot.parse(frame) else { return }
        ingest(snap, now: now)
    }

    func ingest(_ snap: ETRhythmSnapshot, now: Double) {
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
            clearHistory()
            activeGeneration = snap.generation
        }
        let frames: UInt32 = lastFrameCount.map { snap.frameCount &- $0 } ?? 0
        guard writeTempogram(snap, now: now) else { return }
        // 追跡の状態と拍の時計が先。この枠の onset が自分の epoch の offset を見つけられるように。
        advanceClock(snap, dt: Double(frames) * snap.hopSeconds)
        updateBeatLed(snap)
        // 仮の onset は入れない。同じ onset が確定（flags 0）か拍に乗らない（flags 1）で後から来る。
        for event in snap.events where !event.provisional { storeEvent(event) }
        snapshot = snap
        lastObservedTime = snap.timeSeconds
    }

    // MARK: テンポグラム

    private func writeTempogram(_ snap: ETRhythmSnapshot, now: Double) -> Bool {
        let columns = ETRhythm.tempogramColumns
        let bins = ETRhythm.tempogramBins
        var advance = 1
        if let last = lastFrameCount {
            let delta = snap.frameCount &- last
            if delta >= 0x8000_0000 { return false }
            columnPhase += Double(delta) * snap.hopSeconds / ETRhythm.columnSeconds
            advance = Int(columnPhase.rounded(.down))
            columnPhase -= Double(advance)
        }
        if advance >= columns {
            tempogram = [Float](repeating: 0, count: columns * bins)
            tempogramAdopted = [Float](repeating: 0, count: columns)
            tempogramConfidence = [Float](repeating: 0, count: columns)
            advance = 1
        }
        let first = advance == 0 ? 0 : 1
        if first <= advance {
            for step in first...advance {
                let column = (tempogramHead + step) % columns
                for bin in 0..<bins { tempogram[column * bins + bin] = snap.tempogram[bin] }
                tempogramAdopted[column] = snap.analysisValid ? Float(60 / snap.periodSeconds) : 0
                // 枠の確からしさが採用した線の濃さになる。
                tempogramConfidence[column] = Float(snap.confidence)
            }
        }
        tempogramHead = (tempogramHead + advance) % columns
        tempogramDirty = true
        columnFrameTime = now
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

    private func advanceClock(_ snap: ETRhythmSnapshot, dt: Double) {
        let now = Double(snap.frameCount) * snap.hopSeconds
        if snap.analysisValid {
            // anchor は解析した拍（過去のことが多い）。そこから周期で今の位置を出す。
            let period = snap.periodSeconds
            let untilBeat = (Double(snap.anchorFrame) - Double(snap.frameCount) + snap.anchorFraction)
                * snap.hopSeconds
            let position = Double(snap.anchorIndex) - untilBeat / period
            let segment: ETRhythmSegment
            if let existing = segments[snap.analysisEpoch] {
                segment = existing
            } else {
                let previous = openSegment
                segment = ETRhythmSegment(epoch: snap.analysisEpoch, offset: beatClock - position,
                                          startU: previous?.endU ?? beatClock, endU: beatClock,
                                          reanchor: previous != nil)
                segments[snap.analysisEpoch] = segment
                segmentOrder.append(snap.analysisEpoch)
                if segmentOrder.count > ETRhythm.maxSegments {
                    let oldest = segmentOrder.removeFirst()
                    segments[oldest] = nil
                }
            }
            let predicted = beatClock + dt / period
            let gain = 3 * dt < 1 ? 3 * dt : 1
            let next = predicted + gain * (position + segment.offset - predicted)
            if next > beatClock { beatClock = next }
            segment.endU = beatClock
            openSegment = segment
            heldPeriod = period
        } else {
            beatClock += dt / (heldPeriod ?? ETRhythm.defaultPeriod)
            openSegment = nil
        }
        clockHead = (clockHead + 1) % ETRhythm.clockCapacity
        clockTimes[clockHead] = now
        clockValues[clockHead] = beatClock
        if clockCount < ETRhythm.clockCapacity { clockCount += 1 }
    }

    /// 解析した時刻での拍の時計（clockAt）。履歴から補間する。
    func clockAt(_ time: Double) -> Double {
        let capacity = ETRhythm.clockCapacity
        let period = heldPeriod ?? ETRhythm.defaultPeriod
        var index = clockHead
        if clockCount == 0 { return beatClock }
        if time >= clockTimes[index] { return clockValues[index] + (time - clockTimes[index]) / period }
        if clockCount > 1 {
            for _ in 1..<clockCount {
                let older = (index + capacity - 1) % capacity
                let olderTime = clockTimes[older]
                if time >= olderTime {
                    let weight = (time - olderTime) / (clockTimes[index] - olderTime)
                    return clockValues[older] + weight * (clockValues[index] - clockValues[older])
                }
                index = older
            }
        }
        return clockValues[index] - (clockTimes[index] - time) / period
    }

    // MARK: ビート LED

    /// 見せる拍を、その時刻が来たら点ける（updateBeatLed・advanceBeatLed、rhythm_analyzer.js:705-728）。
    /// 同じ epoch で番号が進んでいない拍は出し直しなので受けない。明るさは拍の強さ倍。
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
        while let first = pendingBeats.first, first.time <= now {
            pendingBeats.removeFirst()
            ledBeat = first.time
            ledStrength = first.strength
        }
        let level = ledBeat.map { 1 - (now - $0) / ETRhythm.ledFadeSeconds } ?? 0
        ledLevel = (level > 0 ? level : 0) * ledStrength
    }

    /// 最後に点いた拍からの経過（ms）。ビジュアライザ用の連続した減衰には使わず、
    /// 枠の間も減衰を続けて描くための量（drawVisualizerRhythm の ageMs に当たる）。
    func ledAgeMilliseconds(now: Double) -> Double? {
        guard let snapshot, let ledBeat else { return nil }
        let analysed = Double(snapshot.frameCount) * snapshot.hopSeconds
        let wall = columnFrameTime.map { now - $0 } ?? 0
        return max(0, (analysed - ledBeat) * 1000 + wall * 1000)
    }

    // MARK: onset

    private func storeEvent(_ event: ETRhythmEvent) {
        let segment = event.locked ? segments[event.epoch] : nil
        let serial = eventSerial
        eventSerial += 1
        let index = serial % ETRhythm.eventCapacity
        let u = segment.map { event.position + $0.offset } ?? clockAt(event.time)
        eventU[index] = u
        eventBand[index] = event.band
        eventStrength[index] = event.strength
        eventEpoch[index] = event.epoch
        eventTimed[index] = segment != nil
        eventNovel[index] = false
        guard let segment else { return }
        let fraction = event.beatFraction
        func nearest(_ grid: ETRhythm.Grid) -> Int {
            var best = 0
            for point in 1..<grid.points.count
            where abs(fraction - grid.points[point]) < abs(fraction - grid.points[best]) { best = point }
            return best
        }
        // 16 分の正拍と 3 連の 8 分のどちらの格子に吸わせるかは、epoch ごとの投票で決める。
        let straight = nearest(ETRhythm.straightGrid)
        let triplet = nearest(ETRhythm.tripletGrid)
        let straightError = abs(fraction - ETRhythm.straightGrid.points[straight])
        let tripletError = abs(fraction - ETRhythm.tripletGrid.points[triplet])
        if straightError < tripletError { segment.straight += 1 }
        else if tripletError < straightError { segment.triplet += 1 }
        let useTriplet = segment.triplet > segment.straight
        let grid = useTriplet ? ETRhythm.tripletGrid : ETRhythm.straightGrid
        let point = useTriplet ? triplet : straight
        let raw = (fraction - grid.points[point]) * event.periodSeconds * 1000
        eventSlot[index] = grid.slots[point]
        eventFraction[index] = fraction
        eventRawDeviation[index] = raw
        // 相対の揺れ。epoch の直前 16 拍の中央値の差は共通の遅れで、グルーヴではない。
        eventDeviation[index] = raw - referenceDeviation(serial: serial, u: u, epoch: event.epoch)
        eventNovel[index] = isNovel(serial: serial)
    }

    /// 環に残っている一番古い通し番号。
    var oldestSerial: Int {
        let oldest = eventSerial - ETRhythm.eventCapacity
        return oldest > 0 ? oldest : 0
    }

    /// from <= u <= to の onset を新しい順に見る。環は届いた順で、拍の時計の順にほぼ並ぶので、
    /// 範囲の 1 拍下で打ち切る。
    func forEachEvent(from: Double, to: Double, before: Int? = nil, _ visit: (Int) -> Void) {
        let oldest = oldestSerial
        var serial = (before ?? eventSerial) - 1
        while serial >= oldest {
            let index = serial % ETRhythm.eventCapacity
            let u = eventU[index]
            if u < from - 1 { break }
            if u >= from && u <= to { visit(index) }
            serial -= 1
        }
    }

    private func referenceDeviation(serial: Int, u: Double, epoch: UInt32) -> Double {
        var values: [Double] = []
        forEachEvent(from: u - ETRhythm.referenceBeats, to: u, before: serial) { index in
            if eventTimed[index] && eventEpoch[index] == epoch && eventU[index] > u - ETRhythm.referenceBeats {
                values.append(eventRawDeviation[index])
            }
        }
        return values.count >= ETRhythm.minimumEvents ? ETRhythm.median(values) : 0
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

    // MARK: 描くための読み

    struct EventPoint {
        var x: Double
        var y: Double
        var radius: Double
        var timed: Bool
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
        let x = view.left + (eventU[index] - view.uRight + Double(view.span)) / Double(view.span) * view.width
        let band = eventBand[index]
        var y: Double
        var radius: Double
        if view.echo {
            y = view.top + (0.5 + (Double(ETRhythm.bandRows[band]) - 1) * 0.28) * view.height
            radius = (0.025 + 0.035 * strength) * view.height
        } else {
            let lane = view.height / 3
            let deviation = eventDeviation[index]
            let limit = ETRhythm.deviationMS
            let clipped = deviation < -limit ? -limit : (deviation > limit ? limit : deviation)
            y = view.top + (Double(ETRhythm.bandRows[band]) + 0.5) * lane
                - (eventTimed[index] ? clipped / limit * 0.45 * lane : 0)
            radius = (0.025 + 0.04 * strength) * lane
        }
        return EventPoint(x: x, y: y, radius: radius, timed: eventTimed[index], novel: eventNovel[index],
                          band: band, deviation: eventDeviation[index], index: index)
    }

    func points(for view: LaneView) -> [EventPoint] {
        var out: [EventPoint] = []
        let from = view.uRight - Double(view.span)
        forEachEvent(from: from - 0.2, to: view.uRight + 0.2) { index in
            out.append(eventPoint(index: index, view: view))
        }
        // 古い順に描く（forEachEvent は新しい順）。
        return out.reversed()
    }

    // MARK: ビートレンズ

    /// いまのロックの epoch の直前 32 拍で、帯域ごと・スロットごとの、重み付き中央値からのずれとばらつき、
    /// それにスウィングとジッタ。拍に乗っていないあいだは nil。
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
