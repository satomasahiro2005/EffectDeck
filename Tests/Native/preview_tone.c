#include "ETPreviewTone.h"
#include <assert.h>
#include <math.h>
#include <string.h>

int main(void) {
    static float audio[96000] = {0};
    ETPreviewTone_SetFrequency(440);
    ETPreviewTone_Render(audio, 48000, 2, 48000);
    int crossings = 0;
    double energy = 0;
    for (int i = 0; i < 48000; ++i) {
        assert(isfinite(audio[i]));
        assert(audio[i] == audio[48000 + i]);
        assert(fabsf(audio[i]) <= 0.064f);
        if (i && audio[i - 1] < 0 && audio[i] >= 0) ++crossings;
        energy += audio[i] * audio[i];
    }
    assert(crossings >= 439 && crossings <= 440);
    assert(energy / 48000 > 0.0019 && energy / 48000 < 0.0021);
    static float surround[48000 * 4] = {0};
    ETPreviewTone_Render(surround, 48000, 4, 48000);
    for (int i = 0; i < 48000; ++i) {
        assert(surround[i] == surround[48000 + i]);
        assert(surround[96000 + i] == 0);
        assert(surround[144000 + i] == 0);
    }
    ETPreviewTone_SetFrequency(0);
    memset(audio, 0, sizeof(audio));
    ETPreviewTone_Render(audio, 48000, 2, 48000);
    for (int i = 480; i < 48000; ++i) assert(audio[i] == 0);
    ETPreviewTone_SetFrequency(30000); // Above Nyquist stays silent.
    memset(audio, 0, sizeof(audio));
    ETPreviewTone_Render(audio, 48000, 2, 48000);
    for (int i = 0; i < 96000; ++i) assert(audio[i] == 0);
    return 0;
}
