//  ETZeroTimeStamp.h
//  ドライバのゼロタイムスタンプの計算と、StartIO / StopIO が動かす時刻の状態。
//  EffeTuneDriver.m の ET_GetZeroTimeStamp / ET_StartIO / ET_StopIO がこれを呼ぶ。
//
//  **挙動は EffeTuneDriver.m に直に書いてあったときと同じ。**移したのは計算だけで、
//  mach_absolute_time とロックは EffeTuneDriver.m に残した。
//  ここだけを Linux で建てて確かめる（Tests/Native/driver）。
//
//  仮想デバイスなのでホストクロックから作る。周期（periodFrames）ごとに
//  1 つずつ進む階段で、サンプル時刻は必ず周期の整数倍、ホスト時刻は
//  基準 + n 周期。
//
//  seed の扱い。
//  以前は周期ごとに増やしていて、それは
//    HALS_IORawClock::Update: Re-anchoring IO timeline. Zero timestamp seed changed
//  をホストに毎回起こさせ、後続のセッション活性化が
//    AudioSessionServerImp_iOS.mm:899 "early exit due to failure" ('!pla') で落ちていた。
//  そのあと 1 固定にしたが、今度は StartIO で時刻を巻き戻しているのに
//  同じ seed を名乗ることになっていた。
//  正しいのは「連続しているあいだは同じ、張り直したときだけ進める」。
//  AudioServerPlugIn.h も「タイムラインが変わったら seed を変えろ」と書いている。
//
//  **StartIO は数えない。**StopIO を挟まずに StartIO が 2 回来ても、2 回とも
//  基準を巻き戻して seed を進め、最初の StopIO で止まったことになる。
//  Apple の NullAudio はクライアントを数えるが、iOS がこのドライバに
//  2 つ目の HAL クライアントを付けるかは確かめていない。いまの形を
//  テストで固定してある（Tests/Native/driver の double_start_resets）。

#ifndef ETZeroTimeStamp_h
#define ETZeroTimeStamp_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ETZeroTimeStamp {
    /// kAudioDevicePropertyDeviceIsRunning が返す値。
    bool     running;
    /// タイムラインの世代。**StartIO で張り直したときだけ進める。**
    uint64_t seed;
    /// 周期 0 のホスト時刻。0 は「まだ無い」で、次の Get がその時点に置く。
    uint64_t anchorHostTime;
    /// 基準から数えた周期の数。
    uint64_t periodCount;
    /// 直近に返したサンプル時刻とホスト時刻。
    double   lastSampleTime;
    uint64_t lastHostTime;
} ETZeroTimeStamp;

/// プロセスが起きたときの状態。seed は 1 から。
#define ET_ZERO_TIMESTAMP_INIT { false, 1, 0, 0, 0.0, 0 }

/// 1 フレームあたりのホストティック数。mach_timebase_info の numer / denom を渡す。
double ETZeroTimeStamp_HostTicksPerFrame(double sampleRate, uint32_t numer, uint32_t denom);

/// ET_Initialize。基準だけ捨てる。seed は進めない（まだ IO が始まっていない）。
void ETZeroTimeStamp_Initialize(ETZeroTimeStamp *z);

/// ET_StartIO。走っている印を立て、基準を巻き戻し、seed を進める。
/// 走っている最中にもう一度呼んでも同じことをする（数えない）。
void ETZeroTimeStamp_StartIO(ETZeroTimeStamp *z);

/// ET_StopIO。走っている印を下ろすだけ。タイムラインは触らない。
void ETZeroTimeStamp_StopIO(ETZeroTimeStamp *z);

/// ET_GetZeroTimeStamp。now はいまのホスト時刻。
/// 基準が無ければ now に置く。次の周期の開始を越えていたら **1 周期だけ** 進める
/// （呼ばれ方が空いても 1 回に 1 周期ずつ追いつく）。
/// リアルタイムスレッドから呼ぶ。ロックも確保もしない。出力はどれも NULL でよい。
void ETZeroTimeStamp_Get(ETZeroTimeStamp *z, uint64_t now,
                         double hostTicksPerFrame, uint32_t periodFrames,
                         double *outSampleTime, uint64_t *outHostTime, uint64_t *outSeed);

#ifdef __cplusplus
}
#endif

#endif /* ETZeroTimeStamp_h */
