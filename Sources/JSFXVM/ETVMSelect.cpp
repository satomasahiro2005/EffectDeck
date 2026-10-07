// ETVMSelect.cpp — 中間表現から threaded code（ETVMHandlers.cpp のハンドラの列）を作る。段 S2・S3。
// docs/jsfx-regvm-design.md §9.1–9.5（オペランドは全部が絶対番地）、§16・§17。
//
// 並べる前にすること（どれも「portable と同じ順・同じ番地で読み書きする」を崩さない範囲だけ。[] は ETVM_PASS_*）:
//   1. 使われない純な値は出さない（根 = 書く・呼ぶ・確保する命令と分かれ道の条件から辿れないもの）
//   2. [ldfold] LoadCell をオペランドへ畳む: 同じブロックの中の使う所までに、その升へ書きうる命令が無ければ、
//      使う命令がその升を直に読む（設計 §9.2: 升も枠も同じ double *）
//   3. [direct] 行き先をじかに: StoreCell(c, v) の v を作る同じブロックの演算が c へ書き、StoreCell は出さない。
//      v を作ってから StoreCell までに c を読む・書きうる命令が無いこと。v のほかの使う所（S3: fwd・cse で増える）は
//      同じブロックで、c へ書きうる命令を挟まなければ c を読む
//   4. [loop・cmpbr] ブロックの終わりの「数を減らして比べて跳ぶ」「loop の数を決めて 1 未満なら跳ぶ」
//      「while の次」「比べて跳ぶ」を 1 つに（最後に回る命令どうしだけ。値を読む・書く時点は変わらない）
//   5. 並んだ命令を 1 つに（間に回る命令が無いときだけ）: [fuse] 四則 + フィルタ、megabuf の番地 + 読む／書く、
//      [membi] 頭 + 添字 → megabuf、[fuse2] 四則 2 つ（+ フィルタ）
//   6. [opimm・opto] 四則のオペランドが定数（FConst）なら命令の中に、行き先が左のオペランドと同じ升なら 1 つ省く
//   7. 升: ブロックの外で使う値・phi は専用の升、ブロックの中だけの値は使い終わった升を使い回す。
//      [loop] phi と引数は、生きている範囲が重ならなければ同じ升に（loop・while の数の写しが消える）。
//      切ったときは段 S2 の決め方（引数が phi の最後の使用より後に、引数の来るブロックで作られるとき）
// 「書きうる・読みうる」はポインタの出所で決める: 定数の番地はその升だけ、megabuf・gmem の番地は升に重ならない、
// それ以外（API の返り値・phi・min/max の参照・ユーザーの積み場）はどの升でもありうる。API の呼び出しは全部の升を
// 読み書きしうる。
#include "ETVMExec.h"
#include "ETVMThreaded.h"

#include "ETVM.h"

#include <algorithm>
#include <cinttypes>
#include <cmath>
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
    bool direct = false;  // 結果を dstCell へじかに書く（使う所も dstCell を読む）
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

bool isArith(Op op) { return op == Op::FAdd || op == Op::FSub || op == Op::FMul || op == Op::FDiv; }
int arithIndex(Op op) { return op == Op::FAdd ? 0 : op == Op::FSub ? 1 : op == Op::FMul ? 2 : 3; }

/// 並んだ命令を 1 つにした組（尾の位置に置く）
enum class GK : uint8_t { None, ArithF, MemLoad, MemStore, MemAddrBI, MemLoadBI, MemStoreBI, Fuse2, Fuse2F };
/// ブロックの終わりを 1 つにしたもの
enum class TK : uint8_t { None, LoopInit, Dec, While, Cmp };

struct TermFuse {
    TK kind = TK::None;
    int p0 = -1, p1 = -1; // 取り込んだ命令の位置
    int x = -1;           // While: 取り込んだブロック（条件で跳ぶだけ）
    int cmp = -1;         // While: X の条件の比べも取り込んだ（その位置。D の中で IDec の直前）
};

struct Builder {
    const Function &fn;
    std::string &why;
    const uint32_t passes;
    ThreadedStats st;
    std::vector<VInfo> vi;
    std::vector<const Ins *> def; // 値を作る命令（consts・phi・命令）
    // ブロック・位置ごと
    std::vector<std::vector<uint8_t>> insLive;  // 出す（または出したことにする）か
    std::vector<std::vector<uint8_t>> retarget; // StoreCell を出さない（演算がじかに書く）
    std::vector<std::vector<int8_t>> fuse;      // 0 = 普通, 1 = 組の頭（出さない）, 2 = 組の尾, 3 = 終わりに取り込んだ
    std::vector<std::vector<GK>> groupKind;     // 尾の位置
    std::vector<std::vector<std::vector<int>>> groupMembers; // 尾の位置: 頭から尾まで
    std::vector<TermFuse> term;
    std::vector<uint8_t> absorbed;              // ブロックごと: While に取り込んだ（出さない）

    Builder(const Function &f, std::string &w, uint32_t p) : fn(f), why(w), passes(p) {}

    bool on(uint32_t bit) const { return (passes & bit) != 0; }
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

    /// (b, i) の命令が升 c を読みうるか（畳んだ LoadCell はそれを使う命令の位置で読む。じかに書いた値を使う所は
    /// その升を読む）。
    bool mayRead(int b, int i, uint64_t c) const
    {
        const Ins &in = fn.blocks[b].ins[i];
        for (uint32_t a : in.args) {
            if (vi[a].folded && vi[a].cell == c) return true;
            if (vi[a].direct && vi[a].dstCell == c && !(in.op == Op::StoreCell && retarget[b][i])) return true;
        }
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

    /// 出す命令（回る命令のうち、じかに書いて消えた StoreCell を除く）の位置
    std::vector<int> emitOrder(int b) const
    {
        std::vector<int> order;
        for (size_t i = 0; i < fn.blocks[b].ins.size(); ++i)
            if (executes(b, (int)i) && !retarget[b][i]) order.push_back((int)i);
        return order;
    }

    bool analyse();
    void liveness();
    void foldLoads();
    void directDest();
    void fuseTerms();
    void fuseGroups();
    void coalesceS2();
    void coalesceLive();
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
    insLive.resize(nb); retarget.resize(nb); fuse.resize(nb); groupKind.resize(nb); groupMembers.resize(nb);
    term.assign(nb, TermFuse{});
    absorbed.assign(nb, 0);
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
                in.op == Op::FConst || in.op >= Op::Count)
                return fail(std::string("unexpected op in block: ") + opName(in.op));
            if (in.res != kNoValue) {
                if (in.res >= nv) return fail("value out of range");
                def[in.res] = &in;
                vi[in.res].block = b; vi[in.res].pos = (int)i;
            }
        }
        const size_t n = bl.ins.size();
        insLive[b].assign(n, 0); retarget[b].assign(n, 0); fuse[b].assign(n, 0);
        groupKind[b].assign(n, GK::None); groupMembers[b].assign(n, {});
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
            if (V.phi || V.block != (int)b || V.pos < 0 || V.pos >= (int)s || V.folded || V.direct) continue;
            const Ins &I = bl.ins[V.pos];
            if (!hasF64Dest(I.op)) continue;
            const uint64_t c = S.imm[0];
            // ほかの使う所: 段 S2 は無いことが条件。S3 は同じブロックの S より後（または前の）普通の命令なら、
            // その所まで c を書きうる命令が無ければ c を読む（multi）。
            int maxOther = -1;
            bool ok = true, multi = false;
            for (const Use &u : V.uses) {
                if (!u.phi && u.block == (int)b && u.pos == (int)s) continue;
                multi = true;
                if (u.phi || u.block != (int)b || u.pos >= (int)bl.ins.size() || !on(ETVM_PASS_FWD | ETVM_PASS_CSE)) {
                    ok = false;
                    break;
                }
                maxOther = std::max(maxOther, u.pos);
            }
            // V.uses が S を 1 回だけ含む（同じ値を 2 度同じ升へ、などは段 S2 と同じく断る）
            int selfUses = 0;
            for (const Use &u : V.uses) selfUses += !u.phi && u.block == (int)b && u.pos == (int)s;
            if (!ok || selfUses != 1) continue;
            // v を作ってから S まで: c を読む（古い c が要る。v を使う所は v がまだ direct でないので数えない）・
            // 書く命令が無い。S から先の使う所まで: c を書く命令が無い（使う所は c = v を読む）
            for (int j = V.pos + 1; j < (int)s && ok; ++j)
                if (executes((int)b, j) && (mayRead((int)b, j, c) || mayWrite((int)b, j, c))) ok = false;
            for (int j = (int)s + 1; j < maxOther && ok; ++j)
                if (executes((int)b, j) && mayWrite((int)b, j, c)) ok = false;
            if (!ok) continue;
            V.direct = true;
            V.dstCell = c;
            retarget[b][s] = 1;
            ++st.directDest;
            if (multi) ++st.multiDirect;
        }
    }
}

void Builder::fuseTerms()
{
    const int nb = (int)fn.blocks.size();
    for (int b = 0; b < nb; ++b) {
        const Block &bl = fn.blocks[b];
        if (bl.term != Term::CondBr || absorbed[b]) continue;
        const uint32_t cond = bl.cond;
        if (!def[cond] || vi[cond].block != b || vi[cond].phi || vi[cond].uses.size() != 1) continue;
        const std::vector<int> order = emitOrder(b);
        const int n = (int)order.size();
        if (n < 1 || order[n - 1] != vi[cond].pos) continue;
        const Ins &I1 = bl.ins[order[n - 1]];
        TermFuse tf;
        if (on(ETVM_PASS_LOOP) && n >= 2) {
            const Ins &I0 = bl.ins[order[n - 2]];
            if (I1.op == Op::IGt0 && I0.op == Op::IDec && I1.args[0] == I0.res) {
                tf = TermFuse{TK::Dec, order[n - 2], order[n - 1], -1};
                // while: 真の行き先 X が「条件で H か E へ跳ぶだけ」のブロックで、偽の行き先が同じ E なら X ごと取り込む
                const int X = (int)bl.succ[0], E = (int)bl.succ[1];
                const Block &xb = fn.blocks[X];
                bool w = X != b && X != E && xb.term == Term::CondBr && xb.preds.size() == 1 && (int)xb.succ[1] == E &&
                         (int)xb.succ[0] != X && !absorbed[X];
                if (w)
                    for (size_t i = 0; i < xb.ins.size() && w; ++i) w = !executes(X, (int)i);
                if (w)
                    for (const Ins &P : xb.phis) w = w && !vi[P.res].live;
                if (w) {
                    // E の phi が D からも X からも同じ値を受け取る
                    for (const Ins &P : fn.blocks[E].phis)
                        if (vi[P.res].live && P.args[bl.succPredIdx[1]] != P.args[xb.succPredIdx[1]]) w = false;
                    // X の条件は X の外で作られた値（X には回る命令が無い）
                    if (vi[xb.cond].block == X) w = false;
                }
                if (w) {
                    tf.kind = TK::While;
                    tf.x = X;
                    // X の条件が D の比べ 1 つ（ほかで使わない）で、IDec の直前に回るなら、それも取り込む
                    const uint32_t xc = xb.cond;
                    if (n >= 3 && on(ETVM_PASS_CMPBR) && def[xc] && vi[xc].block == b && !vi[xc].phi &&
                        vi[xc].uses.size() == 1 && order[n - 3] == vi[xc].pos) {
                        switch (bl.ins[vi[xc].pos].op) {
                        case Op::CmpLt: case Op::CmpGe: case Op::CmpEqClose: case Op::CmpNeClose: case Op::CmpEq:
                        case Op::CmpNe: case Op::Truthy: case Op::Falsy:
                            tf.cmp = vi[xc].pos;
                            break;
                        default: break;
                        }
                    }
                }
            } else if (I1.op == Op::ILt1 && I0.op == Op::LoopCount && I1.args[0] == I0.res) {
                tf = TermFuse{TK::LoopInit, order[n - 2], order[n - 1], -1};
            }
        }
        if (tf.kind == TK::None && on(ETVM_PASS_CMPBR)) {
            switch (I1.op) {
            case Op::CmpLt: case Op::CmpGe: case Op::CmpEqClose: case Op::CmpNeClose: case Op::CmpEq: case Op::CmpNe:
            case Op::Truthy: case Op::Falsy:
                tf = TermFuse{TK::Cmp, order[n - 1], -1, -1};
                break;
            default: break;
            }
        }
        if (tf.kind == TK::None) continue;
        term[b] = tf;
        vi[cond].fusedAway = true;
        fuse[b][order[n - 1]] = 3;
        if (tf.p0 >= 0 && tf.p0 != order[n - 1]) fuse[b][tf.p0] = 3;
        if (tf.kind == TK::While) absorbed[tf.x] = 1;
        if (tf.cmp >= 0) {
            fuse[b][tf.cmp] = 3;
            vi[fn.blocks[tf.x].cond].fusedAway = true;
            ++st.cmpBr;
        }
        switch (tf.kind) {
        case TK::LoopInit: case TK::Dec: ++st.loopFused; break;
        case TK::While: ++st.whileFused; break;
        case TK::Cmp: ++st.cmpBr; break;
        case TK::None: break;
        }
    }
}

void Builder::fuseGroups()
{
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        std::vector<int> order;
        for (int i : emitOrder((int)b))
            if (fuse[b][i] == 0) order.push_back(i);
        // 1 つの値が「次の命令だけで 1 回だけ使われる」
        auto feeds = [&](int h, int t) {
            const Ins &H = bl.ins[h];
            if (H.res == kNoValue || vi[H.res].uses.size() != 1 || vi[H.res].direct) return false;
            const Use &u = vi[H.res].uses[0];
            return !u.phi && u.block == (int)b && u.pos == t;
        };
        auto group = [&](GK kind, std::vector<int> members) {
            const int t = members.back();
            for (size_t k = 0; k + 1 < members.size(); ++k) {
                fuse[b][members[k]] = 1;
                vi[bl.ins[members[k]].res].fusedAway = true;
            }
            fuse[b][t] = 2;
            groupKind[b][t] = kind;
            groupMembers[b][t] = std::move(members);
        };
        for (size_t k = 0; k < order.size(); ++k) {
            const int h = order[k];
            const int t1 = k + 1 < order.size() ? order[k + 1] : -1;
            const int t2 = k + 2 < order.size() ? order[k + 2] : -1;
            const Ins &H = bl.ins[h];
            const Ins *T1 = t1 >= 0 ? &bl.ins[t1] : nullptr;
            const Ins *T2 = t2 >= 0 ? &bl.ins[t2] : nullptr;
            // [membi] 頭 + 添字 → megabuf（→ 読む／書く）
            if (on(ETVM_PASS_MEMBI) && H.op == Op::FAdd && T1 && T1->op == Op::MemAddr && feeds(h, t1)) {
                if (on(ETVM_PASS_FUSE) && T2 && feeds(t1, t2) && T2->op == Op::Load) {
                    group(GK::MemLoadBI, {h, t1, t2}); ++st.memBI; ++st.fused; k += 2; continue;
                }
                if (on(ETVM_PASS_FUSE) && T2 && feeds(t1, t2) && T2->op == Op::Store && T2->args[0] == T1->res) {
                    group(GK::MemStoreBI, {h, t1, t2}); ++st.memBI; ++st.fused; k += 2; continue;
                }
                group(GK::MemAddrBI, {h, t1}); ++st.memBI; k += 1; continue;
            }
            // [fuse] megabuf の番地 + 読む／書く
            if (on(ETVM_PASS_FUSE) && H.op == Op::MemAddr && T1 && feeds(h, t1)) {
                if (T1->op == Op::Load) { group(GK::MemLoad, {h, t1}); ++st.fused; k += 1; continue; }
                if (T1->op == Op::Store && T1->args[0] == H.res) { group(GK::MemStore, {h, t1}); ++st.fused; k += 1; continue; }
            }
            // [fuse2] 四則 2 つ（+ フィルタ）
            if (on(ETVM_PASS_FUSE2) && isArith(H.op) && T1 && isArith(T1->op) && feeds(h, t1)) {
                if (on(ETVM_PASS_FUSE) && T2 && T2->op == Op::Filter && feeds(t1, t2)) {
                    group(GK::Fuse2F, {h, t1, t2}); ++st.fuse2; ++st.fused; k += 2; continue;
                }
                group(GK::Fuse2, {h, t1}); ++st.fuse2; k += 1; continue;
            }
            // [fuse] 四則 + フィルタ
            if (on(ETVM_PASS_FUSE) && isArith(H.op) && T1 && T1->op == Op::Filter && feeds(h, t1)) {
                group(GK::ArithF, {h, t1}); ++st.fused; k += 1; continue;
            }
        }
    }
}

/// 段 S2 の決め方: 引数がその phi の最後の使用より後に、引数の来るブロックで作られるとき。
void Builder::coalesceS2()
{
    auto needsSlot = [&](uint32_t v) {
        const VInfo &x = vi[v];
        return x.live && x.block >= 0 && !x.folded && !x.direct && !x.fusedAway;
    };
    for (size_t b = 0; b < fn.blocks.size(); ++b) {
        const Block &bl = fn.blocks[b];
        for (const Ins &P : bl.phis) {
            VInfo &pv = vi[P.res];
            if (!pv.live || pv.uses.empty() || pv.slot == kNoSlot) continue;
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
}

/// [loop] phi とその引数を、生きている範囲が重ならなければ同じ升に（SSA の値どうしの干渉:
/// 片方がもう片方の定義の所で生きているか。phi の引数は来るブロックの終わりで使うとみなす）。
void Builder::coalesceLive()
{
    const int nb = (int)fn.blocks.size();
    auto needsSlot = [&](uint32_t v) {
        const VInfo &x = vi[v];
        return x.live && x.block >= 0 && !x.folded && !x.direct && !x.fusedAway && !x.uses.empty();
    };
    // 候補: 生きている phi と、その升の要る引数
    std::vector<uint32_t> cand;
    std::vector<int> candIdx(fn.values.size(), -1);
    auto add = [&](uint32_t v) {
        if (candIdx[v] < 0 && needsSlot(v)) { candIdx[v] = (int)cand.size(); cand.push_back(v); }
    };
    for (const Block &bl : fn.blocks)
        for (const Ins &P : bl.phis) {
            if (!needsSlot(P.res)) continue;
            add(P.res);
            for (uint32_t a : P.args) add(a);
        }
    if (cand.empty()) return;
    if (cand.size() * (size_t)nb > (size_t)8 << 20) { coalesceS2(); return; } // 大きすぎる: 段 S2 の決め方
    const size_t nc = cand.size();
    std::vector<std::vector<uint8_t>> liveIn(nc), liveOut(nc);
    for (size_t k = 0; k < nc; ++k) {
        const uint32_t v = cand[k];
        const int db = vi[v].block;
        std::vector<uint8_t> &in = liveIn[k], &out = liveOut[k];
        in.assign((size_t)nb, 0);
        out.assign((size_t)nb, 0);
        std::vector<int> work;
        auto atEnd = [&](int p) {
            if (out[p]) return;
            out[p] = 1;
            if (p != db && !in[p]) { in[p] = 1; work.push_back(p); }
        };
        for (const Use &u : vi[v].uses) {
            if (u.phi) atEnd(u.block);
            else if (u.block != db && !in[u.block]) { in[u.block] = 1; work.push_back(u.block); }
        }
        while (!work.empty()) {
            const int bb = work.back();
            work.pop_back();
            for (uint32_t p : fn.blocks[bb].preds) atEnd((int)p);
        }
    }
    // v が (B, pos) の命令のあとで生きているか（pos = -1 は B の phi の所）
    auto liveAfter = [&](size_t k, int B, int pos) {
        const uint32_t v = cand[k];
        const VInfo &x = vi[v];
        if (B == x.block) {
            if (!x.phi && pos < x.pos) return false;
        } else if (!liveIn[k][B]) {
            return false;
        }
        if (liveOut[k][B]) return true;
        for (const Use &u : x.uses)
            if (!u.phi && u.block == B && u.pos > pos) return true;
        return false;
    };
    auto interfere = [&](size_t i, size_t j) {
        const VInfo &a = vi[cand[i]], &b = vi[cand[j]];
        if (a.phi && b.phi && a.block == b.block) return true;
        return liveAfter(i, b.block, b.phi ? -1 : b.pos) || liveAfter(j, a.block, a.phi ? -1 : a.pos);
    };
    std::vector<int> parent(nc);
    std::vector<std::vector<int>> members(nc);
    for (size_t k = 0; k < nc; ++k) { parent[k] = (int)k; members[k] = {(int)k}; }
    auto find = [&](int k) {
        while (parent[k] != k) k = parent[k] = parent[parent[k]];
        return k;
    };
    for (const Block &bl : fn.blocks)
        for (const Ins &P : bl.phis) {
            if (candIdx[P.res] < 0) continue;
            for (uint32_t a : P.args) {
                if (candIdx[a] < 0) continue;
                const int ra = find(candIdx[P.res]), rb = find(candIdx[a]);
                if (ra == rb) continue;
                bool ok = true;
                for (int x : members[ra]) {
                    for (int y : members[rb])
                        if (interfere((size_t)x, (size_t)y)) { ok = false; break; }
                    if (!ok) break;
                }
                if (!ok) continue;
                parent[rb] = ra;
                members[ra].insert(members[ra].end(), members[rb].begin(), members[rb].end());
                members[rb].clear();
                ++st.coalesced;
            }
        }
    // 組ごとに 1 つの升（組の頭の phi の升。無ければ下で取る）
    for (size_t k = 0; k < nc; ++k) {
        if (find((int)k) != (int)k || members[k].size() < 2) continue;
        int slot = kNoSlot;
        for (int m : members[k]) if (vi[cand[m]].slot != kNoSlot) { slot = vi[cand[m]].slot; break; }
        if (slot == kNoSlot) continue; // 呼ぶ側で phi の升を先に取ってある
        for (int m : members[k]) {
            VInfo &x = vi[cand[m]];
            x.slot = slot;
            x.global = true;
            x.coalesced = true;
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
    if (on(ETVM_PASS_LOOP)) coalesceLive();
    else coalesceS2();
    for (uint32_t v = 0; v < nv; ++v)
        if (needsSlot(v) && vi[v].global && vi[v].slot == kNoSlot && !vi[v].uses.empty()) vi[v].slot = nGlobal++;
    // ブロックの中だけの値: 使い終わった升を使い回す（同じ位置で放してから取る。ハンドラは読んでから書く。
    // 1 つにした組・終わりに取り込んだ命令の間には升を取る命令が無い）
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
    void f(double x) { Word w; w.f = x; code.push_back(w); }
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

    // consts の番号（pos に入れておく）
    for (size_t k = 0; k < fn.consts.size(); ++k) vi[fn.consts[k].res].pos = (int)k;
    auto slotOf = [&](uint32_t v) -> Slot * {
        const VInfo &x = vi[v];
        if (x.block < 0) return &p.frame[p.poolBase + (size_t)x.pos];
        if (x.slot == kNoSlot) return junk;
        return &p.frame[(size_t)x.slot];
    };
    auto fop = [&](uint32_t v) -> double * {
        const VInfo &x = vi[v];
        if (x.folded) return (double *)(uintptr_t)x.cell;
        if (x.direct) return (double *)(uintptr_t)x.dstCell;
        return &slotOf(v)->d;
    };
    auto fdst = [&](uint32_t v) -> double * {
        const VInfo &x = vi[v];
        if (x.direct) return (double *)(uintptr_t)x.dstCell;
        return &slotOf(v)->d;
    };
    auto sop = [&](uint32_t v) -> Slot * { return slotOf(v); };
    auto immOf = [&](uint32_t v, double &k) {
        uint64_t bits;
        if (!fn.constF64(v, bits)) return false;
        std::memcpy(&k, &bits, 8);
        return true;
    };
    auto ok = true;
    std::string bad;

    // 四則（+ フィルタ）: 定数のオペランドは命令の中へ（opimm）、行き先 = 左なら 1 つ省く（opto）
    auto emitArith = [&](Op op, bool filt, double *dst, uint32_t a0, uint32_t a1) {
        const int ai = arithIndex(op);
        static const HK kPlain[2][4] = {{HK::FAdd, HK::FSub, HK::FMul, HK::FDiv}, {HK::FAddF, HK::FSubF, HK::FMulF, HK::FDivF}};
        static const HK kImm[2][4] = {{HK::AddI, HK::SubI, HK::MulI, HK::DivI}, {HK::AddIF, HK::SubIF, HK::MulIF, HK::DivIF}};
        static const HK kRImm[2][4] = {{HK::AddI, HK::RSubI, HK::MulI, HK::RDivI}, {HK::AddIF, HK::RSubIF, HK::MulIF, HK::RDivIF}};
        static const HK kTo[2][4] = {{HK::AddT, HK::SubT, HK::MulT, HK::DivT}, {HK::AddTF, HK::SubTF, HK::MulTF, HK::DivTF}};
        static const HK kImmTo[2][4] = {{HK::AddIT, HK::SubIT, HK::MulIT, HK::DivIT}, {HK::AddITF, HK::SubITF, HK::MulITF, HK::DivITF}};
        const int fi = filt ? 1 : 0;
        double k = 0;
        double *pa = fop(a0), *pb = fop(a1);
        if (on(ETVM_PASS_OPIMM) && immOf(a1, k)) {
            ++st.opImm;
            if (on(ETVM_PASS_OPTO) && dst == pa) { ++st.opTo; e.h(kImmTo[fi][ai]); e.d(dst); e.f(k); return; }
            e.h(kImm[fi][ai]); e.d(dst); e.d(pa); e.f(k);
            return;
        }
        // 左が定数: + * は入れ替える（NaN でない定数となら IEEE の + * は入れ替えても同じビット）。- / は R*
        if (on(ETVM_PASS_OPIMM) && immOf(a0, k) && !std::isnan(k)) {
            ++st.opImm;
            if ((ai == 0 || ai == 2) && on(ETVM_PASS_OPTO) && dst == pb) {
                ++st.opTo; e.h(kImmTo[fi][ai]); e.d(dst); e.f(k); return;
            }
            e.h(kRImm[fi][ai]); e.d(dst); e.d(pb); e.f(k);
            return;
        }
        if (on(ETVM_PASS_OPTO) && dst == pa) { ++st.opTo; e.h(kTo[fi][ai]); e.d(dst); e.d(pb); return; }
        // 行き先 = 右の + *: 左を機械の 1 つめのまま（AddTR・MulTR）。フィルタが在れば NaN は 0 になるので
        // 入れ替えて AddTF・MulTF でよい
        if (on(ETVM_PASS_OPTO) && dst == pb && (ai == 0 || ai == 2)) {
            ++st.opTo;
            e.h(filt ? kTo[1][ai] : ai == 0 ? HK::AddTR : HK::MulTR); e.d(dst); e.d(pa);
            return;
        }
        e.h(kPlain[fi][ai]); e.d(dst); e.d(pa); e.d(pb);
    };

    auto emitIns = [&](const Ins &in, int b, int i) {
        const uint32_t *a = in.args.data();
        switch (in.op) {
        case Op::LoadCell: e.h(HK::Mov); e.ptr(fdst(in.res)); e.ptr((void *)(uintptr_t)in.imm[0]); break;
        case Op::StoreCell: e.h(HK::Mov); e.ptr((void *)(uintptr_t)in.imm[0]); e.ptr(fop(a[0])); break;
        case Op::Load: e.h(HK::Load); e.d(fdst(in.res)); e.s(sop(a[0])); break;
        case Op::Store: e.h(HK::Store); e.s(sop(a[0])); e.d(fop(a[1])); break;
        case Op::Filter: e.h(HK::Filt); e.d(fdst(in.res)); e.d(fop(a[0])); break;
        case Op::FAdd: case Op::FSub: case Op::FMul: case Op::FDiv: emitArith(in.op, false, fdst(in.res), a[0], a[1]); break;
#define BIN(O) case Op::O: e.h(HK::O); e.d(fdst(in.res)); e.d(fop(a[0])); e.d(fop(a[1])); break;
        BIN(FMin2) BIN(FMax2) BIN(IAnd) BIN(IOr) BIN(IXor) BIN(IMod) BIN(IShl) BIN(IShr)
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

    auto emitGroup = [&](const Block &bl, GK kind, const std::vector<int> &m) {
        const Ins &T = bl.ins[m.back()];
        switch (kind) {
        case GK::ArithF: {
            const Ins &H = bl.ins[m[0]];
            emitArith(H.op, true, fdst(T.res), H.args[0], H.args[1]);
            break;
        }
        case GK::MemLoad: {
            const Ins &H = bl.ins[m[0]];
            e.h(HK::MemLoad); e.d(fdst(T.res)); e.d(fop(H.args[0])); e.x(H.imm[0]);
            break;
        }
        case GK::MemStore: {
            const Ins &H = bl.ins[m[0]];
            e.h(HK::MemStore); e.d(fop(H.args[0])); e.d(fop(T.args[1])); e.x(H.imm[0]);
            break;
        }
        case GK::MemAddrBI: {
            const Ins &A = bl.ins[m[0]], &M = bl.ins[m[1]];
            e.h(HK::MemAddrBI); e.s(sop(M.res)); e.d(fop(A.args[0])); e.d(fop(A.args[1])); e.x(M.imm[0]);
            break;
        }
        case GK::MemLoadBI: {
            const Ins &A = bl.ins[m[0]], &M = bl.ins[m[1]];
            e.h(HK::MemLoadBI); e.d(fdst(T.res)); e.d(fop(A.args[0])); e.d(fop(A.args[1])); e.x(M.imm[0]);
            break;
        }
        case GK::MemStoreBI: {
            const Ins &A = bl.ins[m[0]], &M = bl.ins[m[1]];
            e.h(HK::MemStoreBI); e.d(fop(A.args[0])); e.d(fop(A.args[1])); e.d(fop(T.args[1])); e.x(M.imm[0]);
            break;
        }
        case GK::Fuse2: case GK::Fuse2F: {
            const Ins &I = bl.ins[m[0]], &O = bl.ins[m[1]];
            const bool right = O.args[1] == I.res;
            const uint32_t c = right ? O.args[0] : O.args[1];
            const int form = (right ? 1 : 0) + (kind == GK::Fuse2F ? 2 : 0);
            const int idx = (int)HK::F2LAddAdd + (arithIndex(I.op) * 4 + arithIndex(O.op)) * 4 + form;
            e.h((HK)idx); e.d(fdst(T.res)); e.d(fop(I.args[0])); e.d(fop(I.args[1])); e.d(fop(c));
            break;
        }
        case GK::None: break;
        }
    };

    // phi の写し（並行の写しを順に。輪になったら一時の升を使う）
    struct Copy { Slot *dst; Slot *src; };
    auto edgeCopies = [&](int to, int predIdx) {
        std::vector<Copy> cs;
        for (const Ins &P : fn.blocks[to].phis) {
            if (!vi[P.res].live || vi[P.res].uses.empty()) continue;
            Slot *dst = slotOf(P.res);
            Slot *src = slotOf(P.args[predIdx]);
            if (dst != src) cs.push_back(Copy{dst, src});
        }
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
    auto nextEmitted = [&](int b) {
        int n = b + 1;
        while (n < nb && absorbed[n]) ++n;
        return n;
    };
    // 辺の行き先のラベル（写しがあれば写しのあとで跳ぶ切れ端）
    auto edgeLabel = [&](int from, int k) {
        const Block &fb = fn.blocks[from];
        const int t = (int)fb.succ[k];
        std::vector<Copy> cs = edgeCopies(t, (int)fb.succPredIdx[k]);
        if (cs.empty()) return t;
        stubs.push_back(Stub{nextLabel, std::move(cs), t});
        return nextLabel++;
    };
    // [lkern] 自分へ戻る loop のブロックで、出すものが「dst = dst op 定数／升」1 つと DecJ だけなら、
    // loop を回し切るハンドラ 1 つに（数の升は phi とまとまっていて、戻る辺に写しが無いこと）
    auto loopKernel = [&](int b) -> bool {
        const Block &bl = fn.blocks[b];
        const TermFuse &tf = term[b];
        if (!on(ETVM_PASS_LKERN) || bl.term != Term::CondBr || tf.kind != TK::Dec || (int)bl.succ[0] != b) return false;
        if (!edgeCopies(b, (int)bl.succPredIdx[0]).empty()) return false;
        const Ins &D = bl.ins[tf.p0];
        const VInfo &pv = vi[D.args[0]];
        if (!pv.phi || pv.block != b || def[D.args[0]]->args[bl.succPredIdx[0]] != D.res) return false;
        int q = -1, n = 0;
        for (int i = 0; i < (int)bl.ins.size(); ++i)
            if (executes(b, i) && !retarget[b][i] && fuse[b][i] != 1 && fuse[b][i] != 3) { q = i; ++n; }
        if (n != 1) return false;
        const Ins *H = nullptr;
        bool filt = false;
        if (fuse[b][q] == 0 && isArith(bl.ins[q].op)) H = &bl.ins[q];
        else if (fuse[b][q] == 2 && groupKind[b][q] == GK::ArithF) { H = &bl.ins[groupMembers[b][q][0]]; filt = true; }
        if (!H) return false;
        double *dst = fdst(bl.ins[q].res);
        const int ai = arithIndex(H->op), fi = filt ? 1 : 0;
        // 行き先が右の + *（dst = a op dst）: 左が NaN でない定数か、フィルタが在れば入れ替えてよい（NaN が
        // 2 つにならない・NaN が 0 になる）。そうでなければ回し切らない（WDL は定数でない + * をフィルタ無しで
        // 升へ戻さない: ADD_OP_FAST・MUL_OP_FAST は定数のときだけ）
        const bool right = fop(H->args[0]) != dst && fop(H->args[1]) == dst && (ai == 0 || ai == 2);
        if (fop(H->args[0]) != dst && !right) return false;
        const uint32_t other = right ? H->args[0] : H->args[1];
        static const HK kIT[2][4] = {{HK::LKAddIT, HK::LKSubIT, HK::LKMulIT, HK::LKDivIT},
                                     {HK::LKAddITF, HK::LKSubITF, HK::LKMulITF, HK::LKDivITF}};
        static const HK kT[2][4] = {{HK::LKAddT, HK::LKSubT, HK::LKMulT, HK::LKDivT},
                                    {HK::LKAddTF, HK::LKSubTF, HK::LKMulTF, HK::LKDivTF}};
        double k = 0;
        if (on(ETVM_PASS_OPIMM) && immOf(other, k) && !(right && !filt && std::isnan(k))) {
            e.h(kIT[fi][ai]); e.s(sop(D.res)); e.s(sop(D.args[0])); e.d(dst); e.f(k);
        } else {
            if (right && !filt) return false;
            double *pb = fop(other);
            if (pb == dst) return false;
            e.h(kT[fi][ai]); e.s(sop(D.res)); e.s(sop(D.args[0])); e.d(dst); e.d(pb);
        }
        ++st.loopKernel;
        return true;
    };
    for (int b = 0; b < nb && ok; ++b) {
        if (absorbed[b]) continue;
        const Block &bl = fn.blocks[b];
        e.labelAt[(size_t)b] = e.code.size();
        if (loopKernel(b)) {
            const int t1 = edgeLabel(b, 1);
            if (t1 != nextEmitted(b)) { e.h(HK::Jmp); e.label(t1); }
            continue;
        }
        for (int i = 0; i < (int)bl.ins.size() && ok; ++i) {
            if (!executes(b, i) || retarget[b][i] || fuse[b][i] == 1 || fuse[b][i] == 3) continue;
            if (fuse[b][i] == 2) { emitGroup(bl, groupKind[b][i], groupMembers[b][i]); continue; }
            emitIns(bl.ins[i], b, i);
        }
        if (!ok) break;
        const int next = nextEmitted(b);
        switch (bl.term) {
        case Term::Ret: e.h(HK::Ret); break;
        case Term::Br: {
            const int t = (int)bl.succ[0];
            emitCopies(edgeCopies(t, (int)bl.succPredIdx[0]));
            if (t != next) { e.h(HK::Jmp); e.label(t); }
            break;
        }
        case Term::CondBr: {
            uint64_t kc = 0;
            const Ins *ci = fn.constIns(bl.cond);
            if (ci && ci->op == Op::BoolConst) {
                // 条件が定数（fold）: 跳ぶ方の辺だけ
                kc = ci->imm[0];
                const int k = kc ? 0 : 1;
                const int t = (int)bl.succ[k];
                emitCopies(edgeCopies(t, (int)bl.succPredIdx[k]));
                if (t != next) { e.h(HK::Jmp); e.label(t); }
                ++st.constBr;
                break;
            }
            const TermFuse &tf = term[b];
            int t0, t1; // 真・偽のラベル
            if (tf.kind == TK::While) {
                // 真: X の真の行き先（H）へ X→H の写し、偽: E（D→E と X→E の写しは同じ）
                const int X = tf.x;
                t0 = edgeLabel(X, 0);
                t1 = edgeLabel(b, 1);
            } else {
                t0 = edgeLabel(b, 0);
                t1 = edgeLabel(b, 1);
            }
            // jump(真なら跳ぶ?, ラベル)
            auto jump = [&](bool ifTrue, int label) {
                switch (tf.kind) {
                case TK::None: e.h(ifTrue ? HK::BrT : HK::BrF); e.s(sop(bl.cond)); break;
                case TK::LoopInit: {
                    const Ins &L = bl.ins[tf.p0];
                    e.h(ifTrue ? HK::LoopInitJ : HK::LoopInitJF); e.s(sop(L.res)); e.d(fop(L.args[0]));
                    break;
                }
                case TK::Dec: {
                    const Ins &D = bl.ins[tf.p0];
                    e.h(ifTrue ? HK::DecJ : HK::DecJF); e.s(sop(D.res)); e.s(sop(D.args[0]));
                    break;
                }
                case TK::While: {
                    const Ins &D = bl.ins[tf.p0];
                    if (tf.cmp < 0) {
                        e.h(ifTrue ? HK::WhileJ : HK::WhileJF); e.s(sop(D.res)); e.s(sop(D.args[0]));
                        e.s(sop(fn.blocks[tf.x].cond));
                        break;
                    }
                    const Ins &C = bl.ins[tf.cmp];
                    HK k = HK::Count;
                    switch (C.op) {
                    case Op::CmpLt: k = ifTrue ? HK::WLtJ : HK::WLtJF; break;
                    case Op::CmpGe: k = ifTrue ? HK::WGeJ : HK::WGeJF; break;
                    case Op::CmpEqClose: k = ifTrue ? HK::WEqCloseJ : HK::WEqCloseJF; break;
                    case Op::CmpNeClose: k = ifTrue ? HK::WNeCloseJ : HK::WNeCloseJF; break;
                    case Op::CmpEq: k = ifTrue ? HK::WEqJ : HK::WEqJF; break;
                    case Op::CmpNe: k = ifTrue ? HK::WNeJ : HK::WNeJF; break;
                    case Op::Truthy: k = ifTrue ? HK::WTruthyJ : HK::WTruthyJF; break;
                    case Op::Falsy: k = ifTrue ? HK::WFalsyJ : HK::WFalsyJF; break;
                    default: break;
                    }
                    e.h(k); e.s(sop(D.res)); e.s(sop(D.args[0])); e.d(fop(C.args[0]));
                    if (C.args.size() == 2) e.d(fop(C.args[1]));
                    break;
                }
                case TK::Cmp: {
                    const Ins &C = bl.ins[tf.p0];
                    HK k = HK::Count;
                    switch (C.op) {
                    case Op::CmpLt: k = ifTrue ? HK::JLt : HK::JNLt; break;
                    case Op::CmpGe: k = ifTrue ? HK::JGe : HK::JNGe; break;
                    case Op::CmpEqClose: k = ifTrue ? HK::JEqClose : HK::JNEqClose; break;
                    case Op::CmpNeClose: k = ifTrue ? HK::JNeClose : HK::JNNeClose; break;
                    case Op::CmpEq: k = ifTrue ? HK::JEq : HK::JNEq; break;
                    case Op::CmpNe: k = ifTrue ? HK::JNe : HK::JNNe; break;
                    case Op::Truthy: k = ifTrue ? HK::JTruthy : HK::JNTruthy; break;
                    case Op::Falsy: k = ifTrue ? HK::JFalsy : HK::JNFalsy; break;
                    default: break;
                    }
                    e.h(k);
                    e.d(fop(C.args[0]));
                    if (C.args.size() == 2) e.d(fop(C.args[1]));
                    break;
                }
                }
                e.label(label);
            };
            if (tf.kind == TK::None && t0 == t1) {
                if (t0 != next) { e.h(HK::Jmp); e.label(t0); }
            } else if (t1 == next) {
                jump(true, t0);
            } else if (t0 == next) {
                jump(false, t1);
            } else if (tf.kind == TK::None) {
                e.h(HK::Br); e.s(sop(bl.cond)); e.label(t0); e.label(t1);
            } else {
                jump(true, t0);
                e.h(HK::Jmp); e.label(t1);
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

/// 命令の中に置いた定数のオペランドの番号（1 から。無ければ 0）
int immOperand(HK k)
{
    switch (k) {
    case HK::AddI: case HK::SubI: case HK::RSubI: case HK::MulI: case HK::DivI: case HK::RDivI:
    case HK::AddIF: case HK::SubIF: case HK::RSubIF: case HK::MulIF: case HK::DivIF: case HK::RDivIF:
        return 3;
    case HK::AddIT: case HK::SubIT: case HK::MulIT: case HK::DivIT:
    case HK::AddITF: case HK::SubITF: case HK::MulITF: case HK::DivITF:
        return 2;
    case HK::LKAddIT: case HK::LKSubIT: case HK::LKMulIT: case HK::LKDivIT:
    case HK::LKAddITF: case HK::LKSubITF: case HK::LKMulITF: case HK::LKDivITF:
        return 4;
    default:
        return 0;
    }
}

} // namespace

ThreadedProgram *buildThreaded(const Function &fn, std::string &why, ThreadedStats *stats, uint32_t passes)
{
    if (fn.blocks.empty()) { why = "no blocks"; return nullptr; }
    Builder b(fn, why, passes);
    if (!b.analyse()) return nullptr;
    b.liveness();
    if (b.on(ETVM_PASS_LDFOLD)) b.foldLoads();
    if (b.on(ETVM_PASS_DIRECT)) b.directDest();
    b.fuseTerms();
    b.fuseGroups();
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
        const int imm = immOperand(k);
        for (int j = 1; j <= n; ++j) {
            std::string o;
            if (j == imm) {
                std::snprintf(buf, sizeof buf, "=%.17g", p->code[at + (size_t)j].f);
                o = buf;
            } else {
                o = operand(p->code[at + (size_t)j]);
            }
            out += (j == 1 ? " " : ", ") + o;
        }
        out += "\n";
        at += 1 + (size_t)n;
    }
    std::snprintf(buf, sizeof buf, "  ; %zu handlers, %zu words, frame %zu (global %zu, local %zu, pool %zu)\n",
                  p->stats.handlers, p->stats.words, p->frame.size(), p->nGlobal, p->nLocal, p->nPool);
    out += buf;
    return out;
}

} // namespace etvm
