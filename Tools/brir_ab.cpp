// 同じ音を 2 通りに通して比べる。**比べるための道具**で、製品には入らない。
//
//   A: Virtual Room を実時間の経路そのままで通す（publish → process）
//   B: 元の 4ch IRS を IR Reverb と同じ形で畳む（dry 無し、指定の dB）
//
// 出すのはステレオ float32 WAV と、峰・実効値・0 dBFS を超えた数。
//
//   clang++ -std=c++20 -O2 -I... Tools/brir_ab.cpp \
//       EffectDeckLocalDSP/spatial/virtual_room/virtual_room_engine.cpp -o brir_ab
//   ./brir_ab in.wav ref.irs outA.wav outB.wav -15

#include "virtual_room_engine.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using effetune::plugins::spatial::VirtualRoomEngine;
using Params = effetune::generated::VirtualRoomPluginParams;

namespace {

constexpr std::uint32_t kBlock = 512u;

struct Wave {
  std::vector<std::vector<float>> channel;
  double rate = 48000.0;
};

std::uint32_t readU32(const std::vector<std::uint8_t> &b, std::size_t at) {
  return b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (std::uint32_t(b[at + 3]) << 24);
}
std::uint16_t readU16(const std::vector<std::uint8_t> &b, std::size_t at) {
  return static_cast<std::uint16_t>(b[at] | (b[at + 1] << 8));
}

bool readWav(const std::string &path, Wave &out) {
  std::FILE *file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) return false;
  std::fseek(file, 0, SEEK_END);
  const long size = std::ftell(file);
  std::fseek(file, 0, SEEK_SET);
  std::vector<std::uint8_t> raw(static_cast<std::size_t>(size));
  std::fread(raw.data(), 1, raw.size(), file);
  std::fclose(file);
  if (raw.size() < 44 || std::memcmp(raw.data(), "RIFF", 4) != 0) return false;

  std::size_t pos = 12;
  std::uint16_t tag = 0, channels = 0, bits = 0;
  std::uint32_t rate = 48000;
  std::size_t dataAt = 0, dataBytes = 0;
  while (pos + 8 <= raw.size()) {
    const std::uint32_t chunk = readU32(raw, pos + 4);
    if (std::memcmp(raw.data() + pos, "fmt ", 4) == 0) {
      tag = readU16(raw, pos + 8);
      channels = readU16(raw, pos + 10);
      rate = readU32(raw, pos + 12);
      bits = readU16(raw, pos + 22);
    } else if (std::memcmp(raw.data() + pos, "data", 4) == 0) {
      dataAt = pos + 8;
      dataBytes = chunk;
    }
    pos += 8 + chunk + (chunk & 1u);
  }
  if (channels == 0 || dataBytes == 0) return false;

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

void push32(std::vector<std::uint8_t> &o, std::uint32_t v) {
  for (int i = 0; i < 4; ++i) o.push_back(static_cast<std::uint8_t>(v >> (8 * i)));
}
void push16(std::vector<std::uint8_t> &o, std::uint16_t v) {
  o.push_back(static_cast<std::uint8_t>(v));
  o.push_back(static_cast<std::uint8_t>(v >> 8));
}

bool writeWav(const std::string &path, const std::vector<float> &left,
              const std::vector<float> &right, double rate) {
  std::vector<float> interleaved(left.size() * 2u);
  for (std::size_t i = 0; i < left.size(); ++i) {
    interleaved[i * 2u] = left[i];
    interleaved[i * 2u + 1u] = right[i];
  }
  std::vector<std::uint8_t> head;
  const auto bytes = static_cast<std::uint32_t>(interleaved.size() * 4u);
  head.insert(head.end(), {'R', 'I', 'F', 'F'});
  push32(head, 36u + bytes);
  head.insert(head.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
  push32(head, 16u);
  push16(head, 3u);
  push16(head, 2u);
  push32(head, static_cast<std::uint32_t>(rate));
  push32(head, static_cast<std::uint32_t>(rate) * 8u);
  push16(head, 8u);
  push16(head, 32u);
  head.insert(head.end(), {'d', 'a', 't', 'a'});
  push32(head, bytes);

  std::FILE *file = std::fopen(path.c_str(), "wb");
  if (file == nullptr) return false;
  std::fwrite(head.data(), 1, head.size(), file);
  std::fwrite(interleaved.data(), 4, interleaved.size(), file);
  std::fclose(file);
  return true;
}

Params defaults() {
  Params p{};
  p.roomWidth = 4.2F;      p.roomDepth = 3.6F;      p.roomHeight = 2.6F;
  p.listenerX = 50.0F;     p.listenerY = 36.1F;     p.listenerHeight = 1.2F;
  p.speakerAngle = 30.0F;  p.speakerDistance = 1.8F; p.speakerElevation = 0.0F;
  p.roomAmount = 100.0F;   p.decayScale = 1.0F;
  p.sideMaterial = 2.0F;   p.frontMaterial = 2.0F;  p.rearMaterial = 2.0F;
  p.floorMaterial = 6.0F;  p.ceilingMaterial = 1.0F;
  p.earlyOrder = 0.0F;
  p.headRadius = 8.75F;    p.pinnaAmount = 100.0F;  p.headShadowAmount = 100.0F;
  p.outputGain = 0.0F;     p.modelVersion = 1.0F;
  p.seedLow = 31777.0F;    p.seedHigh = 41855.0F;
  return p;
}

void report(const char *label, const std::vector<float> &left, const std::vector<float> &right) {
  double peak = 0.0, square = 0.0;
  std::size_t over = 0u, bad = 0u;
  for (const auto *side : {&left, &right}) {
    for (const float v : *side) {
      const double a = std::fabs(static_cast<double>(v));
      if (!(v == v) || a > 1e6) ++bad;
      if (a > peak) peak = a;
      if (a > 1.0) ++over;
      square += static_cast<double>(v) * v;
    }
  }
  const double rms = std::sqrt(square / static_cast<double>(left.size() * 2u));
  // 300 Hz / 3 kHz で 3 つに割る。DSP と同じ割り方（足すと素通しへ戻る）。
  double band[3] = {0.0, 0.0, 0.0};
  const double aLow = 1.0 - std::exp(-2.0 * 3.14159265358979 * 300.0 / 48000.0);
  const double aHigh = 1.0 - std::exp(-2.0 * 3.14159265358979 * 3000.0 / 48000.0);
  for (const auto *side : {&left, &right}) {
    double lo = 0.0, hi = 0.0;
    for (const float v : *side) {
      lo += aLow * (v - lo);
      hi += aHigh * (v - hi);
      band[0] += lo * lo;
      band[1] += (hi - lo) * (hi - lo);
      band[2] += (v - hi) * (v - hi);
    }
  }
  const double count = static_cast<double>(left.size() * 2u);
  std::printf("%-10s  peak %8.4f (%+6.2f dBFS)  rms %+7.2f  低 %+7.2f  中 %+7.2f  高 %+7.2f  "
              "0dBFS超え %zu  壊れ %zu\n",
              label, peak, 20.0 * std::log10(peak > 0 ? peak : 1e-12),
              20.0 * std::log10(rms > 0 ? rms : 1e-12),
              10.0 * std::log10(band[0] / count + 1e-30),
              10.0 * std::log10(band[1] / count + 1e-30),
              10.0 * std::log10(band[2] / count + 1e-30), over, bad);
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 6) {
    std::fprintf(stderr, "使い方: brir_ab in.wav ref.irs outA.wav outB.wav <dB>\n");
    return 1;
  }
  Wave in, ref;
  if (!readWav(argv[1], in)) { std::fprintf(stderr, "入力を読めない\n"); return 1; }
  if (!readWav(argv[2], ref)) { std::fprintf(stderr, "IRS を読めない\n"); return 1; }
  if (in.channel.size() < 2) { std::fprintf(stderr, "入力がステレオでない\n"); return 1; }
  if (ref.channel.size() != 4) { std::fprintf(stderr, "IRS が 4ch でない\n"); return 1; }
  const double decibels = std::atof(argv[5]);
  const auto frames = static_cast<std::uint32_t>(in.channel[0].size());

  report("入力", in.channel[0], in.channel[1]);

  // ---- A: Virtual Room を実時間の経路で通す
  VirtualRoomEngine engine;
  if (!engine.prepare(in.rate, kBlock)) { std::fprintf(stderr, "prepare 失敗\n"); return 1; }
  engine.publish(defaults());

  std::vector<float> aLeft(frames, 0.0F), aRight(frames, 0.0F);
  std::vector<float> left(kBlock), right(kBlock);
  for (std::uint32_t done = 0u; done < frames;) {
    const std::uint32_t n = std::min(kBlock, frames - done);
    for (std::uint32_t i = 0u; i < n; ++i) {
      left[i] = in.channel[0][done + i];
      right[i] = in.channel[1][done + i];
    }
    engine.process(left.data(), right.data(), n);
    for (std::uint32_t i = 0u; i < n; ++i) {
      aLeft[done + i] = left[i];
      aRight[done + i] = right[i];
    }
    done += n;
  }
  report("Virtual", aLeft, aRight);
  writeWav(argv[3], aLeft, aRight, in.rate);

  // ---- B: IR Reverb と同じ形で畳む。**dry を足さない。**
  // out_L = L*LL + R*RL、out_R = L*LR + R*RR（§43 の並び）。
  const double gain = std::pow(10.0, decibels / 20.0);
  const auto taps = static_cast<std::uint32_t>(ref.channel[0].size());
  std::vector<float> bLeft(frames, 0.0F), bRight(frames, 0.0F);
  for (std::uint32_t t = 0u; t < taps; ++t) {
    const double ll = ref.channel[0][t], lr = ref.channel[1][t];
    const double rl = ref.channel[2][t], rr = ref.channel[3][t];
    if (ll == 0.0 && lr == 0.0 && rl == 0.0 && rr == 0.0) continue;
    for (std::uint32_t i = t; i < frames; ++i) {
      const double l = in.channel[0][i - t], r = in.channel[1][i - t];
      bLeft[i] += static_cast<float>((l * ll + r * rl) * gain);
      bRight[i] += static_cast<float>((l * lr + r * rr) * gain);
    }
  }
  char label[32];
  std::snprintf(label, sizeof(label), "IRS%+.0fdB", decibels);
  report(label, bLeft, bRight);
  writeWav(argv[4], bLeft, bRight, in.rate);
  return 0;
}
