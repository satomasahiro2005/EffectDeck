//  ETChain.h
//  エフェクトの鎖を、音のスレッドを止めずに差し替えるための置き場。
//
//  EffeTune の DSP は et_instance_process を 1 個ずつ呼べば鎖になる。
//  面倒なのは「UI がエフェクトを足したり外したりする間、音のスレッドが
//  古い配列を読んでいる」ところだけなので、そこだけ C で持つ。
//
//  作りは Swift 側が担当する:
//    - et_instance_create / destroy / set_params は UI スレッド
//    - ここへ渡すのは出来上がった instance の並びだけ
//
//  音のバッファはプレーナ（ch0 のフレームが frames 個、その後 ch1 …）。
//  EffeTune のカーネルが offset = channel * frame_count で読むため。

#ifndef ETChain_h
#define ETChain_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ET_CHAIN_MAX 64

/// どの engine に属する instance かを教える。
void ETChain_SetEngine(uint32_t engine);

/// 鎖を差し替える。UI スレッドから呼ぶ。count は ET_CHAIN_MAX まで。
void ETChain_Publish(const uint32_t *instances, uint32_t count);

/// 鎖全体を素通しにする。
void ETChain_SetBypass(int bypass);

/// 鎖を通す。リアルタイムスレッドから呼ぶ。確保も待ちもしない。
/// 戻り値は実際に通したエフェクトの数。
uint32_t ETChain_Process(float *planar, uint32_t channels, uint32_t frames, double timeSeconds);

/// ETChain_Process が呼ばれた回数。
/// instance を壊す前に、この値が 2 つ進むのを待てば、
/// 音のスレッドがその instance を読み終えたと分かる。
uint64_t ETChain_ProcessCount(void);

#ifdef __cplusplus
}
#endif

#endif /* ETChain_h */
