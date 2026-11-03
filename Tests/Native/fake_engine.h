//  fake_engine.h
//  ETPipeline.c の相手をする作り物の EffeTune engine（et_* の 6 本だけ）。
//
//  本物の engine（Vendor/effetune + Patches）で見るのは pipeline_engine.c。
//  こちらは engine を建てずに、ETPipeline.c が descriptor をどう書き、いつ configure を呼び、
//  壊す側とどう待ち合わせるかを見る。configure と process は止められるので、
//  音のスレッドが engine の中に居る間に UI が何をするかを作れる。
//
//  ET_FAKE_EXTERNAL_CALLBACK=1 で建てると et_pipeline_set_external_callback を持つ
//  （パッチの当たった engine）。0 だと持たず、ETPipeline.c の弱い参照は NULL になる（旧来の engine）。

#ifndef FAKE_ENGINE_H
#define FAKE_ENGINE_H

#include "effetune/abi.h"

#include <stdatomic.h>
#include <stdint.h>

#ifndef ET_FAKE_EXTERNAL_CALLBACK
#define ET_FAKE_EXTERNAL_CALLBACK 0
#endif

typedef int32_t (*fake_external_fn)(void *, uint32_t, float *, uint32_t, uint32_t, double, int8_t);
typedef uint32_t (*fake_latency_fn)(void *, uint32_t);

#define FAKE_MAX_CHANNELS 8
#define FAKE_MAX_FRAMES 4096
#define FAKE_DESC_BYTES (8 + 64 * 12)

extern float fake_bus[FAKE_MAX_CHANNELS * FAKE_MAX_FRAMES];

// configure が最後に受け取った descriptor（音のスレッドが書く。読むのは止めてから）。
extern uint8_t fake_desc[FAKE_DESC_BYTES];
extern uint32_t fake_desc_len;

extern et_status fake_configure_result;
extern _Atomic uint32_t fake_native_latency;
extern uint32_t fake_last_channels, fake_last_frames, fake_last_bypass;

extern _Atomic int fake_process_calls;
extern _Atomic int fake_configure_calls;
extern _Atomic int fake_block_process, fake_in_process;
extern _Atomic int fake_block_configure, fake_in_configure;
/// configure が読んでいる途中で descriptor が書き換わった。
extern _Atomic int fake_torn;
extern _Atomic int fake_in_destroy, fake_overlap, fake_destroyed;

// et_pipeline_set_external_callback で渡されたもの（パッチの当たった版だけ）。
extern fake_external_fn fake_cb;
extern fake_latency_fn fake_lcb;
extern void *fake_ctx;

/// 数と止めを戻す（descriptor と外部コールバックはそのまま）。
void fake_reset(void);
void fake_sleep_us(unsigned us);
double fake_now_ms(void);
uint32_t fake_rd32(const uint8_t *p);

#endif /* FAKE_ENGINE_H */
