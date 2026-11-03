//  CoreFoundationBool.swift（Linuxの代役）
//  DarwinのFoundationはCoreFoundationを出し直すのでCFGetTypeID / CFBooleanGetTypeIDが見えるが、
//  LinuxのFoundationは出さない。ETChainText.isBool（JSONの真偽と0/1の数を見分ける）が使う。
//  **このフォルダはテストのモジュールへ直接入る**（アプリのファイルにimportを足さずに済む）。
//
//  LinuxのJSONSerializationとNSNumber(value: Bool)は真偽を__NSCFBooleanで作るので、
//  そのクラスかどうかで見分ける。数（__NSCFBooleanでないNSNumber）はDarwinのCFNumberと同じ扱い。

import Foundation

private let etLinuxBooleanTypeID: UInt = 21
private let etLinuxOtherTypeID: UInt = 22

func CFBooleanGetTypeID() -> UInt { etLinuxBooleanTypeID }

func CFGetTypeID(_ object: AnyObject) -> UInt {
    String(describing: type(of: object)) == "__NSCFBoolean" ? etLinuxBooleanTypeID : etLinuxOtherTypeID
}
