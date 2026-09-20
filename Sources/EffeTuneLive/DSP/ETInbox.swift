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
//  JSFX は codex/jsfx-host の側で足す（main には受け皿の ETJSFXHost が無い）。

import Foundation

enum ETInbox {

    /// 受け取った結果。呼び出し側がどの画面を出すかを決める。
    enum Received {
        case ir(String)
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

        // 拡張子で振る。IRLibrary.importFile が拡張子をそのまま複製先の名前に使うので、
        // ここで中身まで見る意味が薄い。読めない中身は importFile の側で落ちる。
        if let id = IRLibrary.shared.importFile(at: url) { return .ir(id) }
        return .unsupported
    }
}
