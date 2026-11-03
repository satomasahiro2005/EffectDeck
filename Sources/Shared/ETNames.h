//  ETNames.h
//  名乗る字を 1 か所にまとめる。
//
//  **名前は 2 系統ある。**
//
//    ET_ROUTE_NAME   MediaOutputDevice.displayName。コントロールセンターの
//                    出力の一覧に出る字。他アプリの音をこちらへ寄越すときに
//                    人が押すのはこれ。
//    ET_DRIVER_NAME  AudioServerPlugIn の仮想デバイス名
//                    （EffeTuneDriver.m の kAudioObjectPropertyName）。
//                    AVAudioSession の出力先の名前として出る。
//
//  **2 つとも同じ字にしてある。**別々の仕組みが持っていて画面でも別の所に出るが、
//  違う字を当てると「どちらを選べばいいのか」という問いが使う人に生まれる。
//  一覧の行をタップすると 2 行になる。**下の行はここではなく、拡張の
//  UTTypeDescription（Sources/Extension/Info.plist）。**そちらも揃えること
//  （docs/connect-log.md「コントロールセンターの 2 行目は UTTypeDescription」。
//  docs/connect-log.md は手元だけの記録で、追跡していない）。
//
//  **帰還ループの判定は名前の包含で見ている**（AudioSessionRules.swift の
//  `ETAudioSessionRules.isOwnDevice(portName:)`。`localizedCaseInsensitiveContains` で
//  Swift の写し `nameStem` を探す。写しがここと同じかは AudioIO の init の assert が見る）。
//  どちらの名前も ET_NAME_STEM を含んでいること。含まない字にすると、出力先が自分へ
//  戻っていても気づけない。

#ifndef ETNames_h
#define ETNames_h

/// 2 つの名前に共通して入っている部分。帰還ループの判定はこれで見る。
#define ET_NAME_STEM "EffectDeck"

/// ルートピッカーに出る字。
#define ET_ROUTE_NAME "EffectDeck"

/// 仮想デバイス（ドライバ）の名前。出力先の名前として出る。
#define ET_DRIVER_NAME "EffectDeck"

/// 作った所。
#define ET_MANUFACTURER "nemut.ai"

#endif /* ETNames_h */
