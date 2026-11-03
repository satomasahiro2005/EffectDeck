//  ETMeterTap.c
//  決まりは ETMeterTap.h の頭。

#include "ETMeterTap.h"
#include <stdatomic.h>
#include <stddef.h>

/// 輪の長さ（フレーム）。2 の冪。48kHz で 1.3 秒。
#define ET_METER_CAPACITY 65536u

static float gRing[ET_METER_CAPACITY * 2];
static _Atomic uint64_t gWrite;
static _Atomic int32_t gPoint = ET_METER_TAP_OFF;

void ETMeterTap_SetPoint(int32_t point)
{
    atomic_store_explicit(&gPoint, point, memory_order_relaxed);
}

void ETMeterTap_Write(int32_t point, const float *planar, uint32_t channels, uint32_t frames)
{
    if (point < 0 || atomic_load_explicit(&gPoint, memory_order_relaxed) != point) return;
    if (channels == 0 || frames == 0) return;
    const uint64_t w = atomic_load_explicit(&gWrite, memory_order_relaxed);
    const float *left = planar;
    const float *right = (planar != NULL && channels > 1) ? planar + frames : planar;
    for (uint32_t i = 0; i < frames; ++i) {
        const uint32_t k = (uint32_t)((w + i) & (ET_METER_CAPACITY - 1)) * 2;
        gRing[k] = left != NULL ? left[i] : 0.0f;
        gRing[k + 1] = right != NULL ? right[i] : 0.0f;
    }
    atomic_store_explicit(&gWrite, w + frames, memory_order_release);
}

uint32_t ETMeterTap_Read(uint64_t from, float *dst, uint32_t maxFrames, uint64_t *next)
{
    const uint64_t end = atomic_load_explicit(&gWrite, memory_order_acquire);
    if (next != NULL) *next = end;
    if (dst == NULL || maxFrames == 0 || from >= end) return 0;
    // 追い越されかけている所は読まない。半周より前は書き換え中かもしれない。
    uint64_t start = from;
    const uint64_t safe = ET_METER_CAPACITY / 2;
    if (end - start > safe) start = end - safe;
    if (end - start > maxFrames) start = end - maxFrames;
    const uint32_t n = (uint32_t)(end - start);
    for (uint32_t i = 0; i < n; ++i) {
        const uint32_t k = (uint32_t)((start + i) & (ET_METER_CAPACITY - 1)) * 2;
        dst[2 * i] = gRing[k];
        dst[2 * i + 1] = gRing[k + 1];
    }
    return n;
}
