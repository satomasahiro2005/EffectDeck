//  pipeline_engine.c
//  ETPipeline.c と ETExternalProcessor.c を、本物の EffeTune engine につないだ試験。
//  engine は HEAD が指している Vendor/effetune に Patches/ の 4 本を当てて建てる
//  （-DET_NATIVE_WITH_ENGINE=ON。CMakeLists.txt が展開と当て込みをする）。
//
//  外部ノードを足す 3 本のパッチが、上流を上げたあとも効いているかを機械で見る唯一の場所。
//  各件は engine を作り直すので、1 件ずつでも全件まとめてでも同じに走る。

#include "ETPipeline.h"
#include "effetune/abi.h"
#include "et_test.h"

#include <math.h>

enum { FR = 64 };

typedef struct {
    float add;
    uint32_t latency;
    uint32_t calls, lastChannels;
} Ext;

static int32_t extProcess(void *c, float *p, uint32_t ch, uint32_t fr, double rate, double t)
{
    (void)rate;
    (void)t;
    Ext *e = (Ext *)c;
    e->calls++;
    e->lastChannels = ch;
    for (uint32_t i = 0; i < ch * fr; i++) p[i] += e->add;
    return 0;
}
static uint32_t extLatency(void *c) { return ((Ext *)c)->latency; }

static int near(float a, float b) { return fabsf(a - b) < 1e-6f; }

typedef struct {
    et_engine engine;
    et_instance inv;
    float *bus;
    Ext x0;
    ETPipeNode extAll, invAll;
} Rig;

static void setup(Rig *g)
{
    memset(g, 0, sizeof *g);
    g->engine = et_engine_create();
    ET_CHECK(g->engine != 0);
    ET_CHECK(et_engine_prepare(g->engine, 48000.0f, 4, 256, 0) == ET_OK);
    ETPipeline_SetEngine(g->engine);
    ETPipeline_SetExternalSampleRate(48000.0);
    g->bus = ETPipeline_MainBus();
    ET_CHECK(g->bus != NULL);
    g->inv = et_instance_create(g->engine, "PolarityInversionPlugin");
    ET_CHECK(g->inv != 0);
    g->x0.add = 1.0f;
    ETExternalProcessor p0;
    memset(&p0, 0, sizeof p0);
    p0.context = &g->x0;
    p0.process = extProcess;
    p0.latency = extLatency;
    ETPipeline_SetExternalProcessorAt(0, &p0);
    const ETPipeNode ext = {.enabled = 1, .sectionGate = 1, .channelSpec = ET_CHANNEL_ALL,
                            .kind = ET_PIPE_NODE_EXTERNAL, .externalIndex = 0};
    const ETPipeNode inv = {.instance = g->inv, .enabled = 1, .sectionGate = 1,
                            .channelSpec = ET_CHANNEL_ALL};
    g->extAll = ext;
    g->invAll = inv;
}

static void teardown(Rig *g)
{
    ETPipeline_ClearExternalProcessor();
    ETPipeline_SetEngine(0);
    et_engine_destroy(g->engine);
}

static void fill(Rig *g, uint32_t ch, float v)
{
    for (uint32_t i = 0; i < ch * FR; i++) g->bus[i] = v;
}

static void publish(const ETPipeNode *n, uint32_t count)
{
    ETPipeline_Publish(n, count);
    ETPipeline_ApplyPending();
    ET_CHECK(ETPipeline_LastStatus() == ET_OK);
}

ET_CASE(external_runs_at_position)
{
    Rig g;
    setup(&g);
    const ETPipeNode ab[2] = {g.extAll, g.invAll};
    publish(ab, 2);
    fill(&g, 2, 0.25f);
    ET_CHECK(ETPipeline_Process(2, FR, 0) == ET_OK);
    ET_CHECK_MSG(near(g.bus[0], -1.25f) && near(g.bus[2 * FR - 1], -1.25f),
                 "[ext,inv] gave %.3f", g.bus[0]);
    const ETPipeNode ba[2] = {g.invAll, g.extAll};
    publish(ba, 2);
    fill(&g, 2, 0.25f);
    ET_CHECK(ETPipeline_Process(2, FR, 0) == ET_OK);
    ET_CHECK_MSG(near(g.bus[0], 0.75f), "[inv,ext] gave %.3f", g.bus[0]);
    // 1 ブロックに 1 回だけ（旧来の後段処理が重ねて走らない）。
    ET_CHECK(g.x0.calls == 2 && g.x0.lastChannels == 2);
    teardown(&g);
}

ET_CASE(channel_pair_17)
{
    Rig g;
    setup(&g);
    ETPipeNode pair = g.extAll;
    pair.channelSpec = 17;   // 対 (2,3)
    publish(&pair, 1);
    fill(&g, 4, 0.0f);
    ET_CHECK(ETPipeline_Process(4, FR, 0) == ET_OK);
    ET_CHECK(g.bus[0] == 0 && g.bus[FR] == 0 && g.bus[2 * FR] == 1 && g.bus[3 * FR] == 1);
    ET_CHECK(g.x0.lastChannels == 2);
    // チャンネル数を超える対は engine が飛ばす（失敗にはしない）。
    ETPipeNode far = g.extAll;
    far.channelSpec = 19;    // 対 (6,7)
    publish(&far, 1);
    fill(&g, 4, 0.0f);
    ET_CHECK(ETPipeline_Process(4, FR, 0) == ET_OK);
    ET_CHECK(g.bus[0] == 0 && g.x0.calls == 1);
    teardown(&g);
}

ET_CASE(parallel_bus_sum)
{
    Rig g;
    setup(&g);
    ETPipeNode wet = g.extAll;
    wet.inputBus = 0;
    wet.outputBus = 1;
    ETPipeNode back = g.invAll;
    back.inputBus = 1;
    back.outputBus = 0;
    const ETPipeNode par[2] = {wet, back};
    publish(par, 2);
    fill(&g, 2, 0.25f);
    ET_CHECK(ETPipeline_Process(2, FR, 0) == ET_OK);
    ET_CHECK_MSG(near(g.bus[0], -1.0f), "0.25 - (0.25 + 1) gave %.3f", g.bus[0]);
    teardown(&g);
}

ET_CASE(external_latency_compensated_once)
{
    Rig g;
    setup(&g);
    g.x0.latency = 10;
    ETPipeNode wet = g.extAll;
    wet.inputBus = 0;
    wet.outputBus = 1;
    ETPipeNode back = g.invAll;
    back.inputBus = 1;
    back.outputBus = 0;
    const ETPipeNode par[2] = {wet, back};
    publish(par, 2);
    // engine が遅延補正に入れるので、こちらで足さない（2 回数えない）。
    ET_CHECK(et_pipeline_latency(g.engine) == 10);
    ET_CHECK(ETPipeline_Latency() == 10);
    ET_CHECK(ETPipeline_ExternalLatency() == 10);
    // 乾いた側のインパルスが報告どおり 10 サンプル遅れて出る。
    for (int blk = 0; blk < 2; blk++) {
        fill(&g, 2, 0.0f);
        if (blk == 1) g.bus[0] = 1.0f;
        ET_CHECK(ETPipeline_Process(2, FR, 0) == ET_OK);
    }
    // out[n] = dry[n-10] - (x[n] + 1)  →  out[0] = -2, out[10] = 0, ほかは -1
    ET_CHECK_MSG(near(g.bus[0], -2.0f) && near(g.bus[10], 0.0f) && near(g.bus[5], -1.0f),
                 "out[0]=%.2f out[5]=%.2f out[10]=%.2f", g.bus[0], g.bus[5], g.bus[10]);
    teardown(&g);
}

ET_CASE(empty_slot_is_bypass)
{
    Rig g;
    setup(&g);
    ETPipeline_ClearExternalProcessorAt(0);
    const ETPipeNode ab[2] = {g.extAll, g.invAll};
    publish(ab, 2);
    fill(&g, 2, 0.25f);
    ET_CHECK(ETPipeline_Process(2, FR, 0) == ET_OK);
    ET_CHECK(near(g.bus[0], -0.25f));
    teardown(&g);
}

ET_CASE(destroy_resets_status)
{
    Rig g;
    setup(&g);
    g.x0.latency = 10;
    const ETPipeNode ab[2] = {g.extAll, g.invAll};
    publish(ab, 2);
    ET_CHECK(ETPipeline_HasConfigured() == 1);
    ET_CHECK(ETPipeline_Latency() == 10 && et_pipeline_latency(g.engine) == 10);
    ET_CHECK(ETPipeline_DestroyInstances(g.engine, &g.inv, 1) == 1);
    // engine は鎖を無効にした。こちらの申告もそれに合う。
    ET_CHECK_MSG(ETPipeline_HasConfigured() == 0 && ETPipeline_LastStatus() == ET_ERR_STATE,
                 "HasConfigured()=%d LastStatus()=%d", ETPipeline_HasConfigured(),
                 ETPipeline_LastStatus());
    ET_CHECK(ETPipeline_ActiveNodes() == 0);
    ET_CHECK_MSG(ETPipeline_Latency() == et_pipeline_latency(g.engine),
                 "Latency()=%u engine=%u", ETPipeline_Latency(), et_pipeline_latency(g.engine));
    fill(&g, 2, 0.25f);
    ET_CHECK(ETPipeline_Process(2, FR, 0) == ET_ERR_STATE);
    ET_CHECK(near(g.bus[0], 0.25f));   // 素通し
    // 残った外部ノードだけで組み直すと戻る。
    publish(&g.extAll, 1);
    ET_CHECK(ETPipeline_HasConfigured() == 1);
    fill(&g, 2, 0.25f);
    ET_CHECK(ETPipeline_Process(2, FR, 0) == ET_OK);
    ET_CHECK(near(g.bus[0], 1.25f));
    teardown(&g);
}

static const et_case cases[] = {
    ET_ENTRY(external_runs_at_position),
    ET_ENTRY(channel_pair_17),
    ET_ENTRY(parallel_bus_sum),
    ET_ENTRY(external_latency_compensated_once),
    ET_ENTRY(empty_slot_is_bypass),
    ET_ENTRY(destroy_resets_status),
};

int main(int argc, char **argv)
{
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
