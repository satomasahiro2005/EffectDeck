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

fake_publish_record fake_publishes[FAKE_STREAM_LOG];
_Atomic int fake_publish_count;
fake_prefetch_record fake_prefetches[FAKE_STREAM_LOG];
_Atomic int fake_prefetch_count;
_Atomic uint64_t fake_stream_generation;
et_status fake_stream_configure_status = ET_OK;
_Atomic int fake_stream_configure_calls;
et_sfz_sample_request fake_requests[4096];
_Atomic uint32_t fake_request_count;
uint32_t fake_request_cursor;
et_status fake_take_status = ET_OK;
_Atomic int fake_take_calls;
et_status fake_prefetch_script[64];
int fake_prefetch_script_count, fake_prefetch_script_cursor;
et_stream_readiness fake_readiness;
et_status fake_readiness_status = ET_OK;
_Atomic uint32_t fake_midi_generation, fake_midi_state, fake_asset_state = ET_ASSET_STATE_ACTIVE;
_Atomic int fake_stream_in_process;
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
    atomic_store(&fake_publish_count, 0);
    atomic_store(&fake_prefetch_count, 0);
    atomic_store(&fake_stream_generation, 0);
    fake_stream_configure_status = ET_OK;
    atomic_store(&fake_stream_configure_calls, 0);
    atomic_store(&fake_request_count, 0);
    fake_request_cursor = 0;
    fake_take_status = ET_OK;
    atomic_store(&fake_take_calls, 0);
    fake_prefetch_script_count = fake_prefetch_script_cursor = 0;
    memset(&fake_readiness, 0, sizeof fake_readiness);
    fake_readiness_status = ET_OK;
    atomic_store(&fake_midi_generation, 0);
    atomic_store(&fake_midi_state, 0);
    atomic_store(&fake_asset_state, ET_ASSET_STATE_ACTIVE);
    atomic_store(&fake_stream_in_process, 0);
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

// ---- 流し込み ----
// 描画の最中（fake_in_process）に呼ばれたら印を立てる。ETPipeline.c は描画の前後でだけ呼ぶ約束。
static void noteStreamCall(void)
{
    if (atomic_load(&fake_in_process)) atomic_fetch_add(&fake_stream_in_process, 1);
}

et_status et_instance_stream_configure(et_engine engine, et_instance instance,
                                       uint32_t generation_low, uint32_t generation_high)
{
    (void)engine;
    (void)instance;
    atomic_fetch_add(&fake_stream_configure_calls, 1);
    if (fake_stream_configure_status != ET_OK) return fake_stream_configure_status;
    atomic_store(&fake_stream_generation, (uint64_t)generation_low | (uint64_t)generation_high << 32u);
    return ET_OK;
}

et_status et_instance_stream_take_requests(et_engine engine, et_instance instance,
                                           et_sfz_sample_request *requests, uint32_t capacity,
                                           uint32_t *count)
{
    (void)engine;
    (void)instance;
    noteStreamCall();
    atomic_fetch_add(&fake_take_calls, 1);
    *count = 0;
    if (fake_take_status != ET_OK) return fake_take_status;
    const uint32_t total = atomic_load(&fake_request_count);
    while (*count < capacity && fake_request_cursor < total) requests[(*count)++] = fake_requests[fake_request_cursor++];
    return ET_OK;
}

et_status et_instance_stream_publish(et_engine engine, et_instance instance,
                                     uint32_t generation_low, uint32_t generation_high,
                                     uint32_t sample, uint32_t page_low, uint32_t page_high,
                                     const float *pcm, uint32_t frames, uint32_t channels,
                                     uint32_t flags)
{
    (void)engine;
    noteStreamCall();
    const uint64_t generation = (uint64_t)generation_low | (uint64_t)generation_high << 32u;
    et_status status = ET_OK;
    if (generation == 0 || generation != atomic_load(&fake_stream_generation)) status = ET_ERR_STATE;
    else if ((flags & ~1u) || frames < 1 || frames > 4096 || channels < 1 || channels > 2 || pcm == NULL) status = ET_ERR_ARGS;
    const int at = atomic_fetch_add(&fake_publish_count, 1);
    if (at < FAKE_STREAM_LOG) {
        fake_publish_record *r = &fake_publishes[at];
        r->instance = instance;
        r->generation = generation;
        r->sample = sample;
        r->page = (uint64_t)page_low | (uint64_t)page_high << 32u;
        r->frames = frames;
        r->channels = channels;
        r->flags = flags;
        r->inProcess = atomic_load(&fake_in_process);
        r->status = status;
        r->first = pcm != NULL ? pcm[0] : 0.0f;
        r->processCalls = atomic_load(&fake_process_calls);
    }
    return status;
}

et_status et_instance_stream_prefetch(et_engine engine, et_instance instance,
                                      const et_midi_event *events, uint32_t count,
                                      uint32_t generation, uint32_t window_frames, uint32_t flags)
{
    (void)engine;
    (void)instance;
    (void)events;
    noteStreamCall();
    et_status status = ET_OK;
    if (fake_prefetch_script_cursor < fake_prefetch_script_count)
        status = fake_prefetch_script[fake_prefetch_script_cursor++];
    const int at = atomic_fetch_add(&fake_prefetch_count, 1);
    if (at < FAKE_STREAM_LOG) {
        fake_prefetch_record *r = &fake_prefetches[at];
        r->generation = generation;
        r->window = window_frames;
        r->flags = flags;
        r->count = count;
        r->inProcess = atomic_load(&fake_in_process);
        r->status = status;
    }
    return status;
}

et_status et_instance_stream_readiness(et_engine engine, et_instance instance, et_stream_readiness *out)
{
    (void)engine;
    (void)instance;
    noteStreamCall();
    *out = fake_readiness;
    return fake_readiness_status;
}

uint32_t et_instance_midi_generation(et_engine engine, et_instance instance)
{
    (void)engine;
    (void)instance;
    return atomic_load(&fake_midi_generation);
}

uint32_t et_instance_midi_state(et_engine engine, et_instance instance)
{
    (void)engine;
    (void)instance;
    return atomic_load(&fake_midi_state);
}

uint32_t et_instance_asset_state(et_engine engine, et_instance instance, uint32_t slot)
{
    (void)engine;
    (void)instance;
    (void)slot;
    return atomic_load(&fake_asset_state);
}
