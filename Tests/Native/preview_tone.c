//  preview_tone.c
//  Sources/Shared/ETPreviewTone.c の試験。図を指でなぞったときに鳴らす -24dBFS の正弦。
//  状態は音のスレッドの持ち物（静的変数）なので、各件の頭で無音へ戻す（drain）。

#include "ETPreviewTone.h"
#include "et_test.h"

#include <math.h>

static const double kPi = 3.14159265358979323846;
static const double A = 0.0630957344;   // -24 dBFS

static void drain(void)
{
    static float buf[4096];
    ETPreviewTone_SetFrequency(0);
    for (int i = 0; i < 8; i++) {
        memset(buf, 0, sizeof buf);
        ETPreviewTone_Render(buf, 2048, 2, 48000);
    }
}

// ---------------------------------------------------------------------------

ET_CASE(active_initial_and_nonfinite)
{
    // **表の先頭に置く。**何も起きていない状態では鳴っていない。
    ET_CHECK(ETPreviewTone_Active(48000) == 0);
    const double bad[] = {NAN, -440, INFINITY, -INFINITY, 0};
    for (size_t k = 0; k < ET_COUNT(bad); k++) {
        ETPreviewTone_SetFrequency(bad[k]);
        ET_CHECK(ETPreviewTone_Active(48000) == 0);
    }
}

ET_CASE(render_440_stereo)
{
    drain();
    static float audio[96000];
    memset(audio, 0, sizeof audio);
    ETPreviewTone_SetFrequency(440);
    ETPreviewTone_Render(audio, 48000, 2, 48000);
    int crossings = 0;
    double energy = 0;
    for (int i = 0; i < 48000; ++i) {
        ET_CHECK(isfinite(audio[i]));
        ET_CHECK(audio[i] == audio[48000 + i]);
        ET_CHECK(fabsf(audio[i]) <= 0.064f);
        if (i && audio[i - 1] < 0 && audio[i] >= 0) ++crossings;
        energy += (double)audio[i] * audio[i];
    }
    ET_CHECK(crossings >= 439 && crossings <= 440);
    ET_CHECK(energy / 48000 > 0.0019 && energy / 48000 < 0.0021);
}

ET_CASE(surround_channels_2_3_silent)
{
    drain();
    static float surround[48000 * 4];
    memset(surround, 0, sizeof surround);
    ETPreviewTone_SetFrequency(440);
    ETPreviewTone_Render(surround, 48000, 4, 48000);
    for (int i = 0; i < 48000; ++i) {
        ET_CHECK(surround[i] == surround[48000 + i]);
        ET_CHECK(surround[96000 + i] == 0);
        ET_CHECK(surround[144000 + i] == 0);
    }
}

ET_CASE(zero_hz_fades_to_silence)
{
    drain();
    static float audio[96000];
    ETPreviewTone_SetFrequency(440);
    memset(audio, 0, sizeof audio);
    ETPreviewTone_Render(audio, 48000, 2, 48000);
    ETPreviewTone_SetFrequency(0);
    memset(audio, 0, sizeof audio);
    ETPreviewTone_Render(audio, 48000, 2, 48000);
    for (int i = 480; i < 48000; ++i) ET_CHECK(audio[i] == 0);
}

ET_CASE(above_nyquist_silent)
{
    drain();
    static float audio[96000];
    ETPreviewTone_SetFrequency(30000);
    memset(audio, 0, sizeof audio);
    ETPreviewTone_Render(audio, 48000, 2, 48000);
    for (int i = 0; i < 96000; ++i) ET_CHECK(audio[i] == 0);
}

ET_CASE(bad_rates_no_write)
{
    drain();
    ETPreviewTone_SetFrequency(440);
    float z[256] = {0};
    const double rates[] = {0, -48000, NAN, INFINITY};
    for (size_t k = 0; k < ET_COUNT(rates); k++) {
        ETPreviewTone_Render(z, 128, 2, rates[k]);
        for (int i = 0; i < 256; i++) ET_CHECK(z[i] == 0);
        ET_CHECK(ETPreviewTone_Active(rates[k]) == 0);
    }
    ETPreviewTone_Render(NULL, 128, 2, 48000);   // 落ちない
    ETPreviewTone_Render(z, 128, 0, 48000);      // チャンネル 0 は書かない
    for (int i = 0; i < 256; i++) ET_CHECK(z[i] == 0);
}

ET_CASE(ramp_5ms)
{
    // 立ち上がりは 5 ms の直線。クリックにならない（1 標本の段差が正弦の傾きを超えない）。
    drain();
    ETPreviewTone_SetFrequency(440);
    float *mono = (float *)calloc(480, sizeof(float));
    ET_CHECK(mono != NULL);
    ETPreviewTone_Render(mono, 480, 1, 48000);
    double maxStep = 0, peakFirst = 0, peakLast = 0;
    for (int i = 1; i < 480; i++) {
        const double d = fabs(mono[i] - mono[i - 1]);
        if (d > maxStep) maxStep = d;
    }
    for (int i = 0; i < 120; i++) if (fabs(mono[i]) > peakFirst) peakFirst = fabs(mono[i]);
    for (int i = 360; i < 480; i++) if (fabs(mono[i]) > peakLast) peakLast = fabs(mono[i]);
    ET_CHECK_MSG(peakFirst < A * 0.55, "first 2.5 ms peak %.5f", peakFirst);
    ET_CHECK_MSG(fabs(peakLast - A) < 1e-3, "after 7.5 ms peak %.5f", peakLast);
    ET_CHECK_MSG(maxStep <= A * 2 * kPi * 440 / 48000 * 1.01, "max step %.6f", maxStep);
    ET_CHECK(ETPreviewTone_Active(48000) == 1);
    free(mono);
}

ET_CASE(phase_continuous_440_880)
{
    drain();
    ETPreviewTone_SetFrequency(440);
    float st[2 * 512];
    memset(st, 0, sizeof st);
    ETPreviewTone_Render(st, 480, 2, 48000);   // 立ち上がりを終える
    memset(st, 0, sizeof st);
    ETPreviewTone_Render(st, 256, 2, 48000);
    const float last = st[255];
    ETPreviewTone_SetFrequency(880);
    memset(st, 0, sizeof st);
    ETPreviewTone_Render(st, 512, 2, 48000);
    const double jump = fabs(st[0] - last), bound = A * 2 * kPi * 880 / 48000 * 1.01;
    ET_CHECK_MSG(jump <= bound, "boundary step %.6f (bound %.6f)", jump, bound);
}

ET_CASE(nyquist_guard_strict)
{
    drain();
    ETPreviewTone_SetFrequency(0.49 * 48000);
    ET_CHECK(ETPreviewTone_Active(48000) == 0);
    ETPreviewTone_SetFrequency(0.49 * 48000 - 1);
    ET_CHECK(ETPreviewTone_Active(48000) == 1);
}

ET_CASE(release_240)
{
    // 離すと 5 ms（48kHz で 240 標本）で消え、その間は鳴っている扱いのまま。
    drain();
    ETPreviewTone_SetFrequency(1000);
    float r[2 * 2048];
    memset(r, 0, sizeof r);
    ETPreviewTone_Render(r, 2048, 2, 48000);
    ETPreviewTone_SetFrequency(0);
    ET_CHECK(ETPreviewTone_Active(48000) == 1);
    memset(r, 0, sizeof r);
    ETPreviewTone_Render(r, 100, 2, 48000);
    ET_CHECK(ETPreviewTone_Active(48000) == 1);
    memset(r, 0, sizeof r);
    ETPreviewTone_Render(r, 200, 2, 48000);
    ET_CHECK(ETPreviewTone_Active(48000) == 0);   // 振幅はちょうど 0 に着く
    for (int i = 140; i < 200; i++) ET_CHECK(r[i] == 0);
}

ET_CASE(ramp_96k)
{
    // 傾きはレートに合わせる（96kHz の 5 ms は 480 標本）。
    drain();
    ETPreviewTone_SetFrequency(440);
    float *hi = (float *)calloc(2 * 480, sizeof(float));
    ET_CHECK(hi != NULL);
    ETPreviewTone_Render(hi, 470, 2, 96000);
    double p = 0;
    for (int i = 400; i < 470; i++) if (fabs(hi[i]) > p) p = fabs(hi[i]);
    ET_CHECK_MSG(p < A, "peak before 480 samples %.5f", p);
    free(hi);
}

ET_CASE(mono_bounds)
{
    // モノの器はちょうど frames 個。2 本目へ書くと ASan が落とす。
    drain();
    ETPreviewTone_SetFrequency(440);
    float *mono = (float *)calloc(1000, sizeof(float));
    ET_CHECK(mono != NULL);
    ETPreviewTone_Render(mono, 1000, 1, 48000);
    double energy = 0;
    for (int i = 900; i < 1000; i++) energy += (double)mono[i] * mono[i];
    ET_CHECK(energy > 0);
    free(mono);
}

ET_CASE(additive_mix)
{
    // 上書きではなく足し込む。
    drain();
    ETPreviewTone_SetFrequency(440);
    float add[2 * 480];
    for (int i = 0; i < 960; i++) add[i] = 0.5f;
    ETPreviewTone_Render(add, 480, 2, 48000);
    double energy = 0;
    for (int i = 0; i < 480; i++) {
        const double tone = add[i] - 0.5;
        ET_CHECK(fabs(tone) <= A + 1e-6);
        ET_CHECK(add[i] == add[480 + i]);
        energy += tone * tone;
    }
    ET_CHECK(energy > 0);
}

static const et_case cases[] = {
    ET_ENTRY(active_initial_and_nonfinite),
    ET_ENTRY(render_440_stereo),
    ET_ENTRY(surround_channels_2_3_silent),
    ET_ENTRY(zero_hz_fades_to_silence),
    ET_ENTRY(above_nyquist_silent),
    ET_ENTRY(bad_rates_no_write),
    ET_ENTRY(ramp_5ms),
    ET_ENTRY(phase_continuous_440_880),
    ET_ENTRY(nyquist_guard_strict),
    ET_ENTRY(release_240),
    ET_ENTRY(ramp_96k),
    ET_ENTRY(mono_bounds),
    ET_ENTRY(additive_mix),
};

int main(int argc, char **argv)
{
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
