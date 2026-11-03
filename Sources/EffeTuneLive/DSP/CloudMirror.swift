//  CloudMirror.swift
//  UserDefaults に残したものを iCloud（NSUbiquitousKeyValueStore）へ写す。
//
//  **正は UserDefaults。**ここは保険で、写すのに失敗しても手元は無事。
//  だから書き込みは「UserDefaults へ書いた後に、同じものをもう一度写す」だけ。
//
//  写すのは 3 つ。どれも短い JSON か辞書で、写して困るものが入っていない:
//      pipeline.last            いま組んである鎖（ショート形式の JSON の Data）
//      presets                  名前を付けた鎖
//      effetune_plugin_presets  エフェクトごとのプリセット
//
//  **IR の素材は入らない。**鎖が持っているのは sha256 の先頭 24 桁の参照だけで
//  （PipelineStore.swift:74-77）、実体は Documents/IR にある。別の端末で戻した鎖が
//  指す素材はこちらに無いので、IR Reverb は素通しに落ちる（IRLoader.swift:53-55）。
//
//  **開いている段（pipeline.expanded）も写さない。**あれは鎖の位置の配列で、
//  鎖と組でなければ意味が無い。戻した鎖は全部畳んだ状態で出る。
//
//  ---------------------------------------------------------------------------
//  **降ってきた変更は、手元がまだ空の鍵だけ受ける。**
//
//  最初は observe しない形にしていた。iCloud の同期は遅れて届くので、走っている
//  最中に受けると、別の端末が前に書いた古い鎖で「いま手で触っている鎖」を
//  上書きしうる、と考えたため。**その理屈は正しいが、受けない形は成立しない。**
//
//  入れ直した直後の起動では、KVS の端末側の控えも一緒に消えている。
//  synchronize() は iCloud から引いてこない（メモリとディスクを揃えるだけ）ので、
//  seed は空振りする。その数ミリ秒後に restore() が既定の Level Meter を置き、
//  publish → persist → saveLast が "pipeline.last" を埋める。以後この端末で
//  seed の条件（手元が空）は二度と成立せず、後から iCloud の鎖が降りてきても
//  読む所が無い。**戻すために足した仕掛けが、戻すはずのものを自分で捨てていた。**
//
//  なので受ける。ただし受け入れる条件を「その鍵が手元でまだ空」に絞る。
//  空なら失うものが無いので、元の心配（編集中の鎖を古い鎖で潰す）は起きない。
//  手元に何か在る鍵は、降ってきても無視する。ここは変えていない。
//
//  鎖が降りたときだけ onChainRestored を呼ぶ。その時点で restore() は既に
//  既定の 1 本を並べ終えているので、UserDefaults へ入れるだけでは次の起動まで
//  出てこない。入れるのは EffeTuneDSP の担当（adoptSeededChain）なので、
//  こちらは知らせるだけにして DSP を直に呼ばない。
//  ---------------------------------------------------------------------------
//
//  ---------------------------------------------------------------------------
//  **辞書は項目ごとに写す。まるごと写さない**（patch）。
//
//  KVS の書き込みは鍵ごとの置き換えで、併合しない。手元の辞書をまるごと写すと、
//  手元に在る分が iCloud に在る分を置き換える。母機に 50 本、2 台目に 1 本という
//  状態で 2 台目が 1 本保存すると、その瞬間 iCloud は 1 本になり母機の 49 本が消える。
//  「保険」のつもりのものが保険そのものを壊す。
//
//  戻す側は「手元が空の鍵だけ」受けるので、2 台目が 50 本を受け取る前に保存する窓が
//  ある。そこは書く側で塞ぐしかない。だから save / remove / merge は触った項目だけを
//  当てる（PresetStore と EffectPresetStore）。鎖（pipeline.last）は値が 1 つなので
//  まるごと（mirror）でよい。
//
//  **残っている穴:** 既に手元にプリセットが在る端末は、iCloud に在る別の端末の分を
//  受け取らない（受けるのは空の鍵だけ）。消えはしないが、2 台が同じ一覧になるわけでも
//  ない。揃えるには併合して読む形が要るが、それは「正は UserDefaults」をやめる話。
//  ---------------------------------------------------------------------------
//
//  上限は 1 鍵 1MB・全体 1MB・鍵は 1024 個
//  （NSUbiquitousKeyValueStore の決まり）。書くのは 3 鍵なので数は当たらない。
//  大きさだけ書く前に測って、超えるものは黙って諦める。

import Foundation
import os

enum CloudMirror {

    private static let log = Logger(subsystem: "ai.nemut.effetune", category: "cloud")

    private static var cloud: NSUbiquitousKeyValueStore { .default }

    /// 決まりはここ（CloudMirrorCore.swift、Foundationだけ）。こちらは本物の入れ物と
    /// -ETSeed を渡して、返ってきた理由をログへ出すだけ。
    ///
    /// **撮影用の起動（-ETSeed）では写さない・戻さない。**並んでいるのは引数から組んだ
    /// 見本の鎖で、人が作ったものではない。写すと、同じ Apple ID の端末で
    /// 1 度撮っただけで人の鎖が消える。戻すと引数の鎖に iCloud の鎖が混ざる。
    private static var core: CloudMirrorCore {
        CloudMirrorCore(cloud: cloud, seeded: ETScreenshotSeed.requested != nil)
    }

    /// 遅れて降りてきた鎖を手元へ入れたときに呼ぶ。立てるのは EffeTuneLiveApp.init。
    @MainActor static var onChainRestored: (() -> Void)?

    // MARK: - 写す

    /// UserDefaults へ書いた直後に呼ぶ。渡すのは書いたものそのまま。
    ///
    /// 鍵の綴りは呼ぶ側（各 store）が持っている。こちらで書き写すと、
    /// 片方だけ直したときに黙って別の鍵になる。
    ///
    /// **ここで synchronize() しない。** ディスクへ落とすのも iCloud へ送るのも
    /// OS が自分でやる。呼んでよいのは起動のときだけ、と決まっている
    /// （NSUbiquitousKeyValueStore.synchronize の説明）。
    /// 呼ぶ側は鎖を触るたびに来るので、そのたび撃つと只のディスク書き込みが増える。
    static func mirror(_ value: Any?, forKey key: String) {
        report(core.mirror(value, forKey: key), key: key)
    }

    /// 辞書の中の**1 項目だけ**を写す。`path` は外側から順の鍵。
    ///
    /// **辞書をまるごと写してはいけない。**KVS の書き込みは鍵ごとの置き換えで
    /// 併合しない。まるごと写すと、手元にある分が iCloud にある分を丸ごと
    /// 置き換える。母機に 50 本、2 台目に 1 本という状態で 2 台目が 1 本保存すると、
    /// その瞬間 iCloud は 1 本だけになり、母機の 49 本が消える。
    ///
    /// **戻す側は「手元が空の鍵だけ」受ける**（下の seed）ので、2 台目が
    /// 50 本を受け取る前に保存する窓がある。そこを塞ぐには、書く側が
    /// 置き換えではなく**触った項目だけ**を当てる形でなければならない。
    ///
    /// `value` が nil ならその項目を消す。消した結果その枝が空になったら
    /// 枝ごと落とす（上流も plugin-preset-store.js:159 でそうしている）。
    static func patch(key: String, path: [String], value: Any?) {
        patch(key: key, changes: [CloudChange(path: path, value: value)])
    }

    /// 項目をまとめて当てる。**iCloud への書き込みは 1 回。**
    ///
    /// 付け替え（古い名前を消して新しい名前を足す）を 2 回に分けて書くと、
    /// 間で大きさの上限に当たったときに消すほうだけが残る。まとめて測って書けば、
    /// 当たったときは前の写しがそのまま残る（CloudMirrorCore.write）。
    static func patch(key: String, changes: [CloudChange]) {
        report(core.patch(key: key, changes: changes), key: key)
    }

    private static func report(_ outcome: CloudMirrorCore.Outcome, key: String) {
        switch outcome {
        case .unencodable:
            log.error("iCloud へ写せない形 \(key, privacy: .public)")
        case .tooLarge(let size):
            log.notice("iCloud へ写すには大きい \(key, privacy: .public) \(size) bytes")
        case .written, .removed, .disabled, .unchanged:
            break
        }
    }

    // MARK: - 消す

    /// iCloud に消し残しがあるか。全部消す（ETFactoryReset）で消し切れなかったときに立てる。
    /// 立っているあいだは iCloud から戻さず、起動のたびに消し直す（seedIfEmpty）。
    static let erasePendingKey = "cloud.erasePending"

    /// iCloud の EffectDeck の鍵を全部消す。消せたら true。
    ///
    /// **消せなかったら印を立てる。**KVS の消しは端末の控えに入って OS が後で送るので、
    /// 送れたかはこちらから分からない。分かるのは synchronize() が控えを書けなかったこと
    /// （entitlement が無いなど）だけ。そのときは成功と言わず、次の起動で消し直す。
    @MainActor
    @discardableResult
    static func eraseAll() -> Bool {
        let store = cloud
        for key in store.dictionaryRepresentation.keys { store.removeObject(forKey: key) }
        let ok = store.synchronize()
        if ok {
            UserDefaults.standard.removeObject(forKey: erasePendingKey)
            log.notice("iCloud の写しを消した")
        } else {
            UserDefaults.standard.set(true, forKey: erasePendingKey)
            log.error("iCloud の写しを消せなかった。次の起動で消し直す")
        }
        return ok
    }

    @MainActor
    private static var erasePending: Bool {
        UserDefaults.standard.bool(forKey: erasePendingKey)
    }

    // MARK: - 戻す

    /// 起動で 1 回だけ。**App の init から呼ぶ**（EffeTuneLiveApp.swift）。
    ///
    /// そこでなければならない理由:
    ///   - 鎖を読むのは EffeTuneDSP.restore() で、それは AudioIO の init から来る。
    ///     戻すのはそれより前でないと間に合わない。
    ///   - 同期で済ませる。ここは最初のフレームより前のメインスレッドなので、
    ///     ネットワークの完了を待たない。KVS の読みは端末に降りている写しを見るだけ。
    ///
    /// **1 回読んで終わりにしない。**入れ直した直後は端末側の控えが空で、
    /// iCloud から降りてくるのは数秒後になる。上の注記を参照。
    @MainActor
    static func seedIfEmpty() {
        // 撮影用の起動（-ETSeed）では鎖を引数から組む。iCloud を引くと混ざる。
        guard ETScreenshotSeed.requested == nil else { return }

        // 呼んでよいのは起動のとき、というのがこれの決まり
        // （NSUbiquitousKeyValueStore.synchronize の説明）。戻り値は
        // 「メモリとディスクを揃えられたか」で、iCloud と揃ったかではない。
        _ = cloud.synchronize()

        // 前に消し切れなかった写しを、戻す前に消す。消し切れるまでは戻さない。
        if erasePending { eraseAll() }
        if !erasePending { seed() }
        observe()
    }

    /// 手元がまだ空の鍵だけ戻す。戻したのが鎖なら true。
    @MainActor
    @discardableResult
    private static func seed() -> Bool {
        let restored = core.seed(into: UserDefaults.standard,
                                 chainKey: PipelineStore.lastKey,
                                 dictionaryKeys: [PresetStore.key, EffectPresetStore.key])
        if let bytes = restored.chainBytes {
            log.notice("iCloud から鎖を戻した \(bytes) bytes")
        }
        for entry in restored.dictionaries {
            if entry.key == PresetStore.key {
                log.notice("iCloud からプリセットを戻した \(entry.count) 本")
            } else {
                log.notice("iCloud からエフェクトのプリセットを戻した \(entry.count) 種")
            }
        }
        return restored.chain
    }

    /// 外して回る所が無いので取っておくだけ。アプリと同じ寿命。
    @MainActor private static var observer: NSObjectProtocol?

    @MainActor
    private static func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: nil
        ) { _ in
            // どのスレッドで来るか決まっていないので、触る前に main へ寄せる。
            // seed() は手元が空の鍵しか触らないので、遅れて来ても壊すものが無い。
            Task { @MainActor in
                guard !erasePending else { return }
                if seed() { onChainRestored?() }
            }
        }
    }
}

/// iCloud の KVS を CloudMirrorCore へ渡すため。要求は元から持っているものだけ
/// （KeyValueStorage.swift）。Linux の Foundation には無いのでこちらに置く。
extension NSUbiquitousKeyValueStore: ETKeyValueStorage {}
