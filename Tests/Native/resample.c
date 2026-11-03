//  resample.c
//  Sources/Shared/ETResample.c の試験。48kHz 入力を前提に、数字で押さえる。
//
//  目標（オーナー決定 D9）:
//    - 往復（Up→Down）の通過域は 20kHz まで ±0.1dB
//    - 24kHz から上は Up の像も Down の折り返しも -60dB 以下（2倍・4倍とも）
//    - LatencySamples はインパルスの実測と一致する
//  26kHz が 22kHz へ -22dB で折り返していたのを直したので、alias_26k がその印。

#include "ETResample.h"
#include "et_test.h"

#include <math.h>

static const double kPi = 3.14159265358979323846;
static const double kRate = 48000.0;
static const uint32_t kFactors[] = {2, 4};

/// 周波数 f の成分の振幅（dB、正弦波の振幅 1 が 0dB）。Hann 窓をかけた 1 本の DFT。
static double tone_db(const float *x, size_t n, double f, double fs)
{
    double re = 0, im = 0, wsum = 0;
    for (size_t i = 0; i < n; i++) {
        const double w = 0.5 - 0.5 * cos(2 * kPi * (double)i / (double)(n - 1));
        re += w * x[i] * cos(2 * kPi * f * (double)i / fs);
        im -= w * x[i] * sin(2 * kPi * f * (double)i / fs);
        wsum += w;
    }
    const double amp = 2 * sqrt(re * re + im * im) / wsum;
    return 20 * log10(amp + 1e-30);
}

/// 入力レートの f を折り返した先（0〜24kHz）。
static double folded(double f)
{
    const double k = floor(f / kRate + 0.5);
    return fabs(f - k * kRate);
}

enum { N = 1 << 14, SKIP = 2048 };

typedef struct {
    ETResampler *r;
    uint32_t F;
    float *in, *hi, *out;
} Rig;

static Rig rig(uint32_t F, uint32_t channels)
{
    Rig g;
    g.F = F;
    g.r = ETResampler_Create(F, channels, N);
    ET_CHECK(g.r != NULL);
    g.in = (float *)calloc((size_t)N * channels, sizeof(float));
    g.hi = (float *)calloc((size_t)N * F * channels, sizeof(float));
    g.out = (float *)calloc((size_t)N * channels, sizeof(float));
    ET_CHECK(g.in && g.hi && g.out);
    return g;
}

static void unrig(Rig *g)
{
    ETResampler_Destroy(g->r);
    free(g->in);
    free(g->hi);
    free(g->out);
}

static void roundtrip(Rig *g)
{
    ETResampler_Reset(g->r);
    ETResampler_Up(g->r, g->in, g->hi, N);
    ETResampler_Down(g->r, g->hi, g->out, N);
}

static void fill_sine(float *x, size_t n, double f, double fs, double amp)
{
    for (size_t i = 0; i < n; i++) x[i] = (float)(amp * sin(2 * kPi * f * (double)i / fs));
}

// ---------------------------------------------------------------------------

ET_CASE(create_rejects_bad_args)
{
    ET_CHECK(ETResampler_Create(0, 2, 64) == NULL);
    ET_CHECK(ETResampler_Create(3, 2, 64) == NULL);
    ET_CHECK(ETResampler_Create(8, 2, 64) == NULL);
    ET_CHECK(ETResampler_Create(2, 0, 64) == NULL);
    ETResampler_Destroy(NULL);
    ET_CHECK(ETResampler_Factor(NULL) == 1);
    ET_CHECK(ETResampler_LatencySamples(NULL) == 0);
    ETResampler_Reset(NULL);
    float a[4] = {0};
    ETResampler_Up(NULL, a, a, 1);
    ETResampler_Down(NULL, a, a, 1);
}

ET_CASE(factor1_passthrough)
{
    ETResampler *one = ETResampler_Create(1, 2, 64);
    ET_CHECK(one != NULL);
    ET_CHECK(ETResampler_Factor(one) == 1);
    ET_CHECK(ETResampler_LatencySamples(one) == 0);
    const float a[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    float b[8] = {0}, c[8] = {0};
    ETResampler_Up(one, a, b, 4);
    ET_CHECK(memcmp(a, b, sizeof a) == 0);
    ETResampler_Down(one, b, c, 4);
    ET_CHECK(memcmp(a, c, sizeof a) == 0);
    ETResampler_Destroy(one);
}

ET_CASE(dc_roundtrip)
{
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        for (uint32_t i = 0; i < N; i++) g.in[i] = 1.0f;
        roundtrip(&g);
        // Up の各位相が同じ利得で直流を通す（ずれると 48kHz の倍数に音が出る）。
        double lo = 1e9, hi = -1e9;
        for (uint32_t i = N * g.F / 2; i < N * g.F; i++) {
            if (g.hi[i] < lo) lo = g.hi[i];
            if (g.hi[i] > hi) hi = g.hi[i];
        }
        ET_CHECK_MSG(fabs(lo - 1) < 1e-5 && fabs(hi - 1) < 1e-5,
                     "x%u Up DC min %.8f max %.8f", g.F, lo, hi);
        ET_CHECK_MSG(fabs(g.out[N - 1] - 1) < 1e-5, "x%u round-trip DC %.8f", g.F, g.out[N - 1]);
        unrig(&g);
    }
}

ET_CASE(latency_matches_impulse)
{
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        g.in[100] = 1.0f;
        roundtrip(&g);
        uint32_t peak = 0;
        double num = 0, den = 0;
        for (uint32_t i = 0; i < N; i++) {
            if (fabs(g.out[i]) > fabs(g.out[peak])) peak = i;
            num += (double)i * g.out[i] * g.out[i];
            den += (double)g.out[i] * g.out[i];
        }
        const uint32_t reported = ETResampler_LatencySamples(g.r);
        const double centroid = num / den - 100.0;
        ET_CHECK_MSG(peak - 100 == reported, "x%u peak at +%u, reported %u", g.F, peak - 100, reported);
        ET_CHECK_MSG(fabs(centroid - reported) < 0.01, "x%u centroid +%.4f, reported %u",
                     g.F, centroid, reported);
        unrig(&g);
    }
}

ET_CASE(passband_flat_to_20k)
{
    static const double freqs[] = {100, 1000, 5000, 10000, 15000, 18000, 19000, 19500, 20000};
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        for (size_t k = 0; k < ET_COUNT(freqs); k++) {
            fill_sine(g.in, N, freqs[k], kRate, 0.5);
            roundtrip(&g);
            const double db = tone_db(g.out + SKIP, N - SKIP, freqs[k], kRate) - 20 * log10(0.5);
            ET_CHECK_MSG(fabs(db) <= 0.1, "x%u round trip at %.0f Hz: %+.4f dB", g.F, freqs[k], db);
        }
        unrig(&g);
    }
}

/// Down の折り返し。高レートで振幅 1 の正弦を入れ、折り返し先の大きさを見る。
static double alias_db(Rig *g, double f)
{
    fill_sine(g->hi, (size_t)N * g->F, f, kRate * g->F, 1.0);
    ETResampler_Reset(g->r);
    ETResampler_Down(g->r, g->hi, g->out, N);
    return tone_db(g->out + SKIP, N - SKIP, folded(f), kRate);
}

ET_CASE(stopband_from_24k)
{
    static const double x2[] = {24050, 24250, 24500, 25000, 26000, 27000, 28000, 30000,
                                33000, 36000, 40000, 44000, 47750};
    static const double x4[] = {50000, 56000, 60000, 66000, 70000, 72100, 80000, 88000,
                                90000, 95750};
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        for (size_t k = 0; k < ET_COUNT(x2); k++) {
            const double db = alias_db(&g, x2[k]);
            ET_CHECK_MSG(db <= -60.0, "x%u %.0f Hz folds to %.0f Hz at %.1f dB", g.F, x2[k],
                         folded(x2[k]), db);
        }
        if (g.F == 4) {
            for (size_t k = 0; k < ET_COUNT(x4); k++) {
                const double db = alias_db(&g, x4[k]);
                ET_CHECK_MSG(db <= -60.0, "x4 %.0f Hz folds to %.0f Hz at %.1f dB", x4[k],
                             folded(x4[k]), db);
            }
        }
        unrig(&g);
    }
}

ET_CASE(alias_26k)
{
    // 以前は遮断が入力ナイキストそのものにあって、26kHz が 22kHz へ -22dB で戻っていた。
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        const double db = alias_db(&g, 26000);
        ET_CHECK_MSG(db <= -60.0, "x%u 26 kHz -> 22 kHz at %.1f dB", g.F, db);
        unrig(&g);
    }
}

ET_CASE(alias_30k_below_84db)
{
    // 今の設計で -88.9dB（2倍）/ -86dB（4倍）。以前の設計は -75dB で、ここで落ちる。
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        const double db = alias_db(&g, 30000);
        ET_CHECK_MSG(db <= -84.0, "x%u 30 kHz -> 18 kHz at %.1f dB", g.F, db);
        unrig(&g);
    }
}

ET_CASE(image_stopband_from_24k)
{
    // Up の像。入力の f は高レートで 48k*j ± f に像を作る。24kHz より上は全部 -60dB 以下。
    static const double src[] = {1000, 10000, 20000, 23500};
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        const double hiRate = kRate * g.F;
        for (size_t k = 0; k < ET_COUNT(src); k++) {
            fill_sine(g.in, N, src[k], kRate, 1.0);
            ETResampler_Reset(g.r);
            ETResampler_Up(g.r, g.in, g.hi, N);
            for (uint32_t j = 1; j <= g.F / 2; j++) {
                const double images[2] = {kRate * j - src[k], kRate * j + src[k]};
                for (int s = 0; s < 2; s++) {
                    if (images[s] >= hiRate / 2) continue;
                    const double db = tone_db(g.hi + SKIP * g.F, (size_t)(N - SKIP) * g.F,
                                              images[s], hiRate);
                    ET_CHECK_MSG(db <= -60.0, "x%u image of %.0f Hz at %.0f Hz: %.1f dB", g.F,
                                 src[k], images[s], db);
                }
            }
        }
        unrig(&g);
    }
}

ET_CASE(image_1k_below_90db)
{
    // 以前の設計では -104dB だったが、遮断を下げて窓を替えたので -99.6dB（2倍）/ -93dB（4倍）。
    // 24kHz より上の全体は image_stopband_from_24k が見ている。ここは 47kHz の一点の押さえ。
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        fill_sine(g.in, N, 1000, kRate, 1.0);
        ETResampler_Reset(g.r);
        ETResampler_Up(g.r, g.in, g.hi, N);
        const double db = tone_db(g.hi + SKIP * g.F, (size_t)(N - SKIP) * g.F, 47000, kRate * g.F);
        ET_CHECK_MSG(db <= -90.0, "x%u image of 1 kHz at 47 kHz: %.1f dB", g.F, db);
        unrig(&g);
    }
}

ET_CASE(overshoot_and_square_peak)
{
    // 高レート側で見える山。オーバーサンプルした歪みは、ここを入力の山として受け取る。
    // 実測（56 タップ/位相）: 段差の山 Up 1.104（2倍）/ 1.124（4倍）、往復 1.048。
    // 1kHz 矩形の山 Up 1.209 / 1.249。
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        for (uint32_t i = 0; i < N; i++) g.in[i] = 1.0f;
        roundtrip(&g);
        double upPeak = 0, rtPeak = 0;
        for (uint32_t i = 0; i < N * g.F; i++) if (g.hi[i] > upPeak) upPeak = g.hi[i];
        for (uint32_t i = 0; i < N; i++) if (g.out[i] > rtPeak) rtPeak = g.out[i];
        ET_CHECK_MSG(upPeak < 1.15, "x%u step overshoot (Up) %.4f", g.F, upPeak);
        ET_CHECK_MSG(rtPeak < 1.06, "x%u step overshoot (round trip) %.4f", g.F, rtPeak);

        for (uint32_t i = 0; i < N; i++) g.in[i] = ((i / 24) & 1) ? -1.0f : 1.0f;   // 1 kHz 矩形
        roundtrip(&g);
        double sqUp = 0;
        for (uint32_t i = 0; i < N * g.F; i++) if (fabs(g.hi[i]) > sqUp) sqUp = fabs(g.hi[i]);
        ET_CHECK_MSG(sqUp < 1.3, "x%u full-scale 1 kHz square peak (Up) %.4f", g.F, sqUp);
        unrig(&g);
    }
}

ET_CASE(block_split_bitexact)
{
    static const uint32_t blocks[] = {1, 7, 128, 1000};
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        for (uint32_t i = 0; i < N; i++) g.in[i] = (float)(sin(i * 0.013) + 0.3 * sin(i * 1.7));
        float *ref = (float *)calloc(N, sizeof(float));
        ET_CHECK(ref != NULL);
        roundtrip(&g);
        memcpy(ref, g.out, N * sizeof(float));
        for (size_t b = 0; b < ET_COUNT(blocks); b++) {
            ETResampler_Reset(g.r);
            for (uint32_t off = 0; off < N; off += blocks[b]) {
                uint32_t n = blocks[b];
                if (off + n > N) n = N - off;
                ETResampler_Up(g.r, g.in + off, g.hi, n);
                ETResampler_Down(g.r, g.hi, g.out + off, n);
            }
            ET_CHECK_MSG(memcmp(ref, g.out, N * sizeof(float)) == 0,
                         "x%u block size %u differs from one shot", g.F, blocks[b]);
        }
        free(ref);
        unrig(&g);
    }
}

ET_CASE(channel_isolation)
{
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        const uint32_t F = kFactors[f], ch = 4, n = 512;
        ETResampler *r = ETResampler_Create(F, ch, n);
        ET_CHECK(r != NULL);
        float *in = (float *)calloc((size_t)n * ch, sizeof(float));
        float *hi = (float *)calloc((size_t)n * F * ch, sizeof(float));
        float *out = (float *)calloc((size_t)n * ch, sizeof(float));
        ET_CHECK(in && hi && out);
        for (uint32_t i = 0; i < n; i++) in[n + i] = (float)sin(i * 0.1);   // ch1 だけ
        ETResampler_Up(r, in, hi, n);
        for (uint32_t i = 0; i < n * F; i++) {
            ET_CHECK(hi[i] == 0.0f);
            ET_CHECK(hi[2 * n * F + i] == 0.0f && hi[3 * n * F + i] == 0.0f);
        }
        ETResampler_Down(r, hi, out, n);
        double energy = 0;
        for (uint32_t i = 0; i < n; i++) {
            ET_CHECK(out[i] == 0.0f && out[2 * n + i] == 0.0f && out[3 * n + i] == 0.0f);
            energy += (double)out[n + i] * out[n + i];
        }
        ET_CHECK(energy > 1.0);
        free(in);
        free(hi);
        free(out);
        ETResampler_Destroy(r);
    }
}

ET_CASE(reset_reproducible)
{
    for (size_t f = 0; f < ET_COUNT(kFactors); f++) {
        Rig g = rig(kFactors[f], 1);
        for (uint32_t i = 0; i < N; i++) g.in[i] = (float)sin(i * 0.37);
        roundtrip(&g);
        float *first = (float *)malloc(N * sizeof(float));
        ET_CHECK(first != NULL);
        memcpy(first, g.out, N * sizeof(float));
        // 別の信号で履歴を汚してから Reset すると、最初と同じ出力に戻る。
        for (uint32_t i = 0; i < 300; i++) g.hi[i] = 0.9f;
        ETResampler_Down(g.r, g.hi, g.out, 50);
        roundtrip(&g);
        ET_CHECK(memcmp(first, g.out, N * sizeof(float)) == 0);
        // 作り直したものとも一致する。
        Rig fresh = rig(kFactors[f], 1);
        memcpy(fresh.in, g.in, N * sizeof(float));
        ETResampler_Up(fresh.r, fresh.in, fresh.hi, N);
        ETResampler_Down(fresh.r, fresh.hi, fresh.out, N);
        ET_CHECK(memcmp(first, fresh.out, N * sizeof(float)) == 0);
        free(first);
        unrig(&fresh);
        unrig(&g);
    }
}

static const et_case cases[] = {
    ET_ENTRY(create_rejects_bad_args),
    ET_ENTRY(factor1_passthrough),
    ET_ENTRY(dc_roundtrip),
    ET_ENTRY(latency_matches_impulse),
    ET_ENTRY(passband_flat_to_20k),
    ET_ENTRY(stopband_from_24k),
    ET_ENTRY(alias_26k),
    ET_ENTRY(alias_30k_below_84db),
    ET_ENTRY(image_stopband_from_24k),
    ET_ENTRY(image_1k_below_90db),
    ET_ENTRY(overshoot_and_square_peak),
    ET_ENTRY(block_split_bitexact),
    ET_ENTRY(channel_isolation),
    ET_ENTRY(reset_reproducible),
};

int main(int argc, char **argv)
{
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
