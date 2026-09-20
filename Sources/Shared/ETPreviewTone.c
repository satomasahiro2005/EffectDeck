#include "ETPreviewTone.h"
#include <math.h>
#include <stdatomic.h>

static _Atomic(double) frequency = 0;
// These are owned exclusively by the audio render thread.
static double phase = 0, amplitude = 0, lastFrequency = 440;

void ETPreviewTone_SetFrequency(double hz) {
    atomic_store_explicit(&frequency, isfinite(hz) && hz > 0 ? hz : 0, memory_order_relaxed);
}

void ETPreviewTone_Render(float *planar, uint32_t frames, uint32_t channels, double rate) {
    if (!planar || channels == 0 || !isfinite(rate) || rate <= 0) return;
    const double hz = atomic_load_explicit(&frequency, memory_order_relaxed);
    const double target = hz > 0 && hz < rate * 0.49 ? 0.0630957344 : 0; // -24 dBFS
    if (target > 0) lastFrequency = hz;
    const double step = 0.0630957344 / (rate * 0.005);
    // **鳴らすものが無いなら抜ける。**
    // lastFrequency の初期値が 440 なので、一度も図に触っていなくても位相は
    // 進み続け、毎サンプル sin() が走る（48kHz なら 48000 回/秒）。出力には
    // 何も足さないので丸損。amplitude は target=0 のとき
    // fmax(-step, fmin(step, -amplitude)) が -amplitude を選ぶ回で厳密に 0 へ
    // 着地するので、消えたあとは必ずこの条件に入る。
    if (target <= 0 && amplitude <= 0) return;
    for (uint32_t i = 0; i < frames; ++i) {
        amplitude += fmax(-step, fmin(step, target - amplitude));
        const float tone = (float)(sin(phase) * amplitude);
        planar[i] += tone;
        if (channels > 1) planar[frames + i] += tone;
        phase += 6.283185307179586 * lastFrequency / rate;
        if (phase >= 6.283185307179586) phase = fmod(phase, 6.283185307179586);
    }
}

int ETPreviewTone_Active(double rate) {
    // **判定は Render の target と同じ形に揃える。**
    // `hz > 0` だけで真を返すと、Nyquist 近くの hz で「鳴っている」と申告して
    // しまう（Render 側は target=0 で無音なので、呼び出し側の早抜けが効かない）。
    //
    // amplitude を読むのは、指を離した回（frequency は 0 だが 0.005 秒の傾きで
    // 減衰の途中）に真を返したいから。ここが 0 を返すと減衰が途中で切れる。
    if (amplitude > 0) return 1;
    const double hz = atomic_load_explicit(&frequency, memory_order_relaxed);
    return (isfinite(rate) && rate > 0 && hz > 0 && hz < rate * 0.49) ? 1 : 0;
}
