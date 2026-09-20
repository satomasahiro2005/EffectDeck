#ifndef ETPreviewTone_h
#define ETPreviewTone_h
#include <stdint.h>
void ETPreviewTone_SetFrequency(double hz);
void ETPreviewTone_Render(float *planar, uint32_t frames, uint32_t channels, double rate);
/// いま音を出しているか。**音のスレッドからだけ呼ぶこと。**
/// 減衰の途中を拾うために `amplitude` を読むが、あれは音のスレッドの専有物。
int ETPreviewTone_Active(double rate);
#endif
