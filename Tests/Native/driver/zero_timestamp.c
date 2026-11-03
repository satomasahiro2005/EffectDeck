//  zero_timestamp.c
//  ドライバのゼロタイムスタンプ（ETZeroTimeStamp）を、mach_absolute_time 抜きで確かめる。
//  now を外から渡すので、周期の境目や長い空白を狙って作れる。

#include "ETZeroTimeStamp.h"
#include "et_check.h"

#include <math.h>

/// EffeTuneDriver.m の kRingFrames と kSampleRate。
#define PERIOD 16384u
#define RATE 48000.0

/// Apple シリコンの mach_timebase_info は 125/3（24 MHz）、シミュレータの Intel は 1/1（ns）。
static double ticks_apple(void) { return ETZeroTimeStamp_HostTicksPerFrame(RATE, 125, 3); }
static double ticks_ns(void) { return ETZeroTimeStamp_HostTicksPerFrame(RATE, 1, 1); }

/// n 周期ぶんのホストティック。ドライバと同じ順で掛ける（丸めまで揃える）。
static uint64_t period_ticks(double tpf, uint64_t n) {
    return (uint64_t)((double)n * (tpf * (double)PERIOD));
}

typedef struct {
    double st;
    uint64_t ht;
    uint64_t seed;
} Stamp;

static Stamp get(ETZeroTimeStamp *z, uint64_t now, double tpf) {
    Stamp s = {-1, 0, 0};
    ETZeroTimeStamp_Get(z, now, tpf, PERIOD, &s.st, &s.ht, &s.seed);
    return s;
}

ET_CASE(ticks_per_frame_from_timebase) {
    CHECK(fabs(ticks_apple() - 500.0) < 1e-9);
    CHECK(fabs(ticks_ns() - 1.0e9 / 48000.0) < 1e-9);
    // 1 周期は 16384 / 48000 秒 = 341.33 ms。
    CHECK_EQ(period_ticks(ticks_ns(), 1), 341333333u);
}

ET_CASE(first_get_anchors_at_now) {
    ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
    CHECK(!z.running);
    CHECK_EQ(z.seed, 1);
    Stamp s = get(&z, 1000000, ticks_apple());
    CHECK_FEQ(s.st, 0.0);
    CHECK_EQ(s.ht, 1000000);
    CHECK_EQ(s.seed, 1);
    CHECK_EQ(z.anchorHostTime, 1000000);
    CHECK_FEQ(z.lastSampleTime, 0.0);
    CHECK_EQ(z.lastHostTime, 1000000);
}

ET_CASE(whole_periods_monotonic) {
    const double tpf[2] = {ticks_apple(), ticks_ns()};
    for (int t = 0; t < 2; t++) {
        ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
        const uint64_t anchor = 123456789;
        const uint64_t step = period_ticks(tpf[t], 1) / 7 + 13;   // 1 周期に 7 回ほど呼ばれる
        double lastSt = 0;
        int bad = 0;
        for (uint64_t now = anchor; now < anchor + period_ticks(tpf[t], 20); now += step) {
            Stamp s = get(&z, now, tpf[t]);
            uint64_t n = (uint64_t)s.st / PERIOD;
            if (fmod(s.st, (double)PERIOD) != 0.0) bad++;               // 周期の整数倍
            if (s.st != lastSt && s.st != lastSt + PERIOD) bad++;       // 0 か 1 周期ずつ
            if (s.ht != anchor + period_ticks(tpf[t], n)) bad++;        // 基準 + n 周期
            if (s.ht > now) bad++;                                      // 先の時刻は出さない
            if (s.seed != 1) bad++;
            lastSt = s.st;
        }
        CHECK_EQ(bad, 0);
        CHECK(lastSt >= 19.0 * PERIOD);
    }
}

ET_CASE(advances_exactly_at_period_boundary) {
    ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
    const double tpf = ticks_ns();
    const uint64_t anchor = 5000;
    get(&z, anchor, tpf);
    Stamp s = get(&z, anchor + period_ticks(tpf, 1) - 1, tpf);
    CHECK_FEQ(s.st, 0.0);
    CHECK_EQ(s.ht, anchor);
    s = get(&z, anchor + period_ticks(tpf, 1), tpf);
    CHECK_FEQ(s.st, (double)PERIOD);
    CHECK_EQ(s.ht, anchor + period_ticks(tpf, 1));
    s = get(&z, anchor + period_ticks(tpf, 2) - 1, tpf);
    CHECK_FEQ(s.st, (double)PERIOD);
}

ET_CASE(catch_up_one_period_per_call) {
    // 呼ばれ方が 10 周期ぶん空いても、1 回に 1 周期ずつしか進まない。
    ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
    const double tpf = ticks_apple();
    const uint64_t anchor = 777;
    get(&z, anchor, tpf);
    const uint64_t late = anchor + period_ticks(tpf, 10) + 5;
    for (uint64_t n = 1; n <= 10; n++) {
        Stamp s = get(&z, late, tpf);
        CHECK_FEQ(s.st, (double)(n * PERIOD));
        CHECK_EQ(s.ht, anchor + period_ticks(tpf, n));
    }
    Stamp s = get(&z, late, tpf);
    CHECK_FEQ(s.st, 10.0 * PERIOD);
    s = get(&z, late, tpf);
    CHECK_FEQ(s.st, 10.0 * PERIOD);
}

ET_CASE(seed_constant_between_starts) {
    ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
    ETZeroTimeStamp_StartIO(&z);
    const double tpf = ticks_apple();
    uint64_t seed = 0;
    for (uint64_t i = 0; i < 100; i++) {
        Stamp s = get(&z, 1000 + i * period_ticks(tpf, 1) / 3, tpf);
        if (i == 0) seed = s.seed;
        CHECK_EQ(s.seed, seed);
    }
    CHECK_EQ(seed, 2);
}

ET_CASE(start_rewinds_and_bumps_seed) {
    ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
    const double tpf = ticks_apple();
    ETZeroTimeStamp_StartIO(&z);
    CHECK(z.running);
    CHECK_EQ(z.seed, 2);
    get(&z, 1000, tpf);
    for (int i = 0; i < 5; i++) get(&z, 1000 + period_ticks(tpf, 5), tpf);
    CHECK_EQ(z.periodCount, 5);
    // 張り直す。前のタイムラインの続きではなく、その時点から 0 で始まる。
    ETZeroTimeStamp_StartIO(&z);
    CHECK_EQ(z.anchorHostTime, 0);
    CHECK_EQ(z.periodCount, 0);
    CHECK_FEQ(z.lastSampleTime, 0.0);
    CHECK_EQ(z.lastHostTime, 0);
    Stamp s = get(&z, 99999999, tpf);
    CHECK_FEQ(s.st, 0.0);
    CHECK_EQ(s.ht, 99999999);
    CHECK_EQ(s.seed, 3);
}

ET_CASE(double_start_resets) {
    // StopIO を挟まない StartIO 2 回（D4: 数えずに毎回張り直す、がいまの答え）。
    ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
    const double tpf = ticks_ns();
    ETZeroTimeStamp_StartIO(&z);
    get(&z, 10, tpf);
    get(&z, 10 + period_ticks(tpf, 1), tpf);
    ETZeroTimeStamp_StartIO(&z);                 // 2 つ目のクライアント
    CHECK(z.running);
    CHECK_EQ(z.seed, 3);                         // 2 回とも進める
    Stamp s = get(&z, 10 + period_ticks(tpf, 3), tpf);
    CHECK_FEQ(s.st, 0.0);                        // 1 つ目のタイムラインは続かない
    CHECK_EQ(s.ht, 10 + period_ticks(tpf, 3));
    // 最初の StopIO で止まったことになる。
    ETZeroTimeStamp_StopIO(&z);
    CHECK(!z.running);
    ETZeroTimeStamp_StopIO(&z);
    CHECK(!z.running);
    CHECK_EQ(z.seed, 3);                         // 止めても seed は動かない
}

ET_CASE(stop_keeps_timeline) {
    ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
    const double tpf = ticks_apple();
    ETZeroTimeStamp_StartIO(&z);
    const uint64_t anchor = 4242;
    get(&z, anchor, tpf);
    get(&z, anchor + period_ticks(tpf, 2), tpf);
    get(&z, anchor + period_ticks(tpf, 2), tpf);
    CHECK_EQ(z.periodCount, 2);
    ETZeroTimeStamp_StopIO(&z);
    CHECK(!z.running);
    Stamp s = get(&z, anchor + period_ticks(tpf, 3), tpf);
    CHECK_FEQ(s.st, 3.0 * PERIOD);
    CHECK_EQ(s.ht, anchor + period_ticks(tpf, 3));
    CHECK_EQ(s.seed, 2);
}

ET_CASE(initialize_drops_anchor_keeps_seed) {
    ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
    const double tpf = ticks_apple();
    ETZeroTimeStamp_StartIO(&z);
    get(&z, 100, tpf);
    get(&z, 100 + period_ticks(tpf, 1), tpf);
    ETZeroTimeStamp_Initialize(&z);
    CHECK_EQ(z.seed, 2);
    CHECK(z.running);
    Stamp s = get(&z, 5000000, tpf);
    CHECK_FEQ(s.st, 0.0);
    CHECK_EQ(s.ht, 5000000);
    CHECK_EQ(s.seed, 2);
}

ET_CASE(null_outputs_ok) {
    ETZeroTimeStamp z = ET_ZERO_TIMESTAMP_INIT;
    const double tpf = ticks_ns();
    ETZeroTimeStamp_Get(&z, 50, tpf, PERIOD, NULL, NULL, NULL);
    ETZeroTimeStamp_Get(&z, 50 + period_ticks(tpf, 1), tpf, PERIOD, NULL, NULL, NULL);
    CHECK_EQ(z.anchorHostTime, 50);
    CHECK_EQ(z.periodCount, 1);
    CHECK_FEQ(z.lastSampleTime, (double)PERIOD);
    ETZeroTimeStamp_Get(NULL, 0, tpf, PERIOD, NULL, NULL, NULL);
    ETZeroTimeStamp_StartIO(NULL);
    ETZeroTimeStamp_StopIO(NULL);
    ETZeroTimeStamp_Initialize(NULL);
}

int main(int argc, char **argv) {
    static const et_case cases[] = {
        ET_ENTRY(ticks_per_frame_from_timebase),
        ET_ENTRY(first_get_anchors_at_now),
        ET_ENTRY(whole_periods_monotonic),
        ET_ENTRY(advances_exactly_at_period_boundary),
        ET_ENTRY(catch_up_one_period_per_call),
        ET_ENTRY(seed_constant_between_starts),
        ET_ENTRY(start_rewinds_and_bumps_seed),
        ET_ENTRY(double_start_resets),
        ET_ENTRY(stop_keeps_timeline),
        ET_ENTRY(initialize_drops_anchor_keeps_seed),
        ET_ENTRY(null_outputs_ok),
    };
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
