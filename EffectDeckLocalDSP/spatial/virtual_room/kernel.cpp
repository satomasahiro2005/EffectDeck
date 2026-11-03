// Virtual Room の PluginKernel 側（docs/virtual-room-design.md §46、§48）。
//
// カーネルの器は 16 KiB（engine.h の kKernelStorageBytes）しかないのに、
// RenderState は 1 面で 3.7 KiB ある。**engine はヒープに置く。**
// 確保するのは prepare だけで、音のスレッドでは触らない（§33）。

#include "virtual_room_engine.h"

#include "effetune/kernel.h"

#include <cstddef>
#include <cstring>
#include <new>

namespace effetune::plugins::spatial {

class VirtualRoomKernel final : public PluginKernel {
  EFFETUNE_PARAMS(generated::VirtualRoomPluginParams)

public:
  ~VirtualRoomKernel() override {
    delete engine_;
    engine_ = nullptr;
  }

  void prepare(const PrepareInfo &info) override {
    if (engine_ == nullptr) {
      engine_ = new (std::nothrow) VirtualRoomEngine();
    }
    ready_ = engine_ != nullptr &&
             engine_->prepare(static_cast<double>(info.sampleRate), info.maxFrames);
    published_ = false;
  }

  [[nodiscard]] bool preparedSuccessfully() const noexcept override { return ready_; }

  void reset() noexcept override {
    if (engine_ != nullptr) {
      engine_->reset();
    }
    published_ = false;
  }

  // **Routing の検査は UI だけに任せない**（§52、§64）。並びに合わない本数で来たら素通す。
  //   Stereo  ちょうど 2ch（Stereo か対）。1ch では像が立たない
  //   5.1     6ch 以上（All）。頭の 6 本を L, R, C, LFE, Ls, Rs として読み、
  //           両耳を 0 番と 1 番へ書いて、2 番から先は 0 にする。
  //           7.1 / 7.1.4（L, R, C, LFE, Ls, Rs, Lb, Rb, ...）も頭の 6 本は同じ並びなので
  //           そこだけ読み、7 本目から先は耳へ入れずに 0 にする（§65。7.1 の並びは持たない）
  // 5.1 にした直後、host が処理の幅を 6 本へ組み直すまでの間は 2ch で来る。そこも素通し。
  void process(float *audio, std::uint32_t channel_count, std::uint32_t frame_count,
               const ProcessInfo &) noexcept override {
    if (!ready_ || engine_ == nullptr) {
      return;
    }
    // 幾何と材質から係数を作るのはここ（制御ではなく先頭の 1 回）。
    // paramsDirty は applyPendingParameters が立てるので、block の頭で 1 度だけ。
    if (paramsDirty() || !published_) {
      engine_->publish(params_);
      published_ = true;
    }
    if (frame_count == 0u || audio == nullptr) {
      return;
    }
    const bool surround = speakerLayout(params_) == SpeakerLayout::Surround51;
    const bool fits = surround ? (channel_count >= kMaxSources && channel_count <= kMaxChannels)
                               : channel_count == kStereoSources;
    if (!fits) {
      return;
    }
    // planar。channel c は audio + c * frame_count から（abi.h）。
    float *channels[kMaxChannels];
    for (std::uint32_t channel = 0u; channel < channel_count; ++channel) {
      channels[channel] = audio + static_cast<std::size_t>(channel) * frame_count;
    }
    engine_->process(channels, channel_count, frame_count);
  }

  [[nodiscard]] std::uint32_t latencySamples() const noexcept override { return 0u; }

private:
  // engine の上限（ETAudioSessionRules.maxChannels と同じ 16）。器を音のスレッドの stack に置く。
  static constexpr std::uint32_t kMaxChannels = 16u;
  VirtualRoomEngine *engine_ = nullptr;
  bool ready_ = false;
  bool published_ = false;
};

}  // namespace effetune::plugins::spatial

EFFETUNE_REGISTER_KERNEL(VirtualRoomPlugin, effetune::plugins::spatial::VirtualRoomKernel)
