#ifndef ETPreviewTone_h
#define ETPreviewTone_h
#include <stdint.h>
void ETPreviewTone_SetFrequency(double hz);
void ETPreviewTone_Render(float *planar, uint32_t frames, uint32_t channels, double rate);
#endif
