//  ETResample.c

#include "ETResample.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// M_PI は C の標準ではない（MSVC と -std=c11 では定義されない）。
static const double kPi = 3.14159265358979323846;

// 1 位相あたりのタップ数。長いほど遷移域が狭くなるが、遅延と演算量が増える。
// 通過域の端 20kHz から入力ナイキスト 24kHz までの 4kHz で -60dB まで落とすのに
// 要る長さから決めた（遷移域は入力レートで見ると factor に依らない）。
// 56 で阻止域は -73dB ほど、往復の遅延は 55 サンプル（48kHz で 1.15ms）。
// 48 だと 24kHz で -47dB、52 でも -56dB で、どちらも -60dB に届かない。
#define TAPS_PER_PHASE 56

// 遮断（-6dB の点）。入力レートに対する比で、48kHz 入力なら 22kHz。
// 通過域の端 20kHz と入力ナイキスト 24kHz のちょうど中。
// 以前はナイキストそのもの（0.5）に置いていたので、非線形エフェクトが
// 24〜28kHz に作った倍音が -22dB（26kHz→22kHz）しか落ちずに可聴域へ折り返していた。
#define CUTOFF_OF_INPUT_RATE (22.0 / 48.0)

// Kaiser 窓の形。7.25 で阻止域 -73dB と通過域の平坦さ（往復で ±0.004dB）の釣り合いが取れる。
#define KAISER_BETA 7.25

struct ETResampler {
    uint32_t factor;
    uint32_t channels;
    uint32_t tapsPerPhase;      // K
    float   *proto;             // factor*K。位相ごとに並べてある
    float   *historyUp;         // channels * ringUp
    float   *historyDown;       // channels * ringDown
    uint32_t maxFrames;
    // 巡回の書き込み位置。巡回の長さは K と factor*K 以上の 2 の冪にして、マスクで回す。
    uint32_t ringUp;
    uint32_t ringDown;
    uint32_t posUp;
    uint32_t posDown;
    uint32_t maskUp;
    uint32_t maskDown;
};

static uint32_t nextPowerOfTwo(uint32_t v)
{
    uint32_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

static double sincd(double x)
{
    if (x > -1e-12 && x < 1e-12) return 1.0;
    return sin(kPi * x) / (kPi * x);
}

/// 0 次の変形ベッセル関数。Kaiser 窓に使う。級数が収まるまで足す。
static double besselI0(double x)
{
    const double q = x * x * 0.25;
    double term = 1.0, sum = 1.0;
    for (int k = 1; k < 200; k++) {
        term *= q / ((double)k * (double)k);
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

/// Kaiser 窓つき sinc。遮断は入力レートの CUTOFF_OF_INPUT_RATE。
/// 位相 p、タップ k の係数を proto[p * K + k] に置く。
static void design(float *proto, uint32_t factor, uint32_t K)
{
    const uint32_t L = factor * K;
    const double cutoff = CUTOFF_OF_INPUT_RATE / (double)factor;   // 高レート側の正規化周波数
    double *h = (double *)calloc(L, sizeof(double));
    if (!h) return;

    const double center = (double)(L - 1) * 0.5;
    const double norm = besselI0(KAISER_BETA);
    for (uint32_t n = 0; n < L; n++) {
        const double t = (double)n - center;
        const double x = 2.0 * (double)n / (double)(L - 1) - 1.0;
        const double w = besselI0(KAISER_BETA * sqrt(fmax(0.0, 1.0 - x * x))) / norm;
        h[n] = 2.0 * cutoff * sincd(2.0 * cutoff * t) * w;
    }

    // 位相ごとに直流で利得 1/factor に揃える（Up は factor 倍して 1 になる）。
    // 全体で揃えるだけだと 4 倍のとき位相ごとの利得が 1e-5 ほどずれ、直流が
    // 48kHz・96kHz の小さな音として出る。位相ごとに揃えるとそこが厳密に 0 になる。
    for (uint32_t p = 0; p < factor; p++) {
        double sum = 0.0;
        for (uint32_t k = 0; k < K; k++) sum += h[k * factor + p];
        if (sum > 1e-12) {
            const double scale = 1.0 / ((double)factor * sum);
            for (uint32_t k = 0; k < K; k++) h[k * factor + p] *= scale;
        }
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
    r->ringUp   = nextPowerOfTwo(K);
    r->ringDown = nextPowerOfTwo(factor * K);
    r->proto       = (float *)calloc((size_t)factor * K, sizeof(float));
    r->historyUp   = (float *)calloc((size_t)channels * r->ringUp, sizeof(float));
    r->historyDown = (float *)calloc((size_t)channels * r->ringDown, sizeof(float));

    if (!r->proto || !r->historyUp || !r->historyDown) {
        ETResampler_Destroy(r);
        return NULL;
    }

    r->maskUp   = r->ringUp - 1;
    r->maskDown = r->ringDown - 1;

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
    // 長さ L = factor*K の対称 FIR を 2 回通すので、高レートで L-1 遅れる。
    // Down は factor 個押し込んだうちの一番新しい位置（m*factor + factor-1）を出すので、
    // 入力 n0 の山は m*factor + factor-1 = n0*factor + L-1 の m に出る。
    // m - n0 = (L - factor) / factor = K - 1。以前は K を返していて 1 サンプル多かった。
    return r->tapsPerPhase - 1;
}

void ETResampler_Reset(ETResampler *r)
{
    if (!r) return;
    memset(r->historyUp, 0, (size_t)r->channels * r->ringUp * sizeof(float));
    memset(r->historyDown, 0, (size_t)r->channels * r->ringDown * sizeof(float));
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
        float       *hist = r->historyUp + (size_t)c * r->ringUp;   // hist[pos] が一番新しい

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
    const uint32_t ch = r->channels;
    const uint32_t inFrames = outFrames * F;

    for (uint32_t c = 0; c < ch; c++) {
        const float *src  = in  + (size_t)c * inFrames;
        float       *dst  = out + (size_t)c * outFrames;
        float       *hist = r->historyDown + (size_t)c * r->ringDown;   // hist[pos] が一番新しい

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
