// ETJSFXBenchPorts.cpp — Debug/JSFXBench の各スクリプトを手で C++ に写したもの（実行系 "cpp"）。
//
// 「前もって機械語にしたらここまで速くなる」の上限として測る。**中身は JSFX と同じ計算にする:**
//   - double で、式の順序も JSFX のとおり（a * b + c は (a * b) + c）。FMA へまとめさせない
//     （下の fp contract(off)。clang は既定で 1 つの式の中の積和を FMA にする）
//   - 入力は ysfx と同じく double にして 1e-16 を足す（ysfx_process_generic の denorm_value）
//   - 変数はブロックをまたいで残る（JSFX の変数は全部大域）。@init → @slider の順に回してから音を通す
//   - メモリの添字は EEL と同じく (unsigned)(値 + 0.00001)（glue_port.h の EEL_BC_MEGABUF）
//   - loop の回数は (int) で切り捨て、1048576 で頭打ち（NSEEL_LOOPFUNC_SUPPORT_MAXLEN）
//   - min / max は EEL_BC_MIN / EEL_BC_MAX と同じ比べ方
//   - 出力は float に戻して、ホストと同じく拭く（scrubOutput）
// EEL が代入で掛ける非正規化数の拭き（denormal_filter_double2）は写さない。どのスクリプトも
// 有限で正規の値しか作らないので、写しても結果は変わらない（照合で確かめる）。
// **スクリプトを変えたらここも。**照合（cpp と portable の差）が落ちて気づく。
#include "ETJSFXBenchEngine.h"

#if ET_JSFX_BENCH
#include <cmath>
#include <cstring>
#include <vector>

#pragma clang fp contract(off)

namespace etbench {
namespace {

constexpr double kPi = 3.141592653589793;   // EEL の $pi（nseel-compiler.c）
constexpr double kDenorm = 0.0000000000000001;
constexpr int kLoopMax = 1048576;

inline double eelMin(double a, double b) { return a > b ? b : a; }
inline double eelMax(double a, double b) { return a < b ? b : a; }
inline size_t eelIndex(double v) { return (size_t)(unsigned int)(v + 0.00001); }
inline int eelLoopCount(double n) { int c = (int)n; return c > kLoopMax ? kLoopMax : c; }

/// 1 サンプルずつの本体（sample(s0, s1)）を、ホストと同じ入出力で回す。
template <class Self>
struct StereoPort : Engine {
    void process(float *planar, uint32_t channels, uint32_t frames, double) override
    {
        if (channels < 2) return;
        float *left = planar, *right = planar + frames;
        auto &self = static_cast<Self &>(*this);
        for (uint32_t i = 0; i < frames; ++i) {
            double s0 = (double)left[i] + kDenorm, s1 = (double)right[i] + kDenorm;
            self.sample(s0, s1);
            left[i] = (float)s0; right[i] = (float)s1;
        }
        scrubOutput(planar, (size_t)channels * frames);
    }
};

// gain.jsfx
struct Gain final : StereoPort<Gain> {
    double slider1 = 1, g = 0;
    explicit Gain(double) { g = 1; g = slider1; }
    inline void sample(double &s0, double &s1) { s0 *= g; s1 *= g; }
};

// filter_drive.jsfx（EffectDeck DSP Filter + Drive の写し）
struct FilterDrive final : StereoPort<FilterDrive> {
    double srate, cutoff = 1200, drive_db = 12, mix = 100, output_db = -6;
    double z1_l = 0, z1_r = 0, coefficient = 0, drive = 0, wet = 0, output = 0;
    double target_coefficient = 0, target_drive = 0, target_wet = 0, target_output = 0;
    double dry = 0, input_l = 0, input_r = 0, shaped_l = 0, shaped_r = 0, driven_l = 0, driven_r = 0;
    explicit FilterDrive(double rate) : srate(rate)
    {
        z1_l = 0; z1_r = 0;
        coefficient = std::exp(-2 * kPi * cutoff / srate);
        drive = std::pow(10.0, drive_db / 20);
        wet = mix / 100;
        output = std::pow(10.0, output_db / 20);
        target_coefficient = std::exp(-2 * kPi * cutoff / srate);
        target_drive = std::pow(10.0, drive_db / 20);
        target_wet = mix / 100;
        target_output = std::pow(10.0, output_db / 20);
    }
    inline void sample(double &s0, double &s1)
    {
        coefficient += (target_coefficient - coefficient) * 0.002;
        drive += (target_drive - drive) * 0.002;
        wet += (target_wet - wet) * 0.002;
        output += (target_output - output) * 0.002;
        dry = 1 - wet;
        input_l = s0;
        input_r = s1;
        z1_l = input_l + coefficient * (z1_l - input_l);
        z1_r = input_r + coefficient * (z1_r - input_r);
        shaped_l = z1_l * drive;
        shaped_r = z1_r * drive;
        driven_l = shaped_l / (1 + std::fabs(shaped_l));
        driven_r = shaped_r / (1 + std::fabs(shaped_r));
        s0 = (input_l * dry + driven_l * wet) * output;
        s1 = (input_r * dry + driven_r * wet) * output;
    }
};

// stereo_delay.jsfx（EffectDeck DSP Stereo Delay の写し）
struct StereoDelay final : StereoPort<StereoDelay> {
    double srate, delay_ms = 280, feedback = 45, mix = 35, crossfeed = 25;
    double max_delay = 0, left_buffer = 0, right_buffer = 0, write_position = 0;
    double delay_samples = 0, feedback_gain = 0, wet = 0, dry = 0, cross = 0;
    double read_position = 0, delayed_l = 0, delayed_r = 0, input_l = 0, input_r = 0;
    std::vector<double> mem;
    explicit StereoDelay(double rate) : srate(rate)
    {
        max_delay = eelMin(1000000, std::ceil(srate * 1.1));
        left_buffer = 0;
        right_buffer = max_delay;
        write_position = 0;
        mem.assign(eelIndex(max_delay * 2) + 1, 0.0);   // memset(left_buffer, 0, max_delay * 2)
        delay_samples = eelMax(1, eelMin(max_delay - 1, std::floor(delay_ms * srate / 1000)));
        feedback_gain = feedback / 100;
        wet = mix / 100;
        dry = 1 - wet;
        cross = crossfeed / 100;
    }
    inline void sample(double &s0, double &s1)
    {
        read_position = write_position - delay_samples;
        if (read_position < 0) read_position += max_delay;
        delayed_l = mem[eelIndex(left_buffer + read_position)];
        delayed_r = mem[eelIndex(right_buffer + read_position)];
        input_l = s0;
        input_r = s1;
        mem[eelIndex(left_buffer + write_position)] = input_l + (delayed_l * (1 - cross) + delayed_r * cross) * feedback_gain;
        mem[eelIndex(right_buffer + write_position)] = input_r + (delayed_r * (1 - cross) + delayed_l * cross) * feedback_gain;
        write_position += 1;
        if (write_position >= max_delay) write_position = 0;
        s0 = input_l * dry + delayed_l * wet;
        s1 = input_r * dry + delayed_r * wet;
    }
};

// slow.jsfx（1 サンプルに loop を n 周。音は素通し）
struct Slow final : StereoPort<Slow> {
    double slider1 = 200, n = 0, i = 0;
    explicit Slow(double) { n = 200; n = slider1; }
    inline void sample(double &, double &)
    {
        i = 0;
        for (int c = eelLoopCount(n); c > 0; --c) i += 1;
    }
};

// biquad.jsfx（関数と instance の名前空間 l1..l4 / r1..r4）
struct Biquad final : StereoPort<Biquad> {
    struct Peak { double b0 = 0, b1 = 0, b2 = 0, a1 = 0, a2 = 0, s1 = 0, s2 = 0; };
    double srate, f[4] = {90, 450, 2200, 9000}, g[4] = {4, -3, 2.5, -5}, q = 1.1;
    Peak l[4], r[4];
    void set(Peak &p, double freq, double gain_db, double width)
    {
        double amp = std::pow(10.0, gain_db / 40);
        double w0 = 2 * kPi * freq / srate;
        double cw = std::cos(w0);
        double alpha = std::sin(w0) / (2 * width);
        double a0inv = 1 / (1 + alpha / amp);
        p.b0 = (1 + alpha * amp) * a0inv;
        p.b1 = -2 * cw * a0inv;
        p.b2 = (1 - alpha * amp) * a0inv;
        p.a1 = p.b1;
        p.a2 = (1 - alpha / amp) * a0inv;
    }
    static inline double tick(Peak &p, double x)
    {
        double y = p.b0 * x + p.s1;
        p.s1 = p.b1 * x - p.a1 * y + p.s2;
        p.s2 = p.b2 * x - p.a2 * y;
        return y;
    }
    explicit Biquad(double rate) : srate(rate)
    {
        for (int b = 0; b < 4; ++b) { l[b].s1 = l[b].s2 = 0; r[b].s1 = r[b].s2 = 0; }
        for (int b = 0; b < 4; ++b) { set(l[b], f[b], g[b], q); set(r[b], f[b], g[b], q); }
    }
    inline void sample(double &s0, double &s1)
    {
        s0 = tick(l[3], tick(l[2], tick(l[1], tick(l[0], s0))));
        s1 = tick(r[3], tick(r[2], tick(r[1], tick(r[0], s1))));
    }
};

// fir.jsfx（64 タップ。係数と履歴はメモリ 0..191）
struct FIR final : StereoPort<FIR> {
    double srate, cutoff = 3000;
    double taps = 0, coef = 0, hist_l = 0, hist_r = 0, pos = 0;
    double fc = 0, sum = 0, k = 0, t = 0, w = 0, acc_l = 0, acc_r = 0, j = 0, c = 0;
    std::vector<double> mem;
    explicit FIR(double rate) : srate(rate), mem(65536, 0.0)
    {
        taps = 64; coef = 0; hist_l = 64; hist_r = 128; pos = 0;
        for (double v = 0; v < taps * 2; v += 1) mem[eelIndex(hist_l + v)] = 0;   // memset
        fc = cutoff / srate;
        sum = 0;
        k = 0;
        for (int n = eelLoopCount(taps); n > 0; --n) {
            t = k - (taps - 1) / 2;
            w = 0.54 - 0.46 * std::cos(2 * kPi * k / (taps - 1));
            mem[eelIndex(coef + k)] = std::sin(2 * kPi * fc * t) / (kPi * t) * w;
            sum += mem[eelIndex(coef + k)];
            k += 1;
        }
        k = 0;
        for (int n = eelLoopCount(taps); n > 0; --n) {
            mem[eelIndex(coef + k)] /= sum;
            k += 1;
        }
    }
    inline void sample(double &s0, double &s1)
    {
        mem[eelIndex(hist_l + pos)] = s0;
        mem[eelIndex(hist_r + pos)] = s1;
        acc_l = 0;
        acc_r = 0;
        k = 0;
        j = pos;
        for (int n = eelLoopCount(taps); n > 0; --n) {
            c = mem[eelIndex(coef + k)];
            acc_l += c * mem[eelIndex(hist_l + j)];
            acc_r += c * mem[eelIndex(hist_r + j)];
            k += 1;
            j -= 1;
            if (j < 0) j += taps;
        }
        pos += 1;
        if (pos >= taps) pos = 0;
        s0 = acc_l;
        s1 = acc_r;
    }
};

// math.jsfx（sin・exp・log・pow と、値で回数の変わる while）
struct Math final : StereoPort<Math> {
    double srate, drive = 4, rate = 3, mix = 50;
    double phase = 0, two_pi = 0, inc = 0, wet = 0, dry = 0, lfo = 0, k = 0;
    double e_l = 0, e_r = 0, t_l = 0, t_r = 0, m = 0, p_l = 0, p_r = 0, x = 0, n = 0, g = 0;
    explicit Math(double sr) : srate(sr)
    {
        phase = 0;
        two_pi = 2 * kPi;
        inc = two_pi * rate / srate;
        wet = mix / 100;
        dry = 1 - wet;
    }
    inline void sample(double &s0, double &s1)
    {
        phase += inc;
        if (phase >= two_pi) phase -= two_pi;
        lfo = 0.5 + 0.5 * std::sin(phase);
        k = drive * (0.5 + lfo);
        e_l = std::exp(2 * k * s0);
        e_r = std::exp(2 * k * s1);
        t_l = (e_l - 1) / (e_l + 1);
        t_r = (e_r - 1) / (e_r + 1);
        m = std::log(1 + std::fabs(s0 + s1) * 8);
        p_l = std::pow(std::fabs(s0) + 0.001, 0.6 + 0.3 * lfo);
        p_r = std::pow(std::fabs(s1) + 0.001, 0.6 + 0.3 * lfo);
        x = std::fabs(s0 * k) * 64 + 1;
        n = 0;
        int guard = kLoopMax;
        do { x *= 0.5; n += 1; } while (x > 0.25 && --guard > 0);
        g = 1 / (1 + 0.02 * n);
        s0 = (s0 * dry + (t_l + 0.1 * p_l * m) * wet) * g;
        s1 = (s1 * dry + (t_r + 0.1 * p_r * m) * wet) * g;
    }
};

template <class T>
std::unique_ptr<Engine> make(double rate) { return std::unique_ptr<Engine>(new T(rate)); }

} // namespace

void scrubOutput(float *planar, size_t count)
{
    for (size_t i = 0; i < count; ++i) {
        uint32_t bits; std::memcpy(&bits, planar + i, 4);
        const uint32_t exponent = bits & 0x7f800000u;
        bits = (exponent == 0 || exponent == 0x7f800000u) ? 0u : bits;
        std::memcpy(planar + i, &bits, 4);
    }
}

std::unique_ptr<Engine> makeCppPort(const std::string &name, double rate, uint32_t)
{
    if (name == "gain") return make<Gain>(rate);
    if (name == "filter_drive") return make<FilterDrive>(rate);
    if (name == "stereo_delay") return make<StereoDelay>(rate);
    if (name == "slow") return make<Slow>(rate);
    if (name == "biquad") return make<Biquad>(rate);
    if (name == "fir") return make<FIR>(rate);
    if (name == "math") return make<Math>(rate);
    return nullptr;
}

} // namespace etbench
#endif
