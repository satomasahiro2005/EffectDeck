//  ETResample.c

#include "ETResample.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// 1 位相あたりのタップ数。長いほど折り返しが減るが、遅延と演算量が増える。
// 32 なら 48k→96k で -90dB 程度の阻止量が取れて、遅延は入力側で 16 サンプル（0.33ms）。
#define TAPS_PER_PHASE 32

struct ETResampler {
    uint32_t factor;
    uint32_t channels;
    uint32_t tapsPerPhase;      // K
    float   *proto;             // factor*K。位相ごとに並べてある
    float   *historyUp;         // channels * K
    float   *historyDown;       // channels * (factor*K)
    uint32_t maxFrames;
    // 巡回の書き込み位置。K も factor*K も 2 の冪なのでマスクで回せる。
    uint32_t posUp;
    uint32_t posDown;
    uint32_t maskUp;
    uint32_t maskDown;
};

static double sincd(double x)
{
    if (x > -1e-12 && x < 1e-12) return 1.0;
    return sin(M_PI * x) / (M_PI * x);
}

/// 窓関数つき sinc。遮断は高いレート側のナイキストの 1/factor。
/// 位相 p、タップ k の係数を proto[p * K + k] に置く。
static void design(float *proto, uint32_t factor, uint32_t K)
{
    const uint32_t L = factor * K;
    const double cutoff = 0.5 / (double)factor;   // 高レート側の正規化周波数
    double *h = (double *)calloc(L, sizeof(double));
    if (!h) return;

    const double center = (double)(L - 1) * 0.5;
    double sum = 0.0;
    for (uint32_t n = 0; n < L; n++) {
        const double t = (double)n - center;
        // Blackman 窓。サイドローブが -58dB 程度まで落ちる
        const double w = 0.42
            - 0.5  * cos(2.0 * M_PI * (double)n / (double)(L - 1))
            + 0.08 * cos(4.0 * M_PI * (double)n / (double)(L - 1));
        h[n] = 2.0 * cutoff * sincd(2.0 * cutoff * t) * w;
        sum += h[n];
    }
    // 直流で利得 1 になるよう揃える
    if (sum > 1e-12) {
        for (uint32_t n = 0; n < L; n++) h[n] /= sum;
    }

    // 位相ごとに並べ替える。位相 p は n ≡ p (mod factor) を集めたもの。
    for (uint32_t p = 0; p < factor; p++) {
        for (uint32_t k = 0; k < K; k++) {
            const uint32_t n = k * factor + p;
            proto[p * K + k] = (float)(n < L ? h[n] : 0.0);
        }
    }
    free(h);
}

ETResampler *ETResampler_Create(uint32_t factor, uint32_t channels, uint32_t maxFrames)
{
    if (factor == 0 || channels == 0) return NULL;
    if (factor != 1 && factor != 2 && factor != 4) return NULL;

    ETResampler *r = (ETResampler *)calloc(1, sizeof(ETResampler));
    if (!r) return NULL;

    r->factor       = factor;
    r->channels     = channels;
    r->maxFrames    = maxFrames;
    r->tapsPerPhase = (factor == 1) ? 1 : TAPS_PER_PHASE;

    const uint32_t K = r->tapsPerPhase;
    r->proto       = (float *)calloc((size_t)factor * K, sizeof(float));
    r->historyUp   = (float *)calloc((size_t)channels * K, sizeof(float));
    r->historyDown = (float *)calloc((size_t)channels * factor * K, sizeof(float));

    if (!r->proto || !r->historyUp || !r->historyDown) {
        ETResampler_Destroy(r);
        return NULL;
    }

    r->maskUp   = K - 1;
    r->maskDown = factor * K - 1;

    if (factor == 1) {
        r->proto[0] = 1.0f;
    } else {
        design(r->proto, factor, K);
    }
    return r;
}

void ETResampler_Destroy(ETResampler *r)
{
    if (!r) return;
    free(r->proto);
    free(r->historyUp);
    free(r->historyDown);
    free(r);
}

uint32_t ETResampler_Factor(const ETResampler *r) { return r ? r->factor : 1; }

uint32_t ETResampler_LatencySamples(const ETResampler *r)
{
    if (!r || r->factor == 1) return 0;
    // 上げと下げで同じ長さの FIR を通すので、入力レートでは K サンプルぶん。
    return r->tapsPerPhase;
}

void ETResampler_Reset(ETResampler *r)
{
    if (!r) return;
    memset(r->historyUp, 0, (size_t)r->channels * r->tapsPerPhase * sizeof(float));
    memset(r->historyDown, 0,
           (size_t)r->channels * r->factor * r->tapsPerPhase * sizeof(float));
    r->posUp = 0;
    r->posDown = 0;
}

void ETResampler_Up(ETResampler *r, const float *in, float *out, uint32_t frames)
{
    if (!r || !in || !out || frames == 0) return;

    const uint32_t F = r->factor;
    if (F == 1) {
        memcpy(out, in, (size_t)frames * r->channels * sizeof(float));
        return;
    }

    const uint32_t K  = r->tapsPerPhase;
    const uint32_t ch = r->channels;
    const uint32_t outFrames = frames * F;

    for (uint32_t c = 0; c < ch; c++) {
        const float *src = in  + (size_t)c * frames;
        float       *dst = out + (size_t)c * outFrames;
        float       *hist = r->historyUp + (size_t)c * K;   // hist[0] が一番新しい

        uint32_t pos = r->posUp;
        for (uint32_t n = 0; n < frames; n++) {
            pos = (pos - 1) & r->maskUp;
            hist[pos] = src[n];

            for (uint32_t p = 0; p < F; p++) {
                const float *hp = r->proto + (size_t)p * K;
                float acc = 0.0f;
                for (uint32_t k = 0; k < K; k++) acc += hp[k] * hist[(pos + k) & r->maskUp];
                // ゼロ詰めで落ちたぶんを戻す
                dst[n * F + p] = acc * (float)F;
            }
        }
        if (c == ch - 1) r->posUp = pos;
    }
}

void ETResampler_Down(ETResampler *r, const float *in, float *out, uint32_t outFrames)
{
    if (!r || !in || !out || outFrames == 0) return;

    const uint32_t F = r->factor;
    if (F == 1) {
        memcpy(out, in, (size_t)outFrames * r->channels * sizeof(float));
        return;
    }

    const uint32_t K  = r->tapsPerPhase;
    const uint32_t L  = F * K;
    const uint32_t ch = r->channels;
    const uint32_t inFrames = outFrames * F;

    for (uint32_t c = 0; c < ch; c++) {
        const float *src  = in  + (size_t)c * inFrames;
        float       *dst  = out + (size_t)c * outFrames;
        float       *hist = r->historyDown + (size_t)c * L;   // hist[0] が一番新しい

        uint32_t pos = r->posDown;
        for (uint32_t m = 0; m < outFrames; m++) {
            // 高いレートのサンプルを F 個押し込んでから 1 個出す
            for (uint32_t i = 0; i < F; i++) {
                pos = (pos - 1) & r->maskDown;
                hist[pos] = src[m * F + i];
            }
            float acc = 0.0f;
            for (uint32_t p = 0; p < F; p++) {
                const float *hp = r->proto + (size_t)p * K;
                for (uint32_t k = 0; k < K; k++) {
                    acc += hp[k] * hist[(pos + k * F + p) & r->maskDown];
                }
            }
            dst[m] = acc;
        }
        if (c == ch - 1) r->posDown = pos;
    }
}
