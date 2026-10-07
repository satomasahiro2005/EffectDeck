// ETVMThreaded.h — レジスタ型 VM の速い実行系（段 S2）の中身。docs/jsfx-regvm-design.md §9。
//
// プログラムは「ハンドラの番地 + オペランド（8 バイトずつ）」を並べた語の列。ハンドラは 1 つの形に 1 つで、
// 終わりに次の語のハンドラへ [[clang::musttail]] で飛ぶ（直接の threaded code。実行時に機械語は作らない）。
// オペランドは全部が絶対番地: 浮動小数は double *（変数・定数・関数の局所・作業表の升、またはプログラムの
// 枠の升）、ポインタ・bool・i32 は枠の升（Slot *）、跳び先は語の番地。
// musttail が無い・使えない建て方（ETVM_THREADED_LOOP）は、ハンドラが次の語を返して外の while で回す。
#pragma once

#include <cstddef>
#include <cstdint>

#if !defined(ETVM_THREADED_LOOP)
#if defined(__clang__) && defined(__has_cpp_attribute)
#if __has_cpp_attribute(clang::musttail)
#define ETVM_THREADED_LOOP 0
#endif
#endif
#endif
#if !defined(ETVM_THREADED_LOOP)
#define ETVM_THREADED_LOOP 1
#endif

namespace etvm::threaded {

union Word;
struct Ctx;
#if ETVM_THREADED_LOOP
using HRet = const Word *;
#else
using HRet = void;
#endif
using Handler = HRet (*)(const Word *ip, Ctx *cx);

/// 枠の升（SSA の値 1 つ。f64・ptr・bool（0 / 1）・i32 をどれも 8 バイトで）。
union Slot {
    double d;
    uint64_t u;
    int64_t i;
    void *p;
};

union Word {
    Handler h;
    double f; // 命令の中に置いた定数（段 S3 の opimm）
    double *d;
    Slot *s;
    const Word *t;
    void *p;
    uint64_t u;
    int64_t i;
};

using FrameCallback = void (*)(void *ctx, unsigned int frame);

struct Ctx {
    const Word *entry;
    unsigned int frame, nframes;
    FrameCallback pre, post;
    void *user;
};

/// fuse2 の組（内側 i, 外側 o）。
#define ETVM_FUSE2_LIST(X)                                                                                    \
    X(Add, Add) X(Add, Sub) X(Add, Mul) X(Add, Div) X(Sub, Add) X(Sub, Sub) X(Sub, Mul) X(Sub, Div)             \
    X(Mul, Add) X(Mul, Sub) X(Mul, Mul) X(Mul, Div) X(Div, Add) X(Div, Sub) X(Div, Mul) X(Div, Div)

/// ハンドラの種類（ETVMHandlers.cpp の表の順）。コメントはオペランドの並び（d = double *、s = Slot *、
/// t = 跳び先、x = 即値）。
enum class HK : uint16_t {
    Jmp,        // t
    Br,         // s cond, t 真, t 偽
    BrT,        // s cond, t 真（偽は次へ）
    BrF,        // s cond, t 偽（真は次へ）
    Ret,        // フレームの終わり（post → 次のフレームなら pre → 入口へ）
    Mov,        // u64 * dst, u64 * src（8 バイトそのまま。升の読み書き・phi の写し）
    Filt,       // d dst, d a
    Load,       // d dst, s p
    Store,      // s p, d v
    MemAddr,    // s dst, d idx, x rt
    MemLoad,    // d dst, d idx, x rt
    MemStore,   // d idx, d v, x rt
    GMemAddr,   // s dst, d idx, x gram
    FAdd, FSub, FMul, FDiv,         // d dst, d a, d b
    FAddF, FSubF, FMulF, FDivF,     // 同じ + denormal_filter_double2（フィルタ付きの代入）
    FMin2, FMax2, IAnd, IOr, IXor, IMod, IShl, IShr, // d dst, d a, d b
    FNeg, FAbs, FSqr, FSign, InvSqrt, IOr0,          // d dst, d a
    CallF1,     // d dst, x fn, d a
    CallF2,     // d dst, x fn, d a, d b
    CmpEqClose, CmpNeClose, CmpEq, CmpNe, CmpLt, CmpGe, // s dst, d a, d b
    Truthy, Falsy,                                      // s dst, d a
    BNot,       // s dst, s a
    BoolToF,    // d dst, s a
    PtrNonNull, // s dst, s a
    BoolToPtr,  // s dst, s a
    PtrMin, PtrMax, // s dst, s p1, s p2
    CallG1, CallG2, CallG3,     // s dst, x fn, x opaque, s args...
    CallGD1, CallGD2, CallGD3,  // d dst, x fn, x opaque, s args...
    CallGXD,    // d dst, x fn, x ctx1, x ctx2, s a, s b
    CallVP,     // d dst, x fn, x opaque, x n, x scratch, s args[n]
    CallVPX,    // d dst, x fn, x ctx1, x ctx2, x n, x scratch, s args[n]
    UPush,      // s p, x sptr, x mask, x or
    UPop,       // s p, x sptr, x mask, x or
    UPopFast,   // s dst, x sptr, x mask, x or
    UPeek,      // s dst, d a, x sptr, x mask, x or
    UPeekInt,   // s dst, x sptr, x sub, x mask, x or
    UPeekTop,   // s dst, x sptr
    UExch,      // s p, x sptr
    LoopCount,  // s dst, d a
    ILt1, IDec, IGt0, // s dst, s a
    // ---- 段 S3 ----
    // loop・while（J は条件が真なら t へ、JF は偽なら t へ。もう片方は次の命令）
    LoopInitJ, LoopInitJF, // s cnt, d n, t: cnt = loop の数(n)。cnt < 1 が真（J）／偽（JF）なら t
    DecJ, DecJF,           // s out, s in, t: out = in - 1。out > 0 が真／偽なら t
    WhileJ, WhileJF,       // s out, s in, s cond, t: out = in - 1。(out > 0 && cond) が真／偽なら t
    // 比べ + 分かれ道（d a, d b, t。式は中間表現の Cmp* と同じ a0, a1 の順）
    JLt, JNLt, JGe, JNGe, JEqClose, JNEqClose, JNeClose, JNNeClose, JEq, JNEq, JNe, JNNe,
    JTruthy, JNTruthy, JFalsy, JNFalsy, // d a, t
    // 定数のオペランド（d dst, d a, x imm）: a op imm、R* は imm op a
    AddI, SubI, RSubI, MulI, DivI, RDivI, AddIF, SubIF, RSubIF, MulIF, DivIF, RDivIF,
    // 行き先 = 左（d dst, d b: dst = dst op b）
    AddT, SubT, MulT, DivT, AddTF, SubTF, MulTF, DivTF,
    // 行き先 = 左、右は定数（d dst, x imm: dst = dst op imm）
    AddIT, SubIT, MulIT, DivIT, AddITF, SubITF, MulITF, DivITF,
    // megabuf の 頭 + 添字（idx = (unsigned)((a + b) + 1e-5) と同じ式）
    MemAddrBI,  // s dst, d a, d b, x rt
    MemLoadBI,  // d dst, d a, d b, x rt
    MemStoreBI, // d a, d b, d v, x rt
    // 続いた四則 2 つ（fuse2）: L は d = (a i b) o c、R は d = c o (a i b)。F は o の結果にフィルタ。d dst, d a, d b, d c
#define ETVM_F2_ENUM(i, o) F2L##i##o, F2R##i##o, F2LF##i##o, F2RF##i##o,
    ETVM_FUSE2_LIST(ETVM_F2_ENUM)
#undef ETVM_F2_ENUM
    Count
};

/// 種類ごとのハンドラと名前とオペランドの数（可変長は -1）。
Handler handler(HK k);
const char *handlerName(HK k);
int handlerOperands(HK k);
/// ハンドラの番地から種類を引く（表示だけ。無ければ HK::Count）。
HK handlerKind(Handler h);

/// 1 つのプログラムを nframes 回（フレームごとに pre → 本体 → post）。入口は entry。
void run(const Word *entry, unsigned int nframes, FrameCallback pre, FrameCallback post, void *user);

} // namespace etvm::threaded
