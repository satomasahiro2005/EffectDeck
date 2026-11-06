//  sample_stream.c
//  ETSampleStream.c（流し込みの標本を、描画の前後で engine へ渡す口）の試験。三つの束ね方で建てる。
//
//    fake_*    作り物の engine（fake_engine.c）。要求の順・1 ブロックの上限・古い世代の拒否・
//              bypass で止まること・先読み（SELECTED_PRESETS）の手順・確保が 0 であること。
//    thread_*  音・control・供給の 3 スレッドを同時に回す（TSan 用。ラベル tsan）。
//    engine_*  本物の engine（-DET_NATIVE_WITH_ENGINE=ON）と SoundFont の見本（kSf2HostFixture）。
//              ページを渡すと鳴り、渡さなければ音が落ちて instance は ERROR にならないこと、
//              本物の allocation guard の下で steady state の確保が 0 であること。
//
//  fake の確保の数え方は上流の WRAP_MALLOC の試験と同じ（-Wl,--wrap=malloc）。Linux だけ。

// pthread_create / nanosleep は POSIX。-std=c11 の glibc では宣言が隠れる（Darwin は隠さない）。
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "ETPipeline.h"
#include "ETSampleStream.h"
#include "effetune/abi.h"
#include "et_test.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

#ifndef ET_SS_ENGINE
#include "fake_engine.h"
#endif

#ifndef ET_SS_WRAP_MALLOC
#define ET_SS_WRAP_MALLOC 0
#endif

enum { FR = 64, ENGINE_ID = 1, INSTANCE_ID = 7 };

// MARK: - 確保の数え方（fake だけ）

#if ET_SS_WRAP_MALLOC
// 数えるのは、数え始めたスレッドだけ。印刷や pthread の中身を数えないよう、数える範囲は呼び出しだけに絞る。
static _Thread_local int tlCounting;
static _Thread_local unsigned long tlAllocs;
void *__real_malloc(size_t);
void *__real_calloc(size_t, size_t);
void *__real_realloc(void *, size_t);
void *__real_aligned_alloc(size_t, size_t);
int __real_posix_memalign(void **, size_t, size_t);
void *__wrap_malloc(size_t n) { if (tlCounting) tlAllocs++; return __real_malloc(n); }
void *__wrap_calloc(size_t a, size_t b) { if (tlCounting) tlAllocs++; return __real_calloc(a, b); }
void *__wrap_realloc(void *p, size_t n) { if (tlCounting) tlAllocs++; return __real_realloc(p, n); }
void *__wrap_aligned_alloc(size_t a, size_t n) { if (tlCounting) tlAllocs++; return __real_aligned_alloc(a, n); }
int __wrap_posix_memalign(void **p, size_t a, size_t n) { if (tlCounting) tlAllocs++; return __real_posix_memalign(p, a, n); }
#define COUNT_BEGIN() do { tlAllocs = 0; tlCounting = 1; } while (0)
#define COUNT_END() (tlCounting = 0, tlAllocs)
#else
#define COUNT_BEGIN() do { } while (0)
#define COUNT_END() 0ul
#endif

// MARK: - 共通の道具

#ifndef ET_SS_ENGINE
static double nowRate(void) { return 48000.0; }
#endif

#ifndef ET_SS_ENGINE
// 1 枚だけ供給役として渡す（全 4096 フレーム・mono・値は一定）。
static uint32_t submitOne(uint32_t slot, uint64_t generation, uint64_t pageIndex, uint32_t sample, float value)
{
    ETStreamPage *page = ETSampleStream_AcquirePage(slot, generation);
    ET_CHECK(page != NULL);
    for (uint32_t k = 0; k < ET_STREAM_PAGE_FRAMES; k++) page->pcm[k] = value;
    const ETStreamRequest request = { generation, pageIndex, sample, 0 };
    return (uint32_t)ETSampleStream_SubmitPage(page, &request, ET_STREAM_PAGE_FRAMES, 1);
}
#endif

// MARK: - fake

#ifndef ET_SS_ENGINE

static void fakeSetup(void)
{
    fake_reset();
    ETPipeline_SetBypass(0);
    ETPipeline_SetEngine(ENGINE_ID);
    ETPipeline_Publish(NULL, 0);
    ETPipeline_ApplyPending();
    ET_CHECK(ETPipeline_HasConfigured());
}

static void fakeTeardown(void)
{
    ETSampleStream_DetachAll();
    ETSampleStream_Reap();
    ETPipeline_SetEngine(0);
    ETSampleStream_ResetGenerationsForTesting();
}

static uint32_t attach(uint64_t generation, uint32_t flags)
{
    uint32_t slot = 99;
    ET_CHECK_MSG(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, generation, nowRate(), flags, &slot) == ET_OK,
                 "attach");
    ET_CHECK(slot < ET_STREAM_MAX_SLOTS);
    return slot;
}

static void setReady(uint32_t scope, uint32_t planned, uint32_t pending);

static void process(uint32_t frames)
{
    ET_CHECK(ETPipeline_Process(2, frames, 0.0) == ET_OK);
}

ET_CASE(fake_attach_configures_and_validates)
{
    fakeSetup();
    uint32_t slot = 99;
    ET_CHECK(ETSampleStream_Attach(0, INSTANCE_ID, 5, nowRate(), 0, &slot) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, 0, 5, nowRate(), 0, &slot) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, 0, nowRate(), 0, &slot) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, 5, 0.0, 0, &slot) == ET_ERR_ARGS);
    ET_CHECK(atomic_load(&fake_stream_configure_calls) == 0);

    // configure が断れば slot は立たない（資産が無い・ERROR のとき）。
    fake_stream_configure_status = ET_ERR_STATE;
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, 5, nowRate(), 0, &slot) == ET_ERR_STATE);
    ET_CHECK(ETSampleStream_SlotFor(ENGINE_ID, INSTANCE_ID) == -1);
    fake_stream_configure_status = ET_OK;

    // 64 ビットの世代が configure に low / high で渡る。
    const uint64_t big = 0x0000000300000005ull;
    slot = attach(big, 0);
    ET_CHECK(atomic_load(&fake_stream_generation) == big);
    ET_CHECK(ETSampleStream_SlotFor(ENGINE_ID, INSTANCE_ID) == (int)slot);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.generation == big);

    // 同じ instance に Attach し直すと slot を使い回し、世代が替わる。
    const uint32_t again = attach(big + 1, 0);
    ET_CHECK(again == slot);
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.generation == big + 1);

    // slot が足りなければ ET_ERR_STATE。
    uint32_t used[ET_STREAM_MAX_SLOTS];
    used[0] = slot;
    for (uint32_t i = 1; i < ET_STREAM_MAX_SLOTS; i++) {
        ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID + i, big + 2 + i, nowRate(), 0, &used[i]) == ET_OK);
    }
    const uint64_t next = big + 2 + ET_STREAM_MAX_SLOTS;
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID + 50, next, nowRate(), 0, &slot) == ET_ERR_STATE);
    ET_CHECK(ETSampleStream_Detach(ENGINE_ID, INSTANCE_ID + 1) == 1);
    ET_CHECK(ETSampleStream_Detach(ENGINE_ID, INSTANCE_ID + 1) == 0);
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID + 50, next, nowRate(), 0, &slot) == ET_OK);
    fakeTeardown();
}

// 世代はプロセス全体で増え続ける。供給の栅は (slot, 世代) だけを見るので、壊した instance の供給が残っていても、
// 同じ世代で別の instance が同じ slot に付けないこと。
ET_CASE(fake_generation_must_increase_across_attaches)
{
    fakeSetup();
    const uint64_t first = ETSampleStream_NextGeneration();
    ET_CHECK(first >= 1);
    ET_CHECK(ETSampleStream_NextGeneration() > first);   // 渡しただけでも先へ進む
    const uint64_t g = ETSampleStream_NextGeneration();
    uint32_t slot = 99;
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, g, nowRate(), 0, &slot) == ET_OK);
    // 同じ世代・古い世代は、別の instance でも、畳んだあとでも断る。slot は変わらない。
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID + 1, g, nowRate(), 0, &slot) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID + 1, g - 1, nowRate(), 0, &slot) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, g, nowRate(), 0, &slot) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_SlotFor(ENGINE_ID, INSTANCE_ID) >= 0 && ETSampleStream_SlotFor(ENGINE_ID, INSTANCE_ID + 1) == -1);
    ET_CHECK(ETSampleStream_Detach(ENGINE_ID, INSTANCE_ID) == 1);
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, g, nowRate(), 0, &slot) == ET_ERR_ARGS);
    // 断られた Attach は下限を動かさない。configure に断られた世代も同じ。
    fake_stream_configure_status = ET_ERR_STATE;
    const uint64_t refused = ETSampleStream_NextGeneration();
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, refused, nowRate(), 0, &slot) == ET_ERR_STATE);
    fake_stream_configure_status = ET_OK;
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, refused, nowRate(), 0, &slot) == ET_OK);
    ET_CHECK(ETSampleStream_NextGeneration() > refused);
    fakeTeardown();
}

// 供給が抜けるのが遅れて解放を延ばした確保は、次の control の呼び出し（Attach / Detach）で拾う。
// Reap を呼び忘れても、墓場（16 本）が詰まって漏れるまで行かない。
ET_CASE(fake_parked_storage_is_reaped_by_next_control_call)
{
    fakeSetup();
    uint32_t slot = attach(ETSampleStream_NextGeneration(), 0);
    uint64_t generation = 0;
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1);
    generation = st.generation;
    ETStreamPage *held = ETSampleStream_AcquirePage(slot, generation);
    ET_CHECK(held != NULL);
    ET_CHECK(ETSampleStream_Detach(ENGINE_ID, INSTANCE_ID) == 1);
    ET_CHECK_MSG(ETSampleStream_Parked() == 1, "借りたままの確保は延ばされる");
    // 借りが返っても、誰かが拾うまでは残る。
    ETSampleStream_ReleasePage(held);
    ET_CHECK(ETSampleStream_Parked() == 1);
    // 次の Attach が拾う（Reap を呼んでいない）。
    slot = attach(ETSampleStream_NextGeneration(), 0);
    ET_CHECK_MSG(ETSampleStream_Parked() == 0, "parked=%u", ETSampleStream_Parked());
    // Detach の先頭でも拾う。
    ETSampleStream_Snapshot(slot, &st);
    held = ETSampleStream_AcquirePage(slot, st.generation);
    ET_CHECK(held != NULL);
    ET_CHECK(ETSampleStream_Detach(ENGINE_ID, INSTANCE_ID) == 1);
    ET_CHECK(ETSampleStream_Parked() == 1);
    ETSampleStream_ReleasePage(held);
    ET_CHECK(ETSampleStream_Detach(ENGINE_ID, INSTANCE_ID) == 0);
    ET_CHECK(ETSampleStream_Parked() == 0);
    fakeTeardown();
}

// 供給が失敗を残したら、画面（Snapshot）から見えて、先読みも止まる。最初の理由だけを残す。古い世代の呼び出しは数えない。
ET_CASE(fake_supply_failure_is_visible_and_stops_forecast)
{
    fakeSetup();
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 1, 1);   // pending があるので揃わない
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    for (int i = 0; i < 4; i++) process(1024);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1);
    ET_CHECK(st.failed == 0 && st.requestsFailed == 0 && st.forecastRuns > 0);
    const uint64_t runs = st.forecastRuns;

    ETSampleStream_Fail(slot, 4, ET_STREAM_FAIL_READ, 9);   // 古い世代
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.failed == 0 && st.requestsFailed == 0);
    ETSampleStream_Fail(slot, 5, ET_STREAM_FAIL_RANGE, 3);
    ETSampleStream_Fail(slot, 5, ET_STREAM_FAIL_READ, 2);
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1);
    ET_CHECK_MSG(st.failed == ET_STREAM_FAIL_RANGE && st.requestsFailed == 5 && st.requestsAbandoned == 5,
                 "failed=%u requestsFailed=%llu", st.failed, (unsigned long long)st.requestsFailed);
    for (int i = 0; i < 20; i++) process(1024);
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.forecastRuns == runs);
    // 読み直す（新しい世代）と失敗は消える。
    const uint32_t again = attach(6, ET_STREAM_ATTACH_FORECAST);
    ET_CHECK(again == slot);
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.failed == 0 && st.requestsFailed == 0);
    fakeTeardown();
}

// 無効な node（ETPipeline_Publish の enabled / sectionGate）の流しは先読みしない。有効に戻せば進む。
ET_CASE(fake_disabled_node_does_not_forecast)
{
    fakeSetup();
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 1, 0);
    attach(5, ET_STREAM_ATTACH_FORECAST);
    ETPipeNode node;
    memset(&node, 0, sizeof node);
    node.instance = INSTANCE_ID;
    node.channelSpec = ET_CHANNEL_ALL;
    node.enabled = 0;
    node.sectionGate = 1;
    ETPipeline_Publish(&node, 1);
    for (int i = 0; i < 20; i++) process(1024);
    ET_CHECK_MSG(atomic_load(&fake_prefetch_count) == 0, "prefetch=%d", atomic_load(&fake_prefetch_count));
    // Section が無効でも同じ。
    node.enabled = 1;
    node.sectionGate = 0;
    ETPipeline_Publish(&node, 1);
    for (int i = 0; i < 20; i++) process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) == 0);
    node.sectionGate = 1;
    ETPipeline_Publish(&node, 1);
    for (int i = 0; i < 20; i++) process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) > 0);
    fakeTeardown();
}

// 要求は engine が出した順のまま、欠けず・重ならずに供給へ届く（輪の上限 4096 を超える分は engine に残る）。
ET_CASE(fake_requests_arrive_in_order)
{
    fakeSetup();
    const uint32_t total = 3000;
    for (uint32_t i = 0; i < total; i++) {
        fake_requests[i] = (et_sfz_sample_request){ 5, 0, i, 0, i % 3, 0 };
    }
    atomic_store(&fake_request_count, total);
    const uint32_t slot = attach(5, 0);
    uint32_t seen = 0;
    ETStreamRequest out[128];
    for (int block = 0; block < 40 && seen < total; block++) {
        process(FR);
        uint32_t n;
        while ((n = ETSampleStream_TakeRequests(slot, 5, out, 128)) > 0) {
            for (uint32_t i = 0; i < n; i++, seen++) {
                ET_CHECK_MSG(out[i].page == seen && out[i].sample == seen % 3 && out[i].generation == 5,
                             "request %u: page=%llu sample=%u", seen, (unsigned long long)out[i].page, out[i].sample);
            }
        }
    }
    ET_CHECK_MSG(seen == total, "seen=%u", seen);
    // 1 ブロックに取るのは ET_STREAM_TAKE_CHUNK 件まで。3000 件は 12 ブロックかかる。
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1);
    ET_CHECK(st.requestsTaken == total && st.outstanding == total);
    fakeTeardown();
}

// ページは用意できた順に、1 ブロックに ET_STREAM_PUBLISH_PER_BLOCK 枚まで、描画の合間（process の外）で渡す。
ET_CASE(fake_publish_is_ordered_bounded_and_between_blocks)
{
    fakeSetup();
    const uint32_t slot = attach(5, 0);
    const uint32_t pages = 20;
    for (uint32_t i = 0; i < pages; i++) ET_CHECK(submitOne(slot, 5, i, i % 4, (float)i) == 1);

    process(FR);
    ET_CHECK_MSG(atomic_load(&fake_publish_count) == ET_STREAM_PUBLISH_PER_BLOCK, "count=%d",
                 atomic_load(&fake_publish_count));
    process(FR);
    ET_CHECK(atomic_load(&fake_publish_count) == 2 * ET_STREAM_PUBLISH_PER_BLOCK);
    process(FR);
    ET_CHECK(atomic_load(&fake_publish_count) == (int)pages);
    process(FR);
    ET_CHECK(atomic_load(&fake_publish_count) == (int)pages);

    for (uint32_t i = 0; i < pages; i++) {
        const fake_publish_record *r = &fake_publishes[i];
        ET_CHECK_MSG(r->page == i && r->sample == i % 4 && r->first == (float)i && r->status == ET_OK, "publish %u", i);
        ET_CHECK(r->generation == 5 && r->frames == ET_STREAM_PAGE_FRAMES && r->channels == 1 && r->flags == 0);
        ET_CHECK_MSG(!r->inProcess, "publish %u ran inside et_pipeline_process", i);
    }
    // 描画の最中に stream の関数が呼ばれていない。
    ET_CHECK(atomic_load(&fake_stream_in_process) == 0);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1);
    ET_CHECK(st.pagesPublished == pages && st.maxPublishPerBlock == ET_STREAM_PUBLISH_PER_BLOCK);
    // 渡し終えた置き場は返ってくる（64 枚を超えて借り直せる）。
    for (uint32_t round = 0; round < 5; round++) {
        for (uint32_t i = 0; i < ET_STREAM_POOL_PAGES; i++) ET_CHECK(submitOne(slot, 5, i, 0, 1.0f) == 1);
        ET_CHECK(ETSampleStream_AcquirePage(slot, 5) == NULL);   // 置き場は空
        for (int b = 0; b < ET_STREAM_POOL_PAGES / ET_STREAM_PUBLISH_PER_BLOCK; b++) process(FR);
    }
    fakeTeardown();
}

// slot をまたいでも、全体の 1 ブロックの上限は守られる。
ET_CASE(fake_publish_budget_is_shared_across_slots)
{
    fakeSetup();
    uint32_t a = 99, b = 99;
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, 5, nowRate(), 0, &a) == ET_OK);
    ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID + 1, 6, nowRate(), 0, &b) == ET_OK);
    for (uint32_t i = 0; i < 30; i++) {
        ET_CHECK(submitOne(a, 5, i, 0, 1.0f) == 1);
        ET_CHECK(submitOne(b, 6, i, 1, 2.0f) == 1);
    }
    process(FR);
    ET_CHECK_MSG(atomic_load(&fake_publish_count) == ET_STREAM_PUBLISH_PER_BLOCK, "count=%d", atomic_load(&fake_publish_count));
    // 順番に先頭が回るので、2 つの slot が飢えない。
    for (int k = 0; k < 6; k++) process(FR);
    int fromA = 0, fromB = 0;
    for (int i = 0; i < atomic_load(&fake_publish_count); i++) {
        if (fake_publishes[i].sample == 0) fromA++;
        else fromB++;
    }
    ET_CHECK_MSG(fromA > 0 && fromB > 0, "a=%d b=%d", fromA, fromB);
    fakeTeardown();
}

// 世代の栅。古い世代の要求・ページ・借り方は、どれも engine へ届かない。
ET_CASE(fake_stale_generation_is_rejected)
{
    fakeSetup();
    uint32_t slot = attach(5, 0);
    ETStreamPage *held = ETSampleStream_AcquirePage(slot, 5);
    ET_CHECK(held != NULL);
    ET_CHECK(ETSampleStream_AcquirePage(slot, 4) == NULL);   // 違う世代では借りられない
    ET_CHECK(ETSampleStream_IsCurrent(slot, 5) == 1 && ETSampleStream_IsCurrent(slot, 4) == 0);

    // バンクを読み直した（世代 6）。借りたままのページは確保ごと延ばして畳まれる。
    ET_CHECK(attach(6, 0) == slot);
    ET_CHECK(ETSampleStream_IsCurrent(slot, 5) == 0 && ETSampleStream_IsCurrent(slot, 6) == 1);
    ET_CHECK(ETSampleStream_AcquirePage(slot, 5) == NULL);
    ET_CHECK(ETSampleStream_Reap() == 1);   // 借りたままなので解放は延びている
    const ETStreamRequest old = { 5, 0, 0, 0 };
    ET_CHECK(ETSampleStream_SubmitPage(held, &old, ET_STREAM_PAGE_FRAMES, 1) == 0);
    ET_CHECK(ETSampleStream_Reap() == 0);   // 返ったので畳める
    ETSampleStream_Abandon(slot, 5, 3);     // 古い世代の断念は数えない
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.requestsAbandoned == 0);

    // 今の世代のページでも、要求の世代が古ければ断る（pagesStale に数える）。
    ETStreamPage *page = ETSampleStream_AcquirePage(slot, 6);
    ET_CHECK(page != NULL);
    ET_CHECK(ETSampleStream_SubmitPage(page, &old, ET_STREAM_PAGE_FRAMES, 1) == 0);
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.pagesStale == 1);
    process(FR);
    ET_CHECK(atomic_load(&fake_publish_count) == 0);

    // engine が世代を替えられた（asset を差し替えた）。渡したページは ET_ERR_STATE で返り、stale に数えて置き場へ戻す。
    ET_CHECK(submitOne(slot, 6, 0, 0, 1.0f) == 1);
    atomic_store(&fake_stream_generation, 99);
    process(FR);
    ET_CHECK(atomic_load(&fake_publish_count) == 1 && fake_publishes[0].status == ET_ERR_STATE);
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.pagesPublished == 0 && st.pagesStale == 2);
    for (uint32_t i = 0; i < ET_STREAM_POOL_PAGES; i++) ET_CHECK(ETSampleStream_AcquirePage(slot, 6) != NULL);
    fakeTeardown();
}

ET_CASE(fake_bad_page_arguments_are_rejected)
{
    fakeSetup();
    const uint32_t slot = attach(5, 0);
    ETStreamPage *page = ETSampleStream_AcquirePage(slot, 5);
    ET_CHECK(page != NULL);
    const ETStreamRequest request = { 5, 0, 0, 0 };
    ET_CHECK(ETSampleStream_SubmitPage(page, &request, 0, 1) == 0);
    page = ETSampleStream_AcquirePage(slot, 5);
    ET_CHECK(page != NULL);
    ET_CHECK(ETSampleStream_SubmitPage(page, &request, ET_STREAM_PAGE_FRAMES + 1, 1) == 0);
    page = ETSampleStream_AcquirePage(slot, 5);
    ET_CHECK(page != NULL);
    ET_CHECK(ETSampleStream_SubmitPage(page, &request, 10, 3) == 0);
    page = ETSampleStream_AcquirePage(slot, 5);
    ET_CHECK(page != NULL);
    ET_CHECK(ETSampleStream_SubmitPage(page, NULL, 10, 1) == 0);
    // 返したページは借り直せる（置き場を漏らさない）。
    for (uint32_t i = 0; i < ET_STREAM_POOL_PAGES; i++) ET_CHECK(ETSampleStream_AcquirePage(slot, 5) != NULL);
    ET_CHECK(ETSampleStream_AcquirePage(slot, 5) == NULL);
    fakeTeardown();
}

// resident のページ（flags 1）と 2 チャンネルのページが、そのまま engine へ渡る。
ET_CASE(fake_page_flags_and_channels_pass_through)
{
    fakeSetup();
    const uint32_t slot = attach(5, 0);
    ETStreamPage *page = ETSampleStream_AcquirePage(slot, 5);
    ET_CHECK(page != NULL);
    for (uint32_t i = 0; i < 100 * 2; i++) page->pcm[i] = 0.5f;
    page->flags = 1;
    const ETStreamRequest request = { 5, (uint64_t)1 << 33, 3, 0 };
    ET_CHECK(ETSampleStream_SubmitPage(page, &request, 100, 2) == 1);
    process(FR);
    ET_CHECK(atomic_load(&fake_publish_count) == 1);
    const fake_publish_record *r = &fake_publishes[0];
    ET_CHECK(r->status == ET_OK && r->page == ((uint64_t)1 << 33) && r->sample == 3 && r->frames == 100 &&
             r->channels == 2 && r->flags == 1);
    // control からの直の publish（resident の preload）。
    float pcm[16];
    for (int i = 0; i < 16; i++) pcm[i] = 0.25f;
    ET_CHECK(ETSampleStream_PublishDirect(ENGINE_ID, INSTANCE_ID, 5, 2, 7, pcm, 16, 1, 1) == ET_OK);
    ET_CHECK(fake_publishes[1].flags == 1 && fake_publishes[1].page == 7 && fake_publishes[1].sample == 2);
    ET_CHECK(ETSampleStream_PublishDirect(ENGINE_ID, INSTANCE_ID, 5, 2, 7, pcm, 0, 1, 1) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_PublishDirect(ENGINE_ID, INSTANCE_ID, 5, 2, 7, pcm, 16, 3, 1) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_PublishDirect(ENGINE_ID, INSTANCE_ID, 5, 2, 7, NULL, 16, 1, 1) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_PublishDirect(ENGINE_ID, INSTANCE_ID, 5, 2, 7, pcm, 4097, 1, 1) == ET_ERR_ARGS);
    fakeTeardown();
}

// master bypass のあいだ（AssetUpload.holdOffAudioThread）は engine の instance に触らない。
ET_CASE(fake_bypass_touches_nothing)
{
    fakeSetup();
    fake_requests[0] = (et_sfz_sample_request){ 5, 0, 1, 0, 0, 0 };
    atomic_store(&fake_request_count, 1);
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    ET_CHECK(submitOne(slot, 5, 0, 0, 1.0f) == 1);
    ETPipeline_SetBypass(1);
    for (int i = 0; i < 20; i++) process(1024);
    ET_CHECK(atomic_load(&fake_take_calls) == 0 && atomic_load(&fake_publish_count) == 0 &&
             atomic_load(&fake_prefetch_count) == 0);
    ETPipeline_SetBypass(0);
    process(FR);
    ET_CHECK(atomic_load(&fake_take_calls) > 0 && atomic_load(&fake_publish_count) == 1);
    fakeTeardown();
}

// instance を壊す前に slot を畳む（壊れた instance へ publish しない）。
ET_CASE(fake_destroy_instances_detaches_first)
{
    fakeSetup();
    attach(5, 0);
    ET_CHECK(ETSampleStream_SlotFor(ENGINE_ID, INSTANCE_ID) >= 0);
    const uint32_t ids[1] = { INSTANCE_ID };
    ET_CHECK(ETPipeline_DestroyInstances(ENGINE_ID, ids, 1) == 1);
    ET_CHECK(ETSampleStream_SlotFor(ENGINE_ID, INSTANCE_ID) == -1);
    ET_CHECK(atomic_load(&fake_destroyed) == 1);
    fakeTeardown();
}

// engine を替えたら slot は全部畳まれる。
ET_CASE(fake_set_engine_detaches_all)
{
    fakeSetup();
    attach(5, 0);
    ETPipeline_SetEngine(ENGINE_ID + 1);
    ET_CHECK(ETSampleStream_SlotFor(ENGINE_ID, INSTANCE_ID) == -1);
    fakeTeardown();
}

static void setReady(uint32_t scope, uint32_t planned, uint32_t pending)
{
    fake_readiness = (et_stream_readiness){ 0, scope, 0, 0, planned, pending };
}

// 先読みの手順（上流 audio-processor.js:5054-5130 の Note Player の枝）。
// flags 13（BEGIN|ADMIT|SELECTED_PRESETS）で受け付け、続けて 6（COMMIT|ADMIT）で確定する。窓は 1.5 s。
ET_CASE(fake_forecast_admits_then_commits)
{
    fakeSetup();
    atomic_store(&fake_midi_generation, 3);
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 2, 0);
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    process(1024);   // 21 ms
    ET_CHECK_MSG(atomic_load(&fake_prefetch_count) == 2, "prefetch=%d", atomic_load(&fake_prefetch_count));
    ET_CHECK(fake_prefetches[0].flags == 13 && fake_prefetches[0].count == 0 && fake_prefetches[0].generation == 3 &&
             fake_prefetches[0].window == 72000);
    ET_CHECK(fake_prefetches[1].flags == 6 && fake_prefetches[1].count == 0 && fake_prefetches[1].window == 72000);
    ET_CHECK(!fake_prefetches[0].inProcess && !fake_prefetches[1].inProcess);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1);
    ET_CHECK(st.forecastReady == 1 && st.forecastLimited == 0 && st.readinessScope == ET_STREAM_SCOPE_SELECTED_PRESETS &&
             st.readinessPlanned == 2 && st.readinessPending == 0 && st.forecastErrors == 0);
    // 揃ったあとは、鳴っている声が無ければ何もしない。
    for (int i = 0; i < 100; i++) process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) == 2);
    fakeTeardown();
}

ET_CASE(fake_forecast_refreshes_while_voices_sound)
{
    fakeSetup();
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 1, 0);
    attach(5, ET_STREAM_ATTACH_FORECAST);
    process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) == 2);
    atomic_store(&fake_midi_state, 1);
    // 先読み完了から 0.5 s（24000 フレーム）未満は動かさない。
    for (int i = 0; i < 10; i++) process(1024);   // 10240 フレーム
    ET_CHECK(atomic_load(&fake_prefetch_count) == 2);
    for (int i = 0; i < 20; i++) process(1024);   // 計 30720 フレーム
    ET_CHECK_MSG(atomic_load(&fake_prefetch_count) >= 4, "prefetch=%d", atomic_load(&fake_prefetch_count));
    ET_CHECK(fake_prefetches[2].flags == 13 && fake_prefetches[3].flags == 6);
    fakeTeardown();
}

// 圧（ET_ERR_OOM）に負けたら、窓を 1.5 s → 1 s → 0.25 s と縮めて受け付け直す。
ET_CASE(fake_forecast_shrinks_window_under_pressure)
{
    fakeSetup();
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 1, 0);
    fake_prefetch_script[0] = ET_ERR_OOM;
    fake_prefetch_script[1] = ET_ERR_OOM;
    fake_prefetch_script_count = 2;
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    for (int i = 0; i < 6; i++) process(1024);
    ET_CHECK_MSG(atomic_load(&fake_prefetch_count) == 4, "prefetch=%d", atomic_load(&fake_prefetch_count));
    ET_CHECK(fake_prefetches[0].flags == 13 && fake_prefetches[0].window == 72000 && fake_prefetches[0].status == ET_ERR_OOM);
    ET_CHECK(fake_prefetches[1].flags == 13 && fake_prefetches[1].window == 48000 && fake_prefetches[1].status == ET_ERR_OOM);
    ET_CHECK(fake_prefetches[2].flags == 13 && fake_prefetches[2].window == 12000 && fake_prefetches[2].status == ET_OK);
    ET_CHECK(fake_prefetches[3].flags == 6 && fake_prefetches[3].window == 12000);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1);
    ET_CHECK(st.forecastReady == 1 && st.forecastLimited == 1);
    fakeTeardown();
}

// 3 つの窓が全部断られたら、圧のまま 0.5 s 待って最初の窓からやり直す。
ET_CASE(fake_forecast_gives_up_then_retries)
{
    fakeSetup();
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 1, 0);
    for (int i = 0; i < 3; i++) fake_prefetch_script[i] = ET_ERR_OOM;
    fake_prefetch_script_count = 3;
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    for (int i = 0; i < 6; i++) process(1024);   // 6144 フレーム。3 回断られて止まる
    ET_CHECK(atomic_load(&fake_prefetch_count) == 3);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.forecastLimited == 1 && st.forecastReady == 0);
    for (int i = 0; i < 30; i++) process(1024);  // 0.5 s を過ぎる
    ET_CHECK_MSG(atomic_load(&fake_prefetch_count) >= 5, "prefetch=%d", atomic_load(&fake_prefetch_count));
    ET_CHECK(fake_prefetches[3].flags == 13 && fake_prefetches[3].window == 72000);
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.forecastReady == 1 && st.forecastLimited == 0);
    fakeTeardown();
}

// commit が ET_NEED_SAMPLE（ページの到着待ち）なら予測は残り、次の機会に commit だけをやり直す。
ET_CASE(fake_forecast_commit_waits_for_pages)
{
    fakeSetup();
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 2, 0);
    fake_prefetch_script[0] = ET_OK;             // admit
    fake_prefetch_script[1] = ET_NEED_SAMPLE;    // commit: まだ
    fake_prefetch_script_count = 2;
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) == 2);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.forecastReady == 0 && st.forecastErrors == 0);
    process(1024);
    ET_CHECK_MSG(atomic_load(&fake_prefetch_count) == 3, "prefetch=%d", atomic_load(&fake_prefetch_count));
    ET_CHECK(fake_prefetches[2].flags == 6);   // admit はやり直さない
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.forecastReady == 1);
    fakeTeardown();
}

// 前回の要求を返し終えるまで次の予測へ進まない。供給が諦めた分（Abandon）は数えて先へ進む。
ET_CASE(fake_forecast_waits_for_outstanding_requests)
{
    fakeSetup();
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 1, 0);
    fake_requests[0] = (et_sfz_sample_request){ 5, 0, 0, 0, 0, 0 };
    fake_requests[1] = (et_sfz_sample_request){ 5, 0, 1, 0, 0, 0 };
    atomic_store(&fake_request_count, 2);
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    for (int i = 0; i < 4; i++) process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) == 0);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.outstanding == 2);
    ETStreamRequest out[4];
    ET_CHECK(ETSampleStream_TakeRequests(slot, 5, out, 4) == 2);
    ETSampleStream_Abandon(slot, 5, 1);
    process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) == 0);   // まだ 1 件残っている
    ET_CHECK(submitOne(slot, 5, 1, 1, 1.0f) == 1);
    process(1024);                                       // 渡して 0 件になる
    process(1024);
    ET_CHECK_MSG(atomic_load(&fake_prefetch_count) == 2, "prefetch=%d", atomic_load(&fake_prefetch_count));
    fakeTeardown();
}

// 要求していないページ（作り直しの再送・resident の再送）が先に渡されても、「返し終えた」の数が回り込んで
// 先読みが止まったままにならない（engine_steady_state_allocates_nothing で見つけた）。
ET_CASE(fake_forecast_survives_unrequested_pages)
{
    fakeSetup();
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 1, 0);
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    for (uint32_t i = 0; i < 10; i++) ET_CHECK(submitOne(slot, 5, i, 0, 1.0f) == 1);
    for (int i = 0; i < 4; i++) process(1024);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.pagesPublished == 10 && st.requestsTaken == 0);
    ET_CHECK_MSG(st.outstanding == 0 && atomic_load(&fake_prefetch_count) == 2, "outstanding=%u prefetch=%d",
                 st.outstanding, atomic_load(&fake_prefetch_count));
    fakeTeardown();
}

// asset が ACTIVE になるまで予測しない。generation が替わったら組み直す。
ET_CASE(fake_forecast_follows_asset_and_midi_generation)
{
    fakeSetup();
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 1, 0);
    atomic_store(&fake_asset_state, ET_ASSET_STATE_PREPARING);
    attach(5, ET_STREAM_ATTACH_FORECAST);
    for (int i = 0; i < 5; i++) process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) == 0);
    atomic_store(&fake_asset_state, ET_ASSET_STATE_ACTIVE);
    process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) == 2 && fake_prefetches[0].generation == 0);
    atomic_store(&fake_midi_generation, 9);
    process(1024);
    ET_CHECK_MSG(atomic_load(&fake_prefetch_count) == 4, "prefetch=%d", atomic_load(&fake_prefetch_count));
    ET_CHECK(fake_prefetches[2].flags == 13 && fake_prefetches[2].generation == 9);
    fakeTeardown();
}

// 予測が失敗したら 0.5 s 空けて組み直す（毎ブロック繰り返さない）。
ET_CASE(fake_forecast_error_backs_off)
{
    fakeSetup();
    fake_readiness_status = ET_ERR_STATE;
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    for (int i = 0; i < 20; i++) process(1024);   // 20480 フレーム（0.43 s）
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1);
    ET_CHECK_MSG(st.forecastErrors == 1, "errors=%llu", (unsigned long long)st.forecastErrors);
    for (int i = 0; i < 10; i++) process(1024);
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.forecastErrors == 2);
    fakeTeardown();
}

// 先読みは Note Player だけ。flag の無い slot では prefetch を呼ばない。
ET_CASE(fake_no_forecast_without_flag)
{
    fakeSetup();
    attach(5, 0);
    for (int i = 0; i < 10; i++) process(1024);
    ET_CHECK(atomic_load(&fake_prefetch_count) == 0);
    fakeTeardown();
}

// 要求を取る側が ET_ERR_OOM（engine の溜め場が溢れた）を返したら数え、積まない。
ET_CASE(fake_request_overflow_is_counted)
{
    fakeSetup();
    const uint32_t slot = attach(5, 0);
    fake_take_status = ET_ERR_OOM;
    process(FR);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.requestOverflows == 1 && st.requestsTaken == 0);
    fakeTeardown();
}

// 数え方そのものが効いていること（効いていなければ「確保 0」は何も言っていない）。
ET_CASE(fake_malloc_counter_sees_allocations)
{
#if !ET_SS_WRAP_MALLOC
    return;
#else
    // 最適化で確保ごと消されないよう、関数ポインタ越しに呼ぶ（-O1 の tsan プリセットでは直に呼ぶと畳まれる）。
    void *(*volatile mallocFn)(size_t) = malloc;
    void *(*volatile callocFn)(size_t, size_t) = calloc;
    void *(*volatile reallocFn)(void *, size_t) = realloc;
    void *(*volatile alignedFn)(size_t, size_t) = aligned_alloc;
    COUNT_BEGIN();
    void *a = mallocFn(32);
    void *b = callocFn(4, 8);
    void *c = reallocFn(a, 64);
    void *d = alignedFn(64, 128);
    const unsigned long n = COUNT_END();
    free(b);
    free(c);
    free(d);
    ET_CHECK_MSG(n == 4, "counted %lu of 4", n);
#endif
}

// steady state の確保は 0。音のスレッド（描画の前後と先読み）も供給の呼び出しも。
ET_CASE(fake_steady_state_allocates_nothing)
{
#if !ET_SS_WRAP_MALLOC
    return;
#else
    fakeSetup();
    atomic_store(&fake_midi_generation, 3);
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 2, 0);
    atomic_store(&fake_midi_state, 1);
    const uint32_t slot = attach(5, ET_STREAM_ATTACH_FORECAST);
    for (uint32_t i = 0; i < 2000; i++) fake_requests[i] = (et_sfz_sample_request){ 5, 0, i, 0, i % 5, 0 };
    atomic_store(&fake_request_count, 2000);
    ETStreamRequest requests[64];
    ETStreamStatus st;
    COUNT_BEGIN();
    for (int block = 0; block < 300; block++) {
        ET_CHECK(ETPipeline_Process(2, 1024, 0.0) == ET_OK);
        const uint32_t n = ETSampleStream_TakeRequests(slot, 5, requests, 64);
        for (uint32_t i = 0; i < n; i++) {
            ETStreamPage *page = ETSampleStream_AcquirePage(slot, 5);
            if (page == NULL) { ETSampleStream_Abandon(slot, 5, 1); continue; }
            page->pcm[0] = 1.0f;
            page->flags = (i & 7u) == 0 ? 1u : 0u;
            if (!ETSampleStream_SubmitPage(page, &requests[i], 256, 1)) ETSampleStream_ReleasePage(page);
        }
        (void)ETSampleStream_IsCurrent(slot, 5);
        (void)ETSampleStream_Snapshot(slot, &st);
    }
    const unsigned long allocs = COUNT_END();
    ET_CHECK_MSG(allocs == 0, "%lu allocations", allocs);
    ET_CHECK(ETSampleStream_Snapshot(slot, &st) == 1 && st.pagesPublished > 100 && st.forecastRuns > 5);
    fakeTeardown();
#endif
}

#endif /* !ET_SS_ENGINE */

// MARK: - thread（音・control・供給を同時に）

#ifndef ET_SS_ENGINE

typedef struct {
    _Atomic int stop;
    _Atomic uint64_t generation;
    uint32_t slot;
    _Atomic uint32_t served;
} ThreadRig;

static void *renderThread(void *arg)
{
    ThreadRig *rig = (ThreadRig *)arg;
    for (int i = 0; i < 6000; i++) {
        (void)ETPipeline_Process(2, 256, 0.0);
        if ((i & 63) == 0) {
            const struct timespec t = {0, 50000};
            nanosleep(&t, NULL);
        }
    }
    atomic_store(&rig->stop, 1);
    return NULL;
}

static void *supplyThread(void *arg)
{
    ThreadRig *rig = (ThreadRig *)arg;
    ETStreamRequest requests[64];
    while (!atomic_load(&rig->stop)) {
        const uint64_t generation = atomic_load(&rig->generation);
        const uint32_t n = ETSampleStream_TakeRequests(rig->slot, generation, requests, 64);
        for (uint32_t i = 0; i < n; i++) {
            ETStreamPage *page = ETSampleStream_AcquirePage(rig->slot, generation);
            if (page == NULL) { ETSampleStream_Abandon(rig->slot, generation, 1); continue; }
            for (uint32_t k = 0; k < 128; k++) page->pcm[k] = (float)requests[i].page;
            if (ETSampleStream_SubmitPage(page, &requests[i], 128, 1)) atomic_fetch_add(&rig->served, 1);
        }
        if (n == 0) {
            const struct timespec t = {0, 20000};
            nanosleep(&t, NULL);
        }
    }
    return NULL;
}

ET_CASE(thread_render_supply_and_reattach)
{
    fakeSetup();
    ThreadRig rig;
    memset(&rig, 0, sizeof rig);
    atomic_store(&rig.generation, 1);
    rig.slot = attach(1, ET_STREAM_ATTACH_FORECAST);
    const uint32_t total = 4000;
    for (uint32_t i = 0; i < total; i++) fake_requests[i] = (et_sfz_sample_request){ 0, 0, i, 0, i % 7, 0 };
    // 世代は Attach のたびに替わる。fake が配る要求の世代は 1 のまま（古い世代として扱われる）。
    for (uint32_t i = 0; i < total; i++) fake_requests[i].generation_low = 1;
    atomic_store(&fake_request_count, total);
    atomic_store(&fake_midi_state, 1);
    setReady(ET_STREAM_SCOPE_SELECTED_PRESETS, 1, 0);
    pthread_t render, supply;
    ET_CHECK(pthread_create(&render, NULL, renderThread, &rig) == 0);
    ET_CHECK(pthread_create(&supply, NULL, supplyThread, &rig) == 0);
    // control: 動いているあいだに世代を替えて読み直し、最後に畳む。
    uint64_t generation = 1;
    for (int round = 0; round < 6 && !atomic_load(&rig.stop); round++) {
        const struct timespec t = {0, 3000000};
        nanosleep(&t, NULL);
        generation++;
        uint32_t slot = 0;
        ET_CHECK(ETSampleStream_Attach(ENGINE_ID, INSTANCE_ID, generation, nowRate(), ET_STREAM_ATTACH_FORECAST, &slot) == ET_OK);
        ET_CHECK(slot == rig.slot);
        atomic_store(&rig.generation, generation);
        (void)ETSampleStream_Reap();
    }
    pthread_join(render, NULL);
    pthread_join(supply, NULL);
    ET_CHECK(atomic_load(&fake_stream_in_process) == 0);
    for (int i = 0; i < atomic_load(&fake_publish_count) && i < FAKE_STREAM_LOG; i++) ET_CHECK(!fake_publishes[i].inProcess);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(rig.slot, &st) == 1);
    ETSampleStream_DetachAll();
    ET_CHECK(ETSampleStream_Reap() == 0);
    fakeTeardown();
}

// 畳んでいる最中にも、音のスレッドは止まらず、解放後のメモリを触らない（ASan / TSan で見る）。
ET_CASE(thread_detach_while_rendering)
{
    fakeSetup();
    ThreadRig rig;
    memset(&rig, 0, sizeof rig);
    pthread_t render;
    for (uint32_t i = 0; i < 4000; i++) fake_requests[i] = (et_sfz_sample_request){ 1, 0, i, 0, i % 7, 0 };
    atomic_store(&fake_request_count, 4000);
    uint64_t generation = 1;
    atomic_store(&rig.generation, generation);
    rig.slot = attach(generation, 0);
    ET_CHECK(pthread_create(&render, NULL, renderThread, &rig) == 0);
    for (int round = 0; round < 30; round++) {
        for (uint32_t i = 0; i < 8; i++) (void)submitOne(rig.slot, generation, i, 0, 1.0f);
        ETSampleStream_Detach(ENGINE_ID, INSTANCE_ID);
        (void)ETSampleStream_Reap();
        generation++;
        rig.slot = attach(generation, 0);
        atomic_store(&rig.generation, generation);
    }
    pthread_join(render, NULL);
    fakeTeardown();
}

// 置き場が満杯でも、供給は要求を捨てない（ETSFZPageSource.acquire と同じ待ち方）。
// 音のスレッドが止まっている間は publish が進まず、64 枚で置き場が尽きる。
// 再開すれば空くので、全ての要求がページになる。
typedef struct {
    ThreadRig base;
    uint32_t total;
    _Atomic uint32_t acquireMisses;
    _Atomic int giveUp;
} WaitRig;

static void *patientSupplyThread(void *arg)
{
    WaitRig *rig = (WaitRig *)arg;
    ETStreamRequest requests[64];
    uint32_t handled = 0;
    const uint64_t generation = atomic_load(&rig->base.generation);
    while (handled < rig->total && !atomic_load(&rig->giveUp)) {
        const uint32_t n = ETSampleStream_TakeRequests(rig->base.slot, generation, requests, 64);
        if (n == 0) {
            const struct timespec t = {0, 100000};
            nanosleep(&t, NULL);
            continue;
        }
        for (uint32_t i = 0; i < n; i++) {
            ETStreamPage *page = NULL;
            while ((page = ETSampleStream_AcquirePage(rig->base.slot, generation)) == NULL) {
                atomic_fetch_add(&rig->acquireMisses, 1);
                if (atomic_load(&rig->giveUp) || !ETSampleStream_IsCurrent(rig->base.slot, generation)) return NULL;
                const struct timespec t = {0, 200000};
                nanosleep(&t, NULL);
            }
            for (uint32_t k = 0; k < 128; k++) page->pcm[k] = (float)requests[i].page;
            if (ETSampleStream_SubmitPage(page, &requests[i], 128, 1)) atomic_fetch_add(&rig->base.served, 1);
            handled++;
        }
    }
    return NULL;
}

ET_CASE(thread_pool_exhaustion_is_waited_out)
{
    fakeSetup();
    static WaitRig rig;
    memset(&rig, 0, sizeof rig);
    rig.total = 300;                         // 置き場（64 枚）より多い
    const uint64_t generation = ETSampleStream_NextGeneration();
    atomic_store(&rig.base.generation, generation);
    rig.base.slot = attach(generation, 0);
    for (uint32_t i = 0; i < rig.total; i++) {
        fake_requests[i] = (et_sfz_sample_request){ (uint32_t)generation, 0, i, 0, i % 3, 0 };
    }
    atomic_store(&fake_request_count, rig.total);
    // 音のスレッドで要求を輪へ積む（ここまでは音が動いている）。その後、音は止まる。
    for (int i = 0; i < 4; i++) process(FR);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(rig.base.slot, &st) == 1 && st.requestsTaken == rig.total);

    pthread_t supply;
    ET_CHECK(pthread_create(&supply, NULL, patientSupplyThread, &rig) == 0);
    // 音が止まったまま、置き場が尽きるまで待つ。
    for (int i = 0; i < 400 && atomic_load(&rig.base.served) < ET_STREAM_POOL_PAGES; i++) {
        const struct timespec t = {0, 1000000};
        nanosleep(&t, NULL);
    }
    ET_CHECK_MSG(atomic_load(&rig.base.served) == ET_STREAM_POOL_PAGES, "served=%u", atomic_load(&rig.base.served));
    // 少し待っても進まず（捨てもせず）、置き場を借りに行き続ける。
    const struct timespec settle = {0, 30000000};
    nanosleep(&settle, NULL);
    ET_CHECK(atomic_load(&rig.base.served) == ET_STREAM_POOL_PAGES);
    ET_CHECK(atomic_load(&rig.acquireMisses) > 0);
    ET_CHECK(ETSampleStream_Snapshot(rig.base.slot, &st) == 1);
    ET_CHECK_MSG(st.requestsAbandoned == 0 && st.requestsFailed == 0 && st.failed == 0, "nothing is dropped while waiting");
    ET_CHECK(atomic_load(&fake_publish_count) == 0);

    // 音が戻る。全部のページが engine へ届く。
    for (int i = 0; i < 20000 && atomic_load(&fake_publish_count) < (int)rig.total; i++) {
        process(FR);
        if ((i & 15) == 0) {
            const struct timespec t = {0, 100000};
            nanosleep(&t, NULL);
        }
    }
    atomic_store(&rig.giveUp, 1);
    pthread_join(supply, NULL);
    ET_CHECK_MSG(atomic_load(&fake_publish_count) == (int)rig.total, "published=%d", atomic_load(&fake_publish_count));
    ET_CHECK(atomic_load(&rig.base.served) == rig.total);
    ET_CHECK(ETSampleStream_Snapshot(rig.base.slot, &st) == 1);
    ET_CHECK(st.pagesPublished == rig.total && st.requestsAbandoned == 0 && st.outstanding == 0);
    // 届いた順は要求の順（欠けも重なりも無い）。
    for (uint32_t i = 0; i < rig.total && i < FAKE_STREAM_LOG; i++) {
        ET_CHECK_MSG(fake_publishes[i].page == i && fake_publishes[i].sample == i % 3, "publish %u", i);
    }
    fakeTeardown();
}

#endif /* !ET_SS_ENGINE */

// MARK: - engine（本物の engine と kSf2HostFixture）

#ifdef ET_SS_ENGINE

#ifndef ET_SF2_FIXTURE_HEADER
#error "ET_SF2_FIXTURE_HEADER (soundfont_player/sf2_fixture.h) is required"
#endif

// 上流の C++ ヘッダ（kSf2HostFixture が std::array の初期化子）から、数字を拾って見本にする。
static uint8_t *loadHostFixture(uint32_t *size)
{
    FILE *f = fopen(ET_SF2_FIXTURE_HEADER, "rb");
    ET_CHECK_MSG(f != NULL, "cannot open %s", ET_SF2_FIXTURE_HEADER);
    fseek(f, 0, SEEK_END);
    const long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *text = (char *)malloc((size_t)n + 1);
    ET_CHECK(text != NULL && fread(text, 1, (size_t)n, f) == (size_t)n);
    text[n] = 0;
    fclose(f);
    const char *at = strstr(text, "kSf2HostFixture{");
    ET_CHECK(at != NULL);
    at += strlen("kSf2HostFixture{");
    uint8_t *bytes = (uint8_t *)malloc(1 << 16);
    ET_CHECK(bytes != NULL);
    uint32_t count = 0;
    while (*at != '}' && *at != 0) {
        if (*at >= '0' && *at <= '9') {
            unsigned v = 0;
            while (*at >= '0' && *at <= '9') v = v * 10u + (unsigned)(*at++ - '0');
            ET_CHECK(v < 256 && count < (1 << 16));
            bytes[count++] = (uint8_t)v;
        } else {
            at++;
        }
    }
    free(text);
    ET_CHECK_MSG(count == 5024, "fixture has %u bytes", count);
    *size = count;
    return bytes;
}

// 上流の allocation guard（Debug の engine に入っている）。C から名前で引く。
// Mach-O（Darwin）のシンボルは先頭にもう 1 つ下線が付く。ELF はそのまま。
#ifdef __APPLE__
#define ET_ITANIUM(name) "_" name
#else
#define ET_ITANIUM(name) name
#endif
extern void ets_guard_begin(void) __asm__(ET_ITANIUM("_ZN8effetune16allocation_guard5beginEv"));
extern void ets_guard_end(void) __asm__(ET_ITANIUM("_ZN8effetune16allocation_guard3endEv"));
extern void ets_guard_abort(int) __asm__(ET_ITANIUM("_ZN8effetune16allocation_guard29setAbortOnViolationForTestingEb"));
extern uint32_t ets_guard_violations(void) __asm__(ET_ITANIUM("_ZN8effetune16allocation_guard14violationCountEv"));

enum { RATE_HZ = 48000, EFR = 128, CHANNELS = 2, GENERATION = 11 };

typedef struct {
    et_engine engine;
    et_instance instrument;
    uint32_t slot;
    float *bus;
    uint32_t clock;
    uint32_t bytes;
    uint8_t *fixture;
} Rig;

static void rigCreate(Rig *g, int forecast, int residentPage0)
{
    memset(g, 0, sizeof *g);
    g->engine = et_engine_create();
    ET_CHECK(g->engine != 0);
    ET_CHECK(et_engine_prepare(g->engine, (float)RATE_HZ, 4, EFR, 0) == ET_OK);
    ETPipeline_SetEngine(g->engine);
    g->instrument = et_instance_create(g->engine, "SoundFontPlayerPlugin");
    ET_CHECK(g->instrument != 0);
    g->fixture = loadHostFixture(&g->bytes);
    uint64_t additional = 0;
    ET_CHECK(et_sample_player_preparation_bytes(g->fixture, g->bytes, g->bytes, ET_ASSET_F32_MULTICH, (float)RATE_HZ,
                                                CHANNELS, EFR, 0.0, &additional, ET_SAMPLE_PLAYER_MAIN) == ET_OK);
    const uint32_t footprint = g->bytes + (uint32_t)additional;
    uint8_t *payload = et_instance_asset_begin_ptr(g->engine, g->instrument, 0, 1, (g->bytes - 32u) / 4u, 0, 0, 1, 0, 0,
                                                   CHANNELS, footprint, g->bytes, 0.0);
    ET_CHECK(payload != NULL);
    memcpy(payload, g->fixture, g->bytes);
    ET_CHECK(et_instance_asset_commit(g->engine, g->instrument, 0, g->bytes, ET_ASSET_F32_MULTICH) == ET_OK);
    ET_CHECK(ETSampleStream_Attach(g->engine, g->instrument, GENERATION, RATE_HZ,
                                   forecast ? ET_STREAM_ATTACH_FORECAST : 0, &g->slot) == ET_OK);
    if (residentPage0) {
        float page[ET_STREAM_PAGE_FRAMES];
        for (int i = 0; i < ET_STREAM_PAGE_FRAMES; i++) page[i] = 0.25f;
        ET_CHECK(ETSampleStream_PublishDirect(g->engine, g->instrument, GENERATION, 0, 0, page,
                                              ET_STREAM_PAGE_FRAMES, 1, 1) == ET_OK);
    }
    ET_CHECK(et_instance_asset_state(g->engine, g->instrument, 0) == ET_ASSET_STATE_ACTIVE);
    ET_CHECK(et_instance_set_midi_events(g->engine, g->instrument, NULL, 0, 7, ET_MIDI_RESET) == ET_OK);
    const ETPipeNode node = { .instance = g->instrument, .enabled = 1, .sectionGate = 1,
                              .channelSpec = ET_CHANNEL_ALL };
    ETPipeline_Publish(&node, 1);
    ETPipeline_ApplyPending();
    ET_CHECK_MSG(ETPipeline_LastStatus() == ET_OK, "configure=%d", ETPipeline_LastStatus());
    g->bus = ETPipeline_MainBus();
    ET_CHECK(g->bus != NULL);
}

static void rigDestroy(Rig *g)
{
    ETSampleStream_DetachAll();
    ETSampleStream_Reap();
    ETPipeline_SetEngine(0);
    ETSampleStream_ResetGenerationsForTesting();
    et_engine_destroy(g->engine);
    free(g->fixture);
}

// 1 ブロック描画する。note があれば先頭で鳴らす。戻りはバスの絶対値の最大。
static float renderBlock(Rig *g, const et_midi_event *events, uint32_t count, int *status)
{
    memset(g->bus, 0, sizeof(float) * CHANNELS * EFR);
    ET_CHECK(et_instance_set_midi_clock(g->engine, g->instrument, g->clock, 0, 7, ET_MIDI_CLOCK_RUNNING) == ET_OK);
    ET_CHECK(et_instance_set_midi_events(g->engine, g->instrument, events, count, 7, 0) == ET_OK);
    *status = ETPipeline_Process(CHANNELS, EFR, (double)g->clock / RATE_HZ);
    g->clock += EFR;
    float peak = 0;
    for (uint32_t i = 0; i < CHANNELS * EFR; i++) if (fabsf(g->bus[i]) > peak) peak = fabsf(g->bus[i]);
    return peak;
}

static const et_midi_event noteOn = { 0, 0x90u | (60u << 8u) | (127u << 16u), 1u, 0u, 0u, 0u };

static void fillConstant(ETStreamPage *page) { for (int i = 0; i < ET_STREAM_PAGE_FRAMES; i++) page->pcm[i] = 0.25f; }

// 要求に応えて 0.25 の定数ページを返す供給（serve は page 番号を値にするので、音の確認用にこちらを使う）。
static uint32_t serveConstant(Rig *g)
{
    ETStreamRequest requests[64];
    uint32_t n, served = 0;
    while ((n = ETSampleStream_TakeRequests(g->slot, GENERATION, requests, 64)) > 0) {
        for (uint32_t i = 0; i < n; i++) {
            ETStreamPage *page = ETSampleStream_AcquirePage(g->slot, GENERATION);
            if (page == NULL) { ETSampleStream_Abandon(g->slot, GENERATION, 1); continue; }
            fillConstant(page);
            ET_CHECK(ETSampleStream_SubmitPage(page, &requests[i], ET_STREAM_PAGE_FRAMES, 1) == 1);
            served++;
        }
    }
    return served;
}

// resident の先頭ページを control が渡し、あとは描画の合間のページで鳴る。
ET_CASE(engine_sf2_renders_non_silent)
{
    Rig g;
    rigCreate(&g, 0, 1);
    int status = 0;
    float peak = renderBlock(&g, &noteOn, 1, &status);
    ET_CHECK(status == ET_OK);
    float loudest = peak;
    for (int block = 0; block < 400; block++) {
        peak = renderBlock(&g, NULL, 0, &status);
        ET_CHECK_MSG(status == ET_OK, "process=%d at %d", status, block);
        if (peak > loudest) loudest = peak;
        serveConstant(&g);
    }
    if (getenv("ET_SS_VERBOSE")) { ETStreamStatus v; ETSampleStream_Snapshot(g.slot, &v); fprintf(stderr, "[renders] loudest=%.4f taken=%llu pub=%llu err=%llu stale=%llu\n", loudest, (unsigned long long)v.requestsTaken, (unsigned long long)v.pagesPublished, (unsigned long long)v.publishErrors, (unsigned long long)v.pagesStale); }
    ET_CHECK_MSG(loudest > 0.01f, "silent (peak %.6f)", loudest);
    ET_CHECK((et_instance_asset_state(g.engine, g.instrument, 0) & 255u) == ET_ASSET_STATE_ACTIVE);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(g.slot, &st) == 1);
    ET_CHECK_MSG(st.publishErrors == 0, "publishErrors=%llu", (unsigned long long)st.publishErrors);
    rigDestroy(&g);
}

// ページを渡さなければ、鳴らずに音が落ちるだけで、instance は ERROR にならず、runtime event が立つ。
ET_CASE(engine_withheld_page_drops_note_without_error)
{
    Rig g;
    rigCreate(&g, 0, 0);
    int status = 0;
    float loudest = renderBlock(&g, &noteOn, 1, &status);
    ET_CHECK(status == ET_OK);
    for (int block = 0; block < 400; block++) {
        const float peak = renderBlock(&g, NULL, 0, &status);
        ET_CHECK_MSG(status == ET_OK, "process=%d at %d", status, block);
        if (peak > loudest) loudest = peak;
        // 要求は受け取る（輪に溜まる）が、ページは返さない。
    }
    if (getenv("ET_SS_VERBOSE")) fprintf(stderr, "[withheld] loudest=%.6f\n", loudest);
    ET_CHECK_MSG(loudest <= 1e-6f, "audible without a page (peak %.6f)", loudest);
    ET_CHECK((et_instance_asset_state(g.engine, g.instrument, 0) & 255u) == ET_ASSET_STATE_ACTIVE);
    et_runtime_event_state ev;
    memset(&ev, 0, sizeof ev);
    ET_CHECK(et_instance_runtime_event(g.engine, g.instrument, &ev) == ET_OK);
    ET_CHECK_MSG(ev.generation > 0 && ev.cause == 1, "runtime event generation=%u latched=%u cause=%u", ev.generation,
                 ev.latched, ev.cause);
    ETStreamStatus st;
    ET_CHECK(ETSampleStream_Snapshot(g.slot, &st) == 1);
    if (getenv("ET_SS_VERBOSE")) fprintf(stderr, "[withheld] taken=%llu ev gen=%u latched=%u cause=%u\n", (unsigned long long)st.requestsTaken, ev.generation, ev.latched, ev.cause);
    ET_CHECK_MSG(st.requestsTaken > 0, "engine asked for no page");
    // 遅れてページが届いたら、次の音から鳴る（event は解ける）。
    ET_CHECK(serveConstant(&g) > 0);
    for (int block = 0; block < 4; block++) renderBlock(&g, NULL, 0, &status);
    float after = 0;
    after = renderBlock(&g, &noteOn, 1, &status);
    for (int block = 0; block < 400; block++) {
        const float peak = renderBlock(&g, NULL, 0, &status);
        if (peak > after) after = peak;
        serveConstant(&g);
    }
    if (getenv("ET_SS_VERBOSE")) fprintf(stderr, "[withheld] after=%.4f\n", after);
    ET_CHECK_MSG(after > 0.01f, "still silent after the page arrived (peak %.6f)", after);
    rigDestroy(&g);
}

// Note Player の先読みが、本物の engine で SELECTED_PRESETS の先頭ページを揃えて完了する。
ET_CASE(engine_forecast_completes)
{
    Rig g;
    rigCreate(&g, 1, 0);
    int status = 0;
    ETStreamStatus st;
    int ready = 0;
    for (int block = 0; block < 2000 && !ready; block++) {
        renderBlock(&g, NULL, 0, &status);
        ET_CHECK(status == ET_OK);
        serveConstant(&g);
        ET_CHECK(ETSampleStream_Snapshot(g.slot, &st) == 1);
        ready = st.forecastReady;
    }
    ET_CHECK_MSG(ready, "forecast never completed: runs=%llu errors=%llu scope=%u planned=%u pending=%u",
                 (unsigned long long)st.forecastRuns, (unsigned long long)st.forecastErrors, st.readinessScope,
                 st.readinessPlanned, st.readinessPending);
    if (getenv("ET_SS_VERBOSE")) fprintf(stderr, "[forecast] runs=%llu taken=%llu pub=%llu planned=%u scope=%u\n", (unsigned long long)st.forecastRuns, (unsigned long long)st.requestsTaken, (unsigned long long)st.pagesPublished, st.readinessPlanned, st.readinessScope);
    ET_CHECK(st.readinessScope == ET_STREAM_SCOPE_SELECTED_PRESETS && st.readinessPending == 0 && st.forecastErrors == 0);
    ET_CHECK(st.pagesPublished > 0 || st.readinessPlanned == 0);
    rigDestroy(&g);
}

// 描画の前後と供給の確保が 0。上流の allocation guard を、ETPipeline_Process の全体と供給の呼び出しにかぶせて数える。
// 二つの窓で測る。
//   cold    最初の音から。要求が出て、ページが初めて publish され、先読みが初めて回る
//           （キャッシュがまだ空なので、確保が起きるならここ）。
//   steady  ページがそろったあと。要求済みのページを作り直して渡し続け（publish の経路）、音も鳴らし直す。
// どちらも guard に数えられた確保（operator new / malloc）が 0。試験が空振りでないことも、窓ごとの
// 数（要求・publish・先読み）で確かめる。
typedef struct {
    ETStreamRequest seen[16];
    uint32_t seenCount;
    uint32_t served;
} Serve;

static void guardedBlock(Rig *g, const et_midi_event *note, int *status)
{
    memset(g->bus, 0, sizeof(float) * CHANNELS * EFR);
    ET_CHECK(et_instance_set_midi_clock(g->engine, g->instrument, g->clock, 0, 7, ET_MIDI_CLOCK_RUNNING) == ET_OK);
    ET_CHECK(et_instance_set_midi_events(g->engine, g->instrument, note, note != NULL ? 1u : 0u, 7, 0) == ET_OK);
    ets_guard_begin();
    *status = ETPipeline_Process(CHANNELS, EFR, (double)g->clock / RATE_HZ);
    ets_guard_end();
    g->clock += EFR;
}

// 供給側の呼び出し一式（TakeRequests / AcquirePage / SubmitPage / Abandon / Snapshot）を guard の下で。
// replay が 1 なら、要求が無くても覚えている要求のページを作り直して渡す（publish の経路を回し続ける）。
static void guardedSupply(Rig *g, Serve *s, int replay)
{
    ETStreamRequest requests[64];
    ETStreamStatus st;
    ets_guard_begin();
    uint32_t n = ETSampleStream_TakeRequests(g->slot, GENERATION, requests, 64);
    for (uint32_t i = 0; i < n; i++) {
        if (s->seenCount < 16) s->seen[s->seenCount++] = requests[i];
        ETStreamPage *page = ETSampleStream_AcquirePage(g->slot, GENERATION);
        if (page == NULL) { ETSampleStream_Abandon(g->slot, GENERATION, 1); continue; }
        fillConstant(page);
        if (ETSampleStream_SubmitPage(page, &requests[i], ET_STREAM_PAGE_FRAMES, 1)) s->served++;
        else ETSampleStream_ReleasePage(page);
    }
    if (replay) {
        for (uint32_t i = 0; i < s->seenCount; i++) {
            ETStreamPage *page = ETSampleStream_AcquirePage(g->slot, GENERATION);
            if (page == NULL) break;
            fillConstant(page);
            if (ETSampleStream_SubmitPage(page, &s->seen[i], ET_STREAM_PAGE_FRAMES, 1)) s->served++;
            else ETSampleStream_ReleasePage(page);
        }
    }
    (void)ETSampleStream_IsCurrent(g->slot, GENERATION);
    (void)ETSampleStream_Snapshot(g->slot, &st);
    ets_guard_end();
}

ET_CASE(engine_steady_state_allocates_nothing)
{
    Rig g;
    rigCreate(&g, 1, 0);
    ets_guard_abort(0);
    const uint32_t before = ets_guard_violations();
    int status = 0;
    Serve serve;
    memset(&serve, 0, sizeof serve);
    ETStreamStatus s0, s1, s2;
    ET_CHECK(ETSampleStream_Snapshot(g.slot, &s0) == 1);

    // cold
    float coldPeak = 0;
    for (int block = 0; block < 400; block++) {
        guardedBlock(&g, (block % 100) == 0 ? &noteOn : NULL, &status);
        ET_CHECK_MSG(status == ET_OK, "process=%d at cold %d", status, block);
        for (uint32_t i = 0; i < CHANNELS * EFR; i++) if (fabsf(g.bus[i]) > coldPeak) coldPeak = fabsf(g.bus[i]);
        guardedSupply(&g, &serve, 0);
    }
    const uint32_t coldViolations = ets_guard_violations() - before;
    ET_CHECK(ETSampleStream_Snapshot(g.slot, &s1) == 1);
    if (getenv("ET_SS_VERBOSE")) {
        fprintf(stderr, "[cold] peak=%.4f runs=%llu taken=%llu pub=%llu served=%u violations=%u" "\n", coldPeak,
                (unsigned long long)s1.forecastRuns, (unsigned long long)s1.requestsTaken,
                (unsigned long long)s1.pagesPublished, serve.served, coldViolations);
    }
    ET_CHECK_MSG(coldViolations == 0, "%u allocations while the first pages stream in", coldViolations);
    ET_CHECK_MSG(s1.requestsTaken > 0 && s1.pagesPublished > 0 && s1.forecastRuns > s0.forecastRuns && coldPeak > 0.01f,
                 "cold window did nothing (taken %llu published %llu runs %llu peak %.4f)",
                 (unsigned long long)s1.requestsTaken, (unsigned long long)s1.pagesPublished,
                 (unsigned long long)s1.forecastRuns, coldPeak);

    // steady
    for (int block = 0; block < 600; block++) {
        guardedBlock(&g, (block % 100) == 0 ? &noteOn : NULL, &status);
        ET_CHECK_MSG(status == ET_OK, "process=%d at steady %d", status, block);
        guardedSupply(&g, &serve, 1);
    }
    const uint32_t violations = ets_guard_violations() - before;
    ET_CHECK(ETSampleStream_Snapshot(g.slot, &s2) == 1);
    if (getenv("ET_SS_VERBOSE")) {
        fprintf(stderr, "[steady] runs=%llu taken=%llu pub=%llu served=%u errors=%llu violations=%u" "\n",
                (unsigned long long)s2.forecastRuns, (unsigned long long)s2.requestsTaken,
                (unsigned long long)s2.pagesPublished, serve.served, (unsigned long long)s2.publishErrors, violations);
    }
    ET_CHECK_MSG(violations == 0, "%u allocations in steady state", violations);
    ET_CHECK_MSG(s2.pagesPublished >= s1.pagesPublished + 100 && s2.forecastRuns > s1.forecastRuns && s2.publishErrors == 0,
                 "steady window did nothing (published %llu -> %llu, runs %llu -> %llu, errors %llu)",
                 (unsigned long long)s1.pagesPublished, (unsigned long long)s2.pagesPublished,
                 (unsigned long long)s1.forecastRuns, (unsigned long long)s2.forecastRuns,
                 (unsigned long long)s2.publishErrors);
    ET_CHECK((et_instance_asset_state(g.engine, g.instrument, 0) & 255u) == ET_ASSET_STATE_ACTIVE);
    ets_guard_abort(1);
    rigDestroy(&g);
}

// 数え方そのものが効いていること。guard の下で malloc を呼んだら数えに入る（入らなければ「確保 0」は何も言っていない）。
ET_CASE(engine_guard_counts_allocations)
{
    void *(*volatile mallocFn)(size_t) = malloc;
    ets_guard_abort(0);
    const uint32_t before = ets_guard_violations();
    void *outside = mallocFn(16);          // guard の外は数えない
    ET_CHECK(ets_guard_violations() == before);
    ets_guard_begin();
    void *inside = mallocFn(16);
    ets_guard_end();
    ET_CHECK_MSG(ets_guard_violations() == before + 1, "guard counted %u", ets_guard_violations() - before);
    free(outside);
    free(inside);
    ets_guard_abort(1);
}

// 資産を ERROR にしない・古い世代は engine が断る（ET_ERR_STATE）。
ET_CASE(engine_stale_generation_is_refused_by_engine)
{
    Rig g;
    rigCreate(&g, 0, 0);
    float page[ET_STREAM_PAGE_FRAMES];
    for (int i = 0; i < ET_STREAM_PAGE_FRAMES; i++) page[i] = 0.1f;
    ET_CHECK(ETSampleStream_PublishDirect(g.engine, g.instrument, GENERATION + 1, 0, 0, page, ET_STREAM_PAGE_FRAMES, 1, 1) == ET_ERR_STATE);
    ET_CHECK(ETSampleStream_PublishDirect(g.engine, g.instrument, GENERATION, 0, 0, page, ET_STREAM_PAGE_FRAMES, 1, 1) == ET_OK);
    ET_CHECK((et_instance_asset_state(g.engine, g.instrument, 0) & 255u) == ET_ASSET_STATE_ACTIVE);
    rigDestroy(&g);
}

// 取り付け直す（世代 12）。engine は別の世代を configure できない（ET_ERR_STATE）ので、読み直しは
// 新しい asset の commit を挟む。そのとき slot は古い世代の借りを持ち越さない。
ET_CASE(engine_reattach_requires_new_asset)
{
    Rig g;
    rigCreate(&g, 0, 0);
    uint32_t slot = 0;
    ET_CHECK(ETSampleStream_Attach(g.engine, g.instrument, GENERATION + 1, RATE_HZ, 0, &slot) == ET_ERR_STATE);
    // 失敗しても、いまの slot は生きている（configure の前に畳まない）。
    ET_CHECK_MSG(ETSampleStream_SlotFor(g.engine, g.instrument) >= 0, "failed re-attach dropped the live slot");
    // 同じ世代で付け直すことはできない（世代は増え続ける。ETSampleStream_NextGeneration）。
    ET_CHECK(ETSampleStream_Attach(g.engine, g.instrument, GENERATION, RATE_HZ, 0, &slot) == ET_ERR_ARGS);
    ET_CHECK(ETSampleStream_SlotFor(g.engine, g.instrument) >= 0);
    rigDestroy(&g);
}

#endif /* ET_SS_ENGINE */

static const et_case cases[] = {
#ifndef ET_SS_ENGINE
    ET_ENTRY(fake_attach_configures_and_validates),
    ET_ENTRY(fake_generation_must_increase_across_attaches),
    ET_ENTRY(fake_parked_storage_is_reaped_by_next_control_call),
    ET_ENTRY(fake_supply_failure_is_visible_and_stops_forecast),
    ET_ENTRY(fake_disabled_node_does_not_forecast),
    ET_ENTRY(fake_requests_arrive_in_order),
    ET_ENTRY(fake_publish_is_ordered_bounded_and_between_blocks),
    ET_ENTRY(fake_publish_budget_is_shared_across_slots),
    ET_ENTRY(fake_stale_generation_is_rejected),
    ET_ENTRY(fake_bad_page_arguments_are_rejected),
    ET_ENTRY(fake_page_flags_and_channels_pass_through),
    ET_ENTRY(fake_bypass_touches_nothing),
    ET_ENTRY(fake_destroy_instances_detaches_first),
    ET_ENTRY(fake_set_engine_detaches_all),
    ET_ENTRY(fake_forecast_admits_then_commits),
    ET_ENTRY(fake_forecast_refreshes_while_voices_sound),
    ET_ENTRY(fake_forecast_shrinks_window_under_pressure),
    ET_ENTRY(fake_forecast_gives_up_then_retries),
    ET_ENTRY(fake_forecast_commit_waits_for_pages),
    ET_ENTRY(fake_forecast_waits_for_outstanding_requests),
    ET_ENTRY(fake_forecast_survives_unrequested_pages),
    ET_ENTRY(fake_forecast_follows_asset_and_midi_generation),
    ET_ENTRY(fake_forecast_error_backs_off),
    ET_ENTRY(fake_no_forecast_without_flag),
    ET_ENTRY(fake_request_overflow_is_counted),
    ET_ENTRY(fake_malloc_counter_sees_allocations),
    ET_ENTRY(fake_steady_state_allocates_nothing),
    ET_ENTRY(thread_render_supply_and_reattach),
    ET_ENTRY(thread_detach_while_rendering),
    ET_ENTRY(thread_pool_exhaustion_is_waited_out),
#else
    ET_ENTRY(engine_sf2_renders_non_silent),
    ET_ENTRY(engine_withheld_page_drops_note_without_error),
    ET_ENTRY(engine_forecast_completes),
    ET_ENTRY(engine_steady_state_allocates_nothing),
    ET_ENTRY(engine_guard_counts_allocations),
    ET_ENTRY(engine_stale_generation_is_refused_by_engine),
    ET_ENTRY(engine_reattach_requires_new_asset),
#endif
};

int main(int argc, char **argv) { return et_run(argc, argv, cases, ET_COUNT(cases)); }
