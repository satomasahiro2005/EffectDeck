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
    for (std::uint32_t source = 0u; source < vr::kSourceCount; ++source) {
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
    for (std::uint32_t source = 0u; source < vr::kSourceCount; ++source) {
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
};

int main(int argc, char **argv) { return et_run(argc, argv, cases, ET_COUNT(cases)); }
