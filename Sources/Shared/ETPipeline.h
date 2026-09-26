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
#include "ETExternalProcessor.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ET_PIPE_MAX_NODES 64
#define ET_EXTERNAL_MAX_PROCESSORS 8

enum {
    ET_PIPE_NODE_NATIVE = 0,
    ET_PIPE_NODE_EXTERNAL = 1,
};

/// channelSpec の値。EffeTune の descriptor と同じ。
enum {
    ET_CHANNEL_ALL    = -2,   // 全チャンネル
    ET_CHANNEL_STEREO = -1,   // 先頭の 2 つ
    // 0〜15 は個別のチャンネル、16〜23 はステレオ対（(値-16)*2 から 2 つ）
};

typedef struct {
    uint32_t instance;
    /// 0 = 切、1 = 入、**2 = 入だが数に入れない**。
    /// 2 は図に重ねるためだけに挿した段（EffeTuneDSP.syncProbes）に使う。
    /// descriptor へは 1 として書くので音の扱いは同じだが、
    /// 画面に出す「動いている数」には入れない。人が置いた段ではないため。
    uint8_t  enabled;      // 0, 1, 2
    uint8_t  inputBus;     // 0〜4
    uint8_t  outputBus;    // 0〜4
    int8_t   channelSpec;
    uint8_t  sectionGate;  // 0 or 1
    uint8_t  kind;         // ET_PIPE_NODE_NATIVE / ET_PIPE_NODE_EXTERNAL
    uint8_t  externalIndex;
} ETPipeNode;

/// engine を渡す。組めている状態を 0 に戻すので、et_engine_prepare のたびに呼ぶ。
/// Engine::prepare は invalidatePipeline() で pipeline_configured_ を落とす
/// （engine.cpp:219-222, 119-129）ので、こちら側も合わせないと嘘の ET_OK が残る。
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
///
/// 戻り値は et_status。ET_OK(0) なら 1 ブロック通した。
/// 以前はノード数を返していたが、上流の et_pipeline_process は件数を返さないので
/// 自前で数えた値を混ぜていた。その結果「素通し」「まだ組めていない」「引数が悪い」
/// 「処理は成功したがノードが 0 本」が全部 0 に潰れて区別できなかった。
/// 通ったノード数は ETPipeline_ActiveNodes() で別に読む。
int32_t ETPipeline_Process(uint32_t channels, uint32_t frames, double timeSeconds);

/// 直近の et_pipeline_configure が返した値。
/// 一度も configure していない間は ET_ERR_STATE。ET_OK(0) と紛れないようにしてある。
/// process 側のエラーはここに入れない（ETPipeline_Process の戻り値で読む）。
int32_t ETPipeline_LastStatus(void);

/// ETPipeline_Process が呼ばれた回数。
/// instance を壊す前に、この値が 2 つ進むのを待てば読み終えたと分かる。
uint64_t ETPipeline_ProcessCount(void);

/// instance を壊す。**音のスレッドが engine の外に居るあいだに壊す。**
///
/// et_instance_destroy は壊した instance だけでなく、invalidatePipeline() で
/// pipeline_ と遅延補正の線まで作り直す（engine.cpp:395-401, 119-129）。
/// ProcessCount を 2 つ待っても守れるのは壊す instance だけで、
/// 音のスレッドが processPipeline の途中ならその線や kernel を解放後に読む。
/// ここは音のスレッドを入口で止め、中に居るのが抜けるのを待ってから壊す。
/// 止めている間の Process / ApplyPending は何もせず戻る（そのブロックは素通し）。
///
/// UI スレッドから呼ぶ。待つのはいま走っているブロックが終わるまでで、**50 ms まで。**
/// JSFX の 1 ブロックには上限が無いので、抜けてこなければ何も壊さずに 0 を返す。
/// そのときは間を置いて呼び直す。壊したら 1。
/// **音のスレッドから呼ばない**（自分を待って戻らない）。
int ETPipeline_DestroyInstances(uint32_t engine, const uint32_t *instances, uint32_t count);

/// et_pipeline_configure を呼んだ回数。成功・失敗の両方を数える。
/// 0 なら Publish が音のスレッドに一度も拾われていない。
uint64_t ETPipeline_ConfigureCount(void);

/// いま組まれている鎖のうち、実際に処理されるノード数。
/// enabled かつ sectionGate のものだけ数えている（engine.cpp:916-919 と同じ条件）。
uint32_t ETPipeline_ActiveNodes(void);

/// **鎖そのものが足す遅れ（標本）。**
/// et_pipeline_latency（abi.h:168）の値で、FIR を持つエフェクトを入れると増える。
/// リンクやブロックの遅れは含まない。あちらは AudioIO が持っている。
/// 上流 EffeTune が右下に出している "Total Delay: N samples" と同じ量。
/// 溜まっている鎖の差し替えを反映する。**音のスレッドから、毎ブロック呼ぶ。**
///
/// ETPipeline_Process も先頭でこれを呼ぶが、Process 自体が
/// 「音が来ているとき」しか呼ばれないので、それだけだと無音の間の
/// 変更が反映されない。休んでいる間もこちらは呼ぶこと。
void ETPipeline_ApplyPending(void);

uint32_t ETPipeline_Latency(void);

/// 素通しにしてあるか。
int ETPipeline_IsBypassed(void);

/// いま鎖が組めているか。直近の configure が ET_OK だったかどうか。
/// engine を差し替えると 0 に戻る。
int ETPipeline_HasConfigured(void);

/// Attach one external processor to the pipeline's final planar bus.
/// The descriptor is borrowed and must remain valid until replaced or cleared.
/// This first ABI stage is deliberately post-pipeline; arbitrary insertion
/// points require native engine support and will be added separately.
void ETPipeline_SetExternalProcessor(const ETExternalProcessor *processor);

/// Publish an ordered external-processor segment. The array is copied in the
/// control plane and executed in this order on every successful native block.
void ETPipeline_SetExternalProcessors(const ETExternalProcessor *processors,
                                       uint32_t count);

/// Replace one slot in the ordered external registry. Slots are stable, so a
/// pipeline node can keep its externalIndex while another AU is added.
void ETPipeline_SetExternalProcessorAt(uint32_t index,
                                        const ETExternalProcessor *processor);
void ETPipeline_ClearExternalProcessorAt(uint32_t index);

/// Clear the external processor. Safe to call from the control thread; the
/// render thread observes the change at the next block boundary.
void ETPipeline_ClearExternalProcessor(void);

void ETPipeline_SetExternalSampleRate(double sampleRate);

uint32_t ETPipeline_ExternalLatency(void);
double ETPipeline_ExternalTailTime(void);
uint64_t ETPipeline_ExternalProcessCount(uint32_t index);
int32_t ETPipeline_ExternalLastStatus(uint32_t index);

#ifdef __cplusplus
}
#endif

#endif /* ETPipeline_h */
