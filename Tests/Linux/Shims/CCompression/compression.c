/* compression.c（Linuxの代役）。include/compression.hの頭書きを参照。 */
#include "compression.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct {
    z_stream z;
    int encode;
    int ended;
} et_state;

compression_status compression_stream_init(compression_stream *stream,
                                           compression_stream_operation operation,
                                           compression_algorithm algorithm) {
    if (stream == NULL || algorithm != COMPRESSION_ZLIB) return COMPRESSION_STATUS_ERROR;
    et_state *s = calloc(1, sizeof *s);
    if (s == NULL) return COMPRESSION_STATUS_ERROR;
    s->encode = operation == COMPRESSION_STREAM_ENCODE;
    int rc = s->encode ? deflateInit2(&s->z, 5, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY)
                       : inflateInit2(&s->z, -15);
    if (rc != Z_OK) {
        free(s);
        return COMPRESSION_STATUS_ERROR;
    }
    stream->state = s;
    stream->dst_ptr = NULL;
    stream->dst_size = 0;
    stream->src_ptr = NULL;
    stream->src_size = 0;
    return COMPRESSION_STATUS_OK;
}

compression_status compression_stream_process(compression_stream *stream, int flags) {
    if (stream == NULL || stream->state == NULL) return COMPRESSION_STATUS_ERROR;
    et_state *s = stream->state;
    if (s->ended) return COMPRESSION_STATUS_END;
    /* zlibのavail_*はuIntなので、大きい区切りは何度かに分けて渡す。 */
    for (;;) {
        uInt in = stream->src_size > UINT32_MAX ? UINT32_MAX : (uInt)stream->src_size;
        uInt out = stream->dst_size > UINT32_MAX ? UINT32_MAX : (uInt)stream->dst_size;
        s->z.next_in = (Bytef *)stream->src_ptr;
        s->z.avail_in = in;
        s->z.next_out = stream->dst_ptr;
        s->z.avail_out = out;
        int rc;
        if (s->encode) {
            rc = deflate(&s->z, (flags & COMPRESSION_STREAM_FINALIZE) ? Z_FINISH : Z_NO_FLUSH);
        } else {
            rc = inflate(&s->z, Z_NO_FLUSH);
        }
        size_t used = in - s->z.avail_in;
        size_t made = out - s->z.avail_out;
        stream->src_ptr += used;
        stream->src_size -= used;
        stream->dst_ptr += made;
        stream->dst_size -= made;
        if (rc == Z_STREAM_END) {
            s->ended = 1;
            return COMPRESSION_STATUS_END;
        }
        if (rc == Z_BUF_ERROR) return COMPRESSION_STATUS_OK; /* 進めない＝入力か出力が尽きた */
        if (rc != Z_OK) return COMPRESSION_STATUS_ERROR;
        /* Z_OK。出力が埋まった・入力を使い切った（締めの符号化を除く）・進まなかったら返す。
         * 続けるのは、4GiBを超える区切りを分けて渡しているときと、締めの符号化の途中だけ。 */
        int finishing = s->encode && (flags & COMPRESSION_STREAM_FINALIZE);
        if (stream->dst_size == 0) return COMPRESSION_STATUS_OK;
        if (stream->src_size == 0 && !finishing) return COMPRESSION_STATUS_OK;
        if (used == 0 && made == 0) return COMPRESSION_STATUS_OK;
    }
}

compression_status compression_stream_destroy(compression_stream *stream) {
    if (stream == NULL || stream->state == NULL) return COMPRESSION_STATUS_ERROR;
    et_state *s = stream->state;
    if (s->encode) deflateEnd(&s->z);
    else inflateEnd(&s->z);
    free(s);
    stream->state = NULL;
    return COMPRESSION_STATUS_OK;
}

size_t compression_encode_scratch_buffer_size(compression_algorithm algorithm) {
    (void)algorithm;
    return 0;
}

size_t compression_decode_scratch_buffer_size(compression_algorithm algorithm) {
    (void)algorithm;
    return 0;
}

static size_t run_buffer(compression_stream_operation op, uint8_t *dst, size_t dst_size,
                         const uint8_t *src, size_t src_size, compression_algorithm algorithm) {
    compression_stream s;
    if (compression_stream_init(&s, op, algorithm) != COMPRESSION_STATUS_OK) return 0;
    s.src_ptr = src;
    s.src_size = src_size;
    s.dst_ptr = dst;
    s.dst_size = dst_size;
    compression_status st = compression_stream_process(&s, COMPRESSION_STREAM_FINALIZE);
    size_t produced = dst_size - s.dst_size;
    compression_stream_destroy(&s);
    /* 符号化は終わりまで書けなければ0（Appleと同じ）。復号は書けたところまで返す。 */
    if (op == COMPRESSION_STREAM_ENCODE && st != COMPRESSION_STATUS_END) return 0;
    if (st == COMPRESSION_STATUS_ERROR) return 0;
    return produced;
}

size_t compression_encode_buffer(uint8_t *dst_buffer, size_t dst_size,
                                 const uint8_t *src_buffer, size_t src_size,
                                 void *scratch_buffer, compression_algorithm algorithm) {
    (void)scratch_buffer;
    return run_buffer(COMPRESSION_STREAM_ENCODE, dst_buffer, dst_size, src_buffer, src_size, algorithm);
}

size_t compression_decode_buffer(uint8_t *dst_buffer, size_t dst_size,
                                 const uint8_t *src_buffer, size_t src_size,
                                 void *scratch_buffer, compression_algorithm algorithm) {
    (void)scratch_buffer;
    return run_buffer(COMPRESSION_STREAM_DECODE, dst_buffer, dst_size, src_buffer, src_size, algorithm);
}
