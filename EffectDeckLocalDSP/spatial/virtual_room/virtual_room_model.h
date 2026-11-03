// Virtual Room binaural room model.
//
// Portions derived from:
//   M0Rf30/easyeffects-presets
//   scripts/generate-synthetic-binaural-room.js
//
// Licensed under the MIT License.
// See NOTICE.md and the bundled third-party license notices.
//
// 由来の内訳（docs/virtual-room-design.md §60.4、§60.5）。**元から持ってきたもの:**
//   - 耳介の tap 表（遅れ [3,6,9,13] / ゲイン [-0.35,0.22,-0.16,0.11] / 仰角の伸び 0.004）
//   - 頭部陰影シェルフの alpha の式と ALPHA_MIN / THETA_MIN
//   - 直接音に対する残響の比（DRR）で late の高さを決める考え方と、その 8 dB
//   - 最後に 1 本のスカラーで全体を揃える（ILD / ITD を壊さない）
// **新規:** 2 次の鏡像 / 帯域ごとの材質 / Eyring の RT60 / 16 本の FDN /
//   RenderState と三重化 / 実時間の寸法変更 / BRIR 書き出し。
//
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

#include <algorithm>
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
inline constexpr std::uint32_t kPinnaTaps = 4u;  // §17
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

// 耳介の反射。Brown & Duda 構造モデル流の短い FIR。**元の JS の表そのまま。**
//
// 遅れは 48 kHz のサンプル数。3 サンプルで最初のくぼみが 8 kHz 付近に来て、
// 符号を交互にすることで 8〜16 kHz へくぼみが並ぶ。
// **ゲインは控えめにする。色を付けるためで、削るためではない。**
//
// 元は「全帯域へ畳む 1 本の FIR」で、音源にも像にも同じものを掛けている。
// 経路ごとに持たせる意味が無いので、こちらも入力段で 1 度だけ掛ける。
struct PinnaTap {
  double delay;  // 48 kHz でのサンプル数
  double gain;
};
inline constexpr PinnaTap kPinnaModel[kPinnaTaps] = {
    {3.0, -0.35},
    {6.0, 0.22},
    {9.0, -0.16},
    {13.0, 0.11},
};
inline constexpr double kPinnaReferenceRate = 48000.0;
// 仰角 1 度あたり何割引き伸ばすか。
inline constexpr double kPinnaElevationSensitivity = 0.004;

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
};

// 音のスレッドが見る唯一のもの（§27）。POD で、指す先を持たない。
struct RenderState {
  std::uint32_t imagesPerSource;  // 7 か 25
  PathState path[kMaxPaths];      // [耳][音源][像]

  std::uint32_t fdnDelay[kFdnLines];     // 内部レートのサンプル
  float fdnBand[kFdnLines][kBandCount];  // 帰還ゲイン
  float fdnInput[kFdnLines][kSourceCount];
  float fdnOutput[kEarCount][kFdnLines];
  /// FDN の入口の遅れ。出力レートのサンプル。late の鳴り始めから
  /// いちばん短い遅延線のぶんを引いたもの（B）。
  float preDelay;
  std::uint32_t seed;   // 変わったら late だけ作り直す（§32）
  /// 線形。Output Gain に**全体の正規化**を掛けたもの（§16）。
  /// 直接音だけを 1 に揃えて early と late を足すと、部屋を広げるほど大きくなる。
  float outputGain;
  float rt60[kBandCount];
  float mixingTime;     // late の鳴り始め（秒）。1 次の像の終わり

  /// 耳介の FIR。全部の経路へ同じものが掛かるので入力段で 1 度だけ適用する。
  /// delay は出力レートのサンプル（整数）。gain は 0 番が必ず 1。
  std::uint32_t pinnaDelay[kPinnaTaps + 1u];
  float pinnaGain[kPinnaTaps + 1u];
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

  // 前はここで平均自由行程の 6 倍を混合時間にしていた（§23）。late の入口は今は
  // 1 次の像の終わりで決める（buildRenderState）。6 倍だと早期反射との間が無音になった。
  return acoustics;
}

// ---------------------------------------------------------------- 頭部

// Brown & Duda の頭部陰影。低域 1、高域 alpha の 1 次シェルフなので、
// 3 帯域のゲインへそのまま畳める（§17、§19）。
// cosine は耳の外向き法線と音源方向の内積。
//
// **返す幅は 0.1 〜 2.0。**音源が耳のすぐ横に来たとき高域は 2 倍になる。
// ここを 1.0 で頭打ちにすると近い方の耳が明るくならず、両耳の差が
// レベルだけになって頭の中で鳴る。元の JS の shadowAlpha と同じ式。
inline double headShadowAlpha(double cosine) noexcept {
  constexpr double kAlphaMin = 0.1;
  constexpr double kThetaMinDegrees = 150.0;
  const double theta = std::acos(clampDouble(cosine, -1.0, 1.0)) * 180.0 / kPi;
  const double t = clampDouble(theta, 0.0, 180.0);
  return (1.0 + kAlphaMin * 0.5) +
         (1.0 - kAlphaMin * 0.5) * std::cos(t / kThetaMinDegrees * kPi);
}

// ---------------------------------------------------------------- late の構造

// 16 本の遅延を対数等間隔に置き、seed で揺らす。乱数で全部決めると
// 固まる場所ができて late が金属的になる。奇数・相異にして周期の重なりを避ける。
//
// **下限は 2.5 ms。**前は 8 ms で、既定の部屋（平均反射間隔 6.5 ms）だと
// 名目 3.7〜6.8 ms の短い 8 本が全部 8 ms へ張り付き、衝突よけで 385, 387, … 399 と
// 2 サンプルおきに積み重なっていた（stop.md の E）。8 本が 4% の中に固まると
// late が櫛形に色づくうえ、late の入口が preDelay + 8 ms まで遅れる。
//
// 揺らしは ±4%、並べたあと隣どうしを 3% 以上離す。隣の名目の比は 4^(1/16) = 9% なので、
// 揺らしを ±12% にすると順番が入れ替わって重なる。
inline constexpr double kFdnShortestSeconds = 0.0025;
inline constexpr double kFdnJitter = 0.04;
inline constexpr double kFdnMinSpacing = 0.03;

inline void buildFdnDelays(const Acoustics &acoustics, double internalRate, std::uint32_t seed,
                           std::uint32_t *out) noexcept {
  effetune::dsp::XorShiftRng rng(seed, seed ^ 0x9E3779B9u);
  const double base = acoustics.meanFreePath / kSpeedOfSound;
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    const double position = (static_cast<double>(line) + 0.5) / static_cast<double>(kFdnLines);
    const double spread = 0.55 * std::pow(2.2 / 0.55, position);
    const double jitter = 1.0 + kFdnJitter * rng.nextFloatSigned();
    const double seconds = clampDouble(base * spread * jitter, kFdnShortestSeconds, 0.120);
    out[line] = static_cast<std::uint32_t>(seconds * internalRate + 0.5) | 1u;
  }
  // 短い順に並べ、隣を 3% 以上・奇数で離す。線の並び自体に意味は無い
  // （Hadamard で全部混ぜるので、どの線がどの長さでも同じ）。
  for (std::uint32_t line = 1u; line < kFdnLines; ++line) {
    const std::uint32_t value = out[line];
    std::uint32_t at = line;
    while (at > 0u && out[at - 1u] > value) {
      out[at] = out[at - 1u];
      --at;
    }
    out[at] = value;
  }
  // 上限は engine の遅延線（0.13 秒ぶん）に収める。部屋の上限（20 x 30 x 10 m）でも
  // 名目の最長は 70 ms ほどなので、ここで頭を打つことはまず無い。
  const auto ceiling = static_cast<std::uint32_t>(0.125 * internalRate) | 1u;
  for (std::uint32_t line = 1u; line < kFdnLines; ++line) {
    const auto spaced = static_cast<std::uint32_t>(
        std::ceil(static_cast<double>(out[line - 1u]) * (1.0 + kFdnMinSpacing)));
    if (out[line] < spaced) {
      out[line] = spaced | 1u;
    }
    if (out[line] > ceiling) {
      out[line] = ceiling;
    }
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

  // 耳介の FIR。全部の経路へ同じものが掛かるので入力段で 1 度だけ適用する。
  // 仰角で少し伸びる。Pinna 0% で素通し（0 番だけが残る）。
  {
    const double elevation =
        sanitize(params.speakerElevation, Range::kSpeakerElevationMin,
                 Range::kSpeakerElevationMax);
    const double stretch =
        (1.0 + kPinnaElevationSensitivity * elevation) * sampleRate / kPinnaReferenceRate;
    state.pinnaDelay[0] = 0u;
    state.pinnaGain[0] = 1.0F;
    for (std::uint32_t tap = 0u; tap < kPinnaTaps; ++tap) {
      const double delay = kPinnaModel[tap].delay * stretch;
      state.pinnaDelay[tap + 1u] =
          static_cast<std::uint32_t>(clampDouble(delay + 0.5, 1.0, 255.0));
      state.pinnaGain[tap + 1u] = static_cast<float>(kPinnaModel[tap].gain * pinnaAmount);
    }
  }

  // 最後の正規化に使う。earlyEnergy は無相関で足したときのエネルギー
  // （中高域はこちらに近い）。低域で同相に足したときの高さは、遅れが全部
  // 決まってから複素数で足す（下の「全体の高さ」）。
  double earlyEnergy = 0.0;
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

        if (image != 0u && image < state.imagesPerSource) {
          // 3 帯域の平均で数える。帯域の割り方は足すと素通しへ戻るので、
          // これが**その経路が運ぶエネルギー**の目安になる。
          const double mean = (static_cast<double>(path.band[0]) +
                               static_cast<double>(path.band[1]) +
                               static_cast<double>(path.band[2])) /
                              3.0;
          earlyEnergy += mean * mean;
        }
      }
    }
  }

  // ------------------------------------------------------------ 共通の遅れを落とす
  //
  // **いちばん早い直接音を原点に寄せる。**部屋の中の絶対位置には意味が無く、
  // そのまま出すと 1.8 m ぶん（48 kHz で 246 サンプル ＝ 5.1 ms）まるごと
  // 遅れが増える。実時間で通す道具なので、その 5 ms は払う理由が無い。
  // 引くのは**全経路に同じ数**なので、ITD も早期反射の間隔も変わらない。
  // 元の JS も同じことをしている（dref）。
  double earliest = 1e9;
  for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      const double d = static_cast<double>(state.path[pathIndex(ear, source, 0u)].delay);
      if (d < earliest) {
        earliest = d;
      }
    }
  }
  // 4 点 Lagrange が 1 サンプル前を読むので、少し残す。
  const double shift = clampDouble(earliest - 4.0, 0.0, 1e9);
  for (std::uint32_t index = 0u; index < kMaxPaths; ++index) {
    state.path[index].delay =
        static_cast<float>(clampDouble(static_cast<double>(state.path[index].delay) - shift,
                                       2.0, 1e9));
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

  // ------------------------------------------------------------ late の入口
  //
  // **late は 1 次の像が着き終わった所から鳴らす**（stop.md の B）。
  // 前は平均自由行程の 6 倍（既定の部屋で 38.9 ms）を入口にしていたが、
  // 2 次の像でも 22.7 ms で終わるので、その間が完全な無音になっていた。
  // 1 次の終わりなら疎な 2 次の像の下を late が埋め、部屋の寸法にも付いて動く
  // （§23 の「時刻 0 から鳴らさない」「幾何から決める」はそのまま）。
  // 元の JS の固定 6 ms は使わない。
  double firstOrderEnd = 0.0;
  for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      for (std::uint32_t image = 0u; image < kFirstOrderImages; ++image) {
        firstOrderEnd = std::max(
            firstOrderEnd, static_cast<double>(state.path[pathIndex(ear, source, image)].delay));
      }
    }
  }

  // ------------------------------------------------------------ late
  const std::uint32_t seed = packedSeed(params);
  const std::uint32_t divider = lateRateDivider(sampleRate);
  const double internalRate = sampleRate / static_cast<double>(divider);
  state.seed = seed;
  buildFdnDelays(acoustics, internalRate, seed, state.fdnDelay);

  double delaySum = 0.0;
  std::uint32_t shortest = state.fdnDelay[0];
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    delaySum += static_cast<double>(state.fdnDelay[line]);
    shortest = std::min(shortest, state.fdnDelay[line]);
    const double seconds = static_cast<double>(state.fdnDelay[line]) / internalRate;
    for (std::uint32_t band = 0u; band < kBandCount; ++band) {
      // §22。3T/RT60 で -60 dB になる。
      const double gain = std::pow(10.0, -3.0 * seconds / acoustics.rt60[band]);
      state.fdnBand[line][band] = static_cast<float>(clampDouble(gain, 0.0, 0.9999));
    }
  }

  // 入口へ入れた音は、いちばん短い線のぶんだけ遅れて初めて出てくる。
  // **その長さを引いて**、late の最初の音が 1 次の終わりに揃うようにする。
  // 前は mixing time に遅延線の 8 ms を上乗せしていた。
  state.preDelay = static_cast<float>(clampDouble(
      firstOrderEnd - static_cast<double>(shortest) * static_cast<double>(divider), 1.0, 1e9));
  // mixingTime は「late の鳴り始め」（tailSeconds と画面が使う）。
  state.mixingTime = static_cast<float>(firstOrderEnd / sampleRate);
  for (std::uint32_t band = 0u; band < kBandCount; ++band) {
    state.rt60[band] = static_cast<float>(acoustics.rt60[band]);
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

  // 3 帯域の割り方（相補な 1 次）の Gram 行列。白い音を入れたとき、帯域 i と j の
  // 出力の内積がいくつになるか。1 次ローパスの応答は a(1-a)^n なので閉じた形で出る。
  // 全部足すと 1（足すと素通しへ戻る）。direct と late の**白で測ったエネルギー**を
  // 帯域ごとのゲインと減衰から出すのに使う。
  double gram[kBandCount][kBandCount];
  {
    const double a1 = 1.0 - std::exp(-2.0 * kPi * kBandSplitLow / sampleRate);
    const double a2 = 1.0 - std::exp(-2.0 * kPi * kBandSplitHigh / sampleRate);
    const auto cross = [](double x, double y) { return x * y / (1.0 - (1.0 - x) * (1.0 - y)); };
    const double r11 = cross(a1, a1);
    const double r12 = cross(a1, a2);
    const double r22 = cross(a2, a2);
    gram[0][0] = r11;
    gram[0][1] = gram[1][0] = r12 - r11;
    gram[0][2] = gram[2][0] = a1 - r12;
    gram[1][1] = r22 - 2.0 * r12 + r11;
    gram[1][2] = gram[2][1] = a2 - r22 - a1 + r12;
    gram[2][2] = 1.0 - 2.0 * a2 + r22;
  }

  // late の高さ。**直接音に対する比（DRR）で決める。**
  //
  // 前は部屋定数から 16*pi*r^2/R を出していたが、あれは実測の部屋で成り立つ式で、
  // 材質を極端にすると簡単に 2 桁ずれる。元の JS と同じく比を直に置く。
  //
  // **DRR の定義: 音源ごとに、両耳の direct エネルギーの和 / 両耳の late エネルギーの和。**
  // 100% で 8 dB。Room Amount は像と同じく振幅に掛けるので、エネルギー比には 2 乗で効き、
  // 200% で late が +6 dB（DRR は約 2 dB）。前のコメントは「+3 dB」と書いていたが、
  // 式は前から 2 乗だった。像（early）も振幅で 2 倍なので、早期と late の釣り合いが崩れない。
  //
  // FDN が吐くエネルギー（1 耳）は ||b||^2 ||c||^2 / (Σd (1 - p^2))（stop.md の A）。
  // 遅延線が d_i サンプルあると、入れたエネルギーは Σd_i 個の枠へ散って、1 サンプルごとに
  // p^2 ずつ減る。||c||^2 = 1（±1/4 が 16 本）、b = lateGain * (±1)。
  // **前の式は Σd が抜けていて、late が 39 dB 足りなかった。**
  //
  // 帯域ごとに減り方が違う（材質で RT60 が帯域ごとに違う）ので、白で測ったエネルギーは
  // Σ_ij G_ij / (Σd (1 - p_i p_j)) になる。direct も同じ G で測る（頭部陰影の帯域ゲインが効く）。
  // こうしておくと、BRIR を白で測った DRR が狙いの値に乗る。
  constexpr double kDirectToReverbDecibels = 8.0;
  const double lateRatio =
      std::pow(10.0, -kDirectToReverbDecibels / 10.0) * roomAmount * roomAmount;
  double decay[kBandCount];
  for (std::uint32_t band = 0u; band < kBandCount; ++band) {
    decay[band] = std::pow(10.0, -3.0 / (acoustics.rt60[band] * internalRate));
  }
  // lateGain = 1 のときの 1 耳の late エネルギー（白）。
  double latePerUnit = 0.0;
  for (std::uint32_t i = 0u; i < kBandCount; ++i) {
    for (std::uint32_t j = 0u; j < kBandCount; ++j) {
      latePerUnit += gram[i][j] / clampDouble(1.0 - decay[i] * decay[j], 1e-9, 1.0);
    }
  }
  latePerUnit *= static_cast<double>(kFdnLines) / delaySum;

  double lateGain[kSourceCount];
  for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
    double direct = 0.0;
    for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
      const PathState &path = state.path[pathIndex(ear, source, 0u)];
      for (std::uint32_t i = 0u; i < kBandCount; ++i) {
        for (std::uint32_t j = 0u; j < kBandCount; ++j) {
          direct += static_cast<double>(path.band[i]) * gram[i][j] *
                    static_cast<double>(path.band[j]);
        }
      }
    }
    // 両耳で direct * lateRatio、1 耳ではその半分。
    lateGain[source] = std::sqrt(direct * lateRatio * 0.5 / latePerUnit);
  }
  for (std::uint32_t line = 0u; line < kFdnLines; ++line) {
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      state.fdnInput[line][source] =
          static_cast<float>(static_cast<double>(inputSigns[source][line]) * lateGain[source]);
    }
  }

  // ------------------------------------------------------------ 全体の高さ
  //
  // §16 で揃えているのは**直接音だけ**。そこへ early と late を足すので、
  // 部屋を広げるほど・材質を硬くするほど出力が大きくなっていた。
  // 元の JS は最後に 1 本のスカラーで全体を揃えている（ILD も ITD も壊れない）。
  // こちらは実時間なので peak では測れない。エネルギーの和で割る。
  //
  // 耳介の FIR も全帯域に掛かるぶんだけ足し引きするので、その利得も入れる。
  double pinnaEnergy = 0.0;
  for (std::uint32_t tap = 0u; tap <= kPinnaTaps; ++tap) {
    const double g = static_cast<double>(state.pinnaGain[tap]);
    pinnaEnergy += g * g;
  }

  // 1 耳・1 音源あたりの late エネルギー（中域の減衰で数える。early の数え方に揃える）と、
  // L=R の低音で 1 耳に積もる late エネルギー（低域の減衰で数え、2 音源ぶん足す）。
  double lateEnergy = 0.0;
  double lateLowEnergy = 0.0;
  {
    const double mid = clampDouble(1.0 - decay[1] * decay[1], 1e-9, 1.0);
    const double low = clampDouble(1.0 - decay[0] * decay[0], 1e-9, 1.0);
    for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
      const double fed =
          lateGain[source] * lateGain[source] * static_cast<double>(kFdnLines) / delaySum;
      lateEnergy += fed / mid * 0.5;
      lateLowEnergy += fed / low;
    }
  }

  // 無相関で足したときの高さ。中高域はこちらが効く。
  // 単位は「direct の両耳エネルギー = 1」。early は 2 音源 x 2 耳ぶん足してあるので半分、
  // late は 1 耳ぶんなので 2 倍して両耳にする。
  const double incoherent =
      std::sqrt(clampDouble((1.0 + earlyEnergy * 0.5 + lateEnergy * 2.0) *
                                clampDouble(pinnaEnergy, 0.25, 4.0),
                            1e-6, 1e6));

  // 低域で同相に足したときの高さ（stop.md の C）。**左右そろった低音がいちばん大きくなる**ので、
  // 両方の音源を耳ごとに足して、大きい方の耳を取る。
  //
  // 前は「全部の像が同じ向きに積もる」として帯域ゲインを単純に足していた。ここでは
  // 40〜300 Hz の対数で 24 点、実際の遅れと 3 帯域の応答・耳介の FIR から複素数で足す。
  // late は位相がばらばらなので、低域の減衰で数えたエネルギーを足す。
  //
  // **下を 40 Hz で切るのは測って決めた。**像は 0〜23 ms に散っているが、40 Hz より下では
  // 周期の方が長く、本当にほぼ同相に積もる（stop.md の C の「300 Hz 以下でも同相に
  // ならない」は 40 Hz より上でしか成り立たない）。既定の部屋（2 次）で、
  //   20 Hz から測る   rms は入力の -10.4 dB、20〜35 Hz の同相の正弦は +0.1 dB
  //   40 Hz から測る   rms は入力の  -6.4 dB、40〜120 Hz は +0.2 dB、20〜35 Hz は +4.1 dB
  //   低域を見ない     rms は入力の  +1.2 dB、40 Hz で +7.7 dB、曲で 0 dBFS 超えが 6 個
  // 40 Hz より下は既定の部屋のいちばん低い軸モード（41 Hz）より下で、2 次で打ち切った像の和は
  // 密閉した箱の圧力のように効く。そこまで守ると全体が 4 dB 余計に小さくなる。
  // **20〜35 Hz を -1 dBFS の同相で入れると +4 dB まで出る**のは承知の上（stop.md）。
  double coherent = 0.0;
  {
    constexpr std::uint32_t kProbes = 24u;
    constexpr double kProbeLowest = 40.0;
    const double a1 = 1.0 - std::exp(-2.0 * kPi * kBandSplitLow / sampleRate);
    const double a2 = 1.0 - std::exp(-2.0 * kPi * kBandSplitHigh / sampleRate);
    for (std::uint32_t probe = 0u; probe < kProbes; ++probe) {
      const double frequency =
          kProbeLowest *
          std::pow(300.0 / kProbeLowest, static_cast<double>(probe) / (kProbes - 1u));
      const double omega = 2.0 * kPi * frequency / sampleRate;
      const double zr = std::cos(omega);
      const double zi = -std::sin(omega);
      // 1 次ローパス a / (1 - (1-a) z^-1)
      const auto lowpass = [&](double a, double &re, double &im) {
        const double dr = 1.0 - (1.0 - a) * zr;
        const double di = -(1.0 - a) * zi;
        const double mag = dr * dr + di * di;
        re = a * dr / mag;
        im = -a * di / mag;
      };
      double l1r = 0.0;
      double l1i = 0.0;
      double l2r = 0.0;
      double l2i = 0.0;
      lowpass(a1, l1r, l1i);
      lowpass(a2, l2r, l2i);
      const double bandRe[kBandCount] = {l1r, l2r - l1r, 1.0 - l2r};
      const double bandIm[kBandCount] = {l1i, l2i - l1i, -l2i};

      double pinnaRe = 0.0;
      double pinnaIm = 0.0;
      for (std::uint32_t tap = 0u; tap <= kPinnaTaps; ++tap) {
        const double phase = omega * static_cast<double>(state.pinnaDelay[tap]);
        pinnaRe += static_cast<double>(state.pinnaGain[tap]) * std::cos(phase);
        pinnaIm -= static_cast<double>(state.pinnaGain[tap]) * std::sin(phase);
      }
      const double pinna2 = pinnaRe * pinnaRe + pinnaIm * pinnaIm;

      for (std::uint32_t ear = 0u; ear < kEarCount; ++ear) {
        double sumRe = 0.0;
        double sumIm = 0.0;
        for (std::uint32_t source = 0u; source < kSourceCount; ++source) {
          for (std::uint32_t image = 0u; image < state.imagesPerSource; ++image) {
            const PathState &path = state.path[pathIndex(ear, source, image)];
            double re = 0.0;
            double im = 0.0;
            for (std::uint32_t band = 0u; band < kBandCount; ++band) {
              re += static_cast<double>(path.band[band]) * bandRe[band];
              im += static_cast<double>(path.band[band]) * bandIm[band];
            }
            const double phase = omega * static_cast<double>(path.delay);
            const double c = std::cos(phase);
            const double sn = -std::sin(phase);
            sumRe += re * c - im * sn;
            sumIm += re * sn + im * c;
          }
        }
        coherent = std::max(coherent, (sumRe * sumRe + sumIm * sumIm + lateLowEnergy) * pinna2);
      }
    }
    coherent = std::sqrt(coherent);
  }

  // **大きい方で割る。**こうすると「バイパスより大きくならない」が成り立つ。
  // 低音が同相で来たときがいちばん厳しく、そこで 0 dBFS を超えていた。
  const double normalize = 1.0 / clampDouble(std::max(incoherent, coherent), 1e-6, 1e6);

  const double outputDecibels =
      sanitize(params.outputGain, Range::kOutputGainMin, Range::kOutputGainMax);
  state.outputGain =
      static_cast<float>(std::pow(10.0, outputDecibels / 20.0) * normalize);
}

}  // namespace effetune::plugins::spatial

#endif
