// Tools/gen_catalog.py が Sources/EffeTuneLive/DSP/VirtualRoom/effect.json から作る。
// 手で直さないこと。
#ifndef EFFECTDECK_GENERATED_VIRTUALROOMPLUGIN_PARAMS_H
#define EFFECTDECK_GENERATED_VIRTUALROOMPLUGIN_PARAMS_H

#include <cstdint>

namespace effectdeck::generated {

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

} // namespace effectdeck::generated

#endif
