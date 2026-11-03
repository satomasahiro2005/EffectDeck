//  link_jitter.c
//  受け手の溜まりの方針（ETLinkJitterRead）を、音のスレッド抜きで確かめる。
//  貼り直し・溜まりすぎの切り詰め・枯れの数え方・溜め直し・2048 への逃げ・戻し。

#include "ETLinkCodec.h"
#include "et_check.h"

#include <stdlib.h>

#define RING ET_LINK_RECV_RING_SAMPLES
#define BEHIND (ET_LINK_TARGET_FRAMES * 2u)          // 狙いの溜まり（サンプル）

/// LocalLink.m の ETLinkReceiver が持っているものと同じ組。
typedef struct {
    float *ring;
    uint64_t w;         // 書き位置（サンプル）
    uint64_t r;         // 読み位置（サンプル）
    uint64_t next;      // 次に書く値の通し番号
    ETLinkJitter j;
    float out[8192];
} Rx;

static Rx *rx_new(void) {
    Rx *x = calloc(1, sizeof(Rx));
    x->ring = calloc(RING, sizeof(float));
    ETLinkJitter init = ET_LINK_JITTER_INIT;
    x->j = init;
    return x;
}

static void rx_free(Rx *x) {
    if (!x) return;
    free(x->ring);
    free(x);
}

/// サンプル s（0 から数えて何番目に書いたか）の値。0 は無音と見分けるために使わない。
static float value_of(uint64_t s) { return (float)(s % 4000000u) + 1.0f; }

/// frames フレーム届いたことにする。値は通し番号。
static void rx_feed(Rx *x, uint32_t frames) {
    static float tmp[65536];
    uint32_t left = frames * 2;
    while (left > 0) {
        uint32_t n = left < 65536 ? left : 65536;
        for (uint32_t i = 0; i < n; i++) tmp[i] = value_of(x->next + i);
        ETLinkRingWrite(x->ring, RING, x->w, (const uint8_t *)tmp, n);
        x->w += n;
        x->next += n;
        left -= n;
    }
}

static uint32_t rx_read(Rx *x, uint32_t frames, bool peer, uint64_t received, ETLinkStarve *s) {
    return ETLinkJitterRead(&x->j, x->ring, RING, x->w, &x->r, x->out, frames, peer, received, s);
}

static uint32_t target(Rx *x) { return atomic_load(&x->j.target); }
static uint32_t starves(Rx *x) { return atomic_load(&x->j.starveCount); }
static bool refilling(Rx *x) { return atomic_load(&x->j.refilling); }

/// 溜まりをちょうど狙いにしてから、狙いより多く読んで 1 回枯れさせる。
/// 溜め直しの途中なら、狙いまで溜まったので溜め直しは明ける。
/// 返すのはその回のログ用の値。
static ETLinkStarve starve_at(Rx *x, uint64_t received) {
    uint64_t behind = (uint64_t)target(x) * 2u;
    uint64_t have = x->w > x->r ? x->w - x->r : 0;
    if (x->r == 0) have = x->w;
    if (have < behind) rx_feed(x, (uint32_t)((behind - have) / 2));
    ETLinkStarve s;
    uint32_t got = rx_read(x, target(x) + 100, true, received, &s);
    CHECK(s.counted);
    CHECK_EQ(got, behind / 2);
    return s;
}

// ---- 貼り直し ----

ET_CASE(first_read_anchors_target_behind) {
    Rx *x = rx_new();
    rx_feed(x, 3000);
    // 読み位置 0 は「まだ貼っていない」。書き位置から狙いのぶん下げて置く。
    // （3000 フレームは切り詰めの線＝狙いの 2 倍も越えている。線より下は次の件）
    CHECK_EQ(rx_read(x, 256, true, 3000, NULL), 256);
    CHECK_FEQ(x->out[0], value_of(6000 - BEHIND));
    CHECK_FEQ(x->out[511], value_of(6000 - BEHIND + 511));
    CHECK_EQ(x->r, 6000 - BEHIND + 512);
    // 初回の貼り直しは切り詰めとして数えない。
    CHECK_EQ(atomic_load(&x->j.trimCount), 0);
    rx_free(x);
}

ET_CASE(first_read_anchors_below_trim_line) {
    // 狙いより多く、切り詰めの線（狙いの 2 倍）には届かない量で初めて読む。
    // ここで貼らないと頭から読み始め、狙いの 2 倍近い遅れを抱えたまま
    // 切り詰めにも届かないので、その遅れが戻らない。
    Rx *x = rx_new();
    rx_feed(x, 1500);
    CHECK(x->w > BEHIND);
    CHECK(x->w <= 2 * BEHIND);
    CHECK_EQ(rx_read(x, 256, true, 1500, NULL), 256);
    CHECK_FEQ(x->out[0], value_of(3000 - BEHIND));
    CHECK_FEQ(x->out[511], value_of(3000 - BEHIND + 511));
    CHECK_EQ(x->r, 3000 - BEHIND + 512);
    CHECK_EQ(atomic_load(&x->j.trimCount), 0);
    rx_free(x);
}

ET_CASE(first_read_short_buffer_starts_at_zero) {
    Rx *x = rx_new();
    rx_feed(x, 500);   // 狙いより少ない。頭から読む
    CHECK_EQ(rx_read(x, 256, false, 500, NULL), 256);
    CHECK_FEQ(x->out[0], value_of(0));
    CHECK_EQ(x->r, 512);
    // 相手が居ないので、足りなくても枯れではない。
    CHECK_EQ(rx_read(x, 400, false, 500, NULL), 244);
    CHECK_FEQ(x->out[487], value_of(999));
    CHECK_FEQ(x->out[488], 0.0f);
    CHECK_FEQ(x->out[799], 0.0f);
    CHECK_EQ(starves(x), 0);
    CHECK(!refilling(x));
    rx_free(x);
}

ET_CASE(trim_at_twice_target) {
    Rx *x = rx_new();
    rx_feed(x, 4000);
    rx_read(x, 0, true, 4000, NULL);            // 貼る: r = w - 狙い
    CHECK_EQ(x->w - x->r, BEHIND);
    // 狙いの 2 倍ちょうどまでは切り詰めない。
    rx_feed(x, ET_LINK_TARGET_FRAMES);
    CHECK_EQ(x->w - x->r, 2 * BEHIND);
    uint64_t r0 = x->r;
    CHECK_EQ(rx_read(x, 1, true, 5024, NULL), 1);
    CHECK_EQ(x->r, r0 + 2);
    CHECK_EQ(atomic_load(&x->j.trimCount), 0);
    // 2 倍を 1 フレームでも越えたら、狙いまで捨てる。
    rx_feed(x, 2);
    CHECK_EQ(x->w - x->r, 2 * BEHIND + 2);
    r0 = x->r;
    CHECK_EQ(rx_read(x, 1, true, 5026, NULL), 1);
    CHECK_EQ(atomic_load(&x->j.trimCount), 1);
    CHECK_EQ(atomic_load(&x->j.trimFrames), (x->w - BEHIND - r0) / 2);
    CHECK_EQ(atomic_load(&x->j.trimFrames), ET_LINK_TARGET_FRAMES + 1);
    CHECK_EQ(x->r, x->w - BEHIND + 2);
    CHECK_FEQ(x->out[0], value_of(x->w - BEHIND));
    rx_free(x);
}

ET_CASE(overrun_reanchors) {
    Rx *x = rx_new();
    rx_feed(x, 3000);
    rx_read(x, 256, true, 3000, NULL);
    uint64_t r0 = x->r;
    // 読み手が止まっているあいだに 1 周より多く書かれた。
    rx_feed(x, RING / 2 + 1000);
    CHECK(x->w > x->r + RING);
    CHECK_EQ(rx_read(x, 256, true, 200000, NULL), 256);
    CHECK_FEQ(x->out[0], value_of(x->w - BEHIND));
    CHECK_EQ(atomic_load(&x->j.trimCount), 1);
    CHECK_EQ(atomic_load(&x->j.trimFrames), (x->w - BEHIND - r0) / 2);
    rx_free(x);
}

ET_CASE(reads_across_ring_wrap) {
    Rx *x = rx_new();
    rx_feed(x, RING / 2 - 100);                 // 端の 200 サンプル手前まで書く
    rx_read(x, 0, true, 1, NULL);               // 貼る
    x->r = RING - 400;                          // 端の 400 サンプル手前から読ませる
    rx_feed(x, 300);                            // 端を越えて 400 サンプル先まで
    CHECK_EQ(x->w, RING + 400);
    CHECK_EQ(rx_read(x, 400, true, 1, NULL), 400);
    for (uint32_t i = 0; i < 800; i++) {
        if (x->out[i] != value_of(RING - 400 + i)) { CHECK_FEQ(x->out[i], value_of(RING - 400 + i)); break; }
    }
    CHECK_EQ(x->r, RING + 400);
    rx_free(x);
}

// ---- 枯れの数え方 ----

ET_CASE(starve_needs_peer_and_settle) {
    Rx *x = rx_new();
    rx_feed(x, 100);
    ETLinkStarve s;
    // 相手が居ない。
    rx_read(x, 256, false, 1000000, &s);
    CHECK(!s.counted);
    // 相手は居るが、繋がってから 48000 フレーム受け取っていない（ちょうどは数えない）。
    rx_read(x, 256, true, ET_LINK_SETTLE_FRAMES, &s);
    CHECK(!s.counted);
    CHECK_EQ(starves(x), 0);
    CHECK(!refilling(x));
    // 1 フレームでも越えたら数える。
    rx_feed(x, 100);
    CHECK_EQ(rx_read(x, 256, true, ET_LINK_SETTLE_FRAMES + 1, &s), 100);
    CHECK(s.counted);
    CHECK_EQ(starves(x), 1);
    CHECK_EQ(atomic_load(&x->j.starveFrames), 156);
    CHECK(refilling(x));
    rx_free(x);
}

ET_CASE(starve_info_for_log) {
    Rx *x = rx_new();
    rx_feed(x, 3000);
    rx_read(x, 0, true, 60000, NULL);           // 貼る: 溜まりは狙いちょうど
    ETLinkStarve s;
    CHECK_EQ(rx_read(x, ET_LINK_TARGET_FRAMES + 76, true, 60000, &s), ET_LINK_TARGET_FRAMES);
    CHECK(s.counted);
    CHECK_EQ(s.filledFrames, 76);
    CHECK_EQ(s.wantFrames, ET_LINK_TARGET_FRAMES + 76);
    CHECK_EQ(s.bufferedFrames, ET_LINK_TARGET_FRAMES);
    CHECK_EQ(s.target, ET_LINK_TARGET_FRAMES);
    CHECK_EQ(s.runBefore, 0);
    // 無音で埋めたところは 0。
    CHECK_FEQ(x->out[2 * ET_LINK_TARGET_FRAMES - 1], value_of(6000 - 1));
    CHECK_FEQ(x->out[2 * ET_LINK_TARGET_FRAMES], 0.0f);
    rx_free(x);
}

ET_CASE(starve_info_after_trim_in_same_read) {
    Rx *x = rx_new();
    rx_feed(x, 4000);
    rx_read(x, 0, true, 60000, NULL);           // 貼る: 溜まりは狙いちょうど
    rx_feed(x, 2000);                           // 狙いの 2 倍を越える
    CHECK_EQ(x->w - x->r, BEHIND + 4000);
    // 同じ回で切り詰めてから枯れる。ログの溜まりは切り詰めた後、読む前の値。
    ETLinkStarve s;
    CHECK_EQ(rx_read(x, ET_LINK_TARGET_FRAMES + 10, true, 60000, &s), ET_LINK_TARGET_FRAMES);
    CHECK_EQ(atomic_load(&x->j.trimCount), 1);
    CHECK(s.counted);
    CHECK_EQ(s.bufferedFrames, ET_LINK_TARGET_FRAMES);
    CHECK_EQ(s.filledFrames, 10);
    CHECK_EQ(s.target, ET_LINK_TARGET_FRAMES);
    CHECK_EQ(s.runBefore, 0);
    rx_free(x);
}

// ---- 溜め直し ----

ET_CASE(refill_waits_until_target) {
    Rx *x = rx_new();
    starve_at(x, 60000);
    CHECK(refilling(x));
    // 狙いに届くまでは、溜まっていても読まずに無音を返す。
    rx_feed(x, ET_LINK_TARGET_FRAMES - 1);
    uint64_t r0 = x->r;
    x->out[0] = 99.0f;
    CHECK_EQ(rx_read(x, 64, true, 61000, NULL), 0);
    CHECK_FEQ(x->out[0], 0.0f);
    CHECK_FEQ(x->out[127], 0.0f);
    CHECK_EQ(x->r, r0);
    CHECK_EQ(atomic_load(&x->j.refillWaits), 1);
    // 狙いちょうどで明けて、その回から読む。
    rx_feed(x, 1);
    CHECK_EQ(rx_read(x, 64, true, 61001, NULL), 64);
    CHECK(!refilling(x));
    CHECK_EQ(atomic_load(&x->j.refillWaits), 0);
    CHECK_FEQ(x->out[0], value_of(r0));
    CHECK_EQ(starves(x), 1);
    rx_free(x);
}

ET_CASE(refill_gives_up_after_200_waits) {
    Rx *x = rx_new();
    starve_at(x, 60000);
    rx_feed(x, 100);                            // 狙いには届かない
    // 200 回は待つ（無音）。
    for (uint32_t i = 0; i < ET_LINK_REFILL_GIVE_UP; i++) {
        if (rx_read(x, 256, true, 60100, NULL) != 0) { CHECK_EQ(i, ET_LINK_REFILL_GIVE_UP); break; }
    }
    CHECK(refilling(x));
    CHECK_EQ(atomic_load(&x->j.refillWaits), ET_LINK_REFILL_GIVE_UP);
    // 201 回目で諦めて、あるだけ読む。足りないのでまた枯れとして数え、溜め直しに入る。
    ETLinkStarve s;
    CHECK_EQ(rx_read(x, 256, true, 60100, &s), 100);
    CHECK_FEQ(x->out[0], value_of(x->w - 200));
    CHECK(s.counted);
    CHECK_EQ(starves(x), 2);
    CHECK(refilling(x));
    CHECK_EQ(atomic_load(&x->j.refillWaits), 0);
    rx_free(x);
}

// ---- 2048 への逃げと戻し ----

ET_CASE(fallback_after_three_starves_within_5s) {
    Rx *x = rx_new();
    starve_at(x, 50000);
    starve_at(x, 60000);
    CHECK_EQ(target(x), ET_LINK_TARGET_FRAMES);
    CHECK_EQ(atomic_load(&x->j.starveRun), 2);
    // 逃げを起こした回のログは、逃げる前の狙い（1024）と数える前の連（2）。
    ETLinkStarve s = starve_at(x, 70000);
    CHECK_EQ(s.target, ET_LINK_TARGET_FRAMES);
    CHECK_EQ(s.runBefore, 2);
    CHECK_EQ(s.bufferedFrames, ET_LINK_TARGET_FRAMES);
    CHECK_EQ(atomic_load(&x->j.starveRun), 3);
    CHECK_EQ(target(x), ET_LINK_TARGET_FALLBACK);
    // 逃げた先から貼り直す。
    rx_feed(x, 5000);
    rx_read(x, 1, true, 80000, NULL);           // 溜め直しが明けて、溜まりすぎなので切り詰める
    CHECK_EQ(x->w - x->r, 2u * ET_LINK_TARGET_FALLBACK - 2);
    rx_free(x);
}

ET_CASE(no_fallback_when_starves_spread) {
    Rx *x = rx_new();
    // 間隔が 5 秒（240000 フレーム）ちょうど以上なら、続いたとは見なさない。
    starve_at(x, 50000);
    starve_at(x, 50000 + ET_LINK_STARVE_NEAR_FRAMES);
    starve_at(x, 50000 + 2 * ET_LINK_STARVE_NEAR_FRAMES);
    CHECK_EQ(atomic_load(&x->j.starveRun), 1);
    CHECK_EQ(target(x), ET_LINK_TARGET_FRAMES);
    CHECK_EQ(starves(x), 3);
    // 1 フレームでも短ければ続いたと見なす。
    starve_at(x, 50000 + 3 * ET_LINK_STARVE_NEAR_FRAMES - 1);
    CHECK_EQ(atomic_load(&x->j.starveRun), 2);
    CHECK_EQ(target(x), ET_LINK_TARGET_FRAMES);
    rx_free(x);
}

ET_CASE(reset_returns_to_1024) {
    Rx *x = rx_new();
    starve_at(x, 50000);
    starve_at(x, 51000);
    starve_at(x, 52000);
    rx_feed(x, 10000);
    rx_read(x, 1, true, 53000, NULL);
    CHECK_EQ(target(x), ET_LINK_TARGET_FALLBACK);
    CHECK(atomic_load(&x->j.trimCount) > 0);
    starve_at(x, 54000);
    CHECK(refilling(x));
    ETLinkJitterReset(&x->j);
    CHECK_EQ(target(x), ET_LINK_TARGET_FRAMES);
    CHECK_EQ(starves(x), 0);
    CHECK_EQ(atomic_load(&x->j.starveFrames), 0);
    CHECK_EQ(atomic_load(&x->j.trimCount), 0);
    CHECK_EQ(atomic_load(&x->j.trimFrames), 0);
    CHECK(!refilling(x));
    CHECK_EQ(atomic_load(&x->j.refillWaits), 0);
    CHECK_EQ(atomic_load(&x->j.lastStarveAt), 0);
    CHECK_EQ(atomic_load(&x->j.starveRun), 0);
    // 戻したあとの 1 回目は、前の連を引き継がない。
    starve_at(x, 55000);
    CHECK_EQ(atomic_load(&x->j.starveRun), 1);
    rx_free(x);
}

int main(int argc, char **argv) {
    static const et_case cases[] = {
        ET_ENTRY(first_read_anchors_target_behind),
        ET_ENTRY(first_read_anchors_below_trim_line),
        ET_ENTRY(first_read_short_buffer_starts_at_zero),
        ET_ENTRY(trim_at_twice_target),
        ET_ENTRY(overrun_reanchors),
        ET_ENTRY(reads_across_ring_wrap),
        ET_ENTRY(starve_needs_peer_and_settle),
        ET_ENTRY(starve_info_for_log),
        ET_ENTRY(starve_info_after_trim_in_same_read),
        ET_ENTRY(refill_waits_until_target),
        ET_ENTRY(refill_gives_up_after_200_waits),
        ET_ENTRY(fallback_after_three_starves_within_5s),
        ET_ENTRY(no_fallback_when_starves_spread),
        ET_ENTRY(reset_returns_to_1024),
    };
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
