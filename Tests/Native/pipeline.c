//  pipeline.c
//  Sources/Shared/ETPipeline.c を作り物の engine（fake_engine.c）につないだ試験。
//
//  2 回建てる:
//    pipeline_cb      engine が et_pipeline_set_external_callback を持つ（パッチの当たった版）。
//                     外部ノードは descriptor の位置で engine から呼ばれる。
//    pipeline_legacy  持たない（旧来の版）。外部処理は鎖の後ろでバス全体に 1 回ずつかける。
//  cb_ で始まる件は前者だけ、legacy_ で始まる件は後者だけに登録される（et_test.h）。

#include "ETPipeline.h"
#include "et_test.h"
#include "fake_engine.h"

#include <math.h>
#include <pthread.h>

// ---------------------------------------------------------------------------
// 外部処理の記録係

typedef struct {
    float *seen;
    uint32_t channels, frames, calls;
    float gain;
    uint32_t latency;
    double tail;
    double rate;
    int32_t ret;
} Rec;

static int32_t recProcess(void *c, float *p, uint32_t ch, uint32_t fr, double rate, double t)
{
    (void)t;
    Rec *r = (Rec *)c;
    r->seen = p;
    r->channels = ch;
    r->frames = fr;
    r->rate = rate;
    r->calls++;
    for (uint32_t i = 0; i < ch * fr; i++) p[i] *= r->gain;
    return r->ret;
}
static uint32_t recLatency(void *c) { return ((Rec *)c)->latency; }
static double recTail(void *c) { return ((Rec *)c)->tail; }

static ETExternalProcessor proc(Rec *r)
{
    ETExternalProcessor p;
    memset(&p, 0, sizeof p);
    p.context = r;
    p.process = recProcess;
    p.latency = recLatency;
    p.tailTime = recTail;
    return p;
}

static void fresh(void)
{
    fake_reset();
    ETPipeline_ClearExternalProcessor();
    ETPipeline_SetBypass(0);
    ETPipeline_SetEngine(7);
}

static const ETPipeNode kOne = {.instance = 1, .enabled = 1, .sectionGate = 1};

static void publishApply(const ETPipeNode *n, uint32_t count)
{
    ETPipeline_Publish(n, count);
    ETPipeline_ApplyPending();
}

// ---------------------------------------------------------------------------

ET_CASE(status_before_engine)
{
    // **表の先頭に置く。**まだ誰も SetEngine していない状態を見る。
    ET_CHECK(ETPipeline_LastStatus() == ET_ERR_STATE);
    ET_CHECK(ETPipeline_HasConfigured() == 0);
    ET_CHECK(ETPipeline_ActiveNodes() == 0);
    ET_CHECK(ETPipeline_ConfigureCount() == 0);
    ET_CHECK(ETPipeline_MainBus() == NULL);
    ET_CHECK(ETPipeline_Process(2, 64, 0) == ET_ERR_ARGS);
    ETPipeline_ApplyPending();   // engine が無くても落ちない
    ET_CHECK(ETPipeline_ConfigureCount() == 0);
}

ET_CASE(encode_records)
{
    fresh();
    const ETPipeNode n[3] = {
        {.instance = 0x01020304, .enabled = 1, .inputBus = 0, .outputBus = 2,
         .channelSpec = ET_CHANNEL_STEREO, .sectionGate = 1},
        {.instance = 9, .enabled = 2, .inputBus = 2, .outputBus = 0, .channelSpec = 17,
         .sectionGate = 7, .kind = ET_PIPE_NODE_NATIVE, .externalIndex = 5},
        {.instance = 0, .enabled = 1, .channelSpec = ET_CHANNEL_ALL, .sectionGate = 0,
         .kind = ET_PIPE_NODE_EXTERNAL, .externalIndex = 3},
    };
    publishApply(n, 3);
    ET_CHECK(fake_desc_len == 8 + 3 * 12);
    ET_CHECK(fake_rd32(fake_desc) == 1);       // 版
    ET_CHECK(fake_rd32(fake_desc + 4) == 3);   // 件数
    const uint8_t *r0 = fake_desc + 8, *r1 = r0 + 12, *r2 = r1 + 12;
    ET_CHECK(fake_rd32(r0) == 0x01020304);
    ET_CHECK(r0[4] == 1 && r0[5] == 0 && r0[6] == 2 && r0[7] == 0xFF && r0[8] == 1);
    ET_CHECK(r0[9] == 0 && r0[10] == 0 && r0[11] == 0);
    ET_CHECK(fake_rd32(r1) == 9);
    ET_CHECK(r1[4] == 1);    // enabled 2 は 1 として書く（音の扱いは同じ）
    ET_CHECK(r1[5] == 2 && r1[6] == 0 && r1[7] == 17);
    ET_CHECK(r1[8] == 1);    // sectionGate は 0/1 に揃える
    ET_CHECK(r1[9] == 0 && r1[10] == 0);   // native の externalIndex は書かない
    ET_CHECK(r2[9] == 1 && r2[10] == 3 && r2[8] == 0 && (int8_t)r2[7] == -2);
    ET_CHECK(ETPipeline_HasConfigured() == 1 && ETPipeline_LastStatus() == ET_OK);
}

ET_CASE(truncates_to_64)
{
    fresh();
    ETPipeNode many[80];
    memset(many, 0, sizeof many);
    for (int i = 0; i < 80; i++) {
        many[i].instance = (uint32_t)i + 1;
        many[i].enabled = 1;
        many[i].sectionGate = 1;
    }
    publishApply(many, 80);
    ET_CHECK(fake_rd32(fake_desc + 4) == 64);
    ET_CHECK(fake_desc_len == 8 + 64 * 12);
    ET_CHECK(fake_rd32(fake_desc + 8 + 63 * 12) == 64);
    ET_CHECK(ETPipeline_ActiveNodes() == 64);
    publishApply(NULL, 0);
    ET_CHECK(fake_desc_len == 8 && fake_rd32(fake_desc + 4) == 0);
    ET_CHECK(ETPipeline_ActiveNodes() == 0);
}

ET_CASE(active_nodes)
{
    fresh();
    const ETPipeNode n[5] = {
        {.instance = 1, .enabled = 1, .sectionGate = 1},   // 数える
        {.instance = 2, .enabled = 2, .sectionGate = 1},   // 図のための探り（数えない）
        {.instance = 3, .enabled = 0, .sectionGate = 1},   // 切
        {.instance = 4, .enabled = 1, .sectionGate = 0},   // Section の門が閉じている
        {.instance = 5, .enabled = 1, .sectionGate = 1},   // 数える
    };
    publishApply(n, 5);
    ET_CHECK(ETPipeline_ActiveNodes() == 2);
}

ET_CASE(configure_once)
{
    fresh();
    const uint64_t before = ETPipeline_ConfigureCount();
    ETPipeline_Publish(&kOne, 1);
    ET_CHECK(ETPipeline_ConfigureCount() == before);        // 音のスレッドが拾うまで渡さない
    ET_CHECK(ETPipeline_HasConfigured() == 0);
    ETPipeline_ApplyPending();
    ET_CHECK(ETPipeline_ConfigureCount() == before + 1);
    ETPipeline_ApplyPending();
    ET_CHECK(ETPipeline_ConfigureCount() == before + 1);    // 1 回だけ
    ET_CHECK(ETPipeline_Process(2, 64, 0) == ET_OK);
    ET_CHECK(ETPipeline_ConfigureCount() == before + 1);
    // Process も先頭で溜まった面を拾う。
    ETPipeline_Publish(&kOne, 1);
    ET_CHECK(ETPipeline_Process(2, 64, 0) == ET_OK);
    ET_CHECK(ETPipeline_ConfigureCount() == before + 2);
    // 拾われる前に 2 回出したら、組むのは新しい方の 1 回だけ。
    const ETPipeNode a = {.instance = 11, .enabled = 1, .sectionGate = 1};
    const ETPipeNode b = {.instance = 12, .enabled = 1, .sectionGate = 1};
    ETPipeline_Publish(&a, 1);
    ETPipeline_Publish(&b, 1);
    ETPipeline_ApplyPending();
    ETPipeline_ApplyPending();
    ET_CHECK(ETPipeline_ConfigureCount() == before + 3);
    ET_CHECK(fake_rd32(fake_desc + 8) == 12);
}

ET_CASE(setengine_drops_pending)
{
    fresh();
    publishApply(&kOne, 1);
    ET_CHECK(ETPipeline_HasConfigured() == 1);
    const uint64_t count = ETPipeline_ConfigureCount();
    ETPipeline_Publish(&kOne, 1);
    ETPipeline_SetEngine(8);
    ETPipeline_ApplyPending();
    ET_CHECK(ETPipeline_ConfigureCount() == count);    // 前の engine の instance なので捨てる
    ET_CHECK(ETPipeline_LastStatus() == ET_ERR_STATE);
    ET_CHECK(ETPipeline_HasConfigured() == 0);
    ET_CHECK(ETPipeline_ActiveNodes() == 0);
    ET_CHECK(ETPipeline_Process(2, 64, 0) == ET_ERR_STATE);
    // 捨てたあとも受け渡しは壊れていない。次の Publish は届く。
    publishApply(&kOne, 1);
    ET_CHECK(ETPipeline_ConfigureCount() == count + 1);
    ET_CHECK(ETPipeline_HasConfigured() == 1);
}

ET_CASE(configure_failure)
{
    fresh();
    atomic_store(&fake_native_latency, 128);
    publishApply(&kOne, 1);
    ET_CHECK(ETPipeline_Latency() == 128);
    fake_configure_result = ET_ERR_DESC;
    publishApply(&kOne, 1);
    ET_CHECK(ETPipeline_LastStatus() == ET_ERR_DESC);
    ET_CHECK(ETPipeline_HasConfigured() == 0);
    ET_CHECK(ETPipeline_ActiveNodes() == 0);
    ET_CHECK(ETPipeline_Latency() == 0);                     // 組めていないので覚えた値（0）
    const int calls = atomic_load(&fake_process_calls);
    ET_CHECK(ETPipeline_Process(2, 64, 0) == ET_ERR_STATE);
    ET_CHECK(atomic_load(&fake_process_calls) == calls);     // engine は呼ばない（素通し）
    fake_configure_result = ET_OK;
    publishApply(&kOne, 1);
    ET_CHECK(ETPipeline_LastStatus() == ET_OK && ETPipeline_HasConfigured() == 1);
}

ET_CASE(latency_live_from_engine)
{
    fresh();
    atomic_store(&fake_native_latency, 64);
    publishApply(&kOne, 1);
    ET_CHECK(ETPipeline_Latency() == 64);
    // 組み直さなくても、パラメータで遅延が変われば読み直す（その場で engine に聞く）。
    atomic_store(&fake_native_latency, 96);
    ET_CHECK(ETPipeline_Latency() == 96);
}

ET_CASE(process_args_and_bypass)
{
    fresh();
    ETPipeline_Publish(&kOne, 1);
    ET_CHECK(ETPipeline_Process(0, 64, 0) == ET_ERR_ARGS);
    ET_CHECK(ETPipeline_Process(2, 0, 0) == ET_ERR_ARGS);
    const uint64_t pc = ETPipeline_ProcessCount();
    ET_CHECK(ETPipeline_Process(2, 64, 0) == ET_OK);
    ET_CHECK(ETPipeline_ProcessCount() == pc + 1);
    ET_CHECK(fake_last_channels == 2 && fake_last_frames == 64 && fake_last_bypass == 0);
    ETPipeline_SetBypass(5);
    ET_CHECK(ETPipeline_IsBypassed() == 1);
    ET_CHECK(ETPipeline_Process(2, 64, 0) == ET_OK && fake_last_bypass == 1);
    ETPipeline_SetBypass(0);
    ET_CHECK(ETPipeline_IsBypassed() == 0);
    ET_CHECK(ETPipeline_MainBus() == fake_bus);
}

ET_CASE(external_copy_semantics)
{
    fresh();
    Rec a = {.gain = 2, .latency = 10, .tail = 0.5}, b = {.gain = 3, .latency = 5, .tail = 2.0};
    ETExternalProcessor ps[2] = {proc(&a), proc(&b)};
    ETPipeline_SetExternalProcessors(ps, 2);
    // 渡した配列は写してあるので、あとで書き換えても効かない。
    memset(ps, 0, sizeof ps);
    ET_CHECK(ETPipeline_ExternalLatency() == 15);
    ETPipeline_ClearExternalProcessorAt(1);
    ET_CHECK(ETPipeline_ExternalLatency() == 10);
    ETPipeline_SetExternalProcessorAt(ET_EXTERNAL_MAX_PROCESSORS, &ps[0]);   // 範囲外は無視
    ETPipeline_ClearExternalProcessor();
    ET_CHECK(ETPipeline_ExternalLatency() == 0);
    ET_CHECK(ETPipeline_ExternalProcessCount(ET_EXTERNAL_MAX_PROCESSORS) == 0);
    ET_CHECK(ETPipeline_ExternalLastStatus(ET_EXTERNAL_MAX_PROCESSORS) == ET_ERR_ARGS);
    // process の無い記述は「外す」と同じ。
    ETExternalProcessor empty;
    memset(&empty, 0, sizeof empty);
    ETPipeline_SetExternalProcessor(&empty);
    ET_CHECK(ETPipeline_ExternalLatency() == 0);
}

ET_CASE(tail_max)
{
    fresh();
    Rec a = {.gain = 1, .tail = 0.5}, b = {.gain = 1, .tail = 2.0}, c = {.gain = 1, .tail = 1.0};
    ETExternalProcessor ps[3] = {proc(&a), proc(&b), proc(&c)};
    ETPipeline_SetExternalProcessors(ps, 3);
    ET_CHECK(ETPipeline_ExternalTailTime() == 2.0);   // 足さずに一番長いもの
    ETPipeline_ClearExternalProcessor();
    ET_CHECK(ETPipeline_ExternalTailTime() == 0.0);
}

#if ET_FAKE_EXTERNAL_CALLBACK
ET_CASE(cb_latency_not_double)
{
    // engine が外部ノードの遅れを遅延補正に入れるので、こちらで足すと 2 回数えることになる。
    fresh();
    Rec a = {.gain = 1, .latency = 10};
    ETExternalProcessor p = proc(&a);
    ETPipeline_SetExternalProcessorAt(0, &p);
    atomic_store(&fake_native_latency, 100);
    const ETPipeNode n = {.enabled = 1, .sectionGate = 1, .channelSpec = ET_CHANNEL_ALL,
                          .kind = ET_PIPE_NODE_EXTERNAL, .externalIndex = 0};
    publishApply(&n, 1);
    ET_CHECK(ETPipeline_Latency() == 100);
    ET_CHECK(ETPipeline_ExternalLatency() == 10);
    ET_CHECK(fake_lcb != NULL && fake_lcb(fake_ctx, 0) == 10);
    ET_CHECK(fake_lcb(fake_ctx, ET_EXTERNAL_MAX_PROCESSORS) == 0);
}

#endif

#if !ET_FAKE_EXTERNAL_CALLBACK
ET_CASE(legacy_latency_sum)
{
    // 旧来の engine は外部処理を知らないので、鎖の遅れに外部の遅れを足して返す。
    fresh();
    Rec a = {.gain = 1, .latency = 10}, b = {.gain = 1, .latency = 5};
    ETExternalProcessor ps[2] = {proc(&a), proc(&b)};
    ETPipeline_SetExternalProcessors(ps, 2);
    atomic_store(&fake_native_latency, 100);
    publishApply(&kOne, 1);
    ET_CHECK(ETPipeline_Latency() == 115);
}

#endif

#if ET_FAKE_EXTERNAL_CALLBACK
ET_CASE(cb_external_slicing)
{
    fresh();
    ETPipeline_SetExternalSampleRate(96000);
    Rec a = {.gain = 2}, b = {.gain = 3};
    ETExternalProcessor ps[2] = {proc(&a), proc(&b)};
    ETPipeline_SetExternalProcessors(ps, 2);
    const ETPipeNode n[2] = {
        {.enabled = 1, .sectionGate = 1, .channelSpec = 18, .kind = ET_PIPE_NODE_EXTERNAL,
         .externalIndex = 0},
        {.enabled = 1, .sectionGate = 1, .channelSpec = 3, .kind = ET_PIPE_NODE_EXTERNAL,
         .externalIndex = 1},
    };
    publishApply(n, 2);
    for (int i = 0; i < 8 * 64; i++) fake_bus[i] = 1;
    ET_CHECK(ETPipeline_Process(8, 64, 0) == ET_OK);
    ET_CHECK(a.calls == 1 && a.channels == 2 && a.seen == fake_bus + 4 * 64);   // 18 → 対 (4,5)
    ET_CHECK(b.calls == 1 && b.channels == 1 && b.seen == fake_bus + 3 * 64);   // 3 → ch3
    ET_CHECK(a.rate == 96000 && b.rate == 96000);
    ET_CHECK(fake_bus[0] == 1 && fake_bus[3 * 64] == 3 && fake_bus[4 * 64] == 2);
    ET_CHECK(fake_bus[5 * 64 + 63] == 2 && fake_bus[6 * 64] == 1);
    ET_CHECK(ETPipeline_ExternalProcessCount(0) == 1 && ETPipeline_ExternalLastStatus(0) == 0);
    // 後段の旧来処理は走らない（走ると 1 ブロックに 2 回かかる）。
    ET_CHECK(ETPipeline_Process(8, 64, 0) == ET_OK);
    ET_CHECK(a.calls == 2 && b.calls == 2);
    // 対がチャンネル数を超える・番号が範囲外は ET_ERR_ARGS。
    ET_CHECK(fake_cb(fake_ctx, 0, fake_bus, 4, 64, 0, 18) == ET_ERR_ARGS);
    ET_CHECK(fake_cb(fake_ctx, ET_EXTERNAL_MAX_PROCESSORS, fake_bus, 2, 64, 0, -2) == ET_ERR_ARGS);
    // まだ作られていない枠は素通し（鎖ごとの失敗にしない）。
    ETPipeline_ClearExternalProcessorAt(1);
    ET_CHECK(fake_cb(fake_ctx, 1, fake_bus, 2, 64, 0, -2) == ET_OK);
    // 失敗はそのまま返り、数と最後の値に残る。
    a.ret = -7;
    ET_CHECK(fake_cb(fake_ctx, 0, fake_bus, 2, 64, 0, ET_CHANNEL_STEREO) == -7);
    ET_CHECK(ETPipeline_ExternalLastStatus(0) == -7);
}

ET_CASE(cb_negative_channel_spec_rejected)
{
    // -2 より小さい channelSpec は無い。以前はチャンネル 0 のモノとして処理していた。
    fresh();
    Rec c = {.gain = 1};
    ETExternalProcessor p = proc(&c);
    ETPipeline_SetExternalProcessorAt(2, &p);
    ET_CHECK(fake_cb != NULL);
    ET_CHECK(fake_cb(fake_ctx, 2, fake_bus, 2, 64, 0, -5) == ET_ERR_ARGS);
    ET_CHECK(fake_cb(fake_ctx, 2, fake_bus, 2, 64, 0, -128) == ET_ERR_ARGS);
    ET_CHECK(c.calls == 0);
    ET_CHECK(fake_cb(fake_ctx, 2, fake_bus, 2, 64, 0, ET_CHANNEL_STEREO) == ET_OK && c.calls == 1);
}

#endif

#if !ET_FAKE_EXTERNAL_CALLBACK
ET_CASE(legacy_postpass_order)
{
    fresh();
    ETPipeline_SetExternalSampleRate(96000);
    Rec a = {.gain = 2}, b = {.gain = 3};
    ETExternalProcessor ps[2] = {proc(&a), proc(&b)};
    ETPipeline_SetExternalProcessors(ps, 2);
    publishApply(&kOne, 1);
    for (int i = 0; i < 8 * 64; i++) fake_bus[i] = 1;
    ET_CHECK(ETPipeline_Process(8, 64, 0) == ET_OK);
    // 鎖の後ろでバス全体に、枠の順に 1 回ずつ。
    ET_CHECK(a.calls == 1 && a.channels == 8 && a.seen == fake_bus);
    ET_CHECK(b.calls == 1 && b.channels == 8 && a.rate == 96000);
    ET_CHECK(fake_bus[0] == 6 && fake_bus[8 * 64 - 1] == 6);   // 1 * 2 * 3
    // 外部の失敗は鎖の戻り値として出る。
    b.ret = -7;
    ET_CHECK(ETPipeline_Process(8, 64, 0) == -7);
    // 組めていなければ外部もかけない。
    fake_configure_result = ET_ERR_DESC;
    publishApply(&kOne, 1);
    const uint32_t calls = a.calls;
    ET_CHECK(ETPipeline_Process(8, 64, 0) == ET_ERR_STATE);
    ET_CHECK(a.calls == calls);
}

#endif

ET_CASE(destroy_skips_instance0_and_null)
{
    fresh();
    publishApply(&kOne, 1);
    const uint32_t one = 1, zero = 0;
    ET_CHECK(ETPipeline_DestroyInstances(0, &one, 1) == 1);     // engine 0
    ET_CHECK(ETPipeline_DestroyInstances(7, NULL, 1) == 1);
    ET_CHECK(ETPipeline_DestroyInstances(7, &one, 0) == 1);
    ET_CHECK(ETPipeline_DestroyInstances(7, &zero, 1) == 1);    // 0 は壊さない
    ET_CHECK(atomic_load(&fake_destroyed) == 0);
    // 何も壊していなければ鎖はそのまま。
    ET_CHECK(ETPipeline_HasConfigured() == 1 && ETPipeline_LastStatus() == ET_OK);
}

static void *render_blocked(void *arg)
{
    (void)arg;
    ETPipeline_Process(2, 64, 0);
    return NULL;
}

ET_CASE(destroy_gives_up_50ms)
{
    fresh();
    publishApply(&kOne, 1);
    atomic_store(&fake_block_process, 1);
    pthread_t t;
    ET_CHECK(pthread_create(&t, NULL, render_blocked, NULL) == 0);
    while (!atomic_load(&fake_in_process)) fake_sleep_us(50);
    const uint32_t ids[3] = {1, 0, 2};
    const double t0 = fake_now_ms();
    const int r = ETPipeline_DestroyInstances(7, ids, 3);
    const double dt = fake_now_ms() - t0;
    ET_CHECK(r == 0);
    ET_CHECK(atomic_load(&fake_destroyed) == 0);   // 諦めたら何も壊さない
    ET_CHECK_MSG(dt >= 49 && dt < 1000, "gave up after %.1f ms", dt);
    ET_CHECK(ETPipeline_HasConfigured() == 1);     // 壊していないので組めたまま
    atomic_store(&fake_block_process, 0);
    ET_CHECK(pthread_join(t, NULL) == 0);
    ET_CHECK(ETPipeline_DestroyInstances(7, ids, 3) == 1);
    ET_CHECK(atomic_load(&fake_destroyed) == 2);   // 0 は飛ばす
    ET_CHECK(atomic_load(&fake_overlap) == 0);
}

ET_CASE(destroy_resets_status)
{
    // 本物の engine は instance を壊すと鎖を無効にする（invalidatePipeline）。
    // 以前は次の Publish が拾われるまで HasConfigured()=1, LastStatus()=ET_OK が残っていた。
    fresh();
    const ETPipeNode n[2] = {{.instance = 1, .enabled = 1, .sectionGate = 1},
                             {.instance = 2, .enabled = 1, .sectionGate = 1}};
    atomic_store(&fake_native_latency, 128);
    publishApply(n, 2);
    ET_CHECK(ETPipeline_HasConfigured() == 1 && ETPipeline_ActiveNodes() == 2);
    ET_CHECK(ETPipeline_Latency() == 128);
    const uint32_t id = 2;
    ET_CHECK(ETPipeline_DestroyInstances(7, &id, 1) == 1);
    ET_CHECK(ETPipeline_HasConfigured() == 0);
    ET_CHECK(ETPipeline_LastStatus() == ET_ERR_STATE);
    ET_CHECK(ETPipeline_ActiveNodes() == 0);
    // engine の遅れも 0 に戻る（invalidatePipeline）。組めていないので覚えた値を返すが、それも 0。
    ET_CHECK_MSG(ETPipeline_Latency() == 0, "Latency() after destroy = %u", ETPipeline_Latency());
    const int calls = atomic_load(&fake_process_calls);
    ET_CHECK(ETPipeline_Process(2, 64, 0) == ET_ERR_STATE);
    ET_CHECK(atomic_load(&fake_process_calls) == calls);
    // 組み直せば戻る（EffeTuneDSP.retire は壊したあと必ず republish する）。
    publishApply(n, 1);
    ET_CHECK(ETPipeline_HasConfigured() == 1 && ETPipeline_LastStatus() == ET_OK);
    ET_CHECK(ETPipeline_ActiveNodes() == 1);
    ET_CHECK(ETPipeline_Latency() == 128);
    ET_CHECK(ETPipeline_Process(2, 64, 0) == ET_OK);
}

static const et_case cases[] = {
    ET_ENTRY(status_before_engine),
    ET_ENTRY(encode_records),
    ET_ENTRY(truncates_to_64),
    ET_ENTRY(active_nodes),
    ET_ENTRY(configure_once),
    ET_ENTRY(setengine_drops_pending),
    ET_ENTRY(configure_failure),
    ET_ENTRY(latency_live_from_engine),
    ET_ENTRY(process_args_and_bypass),
    ET_ENTRY(external_copy_semantics),
    ET_ENTRY(tail_max),
#if ET_FAKE_EXTERNAL_CALLBACK
    ET_ENTRY(cb_latency_not_double),
    ET_ENTRY(cb_external_slicing),
    ET_ENTRY(cb_negative_channel_spec_rejected),
#else
    ET_ENTRY(legacy_latency_sum),
    ET_ENTRY(legacy_postpass_order),
#endif
    ET_ENTRY(destroy_skips_instance0_and_null),
    ET_ENTRY(destroy_gives_up_50ms),
    ET_ENTRY(destroy_resets_status),
};

int main(int argc, char **argv)
{
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
