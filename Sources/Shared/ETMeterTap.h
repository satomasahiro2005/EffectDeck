//  ETMeterTap.h
//  PiP の Mini Meters へ音を渡す口。鎖の入口か出口の音を、ステレオで輪に写す。
//
//  **音のスレッドでは写すだけ。**FFT もラウドネスも読む側（画面のスレッド）で計算する。
//  書き手は音のスレッド 1 本、読み手は画面のスレッド 1 本。鍵は取らない。
//  読む前に輪を一周追い越されたら、その分は捨てて新しい方から読む（図なので抜けてよい）。

#ifndef ETMeterTap_h
#define ETMeterTap_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    ET_METER_TAP_OFF = -1,
    ET_METER_TAP_INPUT = 0,
    ET_METER_TAP_OUTPUT = 1,
};

/// どこを写すか。ET_METER_TAP_OFF なら何もしない（音のスレッドは比べて戻るだけ）。
void ETMeterTap_SetPoint(int32_t point);

/// 音のスレッドから。`planar` はプレーナ（ch0 が frames 個、その後 ch1）。
/// 1 チャンネルなら左右に同じものを入れる。`planar` が NULL なら無音を入れる。
void ETMeterTap_Write(int32_t point, const float *planar, uint32_t channels, uint32_t frames);

/// 画面のスレッドから。`from` 以降に書かれたものを、新しい方から最大 `maxFrames` 個、
/// `dst` へ LRLR… で写す。戻り値は写したフレーム数。`next` に次に渡す位置が入る。
uint32_t ETMeterTap_Read(uint64_t from, float *dst, uint32_t maxFrames, uint64_t *next);

#ifdef __cplusplus
}
#endif

#endif
