//  virtual_room.cpp
//  EffectDeckLocalDSP/spatial/virtual_room の音響の試験。docs/virtual-room-stop.md の
//  A〜D（と E）が戻ってこないことを数字で押さえる。測り方は Tools/brir_metrics.cpp と同じ。
//
//  applyState に経路の帯域ゲインや late の入力を 0 にした面を渡して、
//  direct だけ・late だけの BRIR を同じエンジンで取り出す。
//
//  目標:
//    - DRR_late（音源ごとに両耳を足す）が 100% で 8 dB ±1、200% で 2 dB ±1（A）
//    - late の立ち上がりが 1 次の像の終わり ±1 ms、80 ms までに -60 dB を下回る 5 ms 窓が無い（B）
//    - FDN の遅れが互いに 3% 以上離れている（E）
//    - 同相の低音（40〜120 Hz、-1 dBFS）の峰が入力 +1 dB 以下（C）
//    - prepare したての publish → process が頭から BRIR と -100 dB 以内で一致（D）
//    - ブロック長を振っても畳み込みと -120 dB 以内、同じ面を出し直しても音が変わらない

#include "virtual_room_engine.h"
#include "et_test.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iterator>
#include <vector>

namespace {

namespace vr = effetune::plugins::spatial;
using vr::RenderState;
using vr::VirtualRoomEngine;
using Params = effetune::generated::VirtualRoomPluginParams;

constexpr double kRate = 48000.0;
constexpr std::uint32_t kBlock = 512u;

// params.json の既定（2 次・天井 Drywall）。
Params defaults() {
  Params p{};
  p.roomWidth = 4.2F;
  p.roomDepth = 3.6F;
  p.roomHeight = 2.6F;
  p.listenerX = 50.0F;
  p.listenerY = 36.0F;
  p.listenerHeight = 1.2F;
  p.speakerAngle = 30.0F;
  p.speakerDistance = 1.8F;
  p.speakerElevation = 0.0F;
  p.roomAmount = 100.0F;
  p.decayScale = 1.0F;
  p.sideMaterial = 2.0F;
  p.frontMaterial = 2.0F;
  p.rearMaterial = 2.0F;
  p.floorMaterial = 6.0F;
  p.ceilingMaterial = 2.0F;
  p.earlyOrder = 1.0F;
  p.headRadius = 8.75F;
  p.pinnaAmount = 100.0F;
  p.headShadowAmount = 100.0F;
  p.outputGain = 0.0F;
  p.modelVersion = 1.0F;
  p.seedLow = 31777.0F;
  p.seedHigh = 41887.0F;
  return p;
}

double db10(double v) { return v > 0.0 ? 10.0 * std::log10(v) : -999.0; }
double db20(double v) { return v > 0.0 ? 20.0 * std::log10(v) : -999.0; }

// [音源][耳]
struct Brir {
  std::vector<float> h[2][2];
};

enum class Part { Full, Direct, Late };

RenderState partOf(const RenderState &base, Part part) {
  RenderState s = base;
  if (part == Part::Full) {
    return s;
  }
  for (std::uint32_t ear = 0u; ear < vr::kEarCount; ++ear) {
    for (std::uint32_t source = 0u; source < vr::kMaxSources; ++source) {
      for (std::uint32_t image = 0u; image < vr::kMaxImages; ++image) {
        if (part == Part::Late || image != 0u) {
          for (float &b : s.path[vr::pathIndex(ear, source, image)].band) {
            b = 0.0F;
          }
        }
      }
    }
  }
  if (part == Part::Direct) {
    for (auto &line : s.fdnInput) {
      for (float &v : line) {
        v = 0.0F;
      }
    }
  }
  return s;
}

Brir render(VirtualRoomEngine &engine, const RenderState &state, std::uint32_t frames) {
  Brir out;
  std::vector<float> left(kBlock), right(kBlock);
  for (std::uint32_t source = 0u; source < 2u; ++source) {
    engine.applyState(state);
    out.h[source][0].assign(frames, 0.0F);
    out.h[source][1].assign(frames, 0.0F);
    for (std::uint32_t done = 0u; done < frames;) {
      const std::uint32_t n = std::min(kBlock, frames - done);
      std::fill(left.begin(), left.end(), 0.0F);
      std::fill(right.begin(), right.end(), 0.0F);
      if (done == 0u) {
        (source == 0u ? left : right)[0] = 1.0F;
      }
      engine.process(left.data(), right.data(), n);
      std::copy_n(left.begin(), n, out.h[source][0].begin() + done);
      std::copy_n(right.begin(), n, out.h[source][1].begin() + done);
      done += n;
    }
  }
  return out;
}

double energy(const std::vector<float> &x, std::size_t from, std::size_t to) {
  double sum = 0.0;
  to = std::min(to, x.size());
  for (std::size_t i = from; i < to; ++i) {
    sum += static_cast<double>(x[i]) * x[i];
  }
  return sum;
}

double energy(const std::vector<float> &x) { return energy(x, 0u, x.size()); }

double peakOf(const Brir &b) {
  double peak = 0.0;
  for (const auto &s : b.h) {
    for (const auto &e : s) {
      for (float v : e) {
        peak = std::max(peak, std::fabs(static_cast<double>(v)));
      }
    }
  }
  return peak;
}

// 実時間の経路。prepare したての engine に publish してから流す。
void runRealtime(const Params &params, double rate, std::uint32_t block,
                 const std::vector<float> &inLeft, const std::vector<float> &inRight,
                 std::vector<float> &outLeft, std::vector<float> &outRight) {
  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(rate, block));
  engine.publish(params);
  const auto frames = static_cast<std::uint32_t>(inLeft.size());
  outLeft.assign(frames, 0.0F);
  outRight.assign(frames, 0.0F);
  std::vector<float> left(block), right(block);
  for (std::uint32_t done = 0u; done < frames;) {
    const std::uint32_t n = std::min(block, frames - done);
    std::copy_n(inLeft.begin() + done, n, left.begin());
    std::copy_n(inRight.begin() + done, n, right.begin());
    engine.process(left.data(), right.data(), n);
    std::copy_n(left.begin(), n, outLeft.begin() + done);
    std::copy_n(right.begin(), n, outRight.begin() + done);
    done += n;
  }
}

std::vector<float> noise(std::size_t frames, std::uint32_t seed) {
  std::vector<float> out(frames);
  std::uint32_t x = seed;
  for (float &v : out) {
    x = x * 1664525u + 1013904223u;
    v = (static_cast<float>(x >> 8) / 16777216.0F - 0.5F) * 0.5F;
  }
  return out;
}

void checkDrr(float roomAmount, double want) {
  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(kRate, kBlock));
  Params params = defaults();
  params.roomAmount = roomAmount;
  RenderState state{};
  vr::buildRenderState(params, kRate, state);
  const auto frames = static_cast<std::uint32_t>(kRate * 0.4);
  const Brir direct = render(engine, partOf(state, Part::Direct), frames);
  const Brir late = render(engine, partOf(state, Part::Late), frames);
  for (std::uint32_t source = 0u; source < 2u; ++source) {
    const double drr = db10((energy(direct.h[source][0]) + energy(direct.h[source][1])) /
                            (energy(late.h[source][0]) + energy(late.h[source][1])));
    ET_CHECK_MSG(std::fabs(drr - want) <= 1.0, "source %u DRR_late %+.2f dB, want %+.2f", source,
                 drr, want);
  }
}

}  // namespace

ET_CASE(drr_late_at_100)
{
  checkDrr(100.0F, 8.0);
}

// Room Amount は振幅に掛かるので、200% で late のエネルギーは 4 倍（DRR は 8 - 6.02）。
ET_CASE(drr_late_at_200)
{
  checkDrr(200.0F, 8.0 - 20.0 * std::log10(2.0));
}

ET_CASE(late_starts_at_first_order_end)
{
  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(kRate, kBlock));
  RenderState state{};
  vr::buildRenderState(defaults(), kRate, state);
  const auto frames = static_cast<std::uint32_t>(kRate * 0.1);
  const Brir direct = render(engine, partOf(state, Part::Direct), frames);
  const Brir late = render(engine, partOf(state, Part::Late), frames);
  const Brir full = render(engine, state, frames);

  double firstOrderEnd = 0.0;
  for (std::uint32_t ear = 0u; ear < vr::kEarCount; ++ear) {
    for (std::uint32_t source = 0u; source < vr::kStereoSources; ++source) {
      for (std::uint32_t image = 0u; image < vr::kFirstOrderImages; ++image) {
        firstOrderEnd = std::max(
            firstOrderEnd, static_cast<double>(state.path[vr::pathIndex(ear, source, image)].delay));
      }
    }
  }
  const double directPeak = peakOf(direct);
  std::size_t onset = SIZE_MAX;
  for (const auto &s : late.h) {
    for (const auto &e : s) {
      for (std::size_t i = 0; i < e.size(); ++i) {
        if (std::fabs(static_cast<double>(e[i])) > directPeak * 1e-4) {
          onset = std::min(onset, i);
          break;
        }
      }
    }
  }
  ET_CHECK(onset != SIZE_MAX);
  ET_CHECK_MSG(std::fabs(static_cast<double>(onset) - firstOrderEnd) <= kRate * 0.001,
               "late onset %zu, first-order end %.1f", onset, firstOrderEnd);
  ET_CHECK_MSG(std::fabs(static_cast<double>(state.mixingTime) - firstOrderEnd / kRate) < 1e-6,
               "mixingTime %.6f", static_cast<double>(state.mixingTime));

  // 5 ms 窓。最初の到来から 80 ms まで、直接音の窓から -60 dB を下回らない。
  const auto window = static_cast<std::size_t>(kRate * 0.005);
  double loudest = 0.0;
  double windows[16];
  for (int w = 0; w < 16; ++w) {
    windows[w] = 0.0;
    for (const auto &s : full.h) {
      for (const auto &e : s) {
        windows[w] += energy(e, w * window, (w + 1) * window);
      }
    }
    loudest = std::max(loudest, windows[w]);
  }
  for (int w = 0; w < 16; ++w) {
    ET_CHECK_MSG(db10(windows[w] / loudest) > -60.0, "window %d ms %+.1f dB", w * 5,
                 db10(windows[w] / loudest));
  }
}

// 狭い部屋・既定・広い部屋と seed を振っても、遅れが 3% 以上離れて奇数で、遅延線に収まる。
ET_CASE(fdn_delays_spaced)
{
  const float rooms[][3] = {{2.0F, 2.0F, 2.0F}, {4.2F, 3.6F, 2.6F}, {20.0F, 30.0F, 10.0F}};
  const float seeds[] = {0.0F, 1.0F, 31777.0F, 65535.0F};
  for (const double rate : {44100.0, 48000.0, 96000.0, 192000.0}) {
    const double internal = rate / static_cast<double>(vr::lateRateDivider(rate));
    for (const auto &room : rooms) {
      for (const float seed : seeds) {
        Params params = defaults();
        params.roomWidth = room[0];
        params.roomDepth = room[1];
        params.roomHeight = room[2];
        params.seedLow = seed;
        RenderState state{};
        vr::buildRenderState(params, rate, state);
        std::uint32_t sorted[vr::kFdnLines];
        std::copy(std::begin(state.fdnDelay), std::end(state.fdnDelay), sorted);
        std::sort(std::begin(sorted), std::end(sorted));
        for (std::uint32_t i = 0u; i < vr::kFdnLines; ++i) {
          ET_CHECK((sorted[i] & 1u) == 1u);
          ET_CHECK(sorted[i] <= static_cast<std::uint32_t>(0.13 * internal));
          if (i > 0u) {
            const double gap =
                static_cast<double>(sorted[i] - sorted[i - 1u]) / static_cast<double>(sorted[i - 1u]);
            ET_CHECK_MSG(gap >= 0.03 - 1e-9, "rate %.0f room %.1f seed %.0f lines %u/%u gap %.2f%%",
                         rate, static_cast<double>(room[0]), static_cast<double>(seed),
                         sorted[i - 1u], sorted[i], gap * 100.0);
          }
        }
        ET_CHECK(state.preDelay >= 1.0F);
      }
    }
  }
}

// 同相の低音がバイパスより大きくならない（C）。左右とも同じ正弦、-1 dBFS。
ET_CASE(inphase_bass_headroom)
{
  const auto frames = static_cast<std::uint32_t>(kRate * 0.6);
  const double amplitude = std::pow(10.0, -1.0 / 20.0);
  for (const double f : {40.0, 55.0, 80.0, 120.0}) {
    std::vector<float> in(frames);
    for (std::uint32_t i = 0u; i < frames; ++i) {
      in[i] = static_cast<float>(amplitude * std::sin(2.0 * vr::kPi * f * i / kRate));
    }
    std::vector<float> outLeft, outRight;
    runRealtime(defaults(), kRate, kBlock, in, in, outLeft, outRight);
    double peak = 0.0;
    for (std::uint32_t i = static_cast<std::uint32_t>(kRate * 0.3); i < frames; ++i) {
      peak = std::max({peak, std::fabs(static_cast<double>(outLeft[i])),
                       std::fabs(static_cast<double>(outRight[i]))});
    }
    ET_CHECK_MSG(db20(peak / amplitude) <= 1.0, "%.0f Hz peak %+.2f dB", f,
                 db20(peak / amplitude));
  }
}

// prepare したての engine では、最初の publish を渡りを挟まずに取る（D）。
// インパルスを 0 フレーム目に入れて、applyImmediate の BRIR と頭から比べる。
ET_CASE(first_block_is_not_lost)
{
  for (const double rate : {48000.0, 96000.0}) {
    const std::uint32_t frames = 8192u;
    VirtualRoomEngine reference;
    ET_CHECK(reference.prepare(rate, kBlock));
    reference.applyImmediate(defaults());
    const Brir brir = render(reference, reference.activeState(), frames);

    std::vector<float> left(frames, 0.0F), right(frames, 0.0F), outLeft, outRight;
    left[0] = 1.0F;
    runRealtime(defaults(), rate, kBlock, left, right, outLeft, outRight);
    double diff = 0.0;
    double peak = 0.0;
    for (std::uint32_t i = 0u; i < frames; ++i) {
      diff = std::max({diff, std::fabs(static_cast<double>(outLeft[i]) - brir.h[0][0][i]),
                       std::fabs(static_cast<double>(outRight[i]) - brir.h[0][1][i])});
      peak = std::max({peak, std::fabs(static_cast<double>(brir.h[0][0][i])),
                       std::fabs(static_cast<double>(brir.h[0][1][i]))});
    }
    ET_CHECK(peak > 0.0);
    ET_CHECK_MSG(db20(diff / peak) < -100.0, "rate %.0f diff %+.1f dB", rate, db20(diff / peak));
  }
}

// レートを変えて prepare し直したら、前のレートの面から渡らない。
ET_CASE(reprepare_takes_new_state_at_once)
{
  const std::uint32_t frames = 4096u;
  std::vector<float> left(frames, 0.0F), right(frames, 0.0F);
  left[0] = 1.0F;
  std::vector<float> want, wantRight;
  runRealtime(defaults(), 96000.0, kBlock, left, right, want, wantRight);

  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(48000.0, kBlock));
  engine.publish(defaults());
  std::vector<float> scratchLeft(kBlock, 0.1F), scratchRight(kBlock, -0.1F);
  engine.process(scratchLeft.data(), scratchRight.data(), kBlock);
  ET_CHECK(engine.prepare(96000.0, kBlock));
  engine.publish(defaults());
  std::vector<float> l(left), r(right);
  for (std::uint32_t done = 0u; done < frames; done += kBlock) {
    engine.process(l.data() + done, r.data() + done, kBlock);
  }
  for (std::uint32_t i = 0u; i < frames; ++i) {
    ET_CHECK_MSG(l[i] == want[i] && r[i] == wantRight[i], "frame %u: %g vs %g", i,
                 static_cast<double>(l[i]), static_cast<double>(want[i]));
  }
}

// 実時間の経路と BRIR の畳み込みが、ブロック長によらず頭から一致する。
ET_CASE(blocks_match_convolution)
{
  const std::uint32_t frames = 4096u;
  VirtualRoomEngine reference;
  ET_CHECK(reference.prepare(kRate, kBlock));
  reference.applyImmediate(defaults());
  const Brir brir = render(reference, reference.activeState(), frames);
  const std::vector<float> inLeft = noise(frames, 1u), inRight = noise(frames, 2u);
  std::vector<double> refLeft(frames, 0.0), refRight(frames, 0.0);
  double refPeak = 0.0;
  for (std::uint32_t n = 0u; n < frames; ++n) {
    for (std::uint32_t k = 0u; k <= n; ++k) {
      const double l = inLeft[n - k];
      const double r = inRight[n - k];
      refLeft[n] += l * brir.h[0][0][k] + r * brir.h[1][0][k];
      refRight[n] += l * brir.h[0][1][k] + r * brir.h[1][1][k];
    }
    refPeak = std::max({refPeak, std::fabs(refLeft[n]), std::fabs(refRight[n])});
  }
  for (const std::uint32_t block : {64u, 480u, 512u}) {
    std::vector<float> outLeft, outRight;
    runRealtime(defaults(), kRate, block, inLeft, inRight, outLeft, outRight);
    double diff = 0.0;
    for (std::uint32_t i = 0u; i < frames; ++i) {
      diff = std::max({diff, std::fabs(outLeft[i] - refLeft[i]), std::fabs(outRight[i] - refRight[i])});
    }
    ET_CHECK_MSG(db20(diff / refPeak) < -120.0, "block %u diff %+.1f dB", block,
                 db20(diff / refPeak));
  }
}

// 同じ面を出し直しても音が変わらない。渡りの間は耳介も 2 面で掛けて混ぜるので、
// 同じ面どうしなら cos^2 + sin^2 = 1 で元に戻る。
ET_CASE(republish_same_params_is_transparent)
{
  const std::uint32_t frames = 4096u;
  const std::vector<float> inLeft = noise(frames, 3u), inRight = noise(frames, 4u);
  std::vector<float> want, wantRight;
  runRealtime(defaults(), kRate, kBlock, inLeft, inRight, want, wantRight);

  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(kRate, kBlock));
  engine.publish(defaults());
  std::vector<float> l(inLeft), r(inRight);
  double diff = 0.0;
  double peak = 0.0;
  for (std::uint32_t done = 0u; done < frames; done += kBlock) {
    if (done == 2u * kBlock) {
      engine.publish(defaults());
    }
    engine.process(l.data() + done, r.data() + done, kBlock);
  }
  for (std::uint32_t i = 0u; i < frames; ++i) {
    diff = std::max({diff, std::fabs(static_cast<double>(l[i]) - want[i]),
                     std::fabs(static_cast<double>(r[i]) - wantRight[i])});
    peak = std::max(peak, std::fabs(static_cast<double>(want[i])));
  }
  ET_CHECK_MSG(db20(diff / peak) < -100.0, "diff %+.1f dB", db20(diff / peak));
}

// seed を変えても、late が満ちたまま 1 サンプルで裏返らない（§32）。
// 前は出力の符号の並びを面を取った場で差し替え、古い seed の遅延線に新しい並びが
// 掛かっていた。0.5 の 150 Hz 正弦で 2 階差分が定常の +55 dB（0.033 の段）。
// いまは畳み切って遅延線を空にする点で取る。空の FDN へ入り直す立ち上がりが残るので
// 定常よりは上がる（+23 dB）が、段は出ない。
ET_CASE(seed_change_does_not_click)
{
  const std::uint32_t block = 256u;
  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(kRate, block));
  engine.publish(defaults());
  std::vector<float> left(block), right(block);
  double previous = 0.0, beforePrevious = 0.0;
  double steady = 0.0, after = 0.0;
  std::uint64_t n = 0u;
  for (std::uint32_t index = 0u; index < 260u; ++index) {
    if (index == 200u) {
      Params params = defaults();
      params.seedLow = 12345.0F;
      engine.publish(params);
    }
    for (std::uint32_t i = 0u; i < block; ++i) {
      left[i] = right[i] = 0.5F * static_cast<float>(std::sin(2.0 * 3.14159265358979323846 * 150.0 *
                                                              static_cast<double>(n + i) / kRate));
    }
    engine.process(left.data(), right.data(), block);
    for (std::uint32_t i = 0u; i < block; ++i, ++n) {
      const double d2 = std::fabs(left[i] - 2.0 * previous + beforePrevious);
      if (index >= 100u && index < 200u) {
        steady = std::max(steady, d2);
      } else if (index >= 200u) {
        after = std::max(after, d2);
      }
      beforePrevious = previous;
      previous = left[i];
    }
  }
  ET_CHECK(steady > 0.0);
  ET_CHECK_MSG(db20(after / steady) < 30.0, "2nd diff %+.1f dB over steady", db20(after / steady));
}

// 畳んでいる途中に元の遅れの面が来ても、遅延線が畳んだ先の長さへ入れ替わったまま
// 残らない（帰還ゲインと lateGain は元の遅れのものなので RT60 と late の量がずれる）。
// 前は 4.2→6.0→4.2 m で 16 本とも、4.2→4.21→4.2 m でも 3 本ずれたままだった。
// 揺らしたあと黙らせてからインパルスを入れ、揺らさなかった engine と比べる。
ET_CASE(fold_back_to_same_delays_stays_consistent)
{
  const std::uint32_t block = 256u;
  const std::uint32_t frames = 24000u;
  auto run = [&](float width, std::vector<float> &outLeft, std::vector<float> &outRight) {
    VirtualRoomEngine engine;
    ET_CHECK(engine.prepare(kRate, block));
    engine.publish(defaults());
    std::vector<float> left, right;
    for (std::uint32_t index = 0u; index < 20u; ++index) {
      left = noise(block, 5u + index);
      right = noise(block, 50u + index);
      engine.process(left.data(), right.data(), block);
    }
    // 30 ms の畳みの中で 2 回出す（256 フレームの block を 2 つ、10.7 ms あける）。
    if (width > 0.0F) {
      for (const float w : {width, 4.2F}) {
        Params params = defaults();
        params.roomWidth = w;
        engine.publish(params);
        for (std::uint32_t index = 0u; index < 2u; ++index) {
          left = noise(block, 7u + index);
          right = noise(block, 9u + index);
          engine.process(left.data(), right.data(), block);
        }
      }
    }
    // 3 秒黙らせて残響を落とす。
    for (std::uint32_t index = 0u; index < 3u * 48000u / block; ++index) {
      std::fill(left.begin(), left.end(), 0.0F);
      std::fill(right.begin(), right.end(), 0.0F);
      engine.process(left.data(), right.data(), block);
    }
    outLeft.assign(frames, 0.0F);
    outRight.assign(frames, 0.0F);
    outLeft[0] = 1.0F;
    for (std::uint32_t done = 0u; done + block <= frames; done += block) {
      engine.process(outLeft.data() + done, outRight.data() + done, block);
    }
  };
  std::vector<float> wantLeft, wantRight;
  run(0.0F, wantLeft, wantRight);
  double peak = 0.0;
  for (std::uint32_t i = 0u; i < frames; ++i) {
    peak = std::max({peak, std::fabs(static_cast<double>(wantLeft[i])),
                     std::fabs(static_cast<double>(wantRight[i]))});
  }
  ET_CHECK(peak > 0.0);
  for (const float width : {6.0F, 4.21F, 4.5F}) {
    std::vector<float> gotLeft, gotRight;
    run(width, gotLeft, gotRight);
    double diff = 0.0;
    for (std::uint32_t i = 0u; i < frames; ++i) {
      diff = std::max({diff, std::fabs(static_cast<double>(gotLeft[i]) - wantLeft[i]),
                       std::fabs(static_cast<double>(gotRight[i]) - wantRight[i])});
    }
    ET_CHECK_MSG(db20(diff / peak) < -100.0, "width %.2f diff %+.1f dB", static_cast<double>(width),
                 db20(diff / peak));
  }
}

// ---------------------------------------------------------------- 5.1（§64）
//
// 入力は L, R, C, LFE, Ls, Rs（Spatial Mapper の "5.1 Upmix" の並び）。両耳を 0 番と 1 番へ書き、
// 2 番から先は 0。Stereo の音が 1 bit も変わらないことは、変える前と後の engine に同じ入力を
// 通して比べた（stop.md）。ここでは 5.1 の形と、実時間と offline の一致を押さえる。

namespace {

constexpr std::uint32_t kSurround = vr::kMaxSources;

Params surroundDefaults() {
  Params p = defaults();
  p.speakerLayout = 1.0F;
  return p;
}

// [音源][耳]。6 本の音源へ 1 本ずつインパルスを入れて取る。
struct SurroundBrir {
  std::vector<float> h[kSurround][2];
};

SurroundBrir renderSurround(VirtualRoomEngine &engine, const RenderState &state,
                            std::uint32_t frames, std::uint32_t channelCount = kSurround) {
  SurroundBrir out;
  std::vector<std::vector<float>> buffers(channelCount, std::vector<float>(kBlock));
  std::vector<float *> channels(channelCount);
  for (std::uint32_t c = 0u; c < channelCount; ++c) {
    channels[c] = buffers[c].data();
  }
  for (std::uint32_t source = 0u; source < kSurround; ++source) {
    engine.applyState(state);
    out.h[source][0].assign(frames, 0.0F);
    out.h[source][1].assign(frames, 0.0F);
    for (std::uint32_t done = 0u; done < frames;) {
      const std::uint32_t n = std::min(kBlock, frames - done);
      for (auto &b : buffers) {
        std::fill(b.begin(), b.end(), 0.0F);
      }
      if (done == 0u) {
        buffers[source][0] = 1.0F;
      }
      engine.process(channels.data(), channelCount, n);
      std::copy_n(buffers[0].begin(), n, out.h[source][0].begin() + done);
      std::copy_n(buffers[1].begin(), n, out.h[source][1].begin() + done);
      done += n;
    }
  }
  return out;
}

// 実時間の経路（publish → process）。inputs は 6 本、outputs は channelCount 本ぶん返す。
void runSurround(const Params &params, std::uint32_t block,
                 const std::vector<std::vector<float>> &inputs, std::uint32_t channelCount,
                 std::vector<std::vector<float>> &outputs) {
  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(kRate, block));
  engine.publish(params);
  const auto frames = static_cast<std::uint32_t>(inputs[0].size());
  outputs.assign(channelCount, std::vector<float>(frames, 0.0F));
  for (std::uint32_t c = 0u; c < channelCount; ++c) {
    if (c < inputs.size()) {
      outputs[c] = inputs[c];
    }
  }
  std::vector<float *> channels(channelCount);
  for (std::uint32_t done = 0u; done < frames;) {
    const std::uint32_t n = std::min(block, frames - done);
    for (std::uint32_t c = 0u; c < channelCount; ++c) {
      channels[c] = outputs[c].data() + done;
    }
    engine.process(channels.data(), channelCount, n);
    done += n;
  }
}

}  // namespace

// 面の形。LFE は直接音の低域だけ、late へ入れない。方向を持つ 5 本の late の入口は互いに直交。
ET_CASE(surround_state_shape)
{
  RenderState state{};
  vr::buildRenderState(surroundDefaults(), kRate, state);
  ET_CHECK(state.sourceCount == kSurround);
  for (std::uint32_t source = 0u; source < kSurround; ++source) {
    ET_CHECK(state.sourceImages[source] == (source == vr::kLfeSource ? 1u : vr::kMaxImages));
  }
  for (std::uint32_t ear = 0u; ear < vr::kEarCount; ++ear) {
    const vr::PathState &lfe = state.path[vr::pathIndex(ear, vr::kLfeSource, 0u)];
    ET_CHECK(lfe.band[0] > 0.0F && lfe.band[1] == 0.0F && lfe.band[2] == 0.0F);
    for (std::uint32_t image = 1u; image < vr::kMaxImages; ++image) {
      for (float b : state.path[vr::pathIndex(ear, vr::kLfeSource, image)].band) {
        ET_CHECK(b == 0.0F);
      }
    }
  }
  ET_CHECK(state.pinnaTaps[vr::kLfeSource] == 1u);
  for (std::uint32_t a = 0u; a < kSurround; ++a) {
    double selfA = 0.0;
    for (std::uint32_t line = 0u; line < vr::kFdnLines; ++line) {
      selfA += static_cast<double>(state.fdnInput[line][a]) * state.fdnInput[line][a];
    }
    if (a == vr::kLfeSource) {
      ET_CHECK(selfA == 0.0);
      continue;
    }
    ET_CHECK(selfA > 0.0);
    for (std::uint32_t b = a + 1u; b < kSurround; ++b) {
      if (b == vr::kLfeSource) {
        continue;
      }
      double dot = 0.0;
      double selfB = 0.0;
      for (std::uint32_t line = 0u; line < vr::kFdnLines; ++line) {
        dot += static_cast<double>(state.fdnInput[line][a]) * state.fdnInput[line][b];
        selfB += static_cast<double>(state.fdnInput[line][b]) * state.fdnInput[line][b];
      }
      ET_CHECK_MSG(std::fabs(dot) / std::sqrt(selfA * selfB) < 1e-6, "inputs %u/%u correlate %.3g",
                   a, b, dot / std::sqrt(selfA * selfB));
    }
  }

  // 5.1 の面の上に Stereo を組み直したら、3 本目から先は何も残らない（pool の使い回し）。
  vr::buildRenderState(defaults(), kRate, state);
  ET_CHECK(state.sourceCount == vr::kStereoSources);
  for (std::uint32_t ear = 0u; ear < vr::kEarCount; ++ear) {
    for (std::uint32_t source = vr::kStereoSources; source < kSurround; ++source) {
      for (std::uint32_t image = 0u; image < vr::kMaxImages; ++image) {
        for (float b : state.path[vr::pathIndex(ear, source, image)].band) {
          ET_CHECK(b == 0.0F);
        }
      }
      for (const auto &line : state.fdnInput) {
        ET_CHECK(line[source] == 0.0F);
      }
    }
  }
}

// 横の角が同じで前と後ろ（70° と 110°）の耳介は、event の遅れが違う。
// 頭部陰影と ITD は前後で同じ（cone of confusion）なので、ここが前後を分ける。
ET_CASE(surround_pinna_front_back_differ)
{
  const double toRadians = vr::kPi / 180.0;
  const double front[3] = {std::sin(70.0 * toRadians), std::cos(70.0 * toRadians), 0.0};
  const double back[3] = {std::sin(110.0 * toRadians), std::cos(110.0 * toRadians), 0.0};
  std::uint32_t frontTaps = 0u;
  std::uint32_t backTaps = 0u;
  std::uint32_t frontDelay[vr::kPinnaSlots]{};
  std::uint32_t backDelay[vr::kPinnaSlots]{};
  float frontGain[vr::kPinnaSlots]{};
  float backGain[vr::kPinnaSlots]{};
  vr::buildDirectionalPinna(front, 1.0, kRate, frontTaps, frontDelay, frontGain);
  vr::buildDirectionalPinna(back, 1.0, kRate, backTaps, backDelay, backGain);
  ET_CHECK(frontTaps == vr::kPinnaSlots && backTaps == vr::kPinnaSlots);
  // 重みつきの平均の遅れ。後ろの方が event が早く着く（sin(D (90° - phi)) が負になる）。
  double frontMean = 0.0;
  double backMean = 0.0;
  double frontWeight = 0.0;
  double backWeight = 0.0;
  for (std::uint32_t tap = 1u; tap < vr::kPinnaSlots; ++tap) {
    frontMean += std::fabs(frontGain[tap]) * frontDelay[tap];
    frontWeight += std::fabs(frontGain[tap]);
    backMean += std::fabs(backGain[tap]) * backDelay[tap];
    backWeight += std::fabs(backGain[tap]);
  }
  frontMean /= frontWeight;
  backMean /= backWeight;
  ET_CHECK_MSG(frontMean - backMean > 2.0, "mean delay front %.2f back %.2f", frontMean, backMean);
  // 左右の耳で同じ（cos(theta / 2) は偶関数）。
  const double mirrored[3] = {-front[0], front[1], front[2]};
  std::uint32_t mirroredDelay[vr::kPinnaSlots]{};
  float mirroredGain[vr::kPinnaSlots]{};
  std::uint32_t mirroredTaps = 0u;
  vr::buildDirectionalPinna(mirrored, 1.0, kRate, mirroredTaps, mirroredDelay, mirroredGain);
  for (std::uint32_t tap = 0u; tap < vr::kPinnaSlots; ++tap) {
    ET_CHECK(mirroredDelay[tap] == frontDelay[tap] && mirroredGain[tap] == frontGain[tap]);
  }
}

// 2 番から先は 0 で出る（6 本でも 8 本でも）。0 番と 1 番には音がある。
ET_CASE(surround_zeroes_extra_channels)
{
  const std::uint32_t frames = 4096u;
  std::vector<std::vector<float>> inputs;
  for (std::uint32_t c = 0u; c < kSurround; ++c) {
    inputs.push_back(noise(frames, 10u + c));
  }
  for (const std::uint32_t count : {6u, 8u}) {
    std::vector<std::vector<float>> outputs;
    runSurround(surroundDefaults(), kBlock, inputs, count, outputs);
    for (std::uint32_t c = 2u; c < count; ++c) {
      for (float v : outputs[c]) {
        ET_CHECK(v == 0.0F);
      }
    }
    ET_CHECK(energy(outputs[0]) > 0.0 && energy(outputs[1]) > 0.0);
  }
}

// LFE は低域だけ（300 Hz の 1 次の低域の帯）。50 Hz に比べて 3 kHz が 18 dB 以上小さい。
// 中高域の帯を持つ C は、同じ比べ方で 0 dB 近くになる。
ET_CASE(surround_lfe_is_low_only)
{
  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(kRate, kBlock));
  engine.applyImmediate(surroundDefaults());
  const SurroundBrir brir = renderSurround(engine, engine.activeState(), 8192u);
  const auto magnitude = [](const std::vector<float> &x, double frequency) {
    double re = 0.0;
    double im = 0.0;
    for (std::size_t i = 0u; i < x.size(); ++i) {
      const double phase = 2.0 * vr::kPi * frequency * static_cast<double>(i) / kRate;
      re += x[i] * std::cos(phase);
      im -= x[i] * std::sin(phase);
    }
    return std::sqrt(re * re + im * im);
  };
  for (std::uint32_t ear = 0u; ear < vr::kEarCount; ++ear) {
    const std::vector<float> &lfe = brir.h[vr::kLfeSource][ear];
    const double tilt = db20(magnitude(lfe, 3000.0) / magnitude(lfe, 50.0));
    ET_CHECK_MSG(tilt < -18.0, "ear %u LFE 3 kHz vs 50 Hz %+.1f dB", ear, tilt);
  }
}

// DRR_late は方向を持つ 5 本とも Stereo と同じ 8 dB ±1。
ET_CASE(surround_drr_late)
{
  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(kRate, kBlock));
  RenderState state{};
  vr::buildRenderState(surroundDefaults(), kRate, state);
  const auto frames = static_cast<std::uint32_t>(kRate * 0.4);
  const SurroundBrir direct = renderSurround(engine, partOf(state, Part::Direct), frames);
  const SurroundBrir late = renderSurround(engine, partOf(state, Part::Late), frames);
  for (std::uint32_t source = 0u; source < kSurround; ++source) {
    const double lateEnergy = energy(late.h[source][0]) + energy(late.h[source][1]);
    if (source == vr::kLfeSource) {
      ET_CHECK(lateEnergy == 0.0);
      continue;
    }
    const double drr =
        db10((energy(direct.h[source][0]) + energy(direct.h[source][1])) / lateEnergy);
    ET_CHECK_MSG(std::fabs(drr - 8.0) <= 1.0, "source %u DRR_late %+.2f dB", source, drr);
  }
}

// 実時間の経路と、6 x 2 の BRIR で畳んだものが、ブロック長によらず頭から一致する。
ET_CASE(surround_blocks_match_convolution)
{
  const std::uint32_t frames = 4096u;
  VirtualRoomEngine reference;
  ET_CHECK(reference.prepare(kRate, kBlock));
  reference.applyImmediate(surroundDefaults());
  const SurroundBrir brir = renderSurround(reference, reference.activeState(), frames);
  std::vector<std::vector<float>> inputs;
  for (std::uint32_t c = 0u; c < kSurround; ++c) {
    inputs.push_back(noise(frames, 20u + c));
  }
  std::vector<double> ref[2];
  ref[0].assign(frames, 0.0);
  ref[1].assign(frames, 0.0);
  double refPeak = 0.0;
  for (std::uint32_t n = 0u; n < frames; ++n) {
    for (std::uint32_t source = 0u; source < kSurround; ++source) {
      for (std::uint32_t k = 0u; k <= n; ++k) {
        const double x = inputs[source][n - k];
        ref[0][n] += x * brir.h[source][0][k];
        ref[1][n] += x * brir.h[source][1][k];
      }
    }
    refPeak = std::max({refPeak, std::fabs(ref[0][n]), std::fabs(ref[1][n])});
  }
  for (const std::uint32_t block : {64u, 480u, 512u}) {
    std::vector<std::vector<float>> outputs;
    runSurround(surroundDefaults(), block, inputs, kSurround, outputs);
    double diff = 0.0;
    for (std::uint32_t i = 0u; i < frames; ++i) {
      diff = std::max({diff, std::fabs(outputs[0][i] - ref[0][i]),
                       std::fabs(outputs[1][i] - ref[1][i])});
    }
    ET_CHECK_MSG(db20(diff / refPeak) < -120.0, "block %u diff %+.1f dB", block,
                 db20(diff / refPeak));
  }
}

// Stereo ⇄ 5.1 を鳴らしたまま切り替えても、壊れた値も跳ねも出ない。
// 渡りが終わったあとは、最初から 5.1 で鳴らしたものと同じ面で鳴る。
ET_CASE(surround_layout_switch_is_clean)
{
  const std::uint32_t frames = 48000u;
  std::vector<std::vector<float>> buffers;
  for (std::uint32_t c = 0u; c < kSurround; ++c) {
    buffers.push_back(noise(frames, 30u + c));
  }
  VirtualRoomEngine engine;
  ET_CHECK(engine.prepare(kRate, kBlock));
  engine.publish(defaults());
  double peak = 0.0;
  std::vector<float *> channels(kSurround);
  for (std::uint32_t done = 0u; done + kBlock <= frames; done += kBlock) {
    if (done == 20u * kBlock) {
      engine.publish(surroundDefaults());
    }
    if (done == 60u * kBlock) {
      engine.publish(defaults());
    }
    for (std::uint32_t c = 0u; c < kSurround; ++c) {
      channels[c] = buffers[c].data() + done;
    }
    engine.process(channels.data(), kSurround, kBlock);
    for (std::uint32_t i = 0u; i < kBlock; ++i) {
      const float l = channels[0][i];
      const float r = channels[1][i];
      ET_CHECK(l == l && r == r);
      peak = std::max({peak, std::fabs(static_cast<double>(l)), std::fabs(static_cast<double>(r))});
    }
  }
  // 入力の峰は 0.25。渡りで 2 面を cos^2 / sin^2 で混ぜても 0 dBFS には届かない。
  ET_CHECK_MSG(peak < 1.0, "peak %.3f", peak);
  ET_CHECK(engine.activeState().sourceCount == vr::kStereoSources);
}

static const et_case cases[] = {
    ET_ENTRY(drr_late_at_100),
    ET_ENTRY(drr_late_at_200),
    ET_ENTRY(late_starts_at_first_order_end),
    ET_ENTRY(fdn_delays_spaced),
    ET_ENTRY(inphase_bass_headroom),
    ET_ENTRY(first_block_is_not_lost),
    ET_ENTRY(reprepare_takes_new_state_at_once),
    ET_ENTRY(blocks_match_convolution),
    ET_ENTRY(republish_same_params_is_transparent),
    ET_ENTRY(seed_change_does_not_click),
    ET_ENTRY(fold_back_to_same_delays_stays_consistent),
    ET_ENTRY(surround_state_shape),
    ET_ENTRY(surround_pinna_front_back_differ),
    ET_ENTRY(surround_zeroes_extra_channels),
    ET_ENTRY(surround_lfe_is_low_only),
    ET_ENTRY(surround_drr_late),
    ET_ENTRY(surround_blocks_match_convolution),
    ET_ENTRY(surround_layout_switch_is_clean),
};

int main(int argc, char **argv) { return et_run(argc, argv, cases, ET_COUNT(cases)); }
