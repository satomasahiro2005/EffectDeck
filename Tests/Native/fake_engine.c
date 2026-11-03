//  fake_engine.c
//  fake_engine.h の中身。POSIX（Linux / macOS）だけ。MSVC では建てない。

// nanosleep / clock_gettime / CLOCK_MONOTONIC は POSIX。-std=c11 の glibc では宣言が隠れる。
// ETPipeline.c と同じ守り。
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 199309L
#endif

#include "fake_engine.h"

#include <string.h>
#include <time.h>

float fake_bus[FAKE_MAX_CHANNELS * FAKE_MAX_FRAMES];
uint8_t fake_desc[FAKE_DESC_BYTES];
uint32_t fake_desc_len;
et_status fake_configure_result = ET_OK;
_Atomic uint32_t fake_native_latency;
uint32_t fake_last_channels, fake_last_frames, fake_last_bypass;
_Atomic int fake_process_calls, fake_configure_calls;
_Atomic int fake_block_process, fake_in_process;
_Atomic int fake_block_configure, fake_in_configure;
_Atomic int fake_torn;
_Atomic int fake_in_destroy, fake_overlap, fake_destroyed;
fake_external_fn fake_cb;
fake_latency_fn fake_lcb;
void *fake_ctx;

void fake_sleep_us(unsigned us)
{
    struct timespec t = {(time_t)(us / 1000000u), (long)(us % 1000000u) * 1000L};
    nanosleep(&t, NULL);
}

double fake_now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}

uint32_t fake_rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

void fake_reset(void)
{
    fake_configure_result = ET_OK;
    atomic_store(&fake_native_latency, 0);
    atomic_store(&fake_process_calls, 0);
    atomic_store(&fake_configure_calls, 0);
    atomic_store(&fake_block_process, 0);
    atomic_store(&fake_block_configure, 0);
    atomic_store(&fake_torn, 0);
    atomic_store(&fake_overlap, 0);
    atomic_store(&fake_destroyed, 0);
}

#if ET_FAKE_EXTERNAL_CALLBACK
void et_pipeline_set_external_callback(et_engine engine, fake_external_fn cb, fake_latency_fn lcb,
                                       void *ctx)
{
    (void)engine;
    fake_cb = cb;
    fake_lcb = lcb;
    fake_ctx = ctx;
}
#endif

float *et_arena_combined_ptr(et_engine engine)
{
    (void)engine;
    return fake_bus;
}

uint32_t et_pipeline_latency(et_engine engine)
{
    (void)engine;
    return atomic_load(&fake_native_latency);
}

et_status et_pipeline_configure(et_engine engine, const uint8_t *descriptor, uint32_t bytes)
{
    (void)engine;
    atomic_fetch_add(&fake_configure_calls, 1);
    if (bytes > FAKE_DESC_BYTES) return ET_ERR_DESC;
    atomic_store(&fake_in_configure, 1);
    // 読み始めの中身を控え、止めを解かれてからもう一度比べる。違えば読んでいる最中に書かれた。
    uint8_t snapshot[FAKE_DESC_BYTES];
    memcpy(snapshot, descriptor, bytes);
    while (atomic_load(&fake_block_configure)) fake_sleep_us(100);
    if (memcmp(snapshot, descriptor, bytes) != 0) atomic_store(&fake_torn, 1);
    memcpy(fake_desc, descriptor, bytes);
    fake_desc_len = bytes;
    atomic_store(&fake_in_configure, 0);
    return fake_configure_result;
}

et_status et_pipeline_process(et_engine engine, uint32_t channels, uint32_t frames,
                              double timeSeconds, uint32_t bypass)
{
    (void)engine;
    atomic_store(&fake_in_process, 1);
    if (atomic_load(&fake_in_destroy)) atomic_store(&fake_overlap, 1);
    atomic_fetch_add(&fake_process_calls, 1);
    fake_last_channels = channels;
    fake_last_frames = frames;
    fake_last_bypass = bypass;
    while (atomic_load(&fake_block_process)) fake_sleep_us(100);
    et_status status = ET_OK;
    // パッチの当たった engine と同じく、外部ノードを descriptor の順にその場で呼ぶ。
    // 入切と Section の門が閉じているものは飛ばす（engine.cpp:916-919）。
    const uint32_t count = fake_desc_len >= 8 ? fake_rd32(fake_desc + 4) : 0;
    for (uint32_t i = 0; i < count && fake_cb != NULL; i++) {
        const uint8_t *rec = fake_desc + 8 + i * 12;
        if (rec[9] == 1 && rec[4] && rec[8]) {
            status = fake_cb(fake_ctx, rec[10], fake_bus, channels, frames, timeSeconds,
                             (int8_t)rec[7]);
            if (status != ET_OK) break;
        }
    }
    atomic_store(&fake_in_process, 0);
    return status;
}

void et_instance_destroy(et_engine engine, et_instance instance)
{
    (void)engine;
    (void)instance;
    atomic_store(&fake_in_destroy, 1);
    if (atomic_load(&fake_in_process)) atomic_store(&fake_overlap, 1);
    fake_sleep_us(10);
    atomic_fetch_add(&fake_destroyed, 1);
    atomic_store(&fake_in_destroy, 0);
}
