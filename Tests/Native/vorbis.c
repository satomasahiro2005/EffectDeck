//  vorbis.c
//  Sources/Shared/ETVorbis.c（SF3 の Vorbis 標本を stb_vorbis で読む）の試験。
//  見本は Tests/Fixtures/SFZ/vorbis（Tools/golden/vorbis_fixtures.py が ffmpeg の libvorbis で作った Ogg と、
//  同じ ffmpeg の復号が出した s16 の答え）。
//
//  見るもの:
//    - 復号が答えと 1.5 LSB 以内（答えは 16 bit に丸めてあるので、丸め 0.5 LSB + 復号器の違い）
//    - ページ単位・不規則な順・復号器を閉じて開き直した読みが、一括の読みと 1 ビットまで同じ
//    - 頭のページだけ要るときは頭だけ復号する（resident ページ）
//    - 最後の granule で切る（sourceFrames の外は返さない・granule と食い違う表は開かない）
//    - 壊れた入力（CRC・途中で切れ・モノでない・レート違い・上限）を、確保を残さず断る
//    - **CRC を直した壊れ方**（枠は正しく中身だけ壊れた Ogg）でも落ちない・値が有限（ASan/UBSan の下）

#include "ETVorbis.h"
#include "et_test.h"

#include <math.h>
#include <stdint.h>

#ifndef ET_VORBIS_FIXTURES
#error "ET_VORBIS_FIXTURES (Tests/Fixtures/SFZ/vorbis) is required"
#endif

typedef struct {
    const char *name;
    uint32_t rate;
    uint64_t frames;
} Case;

// vorbis-golden.json と同じ（モノのもの）。
static const Case kCases[] = {
    {"tone-44100", 44100, 12000},
    {"rate-22050", 22050, 9000},
    {"tiny-48000", 48000, 300},
    {"long-44100", 44100, 70000},
};
#define N_CASES (sizeof kCases / sizeof kCases[0])

static uint8_t *readFile(const char *name, const char *ext, size_t *n)
{
    char path[600];
    snprintf(path, sizeof path, "%s/%s.%s", ET_VORBIS_FIXTURES, name, ext);
    FILE *f = fopen(path, "rb");
    ET_CHECK_MSG(f != NULL, "cannot open %s", path);
    fseek(f, 0, SEEK_END);
    *n = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = (uint8_t *)malloc(*n ? *n : 1);
    ET_CHECK(b != NULL);
    ET_CHECK(fread(b, 1, *n, f) == *n);
    fclose(f);
    return b;
}

static ETVorbisStream *openCase(const Case *c, uint8_t **ogg, size_t *size)
{
    *ogg = readFile(c->name, "ogg", size);
    int error = 99;
    ETVorbisStream *s = ETVorbisStream_Open(*ogg, *size, c->rate, c->frames, &error);
    ET_CHECK_MSG(s != NULL, "%s: open failed (%d)", c->name, error);
    ET_CHECK(error == ET_VORBIS_OK);
    return s;
}

/// 全体を一括で読む（答えの基準）。
static float *readAllFrames(ETVorbisStream *s, uint64_t frames)
{
    float *out = (float *)malloc((size_t)frames * sizeof(float));
    ET_CHECK(out != NULL);
    // count は 32 ビット。1 回で足りる大きさ。
    ET_CHECK(ETVorbisStream_Read(s, 0, (uint32_t)frames, out) == ET_VORBIS_OK);
    return out;
}

// MARK: - 復号

ET_CASE(decode_matches_ffmpeg_reference)
{
    for (size_t k = 0; k < N_CASES; k++) {
        const Case *c = &kCases[k];
        uint8_t *ogg;
        size_t size;
        ETVorbisStream *s = openCase(c, &ogg, &size);
        float *pcm = readAllFrames(s, c->frames);
        size_t refBytes;
        uint8_t *ref = readFile(c->name, "s16", &refBytes);
        ET_CHECK_MSG(refBytes == c->frames * 2, "%s: ref %zu bytes", c->name, refBytes);
        double worst = 0;
        for (uint64_t i = 0; i < c->frames; i++) {
            int16_t r = (int16_t)((uint16_t)ref[i * 2] | (uint16_t)ref[i * 2 + 1] << 8);
            double e = fabs((double)pcm[i] - (double)r / 32768.0) * 32768.0;
            if (e > worst) worst = e;
        }
        printf("  %s: max error %.3f LSB over %llu frames\n", c->name, worst, (unsigned long long)c->frames);
        ET_CHECK_MSG(worst <= 1.5, "%s: worst error %.3f LSB", c->name, worst);
        free(ref);
        free(pcm);
        ETVorbisStream_Close(s);
        free(ogg);
    }
}

ET_CASE(paged_reads_equal_whole_read)
{
    for (size_t k = 0; k < N_CASES; k++) {
        const Case *c = &kCases[k];
        uint8_t *ogg;
        size_t size;
        ETVorbisStream *whole = openCase(c, &ogg, &size);
        float *want = readAllFrames(whole, c->frames);
        ETVorbisStream *paged = ETVorbisStream_Open(ogg, size, c->rate, c->frames, NULL);
        ET_CHECK(paged != NULL);
        float page[4096];
        for (uint64_t first = 0; first < c->frames; first += 4096) {
            uint32_t n = (uint32_t)(c->frames - first < 4096 ? c->frames - first : 4096);
            ET_CHECK(ETVorbisStream_Read(paged, first, n, page) == ET_VORBIS_OK);
            ET_CHECK_MSG(memcmp(page, want + first, n * sizeof(float)) == 0, "%s: page at %llu differs", c->name,
                         (unsigned long long)first);
        }
        ET_CHECK(ETVorbisStream_Decoded(paged) == c->frames);
        free(want);
        ETVorbisStream_Close(paged);
        ETVorbisStream_Close(whole);
        free(ogg);
    }
}

static uint32_t lcg(uint32_t *state)
{
    *state = *state * 1664525u + 1013904223u;
    return *state >> 8;
}

ET_CASE(random_pages_with_decoder_release_equal_whole_read)
{
    const Case *c = &kCases[3];   // 17 ページ強。先読みの境界（65536）をまたぐ
    uint8_t *ogg;
    size_t size;
    ETVorbisStream *whole = openCase(c, &ogg, &size);
    float *want = readAllFrames(whole, c->frames);
    ETVorbisStream *s = ETVorbisStream_Open(ogg, size, c->rate, c->frames, NULL);
    ET_CHECK(s != NULL);
    uint32_t state = 12345;
    uint64_t pages = (c->frames + 4095) / 4096;
    float page[4096];
    for (int round = 0; round < 200; round++) {
        uint64_t p = lcg(&state) % pages;
        uint64_t first = p * 4096;
        uint32_t n = (uint32_t)(c->frames - first < 4096 ? c->frames - first : 4096);
        if (lcg(&state) % 3 == 0) ETVorbisStream_ReleaseDecoder(s);
        if (lcg(&state) % 7 == 0) {
            // 途中から始まる読み（ページの境界に合わない範囲）
            first += lcg(&state) % n;
            n = (uint32_t)(c->frames - first < 4096 ? c->frames - first : 4096);
        }
        ET_CHECK(ETVorbisStream_Read(s, first, n, page) == ET_VORBIS_OK);
        ET_CHECK_MSG(memcmp(page, want + first, n * sizeof(float)) == 0, "round %d: page at %llu differs", round,
                     (unsigned long long)first);
    }
    free(want);
    ETVorbisStream_Close(s);
    ETVorbisStream_Close(whole);
    free(ogg);
}

ET_CASE(head_page_decodes_only_the_head)
{
    const Case *c = &kCases[3];
    uint8_t *ogg;
    size_t size;
    ogg = readFile(c->name, "ogg", &size);
    ETVorbisStream *s = ETVorbisStream_Open(ogg, size, c->rate, c->frames, NULL);
    ET_CHECK(s != NULL);
    ET_CHECK(ETVorbisStream_Decoded(s) == 0);
    ET_CHECK(!ETVorbisStream_HasDecoder(s));   // Open は検査だけして復号器を閉じておく
    size_t closed = ETVorbisStream_Bytes(s);
    ET_CHECK(closed == size);
    float page[4096];
    ET_CHECK(ETVorbisStream_Read(s, 0, 4096, page) == ET_VORBIS_OK);
    ET_CHECK(ETVorbisStream_Decoded(s) == 4096);
    ET_CHECK(ETVorbisStream_HasDecoder(s));
    ET_CHECK(ETVorbisStream_Bytes(s) > size + 4096 * sizeof(float));
    // 2 回目の要求（続き）は先読みする。
    ET_CHECK(ETVorbisStream_Read(s, 4096, 4096, page) == ET_VORBIS_OK);
    ET_CHECK_MSG(ETVorbisStream_Decoded(s) == 4096 + 16 * 4096, "decoded %llu", (unsigned long long)ETVorbisStream_Decoded(s));
    // 復号器を閉じると、PCM は残り、復号器の分だけ減る。
    size_t open = ETVorbisStream_Bytes(s);
    ETVorbisStream_ReleaseDecoder(s);
    ET_CHECK(!ETVorbisStream_HasDecoder(s));
    ET_CHECK(ETVorbisStream_Bytes(s) < open);
    ET_CHECK(ETVorbisStream_Decoded(s) == 4096 + 16 * 4096);
    // 覚えている所は復号器を開かずに読める。
    ET_CHECK(ETVorbisStream_Read(s, 8192, 4096, page) == ET_VORBIS_OK);
    ET_CHECK(!ETVorbisStream_HasDecoder(s));
    ETVorbisStream_Close(s);
    free(ogg);
}

ET_CASE(output_is_cropped_to_final_granule)
{
    const Case *c = &kCases[0];   // 12000 フレーム。ffmpeg の復号は 12032 まで出す（最後のブロックは切られない）
    uint8_t *ogg;
    size_t size;
    ETVorbisStream *s = openCase(c, &ogg, &size);
    float page[4096];
    ET_CHECK(ETVorbisStream_Read(s, 8192, 3808, page) == ET_VORBIS_OK);   // 最後のページ
    ET_CHECK(ETVorbisStream_Decoded(s) <= c->frames);
    ET_CHECK(ETVorbisStream_Read(s, 8192, 3809, page) == ET_VORBIS_ERR_ARGUMENT);
    ET_CHECK(ETVorbisStream_Read(s, c->frames, 1, page) == ET_VORBIS_ERR_ARGUMENT);
    ET_CHECK(ETVorbisStream_Read(s, 0, 0, page) == ET_VORBIS_ERR_ARGUMENT);
    ET_CHECK(ETVorbisStream_Read(s, UINT64_MAX, 2, page) == ET_VORBIS_ERR_ARGUMENT);
    ET_CHECK(ETVorbisStream_Read(NULL, 0, 1, page) == ET_VORBIS_ERR_ARGUMENT);
    // granule と食い違う表（sourceFrames の違い・レートの違い）は開かない。
    int error = 0;
    ET_CHECK(ETVorbisStream_Open(ogg, size, c->rate, c->frames - 1, &error) == NULL && error == ET_VORBIS_ERR_FORMAT);
    ET_CHECK(ETVorbisStream_Open(ogg, size, c->rate, c->frames + 1, &error) == NULL && error == ET_VORBIS_ERR_FORMAT);
    ET_CHECK(ETVorbisStream_Open(ogg, size, c->rate + 1, c->frames, &error) == NULL && error == ET_VORBIS_ERR_FORMAT);
    ETVorbisStream_Close(s);
    free(ogg);
}

// MARK: - 断る

ET_CASE(rejects_stereo_truncated_and_garbage)
{
    int error = 0;
    size_t n;
    uint8_t *stereo = readFile("stereo-44100", "ogg", &n);
    ET_CHECK(ETVorbisStream_Open(stereo, n, 44100, 4000, &error) == NULL);
    ET_CHECK_MSG(error == ET_VORBIS_ERR_FORMAT, "stereo: %d", error);
    free(stereo);

    const Case *c = &kCases[0];
    uint8_t *ogg = readFile(c->name, "ogg", &n);
    // 途中で切れている（EOS のページが無い）。
    ET_CHECK(ETVorbisStream_Open(ogg, n - 40, c->rate, c->frames, &error) == NULL && error == ET_VORBIS_ERR_FORMAT);
    ET_CHECK(ETVorbisStream_Open(ogg, 100, c->rate, c->frames, &error) == NULL);
    ET_CHECK(ETVorbisStream_Open(ogg, 57, c->rate, c->frames, &error) == NULL && error == ET_VORBIS_ERR_ARGUMENT);
    // 先頭がずれている。
    ET_CHECK(ETVorbisStream_Open(ogg + 1, n - 1, c->rate, c->frames, &error) == NULL && error == ET_VORBIS_ERR_FORMAT);
    uint8_t zeros[256] = {0};
    ET_CHECK(ETVorbisStream_Open(zeros, sizeof zeros, c->rate, c->frames, &error) == NULL && error == ET_VORBIS_ERR_FORMAT);
    // 引数。
    ET_CHECK(ETVorbisStream_Open(NULL, n, c->rate, c->frames, &error) == NULL && error == ET_VORBIS_ERR_ARGUMENT);
    ET_CHECK(ETVorbisStream_Open(ogg, n, 0, c->frames, &error) == NULL && error == ET_VORBIS_ERR_ARGUMENT);
    ET_CHECK(ETVorbisStream_Open(ogg, n, c->rate, 0, &error) == NULL && error == ET_VORBIS_ERR_ARGUMENT);
    // 上限（中身は読まれない）。
    ET_CHECK(ETVorbisStream_Open(ogg, ET_VORBIS_MAX_BYTES + 1, c->rate, c->frames, &error) == NULL &&
             error == ET_VORBIS_ERR_LIMIT);
    ET_CHECK(ETVorbisStream_Open(ogg, n, c->rate, ET_VORBIS_MAX_FRAMES + 1, &error) == NULL && error == ET_VORBIS_ERR_LIMIT);
    // error は NULL でもよい。
    ET_CHECK(ETVorbisStream_Open(ogg, n, c->rate, c->frames + 5, NULL) == NULL);
    ETVorbisStream_Close(NULL);
    free(ogg);
}

/// Ogg の全ページの CRC を書き直す。
static void fixCrcs(uint8_t *b, size_t size)
{
    size_t at = 0;
    while (at + 27 <= size && b[at] == 'O' && b[at + 1] == 'g' && b[at + 2] == 'g' && b[at + 3] == 'S') {
        size_t length = 27u + b[at + 26];
        if (at + length > size) return;
        for (unsigned i = 0; i < b[at + 26]; i++) length += b[at + 27 + i];
        if (at + length > size) return;
        uint32_t crc = 0;
        for (size_t i = 0; i < length; i++) {
            uint8_t byte = (i >= 22 && i < 26) ? 0 : b[at + i];
            crc ^= (uint32_t)byte << 24;
            for (int bit = 0; bit < 8; bit++) crc = crc & 0x80000000u ? (crc << 1) ^ 0x04c11db7u : crc << 1;
        }
        b[at + 22] = (uint8_t)crc;
        b[at + 23] = (uint8_t)(crc >> 8);
        b[at + 24] = (uint8_t)(crc >> 16);
        b[at + 25] = (uint8_t)(crc >> 24);
        at += length;
    }
}

ET_CASE(damaged_pages_fail_the_crc)
{
    const Case *c = &kCases[0];
    size_t n;
    uint8_t *ogg = readFile(c->name, "ogg", &n);
    uint32_t state = 7;
    for (int round = 0; round < 200; round++) {
        uint8_t *copy = (uint8_t *)malloc(n);
        memcpy(copy, ogg, n);
        // 1 バイトだけ変える（CRC の欄そのものを変えても、中身を変えても、CRC は合わなくなる）。
        copy[lcg(&state) % n] ^= (uint8_t)(1u << (lcg(&state) % 8));
        int error = 0;
        ETVorbisStream *s = ETVorbisStream_Open(copy, n, c->rate, c->frames, &error);
        // 枠の長さや granule を変えると別の形で断られうるが、通ってはいけない（CRC が必ず合わなくなる）。
        ET_CHECK_MSG(s == NULL && error == ET_VORBIS_ERR_FORMAT, "round %d: opened a damaged stream", round);
        free(copy);
    }
    free(ogg);
}

ET_CASE(short_stream_reports_short_and_stays_usable)
{
    // 最後のページの granule を大きくして（CRC は直す）、復号器が先に終わる表を作る。
    const Case *c = &kCases[2];
    size_t n;
    uint8_t *ogg = readFile(c->name, "ogg", &n);
    size_t at = 0, last = 0;
    while (at + 27 <= n) {
        size_t length = 27u + ogg[at + 26];
        for (unsigned i = 0; i < ogg[at + 26]; i++) length += ogg[at + 27 + i];
        last = at;
        if (ogg[at + 5] & 4) break;
        at += length;
    }
    uint64_t fake = 5000;
    for (int k = 0; k < 8; k++) ogg[last + 6 + k] = (uint8_t)(fake >> (8 * k));
    fixCrcs(ogg, n);
    ETVorbisStream *s = ETVorbisStream_Open(ogg, n, c->rate, fake, NULL);
    ET_CHECK(s != NULL);
    float *page = (float *)malloc(5000 * sizeof(float));
    ET_CHECK(ETVorbisStream_Read(s, 0, 100, page) == ET_VORBIS_OK);
    ET_CHECK(ETVorbisStream_Read(s, 0, 5000, page) == ET_VORBIS_ERR_SHORT);
    ET_CHECK(!ETVorbisStream_HasDecoder(s));
    // 届く所までは、何度でも読める。
    ET_CHECK(ETVorbisStream_Read(s, 0, 300, page) == ET_VORBIS_OK);
    ET_CHECK(ETVorbisStream_Read(s, 0, 5000, page) == ET_VORBIS_ERR_SHORT);
    free(page);
    ETVorbisStream_Close(s);
    free(ogg);
}

// MARK: - 枠が正しい壊れ方

/// needle が最初に現れる位置（無ければ n）。
static size_t findBytes(const uint8_t *b, size_t n, const char *needle, size_t len)
{
    for (size_t i = 0; i + len <= n; i++)
        if (memcmp(b + i, needle, len) == 0) return i;
    return n;
}

/// 枠と CRC は正しく、中身（ヘッダーのパケットや音声のパケット）だけ壊した Ogg。stb_vorbis の本体に届く。
/// 結果は成功でも失敗でもよく、落ちない・読めた値が有限であることだけを見る（ASan/UBSan の下で走らせる）。
/// 回数は環境変数 ET_VORBIS_FUZZ_ROUNDS（1 見本あたり。既定 400）で増やせる。
ET_CASE(crc_fixed_mutations_do_not_crash)
{
    uint32_t state = 99;
    long opened = 0, readable = 0, total = 0;
    long rounds = 400;
    if (getenv("ET_VORBIS_FUZZ_ROUNDS")) rounds = atol(getenv("ET_VORBIS_FUZZ_ROUNDS"));
    if (getenv("ET_VORBIS_FUZZ_SEED")) state = (uint32_t)atol(getenv("ET_VORBIS_FUZZ_SEED"));
    for (size_t k = 0; k < 3; k++) {   // long は PCM が大きいので入れない
        const Case *c = &kCases[k];
        size_t n;
        uint8_t *ogg = readFile(c->name, "ogg", &n);
        uint8_t *copy = (uint8_t *)malloc(n);
        float *pcm = (float *)malloc((size_t)c->frames * sizeof(float));
        // 設定ヘッダー（符号表・床・残差・写像・モード）と、コメントのパケット。
        size_t comment = findBytes(ogg, n, "\x03vorbis", 7), setup = findBytes(ogg, n, "\x05vorbis", 7);
        ET_CHECK(comment < n && setup < n && comment < setup);
        size_t setupLength = 800;   // 設定ヘッダーの頭（符号表の見出しが集まる所）
        if (setup + setupLength > n) setupLength = n - setup;
        for (long round = 0; round < rounds; round++) {
            memcpy(copy, ogg, n);
            int edits = 1 + (int)(lcg(&state) % 3);
            for (int e = 0; e < edits; e++) {
                size_t pos;
                switch (lcg(&state) % 4) {
                case 0: pos = setup + lcg(&state) % setupLength; break;                 // 設定の頭
                case 1: pos = comment + lcg(&state) % (setup - comment); break;         // コメント
                case 2: pos = setup + lcg(&state) % (n - setup); break;                 // 設定から後ろ
                default: pos = lcg(&state) % n; break;                                  // どこでも
                }
                copy[pos] = lcg(&state) % 4 == 0 ? (uint8_t)lcg(&state) : (uint8_t)(copy[pos] ^ (1u << (lcg(&state) % 8)));
            }
            fixCrcs(copy, n);
            total++;
            ETVorbisStream *s = ETVorbisStream_Open(copy, n, c->rate, c->frames, NULL);
            if (!s) continue;
            opened++;
            if (ETVorbisStream_Read(s, 0, (uint32_t)c->frames, pcm) == ET_VORBIS_OK) {
                readable++;
                for (uint64_t i = 0; i < c->frames; i++) ET_CHECK(isfinite(pcm[i]));
            }
            ETVorbisStream_Close(s);
        }
        free(pcm);
        free(copy);
        free(ogg);
    }
    printf("  %ld mutations: %ld opened, %ld fully readable\n", total, opened, readable);
    ET_CHECK(total == 3 * rounds);
}

/// stb_vorbis が検査せずに確保や書き込みの大きさに使う欄を、危ない値にして（CRC は直す）断られることを見る。
ET_CASE(hostile_header_fields_are_refused_before_stb_vorbis)
{
    const Case *c = &kCases[0];
    size_t n;
    uint8_t *ogg = readFile(c->name, "ogg", &n);
    size_t comment = findBytes(ogg, n, "\x03vorbis", 7), setup = findBytes(ogg, n, "\x05vorbis", 7);
    ET_CHECK(comment < n && setup < n);
    uint8_t *copy = (uint8_t *)malloc(n);
    int error = 0;

    // コメントの vendor 長が負の int / パケットより長い / 巨大。
    const uint32_t vendors[] = {0x80000000u, 0xffffffffu, 0x7fffffffu, 1u << 20};
    for (size_t i = 0; i < sizeof vendors / sizeof vendors[0]; i++) {
        memcpy(copy, ogg, n);
        for (int k = 0; k < 4; k++) copy[comment + 7 + k] = (uint8_t)(vendors[i] >> (8 * k));
        fixCrcs(copy, n);
        ET_CHECK_MSG(ETVorbisStream_Open(copy, n, c->rate, c->frames, &error) == NULL && error == ET_VORBIS_ERR_FORMAT,
                     "vendor length 0x%x was accepted", vendors[i]);
    }
    // コメントの件数が巨大（件ごとの長さを読む前にパケットの外へ出る）。
    {
        memcpy(copy, ogg, n);
        uint32_t vendor = (uint32_t)copy[comment + 7] | (uint32_t)copy[comment + 8] << 8 | (uint32_t)copy[comment + 9] << 16 |
                          (uint32_t)copy[comment + 10] << 24;
        size_t count = comment + 11 + vendor;
        ET_CHECK(count + 4 < setup);
        copy[count] = copy[count + 1] = copy[count + 2] = copy[count + 3] = 0xff;
        fixCrcs(copy, n);
        ET_CHECK(ETVorbisStream_Open(copy, n, c->rate, c->frames, &error) == NULL && error == ET_VORBIS_ERR_FORMAT);
    }
    // 最初の符号表（設定の [5] "vorbis" の次が符号表の数 - 1、その次が 0x42 0x43 0x56、次元数 2 バイト、符号数 3 バイト）。
    ET_CHECK(ogg[setup + 8] == 0x42 && ogg[setup + 9] == 0x43 && ogg[setup + 10] == 0x56);
    const struct { uint32_t dimensions, entries; } books[] = {
        {0xffff, 0xffffff},      // 積が 2^40
        {1024, 1u << 20},        // 積 2^30（int に切り詰めた大きさ 0 になる形）
        {4096, 262145},          // 積が 2^30 + 4096（4 バイトを掛けて切り詰めると 16384 になる形）
        {1, 0xffffff},           // 符号の数だけが巨大（疎な符号表の一時領域）
        {0, 100},                // 次元数 0
        {2, 0},                  // 符号の数 0
    };
    for (size_t i = 0; i < sizeof books / sizeof books[0]; i++) {
        memcpy(copy, ogg, n);
        copy[setup + 11] = (uint8_t)books[i].dimensions;
        copy[setup + 12] = (uint8_t)(books[i].dimensions >> 8);
        copy[setup + 13] = (uint8_t)books[i].entries;
        copy[setup + 14] = (uint8_t)(books[i].entries >> 8);
        copy[setup + 15] = (uint8_t)(books[i].entries >> 16);
        fixCrcs(copy, n);
        ET_CHECK_MSG(ETVorbisStream_Open(copy, n, c->rate, c->frames, &error) == NULL && error == ET_VORBIS_ERR_FORMAT,
                     "codebook dimensions %u entries %u was accepted", books[i].dimensions, books[i].entries);
    }
    free(copy);
    free(ogg);
}

static const et_case cases[] = {
    ET_ENTRY(decode_matches_ffmpeg_reference),
    ET_ENTRY(paged_reads_equal_whole_read),
    ET_ENTRY(random_pages_with_decoder_release_equal_whole_read),
    ET_ENTRY(head_page_decodes_only_the_head),
    ET_ENTRY(output_is_cropped_to_final_granule),
    ET_ENTRY(rejects_stereo_truncated_and_garbage),
    ET_ENTRY(damaged_pages_fail_the_crc),
    ET_ENTRY(short_stream_reports_short_and_stays_usable),
    ET_ENTRY(hostile_header_fields_are_refused_before_stb_vorbis),
    ET_ENTRY(crc_fixed_mutations_do_not_crash),
};

int main(int argc, char **argv)
{
    return et_run(argc, argv, cases, ET_COUNT(cases));
}
