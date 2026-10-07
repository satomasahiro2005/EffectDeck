// ETVMIR.cpp — 中間表現の型の約束・確かめ（verifier）・表示（printer）。
#include "ETVMIR.h"

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstring>

namespace etvm {

const char *opName(Op op)
{
    static const char *const names[] = {
        "ptrconst", "boolconst", "i32const", "loadcell", "storecell", "load", "store",
        "fadd", "fsub", "fmul", "fdiv", "fneg", "fabs", "fsqr", "fsign", "invsqrt", "fmin2", "fmax2", "filter",
        "iand", "ior", "ixor", "ior0", "imod", "ishl", "ishr", "callf1", "callf2",
        "cmpeqclose", "cmpneclose", "cmpeq", "cmpne", "cmplt", "cmpge", "truthy", "falsy",
        "bnot", "booltof", "ptrnonnull", "booltoptr", "ptrmin", "ptrmax", "memaddr", "gmemaddr",
        "callg", "callgd", "callgxd", "callvarparm", "callvarparmx",
        "ustack.push", "ustack.pop", "ustack.popfast", "ustack.peek", "ustack.peekint", "ustack.peektop",
        "ustack.exch", "loopcount", "ilt1", "idec", "igt0", "phi",
    };
    static_assert(sizeof names / sizeof *names == (size_t)Op::Count, "opName table");
    return (size_t)op < (size_t)Op::Count ? names[(size_t)op] : "?";
}

const char *tyName(Ty ty)
{
    switch (ty) {
    case Ty::Void: return "void";
    case Ty::F64: return "f64";
    case Ty::Ptr: return "ptr";
    case Ty::Bool: return "bool";
    case Ty::I32: return "i32";
    }
    return "?";
}

OpSig opSig(Op op)
{
    using T = Ty;
    switch (op) {
    case Op::PtrConst: return {0, T::Void, T::Ptr, 1};
    case Op::BoolConst: return {0, T::Void, T::Bool, 1};
    case Op::I32Const: return {0, T::Void, T::I32, 1};
    case Op::LoadCell: return {0, T::Void, T::F64, 1};
    case Op::StoreCell: return {1, T::F64, T::Void, 1};
    case Op::Load: return {1, T::Ptr, T::F64, 0};
    case Op::Store: return {2, T::Void, T::Void, 0}; // ptr, f64（下で別に見る）
    case Op::FAdd: case Op::FSub: case Op::FMul: case Op::FDiv: case Op::FMin2: case Op::FMax2:
    case Op::IAnd: case Op::IOr: case Op::IXor: case Op::IMod: case Op::IShl: case Op::IShr:
        return {2, T::F64, T::F64, 0};
    case Op::FNeg: case Op::FAbs: case Op::FSqr: case Op::FSign: case Op::InvSqrt: case Op::Filter: case Op::IOr0:
        return {1, T::F64, T::F64, 0};
    case Op::CallF1: return {1, T::F64, T::F64, 1};
    case Op::CallF2: return {2, T::F64, T::F64, 1};
    case Op::CmpEqClose: case Op::CmpNeClose: case Op::CmpEq: case Op::CmpNe: case Op::CmpLt: case Op::CmpGe:
        return {2, T::F64, T::Bool, 0};
    case Op::Truthy: case Op::Falsy: return {1, T::F64, T::Bool, 0};
    case Op::BNot: return {1, T::Bool, T::Bool, 0};
    case Op::BoolToF: return {1, T::Bool, T::F64, 0};
    case Op::PtrNonNull: return {1, T::Ptr, T::Bool, 0};
    case Op::BoolToPtr: return {1, T::Bool, T::Ptr, 0};
    case Op::PtrMin: case Op::PtrMax: return {2, T::Ptr, T::Ptr, 0};
    case Op::MemAddr: case Op::GMemAddr: return {1, T::F64, T::Ptr, 1};
    case Op::CallG: return {-1, T::Ptr, T::Ptr, 2};
    case Op::CallGD: return {-1, T::Ptr, T::F64, 2};
    case Op::CallGXD: return {2, T::Ptr, T::F64, 3};
    case Op::CallVarparm: return {-1, T::Ptr, T::F64, 3};
    case Op::CallVarparmX: return {-1, T::Ptr, T::F64, 4};
    case Op::UStackPush: case Op::UStackPop: return {1, T::Ptr, T::Void, 3};
    case Op::UStackPopFast: return {0, T::Void, T::Ptr, 3};
    case Op::UStackPeek: return {1, T::F64, T::Ptr, 3};
    case Op::UStackPeekInt: return {0, T::Void, T::Ptr, 4};
    case Op::UStackPeekTop: return {0, T::Void, T::Ptr, 1};
    case Op::UStackExch: return {1, T::Ptr, T::Void, 1};
    case Op::LoopCount: return {1, T::F64, T::I32, 0};
    case Op::ILt1: case Op::IGt0: return {1, T::I32, T::Bool, 0};
    case Op::IDec: return {1, T::I32, T::I32, 0};
    case Op::Phi: return {-1, T::Void, T::Void, 0};
    case Op::Count: break;
    }
    return {0, T::Void, T::Void, 0};
}

bool opHasMemoryEffect(Op op)
{
    switch (op) {
    case Op::LoadCell: case Op::StoreCell: case Op::Load: case Op::Store: case Op::PtrMin: case Op::PtrMax:
    case Op::MemAddr: case Op::GMemAddr: case Op::CallF1: case Op::CallF2: // rand は大域の状態を持つ
    case Op::CallG: case Op::CallGD: case Op::CallGXD: case Op::CallVarparm: case Op::CallVarparmX:
    case Op::UStackPush: case Op::UStackPop: case Op::UStackPopFast: case Op::UStackPeek:
    case Op::UStackPeekInt: case Op::UStackPeekTop: case Op::UStackExch:
        return true;
    default:
        return false;
    }
}

bool Function::constAddr(uint32_t v, uint64_t &addr) const
{
    if (v >= values.size() || values[v].block != -1) return false;
    const Ins &c = consts[values[v].index];
    if (c.op != Op::PtrConst) return false;
    addr = c.imm[0];
    return true;
}

size_t Function::instructionCount() const
{
    size_t n = consts.size();
    for (const Block &b : blocks) n += b.phis.size() + b.ins.size() + 1;
    return n;
}

void Function::finalize()
{
    for (size_t i = 0; i < consts.size(); ++i)
        if (consts[i].res != kNoValue) values[consts[i].res] = ValueInfo{consts[i].ty, -1, (uint32_t)i, false};
    for (size_t b = 0; b < blocks.size(); ++b) {
        Block &bl = blocks[b];
        for (size_t i = 0; i < bl.phis.size(); ++i)
            values[bl.phis[i].res] = ValueInfo{bl.phis[i].ty, (int32_t)b, (uint32_t)i, true};
        for (size_t i = 0; i < bl.ins.size(); ++i)
            if (bl.ins[i].res != kNoValue) values[bl.ins[i].res] = ValueInfo{bl.ins[i].ty, (int32_t)b, (uint32_t)i, false};
        const int ns = bl.term == Term::Br ? 1 : bl.term == Term::CondBr ? 2 : 0;
        // 同じ行き先へ 2 本（CondBr の両方が同じ）でも preds には 2 回入る。k 本目どうしを対にする。
        for (int s = 0; s < ns; ++s) {
            const Block &t = blocks[bl.succ[s]];
            int seen = 0;
            for (int k = 0; k < s; ++k) seen += bl.succ[k] == bl.succ[s];
            for (size_t p = 0; p < t.preds.size(); ++p)
                if (t.preds[p] == b && seen-- == 0) { bl.succPredIdx[s] = (uint32_t)p; break; }
        }
    }
}

namespace {
struct Verifier {
    const Function &fn;
    std::string &why;
    std::vector<int> rpoIndex, idom;
    std::vector<int> order;

    bool fail(const std::string &s) { why = s; return false; }

    bool dominates(int a, int b) const
    {
        // a が b を支配するか（idom を辿る。idom[0] = 0）
        for (;;) {
            if (b == a) return true;
            if (b == 0) return false;
            const int d = idom[b];
            if (d < 0 || d == b) return false;
            b = d;
        }
    }

    int intersect(int a, int b) const
    {
        while (a != b) {
            while (rpoIndex[a] > rpoIndex[b]) a = idom[a];
            while (rpoIndex[b] > rpoIndex[a]) b = idom[b];
        }
        return a;
    }

    bool buildDominators()
    {
        const int n = (int)fn.blocks.size();
        std::vector<int> state(n, 0);
        std::vector<std::pair<int, int>> stack;
        stack.push_back({0, 0});
        state[0] = 1;
        std::vector<int> post;
        while (!stack.empty()) {
            auto &[b, k] = stack.back();
            const Block &bl = fn.blocks[b];
            const int ns = bl.term == Term::Br ? 1 : bl.term == Term::CondBr ? 2 : 0;
            if (k < ns) {
                const int s = (int)bl.succ[k++];
                if (!state[s]) { state[s] = 1; stack.push_back({s, 0}); }
            } else {
                post.push_back(b);
                stack.pop_back();
            }
        }
        if ((int)post.size() != n) return fail("unreachable blocks (" + std::to_string(n - (int)post.size()) + ")");
        order.assign(post.rbegin(), post.rend());
        rpoIndex.assign(n, 0);
        for (int i = 0; i < n; ++i) rpoIndex[order[i]] = i;
        idom.assign(n, -1);
        idom[0] = 0;
        for (bool changed = true; changed;) {
            changed = false;
            for (int i = 1; i < n; ++i) {
                const int b = order[i];
                int nd = -1;
                for (uint32_t p : fn.blocks[b].preds) {
                    if (idom[p] < 0) continue;
                    nd = nd < 0 ? (int)p : intersect((int)p, nd);
                }
                if (nd != idom[b]) { idom[b] = nd; changed = true; }
            }
        }
        return true;
    }

    // v が（block, pos）の位置で使えるか。pos = -1 は phi の位置、SIZE_MAX 相当はブロックの終わり。
    bool available(uint32_t v, int block, long pos) const
    {
        const ValueInfo &vi = fn.values[v];
        if (vi.block < 0) return true;
        if (vi.block == block) {
            if (vi.phi) return pos >= 0;              // phi は ins とブロックの終わりから見える
            return pos > (long)vi.index;              // 前の命令
        }
        return dominates(vi.block, block);
    }

    bool checkIns(const Ins &in, int block, long pos)
    {
        auto where = [&]() {
            char b[96];
            std::snprintf(b, sizeof b, " (b%d #%ld %s pc %u)", block, pos, opName(in.op), in.pc);
            return std::string(b);
        };
        if ((size_t)in.op >= (size_t)Op::Count) return fail("bad op" + where());
        const OpSig sig = opSig(in.op);
        if (in.op != Op::Phi) {
            if (sig.nargs >= 0 && (int)in.args.size() != sig.nargs) return fail("arg count" + where());
            if (in.ty != sig.ret) return fail("result type" + where());
        }
        if ((in.ty == Ty::Void) != (in.res == kNoValue)) return fail("result id" + where());
        if (in.res != kNoValue) {
            if (in.res >= fn.values.size()) return fail("result out of range" + where());
            const ValueInfo &vi = fn.values[in.res];
            if (vi.ty != in.ty || vi.block != block || vi.phi != (in.op == Op::Phi)) return fail("value table" + where());
        }
        for (size_t k = 0; k < in.args.size(); ++k) {
            const uint32_t a = in.args[k];
            if (a >= fn.values.size()) return fail("arg out of range" + where());
            Ty want = sig.arg;
            if (in.op == Op::Store) want = k == 0 ? Ty::Ptr : Ty::F64;
            if (in.op == Op::Phi) want = in.ty;
            if (fn.values[a].ty != want) return fail(std::string("arg type ") + tyName(fn.values[a].ty) + where());
            if (in.op == Op::Phi) {
                const uint32_t p = fn.blocks[block].preds[k];
                if (!available(a, (int)p, 1L << 40)) return fail("phi arg does not dominate pred" + where());
            } else if (!available(a, block, pos)) {
                return fail("use not dominated by def" + where());
            }
        }
        switch (in.op) {
        case Op::CallG: case Op::CallGD:
            if (in.args.empty() || in.args.size() > 3) return fail("callg arity" + where());
            break;
        case Op::CallVarparm:
            if (in.args.size() != in.imm[2]) return fail("varparm count" + where());
            break;
        case Op::CallVarparmX:
            if (in.args.size() != in.imm[3]) return fail("varparmx count" + where());
            break;
        case Op::Phi:
            if (in.args.size() != fn.blocks[block].preds.size()) return fail("phi arity" + where());
            if (in.ty == Ty::Void) return fail("phi type" + where());
            break;
        default: break;
        }
        return true;
    }

    bool run()
    {
        if (fn.blocks.empty()) return fail("no blocks");
        if (!fn.blocks[0].preds.empty()) return fail("entry has preds");
        const int n = (int)fn.blocks.size();
        for (int b = 0; b < n; ++b) {
            const Block &bl = fn.blocks[b];
            const int ns = bl.term == Term::Br ? 1 : bl.term == Term::CondBr ? 2 : 0;
            if (bl.term == Term::None) return fail("block b" + std::to_string(b) + " has no terminator");
            for (int s = 0; s < ns; ++s) {
                if (bl.succ[s] >= (uint32_t)n) return fail("bad succ in b" + std::to_string(b));
                const Block &t = fn.blocks[bl.succ[s]];
                if (bl.succPredIdx[s] >= t.preds.size() || t.preds[bl.succPredIdx[s]] != (uint32_t)b)
                    return fail("succPredIdx in b" + std::to_string(b));
            }
            if (ns == 2 && bl.succPredIdx[0] == bl.succPredIdx[1] && bl.succ[0] == bl.succ[1])
                return fail("double edge shares a pred slot in b" + std::to_string(b));
            // preds の数 = こちらへ来る辺の数
            for (uint32_t p : bl.preds) {
                if (p >= (uint32_t)n) return fail("bad pred");
                const Block &pb = fn.blocks[p];
                const int pns = pb.term == Term::Br ? 1 : pb.term == Term::CondBr ? 2 : 0;
                int edges = 0, listed = 0;
                for (int s = 0; s < pns; ++s) edges += pb.succ[s] == (uint32_t)b;
                for (uint32_t q : bl.preds) listed += q == p;
                if (edges != listed) return fail("pred/succ mismatch b" + std::to_string(p) + "->b" + std::to_string(b));
            }
            if (bl.term == Term::CondBr) {
                if (bl.cond >= fn.values.size() || fn.values[bl.cond].ty != Ty::Bool)
                    return fail("condbr cond in b" + std::to_string(b));
            }
        }
        for (const Ins &c : fn.consts) {
            if (c.op != Op::PtrConst && c.op != Op::BoolConst && c.op != Op::I32Const) return fail("non-const in consts");
            if (c.res == kNoValue || c.res >= fn.values.size() || fn.values[c.res].block != -1) return fail("const value");
        }
        if (!buildDominators()) return false;
        std::vector<uint8_t> defined(fn.values.size(), 0);
        auto def = [&](uint32_t r) {
            if (r == kNoValue) return true;
            if (defined[r]) return false;
            defined[r] = 1;
            return true;
        };
        for (const Ins &c : fn.consts) if (!def(c.res)) return fail("value defined twice");
        for (int b = 0; b < n; ++b) {
            const Block &bl = fn.blocks[b];
            for (size_t i = 0; i < bl.phis.size(); ++i) {
                if (bl.phis[i].op != Op::Phi) return fail("non-phi in phis");
                if (!def(bl.phis[i].res)) return fail("value defined twice");
                if (!checkIns(bl.phis[i], b, -1)) return false;
            }
            for (size_t i = 0; i < bl.ins.size(); ++i) {
                const Ins &in = bl.ins[i];
                if (in.op == Op::Phi || in.op == Op::PtrConst || in.op == Op::BoolConst || in.op == Op::I32Const)
                    return fail("phi/const in body of b" + std::to_string(b));
                if (!def(in.res)) return fail("value defined twice");
                if (!checkIns(in, b, (long)i)) return false;
            }
            if (bl.term == Term::CondBr && !available(bl.cond, b, 1L << 40)) return fail("cond not dominated");
        }
        for (size_t v = 0; v < fn.values.size(); ++v)
            if (!defined[v] && fn.values[v].ty != Ty::Void) return fail("value %" + std::to_string(v) + " never defined");
        return true;
    }
};
} // namespace

bool verify(const Function &fn, std::string &why)
{
    Verifier v{fn, why, {}, {}, {}};
    return v.run();
}

std::string print(const Function &fn, CellNamer namer, void *user)
{
    std::string out;
    char buf[256];
    auto addr = [&](uint64_t a) {
        std::string s;
        if (namer) s = namer(a, user);
        std::snprintf(buf, sizeof buf, "0x%" PRIx64, a);
        return s.empty() ? std::string(buf) : s + "@" + buf;
    };
    auto val = [&](uint32_t v) {
        std::snprintf(buf, sizeof buf, "%%%u", v);
        return std::string(buf);
    };
    auto line = [&](const Ins &in) {
        std::string s = "  ";
        if (in.res != kNoValue) s += val(in.res) + ":" + tyName(in.ty) + " = ";
        s += opName(in.op);
        switch (in.op) {
        case Op::PtrConst: s += " " + addr(in.imm[0]); break;
        case Op::BoolConst: case Op::I32Const:
            std::snprintf(buf, sizeof buf, " %" PRId64, (int64_t)in.imm[0]); s += buf; break;
        case Op::LoadCell: case Op::StoreCell: s += " " + addr(in.imm[0]); break;
        case Op::MemAddr: case Op::GMemAddr: case Op::CallF1: case Op::CallF2: case Op::UStackPeekTop: case Op::UStackExch:
            std::snprintf(buf, sizeof buf, " [0x%" PRIx64 "]", in.imm[0]); s += buf; break;
        case Op::CallG: case Op::CallGD: case Op::CallGXD: case Op::CallVarparm: case Op::CallVarparmX:
        case Op::UStackPush: case Op::UStackPop: case Op::UStackPopFast: case Op::UStackPeek: case Op::UStackPeekInt: {
            const int ni = opSig(in.op).nimm;
            s += " [";
            for (int k = 0; k < ni; ++k) {
                std::snprintf(buf, sizeof buf, "%s0x%" PRIx64, k ? " " : "", in.imm[k]);
                s += buf;
            }
            s += "]";
            break;
        }
        default: break;
        }
        for (size_t k = 0; k < in.args.size(); ++k) s += (k ? ", " : " ") + val(in.args[k]);
        std::snprintf(buf, sizeof buf, "    ; pc %u", in.pc);
        if (in.op != Op::PtrConst && in.op != Op::BoolConst && in.op != Op::I32Const && in.op != Op::Phi) s += buf;
        return s + "\n";
    };
    std::snprintf(buf, sizeof buf, "fn code=0x%" PRIx64 " blocks=%zu values=%zu insns=%zu\n", fn.codeBase,
                  fn.blocks.size(), fn.values.size(), fn.instructionCount());
    out += buf;
    out += "consts:\n";
    for (const Ins &c : fn.consts) out += line(c);
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        std::snprintf(buf, sizeof buf, "b%zu: ; pc %" PRIu64 " preds", b, bl.pc);
        out += buf;
        for (uint32_t p : bl.preds) { std::snprintf(buf, sizeof buf, " b%u", p); out += buf; }
        out += "\n";
        for (const Ins &in : bl.phis) {
            std::string s = "  " + val(in.res) + ":" + tyName(in.ty) + " = phi";
            for (size_t k = 0; k < in.args.size(); ++k) {
                std::snprintf(buf, sizeof buf, "%s[b%u %s]", k ? " " : " ", bl.preds[k], val(in.args[k]).c_str());
                s += buf;
            }
            out += s + "\n";
        }
        for (const Ins &in : bl.ins) out += line(in);
        switch (bl.term) {
        case Term::Br: std::snprintf(buf, sizeof buf, "  br b%u\n", bl.succ[0]); break;
        case Term::CondBr:
            std::snprintf(buf, sizeof buf, "  condbr %s ? b%u : b%u\n", val(bl.cond).c_str(), bl.succ[0], bl.succ[1]);
            break;
        case Term::Ret: std::snprintf(buf, sizeof buf, "  ret\n"); break;
        case Term::None: std::snprintf(buf, sizeof buf, "  <no terminator>\n"); break;
        }
        out += buf;
    }
    return out;
}

} // namespace etvm
