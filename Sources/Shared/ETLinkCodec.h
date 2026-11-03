//  ETLinkCodec.h
//  LocalLink（拡張 → 本体の PCM の線）の中身のうち、ソケットにも dispatch にも
//  os_log にも触らない部分。LocalLink.m がこれを呼ぶ。
//
//  **挙動は LocalLink.m に直に書いてあったときと同じ。**移したのは計算だけで、
//  スレッド・タイマー・ソケット・ログは LocalLink.m に残した。
//  ここだけを Linux で建てて確かめる（Tests/Native/link）。
//
//  **LocalLink.h からは読み込まない。**LocalLink.h は Swift の橋に入っていて、
//  _Atomic のフィールドを持つ構造体は Swift に読ませられない。

#ifndef ETLinkCodec_h
#define ETLinkCodec_h

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// ---- 線の形式 ----
//
// TCP はバイトの列で、4 バイト境界では切れてくれない。recv が返す n が 4 の倍数だと
// 決めつけて n/4 サンプルだけ取ると、余りの 1〜3 バイトが捨てられる。そこから先は
// 隣り合う 2 サンプルにまたがる 4 バイトを float として読むことになり、指数部が
// 任意の値になるので NaN・1e38・非正規化まで飛ぶ。1 回ずれたら復帰しない。
//
// そこで
//   1. 送受とも端数をバイト単位で持ち越す（捨てない・送り直さない）
//   2. チャンクごとにマジックとサンプル数を付け、受け側で毎回検算する
// の両方を持たせた。1 だけだと、ずれたときに誰も気付けない。
//
// 同一機内の 127.0.0.1 しか通らないのでバイト順の変換はしない。
// 値は 'ETLK1001'。リトルエンディアンで書くので hexdump には "1001KLTE" と並ぶ。
#define ET_LINK_MAGIC       0x45544c4b31303031ull
#define ET_LINK_HDR_BYTES   12                      // マジック 8 + サンプル数 4
#define ET_LINK_MAX_SAMPLES 4096                    // 1 チャンクの上限（2048 フレーム）
#define ET_LINK_CHUNK_BYTES (ET_LINK_HDR_BYTES + ET_LINK_MAX_SAMPLES * sizeof(float))

/// 送り手のリング。2 秒ぶん（48 kHz・2ch）。
#define ET_LINK_SEND_RING_SAMPLES (48000 * 2 * 2)
/// 受け手のリング。同じく 2 秒。
#define ET_LINK_RECV_RING_SAMPLES (48000 * 2 * 2)
/// 受け手の受信バイトの溜め。1 チャンク（最大 16396 バイト）より十分大きく取る。
#define ET_LINK_RX_BUF_BYTES      65536

// ---- 受け手の溜まりの方針 ----

/// 貼り直すときに書き位置から下げる量。**経路の遅れの大半がここ。**
/// 1024 は 48 kHz で 21.3 ms。実機で刻んで測った結果、384 は取りこぼし、
/// 512 で枯れ、576 でもたまに枯れる。谷の深さは一定ではないので、
/// 一度 never になった値が安全とは限らない。たまに出る値の倍を取った。
#define ET_LINK_TARGET_FRAMES 1024u
/// 枯れたときに逃げる先。**設定には出さない。**選ばせるものではなく、
/// 1024 で保たない機械や場面のための逃げ道。繋ぎ直すと戻る。
#define ET_LINK_TARGET_FALLBACK 2048u
/// 溜め直しを諦めるまでの回数。**無限に待たない。**条件を満たせない
/// 状態に落ちたときに、永久に無音を出し続ける口を残さないため。
#define ET_LINK_REFILL_GIVE_UP 200u
/// 深い側へ移るまでに要る枯れの回数と、「続いた」と見なす間隔。
/// **散発的な 1 回では移らない。**9 秒に 1 度の 5 ms の欠けは聴こえず、
/// そこで遅れを倍にするのは損。短い間に繰り返すなら 1024 では保たない。
/// 間隔は時計ではなく受信フレーム数で測る（5 秒 = 240000 フレーム）。
#define ET_LINK_STARVE_TO_FALL_BACK 3u
#define ET_LINK_STARVE_NEAR_FRAMES (48000u * 5u)
/// 繋がってからこれだけ受け取るまでは枯れとして数えない。
/// **立ち上がりは必ず通る。**溜まりは 0 から始まるので、最初の数回は
/// 読みに行くほうが早い（実機のログで 107 ms と 533 ms の 2 回）。
#define ET_LINK_SETTLE_FRAMES 48000u

// ---- 送り手 ----

/// 送り手のリングへ積む。samples はインターリーブで frames×channels。
/// 先頭の 2 本だけ取り、1ch なら同じ値を左右に置く。新しい書き位置（サンプル）を返す。
/// リアルタイムスレッドから呼ぶ。確保も待ちもしない。
uint64_t ETLinkRingPush(float *ring, uint64_t ringSamples, uint64_t w,
                        const float *samples, uint32_t frames, uint32_t channels);

/// 送り手のリングの *r から次の 1 チャンクを dst に組み、*r を進める。
/// 返すのはチャンクのサンプル数。送るものが無ければ 0 で、dst も *r も触らない。
/// w は書き位置の写し。1 回の送り出しのあいだは同じ値を渡し続けること。
/// 書き手がリング 1 周より先へ行っていたら、古いぶんを捨てて *r を詰める。
/// dst は ET_LINK_CHUNK_BYTES 以上（境界は問わない）。*outBytes にヘッダ込みのバイト数を書く。
uint32_t ETLinkEncodeNext(uint8_t *dst, size_t *outBytes,
                          const float *ring, uint64_t ringSamples,
                          uint64_t w, uint64_t *r);

// ---- 受け手 ----

/// チャンク本体（count 個の float。4 バイト境界に乗っている保証は無い）を
/// リングの w から写す。非有限値は 0 に置き換え、置き換えた数を返す。
/// 書き位置の公開（release）は呼んだ側でやる。
uint32_t ETLinkRingWrite(float *ring, uint64_t ringSamples, uint64_t w,
                         const uint8_t *payload, uint32_t count);

/// 取り出したチャンクを渡す先。payload は count 個の float のバイト列。
typedef void (*ETLinkChunkFn)(void *ctx, const uint8_t *payload, uint32_t count);

/// buf[0 ..< *len] から取り出せるチャンクを全部取り出して onChunk に渡し、
/// 残りを先頭へ寄せて *len を縮める。ヘッダが揃わない端数・本体が届いていない
/// チャンクはそのまま残す（次の recv と繋ぐ）。
/// 返すのは、ヘッダが合わずに 1 バイトずつ読み飛ばしたバイト数。
size_t ETLinkConsume(uint8_t *buf, size_t *len, ETLinkChunkFn onChunk, void *ctx);

/// 受け手の溜まりの方針が持つ状態。書くのは音のスレッドと繋ぎ直しだけで、
/// ほかのスレッドは数を読むだけ。繋ぎ直しで 0 に戻すので全部 atomic。
typedef struct ETLinkJitter {
    _Atomic uint32_t target;        ///< 狙いの溜まり（フレーム）
    _Atomic uint32_t starveCount;   ///< 尽きて無音を書いた回数
    _Atomic uint64_t starveFrames;  ///< そのフレーム数
    _Atomic uint32_t trimCount;     ///< 溜まりすぎて捨てた回数
    _Atomic uint64_t trimFrames;    ///< そのフレーム数
    _Atomic bool     refilling;     ///< 溜め直している最中か
    _Atomic uint32_t refillWaits;   ///< 溜め直しで待った回数
    _Atomic uint64_t lastStarveAt;  ///< 前に枯れたときの受信フレーム数
    _Atomic uint32_t starveRun;     ///< 近いうちに続いた枯れの回数
} ETLinkJitter;

#define ET_LINK_JITTER_INIT { ET_LINK_TARGET_FRAMES, 0, 0, 0, 0, false, 0, 0, 0 }

/// 繋ぎ直したときに、浅い側から始め直す。数えたものも 0 に戻す。
void ETLinkJitterReset(ETLinkJitter *j);

/// ETLinkJitterRead がこの回を枯れとして数えたときの、ログに出す値。
typedef struct ETLinkStarve {
    bool     counted;        ///< この回を枯れとして数えた
    uint32_t filledFrames;   ///< 無音で埋めたフレーム数
    uint32_t wantFrames;     ///< 頼まれたフレーム数
    uint64_t bufferedFrames; ///< 読む前の溜まり
    uint32_t target;         ///< 数える前の狙い
    uint32_t runBefore;      ///< 数える前の「連」
} ETLinkStarve;

/// 受け手のリングから frames フレーム（インターリーブ 2ch）を out へ読む。
/// 足りない分は無音で埋める。返すのは実際に読めたフレーム数。
/// w は書き位置（acquire で読んだもの）、*r は読み位置で、読んだぶん進める。
/// hasPeer と receivedFrames は「鳴る前の空回り」を枯れと数えないために使う。
/// receivedFrames は**今の相手から**受け取ったフレーム数（起動からの累計ではない）。
/// starve は NULL でよい。
uint32_t ETLinkJitterRead(ETLinkJitter *j, const float *ring, uint64_t ringSamples,
                          uint64_t w, uint64_t *r, float *out, uint32_t frames,
                          bool hasPeer, uint64_t receivedFrames, ETLinkStarve *starve);

#endif /* ETLinkCodec_h */
