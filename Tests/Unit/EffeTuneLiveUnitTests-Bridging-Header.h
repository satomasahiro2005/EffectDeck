//  EffeTuneLiveUnitTests-Bridging-Header.h
//  テストバンドルから C の口を叩くための橋。
//
//  **本体の橋（Sources/EffeTuneLive/EffeTuneLive-Bridging-Header.h）を使い回さない。**
//  あちらは ETPipeline / ETResample / effetune/abi.h まで連れてくる。
//  このバンドルはアプリを建てずに対象だけをコンパイルしているので、
//  ここに入れるのは JSFX Host に要るものだけにする。

#import "ETJSFXHost.h"
