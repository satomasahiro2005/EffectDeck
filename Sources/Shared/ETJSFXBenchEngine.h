// ETJSFXBenchEngine.h — ETJSFXBench の中の口（C++ だけ。Swift からは見ない）。
#ifndef ETJSFXBenchEngine_h
#define ETJSFXBenchEngine_h
#include "ETJSFXBench.h"
#if ET_JSFX_BENCH && defined(__cplusplus)
#include <cstdint>
#include <memory>
#include <string>

namespace etbench {

/// 1 本のスクリプトを 1 つの実行系で回すもの。process はホストと同じ形
/// （planar の float を上書きする。出す前に NaN・Inf・非正規化数を 0 にする）。
struct Engine {
    virtual ~Engine() = default;
    virtual void process(float *planar, uint32_t channels, uint32_t frames, double sampleTime) = 0;
    /// ETJSFX を通る実行系だけ。締切の最悪値（1/1000）・超えた回数・自動バイパスされたか。
    virtual bool hostStats(uint32_t &worstPermille, uint32_t &trips, bool &bypassed) { (void)worstPermille; (void)trips; (void)bypassed; return false; }
    /// 自動バイパスされていたら戻す（測りの途中で外れたまま回さない）。戻したら true。
    virtual bool recover() { return false; }
};

/// 手で書いた C++ の写し（ETJSFXBenchPorts.cpp）。名前は Debug/JSFXBench のファイル名（拡張子なし）。
/// 写しの無い名前は nullptr。
std::unique_ptr<Engine> makeCppPort(const std::string &name, double sampleRate, uint32_t maxFrames);

/// 出力を拭く。ETJSFXHost.cpp の scrub と同じ（指数部が 0 か 255 なら 0）。
void scrubOutput(float *planar, size_t count);

} // namespace etbench
#endif
#endif
