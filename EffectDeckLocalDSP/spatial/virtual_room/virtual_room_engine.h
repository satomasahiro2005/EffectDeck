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
  std::uint32_t pinnaOffset[kPinnaTaps];
  float pinnaCoefficient[kPinnaTaps][4];
  float pinnaGain[kPinnaTaps];
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
  void applyImmediate(const Params &params) noexcept;

  // 音のスレッド。planar な 2ch。入力を置き換える。
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
  void takeLateStructure(const RenderState &state) noexcept;
  void clearBuffers() noexcept;
  [[nodiscard]] const RenderState &newestState() const noexcept;
  void renderBlock(float *left, float *right, std::uint32_t frames) noexcept;
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
  float splitLow_[kSourceCount]{};
  float splitHigh_[kSourceCount]{};
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
  float fdnInputCurrent_[kFdnLines][kSourceCount]{};
  float fdnOutput_[kEarCount][kFdnLines]{};
  float lateSmoothing_ = 0.0F;
  float lateHold_[kEarCount]{};
  /// divider で間引いた late を出力レートへ戻すときの均し（§25）。
  float coherence_[kEarCount]{};
  std::uint32_t fdnSeed_ = 0u;
  SeedPhase seedPhase_ = SeedPhase::Idle;
  std::uint32_t seedFadeFrames_ = 1u;
  float lateScalar_ = 1.0F;

  float outputGainCurrent_ = 1.0F;
};

}  // namespace effetune::plugins::spatial

#endif
