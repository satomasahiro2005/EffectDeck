// Virtual Room の実 DSP 本体。docs/virtual-room-design.md の §14、§25-§35。
//
// 全部 EffectDeck の新規実装（§60.5）。元 JS からコードを写していないので
// §60.4 の由来ヘッダは付けない。数式の出どころは VirtualRoomModel.h の頭。
//
// 音のスレッドでやらないこと: 確保・lock・例外・三角関数・pow。
// 幾何と材質から係数を作るのは全部 VirtualRoomModel.h で、制御スレッドが呼ぶ。

#include "virtual_room_engine.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace effetune::plugins::spatial {
namespace {

std::uint32_t nextPowerOfTwo(std::uint32_t value) noexcept {
  std::uint32_t size = 1u;
  while (size < value) {
    size <<= 1u;
  }
  return size;
}

// 4 点 Lagrange（Laakso et al. 1996）。遅れ d を整数 i と小数 f に割り、
// 遅れ i-1, i, i+1, i+2 の 4 本へ重みを配る。
// **d は必ず 1 以上**。最短の path でも 0.12 m ＝ 16 サンプル以上あるので成り立つ。
void lagrange(double delay, std::uint32_t maxDelay, std::uint32_t &offset,
              float *coefficient) noexcept {
  double clamped = delay;
  if (!(clamped == clamped) || clamped < 1.0) {
    clamped = 1.0;
  }
  const double ceiling = static_cast<double>(maxDelay) - 2.0;
  if (clamped > ceiling) {
    clamped = ceiling;
  }
  const double floored = std::floor(clamped);
  const double f = clamped - floored;
  const auto integer = static_cast<std::uint32_t>(floored);
  offset = integer - 1u;
  coefficient[0] = static_cast<float>(-f * (f - 1.0) * (f - 2.0) / 6.0);
  coefficient[1] = static_cast<float>((f + 1.0) * (f - 1.0) * (f - 2.0) / 2.0);
  coefficient[2] = static_cast<float>(-(f + 1.0) * f * (f - 2.0) / 2.0);
  coefficient[3] = static_cast<float>((f + 1.0) * f * (f - 1.0) / 6.0);
}

// 1 次ローパスの係数。cutoff が Nyquist を超えたら素通し。
float onePole(double cutoff, double rate) noexcept {
  if (cutoff <= 0.0 || rate <= 0.0) {
    return 0.0F;
  }
  const double limit = rate * 0.49;
  const double used = cutoff > limit ? limit : cutoff;
  return static_cast<float>(1.0 - std::exp(-2.0 * kPi * used / rate));
}

// 16 点の高速 Walsh-Hadamard。直交行列なので 1/sqrt(16) = 0.25 を掛けて戻す。
// 乱数の行列より安く、相関も残らない（§22）。
void hadamard16(float *value) noexcept {
  for (std::uint32_t span = 1u; span < kFdnLines; span <<= 1u) {
    for (std::uint32_t base = 0u; base < kFdnLines; base += span << 1u) {
      for (std::uint32_t index = base; index < base + span; ++index) {
        const float a = value[index];
        const float b = value[index + span];
        value[index] = a + b;
        value[index + span] = a - b;
      }
    }
  }
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    value[line] *= 0.25F;
  }
}

}  // namespace

// ---------------------------------------------------------------- 確保

bool VirtualRoomEngine::prepare(double sampleRate, std::uint32_t maxFrames) noexcept {
  prepared_ = false;
  sampleRate_ = sampleRate > 0.0 ? sampleRate : 48000.0;
  maxFrames_ = maxFrames == 0u ? 1u : maxFrames;
  divider_ = lateRateDivider(sampleRate_);
  internalRate_ = sampleRate_ / static_cast<double>(divider_);

  // いちばん遠い像までの距離。20 x 30 x 10 m の部屋で 2 次までなら 113 m ほど。
  // そこへ mixing time（最大 0.1 秒）と block 1 つぶんを足して丸める。
  const double longest = 120.0 / kSpeedOfSound + 0.12;
  const auto needed = static_cast<std::uint32_t>(longest * sampleRate_) + maxFrames_ + 8u;
  ringSize_ = nextPowerOfTwo(needed);
  ringMask_ = ringSize_ - 1u;
  maxDelay_ = static_cast<float>(ringSize_ - 4u);

  const auto fdnNeeded = static_cast<std::uint32_t>(0.13 * internalRate_) + 8u;
  fdnSize_ = nextPowerOfTwo(fdnNeeded);
  fdnMask_ = fdnSize_ - 1u;

  if (!history_.allocate(static_cast<std::size_t>(kSourceCount) * kBandCount * ringSize_)) {
    return false;
  }
  if (!lines_.allocate(static_cast<std::size_t>(kFdnLines) * fdnSize_)) {
    return false;
  }
  if (!preparedStorage_.allocate(static_cast<std::size_t>(kMaxPaths) * 2u)) {
    return false;
  }
  preparedActive_ = preparedStorage_.data();
  preparedIncoming_ = preparedStorage_.data() + kMaxPaths;

  bandCoefficientLow_ = onePole(kBandSplitLow, sampleRate_);
  bandCoefficientHigh_ = onePole(kBandSplitHigh, sampleRate_);
  fdnCoefficientLow_ = onePole(kBandSplitLow, internalRate_);
  fdnCoefficientHigh_ = onePole(kBandSplitHigh, internalRate_);
  // 遅れの束を差し替えるときの渡り。**block より短くしない**（block 内で
  // 終わらないと、次の block の頭で段差が出る）。8 ms あれば耳に付かない。
  transitionFrames_ = std::max<std::uint32_t>(
      maxFrames_, static_cast<std::uint32_t>(0.008 * sampleRate_));
  // seed と部屋の寸法を変えたときに late を畳んで開き直す時間（§30、§32）。
  seedFadeFrames_ = std::max<std::uint32_t>(1u, static_cast<std::uint32_t>(0.030 * sampleRate_));
  // divider で間引いた late を出力レートへ戻すときの均し。
  lateSmoothing_ = onePole(4000.0, sampleRate_);

  freeCount_ = 0u;
  for (std::uint32_t slot = 0u; slot < kPoolSize; ++slot) {
    free_[freeCount_++] = slot;
  }
  ready_.store(kNoSlot, std::memory_order_relaxed);
  released_.store(0u, std::memory_order_relaxed);

  prepared_ = true;
  reset();
  return true;
}

void VirtualRoomEngine::clearBuffers() noexcept {
  history_.clear();
  lines_.clear();
  origin_ = 0u;
  fdnWrite_ = 0u;
  fdnPhase_ = 0u;
  pinnaWrite_ = 0u;
  for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
    splitLow_[source] = 0.0F;
    splitHigh_[source] = 0.0F;
    for (std::uint32_t index = 0u; index < 256u; ++index) {
      pinnaHistory_[source][index] = 0.0F;
    }
  }
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    fdnLow_[line] = 0.0F;
    fdnMid_[line] = 0.0F;
  }
  for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
    lateHold_[ear] = 0.0F;
    coherence_[ear] = 0.0F;
  }
}

void VirtualRoomEngine::reset() noexcept {
  if (!prepared_) {
    return;
  }
  clearBuffers();
  transitionRemaining_ = 0u;
  seedPhase_ = SeedPhase::Idle;
  lateScalar_ = 1.0F;
  outputGainCurrent_ = active_->outputGain > 0.0F ? active_->outputGain : 1.0F;
}

// ---------------------------------------------------------------- 制御側

void VirtualRoomEngine::publish(const Params &params) noexcept {
  if (!prepared_) {
    return;
  }
  // 音のスレッドが読み終えた面を回収する。released_ は slot の bit 集合。
  const std::uint32_t done = released_.exchange(0u, std::memory_order_acquire);
  for (std::uint32_t slot = 0u; slot < kPoolSize; ++slot) {
    if ((done & (1u << slot)) != 0u && freeCount_ < kPoolSize) {
      free_[freeCount_++] = slot;
    }
  }
  if (freeCount_ == 0u) {
    // まだ読まれていない面があれば、それを取り返して書き直す。
    // **溜めない。**溜めると指を離したあとに古い部屋が順に鳴る。
    const std::uint32_t pending = ready_.exchange(kNoSlot, std::memory_order_acq_rel);
    if (pending == kNoSlot) {
      return;
    }
    free_[freeCount_++] = pending;
  }
  const std::uint32_t slot = free_[--freeCount_];
  buildRenderState(params, sampleRate_, pool_[slot]);
  const std::uint32_t previous = ready_.exchange(slot, std::memory_order_release);
  if (previous != kNoSlot && freeCount_ < kPoolSize) {
    free_[freeCount_++] = previous;
  }
}

void VirtualRoomEngine::applyImmediate(const Params &params) noexcept {
  if (!prepared_) {
    return;
  }
  buildRenderState(params, sampleRate_, *active_);
  prepareState(*active_, preparedActive_);
  transitionRemaining_ = 0u;
  seedPhase_ = SeedPhase::Idle;
  lateScalar_ = 1.0F;
  fdnSeed_ = active_->seed;
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    fdnDelayCurrent_[line] = active_->fdnDelay[line];
    fdnDelayTarget_[line] = active_->fdnDelay[line];
    for (std::uint32_t band = 0u; band < kBandCount; ++band) {
      fdnBandCurrent_[line][band] = active_->fdnBand[line][band];
    }
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      fdnInputCurrent_[line][source] = active_->fdnInput[line][source];
    }
  }
  for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
    for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
      fdnOutput_[ear][line] = active_->fdnOutput[ear][line];
    }
  }
  outputGainCurrent_ = active_->outputGain;
  clearBuffers();
}

// ---------------------------------------------------------------- 準備

void VirtualRoomEngine::prepareState(const RenderState &state, PreparedPath *out) const noexcept {
  const auto limit = static_cast<std::uint32_t>(maxDelay_);
  for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      for (std::uint32_t image = 0u; image < kMaxImages; ++image) {
        const std::uint32_t index = pathIndex(ear, source, image);
        const PathState &path = state.path[index];
        PreparedPath &prepared = out[index];
        if (image >= state.imagesPerSource) {
          prepared = PreparedPath{};
          prepared.offset = 1u;
          continue;
        }
        lagrange(static_cast<double>(path.delay), limit, prepared.offset, prepared.coefficient);
        for (std::uint32_t band = 0u; band < kBandCount; ++band) {
          prepared.band[band] = path.band[band];
        }
      }
    }
  }
}

// late の構造を取り込む。
//
// **遅れが変わるときは畳んでから開く**（§30）。遅延線の長さを鳴らしたまま
// 変えると読み出しが飛んで必ず鳴る。seed を変えたときも同じ（§32）。
// 帰還ゲインと入出力の係数だけの変化（材質・Decay・Room Amount）は
// そのまま差し替えてよい（§31）。
void VirtualRoomEngine::takeLateStructure(const RenderState &state) noexcept {
  bool restructure = state.seed != fdnSeed_;
  for (std::uint32_t line = 0u; line < kFdnLines && !restructure; ++line) {
    restructure = state.fdnDelay[line] != fdnDelayCurrent_[line];
  }

  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    for (std::uint32_t band = 0u; band < kBandCount; ++band) {
      fdnBandCurrent_[line][band] = state.fdnBand[line][band];
    }
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      fdnInputCurrent_[line][source] = state.fdnInput[line][source];
    }
  }
  for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
    for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
      fdnOutput_[ear][line] = state.fdnOutput[ear][line];
    }
  }

  if (!restructure) {
    return;
  }
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    fdnDelayTarget_[line] = state.fdnDelay[line];
  }
  fdnSeed_ = state.seed;
  // 既に畳んでいる最中なら、行き先だけ差し替えて畳み直さない。
  if (seedPhase_ != SeedPhase::FadeOut) {
    seedPhase_ = SeedPhase::FadeOut;
  }
}

void VirtualRoomEngine::adoptPublished() noexcept {
  const std::uint32_t slot = ready_.exchange(kNoSlot, std::memory_order_acquire);
  if (slot == kNoSlot) {
    return;
  }
  *incoming_ = pool_[slot];
  released_.fetch_or(1u << slot, std::memory_order_release);

  prepareState(*incoming_, preparedIncoming_);
  takeLateStructure(*incoming_);

  transitionRemaining_ = transitionFrames_;
  fadeCos_ = 1.0;
  fadeSin_ = 0.0;
  const double step = kPi * 0.5 / static_cast<double>(transitionFrames_);
  fadeStepCos_ = std::cos(step);
  fadeStepSin_ = std::sin(step);
}

const RenderState &VirtualRoomEngine::newestState() const noexcept {
  return transitionRemaining_ != 0u ? *incoming_ : *active_;
}

double VirtualRoomEngine::tailSeconds() const noexcept {
  const RenderState &state = newestState();
  double longest = 0.0;
  for (std::uint32_t band = 0u; band < kBandCount; ++band) {
    longest = std::max(longest, static_cast<double>(state.rt60[band]));
  }
  // §45。-80 dB まで落ちるのは RT60 の 80/60 倍。
  return static_cast<double>(state.mixingTime) + longest * (80.0 / 60.0) + 0.05;
}

double VirtualRoomEngine::mixingTimeSeconds() const noexcept {
  return static_cast<double>(newestState().mixingTime);
}

// ---------------------------------------------------------------- 音

void VirtualRoomEngine::process(float *left, float *right, std::uint32_t frames) noexcept {
  if (!prepared_ || left == nullptr || right == nullptr) {
    return;
  }
  // 新しい面はブロックの頭でだけ取り込む。渡りの途中では取らない。
  if (transitionRemaining_ == 0u) {
    adoptPublished();
  }
  renderBlock(left, right, frames);
}

void VirtualRoomEngine::renderBlock(float *left, float *right, std::uint32_t frames) noexcept {
  float *const history = history_.data();
  float *const lines = lines_.data();

  for (std::uint32_t frame = 0u; frame < frames; ++frame) {
    const float raw[kSourceCount] = {left[frame], right[frame]};

    // ---- 耳介（§17）。**全部の経路へ同じものが掛かる**ので入口で 1 度だけ。
    // 元の JS も 1 本の FIR を全部の到来へ畳んでいる。経路ごとに持たせると
    // 100 本ぶん走らせることになるうえ、像ごとに違う耳介になってしまう。
    const RenderState &pinna = *active_;
    pinnaWrite_ = (pinnaWrite_ + 1u) & 255u;
    float input[kSourceCount];
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      pinnaHistory_[source][pinnaWrite_] = raw[source];
      float value = 0.0F;
      for (std::uint32_t tap = 0u; tap <= kPinnaTaps; ++tap) {
        const std::uint32_t position = (pinnaWrite_ - pinna.pinnaDelay[tap]) & 255u;
        value += pinnaHistory_[source][position] * pinna.pinnaGain[tap];
      }
      input[source] = value;
    }

    // ---- 3 帯域へ割って輪へ書く。足すと入力へ完全に戻る形（§19）。
    origin_ = (origin_ + 1u) & ringMask_;
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      splitLow_[source] += bandCoefficientLow_ * (input[source] - splitLow_[source]);
      splitHigh_[source] += bandCoefficientHigh_ * (input[source] - splitHigh_[source]);
      const float low = splitLow_[source];
      const float mid = splitHigh_[source] - splitLow_[source];
      const float high = input[source] - splitHigh_[source];
      const std::uint32_t base = source * kBandCount * ringSize_;
      history[base + origin_] = low;
      history[base + ringSize_ + origin_] = mid;
      history[base + 2u * ringSize_ + origin_] = high;
    }

    // ---- direct + early
    float earA[kEarCount] = {0.0F, 0.0F};
    float earB[kEarCount] = {0.0F, 0.0F};
    accumulatePaths(*active_, preparedActive_, history, earA);
    if (transitionRemaining_ != 0u) {
      accumulatePaths(*incoming_, preparedIncoming_, history, earB);
    }

    float early[kEarCount];
    float gain = outputGainCurrent_;
    if (transitionRemaining_ != 0u) {
      // 等電力。cos^2 + sin^2 = 1 なので、無相関でない 2 面を混ぜても山谷が出ない。
      const auto fadeOut = static_cast<float>(fadeCos_ * fadeCos_);
      const auto fadeIn = static_cast<float>(fadeSin_ * fadeSin_);
      for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
        early[ear] = earA[ear] * fadeOut + earB[ear] * fadeIn;
      }
      gain = active_->outputGain * fadeOut + incoming_->outputGain * fadeIn;
      const double nextCos = fadeCos_ * fadeStepCos_ - fadeSin_ * fadeStepSin_;
      const double nextSin = fadeSin_ * fadeStepCos_ + fadeCos_ * fadeStepSin_;
      fadeCos_ = nextCos;
      fadeSin_ = nextSin;
      if (--transitionRemaining_ == 0u) {
        std::swap(active_, incoming_);
        std::swap(preparedActive_, preparedIncoming_);
        gain = active_->outputGain;
      }
    } else {
      for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
        early[ear] = earA[ear];
      }
      gain = active_->outputGain;
    }
    outputGainCurrent_ = gain;

    // ---- late
    advanceSeedFade();
    const float late[kEarCount] = {advanceLate(0u, history, lines),
                                   advanceLate(1u, history, lines)};

    left[frame] = (early[0] + late[0]) * gain;
    right[frame] = (early[1] + late[1]) * gain;
  }
}

// 1 サンプルぶんの direct + early。**path ごとのフィルタ状態は持たない**ので、
// 面を差し替えても古い状態が混ざらない（§29）。
void VirtualRoomEngine::accumulatePaths(const RenderState &state, const PreparedPath *prepared,
                                        const float *history, float *ear) const noexcept {
  const std::uint32_t images = state.imagesPerSource;
  for (std::uint32_t earIndex = 0u; earIndex < kEarCount; ++earIndex) {
    float sum = 0.0F;
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      const std::uint32_t base = source * kBandCount * ringSize_;
      for (std::uint32_t image = 0u; image < images; ++image) {
        const PreparedPath &path = prepared[pathIndex(earIndex, source, image)];
        float band[kBandCount] = {0.0F, 0.0F, 0.0F};
        for (std::uint32_t tap = 0u; tap < 4u; ++tap) {
          const std::uint32_t position = (origin_ - (path.offset + tap)) & ringMask_;
          const float weight = path.coefficient[tap];
          band[0] += history[base + position] * weight;
          band[1] += history[base + ringSize_ + position] * weight;
          band[2] += history[base + 2u * ringSize_ + position] * weight;
        }
        sum += band[0] * path.band[0] + band[1] * path.band[1] + band[2] * path.band[2];
      }
    }
    ear[earIndex] += sum;
  }
}

// §30、§32。遅れを差し替える前に late を畳み、差し替えてから開く。
void VirtualRoomEngine::advanceSeedFade() noexcept {
  if (seedPhase_ == SeedPhase::Idle) {
    return;
  }
  const float step = 1.0F / static_cast<float>(seedFadeFrames_);
  if (seedPhase_ == SeedPhase::FadeOut) {
    lateScalar_ -= step;
    if (lateScalar_ <= 0.0F) {
      lateScalar_ = 0.0F;
      // 畳み切った所で入れ替える。遅延線を捨てるので読み出しが飛んでも鳴らない。
      for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
        fdnDelayCurrent_[line] = fdnDelayTarget_[line];
        fdnLow_[line] = 0.0F;
        fdnMid_[line] = 0.0F;
      }
      std::memset(lines_.data(), 0, lines_.size() * sizeof(float));
      seedPhase_ = SeedPhase::FadeIn;
      }
    return;
  }
  lateScalar_ += step;
  if (lateScalar_ >= 1.0F) {
    lateScalar_ = 1.0F;
    seedPhase_ = SeedPhase::Idle;
  }
}

// 内部レートで回す FDN（§20-§24）。divider が 1 でなければ間引いて回し、
// 出力レートへは均して戻す（§25）。
float VirtualRoomEngine::advanceLate(std::uint32_t ear, const float *history,
                                     float *lines) noexcept {
  if (ear == 0u) {
    if (fdnPhase_ == 0u) {
      stepFdn(history, lines);
    }
    if (++fdnPhase_ >= divider_) {
      fdnPhase_ = 0u;
    }
  }
  // **間引いたときだけ均す。**divider が 1 なら FDN は全速で回っているので、
  // ここで 1 次を掛けると残響の高域を削るだけになる（前はいつも掛けていた）。
  if (divider_ == 1u) {
    return lateHold_[ear] * lateScalar_;
  }
  coherence_[ear] += lateSmoothing_ * (lateHold_[ear] - coherence_[ear]);
  return coherence_[ear] * lateScalar_;
}

void VirtualRoomEngine::stepFdn(const float *history, float *lines) noexcept {
  const RenderState &state = *active_;

  // 入力は mixing time だけ遅らせた音源そのもの。3 帯域を足せば元へ戻る。
  auto preDelay = static_cast<std::uint32_t>(state.preDelay);
  if (preDelay < 1u) {
    preDelay = 1u;
  }
  if (preDelay > ringSize_ - 4u) {
    preDelay = ringSize_ - 4u;
  }
  const std::uint32_t tap = (origin_ - preDelay) & ringMask_;
  float source[kSourceCount];
  for (std::uint32_t index = 0u; index < kSourceCount; ++index) {
    const std::uint32_t base = index * kBandCount * ringSize_;
    source[index] = history[base + tap] + history[base + ringSize_ + tap] +
                    history[base + 2u * ringSize_ + tap];
  }

  float out[kFdnLines];
  float damped[kFdnLines];
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    const std::uint32_t read = (fdnWrite_ - fdnDelayCurrent_[line]) & fdnMask_;
    const float value = lines[line * fdnSize_ + read];
    out[line] = value;

    // 帯域ごとの帰還ゲイン。音源側と同じ割り方なので、足すと素通しへ戻る。
    fdnLow_[line] += fdnCoefficientLow_ * (value - fdnLow_[line]);
    fdnMid_[line] += fdnCoefficientHigh_ * (value - fdnMid_[line]);
    const float low = fdnLow_[line];
    const float mid = fdnMid_[line] - fdnLow_[line];
    const float high = value - fdnMid_[line];
    damped[line] = low * fdnBandCurrent_[line][0] + mid * fdnBandCurrent_[line][1] +
                   high * fdnBandCurrent_[line][2];
  }

  hadamard16(damped);

  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    float value = damped[line];
    for (std::uint32_t index = 0u; index < kSourceCount; ++index) {
      value += fdnInputCurrent_[line][index] * source[index];
    }
    // 万一発振しても外へ出さない。**ここで潰れたら係数が間違っている。**
    if (!(value == value) || value > 64.0F || value < -64.0F) {
      value = 0.0F;
    }
    lines[line * fdnSize_ + fdnWrite_] = value;
  }

  for (std::uint32_t index = 0u; index < kEarCount; ++index) {
    float sum = 0.0F;
    for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
      sum += fdnOutput_[index][line] * out[line];
    }
    lateHold_[index] = sum;
  }

  fdnWrite_ = (fdnWrite_ + 1u) & fdnMask_;
}

}  // namespace effetune::plugins::spatial
