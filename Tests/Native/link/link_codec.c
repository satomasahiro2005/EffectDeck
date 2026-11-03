//  link_codec.c
//  LocalLink の線の形式（ETLinkCodec の送り手のリング・チャンクの組み立て・
//  受け手の再同期）を、ソケット抜きで確かめる。

#include "ETLinkCodec.h"
#include "et_check.h"

#include <math.h>
#include <stdlib.h>

// ---- 道具 ----

/// ヘッダを手で組む。magic や count をわざと壊すのに使う。
static size_t put_header(uint8_t *dst, uint64_t magic, uint32_t count) {
    memcpy(dst, &magic, sizeof(magic));
    memcpy(dst + 8, &count, sizeof(count));
    return ET_LINK_HDR_BYTES;
}

/// 正しいチャンクを手で組む。値は base, base+1, ...
static size_t put_chunk(uint8_t *dst, uint32_t count, float base) {
    size_t n = put_header(dst, ET_LINK_MAGIC, count);
    for (uint32_t i = 0; i < count; i++) {
        float v = base + (float)i;
        memcpy(dst + n, &v, sizeof(v));
        n += sizeof(v);
    }
    return n;
}

/// consume が渡したチャンクを溜める。
typedef struct {
    float values[65536];
    size_t count;
    size_t chunks;
    uint32_t lastCount;
} Sink;

static void sink_chunk(void *ctx, const uint8_t *payload, uint32_t count) {
    Sink *s = (Sink *)ctx;
    for (uint32_t i = 0; i < count && s->count < sizeof(s->values) / sizeof(s->values[0]); i++) {
        memcpy(&s->values[s->count++], payload + (size_t)i * sizeof(float), sizeof(float));
    }
    s->chunks++;
    s->lastCount = count;
}

static Sink gSink;
static void sink_reset(void) { memset(&gSink, 0, sizeof(gSink)); }

static uint8_t gRx[ET_LINK_RX_BUF_BYTES];

/// 何度でも同じ乱れたバイトを作る。正しいマジックが紛れていないことも確かめる。
static void fill_garbage(uint8_t *dst, size_t n, unsigned seed) {
    et_lcg_state = seed;
    for (size_t i = 0; i < n; i++) dst[i] = (uint8_t)(et_lcg() & 0xffu);
}

static int contains_magic(const uint8_t *p, size_t n) {
    uint64_t magic = ET_LINK_MAGIC;
    for (size_t i = 0; i + 8 <= n; i++) if (memcmp(p + i, &magic, 8) == 0) return 1;
    return 0;
}

// ---- 送り手 ----

ET_CASE(encoder_header_layout) {
    float ring[64];
    for (int i = 0; i < 64; i++) ring[i] = (float)i * 0.5f;
    uint8_t chunk[ET_LINK_CHUNK_BYTES];
    size_t bytes = 0;
    uint64_t r = 0;
    uint32_t n = ETLinkEncodeNext(chunk, &bytes, ring, 64, 10, &r);
    CHECK_EQ(n, 10);
    CHECK_EQ(bytes, ET_LINK_HDR_BYTES + 10 * sizeof(float));
    CHECK_EQ(r, 10);
    // リトルエンディアンのまま書くので "1001KLTE" と並ぶ。
    CHECK(memcmp(chunk, "1001KLTE", 8) == 0);
    CHECK_EQ(chunk[8], 10);
    CHECK_EQ(chunk[9], 0);
    CHECK_EQ(chunk[10], 0);
    CHECK_EQ(chunk[11], 0);
    for (int i = 0; i < 10; i++) {
        float v;
        memcpy(&v, chunk + ET_LINK_HDR_BYTES + i * 4, 4);
        CHECK_FEQ(v, ring[i]);
    }
}

ET_CASE(encoder_even_and_capped) {
    static float ring[16384];
    static uint8_t chunk[ET_LINK_CHUNK_BYTES];
    size_t bytes = 0;
    uint64_t r = 0;
    // 1 サンプルでは送らない（L だけ送ると以後 L と R が入れ替わる）。
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 16384, 1, &r), 0);
    CHECK_EQ(r, 0);
    r = 0;
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 16384, 4095, &r), 4094);
    CHECK_EQ(r, 4094);
    r = 0;
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 16384, 4097, &r), 4096);
    CHECK_EQ(bytes, ET_LINK_CHUNK_BYTES);
    // 9000 は 4096 + 4096 + 808 に切れて、残りは無い。
    r = 0;
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 16384, 9000, &r), 4096);
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 16384, 9000, &r), 4096);
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 16384, 9000, &r), 808);
    CHECK_EQ(r, 9000);
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 16384, 9000, &r), 0);
    CHECK_EQ(r, 9000);
}

ET_CASE(encoder_nothing_when_caught_up) {
    float ring[8] = {0};
    uint8_t chunk[64];
    memset(chunk, 0xEE, sizeof(chunk));
    size_t bytes = 123;
    uint64_t r = 40;
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 8, 40, &r), 0);
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 8, 30, &r), 0);
    CHECK_EQ(r, 40);
    CHECK_EQ(bytes, 123);
    CHECK_EQ(chunk[0], 0xEE);
}

ET_CASE(encoder_wraps_ring) {
    float ring[16];
    for (int i = 0; i < 16; i++) ring[i] = (float)(100 + i);
    uint8_t chunk[ET_LINK_CHUNK_BYTES];
    size_t bytes = 0;
    uint64_t r = 10;
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 16, 20, &r), 10);
    const float want[10] = {110, 111, 112, 113, 114, 115, 100, 101, 102, 103};
    for (int i = 0; i < 10; i++) {
        float v;
        memcpy(&v, chunk + ET_LINK_HDR_BYTES + i * 4, 4);
        CHECK_FEQ(v, want[i]);
    }
    CHECK_EQ(r, 20);
}

ET_CASE(encoder_overrun_drops_oldest) {
    // 書き手が 1 周より先へ行ったら、読めないぶんを捨てて最後の 1 周から送る。
    float ring[16];
    for (int i = 0; i < 16; i++) ring[i] = (float)i;
    uint8_t chunk[ET_LINK_CHUNK_BYTES];
    size_t bytes = 0;
    uint64_t r = 0;
    CHECK_EQ(ETLinkEncodeNext(chunk, &bytes, ring, 16, 100, &r), 16);
    CHECK_EQ(r, 100);
    float first;
    memcpy(&first, chunk + ET_LINK_HDR_BYTES, 4);
    CHECK_FEQ(first, ring[84 % 16]);
}

ET_CASE(push_stereo_mono_multichannel) {
    float ring[8];
    memset(ring, 0, sizeof(ring));
    const float stereo[6] = {1, 2, 3, 4, 5, 6};
    CHECK_EQ(ETLinkRingPush(ring, 8, 0, stereo, 3, 2), 6);
    for (int i = 0; i < 6; i++) CHECK_FEQ(ring[i], stereo[i]);

    // 1ch は左右に同じ値。リングの端で折り返す。
    const float mono[2] = {7, 8};
    CHECK_EQ(ETLinkRingPush(ring, 8, 6, mono, 2, 1), 10);
    CHECK_FEQ(ring[6], 7);
    CHECK_FEQ(ring[7], 7);
    CHECK_FEQ(ring[0], 8);
    CHECK_FEQ(ring[1], 8);

    // 3ch 以上は先頭の 2 本だけ。
    const float quad[8] = {10, 11, 12, 13, 20, 21, 22, 23};
    CHECK_EQ(ETLinkRingPush(ring, 8, 2, quad, 2, 4), 6);
    CHECK_FEQ(ring[2], 10);
    CHECK_FEQ(ring[3], 11);
    CHECK_FEQ(ring[4], 20);
    CHECK_FEQ(ring[5], 21);
}

ET_CASE(push_ignores_empty) {
    float ring[4] = {9, 9, 9, 9};
    const float s[2] = {1, 2};
    CHECK_EQ(ETLinkRingPush(ring, 4, 12, s, 0, 2), 12);
    CHECK_EQ(ETLinkRingPush(ring, 4, 12, NULL, 1, 2), 12);
    for (int i = 0; i < 4; i++) CHECK_FEQ(ring[i], 9);
}

// ---- 受け手 ----

ET_CASE(header_split_every_offset) {
    // ヘッダ 12 バイトのどこで切れても、揃うまで持ち越して 1 チャンクになる。
    uint8_t chunk[256];
    size_t total = put_chunk(chunk, 8, 1.0f);
    for (size_t k = 1; k < ET_LINK_HDR_BYTES; k++) {
        sink_reset();
        memcpy(gRx, chunk, k);
        size_t len = k;
        CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), 0);
        CHECK_EQ(len, k);
        CHECK_EQ(gSink.chunks, 0);
        memcpy(gRx + len, chunk + k, total - k);
        len = total;
        CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), 0);
        CHECK_EQ(len, 0);
        CHECK_EQ(gSink.chunks, 1);
        CHECK_EQ(gSink.count, 8);
        for (int i = 0; i < 8; i++) CHECK_FEQ(gSink.values[i], 1.0f + (float)i);
    }
}

ET_CASE(payload_split_off_boundary) {
    // 本体が float の途中で切れても、揃うまで何も出さない。
    uint8_t chunk[256];
    size_t total = put_chunk(chunk, 8, -3.25f);
    for (size_t k = ET_LINK_HDR_BYTES; k < total; k++) {
        sink_reset();
        memcpy(gRx, chunk, k);
        size_t len = k;
        CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), 0);
        CHECK_EQ(len, k);
        CHECK_EQ(gSink.chunks, 0);
        memcpy(gRx + len, chunk + k, total - k);
        len = total;
        ETLinkConsume(gRx, &len, sink_chunk, &gSink);
        CHECK_EQ(len, 0);
        CHECK_EQ(gSink.chunks, 1);
        for (int i = 0; i < 8; i++) CHECK_FEQ(gSink.values[i], -3.25f + (float)i);
    }
}

ET_CASE(garbage_prefix_resync) {
    uint8_t chunk[256];
    size_t total = put_chunk(chunk, 6, 42.0f);
    for (size_t n = 1; n <= 40; n++) {
        sink_reset();
        fill_garbage(gRx, n, (unsigned)(1000 + n));
        CHECK(!contains_magic(gRx, n));
        memcpy(gRx + n, chunk, total);
        size_t len = n + total;
        CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), n);
        CHECK_EQ(len, 0);
        CHECK_EQ(gSink.chunks, 1);
        CHECK_EQ(gSink.count, 6);
        CHECK_FEQ(gSink.values[0], 42.0f);
        CHECK_FEQ(gSink.values[5], 47.0f);
    }
}

ET_CASE(rejects_bad_counts) {
    // 正しいマジックでも、数が 0・奇数・上限越えならずれている証拠として読み飛ばす。
    // 壊れたヘッダ 12 バイトを 1 バイトずつ飛ばして、直後の正しいチャンクに乗る。
    const uint32_t bad[] = {0, 1, 3, 4095, 4098, 0xFFFFFFFEu};
    for (size_t b = 0; b < sizeof(bad) / sizeof(bad[0]); b++) {
        sink_reset();
        size_t n = put_header(gRx, ET_LINK_MAGIC, bad[b]);
        n += put_chunk(gRx + n, 4, 5.0f);
        size_t len = n;
        CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), ET_LINK_HDR_BYTES);
        CHECK_EQ(len, 0);
        CHECK_EQ(gSink.chunks, 1);
        CHECK_EQ(gSink.lastCount, 4);
    }
    // 上限ちょうど（4096 = 2048 フレーム）は通る。
    sink_reset();
    size_t n = put_chunk(gRx, ET_LINK_MAX_SAMPLES, 0.0f);
    CHECK_EQ(n, ET_LINK_CHUNK_BYTES);
    size_t len = n;
    CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), 0);
    CHECK_EQ(gSink.chunks, 1);
    CHECK_EQ(gSink.lastCount, ET_LINK_MAX_SAMPLES);
    // マジックが 1 ビット違えば通らない。
    sink_reset();
    n = put_header(gRx, ET_LINK_MAGIC ^ 1ull, 4);
    n += put_chunk(gRx + n, 2, 1.0f);
    len = n;
    ETLinkConsume(gRx, &len, sink_chunk, &gSink);
    CHECK_EQ(gSink.chunks, 1);
    CHECK_EQ(gSink.lastCount, 2);
}

ET_CASE(nan_inf_zeroed_and_counted) {
    const float in[8] = {NAN, INFINITY, -INFINITY, 1e-40f, -0.0f, 1e38f, -1.0f, 0.25f};
    uint8_t bytes[1 + sizeof(in)];
    // わざと 1 バイトずらして置く（受信バイトの途中から読むのと同じ）。
    memcpy(bytes + 1, in, sizeof(in));
    float ring[8];
    memset(ring, 0x7F, sizeof(ring));
    CHECK_EQ(ETLinkRingWrite(ring, 8, 0, bytes + 1, 8), 3);
    CHECK_FEQ(ring[0], 0.0f);
    CHECK_FEQ(ring[1], 0.0f);
    CHECK_FEQ(ring[2], 0.0f);
    CHECK_FEQ(ring[3], 1e-40f);          // 非正規化は有限なので通す
    CHECK(ring[4] == 0.0f && signbit(ring[4]));
    CHECK_FEQ(ring[5], 1e38f);
    CHECK_FEQ(ring[6], -1.0f);
    CHECK_FEQ(ring[7], 0.25f);
    // 折り返して書く。
    float small[4] = {0};
    CHECK_EQ(ETLinkRingWrite(small, 4, 6, bytes + 1 + 6 * sizeof(float), 2), 0);
    CHECK_FEQ(small[2], -1.0f);
    CHECK_FEQ(small[3], 0.25f);
}

ET_CASE(garbage_64k_then_recovers) {
    // 受信の溜めいっぱいの乱れたバイト。ヘッダ未満の 11 バイトだけ残して捨てる。
    sink_reset();
    fill_garbage(gRx, ET_LINK_RX_BUF_BYTES, 777u);
    CHECK(!contains_magic(gRx, ET_LINK_RX_BUF_BYTES));
    size_t len = ET_LINK_RX_BUF_BYTES;
    CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), ET_LINK_RX_BUF_BYTES - (ET_LINK_HDR_BYTES - 1));
    CHECK_EQ(len, ET_LINK_HDR_BYTES - 1);
    CHECK_EQ(gSink.chunks, 0);
    // 残った 11 バイトの後ろに正しいチャンクが来れば、そこから立ち直る。
    len += put_chunk(gRx + len, 10, 3.0f);
    CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), ET_LINK_HDR_BYTES - 1);
    CHECK_EQ(len, 0);
    CHECK_EQ(gSink.chunks, 1);
    CHECK_EQ(gSink.count, 10);
    CHECK_FEQ(gSink.values[9], 12.0f);
}

ET_CASE(several_chunks_one_recv) {
    sink_reset();
    uint8_t fourth[256];
    size_t fourthLen = put_chunk(fourth, 12, 400.0f);
    size_t n = 0;
    n += put_chunk(gRx + n, 2, 100.0f);
    n += put_chunk(gRx + n, 4, 200.0f);
    n += put_chunk(gRx + n, 6, 300.0f);
    size_t half = fourthLen / 2 + 1;   // 本体の途中、float の途中で切る
    memcpy(gRx + n, fourth, half);
    size_t len = n + half;
    CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), 0);
    CHECK_EQ(gSink.chunks, 3);
    CHECK_EQ(gSink.count, 12);
    CHECK_FEQ(gSink.values[0], 100.0f);
    CHECK_FEQ(gSink.values[2], 200.0f);
    CHECK_FEQ(gSink.values[6], 300.0f);
    CHECK_FEQ(gSink.values[11], 305.0f);
    // 4 つ目の頭は先頭へ寄せてある。
    CHECK_EQ(len, half);
    CHECK(memcmp(gRx, fourth, half) == 0);
    memcpy(gRx + len, fourth + half, fourthLen - half);
    len = fourthLen;
    ETLinkConsume(gRx, &len, sink_chunk, &gSink);
    CHECK_EQ(gSink.chunks, 4);
    CHECK_EQ(len, 0);
    CHECK_FEQ(gSink.values[12], 400.0f);
    CHECK_FEQ(gSink.values[23], 411.0f);
}

ET_CASE(consume_short_buffer_untouched) {
    sink_reset();
    memset(gRx, 0xAB, 16);
    size_t len = ET_LINK_HDR_BYTES - 1;
    CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), 0);
    CHECK_EQ(len, ET_LINK_HDR_BYTES - 1);
    len = 0;
    CHECK_EQ(ETLinkConsume(gRx, &len, sink_chunk, &gSink), 0);
    CHECK_EQ(len, 0);
    CHECK_EQ(gSink.chunks, 0);
}

ET_CASE(stream_roundtrip_random_splits) {
    // 送り手のリング → チャンク → ばらばらの長さの recv → 受け手のリング、を通して
    // 1 サンプルも欠けず、ずれもしないこと。LocalLink.m の pump と同じく、
    // recv は溜めの空きまでしか入れず、入れるたびに consume する。
    enum { FRAMES = 60000 };
    static float src[FRAMES * 2];
    for (int i = 0; i < FRAMES * 2; i++) src[i] = sinf((float)i * 0.001f) * 0.9f + (float)(i & 7) * 1e-3f;

    float *sendRing = calloc(ET_LINK_SEND_RING_SAMPLES, sizeof(float));
    float *recvRing = calloc(ET_LINK_RECV_RING_SAMPLES, sizeof(float));
    uint8_t *wire = malloc((size_t)FRAMES * 2 * sizeof(float) * 2);
    uint8_t *chunk = malloc(ET_LINK_CHUNK_BYTES);
    CHECK(sendRing && recvRing && wire && chunk);

    // 送り手: 音のコールバックが 256 フレームずつ積み、ポンプが 700 フレームごとに吐く。
    uint64_t w = 0, r = 0;
    size_t wireLen = 0;
    int pushed = 0;
    while (pushed < FRAMES) {
        int step = FRAMES - pushed < 256 ? FRAMES - pushed : 256;
        w = ETLinkRingPush(sendRing, ET_LINK_SEND_RING_SAMPLES, w, src + pushed * 2, (uint32_t)step, 2);
        pushed += step;
        if (pushed % 700 < 256 || pushed == FRAMES) {
            size_t bytes = 0;
            while (ETLinkEncodeNext(chunk, &bytes, sendRing, ET_LINK_SEND_RING_SAMPLES, w, &r) != 0) {
                memcpy(wire + wireLen, chunk, bytes);
                wireLen += bytes;
            }
        }
    }
    CHECK_EQ(r, (uint64_t)FRAMES * 2);

    // 受け手: 1〜5000 バイトの recv に切る。
    typedef struct { float *ring; uint64_t w; uint32_t bad; } Rx;
    Rx rx = {recvRing, 0, 0};
    size_t len = 0, off = 0, skipped = 0;
    et_lcg_state = 99u;
    while (off < wireLen) {
        size_t want = 1 + (size_t)(et_lcg() % 5000);
        size_t room = ET_LINK_RX_BUF_BYTES - len;
        if (want > room) want = room;
        if (want > wireLen - off) want = wireLen - off;
        memcpy(gRx + len, wire + off, want);
        len += want;
        off += want;
        sink_reset();
        skipped += ETLinkConsume(gRx, &len, sink_chunk, &gSink);
        rx.bad += ETLinkRingWrite(rx.ring, ET_LINK_RECV_RING_SAMPLES, rx.w,
                                  (const uint8_t *)gSink.values, (uint32_t)gSink.count);
        rx.w += gSink.count;
    }
    CHECK_EQ(skipped, 0);
    CHECK_EQ(rx.bad, 0);
    CHECK_EQ(len, 0);
    CHECK_EQ(rx.w, (uint64_t)FRAMES * 2);
    // リングは 2 秒 = 96000 フレームぶんあるので、60000 フレームは全部残っている。
    int mismatches = 0;
    for (int i = 0; i < FRAMES * 2; i++) if (recvRing[i] != src[i]) mismatches++;
    CHECK_EQ(mismatches, 0);

    free(sendRing);
    free(recvRing);
    free(wire);
    free(chunk);
}

int main(int argc, char **argv) {
    static const et_case cases[] = {
        ET_ENTRY(encoder_header_layout),
        ET_ENTRY(encoder_even_and_capped),
        ET_ENTRY(encoder_nothing_when_caught_up),
        ET_ENTRY(encoder_wraps_ring),
        ET_ENTRY(encoder_overrun_drops_oldest),
        ET_ENTRY(push_stereo_mono_multichannel),
        ET_ENTRY(push_ignores_empty),
        ET_ENTRY(header_split_every_offset),
        ET_ENTRY(payload_split_off_boundary),
        ET_ENTRY(garbage_prefix_resync),
        ET_ENTRY(rejects_bad_counts),
        ET_ENTRY(nan_inf_zeroed_and_counted),
        ET_ENTRY(garbage_64k_then_recovers),
        ET_ENTRY(several_chunks_one_recv),
        ET_ENTRY(consume_short_buffer_untouched),
        ET_ENTRY(stream_roundtrip_random_splits),
    };
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
