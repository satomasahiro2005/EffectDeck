//  GraphPeekGate.swift
//  カードの図を、スクロールで外れたあとも値を触っている間だけ上に見せる（graph peek）。
//  **その出し入れの判断だけを、Foundation だけで書く。**
//
//  ここは UIKit も SwiftUI も読まない。触りの知らせと値の変化の知らせを受けて、
//  「いま見せたいか（wantsPeek）」と「次にいつ見直すか（deadline）」を返す。
//  時刻は引数で受ける。Linux の swift test から時計を進めて確かめられる。
//
//  **出すのは 2 つの入口だけ。**
//   - 保持: 指がカードの中に置かれている間（と離したあと 0.3 秒）の値の変化。
//     スクロール・長押しの並べ替え・払って削除は値を変えないので、出ない。
//   - パルス: 指が無くても値が変わる所（メニュー、打ち込み、VoiceOver）が立てる 1.2 秒。
//  どちらも、カードを開いた直後 0.6 秒は無視する（onAppear が値を書く図があるため）。

import Foundation

struct ETGraphPeekGate: Equatable {
    // MARK: - 秒数

    /// 指を離したあと、図を残す秒数。
    static let lingerAfterLift: TimeInterval = 0.8
    /// パルスで出す秒数。
    static let pulseDuration: TimeInterval = 1.2
    /// 離したあとでも値の変化を保持の一部として数える秒数（Toggle や選び直しは離した時に変わる）。
    static let graceAfterLift: TimeInterval = 0.3
    /// カードを開いてから、何も出さない秒数。
    static let quietAfterAppear: TimeInterval = 0.6
    /// 消え始めてからの秒数。この間の変化は消えるのを取り消して残す（描き側の fade と同じ長さ）。
    static let fadeDuration: TimeInterval = 0.25

    /// 時刻の足し引きの丸めで、ちょうど境の所が外れないための幅。
    private static let eps: TimeInterval = 1e-9

    /// 図を出さない種類。上の 2 つは遠隔の枠を取り合う（2 枚目が枠を盗む）。
    /// Spectrogram は出した瞬間の履歴が空になる。
    static let peekExcluded: Set<String> = [
        "NoteSpectrogramPlugin", "RhythmAnalyzerPlugin", "SpectrogramPlugin",
    ]

    // MARK: - 出力

    /// いま図を見せたいか。
    private(set) var wantsPeek = false
    /// 次に `tick` を呼ぶ時刻。指が下りている間と、出していない間は nil。
    private(set) var deadline: TimeInterval?
    /// 最後に指が置かれた点（カードの座標）。置き場所の判断（上下の反転）に使う。
    private(set) var touchPoint: CGPoint?

    // MARK: - 入力と内部の状態

    /// このカードの種類。`peekExcluded` に入っていれば何も出さない。
    var typeName: String

    private var holding = false
    /// この保持では出さない（図の上で始まった、指が複数、スクロールなどに変わった）。
    private var blocked = false
    private var liftedAt: TimeInterval?
    private var appearedAt: TimeInterval?
    private var pulseUntil: TimeInterval?
    private var timedOutAt: TimeInterval?

    init(typeName: String = "") {
        self.typeName = typeName
    }

    var isExcluded: Bool { Self.peekExcluded.contains(typeName) }

    // MARK: - 触り

    /// カードの中に指が置かれた。
    /// - Parameters:
    ///   - point: カードの座標での点。
    ///   - inGraph: その点が、いま報告されている図のどれかの矩形の中か。
    ///   - touches: 置かれている指の本数。2 本以上は無視する（3 本指の取り消しなど）。
    mutating func touchDown(point: CGPoint, inGraph: Bool, touches: Int = 1, now: TimeInterval) {
        touchPoint = point
        holding = true
        blocked = inGraph || touches != 1
        liftedAt = nil
        if blocked && touches != 1 {
            hideNow()
        } else if wantsPeek && !blocked {
            // 出ている図を、この保持の間は押さえる。出さない保持（図の上）では、残りの時計を止めない。
            deadline = nil
        }
    }

    /// 指が離れた（取り消しを含む）。
    mutating func touchUp(now: TimeInterval) {
        guard holding else { return }
        holding = false
        liftedAt = blocked ? nil : now
        // 出さない保持は、いま出ている図の時計をそのままにする。
        if wantsPeek && !blocked {
            deadline = max(now + Self.lingerAfterLift, pulseUntil ?? 0)
        }
    }

    // MARK: - 値

    /// カードの値か表示が変わった。
    mutating func valuesChanged(now: TimeInterval) {
        guard !isExcluded, !inQuietPeriod(now) else { return }
        if holding {
            // 図の上で始めた保持や、複数の指は出さない。
            guard !blocked else { return }
            show(until: nil)
        } else if wantsPeek {
            // 残っている間の変化は、消えるのを先へ延ばす（パルスの 1.2 秒は縮めない）。
            extend(to: now + Self.lingerAfterLift)
        } else if let t = liftedAt, now - t <= Self.graceAfterLift + Self.eps {
            show(until: now + Self.lingerAfterLift)
        } else if let t = timedOutAt, now - t <= Self.fadeDuration + Self.eps {
            // 消え始めたところへの変化は、消えるのを取り消して残す。
            show(until: now + Self.lingerAfterLift)
        }
    }

    /// 指が無くても値が変わる所が呼ぶ。1.2 秒出す。
    mutating func pulse(now: TimeInterval) {
        guard !isExcluded, !inQuietPeriod(now) else { return }
        // 出さないと決めた保持の最中は、パルスでも出さない（スライダーの値の書き込みもパルスを呼ぶ）。
        if holding && blocked { return }
        let until = now + Self.pulseDuration
        pulseUntil = max(pulseUntil ?? 0, until)
        if holding {
            // 指が下りている間は離すまで残す。離した時に pulseUntil も見る。
            show(until: nil)
        } else if wantsPeek {
            extend(to: until)
        } else {
            show(until: until)
        }
    }

    // MARK: - 状態

    /// カードの中身が出た（開いた）。
    mutating func appeared(now: TimeInterval) {
        appearedAt = now
        hideNow()
        liftedAt = nil
        timedOutAt = nil
    }

    /// 今すぐ消す。スクロールの開始、並べ替えの開始、カードを畳む、シート、アプリが前に居なくなった時。
    /// 指が下りている間なら、その保持はもう出さない。
    mutating func suppress() {
        hideNow()
        if holding { blocked = true }
        liftedAt = nil
        timedOutAt = nil
    }

    /// 時刻を進める。deadline に来ていれば消す。
    mutating func tick(now: TimeInterval) {
        // 保持の最中に期限を持つのは、出さない保持が残った図だけ（出す保持は期限を持たない）。
        guard wantsPeek, let d = deadline, now >= d else { return }
        wantsPeek = false
        deadline = nil
        pulseUntil = nil
        timedOutAt = d
    }

    // MARK: - 内部

    private func inQuietPeriod(_ now: TimeInterval) -> Bool {
        guard let t = appearedAt else { return false }
        return now - t < Self.quietAfterAppear - Self.eps
    }

    private mutating func show(until: TimeInterval?) {
        wantsPeek = true
        timedOutAt = nil
        if let until { deadline = max(deadline ?? 0, until) } else { deadline = nil }
    }

    private mutating func extend(to t: TimeInterval) {
        if holding { return }
        deadline = max(deadline ?? 0, t)
    }

    private mutating func hideNow() {
        wantsPeek = false
        deadline = nil
        pulseUntil = nil
    }
}

// MARK: - 置き場所と見えているか

/// 図を出す場所。
enum ETGraphPeekPlacement: Equatable {
    case top
    case bottom
}

extension ETGraphPeekGate {
    /// 上に出すか下に出すか、出せないか。
    ///
    /// - Parameters:
    ///   - viewport: 重ねる面の大きさ。
    ///   - topInset: 上の安全域（ナビゲーションバー）。
    ///   - bottomInset: 下の安全域。
    ///   - peekHeight: 出す図の高さ。
    ///   - touchY: 指の高さ（面の上端から）。nil（パルス）は上。
    /// - Returns: 使える高さが `peekHeight × 2 + 48` に満たなければ nil（横向きやキーボードが出ている時）。
    static func placement(viewport: CGSize,
                          topInset: CGFloat,
                          bottomInset: CGFloat,
                          peekHeight: CGFloat,
                          touchY: CGFloat?) -> ETGraphPeekPlacement? {
        let free = viewport.height - topInset - bottomInset
        guard free >= peekHeight * 2 + 48 else { return nil }
        guard let touchY else { return .top }
        return touchY < topInset + peekHeight + 24 ? .bottom : .top
    }

    /// 図が見えているか。**1 つでも高さの threshold 以上が viewport に入っていれば真。**
    /// 図が 1 つも報告されていなければ偽（画面の外として扱う）。
    /// - Parameter viewport: 安全域だけに絞った矩形（バーの下から下の余白の上まで）。
    static func graphVisible(graphRects: [CGRect], viewport: CGRect, threshold: CGFloat = 0.6) -> Bool {
        graphRects.contains { r in
            guard r.height > 0 else { return false }
            let inter = r.intersection(viewport)
            guard !inter.isNull, inter.width > 0 else { return false }
            // 浮動小数の丸めで、ちょうど threshold の所が外れないよう少しだけ緩める。
            return inter.height >= threshold * r.height - 1e-9
        }
    }

    /// 点がどれかの図の矩形の中か（保持が図の上で始まったか）。
    static func point(_ p: CGPoint, inAny graphRects: [CGRect]) -> Bool {
        graphRects.contains { $0.contains(p) }
    }
}
