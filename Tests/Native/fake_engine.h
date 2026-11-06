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


// ---- 流し込み（ETSampleStream.c の相手）。et_instance_stream_* と midi の読み 3 本を台本どおりに返す。 ----
// 音のスレッドだけが書く（control が読むのは止めてから）。世代と台本の入口だけ atomic。
#define FAKE_STREAM_LOG 1024
typedef struct {
    uint32_t instance;
    uint64_t generation;
    uint32_t sample;
    uint64_t page;
    uint32_t frames, channels, flags;
    int inProcess;       ///< publish が et_pipeline_process の最中に呼ばれた（描画の合間でなければ 1）
    et_status status;
    float first;         ///< pcm[0]
    int processCalls;    ///< そのときまでの et_pipeline_process の回数
} fake_publish_record;
typedef struct {
    uint32_t generation, window, flags, count;
    int inProcess;
    et_status status;
} fake_prefetch_record;

extern fake_publish_record fake_publishes[FAKE_STREAM_LOG];
extern _Atomic int fake_publish_count;
extern fake_prefetch_record fake_prefetches[FAKE_STREAM_LOG];
extern _Atomic int fake_prefetch_count;
/// configure が受け取った世代（0 = まだ）。publish はこれと違う世代を ET_ERR_STATE で断る。
extern _Atomic uint64_t fake_stream_generation;
extern et_status fake_stream_configure_status;
extern _Atomic int fake_stream_configure_calls;
/// take_requests が渡す要求（先頭から順に。使い切ると 0 件）。
extern et_sfz_sample_request fake_requests[4096];
extern _Atomic uint32_t fake_request_count;
extern uint32_t fake_request_cursor;
extern et_status fake_take_status;
extern _Atomic int fake_take_calls;
/// prefetch の戻りの台本。尽きたら ET_OK。
extern et_status fake_prefetch_script[64];
extern int fake_prefetch_script_count, fake_prefetch_script_cursor;
extern et_stream_readiness fake_readiness;
extern et_status fake_readiness_status;
extern _Atomic uint32_t fake_midi_generation, fake_midi_state, fake_asset_state;
/// stream 関数が process の最中に呼ばれた回数（描画の合間の約束が破れた印）。
extern _Atomic int fake_stream_in_process;

/// 数と止めを戻す（descriptor と外部コールバックはそのまま）。
void fake_reset(void);
void fake_sleep_us(unsigned us);
double fake_now_ms(void);
uint32_t fake_rd32(const uint8_t *p);

#endif /* FAKE_ENGINE_H */
