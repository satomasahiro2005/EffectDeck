//  ETLinkCodec.c
//  LocalLink の線の形式と、受け手の溜まりの方針。説明は ETLinkCodec.h。
//  ここは確保もロックもログもしない。受け手の読みは音のスレッドから来る。

#include "ETLinkCodec.h"
#include <math.h>
#include <string.h>

// ---- 送り手 ----

uint64_t ETLinkRingPush(float *ring, uint64_t ringSamples, uint64_t w,
                        const float *samples, uint32_t frames, uint32_t channels) {
    if (!ring || ringSamples == 0 || !samples || frames == 0) return w;
    uint64_t at = w % ringSamples;
    for (uint32_t i = 0; i < frames; i++) {
        float l = samples[(size_t)i * channels];
        float r = (channels > 1) ? samples[(size_t)i * channels + 1] : l;
        ring[at] = l; if (++at == ringSamples) at = 0;
        ring[at] = r; if (++at == ringSamples) at = 0;
    }
    return w + (uint64_t)frames * 2u;
}

uint32_t ETLinkEncodeNext(uint8_t *dst, size_t *outBytes,
                          const float *ring, uint64_t ringSamples,
                          uint64_t w, uint64_t *r) {
    if (!dst || !ring || !r || ringSamples == 0) return 0;
    uint64_t rr = *r;
    if (w <= rr) return 0;
    uint64_t avail = w - rr;
    // 書き手がリング 1 周より先へ行った。読めない古いぶんは捨てて、残っている所から送る。
    if (avail > ringSamples) { rr = w - ringSamples; avail = ringSamples; }

    uint32_t n = (uint32_t)(avail < (uint64_t)ET_LINK_MAX_SAMPLES ? avail
                                                                  : (uint64_t)ET_LINK_MAX_SAMPLES);
    n &= ~1u;   // 必ず偶数サンプルで切る。奇数だと以後 L と R が入れ替わる
    if (n == 0) return 0;

    uint64_t magic = ET_LINK_MAGIC;
    uint32_t count = n;
    memcpy(dst, &magic, sizeof(magic));
    memcpy(dst + 8, &count, sizeof(count));
    // dst の境界は決めつけない（呼ぶ側が 4 バイト境界の器を渡すとは限らない）。
    // 1 サンプルずつ memcpy で置く。書かれるバイトは float の代入と同じ。
    uint8_t *payload = dst + ET_LINK_HDR_BYTES;
    uint64_t at = rr % ringSamples;
    for (uint32_t i = 0; i < n; i++) {
        memcpy(payload + (size_t)i * sizeof(float), &ring[at], sizeof(float));
        if (++at == ringSamples) at = 0;
    }
    if (outBytes) *outBytes = ET_LINK_HDR_BYTES + (size_t)n * sizeof(float);
    // リングから dst へ写した時点で読み位置を進める。送信が途中で止まっても
    // 残りは dst が持っているので、リングを読み直す必要は無い。
    *r = rr + n;
    return n;
}

// ---- 受け手 ----

uint32_t ETLinkRingWrite(float *ring, uint64_t ringSamples, uint64_t w,
                         const uint8_t *payload, uint32_t count) {
    if (!ring || ringSamples == 0 || !payload) return 0;
    uint32_t bad = 0;
    uint64_t at = w % ringSamples;
    for (uint32_t i = 0; i < count; i++) {
        float v;
        // 受信バイトの途中から読むので 4 バイト境界に乗っている保証が無い。memcpy で取る。
        memcpy(&v, payload + (size_t)i * sizeof(float), sizeof(v));
        // NaN や inf を 1 つ通すと IIR の状態が戻らなくなり、以後ずっと無音か轟音になる。
        // ここで落として数を返す（黙って埋めると原因が見えない）。
        if (!isfinite(v)) { v = 0.0f; bad++; }
        ring[at] = v;
        if (++at == ringSamples) at = 0;
    }
    return bad;
}

size_t ETLinkConsume(uint8_t *buf, size_t *len, ETLinkChunkFn onChunk, void *ctx) {
    if (!buf || !len) return 0;
    size_t have = *len;
    size_t off = 0;
    size_t skipped = 0;
    while (have - off >= ET_LINK_HDR_BYTES) {
        uint64_t magic = 0;
        uint32_t count = 0;
        memcpy(&magic, buf + off, sizeof(magic));
        memcpy(&count, buf + off + 8, sizeof(count));
        // 送り側が必ず偶数サンプルで切るので、奇数はずれている証拠として弾く。
        if (magic != ET_LINK_MAGIC || count == 0 || (count & 1u) || count > ET_LINK_MAX_SAMPLES) {
            off += 1;       // 1 バイトずつずらして次のマジックを探す
            skipped++;
            continue;
        }
        size_t need = ET_LINK_HDR_BYTES + (size_t)count * sizeof(float);
        if (have - off < need) break;       // 本体がまだ揃っていない
        if (onChunk) onChunk(ctx, buf + off + ET_LINK_HDR_BYTES, count);
        off += need;
    }
    if (off > 0) {
        memmove(buf, buf + off, have - off);
        *len = have - off;
    }
    return skipped;
}

void ETLinkJitterReset(ETLinkJitter *j) {
    if (!j) return;
    atomic_store_explicit(&j->target, ET_LINK_TARGET_FRAMES, memory_order_relaxed);
    atomic_store_explicit(&j->starveCount, 0, memory_order_relaxed);
    atomic_store_explicit(&j->starveFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&j->trimCount, 0, memory_order_relaxed);
    atomic_store_explicit(&j->trimFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&j->refilling, false, memory_order_relaxed);
    atomic_store_explicit(&j->refillWaits, 0, memory_order_relaxed);
    atomic_store_explicit(&j->lastStarveAt, 0, memory_order_relaxed);
    atomic_store_explicit(&j->starveRun, 0, memory_order_relaxed);
}

uint32_t ETLinkJitterRead(ETLinkJitter *j, const float *ring, uint64_t ringSamples,
                          uint64_t w, uint64_t *ioR, float *out, uint32_t frames,
                          bool hasPeer, uint64_t receivedFrames, ETLinkStarve *starve) {
    if (starve) memset(starve, 0, sizeof(*starve));
    if (!j || !ring || ringSamples == 0 || !ioR || !out) return 0;
    uint64_t r = *ioR;
    uint32_t want = frames * 2;
    uint64_t behind = (uint64_t)atomic_load_explicit(&j->target,
                                                     memory_order_relaxed) * 2ull;

    // **貼り直しを先に済ませる。**溜め直しの判定より前に置くこと。
    // 逆にすると、読み位置が 0 のまま（初回や繋ぎ直しの直後）は
    // 貼り直しに届かず、条件を満たせないまま無音を出し続ける。
    //
    // 溜まりすぎたら捨てるのもここ。送り手と読み手のクロックはぴたりとは
    // 合わず、読んだぶんだけ進めるだけでは溜まりが漂う。上限が無かった
    // ときは、狙い 128 に対して実測 3000 まで伸びていた。
    if (r == 0 || w > r + ringSamples || (w > r && w - r > behind * 2)) {
        uint64_t was = r;
        r = (w > behind) ? (w - behind) : 0;
        if (was != 0 && r > was) {
            atomic_fetch_add_explicit(&j->trimCount, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&j->trimFrames, (r - was) / 2, memory_order_relaxed);
        }
    }

    // **溜め直しの途中は読まない。**枯れた直後は読み位置が書き位置に
    // 追いついていて、そのまま読み続けると届くそばから読み切る。
    // 細かく途切れ続けるより、1 度まとめて待って立て直す。
    // **待ち続けない。**溜まらないまま ET_LINK_REFILL_GIVE_UP 回まで来たら諦めて読む。
    if (atomic_load_explicit(&j->refilling, memory_order_acquire)) {
        uint32_t waits = atomic_fetch_add_explicit(&j->refillWaits, 1, memory_order_relaxed);
        if ((w > r && w - r >= behind) || waits >= ET_LINK_REFILL_GIVE_UP) {
            atomic_store_explicit(&j->refilling, false, memory_order_release);
            atomic_store_explicit(&j->refillWaits, 0, memory_order_relaxed);
        } else {
            for (uint32_t i = 0; i < want; i++) out[i] = 0.0f;
            *ioR = r;
            return 0;
        }
    }

    uint64_t avail = (w > r) ? (w - r) : 0;
    uint32_t got = (uint32_t)(avail < (uint64_t)want ? avail : (uint64_t)want);
    uint64_t at = r % ringSamples;
    for (uint32_t i = 0; i < got; i++) {
        out[i] = ring[at];
        if (++at == ringSamples) at = 0;
    }
    for (uint32_t i = got; i < want; i++) out[i] = 0.0f;
    // **埋めたことを残す。**ここは無音を書いて黙って進むので、
    // 記録しないと詰めすぎたのか足りているのか分からない。
    //
    // **鳴る前の空回りは枯れではない。**相手が繋がる前も音のコールバックは
    // 回っていて、当然データが無いので毎枠ここへ来る。数えると Ran dry が
    // 本物と見分けられなくなり、狙いまで 2048 へ逃げて遅れが無駄に増える
    // （実機のログで、枯れ 4 件が全部「受信=0」だった）。
    bool live = hasPeer && (receivedFrames > ET_LINK_SETTLE_FRAMES);
    if (got < want && live) {
        atomic_fetch_add_explicit(&j->starveCount, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&j->starveFrames,
                                  (uint64_t)(want - got) / 2, memory_order_relaxed);
        uint32_t runBefore = atomic_load_explicit(&j->starveRun, memory_order_relaxed);
        if (starve) {
            starve->counted = true;
            starve->filledFrames = (want - got) / 2;
            starve->wantFrames = want / 2;
            starve->bufferedFrames = (w > r) ? (w - r) / 2 : 0;
            starve->target = atomic_load_explicit(&j->target, memory_order_relaxed);
            starve->runBefore = runBefore;
        }
        // **続いたときだけ深い側へ移る。**離れて 1 回なら聴こえないので、
        // そこで遅れを倍にする意味がない。前の枯れからの間隔で見る。
        uint64_t last = atomic_load_explicit(&j->lastStarveAt, memory_order_relaxed);
        uint32_t run = (last != 0 && receivedFrames - last < ET_LINK_STARVE_NEAR_FRAMES)
                     ? runBefore + 1 : 1;
        atomic_store_explicit(&j->starveRun, run, memory_order_relaxed);
        atomic_store_explicit(&j->lastStarveAt, receivedFrames, memory_order_relaxed);
        if (run >= ET_LINK_STARVE_TO_FALL_BACK) {
            atomic_store_explicit(&j->target, ET_LINK_TARGET_FALLBACK, memory_order_relaxed);
        }
        atomic_store_explicit(&j->refillWaits, 0, memory_order_relaxed);
        atomic_store_explicit(&j->refilling, true, memory_order_release);
    }
    *ioR = r + got;
    return got / 2;
}
