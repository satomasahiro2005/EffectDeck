// Tools/gen_catalog.py が EffectDeckLocalDSP/**/params.json から作る。
// 手で直さないこと。上流の gen-dsp-params.mjs が吐くものと同じ形にしてある。
#ifndef EFFETUNE_GENERATED_VIRTUALROOMPLUGIN_PARAMS_H
#define EFFETUNE_GENERATED_VIRTUALROOMPLUGIN_PARAMS_H

#include <cstdint>

namespace effetune::generated {

struct VirtualRoomPluginParams {
  float roomWidth;
  float roomDepth;
  float roomHeight;
  float listenerX;
  float listenerY;
  float listenerHeight;
  float speakerAngle;
  float speakerDistance;
  float speakerElevation;
  float roomAmount;
  float decayScale;
  float sideMaterial;
  float frontMaterial;
  float rearMaterial;
  float floorMaterial;
  float ceilingMaterial;
  float earlyOrder;
  float headRadius;
  float pinnaAmount;
  float headShadowAmount;
  float outputGain;
  float modelVersion;
  float seedLow;
  float seedHigh;
  static constexpr std::uint32_t kHash = 0x64db6513u;
  static constexpr std::uint32_t kFloatCount = 24u;
};
static_assert(sizeof(VirtualRoomPluginParams) == sizeof(float) * 24u);

// effect.json の範囲。kernel が clamp と buffer の確保に使う。
struct VirtualRoomPluginRange {
  static constexpr float kRoomWidthMin = 2.0F;
  static constexpr float kRoomWidthMax = 20.0F;
  static constexpr float kRoomDepthMin = 2.0F;
  static constexpr float kRoomDepthMax = 30.0F;
  static constexpr float kRoomHeightMin = 2.0F;
  static constexpr float kRoomHeightMax = 10.0F;
  static constexpr float kListenerXMin = 5.0F;
  static constexpr float kListenerXMax = 95.0F;
  static constexpr float kListenerYMin = 5.0F;
  static constexpr float kListenerYMax = 95.0F;
  static constexpr float kListenerHeightMin = 0.5F;
  static constexpr float kListenerHeightMax = 2.5F;
  static constexpr float kSpeakerAngleMin = 5.0F;
  static constexpr float kSpeakerAngleMax = 90.0F;
  static constexpr float kSpeakerDistanceMin = 0.5F;
  static constexpr float kSpeakerDistanceMax = 6.0F;
  static constexpr float kSpeakerElevationMin = -30.0F;
  static constexpr float kSpeakerElevationMax = 30.0F;
  static constexpr float kRoomAmountMin = 0.0F;
  static constexpr float kRoomAmountMax = 200.0F;
  static constexpr float kDecayScaleMin = 0.25F;
  static constexpr float kDecayScaleMax = 4.0F;
  static constexpr std::uint32_t kSideMaterialCount = 8u;
  static constexpr std::uint32_t kFrontMaterialCount = 8u;
  static constexpr std::uint32_t kRearMaterialCount = 8u;
  static constexpr std::uint32_t kFloorMaterialCount = 8u;
  static constexpr std::uint32_t kCeilingMaterialCount = 8u;
  static constexpr std::uint32_t kEarlyOrderCount = 2u;
  static constexpr float kHeadRadiusMin = 7.0F;
  static constexpr float kHeadRadiusMax = 11.0F;
  static constexpr float kPinnaAmountMin = 0.0F;
  static constexpr float kPinnaAmountMax = 150.0F;
  static constexpr float kHeadShadowAmountMin = 0.0F;
  static constexpr float kHeadShadowAmountMax = 150.0F;
  static constexpr float kOutputGainMin = -24.0F;
  static constexpr float kOutputGainMax = 12.0F;
  static constexpr float kModelVersionMin = 1.0F;
  static constexpr float kModelVersionMax = 16.0F;
  static constexpr float kSeedLowMin = 0.0F;
  static constexpr float kSeedLowMax = 65535.0F;
  static constexpr float kSeedHighMin = 0.0F;
  static constexpr float kSeedHighMax = 65535.0F;
};

} // namespace effetune::generated

#endif
