// Virtual Room の PluginKernel 側（docs/virtual-room-design.md §46、§48）。
//
// カーネルの器は 16 KiB（engine.h の kKernelStorageBytes）しかないのに、
// RenderState は 1 面で 3.7 KiB ある。**engine はヒープに置く。**
// 確保するのは prepare だけで、音のスレッドでは触らない（§33）。

#include "virtual_room_engine.h"

#include "effetune/kernel.h"

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

  // **Routing の検査は UI だけに任せない**（§52）。2ch 以外で来たら素通す。
  // 部屋も頭も左右 2 本を前提にしていて、1ch では像が立たない。
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
    if (channel_count != 2u || frame_count == 0u || audio == nullptr) {
      return;
    }
    // planar。channel c は audio + c * frame_count から（abi.h）。
    engine_->process(audio, audio + frame_count, frame_count);
  }

  [[nodiscard]] std::uint32_t latencySamples() const noexcept override { return 0u; }

private:
  VirtualRoomEngine *engine_ = nullptr;
  bool ready_ = false;
  bool published_ = false;
};

}  // namespace effetune::plugins::spatial

EFFETUNE_REGISTER_KERNEL(VirtualRoomPlugin, effetune::plugins::spatial::VirtualRoomKernel)
