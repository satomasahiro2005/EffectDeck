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
static _Atomic int      gStatus  = 0;

static uint32_t gEngine = 0;
static int      gConfigured = 0;
static uint32_t gActive = 0;

static void writeU32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

void ETPipeline_SetEngine(uint32_t engine)
{
    gEngine = engine;
    gConfigured = 0;
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
    if (gEngine == 0) return NULL;
    return et_arena_combined_ptr(gEngine);
}

int32_t ETPipeline_LastStatus(void)
{
    return (int32_t)atomic_load_explicit(&gStatus, memory_order_relaxed);
}

uint64_t ETPipeline_ProcessCount(void)
{
    return (uint64_t)atomic_load_explicit(&gCount, memory_order_relaxed);
}

uint32_t ETPipeline_Process(uint32_t channels, uint32_t frames, double timeSeconds)
{
    atomic_fetch_add_explicit(&gCount, 1, memory_order_relaxed);

    if (gEngine == 0 || channels == 0 || frames == 0) return 0;

    // 溜まっている差し替えをここで反映する。
    // configure は確保を伴うが、鎖を変えたときだけなので毎ブロックでは起きない。
    // ここで呼ぶのは、処理と同じスレッドに寄せて競合を無くすため。
    int pending = atomic_exchange_explicit(&gPending, -1, memory_order_acquire);
    if (pending >= 0) {
        const ETPipeDescriptor *d = &gSlots[pending];
        et_status st = et_pipeline_configure(gEngine, d->bytes, d->length);
        atomic_store_explicit(&gStatus, (int)st, memory_order_relaxed);
        gConfigured = (st == ET_OK);
        gActive = gConfigured ? d->active : 0;
    }

    if (!gConfigured) return 0;

    const uint32_t bypass = atomic_load_explicit(&gBypass, memory_order_relaxed) ? 1u : 0u;
    et_status st = et_pipeline_process(gEngine, channels, frames, timeSeconds, bypass);
    if (st != ET_OK) {
        atomic_store_explicit(&gStatus, (int)st, memory_order_relaxed);
        return 0;
    }
    return bypass ? 0u : gActive;
}
