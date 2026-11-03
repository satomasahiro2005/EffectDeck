//  FileManagerAppGroup.swift（Linuxの代役）
//  FileManager.containerURL(forSecurityApplicationGroupIdentifier:)はDarwinだけにある。
//  ETShareInbox.rootが使う。Linuxには共有の置き場（App Group）が無いので、
//  entitlementの無いプロセスでのAppleと同じくnilを返す。テストはrootを使わず、
//  一時フォルダを`in:`で渡す。**このフォルダはテストのモジュールへ直接入る。**

import Foundation

extension FileManager {
    func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? { nil }
}
