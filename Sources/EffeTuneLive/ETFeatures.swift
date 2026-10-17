//  ETFeatures.swift
//  建てるときに決まる機能の入切。**開け閉めはここの 1 行で済むようにする。**

enum ETFeatures {

    /// EffeTune Remote Control（DSP/RemoteMirror.swift・Views/RemoteScannerView.swift）。
    ///
    /// **開けてある。**上流の EffeTune が 2.13.0 で LAN のリモート API を出した（Vendor/effetune/docs/remote-v1.md）ので、
    /// 店の版（Release）でもつなぐ相手が居る。以前はここを Debug と Beta（ET_BETA）だけに絞っていた。
    /// 閉じるときは `false` を返すだけで、入口が全部閉じる（入口の確認は下の一覧）。
    ///
    /// 開けたときの入口:
    ///   - 鎖の画面のツールバーのアイコン（RemoteToolbarButton。PipelineView）
    ///   - 設定画面の Remote の面（SettingsView.Pane）
    ///   - 撮影用の `-ETSheet remote`（PipelineView）
    ///   - 起動でのつなぎ直しと、つなぐこと全部（RemoteMirror.start・apply）
    /// QR の読み取りは Remote のシートと面の中にしか無く、帯と中央の札はつながっているあいだしか出ない。
    /// http://host:port/?t=… や ws:// のリンクを外から開く口（onOpenURL）は持っていない。
    ///
    /// 開けた版が求めるもの: Info.plist の NSLocalNetworkUsageDescription と NSCameraUsageDescription（入っている）。
    /// 審査用の説明（Tools/review_notes.txt）は「Remote Control is off」のままなので、出す前に書き直すこと。
    static var remoteControl: Bool { true }

    /// Visualizer のうち、曲の聞き取り（ShazamKit。Audio/SongRecognizer.swift）に頼るもの。
    /// Visualizer の画面・その編集画面（Views/Visualizer/）・場面（JSFX の要素を含む）・⋯ のメニューの Visualizer・
    /// Floating Meters の拡大ボタンは **どの版にも出る。**ここが絞るのは、聞き取りを使う次の 3 つだけ。
    ///   - 曲の要素（Artwork・Title・Artist。追加の画面からも選択からも消え、描かれもしない）と、
    ///     アートワークの背景（Scene の画面から選べず、場面に残っていても背景の色で塗る）、Now Playing のプリセット
    ///   - Scene の画面の Song Recognition の節（取得状況。デバッグ用）
    ///   - ETSongRecognizer.setActive を呼ぶこと全部（Release では 1 度も呼ばない）
    /// **Debug と Beta だけ。**ShazamKit は音の指紋を Apple へ送り、アートワークも取りに行くので、
    /// site/src/text.js の PRIVACY（音は端末から出ない・音の処理は通信しない）と Tools/review_notes.txt と食い違う。
    /// 店の版で開ける前にそれらを書き直すこと。
    static var visualizer: Bool {
#if DEBUG || ET_BETA
        true
#else
        false
#endif
    }
}
