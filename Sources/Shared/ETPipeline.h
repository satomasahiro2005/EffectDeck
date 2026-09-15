//  ETPipeline.h
//  EffeTune の鎖を、バスつきで動かす。
//
//  以前は et_instance_process を 1 個ずつ直列に呼んでいたが、それだとバスが持てない。
//  EffeTune はエフェクトごとに入力バスと出力バスを選べて、並列や側鎖を組める。
//  その機能は et_pipeline_configure に渡す descriptor 側にあるので、そちらへ移した。
//
//  バスの決まり（dsp/core/engine.cpp:892 の processPipeline を読んで確認）:
//    - バス 0 が本線。et_arena_combined_ptr がその置き場で、入口であり出口
//    - バス 1〜4 は毎ブロック消される
//    - 入力バスと出力バスが同じならその場で処理、違えば写して処理してから出力バスへ加算
//    - descriptor の並び順に処理される
//
//  configure は遅延補正の器を作り直すので確保が入る。だから音のスレッドで
//  毎ブロック呼ぶものではないが、pipeline_ を書き換えるので処理中に
//  別スレッドから呼ぶと壊れる。EffeTune 自身も AudioWorklet スレッドで
//  configure と process の両方を呼んで直列化しているので、こちらも同じにした。
//  確保が起きるのは鎖を変えたときだけ。

#ifndef ETPipeline_h
#define ETPipeline_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ET_PIPE_MAX_NODES 64

/// channelSpec の値。EffeTune の descriptor と同じ。
enum {
    ET_CHANNEL_ALL    = -2,   // 全チャンネル
    ET_CHANNEL_STEREO = -1,   // 先頭の 2 つ
    // 0〜15 は個別のチャンネル、16〜23 はステレオ対（(値-16)*2 から 2 つ）
};

typedef struct {
    uint32_t instance;
    uint8_t  enabled;      // 0 or 1
    uint8_t  inputBus;     // 0〜4
    uint8_t  outputBus;    // 0〜4
    int8_t   channelSpec;
    uint8_t  sectionGate;  // 0 or 1
} ETPipeNode;

void ETPipeline_SetEngine(uint32_t engine);

/// 鎖を差し替える。UI スレッドから呼ぶ。
/// 実際に engine へ渡すのは、次に音のスレッドが回ってきたとき。
void ETPipeline_Publish(const ETPipeNode *nodes, uint32_t count);

/// 鎖全体を素通しにする。
void ETPipeline_SetBypass(int bypass);

/// 本線の置き場。ここへプレーナで書き、処理後はここから読む。
/// 並びは ch0 のフレームが frames 個、その後 ch1 …。
float *ETPipeline_MainBus(void);

/// 1 ブロック処理する。リアルタイムスレッドから呼ぶ。
/// 戻り値は通したノード数。0 は素通しか、まだ組めていないか。
uint32_t ETPipeline_Process(uint32_t channels, uint32_t frames, double timeSeconds);

/// 直近の et_pipeline_configure が返した値。0 以外なら組めていない。
int32_t ETPipeline_LastStatus(void);

/// ETPipeline_Process が呼ばれた回数。
/// instance を壊す前に、この値が 2 つ進むのを待てば読み終えたと分かる。
uint64_t ETPipeline_ProcessCount(void);

#ifdef __cplusplus
}
#endif

#endif /* ETPipeline_h */
