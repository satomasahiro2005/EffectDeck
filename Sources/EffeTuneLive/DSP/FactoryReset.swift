//  FactoryReset.swift
//  全部消して、入れたばかりの状態に戻す（#15）。Settings の About の Reset All Data から。
//
//  **入れ直しでは消えない。**鎖とプリセットは iCloud（CloudMirror）に写してあり、
//  入れ直した最初の起動で戻ってくる。消すなら iCloud の写しも一緒に消す。
//
//  **アプリを落とさずに戻す。**入れ物を消すだけだと、画面と DSP は前の中身を
//  持ったままで、次に何か書いた時に前の値が書き戻される。消したあとで、
//  中身を持っている所（鎖・プリセット・IR・JSFX・SFZ・出力補正・設定）に読み直させる。
//
//  消すもの:
//      鎖・保存した鎖・エフェクトごとのプリセット（UserDefaults と iCloud）
//      出力先ごとの補正の紐付けと入切・設定（UserDefaults）
//      取り込んだ IR（Documents/IR）・JSFX（Application Support/JSFX）・SFZ（Application Support/SFZ）
//      共有シートから受けて置きっぱなしのもの（App Group の Inbox）
//  消さないもの:
//      ETProtocolMigration の印。音の経路の名前を替えた版から上げたかの記録で、
//      人が作ったものではない。消すと上げたばかりの扱いに戻り、帯が出る。

import Foundation

@MainActor
enum ETFactoryReset {

    /// 消し残す UserDefaults の鍵の頭。
    private static let keptPrefixes = ["protocolMigration."]

    /// 全部消す。iCloud の写しまで消せたら true。
    /// 偽のときも手元は消えている。iCloud は次の起動で消し直す（CloudMirror.eraseAll）。
    @discardableResult
    static func run() -> Bool {
        let dsp = EffeTuneDSP.shared

        // 1. 鎖を既定に戻す。外の段（AU・JSFX）の instance もここで片付く。
        //    遅れて書く鎖が残っていると、消したあとに前の鎖が書き戻されるので書き切る。
        dsp.resetToDefault()
        PipelineStore.flush()

        // 2. UserDefaults を消す。
        let defaults = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier,
           let stored = defaults.persistentDomain(forName: domain) {
            for key in stored.keys where !keptPrefixes.contains(where: key.hasPrefix) {
                defaults.removeObject(forKey: key)
            }
        }

        // 3. 手元の鍵を空で埋める。**空のままにすると iCloud から戻ってくる。**
        //    CloudMirror は手元が空の鍵だけ受けるので、別の端末がまだ持っているものが
        //    降りてくると、消したはずのものが並ぶ。既定の鎖は publish が書かない
        //    （ETChainEditing.shouldPersist）ので、ここで書く。
        PipelineStore.saveLast(dsp.chain)
        PipelineStore.flush()
        defaults.set([String: Any](), forKey: PresetStore.key)
        defaults.set([String: Any](), forKey: EffectPresetStore.key)

        // 4. 取り込んだファイル。
        IRLibrary.shared.eraseAll()
        ETJSFXHost.shared.eraseImported()
        SFZLibrary.shared.eraseAll()
        if let inbox = ETShareInbox.root { try? FileManager.default.removeItem(at: inbox) }

        // 5. 中身を持っている所に読み直させる。
        PresetStore.shared.reload()
        EffectPresetStore.shared.reload()
        OutputCorrection.shared.reloadAfterReset()
        Preferences.shared.reload()

        // 6. iCloud。最後に消す。上で書いた既定の鎖の写しもここで消える。
        return CloudMirror.eraseAll()
    }
}
