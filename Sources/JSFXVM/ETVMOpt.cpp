// ETVMOpt.cpp — 中間表現の上の最適化（段 S3）。ETVMOpt.h の注。
//
// ブロックの中を頭から 1 回なめる（ブロックをまたいだ事実は持たない。loop の後ろ向きの辺を気にしなくてよい）:
//   constcell  LoadCell(Const) → FConst（いまの升の値。非正規化数・NaN は畳まない）
//   fold       定数だけの純な演算 → 定数（ETVMOps.h の同じ式で。入力か結果が非正規化数・NaN なら畳まない:
//              建てるスレッドと音のスレッドで FPCR が違いうる。invsqrt・libm・rand は畳まない）
//   cse        同じ升を書かれる前に読み直す LoadCell → 前の値。同じ演算・同じ引数 → 前の値
//              （引数の順も鍵に入れる: + * でも入れ替えない。設計 §8.2）
//   fwd        StoreCell(c, v) のあと書かれる前の LoadCell(c) → v
//   promote    外へ漏れない作業表の升（PrivateTemp）にだけ fwd をし、読まれなくなった升への書き込みを消す
// 「書かれる」: StoreCell(c) は c だけ。Store・ユーザーの積み場の pop・exch はポインタの出所が定数の番地ならその升、
// megabuf・gmem・bool の番地なら升に重ならない、それ以外はどの升も。API の呼び出しはどの升も。Volatile の升は
// 読み直しを省かない（ほかのインスタンス・スレッドが書く）。
#include "ETVMOpt.h"

#include "ETVM.h"
#include "ETVMLink.h"
#include "ETVMOps.h"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <vector>

namespace etvm {

CellFacts cellFacts(const LinkReport &rep)
{
    CellFacts f;
    for (const auto &[addr, c] : rep.cells) {
        uint8_t k = 0;
        switch (c.cls) {
        case CellClass::Var: case CellClass::Static: k = CellFacts::Cacheable; break;
        case CellClass::Const: k = CellFacts::Cacheable | CellFacts::Const; break;
        case CellClass::Temp:
            k = CellFacts::Cacheable;
            if (!c.escaped && !c.storedIndirect && !c.loadedIndirect) k |= CellFacts::PrivateTemp;
            break;
        case CellClass::Volatile: k = 0; break;
        }
        if (k) f.cells[addr] = k;
    }
    return f;
}

namespace {

inline double F(uint64_t x) { double d; std::memcpy(&d, &x, 8); return d; }
inline uint64_t B(double d) { uint64_t x; std::memcpy(&x, &d, 8); return x; }

/// 畳んでよい f64（0・正規化数・無限大。非正規化数と NaN はだめ）
inline bool foldable(double d) { return !std::isnan(d) && (d == 0.0 || std::isinf(d) || std::fabs(d) >= 2.2250738585072014e-308); }
/// 整数に直す命令の入力（飽和の振る舞いに頼らない範囲）
inline bool smallInt(double d) { return std::isfinite(d) && std::fabs(d) < 2147483648.0; }

bool isPure(Op op)
{
    switch (op) {
    case Op::FAdd: case Op::FSub: case Op::FMul: case Op::FDiv: case Op::FNeg: case Op::FAbs: case Op::FSqr:
    case Op::FSign: case Op::InvSqrt: case Op::FMin2: case Op::FMax2: case Op::Filter:
    case Op::IAnd: case Op::IOr: case Op::IXor: case Op::IOr0: case Op::IMod: case Op::IShl: case Op::IShr:
    case Op::CmpEqClose: case Op::CmpNeClose: case Op::CmpEq: case Op::CmpNe: case Op::CmpLt: case Op::CmpGe:
    case Op::Truthy: case Op::Falsy: case Op::BNot: case Op::BoolToF: case Op::PtrNonNull: case Op::BoolToPtr:
    case Op::LoopCount: case Op::ILt1: case Op::IDec: case Op::IGt0:
        return true;
    default:
        return false;
    }
}

bool isCall(Op op)
{
    return op == Op::CallG || op == Op::CallGD || op == Op::CallGXD || op == Op::CallVarparm || op == Op::CallVarparmX;
}

struct Opt {
    Function &fn;
    const uint32_t passes;
    const CellFacts &facts;
    OptStats st;
    std::vector<uint32_t> repl;
    std::map<std::pair<int, uint64_t>, uint32_t> constCache; // (op, ビット) → 値

    Opt(Function &f, uint32_t p, const CellFacts &c) : fn(f), passes(p), facts(c) {}

    bool on(uint32_t bit) const { return (passes & bit) != 0; }

    uint32_t R(uint32_t v) const
    {
        while (v < repl.size() && repl[v] != kNoValue) v = repl[v];
        return v;
    }

    uint32_t makeConst(Op op, Ty ty, uint64_t bits)
    {
        auto key = std::make_pair((int)op, bits);
        auto it = constCache.find(key);
        if (it != constCache.end()) return it->second;
        const uint32_t v = fn.newValue(ty);
        fn.values[v].block = -1;
        fn.values[v].index = (uint32_t)fn.consts.size();
        Ins c;
        c.op = op;
        c.ty = ty;
        c.res = v;
        c.imm[0] = bits;
        fn.consts.push_back(c);
        repl.push_back(kNoValue);
        constCache.emplace(key, v);
        return v;
    }

    const Ins *defOf(uint32_t v) const
    {
        if (v >= fn.values.size()) return nullptr;
        const ValueInfo &x = fn.values[v];
        if (x.block < 0) return fn.constIns(v);
        const Block &bl = fn.blocks[(size_t)x.block];
        return x.phi ? &bl.phis[x.index] : &bl.ins[x.index];
    }

    /// 定数ならビット（op で種類）
    bool cval(uint32_t v, Op want, uint64_t &bits) const
    {
        const Ins *c = fn.constIns(v);
        if (!c || c->op != want) return false;
        bits = c->imm[0];
        return true;
    }

    /// 定数だけの純な演算を畳む。畳めたら新しい値（定数）を返す。
    uint32_t fold(const Ins &in)
    {
        const size_t n = in.args.size();
        uint64_t a = 0, b = 0;
        const bool f2 = n == 2 && cval(in.args[0], Op::FConst, a) && cval(in.args[1], Op::FConst, b);
        const bool f1 = n == 1 && cval(in.args[0], Op::FConst, a);
        const double x = F(a), y = F(b);
        auto fres = [&](double r) -> uint32_t {
            if (!foldable(r)) return kNoValue;
            return makeConst(Op::FConst, Ty::F64, B(r));
        };
        auto bres = [&](bool r) { return makeConst(Op::BoolConst, Ty::Bool, r ? 1 : 0); };
        if (f2) {
            if (!foldable(x) || !foldable(y)) return kNoValue;
            switch (in.op) {
            case Op::FAdd: return fres(x + y);
            case Op::FSub: return fres(x - y);
            case Op::FMul: return fres(x * y);
            case Op::FDiv: return fres(x / y);
            case Op::FMin2: return fres(etvm_fmin2(x, y));
            case Op::FMax2: return fres(etvm_fmax2(x, y));
            case Op::IAnd: return smallInt(x) && smallInt(y) ? fres(etvm_iand(x, y)) : kNoValue;
            case Op::IOr: return smallInt(x) && smallInt(y) ? fres(etvm_ior(x, y)) : kNoValue;
            case Op::IXor: return smallInt(x) && smallInt(y) ? fres(etvm_ixor(x, y)) : kNoValue;
            case Op::IMod: return smallInt(x) && smallInt(y) ? fres(etvm_imod(x, y)) : kNoValue;
            case Op::IShl: return smallInt(x) && smallInt(y) ? fres(etvm_ishl(x, y)) : kNoValue;
            case Op::IShr: return smallInt(x) && smallInt(y) ? fres(etvm_ishr(x, y)) : kNoValue;
            case Op::CmpEqClose: return bres(etvm_eq_close(x, y));
            case Op::CmpNeClose: return bres(etvm_ne_close(x, y));
            case Op::CmpEq: return bres(x == y);
            case Op::CmpNe: return bres(x != y);
            case Op::CmpLt: return bres(x < y);
            case Op::CmpGe: return bres(x >= y);
            default: return kNoValue;
            }
        }
        if (f1) {
            if (!foldable(x)) return kNoValue;
            switch (in.op) {
            case Op::FNeg: return fres(-x);
            case Op::FAbs: return fres(std::fabs(x));
            case Op::FSqr: return fres(x * x);
            case Op::FSign: return fres(etvm_sign(x));
            case Op::Filter: return fres(etvm_filter(x));
            case Op::IOr0: return smallInt(x) ? fres(etvm_ior0(x)) : kNoValue;
            case Op::Truthy: return bres(etvm_truthy(x));
            case Op::Falsy: return bres(etvm_falsy(x));
            case Op::LoopCount:
                return smallInt(x) ? makeConst(Op::I32Const, Ty::I32, (uint64_t)(uint32_t)etvm_loop_count(x)) : kNoValue;
            default: return kNoValue;
            }
        }
        if (n == 1) {
            uint64_t k = 0;
            if (cval(in.args[0], Op::BoolConst, k)) {
                switch (in.op) {
                case Op::BNot: return bres(!k);
                case Op::BoolToF: return makeConst(Op::FConst, Ty::F64, B(k ? 1.0 : 0.0));
                default: return kNoValue;
                }
            }
            if (cval(in.args[0], Op::I32Const, k)) {
                const int32_t c = (int32_t)(uint32_t)k;
                switch (in.op) {
                case Op::ILt1: return bres(c < 1);
                case Op::IGt0: return bres(c > 0);
                case Op::IDec: return makeConst(Op::I32Const, Ty::I32, (uint64_t)(uint32_t)((uint32_t)c - 1u));
                default: return kNoValue;
                }
            }
            if (cval(in.args[0], Op::PtrConst, k) && in.op == Op::PtrNonNull) return bres(k != 0);
        }
        return kNoValue;
    }

    struct Avail { uint32_t v; bool stored; };

    void run()
    {
        const size_t nv0 = fn.values.size();
        repl.assign(nv0, kNoValue);
        for (const Ins &c : fn.consts) constCache.emplace(std::make_pair((int)c.op, c.imm[0]), c.res);
        std::vector<std::vector<uint8_t>> dead(fn.blocks.size());
        std::map<uint64_t, Avail> avail;
        std::map<std::vector<uint64_t>, uint32_t> pure;
        for (size_t b = 0; b < fn.blocks.size(); ++b) {
            Block &bl = fn.blocks[b];
            dead[b].assign(bl.ins.size(), 0);
            avail.clear();
            pure.clear();
            for (size_t i = 0; i < bl.ins.size(); ++i) {
                Ins &in = bl.ins[i];
                for (uint32_t &a : in.args) a = R(a);
                switch (in.op) {
                case Op::LoadCell: {
                    const uint64_t c = in.imm[0];
                    const uint8_t k = facts.of(c);
                    if (on(ETVM_PASS_CONSTCELL) && (k & CellFacts::Const)) {
                        uint64_t bits;
                        std::memcpy(&bits, (const void *)(uintptr_t)c, 8);
                        if (foldable(F(bits))) {
                            repl[in.res] = makeConst(Op::FConst, Ty::F64, bits);
                            dead[b][i] = 1;
                            ++st.constCells;
                            break;
                        }
                    }
                    if (!(k & CellFacts::Cacheable)) break;
                    auto it = avail.find(c);
                    if (it != avail.end()) {
                        const bool fwd = on(ETVM_PASS_FWD) || (on(ETVM_PASS_PROMOTE) && (k & CellFacts::PrivateTemp));
                        if (it->second.stored ? fwd : on(ETVM_PASS_CSE)) {
                            repl[in.res] = it->second.v;
                            dead[b][i] = 1;
                            ++(it->second.stored ? st.forwarded : st.cseLoads);
                            break;
                        }
                    }
                    avail[c] = Avail{in.res, false};
                    break;
                }
                case Op::StoreCell: {
                    const uint64_t c = in.imm[0];
                    if (facts.of(c) & CellFacts::Cacheable) avail[c] = Avail{in.args[0], true};
                    else avail.erase(c);
                    break;
                }
                case Op::Store: case Op::UStackPop: case Op::UStackExch: {
                    uint64_t addr = 0;
                    if (fn.constAddr(in.args[0], addr)) { avail.erase(addr); break; }
                    const Ins *d = defOf(in.args[0]);
                    if (d && (d->op == Op::MemAddr || d->op == Op::GMemAddr || d->op == Op::BoolToPtr)) break;
                    avail.clear();
                    break;
                }
                default:
                    if (isCall(in.op)) { avail.clear(); break; }
                    if (!isPure(in.op)) break;
                    if (on(ETVM_PASS_FOLD)) {
                        const uint32_t k = fold(in);
                        if (k != kNoValue) {
                            repl[in.res] = k;
                            dead[b][i] = 1;
                            ++st.folded;
                            break;
                        }
                    }
                    if (on(ETVM_PASS_CSE)) {
                        std::vector<uint64_t> key;
                        key.reserve(4 + in.args.size());
                        key.push_back((uint64_t)in.op);
                        key.push_back((uint64_t)in.ty);
                        for (uint32_t a : in.args) key.push_back(a);
                        auto [it, fresh] = pure.emplace(std::move(key), in.res);
                        if (!fresh) {
                            repl[in.res] = it->second;
                            dead[b][i] = 1;
                            ++st.csePure;
                        }
                    }
                    break;
                }
            }
        }
        // 外へ漏れない作業表の升で、もう誰も読まないものへの書き込みを消す（作業表の中身は観測されない:
        // ysfx の口からも状態の指紋からも見えない。設計 §15.2 の 10）
        if (on(ETVM_PASS_PROMOTE)) {
            std::map<uint64_t, size_t> reads;
            for (size_t b = 0; b < fn.blocks.size(); ++b)
                for (size_t i = 0; i < fn.blocks[b].ins.size(); ++i) {
                    const Ins &in = fn.blocks[b].ins[i];
                    if (in.op == Op::LoadCell && !dead[b][i]) ++reads[in.imm[0]];
                }
            for (size_t b = 0; b < fn.blocks.size(); ++b)
                for (size_t i = 0; i < fn.blocks[b].ins.size(); ++i) {
                    const Ins &in = fn.blocks[b].ins[i];
                    if (in.op != Op::StoreCell || !(facts.of(in.imm[0]) & CellFacts::PrivateTemp)) continue;
                    if (reads[in.imm[0]] == 0) { dead[b][i] = 1; ++st.deadStores; }
                }
        }
        // 置き換えを全部に当て、消した命令を抜く
        for (size_t b = 0; b < fn.blocks.size(); ++b) {
            Block &bl = fn.blocks[b];
            for (Ins &p : bl.phis) for (uint32_t &a : p.args) a = R(a);
            std::vector<Ins> keep;
            keep.reserve(bl.ins.size());
            for (size_t i = 0; i < bl.ins.size(); ++i) {
                if (dead[b][i]) continue;
                for (uint32_t &a : bl.ins[i].args) a = R(a);
                keep.push_back(std::move(bl.ins[i]));
            }
            bl.ins = std::move(keep);
            if (bl.term == Term::CondBr) bl.cond = R(bl.cond);
        }
        // 置き換えられた値は表から外す（verifier が「定義の無い値」と言わないように型を Void に）
        for (size_t v = 0; v < repl.size(); ++v)
            if (repl[v] != kNoValue) fn.values[v] = ValueInfo{};
        fn.finalize();
    }
};

std::atomic<uint32_t> gPasses{0};
std::atomic<bool> gPassesInit{false};

} // namespace

bool optimize(Function &fn, uint32_t passes, const CellFacts &facts, OptStats *stats, std::string *why)
{
    const uint32_t irMask = ETVM_PASS_CONSTCELL | ETVM_PASS_FOLD | ETVM_PASS_CSE | ETVM_PASS_FWD | ETVM_PASS_PROMOTE;
    if (!(passes & irMask)) return true;
    Function orig = fn;
    Opt o(fn, passes, facts);
    o.run();
    std::string w;
    if (!verify(fn, w)) {
        fn = std::move(orig);
        o.st = OptStats{};
        o.st.verifyFailed = 1;
        if (stats) *stats += o.st;
        if (why) *why = w;
        return false;
    }
    if (stats) *stats += o.st;
    return true;
}

uint32_t currentPasses() { return ETVM_GetPasses(); }

} // namespace etvm

namespace {
struct PassName { const char *name; uint32_t bit; };
const PassName kPassNames[] = {
    {"constcell", ETVM_PASS_CONSTCELL}, {"fold", ETVM_PASS_FOLD}, {"cse", ETVM_PASS_CSE}, {"fwd", ETVM_PASS_FWD},
    {"promote", ETVM_PASS_PROMOTE}, {"ldfold", ETVM_PASS_LDFOLD}, {"direct", ETVM_PASS_DIRECT},
    {"fuse", ETVM_PASS_FUSE}, {"loop", ETVM_PASS_LOOP}, {"cmpbr", ETVM_PASS_CMPBR}, {"opimm", ETVM_PASS_OPIMM},
    {"opto", ETVM_PASS_OPTO}, {"membi", ETVM_PASS_MEMBI}, {"fuse2", ETVM_PASS_FUSE2},
    {"lkern", ETVM_PASS_LKERN},
};
} // namespace

extern "C" uint32_t ETVM_ParsePasses(const char *spec, uint32_t base, const char **bad)
{
    uint32_t m = base;
    if (!spec) return m;
    const char *p = spec;
    while (*p) {
        while (*p == ',' || *p == ' ') ++p;
        if (!*p) break;
        const char *e = p;
        while (*e && *e != ',' && *e != ' ') ++e;
        std::string tok(p, (size_t)(e - p));
        p = e;
        bool add = true;
        if (tok[0] == '-' || tok[0] == '+') { add = tok[0] == '+'; tok.erase(0, 1); }
        if (tok == "all") { m = add ? ETVM_PASSES_ALL : 0; continue; }
        if (tok == "none") { m = add ? 0 : ETVM_PASSES_ALL; continue; }
        if (tok == "ir") { m = add ? (m | 0x1fu) : (m & ~0x1fu); continue; }
        uint32_t bit = 0;
        for (const PassName &n : kPassNames) if (tok == n.name) bit = n.bit;
        if (!bit) {
            if (bad) *bad = spec;
            continue;
        }
        m = add ? (m | bit) : (m & ~bit);
    }
    return m;
}

extern "C" void ETVM_SetPasses(uint32_t passes)
{
    etvm::gPasses.store(passes & ETVM_PASSES_ALL, std::memory_order_relaxed);
    etvm::gPassesInit.store(true, std::memory_order_release);
}

extern "C" uint32_t ETVM_GetPasses(void)
{
    if (!etvm::gPassesInit.load(std::memory_order_acquire)) {
        // 初めて: 環境変数 ETVM_PASSES（無ければ全部）
        const char *bad = nullptr;
        const uint32_t m = ETVM_ParsePasses(std::getenv("ETVM_PASSES"), ETVM_PASSES_ALL, &bad);
        if (bad) std::fprintf(stderr, "ETVM_PASSES: unknown pass in \"%s\" (ignored)\n", bad);
        ETVM_SetPasses(m);
    }
    return etvm::gPasses.load(std::memory_order_relaxed);
}
