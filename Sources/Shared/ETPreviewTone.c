#include "ETPreviewTone.h"
#include <math.h>
#include <stdatomic.h>

static _Atomic(double) frequency = 0;
// These are owned exclusively by the audio render thread.
static double phase = 0, amplitude = 0, lastFrequency = 440;

void ETPreviewTone_SetFrequency(double hz) {
    atomic_store_explicit(&frequency, isfinite(hz) && hz > 0 ? hz : 0, memory_order_relaxed);
}

void ETPreviewTone_Render(float *planar, uint32_t frames, uint32_t channels, double rate) {
    if (!planar || channels == 0 || !isfinite(rate) || rate <= 0) return;
    const double hz = atomic_load_explicit(&frequency, memory_order_relaxed);
    const double target = hz > 0 && hz < rate * 0.49 ? 0.0630957344 : 0; // -24 dBFS
    if (target > 0) lastFrequency = hz;
    const double step = 0.0630957344 / (rate * 0.005);
    for (uint32_t i = 0; i < frames; ++i) {
        amplitude += fmax(-step, fmin(step, target - amplitude));
        const float tone = (float)(sin(phase) * amplitude);
        planar[i] += tone;
        if (channels > 1) planar[frames + i] += tone;
        phase += 6.283185307179586 * lastFrequency / rate;
        if (phase >= 6.283185307179586) phase = fmod(phase, 6.283185307179586);
    }
}
