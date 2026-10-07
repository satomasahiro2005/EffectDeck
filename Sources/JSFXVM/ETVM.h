// ETVM.h — JSFX のレジスタ型 VM（docs/jsfx-regvm-design.md）の C の口。
//
// NSEEL_EXEC_REG = "vm-reg" の中身は、持ち上げた中間表現から並べた threaded code（段 S2、ETVMExec.h）。
// ETVM_SetEngine で段 S1 の参照の解釈（照合のため。遅い）にもできる。
// **アプリの既定には入れない。**ETVM_Install を呼んだプロセスだけで選べる
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

/// プログラムの中身（このあと作るプログラムから効く。作ったものは変わらない）。
#define ETVM_ENGINE_THREADED 0  /* 段 S2: threaded code（既定） */
#define ETVM_ENGINE_REFERENCE 1 /* 段 S1: 中間表現の参照の解釈（照合のため） */
void ETVM_SetEngine(int engine);
int ETVM_GetEngine(void);

#ifdef __cplusplus
}
#endif
