//  ETSampleStream.c

// nanosleep は POSIX。-std=c11 の glibc では宣言が隠れる（Darwin は隠さない）。
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 199309L
#endif

#include "ETSampleStream.h"
#include "effetune/abi.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define ET_RING_MASK (ET_STREAM_REQUEST_RING - 1)
#define ET_POOL_MASK (ET_STREAM_POOL_PAGES - 1)
#define ET_PAGE_FLOATS (ET_STREAM_PAGE_FRAMES * ET_STREAM_PAGE_MAX_CHANNELS)
#define ET_GRAVEYARD 16

_Static_assert((ET_STREAM_REQUEST_RING & (ET_STREAM_REQUEST_RING - 1)) == 0, "ring is a power of two");
_Static_assert((ET_STREAM_POOL_PAGES & (ET_STREAM_POOL_PAGES - 1)) == 0, "pool is a power of two");
_Static_assert(ET_STREAM_REQUEST_RING <= 4096, "engine accepts at most 4096 requests per take");
_Static_assert(sizeof(et_sfz_sample_request) == 24, "abi.h request layout");

enum { PAGE_FREE = 0, PAGE_FILLING = 1, PAGE_READY = 2 };
enum { SLOT_FREE = 0, SLOT_ACTIVE = 1, SLOT_RETIRED = 2 };

// 輪と置き場。Attach で 1 回だけ確保し、畳むときに返す。
typedef struct Storage {
    ETStreamRequest requests[ET_STREAM_REQUEST_RING];
    // 要求の輪。生産者は音のスレッド、消費者は供給。カウンタは巻き戻さず、添え字は & ET_RING_MASK。
    _Atomic uint32_t reqHead, reqTail;
    // 用意できたページの輪。生産者は供給、消費者は音のスレッド。置き場の枚数を超えて積めない。
    uint16_t ready[ET_STREAM_POOL_PAGES];
    _Atomic uint32_t readyHead, readyTail;
    // 供給が借りているページの数。0 になるまで確保を返さない。
    _Atomic int filling;
    _Atomic int pageState[ET_STREAM_POOL_PAGES];
    ETStreamPage pages[ET_STREAM_POOL_PAGES];
} Storage;

typedef struct {
    int valid;
    uint32_t nativeGeneration;
    uint32_t windowIndex, windowFrames;
    int reset, ready, pressure;
    uint32_t nativeScope;
    uint64_t retryFrame, refreshFrame;
} Forecast;

typedef struct {
    _Atomic int state;
    // 供給側の呼び出しが入っている数。畳む側は 0 になるまで確保を返さない。
    _Atomic int sBusy;
    uint32_t engine, instance;
    double rate;
    uint32_t flags;
    _Atomic uint64_t generation;
    Storage *store;

    _Atomic uint64_t taken, published, stale, rejected, publishErrors, abandoned, overflows, forecastRuns, forecastErrors;
    // 供給が作れなかった要求の数と、最初の理由（ET_STREAM_FAIL_*。0 = 無し）。理由が立ったら先読みも止める。
    _Atomic uint64_t failedRequests;
    _Atomic uint32_t failed;
    // 0 のあいだは先読みを進めない（node か Section が無効。上流の advanceSfzSampleForecast の plugin.enabled === false）。
    _Atomic int enabled;
    _Atomic uint32_t maxPublish, fReady, fLimited, rScope, rPlanned, rPending, rAdmitted, rAhead;

    // 以下は音のスレッドだけが触る。
    Forecast fc;
    int goalValid;
    uint32_t goalNativeGeneration;
    int limited;
    uint64_t nextForecast;
    // 前回の予測までに取り出した要求の数（上流の「前回の poll で渡した分」）。返し終えるまで次の予測へ進まない。
    uint64_t pollMark;
} Slot;

static Slot gSlots[ET_STREAM_MAX_SLOTS];
static Storage *gGraveyard[ET_GRAVEYARD];
static _Atomic int gControlLock = 0;
// 世代の栅の約束。controlLock の中でだけ触る。gAttached は Attach が受けた最大、gIssued は NextGeneration が渡した最大。
static uint64_t gAttached = 0;
static uint64_t gIssued = 0;
static unsigned gRoundRobin = 0;    // 音のスレッドだけ
static uint64_t gClock = 0;         // 音のスレッドだけ。処理したフレームの合計

// 音のスレッドの出入り。ETPipeline.c の enterEngine / DestroyInstances と同じ約束で、
// 両側とも seq_cst（自分の印を立ててから相手の印を読む）。待たず・確保しない。
static _Atomic int gInside = 0;
static _Atomic int gHold = 0;
static _Atomic uint_least32_t gBounced = 0;

static int renderEnter(void)
{
    atomic_store_explicit(&gInside, 1, memory_order_seq_cst);
    if (atomic_load_explicit(&gHold, memory_order_seq_cst) == 0) return 1;
    atomic_store_explicit(&gInside, 0, memory_order_seq_cst);
    atomic_fetch_add_explicit(&gBounced, 1, memory_order_seq_cst);
    return 0;
}

static void renderLeave(void) { atomic_store_explicit(&gInside, 0, memory_order_seq_cst); }

static long long monotonicNanos(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static void nap(void)
{
    const struct timespec t = {0, 100000};
    nanosleep(&t, NULL);
}

static void controlLock(void)
{
    while (atomic_exchange_explicit(&gControlLock, 1, memory_order_acquire)) nap();
}

static void controlUnlock(void) { atomic_store_explicit(&gControlLock, 0, memory_order_release); }

// 音のスレッドが slot の中に居ない状態にする。timeoutNs を過ぎたら 0 を返す（呼び手は解放を延ばす）。
static int quiesceRender(long long timeoutNs)
{
    atomic_fetch_add_explicit(&gHold, 1, memory_order_seq_cst);
    const uint_least32_t bounced = atomic_load_explicit(&gBounced, memory_order_seq_cst);
    const long long start = monotonicNanos();
    int ok = 1;
    while (atomic_load_explicit(&gInside, memory_order_seq_cst) &&
           atomic_load_explicit(&gBounced, memory_order_seq_cst) == bounced) {
        if (monotonicNanos() - start > timeoutNs) { ok = 0; break; }
        nap();
    }
    atomic_fetch_sub_explicit(&gHold, 1, memory_order_seq_cst);
    return ok;
}

static Storage *allocateStorage(void)
{
    // 置き場の f32 は Storage の後ろへ続けて取る（確保は 1 回。64 バイト境界）。
    const size_t head = (sizeof(Storage) + 63u) & ~(size_t)63u;
    const size_t bytes = head + (size_t)ET_STREAM_POOL_PAGES * ET_PAGE_FLOATS * sizeof(float);
    Storage *store = (Storage *)aligned_alloc(64, bytes);
    if (store == NULL) return NULL;
    memset(store, 0, head);
    float *pcm = (float *)((uint8_t *)store + head);
    for (uint32_t i = 0; i < ET_STREAM_POOL_PAGES; i++) {
        store->pages[i].pcm = pcm + (size_t)i * ET_PAGE_FLOATS;
        store->pages[i].index = i;
        store->pages[i].owner = store;
        atomic_init(&store->pageState[i], PAGE_FREE);
    }
    return store;
}

static void freeStorage(Storage *store) { free(store); }

// MARK: - 畳む

// slot を畳む。controlLock を持って呼ぶ。確保は、誰も触っていなければ返し、そうでなければ墓場へ延ばす。
static void retireSlot(Slot *s)
{
    if (atomic_load_explicit(&s->state, memory_order_relaxed) != SLOT_ACTIVE) return;
    atomic_store_explicit(&s->state, SLOT_RETIRED, memory_order_seq_cst);
    // 供給側の呼び出しが抜けるのを待つ。1 回は短いので 100 ms で十分。
    const long long start = monotonicNanos();
    int supplyIdle = 1;
    while (atomic_load_explicit(&s->sBusy, memory_order_seq_cst) != 0) {
        if (monotonicNanos() - start > 100000000LL) { supplyIdle = 0; break; }
        nap();
    }
    const int renderIdle = quiesceRender(100000000LL);
    Storage *store = s->store;
    s->store = NULL;
    atomic_store_explicit(&s->generation, 0, memory_order_relaxed);
    if (store != NULL) {
        if (supplyIdle && renderIdle && atomic_load_explicit(&store->filling, memory_order_acquire) == 0) {
            freeStorage(store);
        } else {
            int parked = 0;
            for (int i = 0; i < ET_GRAVEYARD && !parked; i++) {
                if (gGraveyard[i] == NULL) { gGraveyard[i] = store; parked = 1; }
            }
            // 墓場が満杯なら返さない（使われているかもしれない確保を返すより、漏らす）。
        }
    }
    atomic_store_explicit(&s->state, SLOT_FREE, memory_order_release);
}

// 延ばしてある解放を試す。controlLock を持って呼ぶ。まだ残っている数を返す。
static uint32_t reapLocked(void)
{
    uint32_t remaining = 0;
    int any = 0;
    for (int i = 0; i < ET_GRAVEYARD; i++) if (gGraveyard[i] != NULL) any = 1;
    if (!any) return 0;
    if (quiesceRender(10000000LL)) {
        for (int i = 0; i < ET_GRAVEYARD; i++) {
            Storage *store = gGraveyard[i];
            if (store != NULL && atomic_load_explicit(&store->filling, memory_order_acquire) == 0) {
                freeStorage(store);
                gGraveyard[i] = NULL;
            }
        }
    }
    for (int i = 0; i < ET_GRAVEYARD; i++) if (gGraveyard[i] != NULL) remaining++;
    return remaining;
}

uint32_t ETSampleStream_Reap(void)
{
    controlLock();
    const uint32_t remaining = reapLocked();
    controlUnlock();
    return remaining;
}

uint32_t ETSampleStream_Parked(void)
{
    controlLock();
    uint32_t n = 0;
    for (int i = 0; i < ET_GRAVEYARD; i++) if (gGraveyard[i] != NULL) n++;
    controlUnlock();
    return n;
}

uint64_t ETSampleStream_NextGeneration(void)
{
    controlLock();
    const uint64_t floor = gAttached > gIssued ? gAttached : gIssued;
    const uint64_t next = floor + 1u;
    gIssued = next;
    controlUnlock();
    return next;
}

void ETSampleStream_ResetGenerationsForTesting(void)
{
    controlLock();
    gAttached = 0;
    gIssued = 0;
    controlUnlock();
}

void ETSampleStream_SetEnabled(uint32_t engine, uint32_t instance, int enabled)
{
    for (int i = 0; i < ET_STREAM_MAX_SLOTS; i++) {
        Slot *s = &gSlots[i];
        if (atomic_load_explicit(&s->state, memory_order_acquire) == SLOT_ACTIVE &&
            s->engine == engine && s->instance == instance) {
            atomic_store_explicit(&s->enabled, enabled ? 1 : 0, memory_order_relaxed);
        }
    }
}

int ETSampleStream_Detach(uint32_t engine, uint32_t instance)
{
    controlLock();
    // 前に延ばした解放を、ここで拾う（供給が抜けていれば返せる）。
    reapLocked();
    int count = 0;
    for (int i = 0; i < ET_STREAM_MAX_SLOTS; i++) {
        Slot *s = &gSlots[i];
        if (atomic_load_explicit(&s->state, memory_order_relaxed) == SLOT_ACTIVE &&
            s->engine == engine && s->instance == instance) {
            retireSlot(s);
            count++;
        }
    }
    controlUnlock();
    return count;
}

void ETSampleStream_DetachAll(void)
{
    controlLock();
    reapLocked();
    for (int i = 0; i < ET_STREAM_MAX_SLOTS; i++) retireSlot(&gSlots[i]);
    controlUnlock();
}

int ETSampleStream_SlotFor(uint32_t engine, uint32_t instance)
{
    for (int i = 0; i < ET_STREAM_MAX_SLOTS; i++) {
        Slot *s = &gSlots[i];
        if (atomic_load_explicit(&s->state, memory_order_acquire) == SLOT_ACTIVE &&
            s->engine == engine && s->instance == instance) return i;
    }
    return -1;
}

// MARK: - Attach

static void resetSlotCounters(Slot *s)
{
    atomic_store_explicit(&s->taken, 0, memory_order_relaxed);
    atomic_store_explicit(&s->published, 0, memory_order_relaxed);
    atomic_store_explicit(&s->stale, 0, memory_order_relaxed);
    atomic_store_explicit(&s->rejected, 0, memory_order_relaxed);
    atomic_store_explicit(&s->publishErrors, 0, memory_order_relaxed);
    atomic_store_explicit(&s->abandoned, 0, memory_order_relaxed);
    atomic_store_explicit(&s->overflows, 0, memory_order_relaxed);
    atomic_store_explicit(&s->forecastRuns, 0, memory_order_relaxed);
    atomic_store_explicit(&s->forecastErrors, 0, memory_order_relaxed);
    atomic_store_explicit(&s->failedRequests, 0, memory_order_relaxed);
    atomic_store_explicit(&s->failed, 0, memory_order_relaxed);
    atomic_store_explicit(&s->maxPublish, 0, memory_order_relaxed);
    atomic_store_explicit(&s->fReady, 0, memory_order_relaxed);
    atomic_store_explicit(&s->fLimited, 0, memory_order_relaxed);
    atomic_store_explicit(&s->rScope, 0, memory_order_relaxed);
    atomic_store_explicit(&s->rPlanned, 0, memory_order_relaxed);
    atomic_store_explicit(&s->rPending, 0, memory_order_relaxed);
    atomic_store_explicit(&s->rAdmitted, 0, memory_order_relaxed);
    atomic_store_explicit(&s->rAhead, 0, memory_order_relaxed);
}

int32_t ETSampleStream_Attach(uint32_t engine, uint32_t instance, uint64_t generation,
                              double sampleRate, uint32_t flags, uint32_t *slotOut)
{
    if (engine == 0 || instance == 0 || generation == 0 || !(sampleRate >= 1000.0) ||
        !(sampleRate <= 768000.0 * 2.0)) {
        return ET_ERR_ARGS;
    }
    controlLock();
    // 世代は Attach をまたいでプロセス全体で増え続ける（ETSampleStream_NextGeneration）。供給の栅は (slot, 世代) だけを
    // 見るので、壊した instance の供給が残っていても、同じ世代で別の instance が同じ slot に付くことが無いように。
    if (generation <= gAttached) {
        controlUnlock();
        return ET_ERR_ARGS;
    }
    reapLocked();
    // 同じ instance が居れば、その slot を使い回す（バンクの読み直し）。
    Slot *existing = NULL;
    for (int i = 0; i < ET_STREAM_MAX_SLOTS; i++) {
        Slot *s = &gSlots[i];
        if (atomic_load_explicit(&s->state, memory_order_relaxed) == SLOT_ACTIVE &&
            s->engine == engine && s->instance == instance) {
            existing = s;
            break;
        }
    }
    Slot *target = existing;
    if (target == NULL) {
        for (int i = 0; i < ET_STREAM_MAX_SLOTS; i++) {
            if (atomic_load_explicit(&gSlots[i].state, memory_order_relaxed) == SLOT_FREE) {
                target = &gSlots[i];
                break;
            }
        }
    }
    if (target == NULL) {
        controlUnlock();
        return ET_ERR_STATE;
    }
    Storage *store = allocateStorage();
    if (store == NULL) {
        controlUnlock();
        return ET_ERR_OOM;
    }
    // configure は確保を伴い、PREPARING か ACTIVE の bank にだけ通る。
    // **断られたら、いまの slot は畳まずに残す**（読み直しの失敗で、動いている流しを止めない）。
    const et_status status = et_instance_stream_configure(engine, instance,
                                                          (uint32_t)(generation & 0xffffffffu),
                                                          (uint32_t)(generation >> 32u));
    if (status != ET_OK) {
        freeStorage(store);
        controlUnlock();
        return status;
    }
    if (existing != NULL) retireSlot(existing);
    gAttached = generation;
    Slot *s = target;
    resetSlotCounters(s);
    // 読み直しでは有効・無効を引き継ぐ。新しい slot は有効から始める（ETPipeline_Publish が次に合わせる）。
    if (existing == NULL) atomic_store_explicit(&s->enabled, 1, memory_order_relaxed);
    s->engine = engine;
    s->instance = instance;
    s->rate = sampleRate;
    s->flags = flags;
    s->store = store;
    memset(&s->fc, 0, sizeof s->fc);
    s->goalValid = 0;
    s->goalNativeGeneration = 0;
    s->limited = 0;
    s->nextForecast = 0;
    s->pollMark = 0;
    atomic_store_explicit(&s->generation, generation, memory_order_relaxed);
    atomic_store_explicit(&s->state, SLOT_ACTIVE, memory_order_release);
    if (slotOut != NULL) *slotOut = (uint32_t)(s - gSlots);
    controlUnlock();
    return ET_OK;
}

int32_t ETSampleStream_PublishDirect(uint32_t engine, uint32_t instance, uint64_t generation,
                                     uint32_t sample, uint64_t page, const float *pcm,
                                     uint32_t frames, uint32_t channels, int resident)
{
    if (engine == 0 || instance == 0 || generation == 0 || pcm == NULL || frames < 1 ||
        frames > ET_STREAM_PAGE_FRAMES || channels < 1 || channels > ET_STREAM_PAGE_MAX_CHANNELS) {
        return ET_ERR_ARGS;
    }
    return et_instance_stream_publish(engine, instance, (uint32_t)(generation & 0xffffffffu),
                                      (uint32_t)(generation >> 32u), sample,
                                      (uint32_t)(page & 0xffffffffu), (uint32_t)(page >> 32u), pcm,
                                      frames, channels, resident ? 1u : 0u);
}

int ETSampleStream_Snapshot(uint32_t slot, ETStreamStatus *out)
{
    if (out == NULL) return 0;
    memset(out, 0, sizeof *out);
    if (slot >= ET_STREAM_MAX_SLOTS) return 0;
    Slot *s = &gSlots[slot];
    if (atomic_load_explicit(&s->state, memory_order_acquire) != SLOT_ACTIVE) return 0;
    out->generation = atomic_load_explicit(&s->generation, memory_order_relaxed);
    out->requestsTaken = atomic_load_explicit(&s->taken, memory_order_relaxed);
    out->pagesPublished = atomic_load_explicit(&s->published, memory_order_relaxed);
    const uint64_t stale = atomic_load_explicit(&s->stale, memory_order_relaxed);
    out->pagesStale = stale + atomic_load_explicit(&s->rejected, memory_order_relaxed);
    out->publishErrors = atomic_load_explicit(&s->publishErrors, memory_order_relaxed);
    out->requestsAbandoned = atomic_load_explicit(&s->abandoned, memory_order_relaxed);
    out->requestOverflows = atomic_load_explicit(&s->overflows, memory_order_relaxed);
    out->requestsFailed = atomic_load_explicit(&s->failedRequests, memory_order_relaxed);
    out->failed = atomic_load_explicit(&s->failed, memory_order_relaxed);
    out->forecastRuns = atomic_load_explicit(&s->forecastRuns, memory_order_relaxed);
    out->forecastErrors = atomic_load_explicit(&s->forecastErrors, memory_order_relaxed);
    out->maxPublishPerBlock = atomic_load_explicit(&s->maxPublish, memory_order_relaxed);
    out->forecastReady = atomic_load_explicit(&s->fReady, memory_order_relaxed);
    out->forecastLimited = atomic_load_explicit(&s->fLimited, memory_order_relaxed);
    out->readinessScope = atomic_load_explicit(&s->rScope, memory_order_relaxed);
    out->readinessPlanned = atomic_load_explicit(&s->rPlanned, memory_order_relaxed);
    out->readinessPending = atomic_load_explicit(&s->rPending, memory_order_relaxed);
    out->readinessAdmitted = atomic_load_explicit(&s->rAdmitted, memory_order_relaxed);
    out->readinessReadyAhead = atomic_load_explicit(&s->rAhead, memory_order_relaxed);
    // 受け取った要求のうち片付いたもの。供給側が世代違いで断ったページ（rejected）は、前の Attach の要求なので数えない。
    const uint64_t closed = out->pagesPublished + stale + out->publishErrors + out->requestsAbandoned;
    out->outstanding = out->requestsTaken > closed ? (uint32_t)(out->requestsTaken - closed) : 0u;
    return 1;
}

// MARK: - 音のスレッド: 描画の前

// 要求を 1 つ「片付いた」と数える材料。publish を試みた数 + 断念した数。
static uint64_t settledCount(const Slot *s)
{
    return atomic_load_explicit(&s->published, memory_order_relaxed) +
           atomic_load_explicit(&s->stale, memory_order_relaxed) +
           atomic_load_explicit(&s->publishErrors, memory_order_relaxed) +
           atomic_load_explicit(&s->abandoned, memory_order_relaxed);
}

static uint32_t pumpSlot(Slot *s, uint32_t budget)
{
    Storage *st = s->store;
    uint32_t done = 0;
    while (done < budget) {
        const uint32_t tail = atomic_load_explicit(&st->readyTail, memory_order_relaxed);
        if (tail == atomic_load_explicit(&st->readyHead, memory_order_acquire)) break;
        const uint32_t index = st->ready[tail & ET_POOL_MASK];
        ETStreamPage *page = &st->pages[index];
        const uint64_t generation = atomic_load_explicit(&s->generation, memory_order_relaxed);
        if (page->generation != generation) {
            // 世代が違うページは engine へ渡さない（Attach をまたいだ取り残し）。
            atomic_fetch_add_explicit(&s->stale, 1, memory_order_relaxed);
        } else {
            const et_status status = et_instance_stream_publish(
                s->engine, s->instance, (uint32_t)(generation & 0xffffffffu),
                (uint32_t)(generation >> 32u), page->sample, (uint32_t)(page->page & 0xffffffffu),
                (uint32_t)(page->page >> 32u), page->pcm, page->frames, page->channels,
                page->flags & 1u);
            if (status == ET_OK) atomic_fetch_add_explicit(&s->published, 1, memory_order_relaxed);
            else if (status == ET_ERR_STATE) atomic_fetch_add_explicit(&s->stale, 1, memory_order_relaxed);
            else atomic_fetch_add_explicit(&s->publishErrors, 1, memory_order_relaxed);
        }
        // 輪から外してから置き場へ返す（供給は FREE になったページだけを借りる）。
        atomic_store_explicit(&st->readyTail, tail + 1u, memory_order_release);
        atomic_store_explicit(&st->pageState[index], PAGE_FREE, memory_order_release);
        done++;
    }
    return done;
}

void ETSampleStream_BeforeProcess(void)
{
    if (!renderEnter()) return;
    uint32_t budget = ET_STREAM_PUBLISH_PER_BLOCK;
    const unsigned start = gRoundRobin++;
    for (unsigned k = 0; k < ET_STREAM_MAX_SLOTS && budget > 0; k++) {
        Slot *s = &gSlots[(start + k) % ET_STREAM_MAX_SLOTS];
        if (atomic_load_explicit(&s->state, memory_order_acquire) != SLOT_ACTIVE) continue;
        const uint32_t before = ET_STREAM_PUBLISH_PER_BLOCK - budget;
        const uint32_t done = pumpSlot(s, budget);
        budget -= done;
        const uint32_t total = before + done;
        if (total > atomic_load_explicit(&s->maxPublish, memory_order_relaxed))
            atomic_store_explicit(&s->maxPublish, total, memory_order_relaxed);
    }
    renderLeave();
}

// MARK: - 音のスレッド: 描画の後

// 要求を engine から受け取って輪へ積む。積んだ件数を返す。
static uint32_t takeRequests(Slot *s)
{
    Storage *st = s->store;
    const uint32_t head = atomic_load_explicit(&st->reqHead, memory_order_relaxed);
    const uint32_t tail = atomic_load_explicit(&st->reqTail, memory_order_acquire);
    const uint32_t space = (uint32_t)ET_STREAM_REQUEST_RING - (head - tail);
    if (space == 0) return 0;
    et_sfz_sample_request chunk[ET_STREAM_TAKE_CHUNK];
    const uint32_t capacity = space < ET_STREAM_TAKE_CHUNK ? space : ET_STREAM_TAKE_CHUNK;
    uint32_t count = 0;
    const et_status status = et_instance_stream_take_requests(s->engine, s->instance, chunk, capacity, &count);
    if (status == ET_ERR_OOM) {
        // engine の溜め場が溢れている。これ以上は取れないので数えておく（engine 側が failRuntime する）。
        atomic_fetch_add_explicit(&s->overflows, 1, memory_order_relaxed);
        return 0;
    }
    if (status != ET_OK || count == 0 || count > capacity) return 0;
    for (uint32_t i = 0; i < count; i++) {
        ETStreamRequest *r = &st->requests[(head + i) & ET_RING_MASK];
        r->generation = (uint64_t)chunk[i].generation_low | (uint64_t)chunk[i].generation_high << 32u;
        r->page = (uint64_t)chunk[i].page_low | (uint64_t)chunk[i].page_high << 32u;
        r->sample = chunk[i].sample;
        r->reserved = 0;
    }
    atomic_store_explicit(&st->reqHead, head + count, memory_order_release);
    atomic_fetch_add_explicit(&s->taken, count, memory_order_relaxed);
    return count;
}

static uint32_t ceilFrames(double rate, double seconds)
{
    const double v = rate * seconds;
    const uint32_t whole = (uint32_t)v;
    return (double)whole < v ? whole + 1u : whole;
}

// SELECTED_PRESETS の先読み（上流の advanceSfzSampleForecast、Note Player の枝。
// 既知の MIDI 列は持たないので events は常に空・scope は 2）。
static void forecastPublishReadiness(Slot *s, const et_stream_readiness *r)
{
    atomic_store_explicit(&s->rScope, r->scope, memory_order_relaxed);
    atomic_store_explicit(&s->rPlanned, r->planned_pages, memory_order_relaxed);
    atomic_store_explicit(&s->rPending, r->pending_pages, memory_order_relaxed);
    atomic_store_explicit(&s->rAdmitted, r->admitted_frames, memory_order_relaxed);
    atomic_store_explicit(&s->rAhead, r->ready_ahead_frames, memory_order_relaxed);
}

static int readReadiness(Slot *s, et_stream_readiness *r)
{
    if (et_instance_stream_readiness(s->engine, s->instance, r) != ET_OK) return 0;
    // 上流の instanceStreamReadiness と同じ検査。
    if (r->scope > 3u || r->ready_ahead_frames > r->admitted_frames || r->pending_pages > r->planned_pages) return 0;
    forecastPublishReadiness(s, r);
    return 1;
}

static void forecastFail(Slot *s)
{
    atomic_fetch_add_explicit(&s->forecastErrors, 1, memory_order_relaxed);
    s->fc.valid = 0;
    // 失敗を毎ブロック繰り返さない。0.5 s 空けて組み直す。
    s->nextForecast = gClock + ceilFrames(s->rate, 0.5);
}

static void forecastPressure(Slot *s)
{
    Forecast *f = &s->fc;
    const uint32_t windows[3] = { ceilFrames(s->rate, 1.5), ceilFrames(s->rate, 1.0), ceilFrames(s->rate, 0.25) };
    if (++f->windowIndex < 3u) {
        f->windowFrames = windows[f->windowIndex];
        f->reset = 1;
    } else {
        s->limited = 1;
        atomic_store_explicit(&s->fLimited, 1, memory_order_relaxed);
        f->pressure = 1;
        f->retryFrame = gClock + ceilFrames(s->rate, 0.5);
    }
}

// result が -2（ET_ERR_STATE）のとき、予測が古くなっただけか（捨てて組み直す）、本当の失敗かを分ける。
// 古いだけなら 1 を返す。
static int forecastStale(Slot *s, et_status result, uint32_t nativeGeneration)
{
    if (result != ET_ERR_STATE) return 0;
    et_stream_readiness r;
    if (!readReadiness(s, &r)) return 0;
    if (r.scope != ET_STREAM_SCOPE_NONE &&
        et_instance_midi_generation(s->engine, s->instance) == nativeGeneration) {
        return 0;
    }
    s->fc.valid = 0;
    return 1;
}

static void forecastCommit(Slot *s)
{
    Forecast *f = &s->fc;
    const et_status result = et_instance_stream_prefetch(
        s->engine, s->instance, NULL, 0, f->nativeGeneration, f->windowFrames,
        ET_STREAM_FORECAST_COMMIT | ET_STREAM_FORECAST_ADMIT);
    if (result == ET_ERR_OOM) { forecastPressure(s); return; }
    // ET_NEED_SAMPLE は「ページの到着待ち」。予測は残し、次の機会にもう一度 commit する。
    if (result == ET_NEED_SAMPLE || forecastStale(s, result, f->nativeGeneration)) return;
    if (result != ET_OK) { forecastFail(s); return; }
    et_stream_readiness r;
    if (!readReadiness(s, &r)) { forecastFail(s); return; }
    f->nativeScope = r.scope;
    f->ready = r.scope != ET_STREAM_SCOPE_NONE && r.pending_pages == 0 &&
               (r.scope != ET_STREAM_SCOPE_KNOWN_MIDI || r.ready_ahead_frames > 0);
    // 窓を縮めて通ったなら制限つき。最初の窓で揃ったら制限は解ける。
    if (f->windowIndex > 0) { s->limited = 1; }
    else if (f->ready) { s->limited = 0; }
    atomic_store_explicit(&s->fLimited, s->limited ? 1u : 0u, memory_order_relaxed);
    f->refreshFrame = gClock + ceilFrames(s->rate, 0.5);
    if (!f->ready) f->valid = 0;
    atomic_store_explicit(&s->fReady, f->ready ? 1u : 0u, memory_order_relaxed);
}

static void forecastAdvance(Slot *s)
{
    // 無効な node は先読みしない。供給が失敗した流しも、揃うのを待ち続けるだけなので回さない（読み直しを待つ）。
    if (atomic_load_explicit(&s->enabled, memory_order_relaxed) == 0 ||
        atomic_load_explicit(&s->failed, memory_order_relaxed) != 0) {
        return;
    }
    // PREPARING のあいだは prefetch が ET_ERR_STATE になるだけ。ACTIVE になってから回す。
    if ((et_instance_asset_state(s->engine, s->instance, 0) & 255u) != ET_ASSET_STATE_ACTIVE) return;
    atomic_fetch_add_explicit(&s->forecastRuns, 1, memory_order_relaxed);
    const uint32_t nativeGeneration = et_instance_midi_generation(s->engine, s->instance);
    et_stream_readiness snapshot;
    if (!readReadiness(s, &snapshot)) { forecastFail(s); return; }
    Forecast *f = &s->fc;
    const int changedGoal = !s->goalValid || s->goalNativeGeneration != nativeGeneration;
    if (changedGoal) {
        s->goalValid = 1;
        s->goalNativeGeneration = nativeGeneration;
        s->limited = 0;
        atomic_store_explicit(&s->fLimited, 0, memory_order_relaxed);
    }
    const int changed = changedGoal || !f->valid || (f->ready && snapshot.scope != f->nativeScope);
    int refill = 0;
    if (f->valid && f->ready) {
        refill = f->nativeScope == ET_STREAM_SCOPE_KNOWN_MIDI
            // 上流 0.18.0: 窓の半分が残っているうちに継ぎ足す（前は 0.5 秒）。
            ? snapshot.ready_ahead_frames <= (f->windowFrames + 1) / 2
            // 鳴っている声（ET_MIDI_STATE_VOICES|CALLBACKS|GENERATED）があるあいだだけ更新する。
            : (et_instance_midi_state(s->engine, s->instance) & 7u) != 0 && gClock >= f->refreshFrame;
    }
    if (changed || refill || (f->valid && f->pressure && gClock >= f->retryFrame)) {
        memset(f, 0, sizeof *f);
        f->valid = 1;
        f->nativeGeneration = nativeGeneration;
        f->windowFrames = ceilFrames(s->rate, 1.5);
        f->reset = 1;
        atomic_store_explicit(&s->fReady, 0, memory_order_relaxed);
    }
    if (f->ready || f->pressure) return;
    if (!f->reset) { forecastCommit(s); return; }
    const uint32_t flags = ET_STREAM_FORECAST_BEGIN | ET_STREAM_FORECAST_ADMIT | ET_STREAM_FORECAST_SELECTED_PRESETS;
    const et_status result = et_instance_stream_prefetch(s->engine, s->instance, NULL, 0, nativeGeneration,
                                                         f->windowFrames, flags);
    if (result == ET_ERR_OOM) { forecastPressure(s); return; }
    if (forecastStale(s, result, nativeGeneration)) return;
    if (result != ET_OK) { forecastFail(s); return; }
    f->reset = 0;
    forecastCommit(s);
}

void ETSampleStream_AfterProcess(uint32_t frames)
{
    if (!renderEnter()) return;
    gClock += frames;
    for (unsigned i = 0; i < ET_STREAM_MAX_SLOTS; i++) {
        Slot *s = &gSlots[i];
        if (atomic_load_explicit(&s->state, memory_order_acquire) != SLOT_ACTIVE) continue;
        takeRequests(s);
        if ((s->flags & ET_STREAM_ATTACH_FORECAST) && gClock >= s->nextForecast) {
            // 上流は前回の poll で渡した要求を全部返し終えてから次の poll をし、poll のたびに予測を進める。
            // **0.18.0 から、その poll で新しい要求が出ていても進める**（読みが遅いと列が空にならず、予測が
            // 止まったまま全部の声が 1 ページずつの読みになるため）。ここでは要求を毎ブロック取り出すので、
            // 「前回の poll で渡した分」を前回の予測までに取り出した数（pollMark）で数える。
            // 要求していないページ（作り直しの再送など）で settled が先へ出ても、比べるだけなので回り込まない。
            if (settledCount(s) >= s->pollMark) {
                s->nextForecast = gClock + ceilFrames(s->rate, 0.01);
                forecastAdvance(s);
                takeRequests(s);
                s->pollMark = atomic_load_explicit(&s->taken, memory_order_relaxed);
            }
        }
    }
    renderLeave();
}

// MARK: - 供給

// 供給側の呼び出しの入口。slot がこの世代で生きていれば 1 を返し、出口で supplyExit を呼ぶ。
static Slot *supplyEnter(uint32_t slot, uint64_t generation)
{
    if (slot >= ET_STREAM_MAX_SLOTS) return NULL;
    Slot *s = &gSlots[slot];
    atomic_fetch_add_explicit(&s->sBusy, 1, memory_order_seq_cst);
    if (atomic_load_explicit(&s->state, memory_order_seq_cst) == SLOT_ACTIVE &&
        atomic_load_explicit(&s->generation, memory_order_relaxed) == generation) {
        return s;
    }
    atomic_fetch_sub_explicit(&s->sBusy, 1, memory_order_seq_cst);
    return NULL;
}

static void supplyExit(Slot *s) { atomic_fetch_sub_explicit(&s->sBusy, 1, memory_order_seq_cst); }

int ETSampleStream_IsCurrent(uint32_t slot, uint64_t generation)
{
    Slot *s = supplyEnter(slot, generation);
    if (s == NULL) return 0;
    supplyExit(s);
    return 1;
}

uint32_t ETSampleStream_TakeRequests(uint32_t slot, uint64_t generation,
                                     ETStreamRequest *out, uint32_t capacity)
{
    if (out == NULL || capacity == 0) return 0;
    Slot *s = supplyEnter(slot, generation);
    if (s == NULL) return 0;
    Storage *st = s->store;
    const uint32_t tail = atomic_load_explicit(&st->reqTail, memory_order_relaxed);
    const uint32_t head = atomic_load_explicit(&st->reqHead, memory_order_acquire);
    uint32_t n = head - tail;
    if (n > capacity) n = capacity;
    for (uint32_t i = 0; i < n; i++) out[i] = st->requests[(tail + i) & ET_RING_MASK];
    atomic_store_explicit(&st->reqTail, tail + n, memory_order_release);
    supplyExit(s);
    return n;
}

ETStreamPage *ETSampleStream_AcquirePage(uint32_t slot, uint64_t generation)
{
    Slot *s = supplyEnter(slot, generation);
    if (s == NULL) return NULL;
    Storage *st = s->store;
    ETStreamPage *found = NULL;
    for (uint32_t i = 0; i < ET_STREAM_POOL_PAGES; i++) {
        int expected = PAGE_FREE;
        if (atomic_load_explicit(&st->pageState[i], memory_order_acquire) == PAGE_FREE &&
            atomic_compare_exchange_strong_explicit(&st->pageState[i], &expected, PAGE_FILLING,
                                                    memory_order_acq_rel, memory_order_relaxed)) {
            atomic_fetch_add_explicit(&st->filling, 1, memory_order_acq_rel);
            found = &st->pages[i];
            found->slot = slot;
            found->generation = generation;
            found->frames = 0;
            found->channels = 0;
            found->flags = 0;
            break;
        }
    }
    supplyExit(s);
    return found;
}

void ETSampleStream_ReleasePage(ETStreamPage *page)
{
    if (page == NULL) return;
    Storage *st = (Storage *)page->owner;
    atomic_store_explicit(&st->pageState[page->index], PAGE_FREE, memory_order_release);
    // これが最後の触り。0 になれば畳む側が確保を返せる。
    atomic_fetch_sub_explicit(&st->filling, 1, memory_order_acq_rel);
}

int ETSampleStream_SubmitPage(ETStreamPage *page, const ETStreamRequest *request,
                              uint32_t frames, uint32_t channels)
{
    if (page == NULL) return 0;
    Storage *st = (Storage *)page->owner;
    const uint32_t slotIndex = page->slot;
    Slot *s = slotIndex < ET_STREAM_MAX_SLOTS ? &gSlots[slotIndex] : NULL;
    int accepted = 0;
    if (s != NULL && request != NULL && frames >= 1 && frames <= ET_STREAM_PAGE_FRAMES &&
        channels >= 1 && channels <= ET_STREAM_PAGE_MAX_CHANNELS) {
        atomic_fetch_add_explicit(&s->sBusy, 1, memory_order_seq_cst);
        // 世代の栅。借りたときの世代・要求の世代・いまの slot の世代が揃っていて、slot が同じ置き場を持つこと。
        const int current = atomic_load_explicit(&s->state, memory_order_seq_cst) == SLOT_ACTIVE &&
                            s->store == st &&
                            atomic_load_explicit(&s->generation, memory_order_relaxed) == page->generation;
        if (current && request->generation == page->generation) {
            page->page = request->page;
            page->sample = request->sample;
            page->frames = frames;
            page->channels = channels;
            const uint32_t head = atomic_load_explicit(&st->readyHead, memory_order_relaxed);
            st->ready[head & ET_POOL_MASK] = (uint16_t)page->index;
            atomic_store_explicit(&st->pageState[page->index], PAGE_READY, memory_order_release);
            atomic_store_explicit(&st->readyHead, head + 1u, memory_order_release);
            accepted = 1;
        } else if (current) {
            atomic_fetch_add_explicit(&s->rejected, 1, memory_order_relaxed);
        }
        atomic_fetch_sub_explicit(&s->sBusy, 1, memory_order_seq_cst);
    }
    if (accepted) {
        // 渡した。借りは終わり（ページは READY で、音のスレッドが FREE へ戻す）。
        atomic_fetch_sub_explicit(&st->filling, 1, memory_order_acq_rel);
        return 1;
    }
    ETSampleStream_ReleasePage(page);
    return 0;
}

void ETSampleStream_Abandon(uint32_t slot, uint64_t generation, uint32_t count)
{
    Slot *s = supplyEnter(slot, generation);
    if (s == NULL) return;
    atomic_fetch_add_explicit(&s->abandoned, count, memory_order_relaxed);
    supplyExit(s);
}

void ETSampleStream_Fail(uint32_t slot, uint64_t generation, uint32_t reason, uint32_t count)
{
    Slot *s = supplyEnter(slot, generation);
    if (s == NULL) return;
    if (reason == 0) reason = ET_STREAM_FAIL_READ;
    uint32_t none = 0;
    // 最初の理由だけを残す。
    atomic_compare_exchange_strong_explicit(&s->failed, &none, reason, memory_order_relaxed, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->failedRequests, count, memory_order_relaxed);
    // 要求は片付いた（outstanding に残さない）数に入れる。
    atomic_fetch_add_explicit(&s->abandoned, count, memory_order_relaxed);
    supplyExit(s);
}
