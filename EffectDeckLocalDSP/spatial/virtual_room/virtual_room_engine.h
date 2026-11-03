// Virtual Room の実 DSP。docs/virtual-room-design.md の §14、§25-§35。
//
// realtime と BRIR export（§44）で同じものを使う。export 側は publish を使わず
// applyImmediate でその場で差し替え、process を回してインパルス応答を取る。
// **別の残響アルゴリズムを export 用に書いてはいけない。**
//
// 音のスレッドで確保・lock・例外を使わない（§28、§33）。確保は prepare だけ。

#ifndef EFFETUNE_PLUGINS_SPATIAL_VIRTUAL_ROOM_ENGINE_H
#define EFFETUNE_PLUGINS_SPATIAL_VIRTUAL_ROOM_ENGINE_H

#include "virtual_room_model.h"

#include "core/nothrow_storage.h"

#include <atomic>
#include <cstdint>

namespace effetune::plugins::spatial {

// block ごとに作り直さない形にした path。delay も係数も RenderState だけで決まるので、
// 差し替えたときに 1 回組めばよい。あとは読み出しの原点が 1 サンプルずつ進むだけ。
struct PreparedPath {
  std::uint32_t offset;  // 原点からの整数サンプル
  float coefficient[4];  // 4 点 Lagrange
  float band[kBandCount];
};

class VirtualRoomEngine {
public:
  VirtualRoomEngine() noexcept = default;
  VirtualRoomEngine(const VirtualRoomEngine &) = delete;
  VirtualRoomEngine &operator=(const VirtualRoomEngine &) = delete;

  // 確保はここだけ（§33）。失敗したら false を返し、以後 process は何もしない。
  bool prepare(double sampleRate, std::uint32_t maxFrames) noexcept;
  [[nodiscard]] bool prepared() const noexcept { return prepared_; }
  void reset() noexcept;

  // 制御スレッド。幾何も材質も FDN の係数もここで計算して公開する（§26、§28）。
  void publish(const Params &params) noexcept;

  // offline（BRIR export）。移行を挟まずその場で差し替える。
  // buildRenderState をして applyState へ渡すのと同じ。
  void applyImmediate(const Params &params) noexcept;

  // 組み上がった面をその場で差し替える。移行は挟まず、輪と遅延線も空にする。
  // **測るための口。**経路の帯域ゲインや late の入力を 0 にした面を渡せば、
  // direct だけ・early だけ・late だけの BRIR を同じエンジンで取り出せる
  // （Tools/brir_metrics.cpp、Tests/Native/virtual_room.cpp）。
  void applyState(const RenderState &state) noexcept;
  // いま鳴っている面。道具と試験が applyImmediate で組んだ面を読み、部分を 0 にして戻す。
  [[nodiscard]] const RenderState &activeState() const noexcept { return *active_; }

  // 音のスレッド。planar。入力を置き換える。
  // channels の頭から面の sourceCount 本を音源として読み（足りない分は無音）、
  // 両耳を 0 番と 1 番へ書き、**2 番から先は 0 にする**（5.1 を 2ch のヘッドホンへ畳む）。
  void process(float *const *channels, std::uint32_t channelCount,
               std::uint32_t frames) noexcept;
  // Stereo の口（道具と試験）。上と同じものを 2 本で呼ぶ。
  void process(float *left, float *right, std::uint32_t frames) noexcept;

  // §45 で export の長さを決めるのに使う。
  [[nodiscard]] double tailSeconds() const noexcept;
  [[nodiscard]] double mixingTimeSeconds() const noexcept;

private:
  static constexpr std::uint32_t kNoSlot = 0xFFFFFFFFu;
  static constexpr std::uint32_t kPoolSize = 3u;  // §28
  enum class SeedPhase : std::uint8_t { Idle, FadeOut, FadeIn };

  void prepareState(const RenderState &state, PreparedPath *out) const noexcept;
  void adoptPublished() noexcept;
  void takeActiveNow() noexcept;
  void takeLateStructure(const RenderState &state) noexcept;
  void takePendingLate() noexcept;
  void clearBuffers() noexcept;
  [[nodiscard]] const RenderState &newestState() const noexcept;
  void renderBlock(float *const *channels, std::uint32_t channelCount,
                   std::uint32_t frames) noexcept;
  void accumulatePaths(const RenderState &state, const PreparedPath *prepared,
                       const float *history, float *ear) const noexcept;
  void advanceSeedFade() noexcept;
  float advanceLate(std::uint32_t ear, const float *history, float *lines) noexcept;
  void stepFdn(const float *history, float *lines) noexcept;

  // ---- 確保するもの
  effetune::NothrowStorage<float> history_;  // [source][band][ring]
  effetune::NothrowStorage<float> lines_;    // [line][fdn]
  effetune::NothrowStorage<PreparedPath> preparedStorage_;  // 2 面

  double sampleRate_ = 48000.0;
  double internalRate_ = 48000.0;
  std::uint32_t maxFrames_ = 0u;
  std::uint32_t divider_ = 1u;
  std::uint32_t ringSize_ = 0u;
  std::uint32_t ringMask_ = 0u;
  float maxDelay_ = 0.0F;
  std::uint32_t fdnSize_ = 0u;
  std::uint32_t fdnMask_ = 0u;
  bool prepared_ = false;
  /// active_ に本物の面が入っているか。prepare で落とし、applyState と最初の
  /// adoptPublished で立てる。**落ちている間に来た面は渡りを挟まずに取る**（D）。
  /// ゼロの面から渡ると、耳介のゲインも出力ゲインも 0 から始まって頭が欠ける。
  bool hasState_ = false;

  // ---- 制御 → 音（§28）
  RenderState pool_[kPoolSize]{};
  std::atomic<std::uint32_t> ready_{kNoSlot};
  /// 音のスレッドが読み終えた面の bit 集合。slot ごとに 1 bit。
  /// 1 つしか持てない形にすると、publish が回収する前に 2 面消費されたときに
  /// 面が漏れて、3 面とも塞がったまま更新が止まる。
  std::atomic<std::uint32_t> released_{0u};
  std::uint32_t free_[kPoolSize]{};
  std::uint32_t freeCount_ = 0u;

  // ---- 音のスレッドが持つもの
  RenderState stateA_{};
  RenderState stateB_{};
  RenderState *active_ = &stateA_;
  RenderState *incoming_ = &stateB_;
  PreparedPath *preparedActive_ = nullptr;
  PreparedPath *preparedIncoming_ = nullptr;

  std::uint32_t transitionFrames_ = 1u;
  std::uint32_t transitionRemaining_ = 0u;
  double fadeCos_ = 0.0;
  double fadeSin_ = 1.0;
  double fadeStepCos_ = 1.0;
  double fadeStepSin_ = 0.0;

  std::uint32_t origin_ = 0u;
  /// 耳介の FIR を入れる前の生の入力。全経路へ同じものが掛かるので入口で 1 度だけ。
  /// **6 本とも毎サンプル回す。**Stereo の間も 3 本目から先へ 0 を書き続けるので、
  /// 5.1 へ渡るときに何分も前の 5.1 の音が輪から読まれない。
  float pinnaHistory_[kMaxSources][256]{};
  std::uint32_t pinnaWrite_ = 0u;
  float splitLow_[kMaxSources]{};
  float splitHigh_[kMaxSources]{};
  float bandCoefficientLow_ = 0.0F;
  float bandCoefficientHigh_ = 0.0F;

  // ---- late
  std::uint32_t fdnWrite_ = 0u;
  std::uint32_t fdnPhase_ = 0u;
  float fdnLow_[kFdnLines]{};
  float fdnMid_[kFdnLines]{};
  float fdnCoefficientLow_ = 0.0F;
  float fdnCoefficientHigh_ = 0.0F;
  std::uint32_t fdnDelayCurrent_[kFdnLines]{};
  std::uint32_t fdnDelayTarget_[kFdnLines]{};
  float fdnBandCurrent_[kFdnLines][kBandCount]{};
  float fdnInputCurrent_[kFdnLines][kMaxSources]{};
  /// late へ入れる音源の数（いま取り込んでいる面の sourceCount）。
  std::uint32_t lateSources_ = kStereoSources;
  float fdnOutput_[kEarCount][kFdnLines]{};
  float lateSmoothing_ = 0.0F;
  float lateHold_[kEarCount]{};
  /// divider で間引いた late を出力レートへ戻すときの均し（§25）。
  float coherence_[kEarCount]{};
  /// 待たせている late の係数。takeLateStructure が毎回ここへ書き、畳んでいなければ
  /// その場で、畳んでいれば遅延線を空にする点で鳴らす方へ移す（§32）。
  float fdnBandPending_[kFdnLines][kBandCount]{};
  float fdnInputPending_[kFdnLines][kMaxSources]{};
  float fdnOutputPending_[kEarCount][kFdnLines]{};
  std::uint32_t lateSourcesPending_ = kStereoSources;
  /// 畳んだ先の seed。
  std::uint32_t fdnSeed_ = 0u;
  /// 遅延線の中身が属している seed（fdnDelayCurrent_ と対）。
  std::uint32_t fdnSeedCurrent_ = 0u;
  SeedPhase seedPhase_ = SeedPhase::Idle;
  std::uint32_t seedFadeFrames_ = 1u;
  float lateScalar_ = 1.0F;

  float outputGainCurrent_ = 1.0F;
};

}  // namespace effetune::plugins::spatial

#endif
