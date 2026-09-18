#include "ETExternalProcessor.h"

#include <assert.h>
#include <math.h>
#include <stddef.h>

static int32_t half_gain(void *ctx, float *p, uint32_t ch, uint32_t frames,
                         double rate, double time)
{
    (void)ctx; (void)rate; (void)time;
    for (uint32_t c = 0; c < ch; ++c)
        for (uint32_t i = 0; i < frames; ++i)
            p[c * frames + i] *= 0.5f;
    return 0;
}

int main(void)
{
    ETExternalProcessor fx = {0};
    fx.process = half_gain;
    fx.maxFrames = 8;
    fx.maxChannels = 2;

    float audio[8] = {1, 2, 3, 4, 10, 20, 30, 40};
    assert(ETExternalProcessor_Process(&fx, audio, 2, 4, 48000.0, 0.0) == 0);
    assert(fabsf(audio[0] - 0.5f) < 1e-6f);
    assert(fabsf(audio[7] - 20.0f) < 1e-6f);
    assert(ETExternalProcessor_Process(&fx, audio, 2, 9, 48000.0, 0.0) == -2);
    ETExternalProcessor_Clear(&fx);
    assert(ETExternalProcessor_Process(&fx, audio, 2, 4, 48000.0, 0.0) == 0);
    return 0;
}
