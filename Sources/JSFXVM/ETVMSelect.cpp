// ETVMSelect.cpp — 中間表現から threaded code（ETVMHandlers.cpp のハンドラの列）を作る。段 S2。
// docs/jsfx-regvm-design.md §9.1–9.5（tier 1: 中間表現の命令 1 つにハンドラ 1 つ、オペランドは全部が絶対番地）。
//
// 並べる前にすること（どれも「portable と同じ順・同じ番地で読み書きする」を崩さない範囲だけ）:
//   1. 使われない純な値は出さない（根 = 書く・呼ぶ・確保する命令と分かれ道の条件から辿れないもの）
//   2. LoadCell をオペランドへ畳む: 同じブロックの中の使う所までに、その升へ書きうる命令が無ければ、
//      使う命令がその升を直に読む（設計 §9.2: 升も枠も同じ double *）
//   3. 行き先をじかに: StoreCell(c, v) の v が同じブロックの演算 1 か所でしか使われず、その間に c を
//      読む・書きうる命令が無ければ、演算が c へ書き、StoreCell は出さない（設計 §8.1 の 9 を前倒し）
//   4. 並んだ 2 つを 1 つに: 四則 + フィルタ（フィルタ付きの代入）、megabuf の番地 + 読む／書く
//      （間に何も出ないときだけ。読む・確保する時点は変わらない）
//   5. 升: ブロックの外で使う値・phi は専用の升、ブロックの中だけの値は使い終わった升を使い回す。
//      phi の引数が phi の最後の使用より後に作られ、ほかで使われなければ同じ升にする（loop の数の写しが消える）
// 「書きうる・読みうる」はポインタの出所で決める: 定数の番地はその升だけ、megabuf・gmem の番地は升に重ならない、
// それ以外（API の返り値・phi・min/max の参照・ユーザーの積み場）はどの升でもありうる。API の呼び出しは全部の升を
// 読み書きしうる。
#include "ETVMExec.h"
#include "ETVMThreaded.h"

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <vector>

namespace etvm {

using namespace threaded;

struct ThreadedProgram {
    std::vector<Word> code;
    std::vector<Slot> frame;
    std::vector<void *> scratch;
    const Word *entry = nullptr;
    ThreadedStats stats;
    size_t nGlobal = 0, nLocal = 0, poolBase = 0, nPool = 0;
};

namespace {

constexpr int kNoSlot = -1;

struct Use {
    int block;
    int pos; // ブロックの中の位置。phi の写し・分かれ道の条件はブロックの命令の数（終わり）
    bool phi;
};

struct VInfo {
    int block = -1; // -1 = consts
    int pos = -1;   // phi は -1
    bool phi = false;
    bool live = false;
    bool folded = false;  // LoadCell をオペランドへ畳んだ（cell を読む）
    uint64_t cell = 0;
    bool direct = false;  // 結果を dstCell へじかに書く
    uint64_t dstCell = 0;
    bool fusedAway = false;
    bool global = false;
    bool coalesced = false;
    int slot = kNoSlot;
    int lastUse = -1;
    std::vector<Use> uses;
};

enum class Ptr : uint8_t { Cell, Ram, Unknown };

bool removable(Op op)
{
    switch (op) {
    case Op::LoadCell: case Op::Load:
    case Op::FAdd: case Op::FSub: case Op::FMul: case Op::FDiv: case Op::FNeg: case Op::FAbs: case Op::FSqr:
    case Op::FSign: case Op::InvSqrt: case Op::FMin2: case Op::FMax2: case Op::Filter:
    case Op::IAnd: case Op::IOr: case Op::IXor: case Op::IOr0: case Op::IMod: case Op::IShl: case Op::IShr:
    case Op::CmpEqClose: case Op::CmpNeClose: case Op::CmpEq: case Op::CmpNe: case Op::CmpLt: case Op::CmpGe:
    case Op::Truthy: case Op::Falsy: case Op::BNot: case Op::BoolToF: case Op::PtrNonNull: case Op::BoolToPtr:
    case Op::PtrMin: case Op::PtrMax: case Op::LoopCount: case Op::ILt1: case Op::IDec: case Op::IGt0: case Op::Phi:
        return true;
    default:
        return false; // 書く・呼ぶ（rand・API）・確保する（megabuf・gmem）・ユーザーの積み場
    }
}

/// 結果を double * の行き先へ書くハンドラになる命令（StoreCell の升へじかに書ける）。
bool hasF64Dest(Op op)
{
    switch (op) {
    case Op::LoadCell: case Op::Load:
    case Op::FAdd: case Op::FSub: case Op::FMul: case Op::FDiv: case Op::FNeg: case Op::FAbs: case Op::FSqr:
    case Op::FSign: case Op::InvSqrt: case Op::FMin2: case Op::FMax2: case Op::Filter:
    case Op::IAnd: case Op::IOr: case Op::IXor: case Op::IOr0: case Op::IMod: case Op::IShl: case Op::IShr:
    case Op::CallF1: case Op::CallF2: case Op::BoolToF:
    case Op::CallGD: case Op::CallGXD: case Op::CallVarparm: case Op::CallVarparmX:
        return true;
    default:
        return false;
    }
}

bool isCall(Op op)
{
    return op == Op::CallG || op == Op::CallGD || op == Op::CallGXD || op == Op::CallVarparm || op == Op::CallVarparmX;
}

struct Builder {
    const Function &fn;
    std::string &why;
    ThreadedStats st;
    std::vector<VInfo> vi;
    std::vector<const Ins *> def; // 値を作る命令（consts・phi・命令）
    // ブロック・位置ごと
    std::vector<std::vector<uint8_t>> insLive;  // 出す（または出したことにする）か
    std::vector<std::vector<uint8_t>> retarget; // StoreCell を出さない（演算がじかに書く）
    std::vector<std::vector<int8_t>> fuse;      // 0 = 普通, 1 = 次と 1 つにした頭（出さない）, 2 = 1 つにした尾
    std::vector<std::vector<HK>> fuseKind;
    std::vector<std::vector<int>> fusePartner;  // 尾から頭の位置

    Builder(const Function &f, std::string &w) : fn(f), why(w) {}

    bool fail(const std::string &s) { why = s; return false; }

    Ptr ptrOf(uint32_t v, uint64_t &addr) const
    {
        if (fn.constAddr(v, addr)) return Ptr::Cell;
        const Ins *d = def[v];
        if (d && (d->op == Op::MemAddr || d->op == Op::GMemAddr || d->op == Op::BoolToPtr)) return Ptr::Ram;
        return Ptr::Unknown;
    }
    bool aliases(uint32_t p, uint64_t c) const
    {
        uint64_t a = 0;
        switch (ptrOf(p, a)) {
        case Ptr::Cell: return a == c;
        case Ptr::Ram: return false;
        case Ptr::Unknown: return true;
        }
        return true;
    }

    /// (b, i) の命令が升 c へ書きうるか（出さない StoreCell も元の位置で書くものとして数える＝控えめ）。
    bool mayWrite(int b, int i, uint64_t c) const
    {
        const Ins &in = fn.blocks[b].ins[i];
        if (in.res != kNoValue && vi[in.res].direct && vi[in.res].dstCell == c) return true;
        switch (in.op) {
        case Op::StoreCell: return in.imm[0] == c;
        case Op::Store: case Op::UStackPop: case Op::UStackExch: return aliases(in.args[0], c);
        default: return isCall(in.op);
        }
    }

    /// (b, i) の命令が升 c を読みうるか（畳んだ LoadCell はそれを使う命令の位置で読む）。
    bool mayRead(int b, int i, uint64_t c) const
    {
        const Ins &in = fn.blocks[b].ins[i];
        for (uint32_t a : in.args)
            if (vi[a].folded && vi[a].cell == c) return true;
        switch (in.op) {
        case Op::LoadCell: return !vi[in.res].folded && in.imm[0] == c;
        case Op::Load: case Op::UStackPush: case Op::UStackExch: return aliases(in.args[0], c);
        case Op::PtrMin: case Op::PtrMax: return aliases(in.args[0], c) || aliases(in.args[1], c);
        default: return isCall(in.op);
        }
    }

    bool executes(int b, int i) const
    {
        const Ins &in = fn.blocks[b].ins[i];
        if (!insLive[b][i]) return false;
        if (in.op == Op::LoadCell && vi[in.res].folded) return false;
        return true;
    }

    bool analyse();
    void liveness();
    void foldLoads();
    void directDest();
    void fusePairs();
    bool assignSlots(ThreadedProgram &p);
    bool emit(ThreadedProgram &p);
};

bool Builder::analyse()
{
    const size_t nv = fn.values.size();
    vi.assign(nv, VInfo{});
    def.assign(nv, nullptr);
    for (const Ins &c : fn.consts)
        if (c.res != kNoValue && c.res < nv) { def[c.res] = &c; vi[c.res].block = -1; }
    const int nb = (int)fn.blocks.size();
    insLive.resize(nb); retarget.resize(nb); fuse.resize(nb); fuseKind.resize(nb); fusePartner.resize(nb);
    for (int b = 0; b < nb; ++b) {
        const Block &bl = fn.blocks[b];
        for (const Ins &in : bl.phis) {
            if (in.res >= nv) return fail("phi without value");
            def[in.res] = &in;
            vi[in.res].block = b; vi[in.res].pos = -1; vi[in.res].phi = true;
        }
        for (size_t i = 0; i < bl.ins.size(); ++i) {
            const Ins &in = bl.ins[i];
            if (in.op == Op::Phi || in.op == Op::PtrConst || in.op == Op::BoolConst || in.op == Op::I32Const ||
                in.op >= Op::Count)
                return fail(std::string("unexpected op in block: ") + opName(in.op));
            if (in.res != kNoValue) {
                if (in.res >= nv) return fail("value out of range");
                def[in.res] = &in;
                vi[in.res].block = b; vi[in.res].pos = (int)i;
            }
        }
        const size_t n = bl.ins.size();
        insLive[b].assign(n, 0); retarget[b].assign(n, 0); fuse[b].assign(n, 0);
        fuseKind[b].assign(n, HK::Count); fusePartner[b].assign(n, -1);
        if (bl.term == Term::None) return fail("block without terminator");
    }
    return true; // 定義の無い値（持ち上げで捨てた番号）は誰も使わない（verifier）
}

void Builder::liveness()
{
    std::vector<uint32_t> work;
    auto mark = [&](uint32_t v) {
        if (!vi[v].live) { vi[v].live = true; work.push_back(v); }
    };
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        for (size_t i = 0; i < bl.ins.size(); ++i) {
            const Ins &in = bl.ins[i];
            if (!removable(in.op)) {
                insLive[b][i] = 1;
                if (in.res != kNoValue) mark(in.res);
                for (uint32_t a : in.args) mark(a);
            }
        }
        if (bl.term == Term::CondBr) mark(bl.cond);
    }
    while (!work.empty()) {
        const uint32_t v = work.back();
        work.pop_back();
        if (def[v]) for (uint32_t a : def[v]->args) mark(a);
    }
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        for (size_t i = 0; i < bl.ins.size(); ++i) {
            const Ins &in = bl.ins[i];
            if (in.res != kNoValue && vi[in.res].live) insLive[b][i] = 1;
            if (!insLive[b][i]) ++st.dead;
        }
        for (const Ins &in : bl.phis) if (!vi[in.res].live) ++st.dead;
    }
    // 使う所（生きている命令・phi・条件だけ）
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        for (size_t i = 0; i < bl.ins.size(); ++i)
            if (insLive[b][i])
                for (uint32_t a : bl.ins[i].args) vi[a].uses.push_back(Use{(int)b, (int)i, false});
        for (const Ins &in : bl.phis) {
            if (!vi[in.res].live) continue;
            for (size_t k = 0; k < in.args.size(); ++k) {
                const int pred = (int)bl.preds[k];
                vi[in.args[k]].uses.push_back(Use{pred, (int)fn.blocks[pred].ins.size(), true});
            }
        }
        if (bl.term == Term::CondBr) vi[bl.cond].uses.push_back(Use{(int)b, (int)bl.ins.size(), false});
    }
}

void Builder::foldLoads()
{
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        for (size_t i = 0; i < bl.ins.size(); ++i) {
            const Ins &in = bl.ins[i];
            if (in.op != Op::LoadCell || !insLive[b][i]) continue;
            VInfo &v = vi[in.res];
            int maxUse = -1;
            bool ok = !v.uses.empty();
            for (const Use &u : v.uses)
                if (u.phi || u.block != (int)b || u.pos <= (int)i || u.pos >= (int)bl.ins.size()) { ok = false; break; }
                else maxUse = std::max(maxUse, u.pos);
            if (!ok) continue;
            const uint64_t c = in.imm[0];
            for (int j = (int)i + 1; j < maxUse && ok; ++j)
                if (executes((int)b, j) && mayWrite((int)b, j, c)) ok = false;
            if (!ok) continue;
            v.folded = true;
            v.cell = c;
            ++st.foldedLoads;
        }
    }
}

void Builder::directDest()
{
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        for (size_t s = 0; s < bl.ins.size(); ++s) {
            const Ins &S = bl.ins[s];
            if (S.op != Op::StoreCell || !insLive[b][s]) continue;
            const uint32_t v = S.args[0];
            VInfo &V = vi[v];
            if (V.phi || V.block != (int)b || V.pos < 0 || V.pos >= (int)s || V.folded || V.uses.size() != 1) continue;
            const Ins &I = bl.ins[V.pos];
            if (!hasF64Dest(I.op)) continue;
            const uint64_t c = S.imm[0];
            bool ok = true;
            for (int j = V.pos + 1; j < (int)s && ok; ++j)
                if (executes((int)b, j) && (mayRead((int)b, j, c) || mayWrite((int)b, j, c))) ok = false;
            if (!ok) continue;
            V.direct = true;
            V.dstCell = c;
            retarget[b][s] = 1;
            ++st.directDest;
        }
    }
}

void Builder::fusePairs()
{
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        std::vector<int> order;
        for (size_t i = 0; i < bl.ins.size(); ++i)
            if (executes((int)b, (int)i) && !retarget[b][i]) order.push_back((int)i);
        for (size_t k = 0; k + 1 < order.size(); ++k) {
            const int h = order[k], t = order[k + 1];
            if (fuse[b][h]) continue;
            const Ins &H = bl.ins[h], &T = bl.ins[t];
            if (H.res == kNoValue || vi[H.res].uses.size() != 1 || vi[H.res].direct) continue;
            HK kind = HK::Count;
            if (T.op == Op::Filter && T.args[0] == H.res) {
                switch (H.op) {
                case Op::FAdd: kind = HK::FAddF; break;
                case Op::FSub: kind = HK::FSubF; break;
                case Op::FMul: kind = HK::FMulF; break;
                case Op::FDiv: kind = HK::FDivF; break;
                default: break;
                }
            } else if (H.op == Op::MemAddr && T.op == Op::Load && T.args[0] == H.res) {
                kind = HK::MemLoad;
            } else if (H.op == Op::MemAddr && T.op == Op::Store && T.args[0] == H.res && T.args[1] != H.res) {
                kind = HK::MemStore;
            }
            if (kind == HK::Count) continue;
            fuse[b][h] = 1;
            fuse[b][t] = 2;
            fuseKind[b][t] = kind;
            fusePartner[b][t] = h;
            vi[H.res].fusedAway = true;
            ++st.fused;
            ++k; // 尾は次の頭にしない
        }
    }
}

bool Builder::assignSlots(ThreadedProgram &p)
{
    const size_t nv = fn.values.size();
    auto needsSlot = [&](uint32_t v) {
        const VInfo &x = vi[v];
        return x.live && x.block >= 0 && !x.folded && !x.direct && !x.fusedAway;
    };
    // ブロックの外で使う値・phi は専用の升
    for (uint32_t v = 0; v < nv; ++v) {
        VInfo &x = vi[v];
        if (!needsSlot(v)) continue;
        if (x.phi) { x.global = true; continue; }
        for (const Use &u : x.uses) {
            if (u.block != x.block) { x.global = true; break; }
            x.lastUse = std::max(x.lastUse, u.pos);
        }
    }
    int nGlobal = 0;
    for (uint32_t v = 0; v < nv; ++v)
        if (needsSlot(v) && vi[v].phi) vi[v].slot = nGlobal++;
    // phi と引数を同じ升に（引数がその phi の最後の使用より後に、引数の来るブロックで作られるとき）
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        for (const Ins &P : bl.phis) {
            VInfo &pv = vi[P.res];
            if (!pv.live || pv.uses.empty()) continue;
            for (size_t k = 0; k < P.args.size() && !pv.coalesced; ++k) {
                const uint32_t a = P.args[k];
                const int X = (int)bl.preds[k];
                VInfo &av = vi[a];
                if (!needsSlot(a) || av.phi || av.block != X || av.coalesced) continue;
                int phiUses = 0;
                bool ok = true;
                for (const Use &u : av.uses) {
                    if (u.phi) ++phiUses;
                    else if (u.block != X) ok = false;
                }
                if (!ok || phiUses != 1) continue;
                for (const Use &u : pv.uses)
                    if (u.phi || u.block != X || u.pos > av.pos) { ok = false; break; }
                if (!ok) continue;
                av.slot = pv.slot;
                av.global = true;
                av.coalesced = pv.coalesced = true;
                ++st.coalesced;
            }
        }
    }
    for (uint32_t v = 0; v < nv; ++v)
        if (needsSlot(v) && vi[v].global && vi[v].slot == kNoSlot && !vi[v].uses.empty()) vi[v].slot = nGlobal++;
    // ブロックの中だけの値: 使い終わった升を使い回す（同じ位置で放してから取る。ハンドラは読んでから書く）
    int nLocal = 0;
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        const int n = (int)bl.ins.size();
        std::vector<std::vector<uint32_t>> dies(n + 1);
        for (int i = 0; i < n; ++i) {
            const uint32_t r = bl.ins[i].res;
            if (r != kNoValue && needsSlot(r) && !vi[r].global && !vi[r].uses.empty()) dies[vi[r].lastUse].push_back(r);
        }
        std::vector<int> freeList;
        int used = 0;
        for (int i = 0; i < n; ++i) {
            for (uint32_t r : dies[i])
                if (vi[r].slot != kNoSlot) freeList.push_back(vi[r].slot);
            const uint32_t r = bl.ins[i].res;
            if (r == kNoValue || !needsSlot(r) || vi[r].global || vi[r].uses.empty()) continue;
            if (!freeList.empty()) { vi[r].slot = freeList.back(); freeList.pop_back(); }
            else vi[r].slot = nGlobal + used++;
        }
        nLocal = std::max(nLocal, used);
    }
    p.nGlobal = (size_t)nGlobal;
    p.nLocal = (size_t)nLocal;
    p.poolBase = p.nGlobal + p.nLocal;
    p.nPool = fn.consts.size();
    // 枠: [専用][使い回し][定数][写しの一時][捨て場]
    p.frame.assign(p.poolBase + p.nPool + 2, Slot{});
    for (size_t k = 0; k < fn.consts.size(); ++k) {
        const Ins &c = fn.consts[k];
        Slot &s = p.frame[p.poolBase + k];
        if (c.op == Op::I32Const) s.i = (int64_t)(int32_t)(uint32_t)c.imm[0];
        else s.u = c.imm[0];
    }
    st.slots = p.frame.size();
    return true;
}

struct Emitter {
    ThreadedProgram &p;
    std::vector<Word> &code;
    std::vector<std::pair<size_t, int>> fixups; // (語の位置, ラベル)
    std::vector<size_t> labelAt;
    size_t handlers = 0;
    explicit Emitter(ThreadedProgram &prog) : p(prog), code(prog.code) {}
    void h(HK k) { Word w; w.h = handler(k); code.push_back(w); ++handlers; }
    void d(double *x) { Word w; w.d = x; code.push_back(w); }
    void s(Slot *x) { Word w; w.s = x; code.push_back(w); }
    void x(uint64_t v) { Word w; w.u = v; code.push_back(w); }
    void ptr(void *v) { Word w; w.p = v; code.push_back(w); }
    void label(int l) { Word w; w.t = nullptr; fixups.push_back({code.size(), l}); code.push_back(w); }
};

bool Builder::emit(ThreadedProgram &p)
{
    const int nb = (int)fn.blocks.size();
    Emitter e(p);
    Slot *const tmp = &p.frame[p.poolBase + p.nPool];
    Slot *const junk = &p.frame[p.poolBase + p.nPool + 1];
    size_t maxVar = 1;
    for (const Block &bl : fn.blocks)
        for (const Ins &in : bl.ins)
            if (in.op == Op::CallVarparm || in.op == Op::CallVarparmX) maxVar = std::max(maxVar, in.args.size());
    p.scratch.assign(maxVar, nullptr);

    auto slotOf = [&](uint32_t v) -> Slot * {
        const VInfo &x = vi[v];
        if (x.block < 0) return &p.frame[p.poolBase + x.pos /* consts の番号は下で入れる */];
        if (x.slot == kNoSlot) return junk;
        return &p.frame[(size_t)x.slot];
    };
    // consts の番号（pos に入れておく）
    for (size_t k = 0; k < fn.consts.size(); ++k) vi[fn.consts[k].res].pos = (int)k;
    auto fop = [&](uint32_t v) -> double * {
        const VInfo &x = vi[v];
        if (x.folded) return (double *)(uintptr_t)x.cell;
        return &slotOf(v)->d;
    };
    auto fdst = [&](uint32_t v) -> double * {
        const VInfo &x = vi[v];
        if (x.direct) return (double *)(uintptr_t)x.dstCell;
        return &slotOf(v)->d;
    };
    auto sop = [&](uint32_t v) -> Slot * { return slotOf(v); };
    auto ok = true;
    std::string bad;

    auto emitIns = [&](const Ins &in, int b, int i) {
        const uint32_t *a = in.args.data();
        switch (in.op) {
        case Op::LoadCell: e.h(HK::Mov); e.ptr(fdst(in.res)); e.ptr((void *)(uintptr_t)in.imm[0]); break;
        case Op::StoreCell: e.h(HK::Mov); e.ptr((void *)(uintptr_t)in.imm[0]); e.ptr(fop(a[0])); break;
        case Op::Load: e.h(HK::Load); e.d(fdst(in.res)); e.s(sop(a[0])); break;
        case Op::Store: e.h(HK::Store); e.s(sop(a[0])); e.d(fop(a[1])); break;
        case Op::Filter: e.h(HK::Filt); e.d(fdst(in.res)); e.d(fop(a[0])); break;
#define BIN(O) case Op::O: e.h(HK::O); e.d(fdst(in.res)); e.d(fop(a[0])); e.d(fop(a[1])); break;
        BIN(FAdd) BIN(FSub) BIN(FMul) BIN(FDiv) BIN(FMin2) BIN(FMax2) BIN(IAnd) BIN(IOr) BIN(IXor) BIN(IMod)
        BIN(IShl) BIN(IShr)
#undef BIN
#define UN(O) case Op::O: e.h(HK::O); e.d(fdst(in.res)); e.d(fop(a[0])); break;
        UN(FNeg) UN(FAbs) UN(FSqr) UN(FSign) UN(InvSqrt) UN(IOr0)
#undef UN
        case Op::CallF1: e.h(HK::CallF1); e.d(fdst(in.res)); e.x(in.imm[0]); e.d(fop(a[0])); break;
        case Op::CallF2: e.h(HK::CallF2); e.d(fdst(in.res)); e.x(in.imm[0]); e.d(fop(a[0])); e.d(fop(a[1])); break;
#define CMP(O) case Op::O: e.h(HK::O); e.s(sop(in.res)); e.d(fop(a[0])); e.d(fop(a[1])); break;
        CMP(CmpEqClose) CMP(CmpNeClose) CMP(CmpEq) CMP(CmpNe) CMP(CmpLt) CMP(CmpGe)
#undef CMP
        case Op::Truthy: e.h(HK::Truthy); e.s(sop(in.res)); e.d(fop(a[0])); break;
        case Op::Falsy: e.h(HK::Falsy); e.s(sop(in.res)); e.d(fop(a[0])); break;
        case Op::BNot: e.h(HK::BNot); e.s(sop(in.res)); e.s(sop(a[0])); break;
        case Op::BoolToF: e.h(HK::BoolToF); e.d(fdst(in.res)); e.s(sop(a[0])); break;
        case Op::PtrNonNull: e.h(HK::PtrNonNull); e.s(sop(in.res)); e.s(sop(a[0])); break;
        case Op::BoolToPtr: e.h(HK::BoolToPtr); e.s(sop(in.res)); e.s(sop(a[0])); break;
        case Op::PtrMin: e.h(HK::PtrMin); e.s(sop(in.res)); e.s(sop(a[0])); e.s(sop(a[1])); break;
        case Op::PtrMax: e.h(HK::PtrMax); e.s(sop(in.res)); e.s(sop(a[0])); e.s(sop(a[1])); break;
        case Op::MemAddr: e.h(HK::MemAddr); e.s(sop(in.res)); e.d(fop(a[0])); e.x(in.imm[0]); break;
        case Op::GMemAddr: e.h(HK::GMemAddr); e.s(sop(in.res)); e.d(fop(a[0])); e.x(in.imm[0]); break;
        case Op::CallG: case Op::CallGD: {
            const size_t n = in.args.size();
            if (n < 1 || n > 3) { ok = false; bad = "callg arity"; return; }
            static const HK kg[] = {HK::CallG1, HK::CallG2, HK::CallG3};
            static const HK kd[] = {HK::CallGD1, HK::CallGD2, HK::CallGD3};
            e.h(in.op == Op::CallG ? kg[n - 1] : kd[n - 1]);
            if (in.op == Op::CallG) e.s(sop(in.res)); else e.d(fdst(in.res));
            e.x(in.imm[0]); e.x(in.imm[1]);
            for (size_t k = 0; k < n; ++k) e.s(sop(a[k]));
            break;
        }
        case Op::CallGXD:
            e.h(HK::CallGXD); e.d(fdst(in.res)); e.x(in.imm[0]); e.x(in.imm[1]); e.x(in.imm[2]);
            e.s(sop(a[0])); e.s(sop(a[1]));
            break;
        case Op::CallVarparm:
            e.h(HK::CallVP); e.d(fdst(in.res)); e.x(in.imm[0]); e.x(in.imm[1]); e.x(in.args.size());
            e.ptr(p.scratch.data());
            for (uint32_t v : in.args) e.s(sop(v));
            break;
        case Op::CallVarparmX:
            e.h(HK::CallVPX); e.d(fdst(in.res)); e.x(in.imm[0]); e.x(in.imm[1]); e.x(in.imm[2]); e.x(in.args.size());
            e.ptr(p.scratch.data());
            for (uint32_t v : in.args) e.s(sop(v));
            break;
        case Op::UStackPush: e.h(HK::UPush); e.s(sop(a[0])); e.x(in.imm[0]); e.x(in.imm[1]); e.x(in.imm[2]); break;
        case Op::UStackPop: e.h(HK::UPop); e.s(sop(a[0])); e.x(in.imm[0]); e.x(in.imm[1]); e.x(in.imm[2]); break;
        case Op::UStackPopFast:
            e.h(HK::UPopFast); e.s(sop(in.res)); e.x(in.imm[0]); e.x(in.imm[1]); e.x(in.imm[2]);
            break;
        case Op::UStackPeek:
            e.h(HK::UPeek); e.s(sop(in.res)); e.d(fop(a[0])); e.x(in.imm[0]); e.x(in.imm[1]); e.x(in.imm[2]);
            break;
        case Op::UStackPeekInt:
            e.h(HK::UPeekInt); e.s(sop(in.res)); e.x(in.imm[0]); e.x(in.imm[1]); e.x(in.imm[2]); e.x(in.imm[3]);
            break;
        case Op::UStackPeekTop: e.h(HK::UPeekTop); e.s(sop(in.res)); e.x(in.imm[0]); break;
        case Op::UStackExch: e.h(HK::UExch); e.s(sop(a[0])); e.x(in.imm[0]); break;
        case Op::LoopCount: e.h(HK::LoopCount); e.s(sop(in.res)); e.d(fop(a[0])); break;
        case Op::ILt1: e.h(HK::ILt1); e.s(sop(in.res)); e.s(sop(a[0])); break;
        case Op::IDec: e.h(HK::IDec); e.s(sop(in.res)); e.s(sop(a[0])); break;
        case Op::IGt0: e.h(HK::IGt0); e.s(sop(in.res)); e.s(sop(a[0])); break;
        default:
            ok = false;
            bad = std::string("no handler for ") + opName(in.op) + " (block " + std::to_string(b) + " ins " +
                  std::to_string(i) + ")";
            return;
        }
    };

    // phi の写し（並行の写しを順に。輪になったら一時の升を使う）
    struct Copy { Slot *dst; Slot *src; };
    auto edgeCopies = [&](int from, int to, int predIdx) {
        std::vector<Copy> cs;
        for (const Ins &P : fn.blocks[to].phis) {
            if (!vi[P.res].live || vi[P.res].uses.empty()) continue;
            Slot *dst = slotOf(P.res);
            Slot *src = slotOf(P.args[predIdx]);
            if (dst != src) cs.push_back(Copy{dst, src});
        }
        (void)from;
        return cs;
    };
    auto emitCopies = [&](std::vector<Copy> cs) {
        while (!cs.empty()) {
            bool progress = false;
            for (size_t i = 0; i < cs.size(); ++i) {
                bool blocked = false;
                for (size_t j = 0; j < cs.size(); ++j)
                    if (j != i && cs[j].src == cs[i].dst) { blocked = true; break; }
                if (blocked) continue;
                e.h(HK::Mov); e.s(cs[i].dst); e.s(cs[i].src);
                ++st.copies;
                cs.erase(cs.begin() + (long)i);
                progress = true;
                break;
            }
            if (progress) continue;
            // 輪: 先頭の行き先を一時へ逃がし、それを読む写しを一時から読ませる
            Slot *d0 = cs[0].dst;
            e.h(HK::Mov); e.s(tmp); e.s(d0);
            ++st.copies;
            for (Copy &c : cs) if (c.src == d0) c.src = tmp;
        }
    };

    e.labelAt.assign((size_t)nb, 0);
    struct Stub { int label; std::vector<Copy> copies; int target; };
    std::vector<Stub> stubs;
    int nextLabel = nb;
    for (int b = 0; b < nb && ok; ++b) {
        const Block &bl = fn.blocks[b];
        e.labelAt[(size_t)b] = e.code.size();
        for (int i = 0; i < (int)bl.ins.size() && ok; ++i) {
            if (!executes(b, i) || retarget[b][i] || fuse[b][i] == 1) continue;
            const Ins &in = bl.ins[i];
            if (fuse[b][i] == 2) {
                const Ins &H = bl.ins[fusePartner[b][i]];
                const HK k = fuseKind[b][i];
                e.h(k);
                if (k == HK::MemLoad) { e.d(fdst(in.res)); e.d(fop(H.args[0])); e.x(H.imm[0]); }
                else if (k == HK::MemStore) { e.d(fop(H.args[0])); e.d(fop(in.args[1])); e.x(H.imm[0]); }
                else { e.d(fdst(in.res)); e.d(fop(H.args[0])); e.d(fop(H.args[1])); }
                continue;
            }
            emitIns(in, b, i);
        }
        if (!ok) break;
        switch (bl.term) {
        case Term::Ret: e.h(HK::Ret); break;
        case Term::Br: {
            const int t = (int)bl.succ[0];
            emitCopies(edgeCopies(b, t, (int)bl.succPredIdx[0]));
            if (t != b + 1) { e.h(HK::Jmp); e.label(t); }
            break;
        }
        case Term::CondBr: {
            int target[2];
            for (int k = 0; k < 2; ++k) {
                const int t = (int)bl.succ[k];
                std::vector<Copy> cs = edgeCopies(b, t, (int)bl.succPredIdx[k]);
                if (cs.empty()) target[k] = t;
                else { stubs.push_back(Stub{nextLabel, std::move(cs), t}); target[k] = nextLabel++; }
            }
            Slot *c = sop(bl.cond);
            if (target[0] == target[1]) {
                if (target[0] != b + 1) { e.h(HK::Jmp); e.label(target[0]); }
            } else if (target[1] == b + 1) {
                e.h(HK::BrT); e.s(c); e.label(target[0]);
            } else if (target[0] == b + 1) {
                e.h(HK::BrF); e.s(c); e.label(target[1]);
            } else {
                e.h(HK::Br); e.s(c); e.label(target[0]); e.label(target[1]);
            }
            break;
        }
        case Term::None: ok = false; bad = "block without terminator"; break;
        }
    }
    if (!ok) return fail(bad);
    e.labelAt.resize((size_t)nextLabel, 0);
    for (Stub &sb : stubs) {
        e.labelAt[(size_t)sb.label] = e.code.size();
        emitCopies(std::move(sb.copies));
        e.h(HK::Jmp); e.label(sb.target);
    }
    for (const auto &[at, l] : e.fixups) p.code[at].t = p.code.data() + e.labelAt[(size_t)l];
    p.entry = p.code.data();
    st.handlers = e.handlers;
    st.words = p.code.size();
    return true;
}

} // namespace

ThreadedProgram *buildThreaded(const Function &fn, std::string &why, ThreadedStats *stats)
{
    if (fn.blocks.empty()) { why = "no blocks"; return nullptr; }
    Builder b(fn, why);
    if (!b.analyse()) return nullptr;
    b.liveness();
    b.foldLoads();
    b.directDest();
    b.fusePairs();
    auto *p = new ThreadedProgram;
    if (!b.assignSlots(*p) || !b.emit(*p)) { delete p; return nullptr; }
    for (const Block &bl : fn.blocks) b.st.irInstructions += bl.phis.size() + bl.ins.size() + 1;
    p->stats = b.st;
    if (stats) *stats = b.st;
    return p;
}

void runThreaded(const ThreadedProgram *p, unsigned int nframes, ThreadedFrameCallback pre, ThreadedFrameCallback post,
                 void *ctx)
{
    threaded::run(p->entry, nframes, pre, post, ctx);
}

void freeThreaded(ThreadedProgram *p) { delete p; }

const ThreadedStats &threadedStats(const ThreadedProgram *p) { return p->stats; }

std::string disassembleThreaded(const ThreadedProgram *p, CellNamer namer, void *user)
{
    std::string out;
    char buf[160];
    const Word *base = p->code.data();
    const Slot *f0 = p->frame.data(), *f1 = f0 + p->frame.size();
    auto operand = [&](const Word &w) {
        const uintptr_t a = (uintptr_t)w.p;
        if (a >= (uintptr_t)f0 && a < (uintptr_t)f1) {
            const size_t k = (size_t)((const Slot *)w.p - f0);
            if (k >= p->poolBase && k < p->poolBase + p->nPool) std::snprintf(buf, sizeof buf, "#%016" PRIx64, f0[k].u);
            else if (k < p->nGlobal) std::snprintf(buf, sizeof buf, "g%zu", k);
            else if (k < p->poolBase) std::snprintf(buf, sizeof buf, "l%zu", k - p->nGlobal);
            else std::snprintf(buf, sizeof buf, "%s", k == p->poolBase + p->nPool ? "tmp" : "junk");
            return std::string(buf);
        }
        if (a >= (uintptr_t)base && a < (uintptr_t)(base + p->code.size())) {
            std::snprintf(buf, sizeof buf, "@%zu", (size_t)((const Word *)w.p - base));
            return std::string(buf);
        }
        if (namer) {
            std::string n = namer((uint64_t)a, user);
            if (!n.empty()) return n;
        }
        std::snprintf(buf, sizeof buf, "0x%" PRIx64, (uint64_t)a);
        return std::string(buf);
    };
    for (size_t at = 0; at < p->code.size();) {
        const HK k = handlerKind(p->code[at].h);
        if (k == HK::Count) { out += "  ??\n"; break; }
        int n = handlerOperands(k);
        if (k == HK::CallVP) n = 5 + (int)p->code[at + 4].u;
        if (k == HK::CallVPX) n = 6 + (int)p->code[at + 5].u;
        std::snprintf(buf, sizeof buf, "  @%-5zu %-10s", at, handlerName(k));
        out += buf;
        for (int j = 1; j <= n; ++j) out += (j == 1 ? " " : ", ") + operand(p->code[at + (size_t)j]);
        out += "\n";
        at += 1 + (size_t)n;
    }
    std::snprintf(buf, sizeof buf, "  ; %zu handlers, %zu words, frame %zu (global %zu, local %zu, pool %zu)\n",
                  p->stats.handlers, p->stats.words, p->frame.size(), p->nGlobal, p->nLocal, p->nPool);
    out += buf;
    return out;
}

} // namespace etvm
