// ETVMHandlers.cpp — レジスタ型 VM の速い実行系（段 S2）のハンドラ。docs/jsfx-regvm-design.md §9.3–9.5。
//
// 1 つの形に 1 つ。オペランドは全部が絶対番地（ETVMThreaded.h）。**オペランドを全部読んでから先へ書く**
// （行き先の升が読む升と同じでもよいように。ETVMSelect.cpp の升の使い回しはこれを当てにする）。
// 式は ETVMOps.h（glue_port.h の GLUE_CALL_CODE と同じ C の式）。浮動小数の縮約はしない（下の pragma と
// ETVMOps.h の pragma。invsqrt だけは portable の TU と同じく許す）。
// 範囲の外の double → int は -fno-strict-float-cast-overflow（project.yml・run.sh）で arm64 の fcvtzs と同じ飽和。
#include "ETVMThreaded.h"
#include "ETVMOps.h"

#include <cstring>

#if defined(__clang__)
#pragma clang fp contract(off)
#endif

namespace etvm::threaded {

namespace {
using F1 = double (*)(double);
using F2 = double (*)(double, double);
using G1 = EEL_F *(NSEEL_CGEN_CALL *)(void *, EEL_F *);
using G2 = EEL_F *(NSEEL_CGEN_CALL *)(void *, EEL_F *, EEL_F *);
using G3 = EEL_F *(NSEEL_CGEN_CALL *)(void *, EEL_F *, EEL_F *, EEL_F *);
using G1D = EEL_F(NSEEL_CGEN_CALL *)(void *, EEL_F *);
using G2D = EEL_F(NSEEL_CGEN_CALL *)(void *, EEL_F *, EEL_F *);
using G3D = EEL_F(NSEEL_CGEN_CALL *)(void *, EEL_F *, EEL_F *, EEL_F *);
using GXD = EEL_F(NSEEL_CGEN_CALL *)(void *, void *, EEL_F *, EEL_F *);
// varparm は宣言どおりの型で呼ぶ（ETVMInterp.cpp と同じ。設計 §15.2 の 8）。
using VP = EEL_F(NSEEL_CGEN_CALL *)(void *, INT_PTR, EEL_F **);
using VPX = EEL_F(NSEEL_CGEN_CALL *)(void *, void *, INT_PTR, EEL_F **);

#define ETVM_H(name) HRet h_##name(const Word *ip, Ctx *cx)
/// API を呼ぶハンドラ（ETVMOps.h の ETVM_NO_SANITIZE_FUNCTION の注）
#define ETVM_HAPI(name) ETVM_NO_SANITIZE_FUNCTION HRet h_##name(const Word *ip, Ctx *cx)
#if ETVM_THREADED_LOOP
#define ETVM_GO(n) do { (void)cx; return (n); } while (0)
#define ETVM_STOP() return nullptr
#else
#define ETVM_GO(n) do { const Word *n_ = (n); [[clang::musttail]] return n_->h(n_, cx); } while (0)
#define ETVM_STOP() return
#endif
/// 次の命令（自分の語 1 つ + オペランド k 個の先）
#define ETVM_NEXT(k) ETVM_GO(ip + 1 + (k))
/// 同じ命令の続きを別の関数で（遅い道を外へ出して、速い道に積み場の枠を作らせない）
#if ETVM_THREADED_LOOP
#define ETVM_TAIL(fn) return fn(ip, cx)
#else
#define ETVM_TAIL(fn) do { [[clang::musttail]] return fn(ip, cx); } while (0)
#endif

inline uint64_t ld64(const void *p) { uint64_t v; std::memcpy(&v, p, 8); return v; }
inline void st64(void *p, uint64_t v) { std::memcpy(p, &v, 8); }

// ---- 流れ --------------------------------------------------------------------------------------------
ETVM_H(Jmp) { ETVM_GO(ip[1].t); }
ETVM_H(Br) { ETVM_GO(ip[1].s->u ? ip[2].t : ip[3].t); }
ETVM_H(BrT)
{
    if (ip[1].s->u) ETVM_GO(ip[2].t);
    ETVM_NEXT(2);
}
ETVM_H(BrF)
{
    if (!ip[1].s->u) ETVM_GO(ip[2].t);
    ETVM_NEXT(2);
}
ETVM_H(Ret)
{
    (void)ip;
    if (cx->post) cx->post(cx->user, cx->frame);
    if (++cx->frame >= cx->nframes) ETVM_STOP();
    if (cx->pre) cx->pre(cx->user, cx->frame);
    ETVM_GO(cx->entry);
}

// ---- 升・番地 ----------------------------------------------------------------------------------------
ETVM_H(Mov)
{
    st64(ip[1].p, ld64(ip[2].p));
    ETVM_NEXT(2);
}
ETVM_H(Filt)
{
    *ip[1].d = etvm_filter(*ip[2].d);
    ETVM_NEXT(2);
}
ETVM_H(Load)
{
    *ip[1].d = *(const double *)ip[2].s->p;
    ETVM_NEXT(2);
}
ETVM_H(Store)
{
    const double v = *ip[2].d;
    *(double *)ip[1].s->p = v;
    ETVM_NEXT(2);
}
// megabuf（EEL_BC_MEGABUF と同じ式。ETVMOps.h の etvm_megabuf）。塊が在る速い道はここで、無い・範囲の外は
// 同じ添字を __NSEEL_RAMAlloc に渡す遅い道（別の関数へ musttail。速い道は葉のまま）。
#define ETVM_MEGABUF_FAST(rt, v, out)                                                                         \
    const unsigned int idx_ = (unsigned int)((v) + NSEEL_CLOSEFACTOR);                                        \
    EEL_F *const blk_ = idx_ < NSEEL_RAM_BLOCKS * NSEEL_RAM_ITEMSPERBLOCK                                     \
                            ? ((EEL_F *const *)(rt))[idx_ / NSEEL_RAM_ITEMSPERBLOCK]                          \
                            : nullptr;                                                                        \
    EEL_F *const out = blk_ ? blk_ + (idx_ & (NSEEL_RAM_ITEMSPERBLOCK - 1)) : nullptr
inline EEL_F *megabufSlow(void *rt, double v)
{
    return __NSEEL_RAMAlloc((EEL_F **)rt, (unsigned int)(v + NSEEL_CLOSEFACTOR));
}
__attribute__((noinline)) HRet h_MemAddrSlow(const Word *ip, Ctx *cx)
{
    ip[1].s->p = megabufSlow(ip[3].p, *ip[2].d);
    ETVM_NEXT(3);
}
__attribute__((noinline)) HRet h_MemLoadSlow(const Word *ip, Ctx *cx)
{
    *ip[1].d = *megabufSlow(ip[3].p, *ip[2].d);
    ETVM_NEXT(3);
}
__attribute__((noinline)) HRet h_MemStoreSlow(const Word *ip, Ctx *cx)
{
    EEL_F *p = megabufSlow(ip[3].p, *ip[1].d);
    *p = *ip[2].d;
    ETVM_NEXT(3);
}
ETVM_H(MemAddr)
{
    ETVM_MEGABUF_FAST(ip[3].p, *ip[2].d, p);
    if (!p) ETVM_TAIL(h_MemAddrSlow);
    ip[1].s->p = p;
    ETVM_NEXT(3);
}
ETVM_H(MemLoad)
{
    ETVM_MEGABUF_FAST(ip[3].p, *ip[2].d, p);
    if (!p) ETVM_TAIL(h_MemLoadSlow);
    *ip[1].d = *p;
    ETVM_NEXT(3);
}
ETVM_H(MemStore)
{
    ETVM_MEGABUF_FAST(ip[3].p, *ip[1].d, p);
    if (!p) ETVM_TAIL(h_MemStoreSlow);
    *p = *ip[2].d;
    ETVM_NEXT(3);
}
ETVM_H(GMemAddr)
{
    ip[1].s->p = etvm_gmegabuf(ip[3].p, *ip[2].d);
    ETVM_NEXT(3);
}

// ---- 浮動小数 ----------------------------------------------------------------------------------------
#define ETVM_BIN(name, expr)                                                                                  \
    ETVM_H(name)                                                                                              \
    {                                                                                                         \
        const double a = *ip[2].d, b = *ip[3].d;                                                              \
        *ip[1].d = (expr);                                                                                    \
        ETVM_NEXT(3);                                                                                         \
    }
ETVM_BIN(FAdd, a + b)
ETVM_BIN(FSub, a - b)
ETVM_BIN(FMul, a * b)
ETVM_BIN(FDiv, a / b)
ETVM_BIN(FAddF, etvm_filter(a + b))
ETVM_BIN(FSubF, etvm_filter(a - b))
ETVM_BIN(FMulF, etvm_filter(a * b))
ETVM_BIN(FDivF, etvm_filter(a / b))
ETVM_BIN(FMin2, etvm_fmin2(a, b))
ETVM_BIN(FMax2, etvm_fmax2(a, b))
ETVM_BIN(IAnd, etvm_iand(a, b))
ETVM_BIN(IOr, etvm_ior(a, b))
ETVM_BIN(IXor, etvm_ixor(a, b))
ETVM_BIN(IMod, etvm_imod(a, b))
ETVM_BIN(IShl, etvm_ishl(a, b))
ETVM_BIN(IShr, etvm_ishr(a, b))
#undef ETVM_BIN

#define ETVM_UN(name, expr)                                                                                   \
    ETVM_H(name)                                                                                              \
    {                                                                                                         \
        const double a = *ip[2].d;                                                                            \
        *ip[1].d = (expr);                                                                                    \
        ETVM_NEXT(2);                                                                                         \
    }
ETVM_UN(FNeg, -a)
ETVM_UN(FAbs, fabs(a))
ETVM_UN(FSqr, a * a)
ETVM_UN(FSign, etvm_sign(a))
ETVM_UN(InvSqrt, etvm_invsqrt(a))
ETVM_UN(IOr0, etvm_ior0(a))
#undef ETVM_UN

ETVM_H(CallF1)
{
    const double a = *ip[3].d;
    *ip[1].d = ((F1)ip[2].p)(a);
    ETVM_NEXT(3);
}
ETVM_H(CallF2)
{
    const double a = *ip[3].d, b = *ip[4].d;
    *ip[1].d = ((F2)ip[2].p)(a, b);
    ETVM_NEXT(4);
}

// ---- 比べ・bool --------------------------------------------------------------------------------------
#define ETVM_CMP(name, expr)                                                                                  \
    ETVM_H(name)                                                                                              \
    {                                                                                                         \
        const double a = *ip[2].d, b = *ip[3].d;                                                              \
        ip[1].s->u = (expr) ? 1u : 0u;                                                                        \
        ETVM_NEXT(3);                                                                                         \
    }
ETVM_CMP(CmpEqClose, etvm_eq_close(a, b))
ETVM_CMP(CmpNeClose, etvm_ne_close(a, b))
ETVM_CMP(CmpEq, a == b)
ETVM_CMP(CmpNe, a != b)
ETVM_CMP(CmpLt, a < b)
ETVM_CMP(CmpGe, a >= b)
#undef ETVM_CMP
ETVM_H(Truthy)
{
    ip[1].s->u = etvm_truthy(*ip[2].d) ? 1u : 0u;
    ETVM_NEXT(2);
}
ETVM_H(Falsy)
{
    ip[1].s->u = etvm_falsy(*ip[2].d) ? 1u : 0u;
    ETVM_NEXT(2);
}
ETVM_H(BNot)
{
    ip[1].s->u = ip[2].s->u ? 0u : 1u;
    ETVM_NEXT(2);
}
ETVM_H(BoolToF)
{
    *ip[1].d = ip[2].s->u ? 1.0 : 0.0;
    ETVM_NEXT(2);
}
ETVM_H(PtrNonNull)
{
    ip[1].s->u = ip[2].s->u != 0 ? 1u : 0u;
    ETVM_NEXT(2);
}
ETVM_H(BoolToPtr)
{
    ip[1].s->u = ip[2].s->u ? 1u : 0u; // EEL_BC_TRUE は (EEL_F *)1
    ETVM_NEXT(2);
}
ETVM_H(PtrMin)
{
    EEL_F *p1 = (EEL_F *)ip[2].s->p, *p2 = (EEL_F *)ip[3].s->p;
    if (*p1 > *p2) p1 = p2;
    ip[1].s->p = p1;
    ETVM_NEXT(3);
}
ETVM_H(PtrMax)
{
    EEL_F *p1 = (EEL_F *)ip[2].s->p, *p2 = (EEL_F *)ip[3].s->p;
    if (*p1 < *p2) p1 = p2;
    ip[1].s->p = p1;
    ETVM_NEXT(3);
}

// ---- API ---------------------------------------------------------------------------------------------
inline EEL_F *A(const Word &w) { return (EEL_F *)w.s->p; }
ETVM_HAPI(CallG1)
{
    EEL_F *a = A(ip[4]);
    ip[1].s->p = ((G1)ip[2].p)(ip[3].p, a);
    ETVM_NEXT(4);
}
ETVM_HAPI(CallG2)
{
    EEL_F *a = A(ip[4]), *b = A(ip[5]);
    ip[1].s->p = ((G2)ip[2].p)(ip[3].p, a, b);
    ETVM_NEXT(5);
}
ETVM_HAPI(CallG3)
{
    EEL_F *a = A(ip[4]), *b = A(ip[5]), *c = A(ip[6]);
    ip[1].s->p = ((G3)ip[2].p)(ip[3].p, a, b, c);
    ETVM_NEXT(6);
}
ETVM_HAPI(CallGD1)
{
    EEL_F *a = A(ip[4]);
    const double r = ((G1D)ip[2].p)(ip[3].p, a);
    *ip[1].d = r;
    ETVM_NEXT(4);
}
ETVM_HAPI(CallGD2)
{
    EEL_F *a = A(ip[4]), *b = A(ip[5]);
    const double r = ((G2D)ip[2].p)(ip[3].p, a, b);
    *ip[1].d = r;
    ETVM_NEXT(5);
}
ETVM_HAPI(CallGD3)
{
    EEL_F *a = A(ip[4]), *b = A(ip[5]), *c = A(ip[6]);
    const double r = ((G3D)ip[2].p)(ip[3].p, a, b, c);
    *ip[1].d = r;
    ETVM_NEXT(6);
}
ETVM_HAPI(CallGXD)
{
    EEL_F *a = A(ip[5]), *b = A(ip[6]);
    const double r = ((GXD)ip[2].p)(ip[3].p, ip[4].p, a, b);
    *ip[1].d = r;
    ETVM_NEXT(6);
}
ETVM_HAPI(CallVP)
{
    // portable は積み場の上にポインタを並べて渡す。ここはプログラムごとの置き場（建てるときに大きさを決めた）。
    const size_t n = (size_t)ip[4].u;
    void **arr = (void **)ip[5].p;
    for (size_t k = 0; k < n; ++k) arr[k] = ip[6 + k].s->p;
    const double r = ((VP)ip[2].p)(ip[3].p, (INT_PTR)n, (EEL_F **)arr);
    *ip[1].d = r;
    ETVM_NEXT(5 + n);
}
ETVM_HAPI(CallVPX)
{
    const size_t n = (size_t)ip[5].u;
    void **arr = (void **)ip[6].p;
    for (size_t k = 0; k < n; ++k) arr[k] = ip[7 + k].s->p;
    const double r = ((VPX)ip[2].p)(ip[3].p, ip[4].p, (INT_PTR)n, (EEL_F **)arr);
    *ip[1].d = r;
    ETVM_NEXT(6 + n);
}

// ---- ユーザーの積み場（ETVMInterp.cpp・glue_port.h と同じ算術） ---------------------------------------
ETVM_H(UPush)
{
    const void *src = ip[1].s->p;
    UINT_PTR *sptr = (UINT_PTR *)ip[2].p;
    (*sptr) += 8;
    (*sptr) &= (UINT_PTR)ip[3].u;
    (*sptr) |= (UINT_PTR)ip[4].u;
    st64((void *)*sptr, ld64(src));
    ETVM_NEXT(4);
}
ETVM_H(UPop)
{
    void *dst = ip[1].s->p;
    UINT_PTR *sptr = (UINT_PTR *)ip[2].p;
    st64(dst, ld64((const void *)*sptr));
    (*sptr) -= 8;
    (*sptr) &= (UINT_PTR)ip[3].u;
    (*sptr) |= (UINT_PTR)ip[4].u;
    ETVM_NEXT(4);
}
ETVM_H(UPopFast)
{
    UINT_PTR *sptr = (UINT_PTR *)ip[2].p;
    const UINT_PTR r = *sptr;
    (*sptr) -= 8;
    (*sptr) &= (UINT_PTR)ip[3].u;
    (*sptr) |= (UINT_PTR)ip[4].u;
    ip[1].s->u = (uint64_t)r;
    ETVM_NEXT(4);
}
ETVM_H(UPeek)
{
    const double a = *ip[2].d;
    UINT_PTR s = *(const UINT_PTR *)ip[3].p;
    s -= sizeof(EEL_F) * (int)a;
    s &= (UINT_PTR)ip[4].u;
    s |= (UINT_PTR)ip[5].u;
    ip[1].s->u = (uint64_t)s;
    ETVM_NEXT(5);
}
ETVM_H(UPeekInt)
{
    UINT_PTR s = *(const UINT_PTR *)ip[2].p;
    s -= (UINT_PTR)ip[3].u;
    s &= (UINT_PTR)ip[4].u;
    s |= (UINT_PTR)ip[5].u;
    ip[1].s->u = (uint64_t)s;
    ETVM_NEXT(5);
}
ETVM_H(UPeekTop)
{
    ip[1].s->p = *(EEL_F **)ip[2].p;
    ETVM_NEXT(2);
}
ETVM_H(UExch)
{
    EEL_F *p1 = (EEL_F *)ip[1].s->p;
    EEL_F *p = *(EEL_F **)ip[2].p;
    const uint64_t t = ld64(p);
    st64(p, ld64(p1));
    st64(p1, t);
    ETVM_NEXT(2);
}

// ---- loop の数（i32 は枠の升に符号付きで） --------------------------------------------------------------
ETVM_H(LoopCount)
{
    ip[1].s->i = (int64_t)etvm_loop_count(*ip[2].d);
    ETVM_NEXT(2);
}
ETVM_H(ILt1)
{
    ip[1].s->u = (int32_t)ip[2].s->i < 1 ? 1u : 0u;
    ETVM_NEXT(2);
}
ETVM_H(IDec)
{
    ip[1].s->i = (int64_t)(int32_t)((uint32_t)ip[2].s->i - 1u);
    ETVM_NEXT(2);
}
ETVM_H(IGt0)
{
    ip[1].s->u = (int32_t)ip[2].s->i > 0 ? 1u : 0u;
    ETVM_NEXT(2);
}

struct Entry { Handler h; const char *name; int nops; };
#define E(name, n) {h_##name, #name, n}
const Entry kTable[] = {
    E(Jmp, 1), E(Br, 3), E(BrT, 2), E(BrF, 2), E(Ret, 0), E(Mov, 2), E(Filt, 2), E(Load, 2), E(Store, 2),
    E(MemAddr, 3), E(MemLoad, 3), E(MemStore, 3), E(GMemAddr, 3),
    E(FAdd, 3), E(FSub, 3), E(FMul, 3), E(FDiv, 3), E(FAddF, 3), E(FSubF, 3), E(FMulF, 3), E(FDivF, 3),
    E(FMin2, 3), E(FMax2, 3), E(IAnd, 3), E(IOr, 3), E(IXor, 3), E(IMod, 3), E(IShl, 3), E(IShr, 3),
    E(FNeg, 2), E(FAbs, 2), E(FSqr, 2), E(FSign, 2), E(InvSqrt, 2), E(IOr0, 2),
    E(CallF1, 3), E(CallF2, 4),
    E(CmpEqClose, 3), E(CmpNeClose, 3), E(CmpEq, 3), E(CmpNe, 3), E(CmpLt, 3), E(CmpGe, 3),
    E(Truthy, 2), E(Falsy, 2), E(BNot, 2), E(BoolToF, 2), E(PtrNonNull, 2), E(BoolToPtr, 2),
    E(PtrMin, 3), E(PtrMax, 3),
    E(CallG1, 4), E(CallG2, 5), E(CallG3, 6), E(CallGD1, 4), E(CallGD2, 5), E(CallGD3, 6), E(CallGXD, 6),
    E(CallVP, -1), E(CallVPX, -1),
    E(UPush, 4), E(UPop, 4), E(UPopFast, 4), E(UPeek, 5), E(UPeekInt, 5), E(UPeekTop, 2), E(UExch, 2),
    E(LoopCount, 2), E(ILt1, 2), E(IDec, 2), E(IGt0, 2),
};
#undef E
static_assert(sizeof kTable / sizeof *kTable == (size_t)HK::Count, "handler table");
} // namespace

Handler handler(HK k) { return kTable[(size_t)k].h; }
const char *handlerName(HK k) { return (size_t)k < (size_t)HK::Count ? kTable[(size_t)k].name : "?"; }
int handlerOperands(HK k) { return kTable[(size_t)k].nops; }

HK handlerKind(Handler h)
{
    for (size_t k = 0; k < (size_t)HK::Count; ++k)
        if (kTable[k].h == h) return (HK)k;
    return HK::Count;
}

void run(const Word *entry, unsigned int nframes, FrameCallback pre, FrameCallback post, void *user)
{
    if (!nframes) return;
    Ctx cx{entry, 0, nframes, pre, post, user};
    if (pre) pre(user, 0);
#if ETVM_THREADED_LOOP
    for (const Word *ip = entry; ip; ip = ip->h(ip, &cx)) {}
#else
    entry->h(entry, &cx);
#endif
}

} // namespace etvm::threaded
