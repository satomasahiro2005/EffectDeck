//  ETResample.h
//  DSP を入力より高いレートで回すための、整数倍のリサンプラ。
//
//  EffeTune が「内部のサンプルレートを上げると非線形エフェクトの折り返しが減る」
//  という形で質を上げているのと同じことを、iOS でやるために要る。
//  web 版は AudioContext 自体を 96kHz で開けば済むが、こちらは
//  拡張から来る音が 48kHz 固定なので、両端で自分で変換する。
//
//  入力が 48kHz 固定なので、比は整数（2倍・4倍）だけでよい。
//  44.1kHz 系を混ぜると有理数比の変換になって、得るものが無い割に重くなる。
//
//  作りは多相 FIR。窓関数つき sinc を factor 個の位相に分けて持ち、
//  1 入力から factor 個の出力を作る（逆はその転置）。
//  確保は Create のときだけ。処理中は確保も待ちもしない。

#ifndef ETResample_h
#define ETResample_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ETResampler ETResampler;

/// factor は 1 / 2 / 4。1 のときは何もしない器として作られる。
/// maxFrames は 1 回に渡す入力フレーム数の上限（アップ側）。
ETResampler *ETResampler_Create(uint32_t factor, uint32_t channels, uint32_t maxFrames);
void ETResampler_Destroy(ETResampler *r);

uint32_t ETResampler_Factor(const ETResampler *r);
/// 変換で増える遅延（入力レートでのサンプル数）。
uint32_t ETResampler_LatencySamples(const ETResampler *r);

void ETResampler_Reset(ETResampler *r);

/// 上げる。in はプレーナで frames×channels、out は frames*factor×channels。
void ETResampler_Up(ETResampler *r, const float *in, float *out, uint32_t frames);

/// 下げる。in はプレーナで outFrames*factor×channels、out は outFrames×channels。
void ETResampler_Down(ETResampler *r, const float *in, float *out, uint32_t outFrames);

#ifdef __cplusplus
}
#endif

#endif /* ETResample_h */
