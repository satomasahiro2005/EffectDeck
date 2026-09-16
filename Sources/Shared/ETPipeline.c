//  ETPipeline.c

#include "ETPipeline.h"
#include "effetune/abi.h"

#include <string.h>
#include <stdatomic.h>

#define ET_PIPE_SLOTS 4
#define ET_PIPE_HEADER 8
#define ET_PIPE_NODE   12
#define ET_PIPE_VERSION 1
#define ET_PIPE_MAX_BYTES (ET_PIPE_HEADER + ET_PIPE_MAX_NODES * ET_PIPE_NODE)

typedef struct {
    uint8_t  bytes[ET_PIPE_MAX_BYTES];
    uint32_t length;
    uint32_t active;     // 有効なノードの数。表示用
} ETPipeDescriptor;

static ETPipeDescriptor gSlots[ET_PIPE_SLOTS];
static int              gWrite = 0;              // UI スレッドだけが触る

static _Atomic int      gPending = -1;           // 音のスレッドへ渡す面。-1 は無し
static _Atomic int      gBypass  = 0;
static _Atomic uint_least64_t gCount = 0;

// ET_OK は 0 なので、初期値を 0 にすると「configure が成功した」と見分けがつかない。
// 一度も configure していない間は ET_ERR_STATE にしておく。
static _Atomic int      gStatus  = ET_ERR_STATE;
static _Atomic uint_least64_t gConfigures = 0;   // et_pipeline_configure を呼んだ回数

// UI スレッドが書き、音のスレッドが読む。値を 1 つ渡すだけなので relaxed。
static _Atomic uint32_t gEngine = 0;
// 音のスレッドが書き、UI が読むので atomic にした。relaxed で足りる（値を 1 つ読むだけ）。
static _Atomic int           gConfigured = 0;
static _Atomic uint_least32_t gActive = 0;
// 鎖そのものが足す遅れ（標本）。et_pipeline_latency が返す値で、
// FIR を持つエフェクト（Phase Select EQ など）を入れると増える。
// configure のあとに読む。音のスレッドが書き、UI が読む。
static _Atomic uint_least32_t gLatency = 0;

static void writeU32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

void ETPipeline_SetEngine(uint32_t engine)
{
    atomic_store_explicit(&gEngine, engine, memory_order_relaxed);
    atomic_store_explicit(&gConfigured, 0, memory_order_relaxed);
    atomic_store_explicit(&gActive, 0, memory_order_relaxed);
    // 古い ET_OK を残すと「組めている」と読めてしまうので一緒に落とす。
    atomic_store_explicit(&gStatus, ET_ERR_STATE, memory_order_relaxed);
    // 溜まっている面も捨てる。中の instance 番号は前の engine のもので、
    // et_engine_prepare の destroyAllInstances でもう消えている。
    // 残すと次のブロックで ET_ERR_DESC になる（engine.cpp:674 slot == nullptr）。
    atomic_store_explicit(&gPending, -1, memory_order_relaxed);
}

void ETPipeline_Publish(const ETPipeNode *nodes, uint32_t count)
{
    if (count > ET_PIPE_MAX_NODES) count = ET_PIPE_MAX_NODES;

    int slot = gWrite;
    gWrite = (gWrite + 1) % ET_PIPE_SLOTS;

    ETPipeDescriptor *d = &gSlots[slot];
    memset(d, 0, sizeof(*d));

    writeU32(d->bytes, ET_PIPE_VERSION);
    writeU32(d->bytes + 4, count);

    for (uint32_t i = 0; i < count; i++) {
        uint8_t *rec = d->bytes + ET_PIPE_HEADER + i * ET_PIPE_NODE;
        writeU32(rec, nodes[i].instance);
        rec[4] = nodes[i].enabled ? 1u : 0u;
        rec[5] = nodes[i].inputBus;
        rec[6] = nodes[i].outputBus;
        rec[7] = (uint8_t)nodes[i].channelSpec;
        rec[8] = nodes[i].sectionGate ? 1u : 0u;
        // rec[9..11] は詰め物。ゼロでなければ engine に弾かれる。
    }
    d->length = ET_PIPE_HEADER + count * ET_PIPE_NODE;
    for (uint32_t i = 0; i < count; i++) {
        if (nodes[i].enabled && nodes[i].sectionGate) d->active++;
    }

    atomic_store_explicit(&gPending, slot, memory_order_release);
}

void ETPipeline_SetBypass(int bypass)
{
    atomic_store_explicit(&gBypass, bypass ? 1 : 0, memory_order_relaxed);
}

float *ETPipeline_MainBus(void)
{
    const uint32_t engine = atomic_load_explicit(&gEngine, memory_order_relaxed);
    if (engine == 0) return NULL;
    return et_arena_combined_ptr(engine);
}

int32_t ETPipeline_LastStatus(void)
{
    return (int32_t)atomic_load_explicit(&gStatus, memory_order_relaxed);
}

uint64_t ETPipeline_ProcessCount(void)
{
    return (uint64_t)atomic_load_explicit(&gCount, memory_order_relaxed);
}

uint64_t ETPipeline_ConfigureCount(void)
{
    return (uint64_t)atomic_load_explicit(&gConfigures, memory_order_relaxed);
}

uint32_t ETPipeline_ActiveNodes(void)
{
    return (uint32_t)atomic_load_explicit(&gActive, memory_order_relaxed);
}

uint32_t ETPipeline_Latency(void)
{
    return (uint32_t)atomic_load_explicit(&gLatency, memory_order_relaxed);
}

int ETPipeline_IsBypassed(void)
{
    return atomic_load_explicit(&gBypass, memory_order_relaxed);
}

int ETPipeline_HasConfigured(void)
{
    return atomic_load_explicit(&gConfigured, memory_order_relaxed);
}

int32_t ETPipeline_Process(uint32_t channels, uint32_t frames, double timeSeconds)
{
    atomic_fetch_add_explicit(&gCount, 1, memory_order_relaxed);

    const uint32_t engine = atomic_load_explicit(&gEngine, memory_order_relaxed);
    if (engine == 0 || channels == 0 || frames == 0) return ET_ERR_ARGS;

    // 溜まっている差し替えをここで反映する。
    // configure は確保を伴うが、鎖を変えたときだけなので毎ブロックでは起きない。
    // ここで呼ぶのは、処理と同じスレッドに寄せて競合を無くすため。
    int pending = atomic_exchange_explicit(&gPending, -1, memory_order_acquire);
    if (pending >= 0) {
        const ETPipeDescriptor *d = &gSlots[pending];
        et_status st = et_pipeline_configure(engine, d->bytes, d->length);
        // 呼んだ事実そのものを数える。0 なら Publish が一度も拾われていない。
        atomic_fetch_add_explicit(&gConfigures, 1, memory_order_relaxed);
        atomic_store_explicit(&gStatus, (int)st, memory_order_relaxed);
        atomic_store_explicit(&gConfigured, st == ET_OK ? 1 : 0, memory_order_relaxed);
        atomic_store_explicit(&gActive,
                              (uint_least32_t)(st == ET_OK ? d->active : 0u),
                              memory_order_relaxed);
        // **鎖が足す遅れはここでしか読めない。**
        // 組み直した直後の値が正で、次の configure まで変わらない。
        atomic_store_explicit(&gLatency,
                              (uint_least32_t)(st == ET_OK ? et_pipeline_latency(engine) : 0u),
                              memory_order_relaxed);
    }

    if (!atomic_load_explicit(&gConfigured, memory_order_relaxed)) return ET_ERR_STATE;

    const uint32_t bypass = atomic_load_explicit(&gBypass, memory_order_relaxed) ? 1u : 0u;
    // process のエラーは gStatus に入れない。入れると configure の結果を潰してしまい、
    // 「組めなかった」のか「組めたが処理に失敗した」のか読めなくなる。戻り値で返す。
    return (int32_t)et_pipeline_process(engine, channels, frames, timeSeconds, bypass);
}
