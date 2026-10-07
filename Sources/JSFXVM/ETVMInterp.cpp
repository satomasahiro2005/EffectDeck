// ETVMInterp.cpp — 中間表現の参照の解釈（docs/jsfx-regvm-design.md §12.2 の照合の片方。速さは見ない）。
//
// 升・番地は本物のメモリをそのまま読み書きする（portable と同じ番地・同じ順）。値は 64 bit のまま持ち、
// 読み書きは memcpy（NaN のビットを変えない）。式は ETVMOps.h（glue_port.h と同じ C の式）。
#include "ETVMIR.h"
#include "ETVMOps.h"

#include <cstring>

namespace etvm {

namespace {
inline double F(uint64_t x) { double d; std::memcpy(&d, &x, 8); return d; }
inline uint64_t B(double d) { uint64_t x; std::memcpy(&x, &d, 8); return x; }
inline uint64_t P(const void *p) { return (uint64_t)(uintptr_t)p; }
template <class T> inline T *AS(uint64_t x) { return (T *)(uintptr_t)x; }

using F1 = double (*)(double);
using F2 = double (*)(double, double);
using G1 = EEL_F *(NSEEL_CGEN_CALL *)(void *, EEL_F *);
using G2 = EEL_F *(NSEEL_CGEN_CALL *)(void *, EEL_F *, EEL_F *);
using G3 = EEL_F *(NSEEL_CGEN_CALL *)(void *, EEL_F *, EEL_F *, EEL_F *);
using G1D = EEL_F(NSEEL_CGEN_CALL *)(void *, EEL_F *);
using G2D = EEL_F(NSEEL_CGEN_CALL *)(void *, EEL_F *, EEL_F *);
using G3D = EEL_F(NSEEL_CGEN_CALL *)(void *, EEL_F *, EEL_F *, EEL_F *);
using GXD = EEL_F(NSEEL_CGEN_CALL *)(void *, void *, EEL_F *, EEL_F *);
// varparm の関数の本当の型（NSEEL_addfunc_varparm_ex・_ctxptr2）。portable は p2 = 数・p1 = 並びを
// EEL_F * 2 つとして渡す（同じレジスタに同じ値が入る）。ここは宣言どおりの型で呼ぶ。
using VP = EEL_F(NSEEL_CGEN_CALL *)(void *, INT_PTR, EEL_F **);
using VPX = EEL_F(NSEEL_CGEN_CALL *)(void *, void *, INT_PTR, EEL_F **);
} // namespace

// API を呼ぶ（ETVMOps.h の ETVM_NO_SANITIZE_FUNCTION の注）
ETVM_NO_SANITIZE_FUNCTION void interpret(const Function &fn, InterpState &st)
{
    if (st.vals.size() < fn.values.size()) st.vals.resize(fn.values.size());
    uint64_t *V = st.vals.data();
    for (const Ins &c : fn.consts) V[c.res] = c.imm[0];
    std::vector<uint64_t> phiTmp;
    uint32_t b = 0, predIdx = 0;
    for (;;) {
        const Block &bl = fn.blocks[b];
        if (!bl.phis.empty()) {
            phiTmp.resize(bl.phis.size());
            for (size_t i = 0; i < bl.phis.size(); ++i) phiTmp[i] = V[bl.phis[i].args[predIdx]];
            for (size_t i = 0; i < bl.phis.size(); ++i) V[bl.phis[i].res] = phiTmp[i];
        }
        for (const Ins &in : bl.ins) {
            const uint32_t *a = in.args.data();
            uint64_t r = 0;
            switch (in.op) {
            case Op::LoadCell: std::memcpy(&r, AS<void>(in.imm[0]), 8); break;
            case Op::StoreCell: std::memcpy(AS<void>(in.imm[0]), &V[a[0]], 8); break;
            case Op::Load: std::memcpy(&r, AS<void>(V[a[0]]), 8); break;
            case Op::Store: std::memcpy(AS<void>(V[a[0]]), &V[a[1]], 8); break;
            case Op::FAdd: r = B(F(V[a[0]]) + F(V[a[1]])); break;
            case Op::FSub: r = B(F(V[a[0]]) - F(V[a[1]])); break;
            case Op::FMul: r = B(F(V[a[0]]) * F(V[a[1]])); break;
            case Op::FDiv: r = B(F(V[a[0]]) / F(V[a[1]])); break;
            case Op::FNeg: r = B(-F(V[a[0]])); break;
            case Op::FAbs: r = B(fabs(F(V[a[0]]))); break;
            case Op::FSqr: { const double x = F(V[a[0]]); r = B(x * x); break; }
            case Op::FSign: r = B(etvm_sign(F(V[a[0]]))); break;
            case Op::InvSqrt: r = B(etvm_invsqrt(F(V[a[0]]))); break;
            case Op::FMin2: r = B(etvm_fmin2(F(V[a[0]]), F(V[a[1]]))); break;
            case Op::FMax2: r = B(etvm_fmax2(F(V[a[0]]), F(V[a[1]]))); break;
            case Op::Filter: r = B(etvm_filter(F(V[a[0]]))); break;
            case Op::IAnd: r = B(etvm_iand(F(V[a[0]]), F(V[a[1]]))); break;
            case Op::IOr: r = B(etvm_ior(F(V[a[0]]), F(V[a[1]]))); break;
            case Op::IXor: r = B(etvm_ixor(F(V[a[0]]), F(V[a[1]]))); break;
            case Op::IOr0: r = B(etvm_ior0(F(V[a[0]]))); break;
            case Op::IMod: r = B(etvm_imod(F(V[a[0]]), F(V[a[1]]))); break;
            case Op::IShl: r = B(etvm_ishl(F(V[a[0]]), F(V[a[1]]))); break;
            case Op::IShr: r = B(etvm_ishr(F(V[a[0]]), F(V[a[1]]))); break;
            case Op::CallF1: r = B(((F1)(uintptr_t)in.imm[0])(F(V[a[0]]))); break;
            case Op::CallF2: r = B(((F2)(uintptr_t)in.imm[0])(F(V[a[0]]), F(V[a[1]]))); break;
            case Op::CmpEqClose: r = etvm_eq_close(F(V[a[0]]), F(V[a[1]])); break;
            case Op::CmpNeClose: r = etvm_ne_close(F(V[a[0]]), F(V[a[1]])); break;
            case Op::CmpEq: r = F(V[a[0]]) == F(V[a[1]]); break;
            case Op::CmpNe: r = F(V[a[0]]) != F(V[a[1]]); break;
            case Op::CmpLt: r = F(V[a[0]]) < F(V[a[1]]); break;
            case Op::CmpGe: r = F(V[a[0]]) >= F(V[a[1]]); break;
            case Op::Truthy: r = etvm_truthy(F(V[a[0]])); break;
            case Op::Falsy: r = etvm_falsy(F(V[a[0]])); break;
            case Op::BNot: r = V[a[0]] ? 0 : 1; break;
            case Op::BoolToF: r = B(V[a[0]] ? 1.0 : 0.0); break;
            case Op::PtrNonNull: r = V[a[0]] != 0; break;
            case Op::BoolToPtr: r = V[a[0]] ? 1 : 0; break; // EEL_BC_TRUE は (EEL_F*)1
            case Op::PtrMin: {
                const EEL_F *p1 = AS<EEL_F>(V[a[0]]), *p2 = AS<EEL_F>(V[a[1]]);
                if (*p1 > *p2) p1 = p2;
                r = P(p1);
                break;
            }
            case Op::PtrMax: {
                const EEL_F *p1 = AS<EEL_F>(V[a[0]]), *p2 = AS<EEL_F>(V[a[1]]);
                if (*p1 < *p2) p1 = p2;
                r = P(p1);
                break;
            }
            case Op::MemAddr: r = P(etvm_megabuf(AS<void>(in.imm[0]), F(V[a[0]]))); break;
            case Op::GMemAddr: r = P(etvm_gmegabuf(AS<void>(in.imm[0]), F(V[a[0]]))); break;
            case Op::CallG: {
                void *o = AS<void>(in.imm[1]);
                switch (in.args.size()) {
                case 1: r = P(((G1)(uintptr_t)in.imm[0])(o, AS<EEL_F>(V[a[0]]))); break;
                case 2: r = P(((G2)(uintptr_t)in.imm[0])(o, AS<EEL_F>(V[a[0]]), AS<EEL_F>(V[a[1]]))); break;
                default:
                    r = P(((G3)(uintptr_t)in.imm[0])(o, AS<EEL_F>(V[a[0]]), AS<EEL_F>(V[a[1]]), AS<EEL_F>(V[a[2]])));
                    break;
                }
                break;
            }
            case Op::CallGD: {
                void *o = AS<void>(in.imm[1]);
                switch (in.args.size()) {
                case 1: r = B(((G1D)(uintptr_t)in.imm[0])(o, AS<EEL_F>(V[a[0]]))); break;
                case 2: r = B(((G2D)(uintptr_t)in.imm[0])(o, AS<EEL_F>(V[a[0]]), AS<EEL_F>(V[a[1]]))); break;
                default:
                    r = B(((G3D)(uintptr_t)in.imm[0])(o, AS<EEL_F>(V[a[0]]), AS<EEL_F>(V[a[1]]), AS<EEL_F>(V[a[2]])));
                    break;
                }
                break;
            }
            case Op::CallGXD:
                r = B(((GXD)(uintptr_t)in.imm[0])(AS<void>(in.imm[1]), AS<void>(in.imm[2]), AS<EEL_F>(V[a[0]]),
                                                   AS<EEL_F>(V[a[1]])));
                break;
            case Op::CallVarparm: case Op::CallVarparmX: {
                // portable は p2 = 数（ポインタの形）、p1 = 積み場の上のポインタの並び（EEL_F **）を渡す。
                const size_t n = in.args.size();
                if (st.scratch.size() < n + 1) st.scratch.resize(n + 1);
                for (size_t k = 0; k < n; ++k) st.scratch[k] = AS<void>(V[a[k]]);
                EEL_F **arr = (EEL_F **)(void *)st.scratch.data();
                if (in.op == Op::CallVarparm) r = B(((VP)(uintptr_t)in.imm[0])(AS<void>(in.imm[1]), (INT_PTR)n, arr));
                else r = B(((VPX)(uintptr_t)in.imm[0])(AS<void>(in.imm[1]), AS<void>(in.imm[2]), (INT_PTR)n, arr));
                break;
            }
            case Op::UStackPush: {
                UINT_PTR *sptr = AS<UINT_PTR>(in.imm[0]);
                (*sptr) += 8;
                (*sptr) &= (UINT_PTR)in.imm[1];
                (*sptr) |= (UINT_PTR)in.imm[2];
                std::memcpy((void *)*sptr, AS<void>(V[a[0]]), 8);
                break;
            }
            case Op::UStackPop: {
                UINT_PTR *sptr = AS<UINT_PTR>(in.imm[0]);
                std::memcpy(AS<void>(V[a[0]]), (void *)*sptr, 8);
                (*sptr) -= 8;
                (*sptr) &= (UINT_PTR)in.imm[1];
                (*sptr) |= (UINT_PTR)in.imm[2];
                break;
            }
            case Op::UStackPopFast: {
                UINT_PTR *sptr = AS<UINT_PTR>(in.imm[0]);
                r = (uint64_t)*sptr;
                (*sptr) -= 8;
                (*sptr) &= (UINT_PTR)in.imm[1];
                (*sptr) |= (UINT_PTR)in.imm[2];
                break;
            }
            case Op::UStackPeek: {
                UINT_PTR s = *AS<UINT_PTR>(in.imm[0]);
                s -= sizeof(EEL_F) * (int)(F(V[a[0]]));
                s &= (UINT_PTR)in.imm[1];
                s |= (UINT_PTR)in.imm[2];
                r = (uint64_t)s;
                break;
            }
            case Op::UStackPeekInt: {
                UINT_PTR s = *AS<UINT_PTR>(in.imm[0]);
                s -= (UINT_PTR)in.imm[1];
                s &= (UINT_PTR)in.imm[2];
                s |= (UINT_PTR)in.imm[3];
                r = (uint64_t)s;
                break;
            }
            case Op::UStackPeekTop: r = P(*AS<EEL_F *>(in.imm[0])); break;
            case Op::UStackExch: {
                EEL_F *p = *AS<EEL_F *>(in.imm[0]);
                EEL_F *p1 = AS<EEL_F>(V[a[0]]);
                uint64_t t;
                std::memcpy(&t, p, 8);
                std::memcpy(p, p1, 8);
                std::memcpy(p1, &t, 8);
                break;
            }
            case Op::LoopCount: r = (uint64_t)(uint32_t)etvm_loop_count(F(V[a[0]])); break;
            case Op::ILt1: r = (int32_t)(uint32_t)V[a[0]] < 1; break;
            case Op::IDec: r = (uint64_t)(uint32_t)((int32_t)(uint32_t)V[a[0]] - 1); break;
            case Op::IGt0: r = (int32_t)(uint32_t)V[a[0]] > 0; break;
            case Op::PtrConst: case Op::BoolConst: case Op::I32Const: case Op::FConst: case Op::Phi: case Op::Count:
                break;
            }
            if (in.res != kNoValue) V[in.res] = r;
        }
        switch (bl.term) {
        case Term::Br: predIdx = bl.succPredIdx[0]; b = bl.succ[0]; break;
        case Term::CondBr: {
            const int k = V[bl.cond] ? 0 : 1;
            predIdx = bl.succPredIdx[k];
            b = bl.succ[k];
            break;
        }
        case Term::Ret: case Term::None: return;
        }
    }
}

} // namespace etvm
