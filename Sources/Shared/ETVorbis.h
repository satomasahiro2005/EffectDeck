//  ETVorbis.h
//  SoundFont 3（SF3）の標本（モノの Ogg Vorbis）を、float の PCM にして返す。
//
//  SF3 の標本は標本ごとに独立した Ogg Vorbis で、上流の Web 版は WebCodecs の AudioDecoder で読む。
//  iOS ではその代わりに stb_vorbis（Sources/Shared/ThirdParty/stb_vorbis.c、上流のまま）を使う。
//  **音のスレッドでは呼ばない。**確保も長い計算もする。呼ぶのは ETSFZPageSource（供給のスレッド）と、
//  control 側の resident ページ（ETSFZStream.preload）だけで、1 本の ETVorbisStream は 1 つのスレッドから使う。
//
//  作り:
//    Open   Ogg のバイト列を写し、全ページの枠と CRC を確かめ、ヘッダーを読む。検査が通れば、
//           stb_vorbis は **枠の正しい（CRC が合う）ストリーム**だけを見る。
//    Read   [first, first+count) を返す。まだ復号していない所まで、先頭から続きを復号して足す。
//           復号した所は覚える（先頭から。頭だけ要る resident ページは 1 ページ分しか復号しない）。
//           最後のページの granule（sourceFrames）で切る。stb_vorbis は最後のブロックを切らないので、
//           それより後ろは返さない。
//    ReleaseDecoder  復号器（stb_vorbis の実体。符号表で数百 KB）だけ閉じる。復号済みの PCM は残す。
//                    続きを読むときに、復号器を開き直して先頭から読み捨てて追いつく。
//
//  数字の根拠: 上流 js/sf2/ogg-vorbis.js の readOggVorbisMetadata（枠・CRC・モノ・レート）と decodeOggVorbisFrames
//  （granule で切る）。上流は ogg の最後のページの granule を frames にするので、ここでも sourceFrames をそれにする。

#ifndef ETVorbis_h
#define ETVorbis_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1 本の標本の Ogg の上限（バイト）。これを超えるものは開かない。
#define ET_VORBIS_MAX_BYTES ((size_t)64 * 1024 * 1024)
/// 1 本の標本の復号後の上限（フレーム）。float で 64 MiB。先頭から全部覚えるので、これを超える標本は鳴らさない。
#define ET_VORBIS_MAX_FRAMES ((uint64_t)16 * 1024 * 1024)

enum {
    ET_VORBIS_OK = 0,
    /// 引数が不正（範囲が sourceFrames の外・count が 0・NULL）。
    ET_VORBIS_ERR_ARGUMENT = -1,
    /// 枠・CRC・ヘッダーがおかしい、モノでない、レートが SHDR と違う、符号器が読めない。
    ET_VORBIS_ERR_FORMAT = -2,
    /// 復号器が sourceFrames に届く前に終わった（途中で切れている）。
    ET_VORBIS_ERR_SHORT = -3,
    ET_VORBIS_ERR_MEMORY = -4,
    /// 上限（ET_VORBIS_MAX_*）を超える。
    ET_VORBIS_ERR_LIMIT = -5
};

typedef struct ETVorbisStream ETVorbisStream;

/// ogg（size バイト）を開く。写しを持つので、呼んだ後に ogg は捨ててよい。
/// sampleRate と sourceFrames は SoundFont 側の表の値（レートは SHDR、sourceFrames は最後のページの granule）。
/// 失敗したら NULL を返し、*error に ET_VORBIS_ERR_* を入れる（error は NULL でもよい）。
ETVorbisStream *ETVorbisStream_Open(const uint8_t *ogg, size_t size, uint32_t sampleRate, uint64_t sourceFrames,
                                    int *error);

/// first から count フレームを out へ（モノの float）。first + count は sourceFrames 以下。
/// 戻りは ET_VORBIS_OK か ET_VORBIS_ERR_*。失敗しても Stream は壊れない（同じ範囲をもう一度呼んでよい）。
int ETVorbisStream_Read(ETVorbisStream *stream, uint64_t first, uint32_t count, float *out);

/// いま持っているメモリ（Ogg の写し + 復号済みの PCM + 開いている復号器の見積り）。キャッシュの予算の勘定に使う。
size_t ETVorbisStream_Bytes(const ETVorbisStream *stream);

/// 復号器が開いているか。
int ETVorbisStream_HasDecoder(const ETVorbisStream *stream);

/// 復号済みのフレーム数（先頭から）。
uint64_t ETVorbisStream_Decoded(const ETVorbisStream *stream);

/// 復号器だけ閉じる（PCM は残す）。
void ETVorbisStream_ReleaseDecoder(ETVorbisStream *stream);

/// すべて閉じる。NULL でもよい。
void ETVorbisStream_Close(ETVorbisStream *stream);

#ifdef __cplusplus
}
#endif

#endif /* ETVorbis_h */
