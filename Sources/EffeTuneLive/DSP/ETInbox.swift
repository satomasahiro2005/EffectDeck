//  ETInbox.swift
//  外から渡されたファイルの振り分け。
//
//  共有シートや他のアプリの「このアプリで開く」から来る URL を、どこへ入れるかだけ決める。
//  View は持たない。呼ぶのは PipelineView の `.onOpenURL` と drainShared
//  （共有の拡張が App Group に置いたもの。ETShareInbox）、EffectPickerView のリンク取り込み。
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
//
//  **順番と断りの読み方は ETInboxRouting.swift（route）。**ここは本物の取り込み 2 つを
//  渡すだけで、単体テストは偽の 2 つを route に渡して試す（InboxTests）。

import Foundation

extension ETInbox {

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

        return route(url,
                     importIR: { IRLibrary.shared.importFile(at: $0) },
                     importJSFX: { try ETJSFXHost.shared.importFile($0).id })
    }
}
