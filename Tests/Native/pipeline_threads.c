//  pipeline_threads.c
//  ETPipeline.c の、UI スレッドと音のスレッドのすれ違い。ctest のラベルは tsan。
//  TSan で走らせる（CMakePresets.json の tsan）と、競合があれば報告で落ちる。
//  TSan なしでも、読んでいる面が書き換わったかどうかは作り物の engine が数えている。

#include "ETPipeline.h"
#include "et_test.h"
#include "fake_engine.h"

#include <pthread.h>

static void fresh(void)
{
    fake_reset();
    ETPipeline_ClearExternalProcessor();
    ETPipeline_SetBypass(0);
    ETPipeline_SetEngine(7);
}

static void *render_apply(void *arg)
{
    (void)arg;
    ETPipeline_ApplyPending();
    return NULL;
}

static ETPipeNode node(uint32_t instance)
{
    ETPipeNode n;
    memset(&n, 0, sizeof n);
    n.instance = instance;
    n.enabled = 1;
    n.sectionGate = 1;
    return n;
}

/// 音のスレッドを configure の中で止めたまま、UI が何度も Publish する。
static void publish_while_configuring(uint32_t publishes, uint32_t *lastInstance)
{
    const ETPipeNode first = node(1);
    ETPipeline_Publish(&first, 1);
    atomic_store(&fake_block_configure, 1);
    pthread_t t;
    ET_CHECK(pthread_create(&t, NULL, render_apply, NULL) == 0);
    while (!atomic_load(&fake_in_configure)) fake_sleep_us(50);
    for (uint32_t k = 0; k < publishes; k++) {
        ETPipeNode two[2] = {node(100 + k), node(1000 + k)};
        ETPipeline_Publish(two, 2);
        *lastInstance = 100 + k;
    }
    atomic_store(&fake_block_configure, 0);
    ET_CHECK(pthread_join(t, NULL) == 0);
}

ET_CASE(slot_reuse)
{
    // 以前の 4 面の輪では、configure が読んでいる面を 4 回目の Publish が memset して書き直した。
    fresh();
    uint32_t last = 0;
    publish_while_configuring(4, &last);
    ET_CHECK_MSG(atomic_load(&fake_torn) == 0,
                 "the descriptor being configured was rewritten by Publish");
    ET_CHECK(fake_rd32(fake_desc + 4) == 1 && fake_rd32(fake_desc + 8) == 1);
}

ET_CASE(latest_publish_wins)
{
    // 止めている間に何度出しても、読んでいる面は壊れず、次に組むのは最後に出したもの。
    fresh();
    uint32_t last = 0;
    publish_while_configuring(100, &last);
    ET_CHECK(atomic_load(&fake_torn) == 0);
    const int before = atomic_load(&fake_configure_calls);
    ETPipeline_ApplyPending();
    ET_CHECK(atomic_load(&fake_configure_calls) == before + 1);
    ET_CHECK(fake_rd32(fake_desc + 4) == 2);
    ET_CHECK_MSG(fake_rd32(fake_desc + 8) == last, "configured %u, last published %u",
                 fake_rd32(fake_desc + 8), last);
    ETPipeline_ApplyPending();
    ET_CHECK(atomic_load(&fake_configure_calls) == before + 1);
}

ET_CASE(setengine_while_configuring)
{
    // configure の最中に SetEngine が溜まった面を捨てたら、抜けたあとも拾わない。
    fresh();
    const ETPipeNode first = node(1);
    ETPipeline_Publish(&first, 1);
    atomic_store(&fake_block_configure, 1);
    pthread_t t;
    ET_CHECK(pthread_create(&t, NULL, render_apply, NULL) == 0);
    while (!atomic_load(&fake_in_configure)) fake_sleep_us(50);
    const ETPipeNode second = node(2);
    ETPipeline_Publish(&second, 1);
    ETPipeline_SetEngine(8);
    atomic_store(&fake_block_configure, 0);
    ET_CHECK(pthread_join(t, NULL) == 0);
    const int before = atomic_load(&fake_configure_calls);
    ETPipeline_ApplyPending();
    ET_CHECK(atomic_load(&fake_configure_calls) == before);
    // そのあとの Publish は届く。
    const ETPipeNode third = node(3);
    ETPipeline_Publish(&third, 1);
    ETPipeline_ApplyPending();
    ET_CHECK(atomic_load(&fake_configure_calls) == before + 1);
    ET_CHECK(fake_rd32(fake_desc + 8) == 3);
}

static _Atomic int gStop;

static void *render_loop(void *arg)
{
    (void)arg;
    while (!atomic_load(&gStop)) {
        ETPipeline_ApplyPending();
        ETPipeline_Process(2, 64, 0);
    }
    return NULL;
}

ET_CASE(destroy_2000)
{
    // 音のスレッドが回り続けている横で 2000 回壊す。engine の中で重なってはいけない。
    fresh();
    const ETPipeNode n = node(1);
    ETPipeline_Publish(&n, 1);
    atomic_store(&gStop, 0);
    pthread_t t;
    ET_CHECK(pthread_create(&t, NULL, render_loop, NULL) == 0);
    // 諦めるのは音のスレッドが 50 ms 中に居続けたときだけだが、混んだ機械では
    // engine の中で CPU を取り上げられてそうなる。EffeTuneDSP.retire と同じく、
    // 諦めたら間を置いて呼び直す。何度も諦め続けるのは止まっているので落とす。
    int giveUps = 0;
    const uint32_t id = 1;
    for (int i = 0; i < 2000; i++) {
        int tries = 0;
        while (!ETPipeline_DestroyInstances(7, &id, 1)) {
            giveUps++;
            if (++tries >= 100) break;
            fake_sleep_us(1000);
        }
        if (tries >= 100) break;
        if (i % 50 == 0) ETPipeline_Publish(&n, 1);
    }
    atomic_store(&gStop, 1);
    ET_CHECK(pthread_join(t, NULL) == 0);
    printf("   destroy_2000: %d/2000 destroyed, %d give-ups retried, overlap=%d\n",
           atomic_load(&fake_destroyed), giveUps, atomic_load(&fake_overlap));
    ET_CHECK(atomic_load(&fake_overlap) == 0);
    // 諦めた回は何も壊さないので、呼び直しを含めてちょうど 2000 回壊れる。
    ET_CHECK_MSG(atomic_load(&fake_destroyed) == 2000, "%d of 2000 destroyed",
                 atomic_load(&fake_destroyed));
}

ET_CASE(publish_storm)
{
    // 音のスレッドが回っている間に UI が出し続けても、configure が読む面は書き換わらない。
    fresh();
    atomic_store(&gStop, 0);
    pthread_t t;
    ET_CHECK(pthread_create(&t, NULL, render_loop, NULL) == 0);
    for (uint32_t k = 0; k < 20000; k++) {
        ETPipeNode two[2] = {node(k + 1), node(k + 2)};
        ETPipeline_Publish(two, (k & 1) + 1);
    }
    const ETPipeNode last = node(424242);
    ETPipeline_Publish(&last, 1);
    atomic_store(&gStop, 1);
    ET_CHECK(pthread_join(t, NULL) == 0);
    ET_CHECK(atomic_load(&fake_torn) == 0);
    ETPipeline_ApplyPending();   // 止めたあとに残っていれば拾う
    ET_CHECK(fake_rd32(fake_desc + 4) == 1 && fake_rd32(fake_desc + 8) == 424242);
}

static const et_case cases[] = {
    ET_ENTRY(slot_reuse),
    ET_ENTRY(latest_publish_wins),
    ET_ENTRY(setengine_while_configuring),
    ET_ENTRY(destroy_2000),
    ET_ENTRY(publish_storm),
};

int main(int argc, char **argv)
{
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
