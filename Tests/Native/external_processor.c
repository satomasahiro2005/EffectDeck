//  external_processor.c
//  Sources/Shared/ETExternalProcessor.c の試験。AU / JSFX を鎖へ挿すための薄い ABI。

#include "ETExternalProcessor.h"
#include "et_test.h"

#include <math.h>
#include <stddef.h>

static int gCalls;

static int32_t half_gain(void *ctx, float *p, uint32_t ch, uint32_t frames,
                         double rate, double time)
{
    (void)ctx; (void)rate; (void)time;
    gCalls++;
    for (uint32_t c = 0; c < ch; ++c)
        for (uint32_t i = 0; i < frames; ++i)
            p[c * frames + i] *= 0.5f;
    return 0;
}

static int32_t add_gain(void *ctx, float *p, uint32_t ch, uint32_t frames,
                        double rate, double time)
{
    (void)ctx; (void)rate; (void)time;
    for (uint32_t c = 0; c < ch; ++c)
        for (uint32_t i = 0; i < frames; ++i)
            p[c * frames + i] += 1.0f;
    return 0;
}

typedef struct {
    uint32_t latency;
    double tail;
    double rate, time;
} Ctx;

static int32_t record(void *ctx, float *p, uint32_t ch, uint32_t frames, double rate, double time)
{
    (void)p; (void)ch; (void)frames;
    Ctx *c = (Ctx *)ctx;
    c->rate = rate;
    c->time = time;
    return 42;
}
static uint32_t latency_of(void *ctx) { return ((Ctx *)ctx)->latency; }
static double tail_of(void *ctx) { return ((Ctx *)ctx)->tail; }

ET_CASE(process_half_gain)
{
    ETExternalProcessor fx = {0};
    fx.process = half_gain;
    fx.maxFrames = 8;
    fx.maxChannels = 2;
    float audio[8] = {1, 2, 3, 4, 10, 20, 30, 40};
    ET_CHECK(ETExternalProcessor_Process(&fx, audio, 2, 4, 48000.0, 0.0) == 0);
    ET_CHECK(fabsf(audio[0] - 0.5f) < 1e-6f);
    ET_CHECK(fabsf(audio[7] - 20.0f) < 1e-6f);
}

ET_CASE(max_frames_minus2)
{
    ETExternalProcessor fx = {0};
    fx.process = half_gain;
    fx.maxFrames = 8;
    float audio[18] = {0};
    gCalls = 0;
    ET_CHECK(ETExternalProcessor_Process(&fx, audio, 2, 9, 48000.0, 0.0) == -2);
    ET_CHECK(gCalls == 0);
    ET_CHECK(ETExternalProcessor_Process(&fx, audio, 2, 8, 48000.0, 0.0) == 0);
    ET_CHECK(gCalls == 1);
}

ET_CASE(minus1_bad_args)
{
    ETExternalProcessor fx = {0};
    fx.process = half_gain;
    float audio[4] = {0};
    gCalls = 0;
    ET_CHECK(ETExternalProcessor_Process(&fx, NULL, 1, 4, 48000.0, 0.0) == -1);
    ET_CHECK(ETExternalProcessor_Process(&fx, audio, 0, 4, 48000.0, 0.0) == -1);
    ET_CHECK(ETExternalProcessor_Process(&fx, audio, 1, 0, 48000.0, 0.0) == -1);
    ET_CHECK(gCalls == 0);
}

ET_CASE(minus3_too_many_channels)
{
    ETExternalProcessor fx = {0};
    fx.process = half_gain;
    fx.maxChannels = 2;
    float audio[12] = {0};
    gCalls = 0;
    ET_CHECK(ETExternalProcessor_Process(&fx, audio, 3, 4, 48000.0, 0.0) == -3);
    ET_CHECK(gCalls == 0);
    // 上限 0 は「上限なし」。
    fx.maxChannels = 0;
    ET_CHECK(ETExternalProcessor_Process(&fx, audio, 3, 4, 48000.0, 0.0) == 0);
    ET_CHECK(gCalls == 1);
}

ET_CASE(missing_processor_is_noop)
{
    float audio[4] = {1, 2, 3, 4};
    ET_CHECK(ETExternalProcessor_Process(NULL, audio, 1, 4, 48000.0, 0.0) == 0);
    ETExternalProcessor fx = {0};
    fx.process = half_gain;
    ETExternalProcessor_Clear(&fx);
    ET_CHECK(fx.process == NULL && fx.context == NULL && fx.maxFrames == 0);
    ET_CHECK(ETExternalProcessor_Process(&fx, audio, 1, 4, 48000.0, 0.0) == 0);
    ET_CHECK(audio[0] == 1 && audio[3] == 4);
    ETExternalProcessor_Clear(NULL);
}

ET_CASE(passes_rate_time_and_status)
{
    Ctx c = {0};
    ETExternalProcessor fx = {0};
    fx.context = &c;
    fx.process = record;
    float audio[2] = {0};
    ET_CHECK(ETExternalProcessor_Process(&fx, audio, 1, 2, 96000.0, 12.5) == 42);
    ET_CHECK(c.rate == 96000.0 && c.time == 12.5);
}

ET_CASE(latency)
{
    ET_CHECK(ETExternalProcessor_Latency(NULL) == 0);
    Ctx c = {.latency = 128};
    ETExternalProcessor fx = {0};
    fx.context = &c;
    ET_CHECK(ETExternalProcessor_Latency(&fx) == 0);    // 関数が無ければ 0
    fx.latency = latency_of;
    ET_CHECK(ETExternalProcessor_Latency(&fx) == 128);
}

ET_CASE(tailtime)
{
    ET_CHECK(ETExternalProcessor_TailTime(NULL) == 0.0);
    Ctx c = {.tail = 2.5};
    ETExternalProcessor fx = {0};
    fx.context = &c;
    ET_CHECK(ETExternalProcessor_TailTime(&fx) == 0.0);
    fx.tailTime = tail_of;
    ET_CHECK(ETExternalProcessor_TailTime(&fx) == 2.5);
}

ET_CASE(ordered_chain)
{
    ETExternalProcessor ordered[2] = {{0}, {0}};
    ordered[0].process = half_gain;
    ordered[1].process = add_gain;
    float audio[4] = {2, 4, 6, 8};
    ET_CHECK(ETExternalProcessor_Process(&ordered[0], audio, 1, 4, 48000.0, 0.0) == 0);
    ET_CHECK(ETExternalProcessor_Process(&ordered[1], audio, 1, 4, 48000.0, 0.0) == 0);
    ET_CHECK(fabsf(audio[0] - 2.0f) < 1e-6f && fabsf(audio[3] - 5.0f) < 1e-6f);
}

static const et_case cases[] = {
    ET_ENTRY(process_half_gain),
    ET_ENTRY(max_frames_minus2),
    ET_ENTRY(minus1_bad_args),
    ET_ENTRY(minus3_too_many_channels),
    ET_ENTRY(missing_processor_is_noop),
    ET_ENTRY(passes_rate_time_and_status),
    ET_ENTRY(latency),
    ET_ENTRY(tailtime),
    ET_ENTRY(ordered_chain),
};

int main(int argc, char **argv)
{
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
