// Virtual Room の幾何・材質・経路生成。docs/virtual-room-design.md の §15-§24、§53。
//
// ここは制御スレッドだけが呼ぶ（§26）。音のスレッドは出来上がった RenderState しか
// 見ない。だから三角関数も pow もここへ集める。確保も例外も無い。
//
// 数式の出どころ（§60.6。citation であって帰属ではない）:
//   image-source method          Allen & Berkley 1979
//   Eyring の残響式              Eyring 1930
//   頭部陰影 / 耳介の構造モデル  Brown & Duda 1998
//   feedback delay network       Jot & Chaigne 1991
//   4 点 Lagrange 補間           Laakso et al. 1996

#ifndef EFFETUNE_PLUGINS_SPATIAL_VIRTUAL_ROOM_MODEL_H
#define EFFETUNE_PLUGINS_SPATIAL_VIRTUAL_ROOM_MODEL_H

#include "VirtualRoomPluginParams.h"

#include "effetune/dsp/xorshift_rng.h"

#include <array>
#include <cmath>
#include <cstdint>

namespace effetune::plugins::spatial {

using Params = generated::VirtualRoomPluginParams;
using Range = generated::VirtualRoomPluginRange;

inline constexpr double kSpeedOfSound = 343.0;  // m/s、20 度
inline constexpr double kPi = 3.14159265358979323846;

inline constexpr std::uint32_t kBandCount = 3u;    // 低 / 中 / 高（§19）
inline constexpr std::uint32_t kSourceCount = 2u;  // 仮想スピーカー L / R
inline constexpr std::uint32_t kEarCount = 2u;
inline constexpr std::uint32_t kMaxImageOrder = 2u;  // §18。3 次以降は late へ渡す
inline constexpr std::uint32_t kMaxImages = 25u;     // |mx|+|my|+|mz| <= 2 の数
inline constexpr std::uint32_t kFirstOrderImages = 7u;
inline constexpr std::uint32_t kMaxPaths = kMaxImages * kSourceCount * kEarCount;
inline constexpr std::uint32_t kPinnaTaps = 2u;  // §17
inline constexpr std::uint32_t kFdnLines = 16u;  // §20
inline constexpr std::uint32_t kModelVersion = 1u;  // §13

// 帯域の境目。complementary な 1 次フィルタで割る（low = LP(f1)、
// mid = LP(f2)-LP(f1)、high = x-LP(f2)）ので足すと入力へ完全に戻り、
// 3 帯域へゲインを掛けた結果はそのまま 2 段のシェルビングになる。
// §19 が言う「1 本の path につきシェルフ 2 つ程度」を、path ごとに
// フィルタを持たせずに音源側で 1 回だけ割ることで実現している。
inline constexpr double kBandSplitLow = 300.0;
inline constexpr double kBandSplitHigh = 3000.0;

// 壁とリスナーの間に最低これだけ空ける（§53）。耳は頭の半径ぶん外側に出るので、
// 半径の上限 0.11 m より大きく取る。
inline constexpr double kWallMargin = 0.2;

// 音源からの距離がこれより近いと 1/r が暴れる。
inline constexpr double kMinRadius = 0.12;

struct Material {
  float alpha[kBandCount];  // 吸音率。低 / 中 / 高
};

// 一般に公開されている吸音率の代表値から起こした表（§60.7）。
// 外部のデータセットを写したものではない。並びは effect.json の values と同じ。
// Drywall の低域が高いのは石膏ボードが面で共振して低音を吸うため。
inline constexpr Material kMaterials[] = {
    {{0.02F, 0.03F, 0.04F}},  // Concrete
    {{0.03F, 0.04F, 0.06F}},  // Painted Wall
    {{0.29F, 0.07F, 0.09F}},  // Drywall
    {{0.15F, 0.10F, 0.10F}},  // Wood
    {{0.18F, 0.05F, 0.02F}},  // Glass
    {{0.14F, 0.55F, 0.65F}},  // Heavy Curtain
    {{0.08F, 0.30F, 0.60F}},  // Carpet
    {{0.25F, 0.85F, 0.75F}},  // Acoustic Panel
};
static_assert(sizeof(kMaterials) / sizeof(kMaterials[0]) == Range::kSideMaterialCount);

// 耳介。Brown & Duda の構造モデルの短い tap 列を 2 本へ絞ったもの。
// 遅れは 44.1 kHz のサンプル数で書かれているので秒へ直して持つ。
// 高域だけへ掛ける（耳介の効きは 4 kHz 以上）。
struct PinnaTap {
  double gain;       // rho
  double amplitude;  // A
  double offset;     // B
  double elevation;  // D
};
inline constexpr PinnaTap kPinnaModel[kPinnaTaps] = {
    {0.50, 1.0, 2.0, 1.0},
    {-1.00, 5.0, 4.0, 0.5},
};
inline constexpr double kPinnaReferenceRate = 44100.0;

// ---------------------------------------------------------------- 像の並び

struct ImageIndex {
  std::int8_t mx;
  std::int8_t my;
  std::int8_t mz;
};

constexpr int absInt(int v) noexcept { return v < 0 ? -v : v; }

// 次数の小さい順に並べる。先頭 7 つが直接音 + 1 次なので、
// First Order のときは頭から 7 つだけ使えばよい（§11 Rendering）。
constexpr std::array<ImageIndex, kMaxImages> makeImageTable() noexcept {
  std::array<ImageIndex, kMaxImages> table{};
  std::uint32_t count = 0u;
  const int limit = static_cast<int>(kMaxImageOrder);
  for (int order = 0; order <= limit; ++order) {
    for (int mx = -limit; mx <= limit; ++mx) {
      for (int my = -limit; my <= limit; ++my) {
        for (int mz = -limit; mz <= limit; ++mz) {
          if (absInt(mx) + absInt(my) + absInt(mz) != order) {
            continue;
          }
          table[count++] = {static_cast<std::int8_t>(mx), static_cast<std::int8_t>(my),
                            static_cast<std::int8_t>(mz)};
        }
      }
    }
  }
  return table;
}
inline constexpr std::array<ImageIndex, kMaxImages> kImageTable = makeImageTable();
static_assert(kImageTable[0].mx == 0 && kImageTable[0].my == 0 && kImageTable[0].mz == 0);

// 像の座標。m が偶数なら平行移動、奇数なら折り返し。
constexpr double mirrorCoordinate(int m, double position, double length) noexcept {
  return (m & 1) != 0 ? (static_cast<double>(m + 1) * length - position)
                      : (static_cast<double>(m) * length + position);
}

// その軸で負側の壁・正側の壁に何回当たるか。
constexpr void wallHits(int m, int &negative, int &positive) noexcept {
  const int magnitude = absInt(m);
  const int high = (magnitude + 1) / 2;
  const int low = magnitude / 2;
  negative = m < 0 ? high : low;
  positive = m < 0 ? low : high;
}

// ---------------------------------------------------------------- 状態の器

// 1 本の direct / early path（ある像から片方の耳へ）。
// path ごとのフィルタ状態は持たない。持つと §29 の差し替えで
// 古い状態と新しい状態が混ざり、block 長で結果が変わる。
struct PathState {
  float delay;  // サンプル。小数のまま
  float band[kBandCount];
  float pinnaDelay[kPinnaTaps];
  float pinnaGain[kPinnaTaps];
};

// 音のスレッドが見る唯一のもの（§27）。POD で、指す先を持たない。
struct RenderState {
  std::uint32_t imagesPerSource;  // 7 か 25
  PathState path[kMaxPaths];      // [耳][音源][像]

  std::uint32_t fdnDelay[kFdnLines];     // 内部レートのサンプル
  float fdnBand[kFdnLines][kBandCount];  // 帰還ゲイン
  float fdnInput[kFdnLines][kSourceCount];
  float fdnOutput[kEarCount][kFdnLines];
  float preDelay;       // mixing time。出力レートのサンプル
  std::uint32_t seed;   // 変わったら late だけ作り直す（§32）
  float outputGain;     // 線形
  float rt60[kBandCount];
  float mixingTime;     // 秒
};

constexpr std::uint32_t pathIndex(std::uint32_t ear, std::uint32_t source,
                                  std::uint32_t image) noexcept {
  return (ear * kSourceCount + source) * kMaxImages + image;
}

// ---------------------------------------------------------------- 幾何

// 座標系。x = 幅、y = 奥行き、z = 高さ。単位は m。
//   x=0 / x=W   左右の側壁（どちらも Side Walls）
//   y=0         後ろの壁（Rear Wall）
//   y=D         前の壁（Front Wall。スピーカーはこちら側）
//   z=0 / z=H   床 / 天井
// リスナーは +y を向き、耳は x 軸上に並ぶ。
//
// **ly は後ろの壁からの割合。**§54 の既定 36% はこの向きでないと成り立たない。
// 前の壁から 36% だと 3.6 m の部屋でリスナーが前の壁から 1.30 m に座り、
// 1.8 m のスピーカーが前の壁を突き抜ける。後ろから 36% なら前の壁まで 2.30 m で、
// スピーカーは前の壁の 0.74 m 手前に立つ。
struct Geometry {
  double width;
  double depth;
  double height;
  double listener[3];
  double ear[kEarCount][3];
  double source[kSourceCount][3];
  double headRadius;
  double sourceDistance;  // §53 で詰めたあとの実効距離
};

inline double clampDouble(double value, double low, double high) noexcept {
  return value < low ? low : (value > high ? high : value);
}

// NaN と範囲外を落とす。保存値そのものは書き換えない（§53）。
inline double sanitize(float raw, double low, double high) noexcept {
  const double value = static_cast<double>(raw);
  if (!(value == value)) {
    return low;
  }
  return clampDouble(value, low, high);
}

inline std::uint32_t materialIndex(float raw) noexcept {
  const double value = static_cast<double>(raw);
  if (!(value == value) || value <= 0.0) {
    return 0u;
  }
  const std::uint32_t index = static_cast<std::uint32_t>(value + 0.5);
  return index >= Range::kSideMaterialCount ? Range::kSideMaterialCount - 1u : index;
}

inline Geometry buildGeometry(const Params &params) noexcept {
  Geometry geometry{};
  geometry.width = sanitize(params.roomWidth, Range::kRoomWidthMin, Range::kRoomWidthMax);
  geometry.depth = sanitize(params.roomDepth, Range::kRoomDepthMin, Range::kRoomDepthMax);
  geometry.height = sanitize(params.roomHeight, Range::kRoomHeightMin, Range::kRoomHeightMax);
  geometry.headRadius =
      sanitize(params.headRadius, Range::kHeadRadiusMin, Range::kHeadRadiusMax) * 0.01;

  const double fractionX =
      sanitize(params.listenerX, Range::kListenerXMin, Range::kListenerXMax) * 0.01;
  const double fractionY =
      sanitize(params.listenerY, Range::kListenerYMin, Range::kListenerYMax) * 0.01;
  const double earHeight =
      sanitize(params.listenerHeight, Range::kListenerHeightMin, Range::kListenerHeightMax);

  // 壁から margin だけ内側へ詰める。保存値は触らないので、部屋を広げれば元へ戻る。
  const double marginX = clampDouble(kWallMargin, 0.0, geometry.width * 0.45);
  const double marginY = clampDouble(kWallMargin, 0.0, geometry.depth * 0.45);
  const double marginZ = clampDouble(kWallMargin, 0.0, geometry.height * 0.45);
  geometry.listener[0] =
      clampDouble(fractionX * geometry.width, marginX, geometry.width - marginX);
  geometry.listener[1] =
      clampDouble(fractionY * geometry.depth, marginY, geometry.depth - marginY);
  geometry.listener[2] = clampDouble(earHeight, marginZ, geometry.height - marginZ);

  for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
    const double side = ear == 0u ? -1.0 : 1.0;  // 0 = 左耳
    geometry.ear[ear][0] =
        clampDouble(geometry.listener[0] + side * geometry.headRadius, 0.01, geometry.width - 0.01);
    geometry.ear[ear][1] = geometry.listener[1];
    geometry.ear[ear][2] = geometry.listener[2];
  }

  const double azimuth =
      sanitize(params.speakerAngle, Range::kSpeakerAngleMin, Range::kSpeakerAngleMax) * kPi /
      180.0;
  const double elevation =
      sanitize(params.speakerElevation, Range::kSpeakerElevationMin, Range::kSpeakerElevationMax) *
      kPi / 180.0;
  const double requested =
      sanitize(params.speakerDistance, Range::kSpeakerDistanceMin, Range::kSpeakerDistanceMax);

  // §53。部屋を狭めるとスピーカーが壁の外へ出るので、実効距離だけ詰める。
  double direction[kSourceCount][3];
  for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
    const double side = source == 0u ? -1.0 : 1.0;  // 0 = 左スピーカー
    direction[source][0] = side * std::cos(elevation) * std::sin(azimuth);
    direction[source][1] = std::cos(elevation) * std::cos(azimuth);
    direction[source][2] = std::sin(elevation);
  }
  const double bounds[3] = {geometry.width, geometry.depth, geometry.height};
  const double margins[3] = {marginX, marginY, marginZ};
  double allowed = requested;
  for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
    for (std::uint32_t axis = 0u; axis < 3u; ++axis) {
      const double step = direction[source][axis];
      if (step > 1e-9) {
        allowed = clampDouble(
            (bounds[axis] - margins[axis] - geometry.listener[axis]) / step, 0.0, allowed);
      } else if (step < -1e-9) {
        allowed =
            clampDouble((margins[axis] - geometry.listener[axis]) / step, 0.0, allowed);
      }
    }
  }
  geometry.sourceDistance = clampDouble(allowed, kMinRadius, requested);

  for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
    for (std::uint32_t axis = 0u; axis < 3u; ++axis) {
      geometry.source[source][axis] =
          geometry.listener[axis] + direction[source][axis] * geometry.sourceDistance;
    }
  }
  return geometry;
}

// ---------------------------------------------------------------- 残響

struct Acoustics {
  double rt60[kBandCount];     // 秒。DecayScale を掛けたあと
  double absorption[kBandCount];
  double surface;              // m^2
  double volume;               // m^3
  double meanFreePath;         // m
  double mixingTime;           // 秒
};

inline Acoustics buildAcoustics(const Geometry &geometry, const Params &params) noexcept {
  Acoustics acoustics{};
  const Material &side = kMaterials[materialIndex(params.sideMaterial)];
  const Material &front = kMaterials[materialIndex(params.frontMaterial)];
  const Material &rear = kMaterials[materialIndex(params.rearMaterial)];
  const Material &floor = kMaterials[materialIndex(params.floorMaterial)];
  const Material &ceiling = kMaterials[materialIndex(params.ceilingMaterial)];

  const double sideArea = geometry.depth * geometry.height * 2.0;
  const double endArea = geometry.width * geometry.height;
  const double capArea = geometry.width * geometry.depth;
  acoustics.volume = geometry.width * geometry.depth * geometry.height;
  acoustics.surface = sideArea + endArea * 2.0 + capArea * 2.0;
  acoustics.meanFreePath = 4.0 * acoustics.volume / acoustics.surface;

  const double decay =
      sanitize(params.decayScale, Range::kDecayScaleMin, Range::kDecayScaleMax);
  for (std::uint32_t band = 0u; band < kBandCount; ++band) {
    const double weighted = sideArea * side.alpha[band] + endArea * front.alpha[band] +
                            endArea * rear.alpha[band] + capArea * floor.alpha[band] +
                            capArea * ceiling.alpha[band];
    const double mean = clampDouble(weighted / acoustics.surface, 0.001, 0.99);
    acoustics.absorption[band] = mean;
    // Eyring（§21）。Sabine だと吸音の大きい部屋で残響が長く出すぎる。
    const double eyring =
        0.161 * acoustics.volume / (-acoustics.surface * std::log(1.0 - mean));
    acoustics.rt60[band] = clampDouble(eyring * decay, 0.05, 20.0);
  }

  // §23。平均自由行程から反射の間隔を出し、その 6 倍を混合時間とする。
  const double reflectionInterval = acoustics.meanFreePath / kSpeedOfSound;
  acoustics.mixingTime = clampDouble(6.0 * reflectionInterval, 0.015, 0.100);
  return acoustics;
}

// ---------------------------------------------------------------- 頭部

// Brown & Duda の頭部陰影。低域 1、高域 alpha の 1 次シェルフなので、
// 3 帯域のゲインへそのまま畳める（§17、§19）。
// cosine は耳の外向き法線と音源方向の内積。
inline double headShadowAlpha(double cosine) noexcept {
  constexpr double kAlphaMin = 0.1;
  const double theta = std::acos(clampDouble(cosine, -1.0, 1.0));
  return (1.0 + kAlphaMin) * 0.5 + (1.0 - kAlphaMin) * 0.5 * std::cos(theta * (180.0 / 150.0));
}

// ---------------------------------------------------------------- late の構造

// 16 本の遅延を対数等間隔に置き、seed で揺らす。乱数で全部決めると
// 固まる場所ができて late が金属的になる。奇数・相異にして周期の重なりを避ける。
inline void buildFdnDelays(const Acoustics &acoustics, double internalRate, std::uint32_t seed,
                           std::uint32_t *out) noexcept {
  effetune::dsp::XorShiftRng rng(seed, seed ^ 0x9E3779B9u);
  const double base = acoustics.meanFreePath / kSpeedOfSound;
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    const double position = (static_cast<double>(line) + 0.5) / static_cast<double>(kFdnLines);
    const double spread = 0.55 * std::pow(2.2 / 0.55, position);
    const double jitter = 1.0 + 0.12 * rng.nextFloatSigned();
    const double seconds = clampDouble(base * spread * jitter, 0.008, 0.120);
    std::uint32_t samples = static_cast<std::uint32_t>(seconds * internalRate);
    samples |= 1u;
    if (samples < 9u) {
      samples = 9u;
    }
    bool collided = true;
    while (collided) {
      collided = false;
      for (std::uint32_t earlier = 0u; earlier < line; ++earlier) {
        if (out[earlier] == samples) {
          samples += 2u;
          collided = true;
          break;
        }
      }
    }
    out[line] = samples;
  }
}

// 2 本の符号ベクトルを直交させる。16 個のうち 8 個だけ符号を反転させれば
// 内積はちょうど 0 になる。乱数任せだと相関が残って左右が寄る。
inline void buildOrthogonalSigns(effetune::dsp::XorShiftRng &rng, double magnitude, float *first,
                                 float *second) noexcept {
  std::uint32_t order[kFdnLines];
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    first[line] = (rng.nextU64() & 1u) != 0u ? static_cast<float>(magnitude)
                                             : static_cast<float>(-magnitude);
    second[line] = first[line];
    order[line] = line;
  }
  for (std::uint32_t line = kFdnLines; line > 1u; --line) {
    const std::uint32_t pick = static_cast<std::uint32_t>(rng.nextU64() % line);
    const std::uint32_t swap = order[line - 1u];
    order[line - 1u] = order[pick];
    order[pick] = swap;
  }
  for (std::uint32_t index = 0u; index < kFdnLines / 2u; ++index) {
    second[order[index]] = -second[order[index]];
  }
}

// ---------------------------------------------------------------- 本体

inline std::uint32_t lateRateDivider(double sampleRate) noexcept {
  if (sampleRate <= 50000.0) {
    return 1u;
  }
  return sampleRate <= 100000.0 ? 2u : 4u;  // §25
}

inline std::uint32_t packedSeed(const Params &params) noexcept {
  const double low = sanitize(params.seedLow, Range::kSeedLowMin, Range::kSeedLowMax);
  const double high = sanitize(params.seedHigh, Range::kSeedHighMin, Range::kSeedHighMax);
  return (static_cast<std::uint32_t>(high + 0.5) << 16u) |
         static_cast<std::uint32_t>(low + 0.5);
}

// パラメータ一式から、音のスレッドがそのまま使える形を組む。
// 呼ぶのは制御スレッドか offline の export。確保も lock もしない。
inline void buildRenderState(const Params &params, double sampleRate, RenderState &state) noexcept {
  const Geometry geometry = buildGeometry(params);
  const Acoustics acoustics = buildAcoustics(geometry, params);

  const double roomAmount =
      sanitize(params.roomAmount, Range::kRoomAmountMin, Range::kRoomAmountMax) * 0.01;
  const double pinnaAmount =
      sanitize(params.pinnaAmount, Range::kPinnaAmountMin, Range::kPinnaAmountMax) * 0.01;
  const double shadowAmount =
      sanitize(params.headShadowAmount, Range::kHeadShadowAmountMin,
               Range::kHeadShadowAmountMax) *
      0.01;
  const double order =
      sanitize(params.earlyOrder, 0.0, static_cast<double>(Range::kEarlyOrderCount - 1u));
  state.imagesPerSource = order < 0.5 ? kFirstOrderImages : kMaxImages;

  const Material &side = kMaterials[materialIndex(params.sideMaterial)];
  const Material &front = kMaterials[materialIndex(params.frontMaterial)];
  const Material &rear = kMaterials[materialIndex(params.rearMaterial)];
  const Material &floor = kMaterials[materialIndex(params.floorMaterial)];
  const Material &ceiling = kMaterials[materialIndex(params.ceilingMaterial)];

  // 反射率。rho = sqrt(1 - alpha)（§19）
  double reflect[5][kBandCount];
  for (std::uint32_t band = 0u; band < kBandCount; ++band) {
    reflect[0][band] = std::sqrt(clampDouble(1.0 - side.alpha[band], 0.0, 1.0));
    reflect[1][band] = std::sqrt(clampDouble(1.0 - rear.alpha[band], 0.0, 1.0));
    reflect[2][band] = std::sqrt(clampDouble(1.0 - front.alpha[band], 0.0, 1.0));
    reflect[3][band] = std::sqrt(clampDouble(1.0 - floor.alpha[band], 0.0, 1.0));
    reflect[4][band] = std::sqrt(clampDouble(1.0 - ceiling.alpha[band], 0.0, 1.0));
  }

  const double pinnaScale = sampleRate / kPinnaReferenceRate;
  double sourceNormalization[kSourceCount];

  for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
    // §16。直接音の両耳エネルギーを 1 に揃える。ILD はそのまま残る。
    double energy = 0.0;
    for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
      double squared = 0.0;
      for (std::uint32_t axis = 0u; axis < 3u; ++axis) {
        const double delta = geometry.source[source][axis] - geometry.ear[ear][axis];
        squared += delta * delta;
      }
      const double gain = 1.0 / clampDouble(std::sqrt(squared), kMinRadius, 1e6);
      energy += gain * gain;
    }
    sourceNormalization[source] = 1.0 / std::sqrt(energy > 1e-12 ? energy : 1e-12);

    for (std::uint32_t image = 0u; image < kMaxImages; ++image) {
      const ImageIndex &index = kImageTable[image];
      const double position[3] = {
          mirrorCoordinate(index.mx, geometry.source[source][0], geometry.width),
          mirrorCoordinate(index.my, geometry.source[source][1], geometry.depth),
          mirrorCoordinate(index.mz, geometry.source[source][2], geometry.height)};

      int sideHits = absInt(index.mx);
      int rearHits = 0;
      int frontHits = 0;
      int floorHits = 0;
      int ceilingHits = 0;
      wallHits(index.my, rearHits, frontHits);
      wallHits(index.mz, floorHits, ceilingHits);

      double surfaceResponse[kBandCount];
      for (std::uint32_t band = 0u; band < kBandCount; ++band) {
        double response = 1.0;
        for (int hit = 0; hit < sideHits; ++hit) {
          response *= reflect[0][band];
        }
        for (int hit = 0; hit < rearHits; ++hit) {
          response *= reflect[1][band];
        }
        for (int hit = 0; hit < frontHits; ++hit) {
          response *= reflect[2][band];
        }
        for (int hit = 0; hit < floorHits; ++hit) {
          response *= reflect[3][band];
        }
        for (int hit = 0; hit < ceilingHits; ++hit) {
          response *= reflect[4][band];
        }
        surfaceResponse[band] = response;
      }
      // 直接音に Room Amount は掛けない（§10）。
      const double amount = image == 0u ? 1.0 : roomAmount;

      for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
        PathState &path = state.path[pathIndex(ear, source, image)];
        double delta[3];
        double squared = 0.0;
        for (std::uint32_t axis = 0u; axis < 3u; ++axis) {
          delta[axis] = position[axis] - geometry.ear[ear][axis];
          squared += delta[axis] * delta[axis];
        }
        const double radius = clampDouble(std::sqrt(squared), kMinRadius, 1e6);
        path.delay = static_cast<float>(radius / kSpeedOfSound * sampleRate);

        // 耳の外向き法線との角度。0 が同側。
        const double outward = ear == 0u ? -1.0 : 1.0;
        const double cosine = outward * delta[0] / radius;
        const double alpha = headShadowAlpha(cosine);
        const double level = sourceNormalization[source] * amount / radius;
        path.band[0] = static_cast<float>(level * surfaceResponse[0]);
        path.band[1] =
            static_cast<float>(level * surfaceResponse[1] * std::pow(alpha, shadowAmount * 0.5));
        path.band[2] =
            static_cast<float>(level * surfaceResponse[2] * std::pow(alpha, shadowAmount));

        // §17。耳介は高域だけへ、主 tap からの短い遅れとして足す。
        const double azimuth = std::acos(clampDouble(cosine, -1.0, 1.0));
        const double elevationDeg =
            std::asin(clampDouble(delta[2] / radius, -1.0, 1.0)) * 180.0 / kPi;
        for (std::uint32_t tap = 0u; tap < kPinnaTaps; ++tap) {
          const PinnaTap &model = kPinnaModel[tap];
          const double offset =
              model.amplitude * std::cos(azimuth * 0.5) *
                  std::sin(model.elevation * (90.0 - elevationDeg) * kPi / 180.0) +
              model.offset;
          path.pinnaDelay[tap] =
              static_cast<float>(static_cast<double>(path.delay) + offset * pinnaScale);
          path.pinnaGain[tap] =
              static_cast<float>(model.gain * pinnaAmount * static_cast<double>(path.band[2]));
        }
      }
    }
  }

  // 使わない像は 0 にしておく。同じ seed / params なら同じ形になることを
  // 数で確かめられるようにする（§56）。
  for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      for (std::uint32_t image = state.imagesPerSource; image < kMaxImages; ++image) {
        state.path[pathIndex(ear, source, image)] = PathState{};
      }
    }
  }

  // ------------------------------------------------------------ late
  const std::uint32_t seed = packedSeed(params);
  const double internalRate = sampleRate / static_cast<double>(lateRateDivider(sampleRate));
  state.seed = seed;
  buildFdnDelays(acoustics, internalRate, seed, state.fdnDelay);

  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    const double seconds = static_cast<double>(state.fdnDelay[line]) / internalRate;
    for (std::uint32_t band = 0u; band < kBandCount; ++band) {
      // §22。3T/RT60 で -60 dB になる。
      const double gain = std::pow(10.0, -3.0 * seconds / acoustics.rt60[band]);
      state.fdnBand[line][band] = static_cast<float>(clampDouble(gain, 0.0, 0.9999));
    }
  }

  effetune::dsp::XorShiftRng rng(seed ^ 0x5BF03635u, seed + 0x85EBCA6Bu);
  const double unit = 1.0 / std::sqrt(static_cast<double>(kFdnLines));
  float inputSigns[kSourceCount][kFdnLines];
  buildOrthogonalSigns(rng, 1.0, inputSigns[0], inputSigns[1]);
  float outputLeft[kFdnLines];
  float outputRight[kFdnLines];
  buildOrthogonalSigns(rng, unit, outputLeft, outputRight);
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    state.fdnOutput[0][line] = outputLeft[line];
    state.fdnOutput[1][line] = outputRight[line];
  }

  // late の高さ。拡散音場の残響 / 直接音エネルギー比から決める。
  // R = S*alpha/(1-alpha)、比 = 16*pi*r^2/R。直接音は §16 でエネルギー 1 に
  // 揃えてあるので、この比がそのまま late の目標エネルギーになる。
  // 直交帰還の FDN は入力エネルギーを ||b||^2/(1-g^2) だけ吐くので、そこから
  // 1 本あたりの入力ゲインを逆算する。
  const double roomConstant = acoustics.surface * acoustics.absorption[1] /
                              clampDouble(1.0 - acoustics.absorption[1], 0.01, 1.0);
  const double ratio = clampDouble(
      16.0 * kPi * geometry.sourceDistance * geometry.sourceDistance / roomConstant, 0.0, 400.0);
  const double perSample = std::pow(10.0, -3.0 / (acoustics.rt60[1] * internalRate));
  const double leak = clampDouble(1.0 - perSample * perSample, 1e-9, 1.0);
  const double lateGain =
      std::sqrt(ratio * leak / static_cast<double>(kFdnLines)) * roomAmount;
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      state.fdnInput[line][source] = static_cast<float>(
          static_cast<double>(inputSigns[source][line]) * lateGain * sourceNormalization[source]);
    }
  }

  state.preDelay = static_cast<float>(acoustics.mixingTime * sampleRate);
  state.mixingTime = static_cast<float>(acoustics.mixingTime);
  for (std::uint32_t band = 0u; band < kBandCount; ++band) {
    state.rt60[band] = static_cast<float>(acoustics.rt60[band]);
  }
  const double outputDecibels =
      sanitize(params.outputGain, Range::kOutputGainMin, Range::kOutputGainMax);
  state.outputGain = static_cast<float>(std::pow(10.0, outputDecibels / 20.0));
}

}  // namespace effetune::plugins::spatial

#endif
