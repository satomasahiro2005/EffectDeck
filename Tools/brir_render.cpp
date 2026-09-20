// Virtual Room の BRIR を手元で書き出す。**比べるための道具**で、製品には入らない。
//
// アプリと同じ VirtualRoomEngine を offline で回す（§44 と同じ形）。
// 出すのは 4ch float32 WAV、並びは LL / LR / RL / RR（§43）。
//
//   clang++ -std=c++20 -O2 -I<...> Tools/brir_render.cpp \
//       EffectDeckLocalDSP/spatial/virtual_room/virtual_room_engine.cpp -o brir_render
//   ./brir_render out.wav
//
// 比べる相手は M0Rf30/easyeffects-presets の
// scripts/generate-synthetic-binaural-room.js が吐く .irs。

#include "virtual_room_engine.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using effetune::plugins::spatial::VirtualRoomEngine;
using Params = effetune::generated::VirtualRoomPluginParams;

namespace {

constexpr double kRate = 48000.0;
constexpr std::uint32_t kBlock = 512u;

// 元の JS と同じ配置。材質だけは向こうが反射率の直打ちなので合わせられない。
Params defaults() {
  Params p{};
  p.roomWidth = 4.2F;
  p.roomDepth = 3.6F;
  p.roomHeight = 2.6F;
  p.listenerX = 50.0F;
  p.listenerY = 36.1F;  // 向こうの HEAD_Y_M 1.3 / 3.6
  p.listenerHeight = 1.2F;
  p.speakerAngle = 30.0F;
  p.speakerDistance = 1.8F;
  p.speakerElevation = 0.0F;
  p.roomAmount = 100.0F;
  p.decayScale = 1.0F;
  p.sideMaterial = 2.0F;     // Drywall
  p.frontMaterial = 2.0F;
  p.rearMaterial = 2.0F;
  p.floorMaterial = 6.0F;    // Carpet
  p.ceilingMaterial = 1.0F;  // Painted Wall
  p.earlyOrder = 0.0F;       // First Order（向こうは 1 次だけ）
  p.headRadius = 8.75F;
  p.pinnaAmount = 100.0F;
  p.headShadowAmount = 100.0F;
  p.outputGain = 0.0F;
  p.modelVersion = 1.0F;
  p.seedLow = 31777.0F;
  p.seedHigh = 41855.0F;
  return p;
}

void writeU32(std::vector<std::uint8_t> &out, std::uint32_t v) {
  for (int i = 0; i < 4; ++i) out.push_back(static_cast<std::uint8_t>(v >> (8 * i)));
}
void writeU16(std::vector<std::uint8_t> &out, std::uint16_t v) {
  out.push_back(static_cast<std::uint8_t>(v));
  out.push_back(static_cast<std::uint8_t>(v >> 8));
}

bool writeWav(const std::string &path, const std::vector<float> &interleaved,
              std::uint32_t channels, double rate) {
  std::vector<std::uint8_t> head;
  const auto dataBytes = static_cast<std::uint32_t>(interleaved.size() * sizeof(float));
  head.insert(head.end(), {'R', 'I', 'F', 'F'});
  writeU32(head, 36u + dataBytes);
  head.insert(head.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
  writeU32(head, 16u);
  writeU16(head, 3u);  // IEEE float
  writeU16(head, static_cast<std::uint16_t>(channels));
  writeU32(head, static_cast<std::uint32_t>(rate));
  writeU32(head, static_cast<std::uint32_t>(rate) * channels * 4u);
  writeU16(head, static_cast<std::uint16_t>(channels * 4u));
  writeU16(head, 32u);
  head.insert(head.end(), {'d', 'a', 't', 'a'});
  writeU32(head, dataBytes);

  std::FILE *file = std::fopen(path.c_str(), "wb");
  if (file == nullptr) return false;
  std::fwrite(head.data(), 1, head.size(), file);
  std::fwrite(interleaved.data(), sizeof(float), interleaved.size(), file);
  std::fclose(file);
  return true;
}

// 片方のスピーカーだけ叩く。戻るのは (左耳, 右耳)。
void sweep(VirtualRoomEngine &engine, const Params &params, int impulseOn, std::uint32_t frames,
           std::vector<float> &outLeft, std::vector<float> &outRight) {
  engine.reset();
  engine.applyImmediate(params);
  outLeft.assign(frames, 0.0F);
  outRight.assign(frames, 0.0F);

  std::vector<float> left(kBlock, 0.0F);
  std::vector<float> right(kBlock, 0.0F);
  std::uint32_t done = 0u;
  while (done < frames) {
    const std::uint32_t n = std::min(kBlock, frames - done);
    std::fill(left.begin(), left.end(), 0.0F);
    std::fill(right.begin(), right.end(), 0.0F);
    if (done == 0u) {
      (impulseOn == 0 ? left : right)[0] = 1.0F;
    }
    engine.process(left.data(), right.data(), n);
    for (std::uint32_t i = 0u; i < n; ++i) {
      outLeft[done + i] = left[i];
      outRight[done + i] = right[i];
    }
    done += n;
  }
}

}  // namespace

int main(int argc, char **argv) {
  const std::string path = argc > 1 ? argv[1] : "brir.wav";
  const auto frames = static_cast<std::uint32_t>(kRate * 1.0);  // 1 秒で足りる

  VirtualRoomEngine engine;
  if (!engine.prepare(kRate, kBlock)) {
    std::fprintf(stderr, "prepare に失敗\n");
    return 1;
  }
  const Params params = defaults();

  std::vector<float> ll, lr, rl, rr;
  sweep(engine, params, 0, frames, ll, lr);
  sweep(engine, params, 1, frames, rl, rr);

  std::vector<float> interleaved(static_cast<std::size_t>(frames) * 4u);
  for (std::uint32_t i = 0u; i < frames; ++i) {
    interleaved[i * 4u + 0u] = ll[i];
    interleaved[i * 4u + 1u] = lr[i];
    interleaved[i * 4u + 2u] = rl[i];
    interleaved[i * 4u + 3u] = rr[i];
  }
  if (!writeWav(path, interleaved, 4u, kRate)) {
    std::fprintf(stderr, "書けない: %s\n", path.c_str());
    return 1;
  }
  std::printf("%s に %u フレーム書いた\n", path.c_str(), frames);
  return 0;
}
