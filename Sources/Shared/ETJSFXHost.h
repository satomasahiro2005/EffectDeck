// ETJSFXHost.h — bounded, portable JSFX runtime bridge.
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
typedef int32_t (*ETJSFXMenuCallback)(void *context, const char *menu,
                                      int32_t x, int32_t y);
ETJSFX *ETJSFX_Create(const char *path, double sampleRate, uint32_t maxFrames,
                      char *error, size_t errorCapacity);
void ETJSFX_Destroy(ETJSFX *host);
ETExternalProcessor ETJSFX_Processor(ETJSFX *host);
bool ETJSFX_Reconfigure(ETJSFX *host, double sampleRate, uint32_t maxFrames);
bool ETJSFX_SaveState(ETJSFX *host, uint8_t **bytes, size_t *size);
bool ETJSFX_LoadState(ETJSFX *host, const uint8_t *bytes, size_t size);
void ETJSFX_FreeBytes(void *bytes);
const char *ETJSFX_Name(const ETJSFX *host);
const char *ETJSFX_Author(const ETJSFX *host);
const char *ETJSFX_Diagnostic(const ETJSFX *host);
uint32_t ETJSFX_SliderCount(const ETJSFX *host);
bool ETJSFX_SliderInfo(ETJSFX *host, uint32_t ordinal,
                       uint32_t *index, const char **name,
                       double *value, double *minimum, double *maximum,
                       double *step, uint8_t *shape, bool *visible);
uint32_t ETJSFX_SliderEnumCount(ETJSFX *host, uint32_t index);
const char *ETJSFX_SliderEnumName(ETJSFX *host, uint32_t index, uint32_t ordinal);
double ETJSFX_SliderToNormalized(ETJSFX *host, uint32_t index, double value);
double ETJSFX_SliderFromNormalized(ETJSFX *host, uint32_t index, double value);
void ETJSFX_SetSlider(ETJSFX *host, uint32_t index, double value);
double ETJSFX_GetSlider(ETJSFX *host, uint32_t index);
/// trigger を送る。**running でなければ false を返して捨てる。**
/// 溜めると、再開した最初の 1 ブロックで一斉に発火して、押した覚えの無い音が出る。
bool ETJSFX_SendTrigger(ETJSFX *host, uint32_t index);
/// trigger の本数（ysfx_max_triggers）。UI が 10 を直書きしないため。
uint32_t ETJSFX_MaxTriggers(void);
/// このスクリプトが `trigger` を読むか。**読まないものに札を出さない。**
/// REAPER では MIDI やアクションから叩くもので、EffectDeck には叩く手段が
/// 無いので、使っていないスクリプトに 10 個並べても押せる先が無い。
/// `import` は拒否しているので、見るのは 1 ファイルだけで足りる。
bool ETJSFX_UsesTrigger(const ETJSFX *host);
/// いま音を通しているか。false のあいだ SendTrigger は捨てる。
bool ETJSFX_IsRunning(const ETJSFX *host);
/// 自動バイパスを解く。診断を消し、締切の回数を 0 に戻し、
/// **automaticBypass のときだけ** running へ戻す（maintenance は触らない）。
/// 戻せたら true。
bool ETJSFX_ClearDiagnostic(ETJSFX *host);
/// 締切を超えたブロックの累計。**測るためだけ。**
uint32_t ETJSFX_DeadlineTrips(const ETJSFX *host);
/// 1 ブロックの持ち時間に対して使った割合の最大値（1/1000）。1000 で使い切り。
uint32_t ETJSFX_DeadlineWorstPermille(const ETJSFX *host);
bool ETJSFX_ConsumeLatencyChange(ETJSFX *host);
bool ETJSFX_ConsumeSliderChange(ETJSFX *host);
bool ETJSFX_HasGFX(const ETJSFX *host);
bool ETJSFX_GFXWantsRetina(ETJSFX *host);
void ETJSFX_PreferredGFXSize(ETJSFX *host, uint32_t *width, uint32_t *height);
uint32_t ETJSFX_GFXFrameRate(ETJSFX *host);
bool ETJSFX_RunGFX(ETJSFX *host, uint32_t width, uint32_t height, double scale);
void ETJSFX_SetGFXMenuCallback(ETJSFX *host, ETJSFXMenuCallback callback, void *context);
bool ETJSFX_CopyGFX(ETJSFX *host, uint8_t *bgra, size_t capacity,
                    uint32_t *width, uint32_t *height, uint32_t *stride);
void ETJSFX_GFXMouse(ETJSFX *host, uint32_t modifiers, int32_t x, int32_t y,
                     uint32_t buttons, double wheel, double horizontalWheel);
void ETJSFX_GFXKey(ETJSFX *host, uint32_t modifiers, uint32_t key, bool pressed);
void ETJSFX_GFXWindowState(ETJSFX *host, bool focused, bool visible, bool mouseOver);
#ifdef __cplusplus
}
#endif
#endif
