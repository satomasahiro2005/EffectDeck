// ETJSFXHost.h
// Small C ABI around ysfx for Swift and ETExternalProcessor.

#ifndef ETJSFXHost_h
#define ETJSFXHost_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "ETExternalProcessor.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ETJSFX ETJSFX;

ETJSFX *ETJSFX_Create(const char *path,
                      const char *importRoot,
                      double sampleRate,
                      uint32_t maxFrames,
                      char *error,
                      size_t errorCapacity);
void ETJSFX_Destroy(ETJSFX *host);
ETExternalProcessor ETJSFX_Processor(ETJSFX *host);
void ETJSFX_Configure(ETJSFX *host, double sampleRate, uint32_t maxFrames);

const char *ETJSFX_Name(const ETJSFX *host);
const char *ETJSFX_Author(const ETJSFX *host);
uint32_t ETJSFX_SliderCount(const ETJSFX *host);
bool ETJSFX_SliderInfo(ETJSFX *host, uint32_t ordinal,
                       uint32_t *index, const char **name,
                       double *value, double *minimum,
                       double *maximum, double *step,
                       bool *visible);
void ETJSFX_SetSlider(ETJSFX *host, uint32_t index, double value);
double ETJSFX_GetSlider(ETJSFX *host, uint32_t index);

#ifdef __cplusplus
}
#endif

#endif
