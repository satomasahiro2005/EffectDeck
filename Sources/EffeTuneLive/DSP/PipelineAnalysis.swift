//  PipelineAnalysis.swift
//  鎖の意味を 1 か所で決める。
//
//  **保存形式を内側の模型にしない。**EffeTune の形は「渡すための形」で、
//  こちらが考えるための形ではない。向こうには組を閉じる印が無く、
//  `Section("")` を終端の代わりに使う（上流自身も preset-manager.js:149-161 で
//  同じことをしている）。それをこちらでも Section として持つと、
//
//      名前が空なら組を作らない
//      ただし切ってあるなら作る
//      畳めるが線は引かない
//      掃除の候補だが開いていたら残す
//
//  という但し書きが画面のあちこちに散る。実際そうなっていた。
//
//  **こちらでは終端を独立した語にする。**それが `rootReset`。
//  Section ではないので、名前も入切も持たず、行にも出ず、畳めもしない。
//  EffeTune へ出す瞬間だけ `Section(cm: "")` に化ける（ETWireCodec）。
//
//  **外から来た空 Section を rootReset と推測してはいけない。**
//  人が付けなかった名前なのか、上流が挿した終端なのか、渡された形からは
//  区別できない。外のものは必ず普通の Section として読む。自分で作ったものだけ、
//  端末に残した覚え（ETPipelineMetadata）から戻す。**誤って消すより、
//  見た目の情報を失うほうが安全。**

import Foundation

/// 段の役目。**鎖の並びそのものが持つ意味**で、見た目の都合ではない。
enum ETItemRole: String, Codable {
    /// 音を通す普通の段。
    case effect
    /// 組の始まり。名前と入切を持つ。
    case section
    /// **組を抜けて root へ戻る印。**名前も入切も持たない。
    case rootReset
}

/// 鎖を読んで、所属と gate を出す。**派生値はここでしか作らない。**
///
/// 上流の走り方と同じ（dsp-pipeline-descriptor.js:190-212）。違うのは、
/// 向こうが Section に当たるたびに `sectionEnabled` を上書きするだけなのに対し、
/// こちらは `rootReset` で持ち主を無しに戻せること。出す形は同じなので、
/// 音の意味は完全に一致する。
struct ETPipelineAnalysis {

    struct State {
        /// どの Section のものか。root に居るなら nil。
        let owner: UUID?
        /// 音が通るか。持ち主が切ってあれば 0。
        let gate: UInt8
    }

    /// 段ごとの答え。鍵は Node.id。
    private(set) var state: [UUID: State] = [:]
    /// Section ごとの配下。**配下を知りたいコードはここだけを見る**
    /// （`range(after:)` を画面から追い出すため）。
    private(set) var members: [UUID: [UUID]] = [:]

    /// 走らせる。`roles` と `ids` と `enabled` は同じ長さ。
    static func analyze(roles: [ETItemRole], ids: [UUID], enabled: [Bool]) -> ETPipelineAnalysis {
        precondition(roles.count == ids.count && roles.count == enabled.count)
        var out = ETPipelineAnalysis()
        var owner: UUID?
        var open = true      // 持ち主が入っているか。root では常に通る。

        for i in roles.indices {
            switch roles[i] {
            case .section:
                owner = ids[i]
                open = enabled[i]
            case .rootReset:
                owner = nil
                open = true
            case .effect:
                out.state[ids[i]] = State(owner: owner, gate: open ? 1 : 0)
                if let owner { out.members[owner, default: []].append(ids[i]) }
            }
        }
        return out
    }

    func owner(of id: UUID) -> UUID? { state[id]?.owner }
    func gate(of id: UUID) -> UInt8 { state[id]?.gate ?? 1 }
    func members(of section: UUID) -> [UUID] { members[section] ?? [] }
}

// MARK: - 正規形

enum ETRootResetRule {

    /// `rootReset` が要るのは、**組の中に居て、かつその後ろに次の Section より前へ
    /// 段が在る**ときだけ。要らないものを落とす。
    ///
    /// 落とす形は 4 つ:
    ///
    ///     reset X          既に root に居る
    ///     A X reset        戻した先に何も無い
    ///     A X reset B Y    次の Section が終わらせるので要らない
    ///     A X reset reset  2 つ以上並んでいる
    ///
    /// **今の音が同じかどうかでは決めない。**`A(入) X reset Y` は reset を消しても
    /// いまの gate は変わらないが、あとで A を切ると Y まで止まる。
    /// 出ている音が同じことと、文書の意味が同じことは別。**形だけで決める。**
    ///
    /// 決まった答えを返す（同じ入力なら同じ出力）。そして 2 度掛けても変わらない。
    static func keep(roles: [ETItemRole]) -> [Bool] {
        var out = [Bool](repeating: true, count: roles.count)
        var atRoot = true

        for i in roles.indices {
            switch roles[i] {
            case .section:
                atRoot = false
            case .effect:
                break
            case .rootReset:
                guard !atRoot else { out[i] = false; continue }
                // 次の Section より前に段が在るか。
                var needed = false
                var j = i + 1
                while j < roles.count {
                    if roles[j] == .section { break }
                    if roles[j] == .effect { needed = true; break }
                    j += 1
                }
                guard needed else { out[i] = false; continue }
                atRoot = true
            }
        }
        return out
    }

    /// その段を組から出すとき、**印をどこへ挿すか**。nil なら何もしない。
    ///
    /// 挿さないのは 3 つ:
    ///   - その段が段でない（Section や印を「外へ出す」ことはない）
    ///   - 既に root に居る
    ///   - 挿しても正規形で落ちる（＝意味が変わらない）
    ///
    /// **判断をここに置くのは、模型の外から試せるようにするため。**
    /// EffeTuneDSP の中に書くと Node と AVFoundation が付いてきて、
    /// 素の並びだけで確かめられなくなる。
    static func insertion(roles: [ETItemRole], enabled: [Bool], at index: Int) -> Int? {
        precondition(roles.count == enabled.count)
        guard roles.indices.contains(index), roles[index] == .effect else { return nil }

        // 持ち主が居なければ、もう外に出ている。
        var owner: Int?
        for i in 0..<index {
            switch roles[i] {
            case .section:   owner = i
            case .rootReset: owner = nil
            case .effect:    break
            }
        }
        guard owner != nil else { return nil }

        // 挿した形が正規形で残るか。残らないなら意味が変わらないので挿さない。
        var after = roles
        after.insert(.rootReset, at: index)
        return keep(roles: after)[index] ? index : nil
    }
}
