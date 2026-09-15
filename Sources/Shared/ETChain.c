//  ETChain.c
//
//  鎖の置き場を 8 面用意して、書き終えてから「これを使え」と番号を差し替える。
//  音のスレッドは番号を 1 回読んで、その面だけを見る。
//  1 コールバックの間に 8 回差し替えない限り、読んでいる最中の面は書き換わらない。

#include "ETChain.h"
#include "effetune/abi.h"

#include <string.h>
#include <stdatomic.h>

#define ET_CHAIN_SLOTS 8

typedef struct {
    uint32_t instances[ET_CHAIN_MAX];
    uint32_t count;
} ETChainSet;

static ETChainSet      gSets[ET_CHAIN_SLOTS];
static _Atomic int     gCurrent = -1;     // -1 = 鎖が無い＝素通し
static int             gWrite   = 0;      // UI スレッドだけが触る
static uint32_t        gEngine  = 0;
static _Atomic int     gBypass  = 0;
static _Atomic uint_least64_t gCount = 0;

void ETChain_SetEngine(uint32_t engine)
{
    gEngine = engine;
}

void ETChain_Publish(const uint32_t *instances, uint32_t count)
{
    if (count > ET_CHAIN_MAX) count = ET_CHAIN_MAX;

    int slot = gWrite;
    gWrite = (gWrite + 1) % ET_CHAIN_SLOTS;

    ETChainSet *set = &gSets[slot];
    memset(set, 0, sizeof(*set));
    if (instances && count > 0) {
        memcpy(set->instances, instances, count * sizeof(uint32_t));
        set->count = count;
    }

    atomic_store_explicit(&gCurrent, slot, memory_order_release);
}

void ETChain_SetBypass(int bypass)
{
    atomic_store_explicit(&gBypass, bypass ? 1 : 0, memory_order_relaxed);
}

uint32_t ETChain_Process(float *planar, uint32_t channels, uint32_t frames, double timeSeconds)
{
    atomic_fetch_add_explicit(&gCount, 1, memory_order_relaxed);

    if (!planar || channels == 0 || frames == 0) return 0;
    if (gEngine == 0) return 0;
    if (atomic_load_explicit(&gBypass, memory_order_relaxed)) return 0;

    int slot = atomic_load_explicit(&gCurrent, memory_order_acquire);
    if (slot < 0) return 0;

    const ETChainSet *set = &gSets[slot];
    uint32_t applied = 0;
    for (uint32_t i = 0; i < set->count; i++) {
        if (et_instance_process(gEngine, set->instances[i], planar,
                                channels, frames, timeSeconds) == ET_OK) {
            applied++;
        }
    }
    return applied;
}

uint64_t ETChain_ProcessCount(void)
{
    return (uint64_t)atomic_load_explicit(&gCount, memory_order_relaxed);
}
