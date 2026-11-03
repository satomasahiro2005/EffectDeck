//  EffeTuneLiveUnitTests-Bridging-Header.h
//  テストバンドルから C の口を叩くための橋。
//
//  **本体の橋（Sources/EffeTuneLive/EffeTuneLive-Bridging-Header.h）を使い回さない。**
//  あちらは ETPipeline / ETResample / effetune/abi.h まで連れてくる。
//  このバンドルはアプリを建てずに対象だけをコンパイルしているので、
//  ここに入れるのは JSFX Host と、PiP の帯が音を読む口（ETMeterTap）に要るものだけにする。

#import "ETJSFXHost.h"
// PiP の帯（MiniMetersTests）が音の輪へ書く。
#import "ETMeterTap.h"
