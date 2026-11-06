//  ETVorbis.c
//  SF3 の標本（モノの Ogg Vorbis）を stb_vorbis で float にする。説明は ETVorbis.h。

#include "ETVorbis.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// stb_vorbis.c は上流のまま（手を入れない）。ここでは宣言だけ取り込み、本体は別の翻訳単位として建つ。
#define STB_VORBIS_HEADER_ONLY
#include "ThirdParty/stb_vorbis.c"

/// 1 回の復号の単位（フレーム）。
#define ET_VORBIS_CHUNK 65536u
/// ページ（ETSampleStream の 4096 フレーム）。目標はこの倍数に切り上げる。
#define ET_VORBIS_PAGE 4096u
/// 3 つのヘッダーパケット（識別・コメント・設定）の合計の上限。上流の MAX_HEADER_BYTES と同じ。
#define ET_VORBIS_MAX_HEADER_BYTES (256u * 1024u)
/// 符号表 1 つの大きさの上限。entries（符号の数）と entries × dimensions（引く表の値の数）。libvorbis が書く表は
/// entries が数千・dimensions が 8 以下。
#define ET_VORBIS_MAX_BOOK_ENTRIES (1u << 20)
#define ET_VORBIS_MAX_BOOK_VALUES (1u << 22)
/// 続きを読むときの先読み（フレーム）。最初の 1 回（頭のページだけ）は先読みしない。
#define ET_VORBIS_AHEAD (16u * ET_VORBIS_PAGE)

struct ETVorbisStream {
    uint8_t *ogg;
    size_t size;
    uint32_t sampleRate;
    uint64_t sourceFrames;

    stb_vorbis *decoder;
    /// 開いている復号器が、先頭から何フレーム読んだか。
    uint64_t decoderPosition;
    size_t decoderBytes;

    float *pcm;
    uint64_t decoded;
    uint64_t capacity;
};

// MARK: - Ogg の枠と CRC

// Ogg の CRC-32（多項式 0x04c11db7、初期値 0、反転なし）。4 ビットずつの表。
static const uint32_t kCrcNibble[16] = {
    0x00000000, 0x04c11db7, 0x09823b6e, 0x0d4326d9, 0x130476dc, 0x17c56b6b, 0x1a864db2, 0x1e475005,
    0x2608edb8, 0x22c9f00f, 0x2f8ad6d6, 0x2b4bcb61, 0x350c9b64, 0x31cd86d3, 0x3c8ea00a, 0x384fbdbd};

static uint32_t crcStep(uint32_t crc, uint8_t byte)
{
    crc = (crc << 4) ^ kCrcNibble[(crc >> 28) ^ (uint32_t)(byte >> 4)];
    crc = (crc << 4) ^ kCrcNibble[(crc >> 28) ^ (uint32_t)(byte & 15)];
    return crc;
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/// 全ページを頭から確かめる: OggS・版 0・フラグ・長さが収まる・CRC・serial が同じ・番号が 1 ずつ・
/// 先頭が BOS・最後が EOS（その後ろは見ない）・最後の granule が sourceFrames。上流の page() と同じ厳しさ。
static int validatePages(const uint8_t *b, size_t size, uint64_t sourceFrames)
{
    size_t at = 0;
    uint32_t serial = 0, sequence = 0;
    for (int first = 1;; first = 0) {
        if (at > size || size - at < 27) return ET_VORBIS_ERR_FORMAT;
        const uint8_t *h = b + at;
        if (h[0] != 'O' || h[1] != 'g' || h[2] != 'g' || h[3] != 'S' || h[4] != 0 || (h[5] & ~7) || h[26] == 0)
            return ET_VORBIS_ERR_FORMAT;
        size_t length = 27u + h[26];
        if (length > size - at) return ET_VORBIS_ERR_FORMAT;
        size_t body = 0;
        for (unsigned i = 0; i < h[26]; i++) body += h[27 + i];
        if (body > size - at - length) return ET_VORBIS_ERR_FORMAT;
        length += body;
        // BOS は先頭のページだけ。
        if (((h[5] & 2) != 0) != (first != 0)) return ET_VORBIS_ERR_FORMAT;
        if (first) serial = le32(h + 14);
        else if (le32(h + 14) != serial) return ET_VORBIS_ERR_FORMAT;
        if (le32(h + 18) != sequence) return ET_VORBIS_ERR_FORMAT;
        sequence++;
        uint32_t crc = 0;
        for (size_t i = 0; i < length; i++) crc = crcStep(crc, (i >= 22 && i < 26) ? 0 : h[i]);
        if (crc != le32(h + 22)) return ET_VORBIS_ERR_FORMAT;
        if (h[5] & 4) {
            // 最後のページ。granule（8 バイト）は frames と同じ（-1 は「このページでは終わらない」で、EOS にはあり得ない）。
            uint64_t granule = 0;
            for (int k = 7; k >= 0; k--) granule = granule << 8 | h[6 + k];
            return granule == sourceFrames ? ET_VORBIS_OK : ET_VORBIS_ERR_FORMAT;
        }
        at += length;
    }
}

// MARK: - ヘッダーパケット

static uint32_t packetU32(const uint8_t *p) { return le32(p); }

/// コメントのパケット（[3] "vorbis"、vendor 長 + vendor、件数、件ごとの長さ + 本文、framing 1 バイト）が、パケットの
/// 長さの中で閉じているか。stb_vorbis はこれらの長さを検査せずに確保・書き込みに使う（負の int は setup_malloc に渡って
/// 1 バイト書き戻す・巨大な値は確保と読み込みの長い繰り返しになる）ので、**stb_vorbis に渡す前にここで止める。**
static int commentPacketOk(const uint8_t *p, size_t length)
{
    if (length < 7 + 4 + 4 + 1 || p[0] != 3 || memcmp(p + 1, "vorbis", 6) != 0) return 0;
    size_t at = 7;
    uint32_t vendor = packetU32(p + at);
    at += 4;
    if (vendor > length - at) return 0;
    at += vendor;
    if (length - at < 4) return 0;
    uint32_t count = packetU32(p + at);
    at += 4;
    for (uint32_t i = 0; i < count; i++) {
        if (length - at < 4) return 0;
        uint32_t item = packetU32(p + at);
        at += 4;
        if (item > length - at) return 0;
        at += item;
    }
    return length - at >= 1;
}

/// 設定ヘッダー（[5] "vorbis"、符号表の列、…）の符号表を、stb_vorbis に渡す前に読み通す。
/// stb_vorbis は symbol 数 × 次元数の積を int に切り詰めて確保の大きさにするので、大きな積（entries 24 bit × dimensions
/// 16 bit）を書いた入力は確保より多く書く。巨大な表は確保も読み込みの繰り返しも長く、途中で断るときに一時領域を残す。
/// ここでは構造（同期語・符号長・探索表の長さ）を最後まで読み、表の大きさを上の上限に収める。
typedef struct {
    const uint8_t *p;
    size_t bits;
    size_t at;   // ビットの位置
    int bad;
} BitReader;

static uint32_t takeBits(BitReader *r, unsigned n)
{
    uint32_t v = 0;
    if (n == 0) return 0;
    if (r->bad || n > 32 || r->bits - r->at < n) { r->bad = 1; return 0; }
    for (unsigned i = 0; i < n; i++, r->at++) v |= (uint32_t)((r->p[r->at >> 3] >> (r->at & 7)) & 1) << i;
    return v;
}

static unsigned ilogOf(uint32_t x)
{
    unsigned n = 0;
    while (x) { n++; x >>= 1; }
    return n;
}

static uint64_t powSat(uint64_t base, uint32_t exponent)
{
    uint64_t r = 1;
    for (uint32_t i = 0; i < exponent; i++) {
        if (base != 0 && r > UINT64_MAX / base) return UINT64_MAX;
        r *= base;
    }
    return r;
}

/// v^dimensions <= entries を満たす最大の v（仕様の lookup1_values）。
static uint32_t lookup1Values(uint32_t entries, uint32_t dimensions)
{
    uint32_t v = (uint32_t)floor(exp(log((double)entries) / (double)dimensions));
    if (v < 1) v = 1;
    while (powSat((uint64_t)v + 1, dimensions) <= entries) v++;
    while (v > 1 && powSat(v, dimensions) > entries) v--;
    return v;
}

static int setupPacketOk(const uint8_t *p, size_t length)
{
    if (length < 7 + 1 || p[0] != 5 || memcmp(p + 1, "vorbis", 6) != 0) return 0;
    BitReader r = {p + 7, (length - 7) * 8, 0, 0};
    uint32_t books = takeBits(&r, 8) + 1;
    for (uint32_t b = 0; b < books && !r.bad; b++) {
        if (takeBits(&r, 24) != 0x564342) return 0;
        uint32_t dimensions = takeBits(&r, 16), entries = takeBits(&r, 24);
        int ordered = (int)takeBits(&r, 1), sparse = ordered ? 0 : (int)takeBits(&r, 1);
        if (r.bad || dimensions == 0 || entries == 0 || entries > ET_VORBIS_MAX_BOOK_ENTRIES ||
            (uint64_t)entries * dimensions > ET_VORBIS_MAX_BOOK_VALUES)
            return 0;
        if (ordered) {
            uint32_t current = 0, len = takeBits(&r, 5) + 1;
            while (current < entries && !r.bad) {
                uint32_t n = takeBits(&r, ilogOf(entries - current));
                if (len >= 32 || n > entries - current) return 0;
                current += n;
                len++;
            }
        } else {
            for (uint32_t j = 0; j < entries && !r.bad; j++) {
                if (!sparse || takeBits(&r, 1)) {
                    if (takeBits(&r, 5) + 1 == 32) return 0;
                }
            }
        }
        uint32_t lookup = takeBits(&r, 4);
        if (r.bad || lookup > 2) return 0;
        if (lookup > 0) {
            takeBits(&r, 32);
            takeBits(&r, 32);
            unsigned valueBits = takeBits(&r, 4) + 1;
            takeBits(&r, 1);
            uint64_t values = lookup == 1 ? lookup1Values(entries, dimensions) : (uint64_t)entries * dimensions;
            if (r.bad || values == 0 || values > ET_VORBIS_MAX_BOOK_VALUES) return 0;
            if (values * valueBits > r.bits - r.at) return 0;
            r.at += (size_t)(values * valueBits);
        }
    }
    return !r.bad;
}

/// 先頭の 3 パケットを集めて確かめる。識別は 30 バイト・モノ・SHDR のレート、コメントと設定は上の検査。
/// ページの枠は validatePages が確かめた後に呼ぶ（長さがはみ出さない）。
static int validateHeaders(const uint8_t *b, size_t size, uint32_t sampleRate)
{
    uint8_t *packets = (uint8_t *)malloc(ET_VORBIS_MAX_HEADER_BYTES);
    if (!packets) return ET_VORBIS_ERR_MEMORY;
    size_t ends[3] = {0, 0, 0}, used = 0;
    int found = 0, status = ET_VORBIS_OK;
    for (size_t at = 0; found < 3 && status == ET_VORBIS_OK;) {
        if (size - at < 27) { status = ET_VORBIS_ERR_FORMAT; break; }
        const uint8_t *h = b + at;
        const uint8_t *body = h + 27 + h[26];
        for (unsigned i = 0; i < h[26] && found < 3; i++) {
            unsigned lace = h[27 + i];
            if (used + lace > ET_VORBIS_MAX_HEADER_BYTES) { status = ET_VORBIS_ERR_FORMAT; break; }
            memcpy(packets + used, body, lace);
            used += lace;
            body += lace;
            if (lace < 255) ends[found++] = used;
        }
        if (h[5] & 4) break;   // 最後のページ（ヘッダーだけで終わる）
        size_t length = 27u + h[26];
        for (unsigned i = 0; i < h[26]; i++) length += h[27 + i];
        at += length;
    }
    if (status == ET_VORBIS_OK && found < 3) status = ET_VORBIS_ERR_FORMAT;
    if (status == ET_VORBIS_OK) {
        const uint8_t *ident = packets;
        size_t identLength = ends[0];
        if (identLength != 30 || ident[0] != 1 || memcmp(ident + 1, "vorbis", 6) != 0 || le32(ident + 7) != 0 ||
            ident[11] != 1 || le32(ident + 12) != sampleRate || !(ident[29] & 1))
            status = ET_VORBIS_ERR_FORMAT;
        else if (!commentPacketOk(packets + ends[0], ends[1] - ends[0]) ||
                 !setupPacketOk(packets + ends[1], ends[2] - ends[1]))
            status = ET_VORBIS_ERR_FORMAT;
    }
    free(packets);
    return status;
}

// MARK: - 復号器

static void releaseDecoder(ETVorbisStream *s)
{
    if (s->decoder) stb_vorbis_close(s->decoder);
    s->decoder = NULL;
    s->decoderPosition = 0;
    s->decoderBytes = 0;
}

/// 復号器を開く（先頭から）。モノとレートも毎回確かめる。
static int openDecoder(ETVorbisStream *s)
{
    int err = 0;
    stb_vorbis *v = stb_vorbis_open_memory(s->ogg, (int)s->size, &err, NULL);
    if (!v) return err == VORBIS_outofmem ? ET_VORBIS_ERR_MEMORY : ET_VORBIS_ERR_FORMAT;
    stb_vorbis_info info = stb_vorbis_get_info(v);
    if (info.channels != 1 || info.sample_rate != s->sampleRate) {
        stb_vorbis_close(v);
        return ET_VORBIS_ERR_FORMAT;
    }
    s->decoder = v;
    s->decoderPosition = 0;
    s->decoderBytes = (size_t)info.setup_memory_required + (size_t)info.temp_memory_required +
                      (size_t)info.setup_temp_memory_required;
    return ET_VORBIS_OK;
}

/// 復号器から n フレームを dst へ。足りなければ戻りが n 未満。
static uint64_t pump(ETVorbisStream *s, float *dst, uint64_t n)
{
    uint64_t done = 0;
    while (done < n) {
        uint64_t want = n - done < ET_VORBIS_CHUNK ? n - done : ET_VORBIS_CHUNK;
        int got = stb_vorbis_get_samples_float_interleaved(s->decoder, 1, dst + done, (int)want);
        if (got <= 0) break;
        done += (uint64_t)got;
        s->decoderPosition += (uint64_t)got;
    }
    return done;
}

/// 先頭から end フレームまで復号済みにする。
static int ensure(ETVorbisStream *s, uint64_t end)
{
    if (end <= s->decoded) return ET_VORBIS_OK;
    // 最初（頭のページだけのことが多い）は要る分だけ。続きは先読みして、復号器の開閉を減らす。
    uint64_t target = s->decoded == 0 ? end : (end > s->decoded + ET_VORBIS_AHEAD ? end : s->decoded + ET_VORBIS_AHEAD);
    target = (target + ET_VORBIS_PAGE - 1) / ET_VORBIS_PAGE * ET_VORBIS_PAGE;
    if (target > s->sourceFrames) target = s->sourceFrames;
    if (target < end) target = end;

    if (target > s->capacity) {
        float *grown = (float *)realloc(s->pcm, (size_t)target * sizeof(float));
        if (!grown) return ET_VORBIS_ERR_MEMORY;
        s->pcm = grown;
        s->capacity = target;
    }

    if (!s->decoder) {
        int status = openDecoder(s);
        if (status != ET_VORBIS_OK) return status;
    }
    // 復号器が閉じていた（開き直した）ときは、先頭から読み捨てて、覚えている所の終わりに追いつく。
    // 同じ入力を同じ手順で読むので、読み捨てる値は覚えているものと同じ。覚えている PCM には書かない
    // （無害な値の置き換えのために、確かめて直した値（非有限を 0 にしたもの）を壊さない）。
    if (s->decoderPosition > s->decoded) {
        // ここへは来ない（復号器は decoded より先へ進めない）。進んでいたら作り直す。
        releaseDecoder(s);
        int status = openDecoder(s);
        if (status != ET_VORBIS_OK) return status;
    }
    if (s->decoderPosition < s->decoded) {
        float *scratch = (float *)malloc((size_t)ET_VORBIS_CHUNK * sizeof(float));
        if (!scratch) return ET_VORBIS_ERR_MEMORY;
        while (s->decoderPosition < s->decoded) {
            uint64_t behind = s->decoded - s->decoderPosition;
            uint64_t want = behind < ET_VORBIS_CHUNK ? behind : ET_VORBIS_CHUNK;
            if (pump(s, scratch, want) != want) {
                free(scratch);
                releaseDecoder(s);
                return ET_VORBIS_ERR_FORMAT;
            }
        }
        free(scratch);
    }

    uint64_t before = s->decoded;
    uint64_t got = pump(s, s->pcm + s->decoded, target - s->decoded);
    for (uint64_t i = before; i < before + got; i++)
        if (!isfinite(s->pcm[i])) s->pcm[i] = 0.0f;
    s->decoded = before + got;
    // 目標まで届かなくても、要る所（end）まで届いていればよい。
    if (s->decoded < end) {
        // 復号器が先に終わった。この先は読めないので閉じる（同じ所を読み直しても同じ）。
        releaseDecoder(s);
        return ET_VORBIS_ERR_SHORT;
    }
    return ET_VORBIS_OK;
}

// MARK: - 公開

ETVorbisStream *ETVorbisStream_Open(const uint8_t *ogg, size_t size, uint32_t sampleRate, uint64_t sourceFrames,
                                    int *error)
{
    int status = ET_VORBIS_OK;
    ETVorbisStream *s = NULL;
    if (!ogg || size < 58 || sampleRate < 1 || sampleRate > 768000 || sourceFrames < 1) {
        status = ET_VORBIS_ERR_ARGUMENT;
    } else if (size > ET_VORBIS_MAX_BYTES || sourceFrames > ET_VORBIS_MAX_FRAMES) {
        status = ET_VORBIS_ERR_LIMIT;
    } else if ((status = validatePages(ogg, size, sourceFrames)) == ET_VORBIS_OK &&
               (status = validateHeaders(ogg, size, sampleRate)) == ET_VORBIS_OK) {
        s = (ETVorbisStream *)calloc(1, sizeof *s);
        if (!s) {
            status = ET_VORBIS_ERR_MEMORY;
        } else {
            s->ogg = (uint8_t *)malloc(size);
            if (!s->ogg) {
                status = ET_VORBIS_ERR_MEMORY;
            } else {
                memcpy(s->ogg, ogg, size);
                s->size = size;
                s->sampleRate = sampleRate;
                s->sourceFrames = sourceFrames;
                // ヘッダーが読めるか・モノか・レートが合うかをここで確かめ、復号器は閉じておく。
                status = openDecoder(s);
                if (status == ET_VORBIS_OK) releaseDecoder(s);
            }
            if (status != ET_VORBIS_OK) { ETVorbisStream_Close(s); s = NULL; }
        }
    }
    if (error) *error = status;
    return status == ET_VORBIS_OK ? s : NULL;
}

int ETVorbisStream_Read(ETVorbisStream *s, uint64_t first, uint32_t count, float *out)
{
    if (!s || !out || count == 0 || first >= s->sourceFrames || count > s->sourceFrames - first)
        return ET_VORBIS_ERR_ARGUMENT;
    int status = ensure(s, first + count);
    if (status != ET_VORBIS_OK) return status;
    memcpy(out, s->pcm + first, (size_t)count * sizeof(float));
    return ET_VORBIS_OK;
}

size_t ETVorbisStream_Bytes(const ETVorbisStream *s)
{
    if (!s) return 0;
    return s->size + (size_t)s->capacity * sizeof(float) + s->decoderBytes;
}

int ETVorbisStream_HasDecoder(const ETVorbisStream *s) { return s && s->decoder ? 1 : 0; }

uint64_t ETVorbisStream_Decoded(const ETVorbisStream *s) { return s ? s->decoded : 0; }

void ETVorbisStream_ReleaseDecoder(ETVorbisStream *s)
{
    if (s) releaseDecoder(s);
}

void ETVorbisStream_Close(ETVorbisStream *s)
{
    if (!s) return;
    releaseDecoder(s);
    free(s->pcm);
    free(s->ogg);
    free(s);
}
