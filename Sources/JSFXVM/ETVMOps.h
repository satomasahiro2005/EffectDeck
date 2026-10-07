// ETVMOps.h — 命令の意味（WDL の glue_port.h の GLUE_CALL_CODE と同じ C の式）。
//
// 段 2 の参照の解釈（ETVMInterp.cpp）と、これから作る畳み込み・ハンドラが同じものを使う。
// **式は glue_port.h の写しのまま変えない**（オペランドの順・型の詰め替え・比べ方まで）。
// 設計（docs/jsfx-regvm-design.md §9.8）では glue_port.h もこれを読むようにパッチで替えるが、
// それは portable 自身の出力を（invsqrt で）変えうるので段 S2 以降に回した。今は glue_port.h が正で、
// Tools/jsfx-bench の --vm-opgrid（設計 §12.1）が値の格子で 1 ビットまで同じかを見る。
//
// 浮動小数の縮約（FMA）はしない。invsqrt だけは portable の TU（C、clang の既定 -ffp-contract=on）と同じく
// 縮約を許す（portable と同じ機械語になるように）。
#pragma once

#include "WDL/eel2/ns-eel-int.h"
#include "WDL/denormal.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

#if defined(__clang__)
#pragma clang fp contract(off)
#endif

#define ETVM_CLOSEFACTOR NSEEL_CLOSEFACTOR

// API の関数（NSEEL_addfunc_retptr・retval で登録）は 1 つめの引数の型がまちまち（void *・EEL_F **・
// ysfx_t * …）で、WDL は全部を (void *, EEL_F *…) の形で呼ぶ（GLUE_CALL_CODE の GENERIC*）。同じ値を同じ
// レジスタで渡すので呼ばれる側から見て同じだが、UBSan の -fsanitize=function は型の違いを拾う
// （Tests/Fuzz/run.sh も nseel-*.c はこれを外す）。API を呼ぶ所だけこれを付ける。
#if defined(__clang__)
#define ETVM_NO_SANITIZE_FUNCTION __attribute__((no_sanitize("function")))
#else
#define ETVM_NO_SANITIZE_FUNCTION
#endif

static inline double etvm_filter(double a) { return denormal_filter_double2(a); }

// + と *（EEL_BC_ADD・MUL・ADD_OP_FAST・MUL_OP_FAST）。オペランドが 2 つとも NaN のとき、どちらのペイロード
// （と符号）が残るかは機械の命令の 1 つめのオペランドで決まる（x86-64 の addsd・mulsd は 1 つめを静かにしたもの、
// arm64 の fadd・fmul は信号の NaN が先で、そのあと 1 つめ）。C の a + b はコンパイラがオペランドを入れ替えて
// よい（NaN のペイロードの他は入れ替えても同じなので）。ここは命令を asm で書いて a を必ず 1 つめにする。
// パッチの glue_port.h（portable）と glue_port_vm.h も同じく式の左を 1 つめにしている（effectdeck_nan_order_fadd）。
// 持ち上げは portable がどちらを 1 つめにしたかを etvm::portableNaNOrder() で調べて、中間表現の左をそれに
// する（パッチの無い建て方でも合うように。ETVMLift.cpp、設計 §15.2 の 9）。
// NaN が 1 つ以下なら C の a + b と同じビット。フィルタを通す結果（ADD_OP など）は NaN が 0 になるので順は
// 効かず、C のままでよい。_m は 2 つめをメモリから（x86 はメモリのオペランドを畳む。asm の "xm" は clang が
// 積み場へ写すので使わない）。
#if (defined(__clang__) || defined(__GNUC__)) && defined(__x86_64__)
static inline double etvm_fadd(double a, double b) { __asm__("addsd %1, %0" : "+x"(a) : "x"(b)); return a; }
static inline double etvm_fmul(double a, double b) { __asm__("mulsd %1, %0" : "+x"(a) : "x"(b)); return a; }
static inline double etvm_fadd_m(double a, const double *b) { __asm__("addsd %1, %0" : "+x"(a) : "m"(*b)); return a; }
static inline double etvm_fmul_m(double a, const double *b) { __asm__("mulsd %1, %0" : "+x"(a) : "m"(*b)); return a; }
#elif (defined(__clang__) || defined(__GNUC__)) && defined(__aarch64__)
static inline double etvm_fadd(double a, double b)
{
    double r;
    __asm__("fadd %d0, %d1, %d2" : "=w"(r) : "w"(a), "w"(b));
    return r;
}
static inline double etvm_fmul(double a, double b)
{
    double r;
    __asm__("fmul %d0, %d1, %d2" : "=w"(r) : "w"(a), "w"(b));
    return r;
}
static inline double etvm_fadd_m(double a, const double *b) { return etvm_fadd(a, *b); }
static inline double etvm_fmul_m(double a, const double *b) { return etvm_fmul(a, *b); }
#else
// ほかの機械・コンパイラ: 1 つめを決められない（NaN が 2 つのときだけ portable と違いうる）
static inline double etvm_fadd(double a, double b) { return a + b; }
static inline double etvm_fmul(double a, double b) { return a * b; }
static inline double etvm_fadd_m(double a, const double *b) { return a + *b; }
static inline double etvm_fmul_m(double a, const double *b) { return a * *b; }
#endif

// EEL_BC_AND / OR / XOR: (EEL_F)(((WDL_INT64)top) op (WDL_INT64)(top2))
static inline double etvm_iand(double a, double b) { return (double)(((WDL_INT64)a) & (WDL_INT64)(b)); }
static inline double etvm_ior(double a, double b) { return (double)(((WDL_INT64)a) | (WDL_INT64)(b)); }
static inline double etvm_ixor(double a, double b) { return (double)(((WDL_INT64)a) ^ (WDL_INT64)(b)); }
static inline double etvm_ior0(double a) { return (double)((WDL_INT64)(a)); }

// EEL_BC_MOD: int a = (int)fabs(divisor); a ? (EEL_F)(((WDL_INT64)fabs(x)) % a) : 0.0
static inline double etvm_imod(double x, double divisor)
{
    int a = (int)fabs(divisor);
    return a ? (double)(((WDL_INT64)fabs(x)) % a) : 0.0;
}

// EEL_BC_SHR / SHL（EffectDeck のパッチ: 量は下 5 bit、左は unsigned）
static inline double etvm_ishr(double x, double s) { return (double)(((int)x) >> (((int)s) & 31)); }
static inline double etvm_ishl(double x, double s)
{
    return (double)(int)(((unsigned int)(int)x) << (((int)s) & 31));
}

static inline double etvm_sign(double x)
{
    if (x < 0.0) x = -1.0;
    else if (x > 0.0) x = 1.0;
    return x;
}

// EEL_BC_INVSQRT。portable の TU と同じく縮約を許す（上の注）。
static inline double etvm_invsqrt(double top)
{
#if defined(__clang__)
#pragma clang fp contract(on)
#endif
    float y = (float)top;
    int iy;
    memcpy(&iy, &y, sizeof iy);
    int i = (int)(0x5f3759dfu - (unsigned int)(iy >> 1));
    memcpy(&y, &i, sizeof y);
    return y * (1.5F - ((top * 0.5) * y * y));
}

// EEL_BC_MIN_FP / MAX_FP: a = pop; if (a < top) top = a
static inline double etvm_fmin2(double top, double a) { return (a < top) ? a : top; }
static inline double etvm_fmax2(double top, double a) { return (a > top) ? a : top; }

// 比べ（top は後から積んだ方）
static inline int etvm_eq_close(double top, double top2) { return fabs(top - top2) < NSEEL_CLOSEFACTOR; }
static inline int etvm_ne_close(double top, double top2) { return fabs(top - top2) >= NSEEL_CLOSEFACTOR; }
static inline int etvm_truthy(double v) { return fabs(v) >= NSEEL_CLOSEFACTOR; }
static inline int etvm_falsy(double v) { return fabs(v) < NSEEL_CLOSEFACTOR; }

// EEL_BC_LOOP_LOADCNT: (int)n、1 未満は飛ばす、NSEEL_LOOPFUNC_SUPPORT_MAXLEN で頭を打つ
static inline int32_t etvm_loop_count(double n)
{
    int c = (int)n;
    if (c > NSEEL_LOOPFUNC_SUPPORT_MAXLEN) c = NSEEL_LOOPFUNC_SUPPORT_MAXLEN;
    return c;
}

// EEL_BC_MEGABUF
static inline EEL_F *etvm_megabuf(void *rt, double v)
{
    unsigned int idx = (unsigned int)(v + NSEEL_CLOSEFACTOR);
    EEL_F **f = (EEL_F **)rt, *f2;
    return (idx < NSEEL_RAM_BLOCKS * NSEEL_RAM_ITEMSPERBLOCK && (f2 = f[idx / NSEEL_RAM_ITEMSPERBLOCK]))
               ? (f2 + (idx & (NSEEL_RAM_ITEMSPERBLOCK - 1)))
               : __NSEEL_RAMAlloc((EEL_F **)rt, idx);
}

// EEL_BC_GMEGABUF（即値は ctx->gram_blocks の値そのもの = EEL_F ***。NULL もある。中身は呼ばれた先が毎回読む）
static inline EEL_F *etvm_gmegabuf(void *gram, double v)
{
    return __NSEEL_RAMAllocGMEM((EEL_F ***)gram, (int)(v + NSEEL_CLOSEFACTOR));
}
