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
// The descriptor is published by the control thread and read by the render
// thread. Its context is owned by the adapter; replacement must be coordinated
// by the caller after the render thread has stopped using the old context.
static ETExternalProcessor gExternal[ET_EXTERNAL_MAX_PROCESSORS];
static uint32_t gExternalCount = 0;
static ETExternalProcessor gPreExternal[ET_EXTERNAL_MAX_PROCESSORS];
static uint32_t gPreExternalCount = 0;
static _Atomic int gExternalEnabled = 0;
static _Atomic uint64_t gExternalRateBits = 0;
static double bitsDouble(uint64_t bits);

typedef int32_t (*ETPipelineExternalCallback)(void *, uint32_t, float *, uint32_t,
                                              uint32_t, double, int8_t);
#if defined(__clang__) || defined(__GNUC__)
extern void et_pipeline_set_external_callback(uint32_t, ETPipelineExternalCallback, void *)
    __attribute__((weak_import));
#else
extern void et_pipeline_set_external_callback(uint32_t, ETPipelineExternalCallback, void *);
#endif

static int32_t pipelineExternalCallback(void *context, uint32_t index, float *audio,
                                        uint32_t channels, uint32_t frames, double timeSeconds,
                                        int8_t channelSpec)
{
    (void)context;
    (void)channelSpec;
    if (index >= gExternalCount) return ET_ERR_ARGS;
    const int32_t status = ETExternalProcessor_Process(&gExternal[index], audio, channels,
                                                       frames, bitsDouble(atomic_load_explicit(
                                                           &gExternalRateBits, memory_order_relaxed)),
                                                       timeSeconds);
    return status;
}

static uint64_t doubleBits(double value)
{
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static double bitsDouble(uint64_t bits)
{
    double value = 0.0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

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
    if (et_pipeline_set_external_callback != NULL) {
        et_pipeline_set_external_callback(engine, pipelineExternalCallback, NULL);
    }
}

void ETPipeline_SetExternalProcessor(const ETExternalProcessor *processor)
{
    if (processor == NULL || processor->process == NULL) {
        ETPipeline_ClearExternalProcessor();
        return;
    }
    ETPipeline_SetExternalProcessors(processor, 1);
}

void ETPipeline_SetExternalProcessors(const ETExternalProcessor *processors,
                                      uint32_t count)
{
    if (processors == NULL || count == 0) {
        ETPipeline_ClearExternalProcessor();
        return;
    }
    if (count > ET_EXTERNAL_MAX_PROCESSORS) count = ET_EXTERNAL_MAX_PROCESSORS;
    for (uint32_t i = 0; i < count; ++i) gExternal[i] = processors[i];
    gExternalCount = count;
    atomic_store_explicit(&gExternalEnabled, 1, memory_order_release);
}

void ETPipeline_SetPreExternalProcessors(const ETExternalProcessor *processors,
                                         uint32_t count)
{
    if (processors == NULL || count == 0) {
        gPreExternalCount = 0;
        return;
    }
    if (count > ET_EXTERNAL_MAX_PROCESSORS) count = ET_EXTERNAL_MAX_PROCESSORS;
    for (uint32_t i = 0; i < count; ++i) gPreExternal[i] = processors[i];
    gPreExternalCount = count;
}

void ETPipeline_ClearExternalProcessor(void)
{
    atomic_store_explicit(&gExternalEnabled, 0, memory_order_release);
    gExternalCount = 0;
    for (uint32_t i = 0; i < ET_EXTERNAL_MAX_PROCESSORS; ++i)
        ETExternalProcessor_Clear(&gExternal[i]);
    gPreExternalCount = 0;
    for (uint32_t i = 0; i < ET_EXTERNAL_MAX_PROCESSORS; ++i)
        ETExternalProcessor_Clear(&gPreExternal[i]);
}

void ETPipeline_SetExternalSampleRate(double sampleRate)
{
    atomic_store_explicit(&gExternalRateBits, doubleBits(sampleRate), memory_order_relaxed);
}

uint32_t ETPipeline_ExternalLatency(void)
{
    if (!atomic_load_explicit(&gExternalEnabled, memory_order_acquire)) return 0;
    uint32_t total = 0;
    for (uint32_t i = 0; i < gPreExternalCount; ++i)
        total += ETExternalProcessor_Latency(&gPreExternal[i]);
    for (uint32_t i = 0; i < gExternalCount; ++i)
        total += ETExternalProcessor_Latency(&gExternal[i]);
    return total;
}

double ETPipeline_ExternalTailTime(void)
{
    if (!atomic_load_explicit(&gExternalEnabled, memory_order_acquire)) return 0.0;
    double tail = 0.0;
    for (uint32_t i = 0; i < gPreExternalCount; ++i) {
        const double value = ETExternalProcessor_TailTime(&gPreExternal[i]);
        if (value > tail) tail = value;
    }
    for (uint32_t i = 0; i < gExternalCount; ++i) {
        const double value = ETExternalProcessor_TailTime(&gExternal[i]);
        if (value > tail) tail = value;
    }
    return tail;
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
        rec[9] = nodes[i].kind == ET_PIPE_NODE_EXTERNAL ? 1u : 0u;
        rec[10] = nodes[i].kind == ET_PIPE_NODE_EXTERNAL ? nodes[i].externalIndex : 0u;
        // rec[11] は詰め物。
    }
    d->length = ET_PIPE_HEADER + count * ET_PIPE_NODE;
    for (uint32_t i = 0; i < count; i++) {
        if (nodes[i].enabled == 1 && nodes[i].sectionGate) d->active++;
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
    // **その場で engine に聞く。**
    // 組み直したときの値を覚えているだけだと、パラメータで遅延が変わる
    // エフェクト（IR Reverb の Latency / Conv Rate、FIR 系の Taps など）を
    // 触っても帯の数字が動かない。資産を送ったときも同じ。
    // 読むだけの呼び出しで、音のスレッドは通らない。
    const uint32_t engine = atomic_load_explicit(&gEngine, memory_order_relaxed);
    if (engine != 0 && atomic_load_explicit(&gConfigured, memory_order_relaxed)) {
        return (uint32_t)et_pipeline_latency(engine) + ETPipeline_ExternalLatency();
    }
    return (uint32_t)atomic_load_explicit(&gLatency, memory_order_relaxed)
         + ETPipeline_ExternalLatency();
}

int ETPipeline_IsBypassed(void)
{
    return atomic_load_explicit(&gBypass, memory_order_relaxed);
}

int ETPipeline_HasConfigured(void)
{
    return atomic_load_explicit(&gConfigured, memory_order_relaxed);
}

void ETPipeline_ApplyPending(void)
{
    const uint32_t engine = atomic_load_explicit(&gEngine, memory_order_relaxed);
    if (engine == 0) return;

    // 溜まっている差し替えを反映する。
    // configure は確保を伴うが、鎖を変えたときだけなので毎ブロックでは起きない。
    // 音のスレッドから呼ぶ。処理と同じスレッドに寄せて競合を無くすため。
    //
    // **ETPipeline_Process から切り出してある。**
    // 以前はこの中身が Process の先頭に埋まっていて、その Process は
    // AudioIO のレンダーブロックが `if awake` の内側でしか呼ばない。
    // PowerGate が無音で休んでいる間は Process ごと飛ぶので、
    // **無音の間に鎖を変えると descriptor が gPending に積まれたまま消費されない。**
    // エフェクトを足しても、鎖を戻しても、プリセットを読んでも、
    // グラフは古いままで、音が戻るまで何も効かない。
    // 反映は処理と別なので、休んでいても必ず通す。
    int pending = atomic_exchange_explicit(&gPending, -1, memory_order_acquire);
    if (pending < 0) return;

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

int32_t ETPipeline_Process(uint32_t channels, uint32_t frames, double timeSeconds)
{
    atomic_fetch_add_explicit(&gCount, 1, memory_order_relaxed);

    const uint32_t engine = atomic_load_explicit(&gEngine, memory_order_relaxed);
    if (engine == 0 || channels == 0 || frames == 0) return ET_ERR_ARGS;

    ETPipeline_ApplyPending();

    if (!atomic_load_explicit(&gConfigured, memory_order_relaxed)) return ET_ERR_STATE;

    const uint32_t bypass = atomic_load_explicit(&gBypass, memory_order_relaxed) ? 1u : 0u;
    // process のエラーは gStatus に入れない。入れると configure の結果を潰してしまい、
    // 「組めなかった」のか「組めたが処理に失敗した」のか読めなくなる。戻り値で返す。
    float *bus = et_arena_combined_ptr(engine);
    const double sampleRate = bitsDouble(atomic_load_explicit(&gExternalRateBits,
                                                               memory_order_relaxed));
    for (uint32_t i = 0; i < gPreExternalCount; ++i) {
        const int32_t externalStatus = ETExternalProcessor_Process(
            &gPreExternal[i], bus, channels, frames, sampleRate, timeSeconds);
        if (externalStatus != 0) return externalStatus;
    }
    const int32_t status = (int32_t)et_pipeline_process(engine, channels, frames,
                                                         timeSeconds, bypass);
    if (status != ET_OK) return status;
    if (atomic_load_explicit(&gExternalEnabled, memory_order_acquire)) {
        for (uint32_t i = 0; i < gExternalCount; ++i) {
            const int32_t externalStatus = ETExternalProcessor_Process(
                &gExternal[i], bus, channels, frames, sampleRate, timeSeconds);
            if (externalStatus != 0) return externalStatus;
        }
    }
    return status;
}
