//  ETInboxRouting.swift
//  外から渡されたファイルをどちらの取り込みへ回すか（ETInbox の判断だけ）。
//
//  取り込みそのもの（IRLibrary.importFile と ETJSFXHost.importFile）は AVFoundation と
//  ysfx に触るので、単体テストのバンドルにも Linux にも入らない。**順番と、断りの読み方だけを
//  ここへ出し、取り込みの 2 つは引数で受ける。**本物を渡すのは ETInbox.swift の receive。
//  Foundation だけ（InboxTests）。

import Foundation

enum ETInbox {

    /// 受け取った結果。呼び出し側がどの画面を出すかを決める。
    enum Received: Equatable {
        case ir(String)
        case jsfx(String)
        /// JSFX らしいが受けられなかった。理由を出すために持つ。
        case failed(String)
        case unsupported
    }

    /// リンクから来たものが音でも JSFX でもなかったときの字。
    /// 「Import → From Link」と共有の拡張の両方で出す。
    static let unsupportedLink = "That link is neither a JSFX source nor an impulse response."

    /// 「このアプリで開く」で来たファイルが音でもJSFXでもなかったときの字（PDFなど）。
    /// JSFXには決まった拡張子が無いので、Info.plistでpublic.itemを名乗っていて何でも来る。
    static let unsupportedFile = "That file is neither a JSFX source nor an impulse response."

    /// ETJSFXHost.importFile が「JSFX ではない」と断るときの印（looksLikeJSFX が外れた）。
    /// これだけは理由を出さず、音でも JSFX でもないものとして扱う。
    static let notJSFXDomain = "ETJSFX"
    static let notJSFXCode = 10

    /// 1 本を振り分ける。
    ///
    /// **どちらも中身で判定する。拡張子では振らない。**
    ///
    /// 前は音を先に試していた。IRLibrary.importFile は読めさえすれば何でも
    /// 受けていたので（拡張子は複製先の名前に使うだけ）、**JSFX を渡しても
    /// IR として取り込まれて終わっていた。**いまは両方が頭の印と中身を見る。
    ///
    /// - Parameters:
    ///   - importIR: 音として取り込む。音でなければ nil（IRLibrary.looksLikeAudio が
    ///     AVAudioFile で開けるかを見る）。**先に試す。**
    ///   - importJSFX: JSFX として取り込み、識別子を返す（ETJSFXHost.importFile の
    ///     looksLikeJSFX が `desc:` と `@…` を見る）。拡張子が無いもの、`.txt` が付いたものも
    ///     同じ道を通る。
    static func route(_ url: URL,
                      importIR: (URL) -> String?,
                      importJSFX: (URL) throws -> String) -> Received {
        if let id = importIR(url) { return .ir(id) }
        do {
            return .jsfx(try importJSFX(url))
        } catch let error as NSError where error.domain == notJSFXDomain && error.code == notJSFXCode {
            // JSFX でも音でもなかった。
            return .unsupported
        } catch {
            // JSFX らしいが受けられなかった（大きすぎる、字に起こせない、写せない）。
            // 黙って落とすと「押しても何も起きない」になるので、理由を返す。
            return .failed(error.localizedDescription)
        }
    }
}
