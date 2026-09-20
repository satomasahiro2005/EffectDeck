//  ETInbox.swift
//  外から渡されたファイルの振り分け。
//
//  共有シートや他のアプリの「このアプリで開く」から来る URL を、どこへ入れるかだけ決める。
//  View は持たない。呼ぶのは PipelineView の `.onOpenURL` 1 か所だけにしてある。
//
//  **宣言（Info.plist の CFBundleDocumentTypes）と受け口は組でしか入れられない。**
//  宣言だけ足すと共有シートに出るのに押しても何も起きない、という新しい症状になる。
//
//  v1 で受けるのは音のファイル（IR）だけ。
//  preset の JSON は受けない。BackupSection が「読めたがまだ入れていない中身」を
//  自分の @State で持って 2 段で押させる形なので、外から来たものを同じ重さで扱うには
//  その置き場を View の外へ出す設計の決めが要る。`public.json` を名乗ると
//  無関係な JSON 全部で候補に出る副作用も付く。
//
//  JSFX も受ける。**拡張子では振らない。**JSFX には拡張子が無いことがあり、
//  メールや Files が付けた `.txt` でも来る。中身で判定するのは
//  ETJSFXHost.importFile（looksLikeJSFX）なので、ここは順に試すだけにする。

import Foundation

enum ETInbox {

    /// 受け取った結果。呼び出し側がどの画面を出すかを決める。
    enum Received {
        case ir(String)
        case jsfx(String)
        /// JSFX らしいが受けられなかった。理由を出すために持つ。
        case failed(String)
        case unsupported
    }

    /// 1 本受ける。
    ///
    /// **security scope を開いてから読む。**共有シートから来る URL は自分の
    /// コンテナの外を指すことがあり、開かずに読むと空で返る。
    /// in-place で来ない（コンテナへ写されてから渡る）回もあるので、
    /// 開けなくても読んでみる。
    @MainActor
    static func receive(_ url: URL) -> Received {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // **どちらも中身で判定する。拡張子では振らない。**
        //
        // 前は音を先に試していた。IRLibrary.importFile は読めさえすれば何でも
        // 受けていたので（拡張子は複製先の名前に使うだけ）、**JSFX を渡しても
        // IR として取り込まれて終わっていた。**いまは両方が頭の印と中身を見る。

        // 音（IRLibrary.looksLikeAudio が RIFF/FORM/fLaC/caff を見る）。
        if let id = IRLibrary.shared.importFile(at: url) { return .ir(id) }

        // JSFX（ETJSFXHost.importFile の looksLikeJSFX が `desc:` と `@…` を見る）。
        // 拡張子が無いもの、`.txt` が付いたものも同じ道を通る。
        do {
            let entry = try ETJSFXHost.shared.importFile(url)
            return .jsfx(entry.id)
        } catch let error as NSError where error.domain == "ETJSFX" && error.code == 10 {
            // JSFX でも音でもなかった。
            return .unsupported
        } catch {
            // JSFX らしいが受けられなかった（大きすぎる、字に起こせない、写せない）。
            // 黙って落とすと「押しても何も起きない」になるので、理由を返す。
            return .failed(error.localizedDescription)
        }
    }
}
