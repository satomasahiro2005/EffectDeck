// ETVM.h — JSFX のレジスタ型 VM（docs/jsfx-regvm-design.md）の C の口。
//
// NSEEL_EXEC_REG = "vm-reg" の中身は、持ち上げた中間表現から並べた threaded code（段 S2、ETVMExec.h）。
// ETVM_SetEngine で段 S1 の参照の解釈（照合のため。遅い）にもできる。
// **アプリの既定には入れない。**ETVM_Install を呼んだプロセスだけで選べる
// （ETJSFX_SetEELExecutor(h, NSEEL_EXEC_REG)・ysfx_set_eel_exec_mode）。
#pragma once

#include <stdint.h>
#include <stddef.h>

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

/// 段 S3 の最適化（1 つずつ切って原因を絞れるように。このあと作るプログラムから効く）。
/// 既定は全部。環境変数 ETVM_PASSES（"-cse,-fwd" で外す、"none,+loop" で足す、"all"）が最初に読まれる。
/// 中間表現の段（ETVMOpt.cpp。参照の解釈 vm-reg-ref も同じ中間表現を回す）:
#define ETVM_PASS_CONSTCELL (1u << 0)  /* constcell: どの handle も書かず外へ漏れない升（Const）を読む所を定数に */
#define ETVM_PASS_FOLD (1u << 1)       /* fold: 定数だけの演算を建てるときに計算（非正規化数・NaN は畳まない） */
#define ETVM_PASS_CSE (1u << 2)        /* cse: 同じ升の読み直し・同じ演算をブロックの中で 1 つに */
#define ETVM_PASS_FWD (1u << 3)        /* fwd: 書いた升をすぐ読むのを、書いた値に（ブロックの中） */
#define ETVM_PASS_PROMOTE (1u << 4)    /* promote: 外へ漏れない作業表の升への書き込みを値に替え、読まれない書き込みを消す */
/// 並べる段（ETVMSelect.cpp）:
#define ETVM_PASS_LDFOLD (1u << 8)     /* ldfold: LoadCell をオペランドの升へ畳む（段 S2） */
#define ETVM_PASS_DIRECT (1u << 9)     /* direct: 演算が StoreCell の升へじかに書く（段 S2） */
#define ETVM_PASS_FUSE (1u << 10)      /* fuse: 四則 + フィルタ、megabuf の番地 + 読み書き（段 S2） */
#define ETVM_PASS_LOOP (1u << 11)      /* loop: loop の入口・次の周・while の次を 1 つに、数の升を phi とまとめる */
#define ETVM_PASS_CMPBR (1u << 12)     /* cmpbr: 比べ + 分かれ道を 1 つに */
#define ETVM_PASS_OPIMM (1u << 13)     /* opimm: 定数のオペランドを命令の中に（cell OP= 定数） */
#define ETVM_PASS_OPTO (1u << 14)      /* opto: 行き先と左のオペランドが同じ升（cell OP= cell） */
#define ETVM_PASS_MEMBI (1u << 15)     /* membi: megabuf の 頭 + 添字 の足し算を番地の命令に */
#define ETVM_PASS_FUSE2 (1u << 16)     /* fuse2: 続いた四則 2 つ（a*b + c など）を 1 つに */
#define ETVM_PASS_LKERN (1u << 17)     /* lkern: 中身が cell OP= 定数／cell だけの loop を 1 つのハンドラで回す */
#define ETVM_PASSES_ALL 0x0003ff1fu
void ETVM_SetPasses(uint32_t passes);
uint32_t ETVM_GetPasses(void);
/// "-cse,-fwd" などを読んで、base から足し引きした値を返す（名前を知らなければ *bad に書く）。
uint32_t ETVM_ParsePasses(const char *spec, uint32_t base, const char **bad);

#ifdef __cplusplus
}
#endif
