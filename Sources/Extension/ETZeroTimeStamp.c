//  ETZeroTimeStamp.c
//  ドライバのゼロタイムスタンプ。説明は ETZeroTimeStamp.h。

#include "ETZeroTimeStamp.h"
#include <stddef.h>

double ETZeroTimeStamp_HostTicksPerFrame(double sampleRate, uint32_t numer, uint32_t denom) {
    const double nsPerFrame = 1.0e9 / sampleRate;
    return nsPerFrame * (double)denom / (double)numer;
}

void ETZeroTimeStamp_Initialize(ETZeroTimeStamp *z) {
    if (!z) return;
    z->anchorHostTime = 0;
}

void ETZeroTimeStamp_StartIO(ETZeroTimeStamp *z) {
    if (!z) return;
    z->running = true;
    // ここで時刻の基準を巻き戻すので、タイムラインは不連続になる。
    // seed を進めないと、ホストは前の続きと思って飛んだ時刻を受け取る。
    z->seed++;
    z->anchorHostTime = 0;
    z->lastSampleTime = 0;
    z->lastHostTime = 0;
    z->periodCount = 0;
}

void ETZeroTimeStamp_StopIO(ETZeroTimeStamp *z) {
    if (!z) return;
    z->running = false;
}

void ETZeroTimeStamp_Get(ETZeroTimeStamp *z, uint64_t now,
                         double hostTicksPerFrame, uint32_t periodFrames,
                         double *outSampleTime, uint64_t *outHostTime, uint64_t *outSeed) {
    if (!z) return;
    const double hostTicksPerPeriod = hostTicksPerFrame * (double)periodFrames;

    if (z->anchorHostTime == 0) {
        z->anchorHostTime = now;
        z->periodCount = 0;
    }
    // 次の周期の開始時刻を超えていたら 1 周期進める。
    double offset = ((double)(z->periodCount + 1)) * hostTicksPerPeriod;
    uint64_t nextHostTime = z->anchorHostTime + (uint64_t)offset;
    if (nextHostTime <= now) {
        z->periodCount++;
    }
    double st = (double)(z->periodCount * (uint64_t)periodFrames);
    uint64_t ht = z->anchorHostTime + (uint64_t)(((double)z->periodCount) * hostTicksPerPeriod);
    z->lastSampleTime = st;
    z->lastHostTime = ht;

    if (outSampleTime) *outSampleTime = st;
    if (outHostTime)   *outHostTime   = ht;
    if (outSeed)       *outSeed       = z->seed;
}
