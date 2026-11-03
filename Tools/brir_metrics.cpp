// Virtual Room の BRIR を数字で測る。**比べるための道具**で、製品には入らない。
//
// docs/virtual-room-stop.md の 4 つ（A〜D）が直ったかを、耳より先に数字で見る。
// アプリと同じ VirtualRoomEngine を回し、applyState に経路や late の入力を 0 にした面を
// 渡して direct だけ・early だけ・late だけの BRIR を別々に取り出す。
//
//   clang++ -std=c++20 -O2 -I EffectDeckLocalDSP/spatial/virtual_room -I Generated/dsp \
//       -I Vendor/effetune/dsp/include -I Vendor/effetune/dsp \
//       Tools/brir_metrics.cpp EffectDeckLocalDSP/spatial/virtual_room/virtual_room_engine.cpp \
//       -o brir_metrics
//
//   ./brir_metrics room [js|app] [Room Amount %]   BRIR の形（DRR・late の立ち上がり・窓）
//   ./brir_metrics realtime [js|app]               実時間の経路と畳み込みの一致、最初の block
//   ./brir_metrics sine [js|app]                   同相の低音（40〜120 Hz、-1 dBFS）の峰
//   ./brir_metrics file in.wav [js|app]            曲を通した実効値・3 帯域・峰・0 dBFS 超え
//   ./brir_metrics irs ref.irs                     元の JS の IRS を同じ物差しで測る
//   ./brir_metrics response [js|app] [direct|early|late]  1/3 オクターブの周波数応答
//   ./brir_metrics response irs ref.irs                   同じものを元の JS の IRS で
//   ./brir_metrics signal out.wav                  比べるための曲の代わり（決まった乱数）
//   ./brir_metrics surround sine|file in.wav|cone|realtime|cpu   5.1（§64）
//
// js は brir_render / brir_ab と同じ配置（元の JS に寄せた 1 次・天井 Painted Wall）、
// app は params.json の既定（2 次・天井 Drywall）。
// 目標を外れたら FAIL を出して 1 で終わる。

#include "virtual_room_engine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace vr = effetune::plugins::spatial;
using vr::RenderState;
using vr::VirtualRoomEngine;
using Params = effetune::generated::VirtualRoomPluginParams;

namespace {

constexpr double kRate = 48000.0;
constexpr std::uint32_t kBlock = 512u;
int failures = 0;

void verdict(bool ok, const char *what) {
  std::printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) ++failures;
}

double db10(double v) { return v > 0.0 ? 10.0 * std::log10(v) : -999.0; }
double db20(double v) { return v > 0.0 ? 20.0 * std::log10(v) : -999.0; }

// ---------------------------------------------------------------- 配置

Params jsParams() {
  Params p{};
  p.roomWidth = 4.2F;      p.roomDepth = 3.6F;       p.roomHeight = 2.6F;
  p.listenerX = 50.0F;     p.listenerY = 36.1F;      p.listenerHeight = 1.2F;
  p.speakerAngle = 30.0F;  p.speakerDistance = 1.8F; p.speakerElevation = 0.0F;
  p.roomAmount = 100.0F;   p.decayScale = 1.0F;
  p.sideMaterial = 2.0F;   p.frontMaterial = 2.0F;   p.rearMaterial = 2.0F;
  p.floorMaterial = 6.0F;  p.ceilingMaterial = 1.0F;
  p.earlyOrder = 0.0F;
  p.headRadius = 8.75F;    p.pinnaAmount = 100.0F;   p.headShadowAmount = 100.0F;
  p.outputGain = 0.0F;     p.modelVersion = 1.0F;
  p.seedLow = 31777.0F;    p.seedHigh = 41855.0F;
  return p;
}

// params.json の既定。
Params appParams() {
  Params p = jsParams();
  p.listenerY = 36.0F;
  p.ceilingMaterial = 2.0F;  // Drywall
  p.earlyOrder = 1.0F;       // Second Order
  p.seedHigh = 41887.0F;
  return p;
}

Params pickParams(const char *name) {
  return (name != nullptr && std::strcmp(name, "app") == 0) ? appParams() : jsParams();
}

// ---------------------------------------------------------------- WAV

struct Wave {
  std::vector<std::vector<float>> channel;
  double rate = kRate;
};

bool readWav(const std::string &path, Wave &out) {
  std::FILE *file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) return false;
  std::fseek(file, 0, SEEK_END);
  const long size = std::ftell(file);
  std::fseek(file, 0, SEEK_SET);
  std::vector<std::uint8_t> raw(static_cast<std::size_t>(size));
  const std::size_t got = std::fread(raw.data(), 1, raw.size(), file);
  std::fclose(file);
  if (got != raw.size() || raw.size() < 44 || std::memcmp(raw.data(), "RIFF", 4) != 0) return false;
  auto u32 = [&](std::size_t at) {
    return std::uint32_t(raw[at]) | (std::uint32_t(raw[at + 1]) << 8) |
           (std::uint32_t(raw[at + 2]) << 16) | (std::uint32_t(raw[at + 3]) << 24);
  };
  auto u16 = [&](std::size_t at) { return std::uint16_t(raw[at] | (raw[at + 1] << 8)); };
  std::size_t pos = 12, dataAt = 0, dataBytes = 0;
  std::uint16_t tag = 0, channels = 0, bits = 0;
  std::uint32_t rate = 48000;
  while (pos + 8 <= raw.size()) {
    const std::uint32_t chunk = u32(pos + 4);
    if (std::memcmp(raw.data() + pos, "fmt ", 4) == 0) {
      tag = u16(pos + 8); channels = u16(pos + 10); rate = u32(pos + 12); bits = u16(pos + 22);
    } else if (std::memcmp(raw.data() + pos, "data", 4) == 0) {
      dataAt = pos + 8;
      dataBytes = std::min<std::size_t>(chunk, raw.size() - dataAt);
    }
    pos += 8 + chunk + (chunk & 1u);
  }
  if (channels == 0 || dataBytes == 0 || bits == 0) return false;
  const std::size_t bytes = bits / 8u;
  const std::size_t frames = dataBytes / (bytes * channels);
  out.rate = rate;
  out.channel.assign(channels, std::vector<float>(frames, 0.0F));
  for (std::size_t f = 0; f < frames; ++f) {
    for (std::uint16_t c = 0; c < channels; ++c) {
      const std::size_t at = dataAt + (f * channels + c) * bytes;
      float v = 0.0F;
      if (tag == 3 && bits == 32) {
        std::memcpy(&v, raw.data() + at, 4);
      } else if (tag == 1 && bits == 16) {
        std::int16_t s = 0;
        std::memcpy(&s, raw.data() + at, 2);
        v = static_cast<float>(s) / 32768.0F;
      }
      out.channel[c][f] = v;
    }
  }
  return true;
}

bool writeWav(const std::string &path, const std::vector<std::vector<float>> &channel, double rate) {
  const auto channels = static_cast<std::uint32_t>(channel.size());
  const std::size_t frames = channel.empty() ? 0u : channel[0].size();
  std::vector<float> interleaved(frames * channels);
  for (std::size_t i = 0; i < frames; ++i)
    for (std::uint32_t c = 0; c < channels; ++c) interleaved[i * channels + c] = channel[c][i];
  std::vector<std::uint8_t> head;
  auto p32 = [&](std::uint32_t v) { for (int i = 0; i < 4; ++i) head.push_back(std::uint8_t(v >> (8 * i))); };
  auto p16 = [&](std::uint16_t v) { head.push_back(std::uint8_t(v)); head.push_back(std::uint8_t(v >> 8)); };
  const auto bytes = static_cast<std::uint32_t>(interleaved.size() * 4u);
  head.insert(head.end(), {'R', 'I', 'F', 'F'}); p32(36u + bytes);
  head.insert(head.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '}); p32(16u);
  p16(3u); p16(static_cast<std::uint16_t>(channels)); p32(static_cast<std::uint32_t>(rate));
  p32(static_cast<std::uint32_t>(rate) * channels * 4u); p16(static_cast<std::uint16_t>(channels * 4u));
  p16(32u);
  head.insert(head.end(), {'d', 'a', 't', 'a'}); p32(bytes);
  std::FILE *file = std::fopen(path.c_str(), "wb");
  if (file == nullptr) return false;
  std::fwrite(head.data(), 1, head.size(), file);
  std::fwrite(interleaved.data(), 4, interleaved.size(), file);
  std::fclose(file);
  return true;
}

// ---------------------------------------------------------------- BRIR

// [音源][耳]。0 = 左。
struct Brir {
  std::vector<float> h[2][2];
  [[nodiscard]] std::size_t size() const { return h[0][0].size(); }
};

enum class Part { Full, Direct, Early, Late };

// 部分だけ鳴る面を作る。帯域ゲインと late の入力を 0 にするだけで、
// 遅れ・耳介・出力ゲインはそのまま（=同じ物差しで足し算になる）。
RenderState partOf(const RenderState &base, Part part) {
  RenderState s = base;
  if (part == Part::Full) return s;
  for (std::uint32_t ear = 0u; ear < vr::kEarCount; ++ear) {
    for (std::uint32_t source = 0u; source < vr::kMaxSources; ++source) {
      for (std::uint32_t image = 0u; image < vr::kMaxImages; ++image) {
        const bool keep = (part == Part::Direct && image == 0u) ||
                          (part == Part::Early && image != 0u);
        if (!keep) {
          for (float &b : s.path[vr::pathIndex(ear, source, image)].band) b = 0.0F;
        }
      }
    }
  }
  if (part != Part::Late) {
    for (auto &line : s.fdnInput)
      for (float &v : line) v = 0.0F;
  }
  return s;
}

Brir renderState(VirtualRoomEngine &engine, const RenderState &state, std::uint32_t frames) {
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
      if (done == 0u) (source == 0u ? left : right)[0] = 1.0F;
      engine.process(left.data(), right.data(), n);
      std::copy_n(left.begin(), n, out.h[source][0].begin() + done);
      std::copy_n(right.begin(), n, out.h[source][1].begin() + done);
      done += n;
    }
  }
  return out;
}

double energy(const std::vector<float> &x, std::size_t from = 0, std::size_t to = SIZE_MAX) {
  double sum = 0.0;
  to = std::min(to, x.size());
  for (std::size_t i = from; i < to; ++i) sum += double(x[i]) * x[i];
  return sum;
}

double brirEnergy(const Brir &b, std::size_t from, std::size_t to) {
  double sum = 0.0;
  for (const auto &s : b.h)
    for (const auto &e : s) sum += energy(e, from, to);
  return sum;
}

double brirPeak(const Brir &b) {
  double peak = 0.0;
  for (const auto &s : b.h)
    for (const auto &e : s)
      for (float v : e) peak = std::max(peak, std::fabs(double(v)));
  return peak;
}

// ---------------------------------------------------------------- 曲の物差し

struct Levels {
  double rms, band[3], peak;
  std::size_t over, broken;
};

// brir_ab と同じ割り方（300 Hz / 3 kHz の相補 1 次）。両チャンネルの平均二乗。
Levels measure(const std::vector<float> &left, const std::vector<float> &right, double rate) {
  Levels l{};
  double square = 0.0;
  const double aLow = 1.0 - std::exp(-2.0 * vr::kPi * 300.0 / rate);
  const double aHigh = 1.0 - std::exp(-2.0 * vr::kPi * 3000.0 / rate);
  for (const auto *side : {&left, &right}) {
    double lo = 0.0, hi = 0.0;
    for (float v : *side) {
      const double a = std::fabs(double(v));
      if (!(v == v) || a > 1e6) ++l.broken;
      l.peak = std::max(l.peak, a);
      if (a > 1.0) ++l.over;
      square += double(v) * v;
      lo += aLow * (v - lo);
      hi += aHigh * (v - hi);
      l.band[0] += lo * lo;
      l.band[1] += (hi - lo) * (hi - lo);
      l.band[2] += (v - hi) * (v - hi);
    }
  }
  const double count = double(left.size() * 2u);
  l.rms = db10(square / count);
  for (double &b : l.band) b = db10(b / count);
  return l;
}

void printLevels(const char *label, const Levels &l) {
  std::printf("  %-12s rms %+7.2f  低 %+7.2f  中 %+7.2f  高 %+7.2f  peak %+6.2f dBFS  0dBFS超え %zu  壊れ %zu\n",
              label, l.rms, l.band[0], l.band[1], l.band[2], db20(l.peak), l.over, l.broken);
}

// 実時間の経路（publish → process）で通す。prepare したての engine を使う。
void runRealtime(const Params &params, const std::vector<float> &inLeft,
                 const std::vector<float> &inRight, double rate, std::uint32_t block,
                 std::vector<float> &outLeft, std::vector<float> &outRight) {
  VirtualRoomEngine engine;
  if (!engine.prepare(rate, block)) {
    std::fprintf(stderr, "prepare 失敗\n");
    std::exit(2);
  }
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

// ---------------------------------------------------------------- room

void printDelays(const RenderState &s) {
  std::printf("  FDN の遅れ（内部レートのサンプル）:");
  std::uint32_t sorted[vr::kFdnLines];
  std::copy(std::begin(s.fdnDelay), std::end(s.fdnDelay), sorted);
  std::sort(std::begin(sorted), std::end(sorted));
  double closest = 1e9;
  std::uint64_t total = 0;
  for (std::uint32_t i = 0u; i < vr::kFdnLines; ++i) {
    std::printf(" %u", sorted[i]);
    total += sorted[i];
    if (i > 0u) {
      closest = std::min(closest, double(sorted[i] - sorted[i - 1u]) / double(sorted[i - 1u]));
    }
  }
  std::printf("\n  Σd %llu（10log10 %.2f）  隣どうしの最小の差 %.2f%%\n",
              static_cast<unsigned long long>(total), db10(double(total)), closest * 100.0);
  verdict(closest >= 0.03, "FDN の遅れが互いに 3% 以上離れている");
}

int cmdRoom(const Params &params, bool assertTargets) {
  VirtualRoomEngine engine;
  if (!engine.prepare(kRate, kBlock)) return 2;
  RenderState state{};
  vr::buildRenderState(params, kRate, state);
  const auto frames = static_cast<std::uint32_t>(kRate * 0.6);

  const Brir direct = renderState(engine, partOf(state, Part::Direct), frames);
  const Brir early = renderState(engine, partOf(state, Part::Early), frames);
  const Brir late = renderState(engine, partOf(state, Part::Late), frames);
  const Brir full = renderState(engine, state, frames);

  std::printf("Room Amount %.0f%%  preDelay %.1f サンプル（%.2f ms）  mixingTime %.2f ms  "
              "outputGain %.4f（%+.2f dB）  RT60 %.3f / %.3f / %.3f s\n",
              double(params.roomAmount), double(state.preDelay),
              double(state.preDelay) / kRate * 1e3, double(state.mixingTime) * 1e3,
              double(state.outputGain), db20(double(state.outputGain)), double(state.rt60[0]),
              double(state.rt60[1]), double(state.rt60[2]));
  printDelays(state);

  // DRR は**音源ごとに両耳を足して**比べる（model.h と同じ定義）。
  const double ratio = double(params.roomAmount) * 0.01;
  const double wantDrr = 8.0 - 20.0 * std::log10(std::max(ratio, 1e-6));
  for (std::uint32_t source = 0u; source < 2u; ++source) {
    const double ed = energy(direct.h[source][0]) + energy(direct.h[source][1]);
    const double el = energy(late.h[source][0]) + energy(late.h[source][1]);
    const double ee = energy(early.h[source][0]) + energy(early.h[source][1]);
    const double drr = db10(ed / el);
    std::printf("  音源 %u: direct %+.2f dB  early %+.2f dB  late %+.2f dB  DRR_late %+.2f dB"
                "（目標 %+.2f）  direct/early %+.2f dB\n",
                source, db10(ed), db10(ee), db10(el), drr, wantDrr, db10(ed / ee));
    if (assertTargets) {
      char what[96];
      std::snprintf(what, sizeof(what), "音源 %u の DRR_late が目標 ±1 dB", source);
      verdict(std::fabs(drr - wantDrr) <= 1.0, what);
    }
  }

  // late の立ち上がり。direct の峰から -80 dB を最初に超えた所。
  const double directPeak = brirPeak(direct);
  std::size_t onset = SIZE_MAX;
  for (const auto &s : late.h)
    for (const auto &e : s)
      for (std::size_t i = 0; i < e.size(); ++i)
        if (std::fabs(double(e[i])) > directPeak * 1e-4) {
          onset = std::min(onset, i);
          break;
        }
  std::size_t firstOrderEnd = 0u;
  {
    // 1 次までの像で、いちばん遅く着く経路。
    for (std::uint32_t ear = 0u; ear < vr::kEarCount; ++ear)
      for (std::uint32_t source = 0u; source < vr::kStereoSources; ++source)
        for (std::uint32_t image = 0u; image < std::min(state.imagesPerSource, vr::kFirstOrderImages);
             ++image)
          firstOrderEnd = std::max<std::size_t>(
              firstOrderEnd, std::size_t(state.path[vr::pathIndex(ear, source, image)].delay));
  }
  std::printf("  late の立ち上がり %.2f ms   1 次の像の終わり %.2f ms\n",
              onset == SIZE_MAX ? -1.0 : double(onset) / kRate * 1e3,
              double(firstOrderEnd) / kRate * 1e3);
  if (assertTargets) {
    verdict(onset != SIZE_MAX && std::fabs(double(onset) - double(firstOrderEnd)) <= kRate * 0.001,
            "late の立ち上がりが 1 次の像の終わり ±1 ms");
  }

  // 5 ms ごとの窓。全チャンネルを足したエネルギーを、いちばん大きい窓（直接音）に対して。
  const auto win5 = static_cast<std::size_t>(kRate * 0.005);
  double windows[20];
  double loudest = 0.0;
  for (int w = 0; w < 20; ++w) {
    windows[w] = brirEnergy(full, w * win5, (w + 1) * win5);
    loudest = std::max(loudest, windows[w]);
  }
  std::size_t firstArrival = SIZE_MAX;
  for (const auto &s : direct.h)
    for (const auto &e : s)
      for (std::size_t i = 0; i < e.size(); ++i)
        if (std::fabs(double(e[i])) > directPeak * 0.05) {
          firstArrival = std::min(firstArrival, i);
          break;
        }
  std::printf("  5 ms 窓（dB、直接音の窓に対して）:");
  double quietest = 0.0;
  for (int w = 0; w < 20; ++w) {
    const double rel = db10(windows[w] / loudest);
    std::printf(" %d:%+.1f", w * 5, rel);
    const std::size_t start = w * win5;
    if (start + win5 > firstArrival && start < static_cast<std::size_t>(kRate * 0.080)) {
      quietest = std::min(quietest, rel);
    }
  }
  std::printf("\n  最初の到来から 80 ms までで最も静かな 5 ms 窓 %+.1f dB\n", quietest);
  if (assertTargets) verdict(quietest > -60.0, "80 ms までに -60 dB を下回る 5 ms 窓が無い");

  // 10 ms 窓。20-30 と 30-40 が 10-20 と 40-50 の間（dB で直線）に乗っているか。
  const auto win10 = static_cast<std::size_t>(kRate * 0.010);
  double w10[10];
  std::printf("  10 ms 窓（dB、全体の峰の窓に対して）:");
  for (int w = 0; w < 10; ++w) {
    w10[w] = db10(brirEnergy(full, w * win10, (w + 1) * win10) / (loudest * 2.0));
    std::printf(" %d:%+.1f", w * 10, w10[w]);
  }
  const double a = w10[1], b = w10[4];
  const double at2 = a + (b - a) / 3.0, at3 = a + (b - a) * 2.0 / 3.0;
  std::printf("\n  20-30 ms %+.1f（直線 %+.1f、差 %+.1f）  30-40 ms %+.1f（直線 %+.1f、差 %+.1f）\n",
              w10[2], at2, w10[2] - at2, w10[3], at3, w10[3] - at3);
  if (assertTargets) {
    verdict(std::fabs(w10[2] - at2) <= 6.0 && std::fabs(w10[3] - at3) <= 6.0,
            "20-30 / 30-40 ms の窓が 10-20 と 40-50 の間 ±6 dB");
  }

  // stop.md と同じ物差し: preDelay の所で前後に割った全体の比。
  const auto split = static_cast<std::size_t>(state.preDelay);
  std::printf("  （参考）preDelay で前後に割った比 %+.2f dB\n",
              db10(brirEnergy(full, 0, split) / brirEnergy(full, split, SIZE_MAX)));
  return 0;
}

// ---------------------------------------------------------------- realtime

std::vector<float> noise(std::size_t frames, std::uint32_t seed) {
  std::vector<float> out(frames);
  std::uint32_t x = seed;
  for (auto &v : out) {
    x = x * 1664525u + 1013904223u;
    v = (static_cast<float>(x >> 8) / 16777216.0F - 0.5F) * 0.5F;
  }
  return out;
}

int cmdRealtime(const Params &params) {
  VirtualRoomEngine engine;
  if (!engine.prepare(kRate, kBlock)) return 2;
  const std::uint32_t frames = 24000u;
  engine.applyImmediate(params);
  const Brir brir = renderState(engine, engine.activeState(), frames);

  // 最初の block。prepare したての engine に publish してすぐインパルスを通す。
  {
    std::vector<float> l(frames, 0.0F), r(frames, 0.0F), ol, orr;
    l[0] = 1.0F;
    runRealtime(params, l, r, kRate, kBlock, ol, orr);
    double diff = 0.0, peak = 0.0;
    std::size_t firstNonZero = SIZE_MAX;
    for (std::uint32_t i = 0u; i < frames; ++i) {
      diff = std::max({diff, std::fabs(double(ol[i]) - brir.h[0][0][i]),
                       std::fabs(double(orr[i]) - brir.h[0][1][i])});
      peak = std::max({peak, std::fabs(double(brir.h[0][0][i])), std::fabs(double(brir.h[0][1][i]))});
      if (firstNonZero == SIZE_MAX && (ol[i] != 0.0F || orr[i] != 0.0F)) firstNonZero = i;
    }
    std::printf("  最初の block（512）: publish → process と applyImmediate の BRIR の差 %+.1f dB"
                "（峰に対して）  最初に音が出たサンプル %zu\n",
                db20(diff / peak), firstNonZero);
    verdict(db20(diff / peak) < -100.0, "最初の block から BRIR と -100 dB 以内で一致");
  }

  // 雑音を畳み込みと実時間で通す。ブロック長を振る。
  const std::vector<float> inL = noise(frames, 1u), inR = noise(frames, 2u);
  std::vector<float> refL(frames, 0.0F), refR(frames, 0.0F);
  for (std::uint32_t n = 0u; n < frames; ++n) {
    double sl = 0.0, sr = 0.0;
    for (std::uint32_t k = 0u; k <= n; ++k) {
      const double l = inL[n - k], r = inR[n - k];
      sl += l * brir.h[0][0][k] + r * brir.h[1][0][k];
      sr += l * brir.h[0][1][k] + r * brir.h[1][1][k];
    }
    refL[n] = float(sl);
    refR[n] = float(sr);
  }
  double refPeak = 0.0;
  for (std::uint32_t i = 0u; i < frames; ++i)
    refPeak = std::max({refPeak, std::fabs(double(refL[i])), std::fabs(double(refR[i]))});
  for (std::uint32_t block : {64u, 128u, 256u, 480u, 512u}) {
    std::vector<float> ol, orr;
    runRealtime(params, inL, inR, kRate, block, ol, orr);
    double diffAll = 0.0, diffLate = 0.0;
    for (std::uint32_t i = 0u; i < frames; ++i) {
      const double d = std::max(std::fabs(double(ol[i]) - refL[i]), std::fabs(double(orr[i]) - refR[i]));
      diffAll = std::max(diffAll, d);
      if (i >= 8192u) diffLate = std::max(diffLate, d);
    }
    std::printf("  block %3u: 畳み込みとの差 頭から %+.1f dB   8192 以降 %+.1f dB\n", block,
                db20(diffAll / refPeak), db20(diffLate / refPeak));
    char what[96];
    std::snprintf(what, sizeof(what), "block %u で頭から畳み込みと -120 dB 以内", block);
    verdict(db20(diffAll / refPeak) < -120.0, what);
  }
  return 0;
}

// ---------------------------------------------------------------- sine

int cmdSine(const Params &params) {
  const auto frames = static_cast<std::uint32_t>(kRate * 1.5);
  const double amplitude = std::pow(10.0, -1.0 / 20.0);
  double worst = -999.0, worstFrequency = 0.0, sub = -999.0;
  // 目標は 40〜120 Hz。20〜35 Hz は参考に出すだけ（正規化がどこまで守っているかを見る）。
  std::printf("  同相の正弦 -1 dBFS（峰の dB は入力の峰に対して、0.5 s 以降）:");
  for (double f = 20.0; f <= 120.0 + 1e-9; f += 5.0) {
    std::vector<float> in(frames);
    for (std::uint32_t i = 0u; i < frames; ++i)
      in[i] = float(amplitude * std::sin(2.0 * vr::kPi * f * i / kRate));
    std::vector<float> ol, orr;
    runRealtime(params, in, in, kRate, kBlock, ol, orr);
    double peak = 0.0;
    for (std::uint32_t i = static_cast<std::uint32_t>(kRate * 0.5); i < frames; ++i)
      peak = std::max({peak, std::fabs(double(ol[i])), std::fabs(double(orr[i]))});
    const double rel = db20(peak / amplitude);
    std::printf(" %.0f:%+.2f", f, rel);
    if (f < 39.0) {
      sub = std::max(sub, rel);
    } else if (rel > worst) {
      worst = rel;
      worstFrequency = f;
    }
  }
  std::printf("\n  40-120 Hz でいちばん大きいのは %.0f Hz の %+.2f dB（20-35 Hz は %+.2f dB）\n",
              worstFrequency, worst, sub);
  verdict(worst <= 1.0, "同相の低音の峰が入力の峰 +1 dB 以下");
  return 0;
}

// ---------------------------------------------------------------- file

int cmdFile(const char *path, const Params &params) {
  Wave in;
  if (!readWav(path, in) || in.channel.size() < 2) {
    std::fprintf(stderr, "ステレオの WAV を読めない: %s\n", path);
    return 2;
  }
  std::vector<float> ol, orr;
  runRealtime(params, in.channel[0], in.channel[1], in.rate, kBlock, ol, orr);
  const Levels a = measure(in.channel[0], in.channel[1], in.rate);
  const Levels b = measure(ol, orr, in.rate);
  printLevels("入力", a);
  printLevels("Virtual", b);
  std::printf("  入力に対して: rms %+.2f  低 %+.2f  中 %+.2f  高 %+.2f\n", b.rms - a.rms,
              b.band[0] - a.band[0], b.band[1] - a.band[1], b.band[2] - a.band[2]);
  verdict(std::fabs(b.rms - a.rms) <= 1.0, "実効値が入力 ±1 dB");
  verdict(b.over == 0u && b.broken == 0u, "0 dBFS を超えたサンプルが 0");
  return 0;
}

// ---------------------------------------------------------------- irs

int cmdIrs(const char *path) {
  Wave w;
  if (!readWav(path, w) || w.channel.size() != 4) {
    std::fprintf(stderr, "4ch の IRS を読めない: %s\n", path);
    return 2;
  }
  // LL / LR / RL / RR → [音源][耳]
  Brir b;
  b.h[0][0] = w.channel[0]; b.h[0][1] = w.channel[1];
  b.h[1][0] = w.channel[2]; b.h[1][1] = w.channel[3];
  const double rate = w.rate;
  double loudest = 0.0;
  const auto win5 = static_cast<std::size_t>(rate * 0.005);
  for (int k = 0; k < 20; ++k) loudest = std::max(loudest, brirEnergy(b, k * win5, (k + 1) * win5));
  std::printf("  5 ms 窓（dB、直接音の窓に対して）:");
  for (int k = 0; k < 20; ++k)
    std::printf(" %d:%+.1f", k * 5, db10(brirEnergy(b, k * win5, (k + 1) * win5) / loudest));
  const auto win10 = static_cast<std::size_t>(rate * 0.010);
  std::printf("\n  10 ms 窓（dB、全体の峰の窓に対して）:");
  for (int k = 0; k < 10; ++k)
    std::printf(" %d:%+.1f", k * 10, db10(brirEnergy(b, k * win10, (k + 1) * win10) / (loudest * 2.0)));
  for (double ms : {6.0, 10.75, 33.81}) {
    const auto split = static_cast<std::size_t>(rate * ms * 1e-3);
    std::printf("\n  %.2f ms で前後に割った比 %+.2f dB", ms,
                db10(brirEnergy(b, 0, split) / brirEnergy(b, split, SIZE_MAX)));
  }
  std::printf("\n");
  return 0;
}

// ---------------------------------------------------------------- response

// 1/3 オクターブごとの周波数応答（dB、入力に対して）。耳ごとに、
//   同相: L=R の音を入れたとき |H_L→e + H_R→e|^2（低音の同相和）
//   無相関: L と R が無相関のとき |H_L→e|^2 + |H_R→e|^2（左右ばらばらの音）
// 帯の中を 24 点で平均する。late の山谷をならして傾きだけを見るため。
void printResponse(const Brir &b, double rate) {
  const double centers[] = {20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400,
                            500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000,
                            6300, 8000, 10000, 12500, 16000};
  std::printf("  Hz      同相 L耳  同相 R耳  無相関 L耳 無相関 R耳\n");
  for (double center : centers) {
    double coherent[2] = {0, 0}, separate[2] = {0, 0};
    constexpr int kPoints = 24;
    for (int k = 0; k < kPoints; ++k) {
      const double f = center * std::pow(2.0, (double(k) / (kPoints - 1) - 0.5) / 3.0);
      const double omega = 2.0 * vr::kPi * f / rate;
      for (int ear = 0; ear < 2; ++ear) {
        double re[2] = {0, 0}, im[2] = {0, 0};
        for (int source = 0; source < 2; ++source) {
          const auto &h = b.h[source][ear];
          double cr = 1.0, ci = 0.0;
          const double sr = std::cos(omega), si = -std::sin(omega);
          for (std::size_t n = 0; n < h.size(); ++n) {
            re[source] += h[n] * cr;
            im[source] += h[n] * ci;
            const double nr = cr * sr - ci * si;
            ci = cr * si + ci * sr;
            cr = nr;
          }
        }
        coherent[ear] += (re[0] + re[1]) * (re[0] + re[1]) + (im[0] + im[1]) * (im[0] + im[1]);
        separate[ear] += re[0] * re[0] + im[0] * im[0] + re[1] * re[1] + im[1] * im[1];
      }
    }
    std::printf("  %6.0f  %+7.2f  %+7.2f   %+7.2f  %+7.2f\n", center, db10(coherent[0] / kPoints),
                db10(coherent[1] / kPoints), db10(separate[0] / kPoints), db10(separate[1] / kPoints));
  }
}

int cmdResponse(int argc, char **argv) {
  if (argc > 2 && std::strcmp(argv[2], "irs") == 0 && argc > 3) {
    Wave w;
    if (!readWav(argv[3], w) || w.channel.size() != 4) return 2;
    Brir b;
    b.h[0][0] = w.channel[0]; b.h[0][1] = w.channel[1];
    b.h[1][0] = w.channel[2]; b.h[1][1] = w.channel[3];
    printResponse(b, w.rate);
    return 0;
  }
  Params params = pickParams(argc > 2 ? argv[2] : nullptr);
  VirtualRoomEngine engine;
  if (!engine.prepare(kRate, kBlock)) return 2;
  engine.applyImmediate(params);
  RenderState state = engine.activeState();
  Part part = Part::Full;
  if (argc > 3) {
    const std::string which = argv[3];
    part = which == "direct" ? Part::Direct : which == "early" ? Part::Early
         : which == "late" ? Part::Late : Part::Full;
  }
  const Brir b = renderState(engine, partOf(state, part), static_cast<std::uint32_t>(kRate * 0.8));
  std::printf("  outputGain %+.2f dB\n", db20(double(state.outputGain)));
  printResponse(b, kRate);
  return 0;
}

// ---------------------------------------------------------------- signal

// 曲の代わり。stop.md で使った曲は残っていないので、決まった乱数で作る。
// 低音は左右同相（ベースとキック）、中高域は左右で 6 割ほど相関した雑音（ピンク寄り）。
// 峰は -1 dBFS に揃える。
int cmdSignal(const char *path) {
  const auto frames = static_cast<std::size_t>(kRate * 12.0);
  std::vector<std::vector<float>> out(2, std::vector<float>(frames, 0.0F));
  std::uint32_t x = 12345u;
  auto white = [&]() {
    x = x * 1664525u + 1013904223u;
    return static_cast<double>(x >> 8) / 8388608.0 - 1.0;
  };
  // Paul Kellet の簡易ピンク。
  struct Pink {
    double b[7]{};
    double next(double w) {
      b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759;
      b[2] = 0.96900 * b[2] + w * 0.1538520; b[3] = 0.86650 * b[3] + w * 0.3104856;
      b[4] = 0.55000 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.0168980;
      const double v = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362;
      b[6] = w * 0.115926;
      return v * 0.11;
    }
  } common, sideL, sideR;
  const double notes[] = {41.20, 55.00, 73.42, 61.74, 49.00, 82.41, 98.00, 65.41};
  const double beat = 0.5;  // 120 BPM
  double hp[2] = {0.0, 0.0};
  const double aHp = 1.0 - std::exp(-2.0 * vr::kPi * 150.0 / kRate);
  for (std::size_t i = 0; i < frames; ++i) {
    const double t = double(i) / kRate;
    const auto index = static_cast<std::size_t>(t / beat);
    const double local = t - double(index) * beat;
    // ベース: 倍音つきの正弦。立ち上がり 5 ms、ゆっくり減る。
    const double f = notes[index % 8];
    const double env = std::min(1.0, local / 0.005) * std::exp(-local * 3.0);
    const double bass = env * (std::sin(2 * vr::kPi * f * t) + 0.35 * std::sin(4 * vr::kPi * f * t) +
                               0.15 * std::sin(6 * vr::kPi * f * t));
    // キック: 1 拍おきに 110→45 Hz へ落ちる正弦。
    double kick = 0.0;
    if (index % 2 == 0) {
      const double phase = 2 * vr::kPi * (45.0 * local + 65.0 * (1.0 - std::exp(-local * 30.0)) / 30.0);
      kick = std::sin(phase) * std::exp(-local * 12.0);
    }
    const double c = common.next(white());
    const double l = sideL.next(white());
    const double r = sideR.next(white());
    // 中高域の雑音は 150 Hz 以下を落とす（低音は同相の楽器だけにする）。
    double mid[2] = {0.75 * c + 0.55 * l + 0.10 * white(), 0.75 * c + 0.55 * r + 0.10 * white()};
    for (int ch = 0; ch < 2; ++ch) {
      hp[ch] += aHp * (mid[ch] - hp[ch]);
      mid[ch] -= hp[ch];
    }
    // 拍に合わせて少し揺らす（ハイハットの代わり）。
    const double swell = 0.6 + 0.4 * std::exp(-std::fmod(t, beat * 0.5) * 10.0);
    for (int ch = 0; ch < 2; ++ch) {
      out[ch][i] = float(0.30 * bass + 0.45 * kick + 1.00 * mid[ch] * swell);
    }
  }
  double peak = 0.0;
  for (const auto &ch : out)
    for (float v : ch) peak = std::max(peak, std::fabs(double(v)));
  const double scale = std::pow(10.0, -1.0 / 20.0) / peak;
  for (auto &ch : out)
    for (float &v : ch) v = float(v * scale);
  if (!writeWav(path, out, kRate)) return 2;
  printLevels("曲の代わり", measure(out[0], out[1], kRate));
  return 0;
}

// ---------------------------------------------------------------- surround（§64）
//
// 5.1 の数字。入力は L, R, C, LFE, Ls, Rs。曲は Spatial Mapper の代わりに**固定の行列**で広げる:
//   L, R はそのまま、C = 0.7 (L + R)（"5.1 Upmix" の direct 行列と同じ）、LFE = 0、
//   Ls = 0.5 (L - R)、Rs = 0.5 (R - L)（ambience の代わり。本物は相関で切り出すので違う）。

std::vector<std::vector<float>> upmix(const std::vector<float> &left,
                                      const std::vector<float> &right) {
  const std::size_t frames = left.size();
  std::vector<std::vector<float>> out(vr::kMaxSources, std::vector<float>(frames, 0.0F));
  for (std::size_t i = 0; i < frames; ++i) {
    const double l = left[i], r = right[i];
    out[0][i] = float(l);
    out[1][i] = float(r);
    out[2][i] = float(0.7 * (l + r));
    out[4][i] = float(0.5 * (l - r));
    out[5][i] = float(0.5 * (r - l));
  }
  return out;
}

// 実時間の経路を 6 本で回す。両耳を返す。
void runSurroundRealtime(const Params &params, const std::vector<std::vector<float>> &in,
                         std::uint32_t block, std::vector<float> &outLeft,
                         std::vector<float> &outRight) {
  VirtualRoomEngine engine;
  if (!engine.prepare(kRate, block)) std::exit(2);
  engine.publish(params);
  std::vector<std::vector<float>> io = in;
  const std::size_t frames = in[0].size();
  float *ch[vr::kMaxSources];
  for (std::size_t done = 0; done < frames;) {
    const auto n = static_cast<std::uint32_t>(std::min<std::size_t>(block, frames - done));
    for (std::uint32_t c = 0; c < vr::kMaxSources; ++c) ch[c] = io[c].data() + done;
    engine.process(ch, vr::kMaxSources, n);
    done += n;
  }
  outLeft = io[0];
  outRight = io[1];
}

// [音源][耳] の BRIR を applyImmediate から取る。
void surroundBrir(const Params &params, std::uint32_t frames,
                  std::vector<float> (&h)[vr::kMaxSources][2], bool directOnly = false) {
  VirtualRoomEngine engine;
  if (!engine.prepare(kRate, kBlock)) std::exit(2);
  engine.applyImmediate(params);
  RenderState state = engine.activeState();
  if (directOnly) state = partOf(state, Part::Direct);
  std::vector<std::vector<float>> buffers(vr::kMaxSources, std::vector<float>(kBlock));
  float *ch[vr::kMaxSources];
  for (std::uint32_t source = 0; source < vr::kMaxSources; ++source) {
    engine.applyState(state);
    h[source][0].assign(frames, 0.0F);
    h[source][1].assign(frames, 0.0F);
    for (std::uint32_t done = 0; done < frames; done += kBlock) {
      for (std::uint32_t c = 0; c < vr::kMaxSources; ++c) {
        std::fill(buffers[c].begin(), buffers[c].end(), 0.0F);
        ch[c] = buffers[c].data();
      }
      if (done == 0) buffers[source][0] = 1.0F;
      const std::uint32_t n = std::min(kBlock, frames - done);
      engine.process(ch, vr::kMaxSources, n);
      std::copy_n(buffers[0].begin(), n, h[source][0].begin() + done);
      std::copy_n(buffers[1].begin(), n, h[source][1].begin() + done);
    }
  }
}

double bandPower(const std::vector<float> &h, double low, double high) {
  constexpr int kPoints = 32;
  double sum = 0.0;
  for (int k = 0; k < kPoints; ++k) {
    const double f = low * std::pow(high / low, (k + 0.5) / kPoints);
    const double omega = 2.0 * vr::kPi * f / kRate;
    double re = 0.0, im = 0.0;
    for (std::size_t n = 0; n < h.size(); ++n) {
      re += h[n] * std::cos(omega * double(n));
      im -= h[n] * std::sin(omega * double(n));
    }
    sum += re * re + im * im;
  }
  return sum / kPoints;
}

int cmdSurround(int argc, char **argv) {
  Params params = appParams();
  params.speakerLayout = 1.0F;
  const std::string what = argc > 2 ? argv[2] : "";

  if (what == "sine") {
    // L = R の正弦 -1 dBFS を固定の行列で広げる（C = 1.4 倍、Ls / Rs は 0）。
    const auto frames = static_cast<std::uint32_t>(kRate * 1.5);
    const double amplitude = std::pow(10.0, -1.0 / 20.0);
    double worst = -999.0, worstFrequency = 0.0, sub = -999.0;
    std::printf("  同相の正弦 -1 dBFS を 5.1 へ（峰の dB は入力の峰に対して、0.5 s 以降）:");
    for (double f = 20.0; f <= 120.0 + 1e-9; f += 5.0) {
      std::vector<float> s(frames);
      for (std::uint32_t i = 0; i < frames; ++i)
        s[i] = float(amplitude * std::sin(2.0 * vr::kPi * f * i / kRate));
      std::vector<float> ol, orr;
      runSurroundRealtime(params, upmix(s, s), kBlock, ol, orr);
      double peak = 0.0;
      for (std::uint32_t i = static_cast<std::uint32_t>(kRate * 0.5); i < frames; ++i)
        peak = std::max({peak, std::fabs(double(ol[i])), std::fabs(double(orr[i]))});
      const double gain = db20(peak / amplitude);
      std::printf(" %.0f:%+.2f", f, gain);
      if (f >= 40.0) {
        if (gain > worst) { worst = gain; worstFrequency = f; }
      } else {
        sub = std::max(sub, gain);
      }
    }
    std::printf("\n  40〜120 Hz の峰 %+.2f dB（%.0f Hz）、20〜35 Hz の峰 %+.2f dB\n", worst,
                worstFrequency, sub);
    verdict(worst <= 1.0, "40〜120 Hz の同相の峰が入力 +1 dB 以下");
    return 0;
  }

  if (what == "file" && argc > 3) {
    Wave in;
    if (!readWav(argv[3], in) || in.channel.size() < 2) return 2;
    std::vector<float> ol, orr, sl, sr;
    runSurroundRealtime(params, upmix(in.channel[0], in.channel[1]), kBlock, ol, orr);
    runRealtime(appParams(), in.channel[0], in.channel[1], in.rate, kBlock, sl, sr);
    const Levels a = measure(in.channel[0], in.channel[1], in.rate);
    const Levels s = measure(sl, sr, in.rate);
    const Levels b = measure(ol, orr, in.rate);
    printLevels("入力", a);
    printLevels("Stereo", s);
    printLevels("5.1", b);
    std::printf("  入力に対して: Stereo rms %+.2f / 5.1 rms %+.2f  低 %+.2f  中 %+.2f  高 %+.2f\n",
                s.rms - a.rms, b.rms - a.rms, b.band[0] - a.band[0], b.band[1] - a.band[1],
                b.band[2] - a.band[2]);
    verdict(b.over == 0u && b.broken == 0u, "0 dBFS を超えたサンプルが 0");
    return 0;
  }

  if (what == "cone") {
    // 前後の取り違え（cone of confusion）。L を 70° に置くと Ls（110°）と横の角が同じになり、
    // ITD と頭部陰影は同じ。違いは耳介・後ろの陰・部屋の反射だけ。直接音だけで比べる。
    Params cone = params;
    cone.speakerAngle = 70.0F;
    std::vector<float> h[vr::kMaxSources][2];
    surroundBrir(cone, 4096u, h, true);
    const double bands[][2] = {{300, 1000}, {1000, 3000}, {3000, 6000},
                               {6000, 10000}, {10000, 16000}};
    std::printf("  直接音、Ls（110°）- L（70°）の dB（左耳 = 近い耳 / 右耳 = 遠い耳）:\n");
    for (const auto &band : bands) {
      std::printf("    %5.0f〜%5.0f Hz  近 %+6.2f  遠 %+6.2f\n", band[0], band[1],
                  db10(bandPower(h[4][0], band[0], band[1]) / bandPower(h[0][0], band[0], band[1])),
                  db10(bandPower(h[4][1], band[0], band[1]) / bandPower(h[0][1], band[0], band[1])));
    }
    return 0;
  }

  if (what == "realtime") {
    const std::uint32_t frames = 8192u;
    std::vector<float> h[vr::kMaxSources][2];
    surroundBrir(params, frames, h);
    std::vector<std::vector<float>> in(vr::kMaxSources, std::vector<float>(frames));
    std::uint32_t x = 99u;
    for (auto &ch : in)
      for (float &v : ch) {
        x = x * 1664525u + 1013904223u;
        v = (float(x >> 8) / 16777216.0F - 0.5F) * 0.5F;
      }
    std::vector<double> ref[2] = {std::vector<double>(frames, 0.0), std::vector<double>(frames, 0.0)};
    double peak = 0.0;
    for (std::uint32_t n = 0; n < frames; ++n) {
      for (std::uint32_t s = 0; s < vr::kMaxSources; ++s)
        for (std::uint32_t k = 0; k <= n; ++k) {
          ref[0][n] += double(in[s][n - k]) * h[s][0][k];
          ref[1][n] += double(in[s][n - k]) * h[s][1][k];
        }
      peak = std::max({peak, std::fabs(ref[0][n]), std::fabs(ref[1][n])});
    }
    double worst = -999.0;
    for (std::uint32_t block : {64u, 128u, 480u, 512u, 1024u}) {
      std::vector<float> ol, orr;
      runSurroundRealtime(params, in, block, ol, orr);
      double diff = 0.0;
      for (std::uint32_t i = 0; i < frames; ++i)
        diff = std::max({diff, std::fabs(ol[i] - ref[0][i]), std::fabs(orr[i] - ref[1][i])});
      std::printf("  block %4u: 6 x 2 の BRIR で畳んだものとの差 %+.1f dB\n", block, db20(diff / peak));
      worst = std::max(worst, db20(diff / peak));
    }
    verdict(worst < -120.0, "実時間と畳み込みの差が -120 dB 以内");
    return 0;
  }

  if (what == "cpu") {
    // 1 block の処理時間の p99（block の長さに対する %）。この道具を回した機械での値。
    for (int layout = 0; layout < 2; ++layout) {
      Params p = appParams();
      p.speakerLayout = float(layout);
      VirtualRoomEngine engine;
      if (!engine.prepare(kRate, kBlock)) return 2;
      engine.publish(p);
      std::vector<std::vector<float>> io(vr::kMaxSources, std::vector<float>(kBlock));
      std::uint32_t x = 7u;
      float *ch[vr::kMaxSources];
      std::vector<double> spent;
      const std::uint32_t channels = layout == 0 ? 2u : vr::kMaxSources;
      for (int block = 0; block < 2000; ++block) {
        for (std::uint32_t c = 0; c < vr::kMaxSources; ++c) {
          for (float &v : io[c]) {
            x = x * 1664525u + 1013904223u;
            v = (float(x >> 8) / 16777216.0F - 0.5F) * 0.5F;
          }
          ch[c] = io[c].data();
        }
        const auto begin = std::chrono::steady_clock::now();
        engine.process(ch, channels, kBlock);
        const auto end = std::chrono::steady_clock::now();
        if (block >= 100) spent.push_back(std::chrono::duration<double>(end - begin).count());
      }
      std::sort(spent.begin(), spent.end());
      const double budget = double(kBlock) / kRate;
      std::printf("  %s: 中央値 %.1f%%  p99 %.1f%%（48 kHz、block %u）\n",
                  layout == 0 ? "Stereo" : "5.1   ", 100.0 * spent[spent.size() / 2] / budget,
                  100.0 * spent[spent.size() * 99 / 100] / budget, kBlock);
    }
    return 0;
  }

  std::fprintf(stderr, "surround sine | file in.wav | cone | realtime | cpu\n");
  return 2;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "使い方は頭のコメント\n");
    return 2;
  }
  const std::string cmd = argv[1];
  int rc = 0;
  if (cmd == "room") {
    Params params = pickParams(argc > 2 ? argv[2] : nullptr);
    if (argc > 3) params.roomAmount = static_cast<float>(std::atof(argv[3]));
    rc = cmdRoom(params, true);
  } else if (cmd == "realtime") {
    rc = cmdRealtime(pickParams(argc > 2 ? argv[2] : nullptr));
  } else if (cmd == "sine") {
    rc = cmdSine(pickParams(argc > 2 ? argv[2] : nullptr));
  } else if (cmd == "file" && argc > 2) {
    rc = cmdFile(argv[2], pickParams(argc > 3 ? argv[3] : nullptr));
  } else if (cmd == "response") {
    rc = cmdResponse(argc, argv);
  } else if (cmd == "irs" && argc > 2) {
    rc = cmdIrs(argv[2]);
  } else if (cmd == "surround") {
    rc = cmdSurround(argc, argv);
  } else if (cmd == "signal" && argc > 2) {
    rc = cmdSignal(argv[2]);
  } else {
    std::fprintf(stderr, "知らない使い方: %s\n", cmd.c_str());
    return 2;
  }
  if (rc != 0) return rc;
  return failures == 0 ? 0 : 1;
}
