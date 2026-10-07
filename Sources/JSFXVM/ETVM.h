// ETVM.h — JSFX のレジスタ型 VM（docs/jsfx-regvm-design.md）の C の口。
//
// 段 S1 の中身は「持ち上げた中間表現を参照の解釈で回す」実行系（NSEEL_EXEC_REG = "vm-reg"）。
// 遅い（照合のためだけ）。**アプリの既定には入れない。**ETVM_Install を呼んだプロセスだけで選べる
// （ETJSFX_SetEELExecutor(h, NSEEL_EXEC_REG)・ysfx_set_eel_exec_mode）。
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// WDL（NSEEL_set_exec_backend）と ysfx（ysfx_set_eel_program_builder）に登録する。何度呼んでもよい。
void ETVM_Install(void);
/// プログラムを付ける節（ysfx_section_type_t のビット 1 << section）。既定は @init・@slider・@block・@sample。
/// @gfx・@serialize は付けても ysfx が NSEEL_code_execute で回す（持ち上げは解析のためにする）。
void ETVM_SetSectionMask(uint32_t mask);
uint32_t ETVM_GetSectionMask(void);
#define ETVM_SECTIONS_DEFAULT ((1u << 1) | (1u << 2) | (1u << 3) | (1u << 4))

#ifdef __cplusplus
}
#endif
