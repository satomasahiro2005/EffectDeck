// ETVMLift.cpp — portable のバイトコード → SSA（docs/jsfx-regvm-design.md §6、付録 A）。
//
// 1. 辿る: 入口から命令を 1 つずつ読み、(番地, FCALL の戻り先の列) を 1 つの節にして行き先を張る。
//    FCALL は呼ぶ所ごとに展開する（関数の中は呼ぶ所の積み場のまま続く。EEL は再帰しない）。
// 2. 節を基本ブロックにまとめ、逆後順（RPO）に並べて後ろへの辺（loop の戻り）を見つける。
// 3. RPO の順に、portable の機械（p1〜p3・浮動小数の積み場・解釈の積み場・wtp）を抽象的に回して
//    命令を出す。合流では値の違う段だけ phi にする。後ろへの辺の来るブロック（loop の頭）は全部の段を
//    phi にしておき、戻りの辺の値は最後に埋める。最後に要らない phi と定数を消して番号を詰め、verify する。
#include "ETVMLift.h"

#include "ETVMBytecode.h"
#include "WDL/eel2/ns-eel-int.h"

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <map>
#include <unordered_map>
#include <vector>

namespace etvm {

const char *fallbackName(Fallback f)
{
    static const char *const names[] = {
        "none", "no-code", "unknown-opcode", "opcode-0", "dbg-getstackptr", "jump-outside", "call-depth",
        "node-budget", "ir-budget", "fp-underflow", "fp-overflow", "stack-underflow", "stack-overflow",
        "shape-mismatch", "wtp-mismatch", "undefined", "type-confusion", "null-deref", "bool-deref",
        "stackaddr-misuse", "varparm-shape", "ret-mismatch", "verify-failed",
    };
    static_assert(sizeof names / sizeof *names == (size_t)Fallback::Count, "fallbackName table");
    return (size_t)f < (size_t)Fallback::Count ? names[(size_t)f] : "?";
}

bool liftInputFromHandle(void *handle, LiftInput &in)
{
    const codeHandleType *h = (const codeHandleType *)handle;
    if (!h || !h->code) return false;
    in.code = (const unsigned char *)h->code;
    in.workTable = (uint64_t)(uintptr_t)h->workTable;
    in.ramPtr = (uint64_t)(uintptr_t)h->ramPtr;
    in.codeRanges.clear();
    for (const llBlock *b = h->blocks_code; b; b = b->next) {
        const uint64_t start = (uint64_t)(uintptr_t)(b + 1);
        in.codeRanges.push_back({start, start + (uint64_t)b->sizeused});
    }
    return true;
}

namespace {

constexpr size_t kFpMax = 64;                 // GLUE_MAX_FPSTACK_SIZE
constexpr size_t kStackBytes = 65536;         // EEL_BC_STACKSIZE
constexpr int32_t kLoopMax = NSEEL_LOOPFUNC_SUPPORT_MAXLEN;

struct LiftError {
    Fallback reason;
    std::string detail;
    uint64_t pc;
};

struct Node {
    uint64_t pc = 0, next = 0;
    uint32_t cs = 0;
    int op = 0;
    uint32_t succ[2] = {0, 0};
    uint8_t nsucc = 0;
    uint32_t npred = 0, pred0 = 0;
    uint32_t block = UINT32_MAX;
};

struct PReg {
    uint8_t k = 0;  // 0 = 値, 1 = 解釈の積み場の番地（v = その時の段数）, 2 = 合流で道ごとに違う（使えない）
    uint32_t v = 0;
};
struct Slot {
    uint8_t k = 0;  // 0 = 書いていない, 1 = 値, 2 = 保存した wtp, 3 = 戻り先
    uint32_t v = 0;
    uint64_t x = 0;
};
struct State {
    PReg p[3];
    std::vector<uint32_t> fp;
    std::vector<Slot> stk;
    uint64_t wtp = 0;
};

struct Edge { uint32_t src; uint8_t e; bool back; };

struct Ctx {
    std::vector<uint64_t> calls;  // FCALL の戻り先
    uint64_t wtp = 0;
    std::vector<uint64_t> saves;  // LOOP_LOADCNT・WHILE_BEGIN が保存した wtp
    bool operator<(const Ctx &o) const
    {
        if (wtp != o.wtp) return wtp < o.wtp;
        if (calls != o.calls) return calls < o.calls;
        return saves < o.saves;
    }
};

struct BlockInfo {
    std::vector<uint32_t> nodes;
    uint32_t succ[2] = {0, 0};
    uint8_t nsucc = 0;
    std::vector<Edge> preds;  // IR の preds と同じ順
    uint32_t ir = UINT32_MAX; // RPO の番号 = IR のブロック
    bool header = false;
    bool done = false;
    State entry;
    State out[2];
};

struct PendingPhi { uint32_t bi; uint32_t phiIndex; int slot; Ty ty; };

struct PairHash {
    size_t operator()(const std::pair<uint64_t, uint32_t> &k) const
    {
        return std::hash<uint64_t>()(k.first * 0x9e3779b97f4a7c15ull ^ k.second);
    }
};

class Lifter {
public:
    Lifter(const LiftInput &in, const LiftOptions &opt) : in_(in), opt_(opt) {}

    LiftResult run()
    {
        LiftResult r;
        if (!in_.code) { r.reason = Fallback::NoCode; return r; }
        base_ = (uint64_t)(uintptr_t)in_.code;
        fn_.codeBase = base_;
        try {
            discover();
            r.nodes = nodes_.size();
            buildBlocks();
            liftAll();
            cleanup();
            fn_.finalize();
            std::string why;
            if (!verify(fn_, why)) throw LiftError{Fallback::VerifyFailed, why, 0};
        } catch (const LiftError &e) {
            r.reason = e.reason;
            r.detail = e.detail;
            r.pc = e.pc >= base_ && e.pc - base_ < (1ull << 32) ? e.pc - base_ : e.pc;
            r.nodes = nodes_.size();
            return r;
        }
        uint64_t bytes = 0;
        for (auto &rg : in_.codeRanges) bytes += rg.second - rg.first;
        r.bytecodeBytes = (size_t)bytes;
        r.fn = std::move(fn_);
        return r;
    }

private:
    const LiftInput &in_;
    LiftOptions opt_;
    uint64_t base_ = 0;
    Function fn_;
    std::vector<Node> nodes_;
    std::unordered_map<std::pair<uint64_t, uint32_t>, uint32_t, PairHash> nodeIds_;
    std::vector<Ctx> ctxs_;
    std::map<Ctx, uint32_t> ctxIds_;
    std::vector<uint32_t> work_;
    std::vector<BlockInfo> blocks_;
    std::vector<uint32_t> rpo_;          // RPO の順の BlockInfo の番号
    std::vector<PendingPhi> pending_;
    std::map<uint64_t, uint32_t> ptrConsts_;
    std::map<int64_t, uint32_t> i32Consts_;
    uint32_t boolConsts_[2] = {kNoValue, kNoValue};
    uint32_t cur_ = 0;                   // 命令を出す IR のブロック
    uint64_t curPc_ = 0;
    size_t insCount_ = 0;

    [[noreturn]] void fail(Fallback f, const std::string &detail, uint64_t pc) { throw LiftError{f, detail, pc}; }
    [[noreturn]] void fail(Fallback f, const std::string &detail) { throw LiftError{f, detail, curPc_}; }

    bool inCode(uint64_t pc, uint64_t len) const
    {
        for (auto &r : in_.codeRanges)
            if (pc >= r.first && pc + len <= r.second && pc + len >= pc) return true;
        return false;
    }

    // ---- 1. 辿る ----------------------------------------------------------------------------------
    // 節の文脈 = FCALL の戻り先の列・wtp・loop / while が保存した wtp の列。wtp は道ごとに静的に決まる
    // （RESET_WTP・POP_FPSTACK_TO_WTP・保存と戻し）。合流で wtp が違う（?: の片方だけが作業表を使う）なら
    // 先を道ごとに別の節にする（portable と同じ番地の一時を使い続けるため）。
    uint32_t internCtx(const Ctx &c)
    {
        auto it = ctxIds_.find(c);
        if (it != ctxIds_.end()) return it->second;
        const uint32_t id = (uint32_t)ctxs_.size();
        ctxs_.push_back(c);
        ctxIds_.emplace(c, id);
        return id;
    }

    uint32_t nodeId(uint64_t pc, uint32_t cs)
    {
        auto key = std::make_pair(pc, cs);
        auto it = nodeIds_.find(key);
        if (it != nodeIds_.end()) return it->second;
        if (nodes_.size() >= opt_.maxNodes) fail(Fallback::NodeBudget, std::to_string(nodes_.size()) + " nodes", pc);
        const uint32_t id = (uint32_t)nodes_.size();
        Node n;
        n.pc = pc;
        n.cs = cs;
        nodes_.push_back(n);
        nodeIds_.emplace(key, id);
        work_.push_back(id);
        return id;
    }

    void discover()
    {
        Ctx start;
        start.wtp = in_.workTable;
        nodeId(base_, internCtx(start));
        while (!work_.empty()) {
            const uint32_t id = work_.back();
            work_.pop_back();
            const uint64_t pc = nodes_[id].pc;
            const uint32_t cs = nodes_[id].cs;
            if (!inCode(pc, 4)) fail(Fallback::JumpOutside, "instruction outside code", pc);
            const unsigned char *p = (const unsigned char *)(uintptr_t)pc;
            const int op = etbc_read_i32(p);
            if (op == 0) fail(Fallback::Opcode0, "opcode 0", pc);
            const int ib = etbc_imm_bytes(op);
            if (ib < 0) fail(Fallback::UnknownOpcode, "opcode " + std::to_string(op), pc);
            if (op == ETBC_DBG_GETSTACKPTR) fail(Fallback::DbgGetStackPtr, "__dbg_getstackptr", pc);
            if (!inCode(pc, 4 + (uint64_t)ib)) fail(Fallback::JumpOutside, "immediate outside code", pc);
            const uint64_t next = pc + 4 + (uint64_t)ib;
            uint64_t target = 0;
            if (ib == 4 && op != ETBC_MOVE_STACK && op != ETBC_STORE_P1_TO_STACK_AT_OFFS)
                target = pc + 8 + (uint64_t)(int64_t)etbc_read_i32(p + 4);
            uint64_t s0 = next, s1 = 0;
            Ctx c0 = ctxs_[cs], c1 = ctxs_[cs];
            int ns = 1;
            auto needSave = [&]() {
                if (c0.saves.empty()) fail(Fallback::WtpMismatch, "loop end without a saved wtp", pc);
            };
            switch (op) {
            case ETBC_JMP_NC: s0 = target; break;
            case ETBC_JMP_IF_P1_Z: s0 = next; s1 = target; ns = 2; break;
            case ETBC_JMP_IF_P1_NZ: case ETBC_WHILE_CHECK_RV: s0 = target; s1 = next; ns = 2; break;
            case ETBC__RESET_WTP: c0.wtp = etbc_read_u64(p + 4); break;
            case ETBC_POP_FPSTACK_TO_WTP: c0.wtp += 8; break;
            case ETBC_LOOP_LOADCNT: // 0 = 飛ばす（積まない）, 1 = 回す（wtp を保存）
                s0 = target; s1 = next; ns = 2;
                c1.saves.push_back(c1.wtp);
                break;
            case ETBC_LOOP_END: // 0 = 戻る（保存はそのまま）, 1 = 抜ける（降ろす）。どちらも wtp を戻す
                needSave();
                s0 = target; s1 = next; ns = 2;
                c0.wtp = c1.wtp = c0.saves.back();
                c1.saves.pop_back();
                break;
            case ETBC_WHILE_BEGIN: c0.saves.push_back(c0.wtp); break;
            case ETBC_WHILE_END: // 0 = 続ける, 1 = 打ち切る。どちらも保存を降ろして戻す
                needSave();
                s0 = next; s1 = target; ns = 2;
                c0.wtp = c0.saves.back();
                c0.saves.pop_back();
                c1 = c0;
                break;
            case ETBC_FCALL:
                if ((int)c0.calls.size() >= opt_.maxCallDepth) fail(Fallback::CallDepth, "FCALL depth", pc);
                c0.calls.push_back(next);
                s0 = etbc_read_u64(p + 4);
                break;
            case ETBC_RET:
                if (c0.calls.empty()) { ns = 0; break; }
                s0 = c0.calls.back();
                c0.calls.pop_back();
                break;
            default: break;
            }
            uint32_t succ[2] = {0, 0};
            if (ns >= 1) succ[0] = nodeId(s0, internCtx(c0));
            if (ns >= 2) succ[1] = nodeId(s1, internCtx(c1));
            Node &n = nodes_[id];
            n.op = op;
            n.next = next;
            n.nsucc = (uint8_t)ns;
            n.succ[0] = succ[0];
            n.succ[1] = succ[1];
        }
        for (uint32_t i = 0; i < nodes_.size(); ++i)
            for (int s = 0; s < nodes_[i].nsucc; ++s) {
                Node &t = nodes_[nodes_[i].succ[s]];
                if (t.npred++ == 0) t.pred0 = i;
            }
    }

    // ---- 2. ブロックと RPO --------------------------------------------------------------------------
    bool isLeader(uint32_t i) const
    {
        const Node &n = nodes_[i];
        return i == 0 || n.npred != 1 || nodes_[n.pred0].nsucc != 1;
    }

    void buildBlocks()
    {
        for (uint32_t i = 0; i < nodes_.size(); ++i) {
            if (!isLeader(i)) continue;
            BlockInfo b;
            uint32_t cur = i;
            for (;;) {
                if (nodes_[cur].block != UINT32_MAX) fail(Fallback::ShapeMismatch, "cfg: node in two blocks", nodes_[cur].pc);
                nodes_[cur].block = (uint32_t)blocks_.size();
                b.nodes.push_back(cur);
                const Node &n = nodes_[cur];
                if (n.nsucc != 1 || isLeader(n.succ[0])) break;
                cur = n.succ[0];
            }
            blocks_.push_back(std::move(b));
        }
        for (const Node &n : nodes_)
            if (n.block == UINT32_MAX) fail(Fallback::ShapeMismatch, "cfg: node without block", n.pc);
        for (BlockInfo &b : blocks_) {
            const Node &last = nodes_[b.nodes.back()];
            b.nsucc = last.nsucc;
            for (int s = 0; s < last.nsucc; ++s) b.succ[s] = nodes_[last.succ[s]].block;
        }
        // RPO と後ろへの辺
        const uint32_t n = (uint32_t)blocks_.size();
        std::vector<uint8_t> st(n, 0);
        std::vector<std::pair<uint32_t, int>> stack{{nodes_[0].block, 0}};
        st[nodes_[0].block] = 1;
        std::vector<uint32_t> post;
        std::vector<std::vector<uint8_t>> back(n, std::vector<uint8_t>(2, 0));
        while (!stack.empty()) {
            auto &[b, k] = stack.back();
            if (k < blocks_[b].nsucc) {
                const uint32_t s = blocks_[b].succ[k];
                if (st[s] == 1) back[b][k] = 1;
                else if (st[s] == 0) { st[s] = 1; ++k; stack.push_back({s, 0}); continue; }
                ++k;
            } else {
                st[b] = 2;
                post.push_back(b);
                stack.pop_back();
            }
        }
        rpo_.assign(post.rbegin(), post.rend());
        if (rpo_.size() != n) fail(Fallback::ShapeMismatch, "cfg: unreachable blocks", base_);
        fn_.blocks.resize(n);
        for (uint32_t i = 0; i < n; ++i) blocks_[rpo_[i]].ir = i;
        for (uint32_t i = 0; i < n; ++i) {
            const uint32_t b = rpo_[i];
            for (int k = 0; k < blocks_[b].nsucc; ++k) {
                BlockInfo &t = blocks_[blocks_[b].succ[k]];
                t.preds.push_back(Edge{b, (uint8_t)k, back[b][k] != 0});
                if (back[b][k]) t.header = true;
                fn_.blocks[t.ir].preds.push_back(i);
            }
        }
        if (!blocks_[rpo_[0]].preds.empty()) fail(Fallback::ShapeMismatch, "cfg: entry is a jump target", base_);
    }

    // ---- 3. 値 ------------------------------------------------------------------------------------
    uint32_t newConst(Op op, Ty ty, uint64_t imm)
    {
        Ins c;
        c.op = op;
        c.ty = ty;
        c.res = fn_.newValue(ty);
        c.imm[0] = imm;
        fn_.values[c.res].block = -1;          // constAddr が持ち上げの途中でも引けるように
        fn_.values[c.res].index = (uint32_t)fn_.consts.size();
        fn_.consts.push_back(c);
        return c.res;
    }
    uint32_t ptrConst(uint64_t a)
    {
        auto it = ptrConsts_.find(a);
        if (it != ptrConsts_.end()) return it->second;
        const uint32_t v = newConst(Op::PtrConst, Ty::Ptr, a);
        ptrConsts_.emplace(a, v);
        return v;
    }
    uint32_t boolConst(bool b)
    {
        uint32_t &v = boolConsts_[b ? 1 : 0];
        if (v == kNoValue) v = newConst(Op::BoolConst, Ty::Bool, b ? 1 : 0);
        return v;
    }
    uint32_t i32Const(int32_t x)
    {
        auto it = i32Consts_.find(x);
        if (it != i32Consts_.end()) return it->second;
        const uint32_t v = newConst(Op::I32Const, Ty::I32, (uint64_t)(int64_t)x);
        i32Consts_.emplace(x, v);
        return v;
    }

    uint32_t emitTo(uint32_t block, Op op, Ty ty, std::vector<uint32_t> args, uint64_t i0 = 0, uint64_t i1 = 0,
                    uint64_t i2 = 0, uint64_t i3 = 0)
    {
        if (++insCount_ > opt_.maxIns) fail(Fallback::IRBudget, std::to_string(insCount_) + " IR instructions");
        Ins in;
        in.op = op;
        in.ty = ty;
        in.args = std::move(args);
        in.imm[0] = i0; in.imm[1] = i1; in.imm[2] = i2; in.imm[3] = i3;
        in.pc = (uint32_t)(curPc_ - base_);
        if (ty != Ty::Void) {
            in.res = fn_.newValue(ty);
            fn_.values[in.res].block = (int32_t)block;
            fn_.values[in.res].index = (uint32_t)fn_.blocks[block].ins.size();
        }
        fn_.blocks[block].ins.push_back(std::move(in));
        return fn_.blocks[block].ins.back().res;
    }
    uint32_t emit(Op op, Ty ty, std::vector<uint32_t> args, uint64_t i0 = 0, uint64_t i1 = 0, uint64_t i2 = 0,
                  uint64_t i3 = 0)
    {
        return emitTo(cur_, op, ty, std::move(args), i0, i1, i2, i3);
    }

    Ty tyOf(uint32_t v) const { return fn_.values[v].ty; }

    uint32_t valOf(const PReg &r)
    {
        if (r.k == 2) fail(Fallback::Undefined, "p-register differs by path at a merge and is read afterwards");
        if (r.k != 0) fail(Fallback::StackAddrMisuse, "interpreter stack address used as a value");
        return r.v;
    }
    uint32_t asPtr(const PReg &r)
    {
        const uint32_t v = valOf(r);
        if (tyOf(v) == Ty::Ptr) return v;
        if (tyOf(v) == Ty::Bool) return emit(Op::BoolToPtr, Ty::Ptr, {v});
        fail(Fallback::TypeConfusion, std::string("p-register holds ") + tyName(tyOf(v)));
    }
    uint32_t asBool(const PReg &r)
    {
        const uint32_t v = valOf(r);
        if (tyOf(v) == Ty::Bool) return v;
        if (tyOf(v) == Ty::Ptr) return emit(Op::PtrNonNull, Ty::Bool, {v});
        fail(Fallback::TypeConfusion, std::string("p-register holds ") + tyName(tyOf(v)));
    }
    uint32_t loadVia(const PReg &r)
    {
        const uint32_t v = valOf(r);
        if (tyOf(v) == Ty::Bool) fail(Fallback::BoolDeref, "load through a compare result");
        if (tyOf(v) != Ty::Ptr) fail(Fallback::TypeConfusion, "load through a non-pointer");
        uint64_t a;
        if (fn_.constAddr(v, a)) {
            if (a == 0) fail(Fallback::NullDeref, "load from address 0");
            return emit(Op::LoadCell, Ty::F64, {}, a);
        }
        return emit(Op::Load, Ty::F64, {v});
    }
    void storeVia(const PReg &r, uint32_t val)
    {
        const uint32_t v = valOf(r);
        if (tyOf(v) == Ty::Bool) fail(Fallback::BoolDeref, "store through a compare result");
        if (tyOf(v) != Ty::Ptr) fail(Fallback::TypeConfusion, "store through a non-pointer");
        uint64_t a;
        if (fn_.constAddr(v, a)) {
            if (a == 0) fail(Fallback::NullDeref, "store to address 0");
            emit(Op::StoreCell, Ty::Void, {val}, a);
            return;
        }
        emit(Op::Store, Ty::Void, {v, val});
    }
    void storeCell(uint64_t a, uint32_t val)
    {
        if (a == 0) fail(Fallback::NullDeref, "store to address 0");
        emit(Op::StoreCell, Ty::Void, {val}, a);
    }
    uint32_t loadCell(uint64_t a)
    {
        if (a == 0) fail(Fallback::NullDeref, "load from address 0");
        return emit(Op::LoadCell, Ty::F64, {}, a);
    }

    uint32_t fpPop(State &s)
    {
        if (s.fp.empty()) fail(Fallback::FpUnderflow, "fp stack empty");
        const uint32_t v = s.fp.back();
        s.fp.pop_back();
        return v;
    }
    uint32_t &fpTop(State &s)
    {
        if (s.fp.empty()) fail(Fallback::FpUnderflow, "fp stack empty");
        return s.fp.back();
    }
    void fpPush(State &s, uint32_t v)
    {
        if (s.fp.size() >= kFpMax) fail(Fallback::FpOverflow, "fp stack > 64");
        s.fp.push_back(v);
    }
    void stkPush(State &s, const Slot &x)
    {
        if ((s.stk.size() + 1) * 8 > kStackBytes) fail(Fallback::StackOverflow, "interpreter stack > 64 KiB");
        s.stk.push_back(x);
    }
    Slot stkPop(State &s)
    {
        if (s.stk.empty()) fail(Fallback::StackUnderflow, "interpreter stack empty");
        Slot x = s.stk.back();
        s.stk.pop_back();
        return x;
    }
    Slot &stkTop(State &s)
    {
        if (s.stk.empty()) fail(Fallback::StackUnderflow, "interpreter stack empty");
        return s.stk.back();
    }
    uint32_t slotValue(const Slot &x, Ty want1, Ty want2 = Ty::Void)
    {
        if (x.k == 0) fail(Fallback::Undefined, "read of an unwritten interpreter stack slot");
        if (x.k != 1) fail(Fallback::TypeConfusion, "interpreter stack slot holds a saved wtp / return address");
        const Ty t = tyOf(x.v);
        if (t != want1 && t != want2)
            fail(Fallback::TypeConfusion, std::string("interpreter stack slot holds ") + tyName(t));
        return x.v;
    }
    PReg slotToPReg(const Slot &x)
    {
        PReg r;
        r.v = slotValue(x, Ty::Ptr, Ty::Bool);
        return r;
    }

    // ---- 合流 ---------------------------------------------------------------------------------------
    static uint32_t *slotRef(State &s, int id)
    {
        if (id < 3) return s.p[id].k == 0 ? &s.p[id].v : nullptr;
        if (id < 3 + (int)kFpMax) return (size_t)(id - 3) < s.fp.size() ? &s.fp[id - 3] : nullptr;
        const size_t j = (size_t)(id - 3 - (int)kFpMax);
        return j < s.stk.size() && s.stk[j].k == 1 ? &s.stk[j].v : nullptr;
    }

    void sameShape(const State &a, const State &b, const char *where)
    {
        auto bad = [&](const std::string &what) { fail(Fallback::ShapeMismatch, std::string(where) + ": " + what); };
        // p1〜p3 の種類の違いは mergeEntry が「書いていない」にする（使えば Undefined）。
        if (a.fp.size() != b.fp.size()) bad("fp depth " + std::to_string(a.fp.size()) + "/" + std::to_string(b.fp.size()));
        if (a.stk.size() != b.stk.size())
            bad("stack depth " + std::to_string(a.stk.size()) + "/" + std::to_string(b.stk.size()));
        for (size_t j = 0; j < a.stk.size(); ++j) {
            const Slot &x = a.stk[j], &y = b.stk[j];
            if (x.k != y.k) bad("stack slot kind");
            if ((x.k == 2 || x.k == 3) && x.x != y.x) bad("stack slot saved value");
        }
        if (a.wtp != b.wtp) fail(Fallback::WtpMismatch, std::string(where) + ": wtp");
    }

    uint32_t convertAtEnd(uint32_t irBlock, uint32_t v, Ty want)
    {
        if (tyOf(v) == want) return v;
        if (tyOf(v) == Ty::Bool && want == Ty::Ptr) return emitTo(irBlock, Op::BoolToPtr, Ty::Ptr, {v});
        fail(Fallback::TypeConfusion, std::string("merge of ") + tyName(tyOf(v)) + " into " + tyName(want));
    }

    static Ty unify(Ty a, Ty b, bool &ok)
    {
        if (a == b) return a;
        if ((a == Ty::Bool || a == Ty::Ptr) && (b == Ty::Bool || b == Ty::Ptr)) return Ty::Ptr;
        ok = false;
        return a;
    }

    State mergeEntry(uint32_t bi)
    {
        BlockInfo &b = blocks_[bi];
        std::vector<size_t> fwd;
        for (size_t k = 0; k < b.preds.size(); ++k)
            if (!b.preds[k].back) fwd.push_back(k);
        if (fwd.empty()) fail(Fallback::ShapeMismatch, "block reached only by back edges");
        auto predOut = [&](size_t k) -> State & { return blocks_[b.preds[k].src].out[b.preds[k].e]; };
        State s = predOut(fwd[0]);
        for (size_t i = 1; i < fwd.size(); ++i) sameShape(s, predOut(fwd[i]), "merge");
        // p1〜p3: 道ごとに種類が違う（varparm の呼び出しのあとの積み場の番地と値など）なら、合流の先では
        // 使えない値にする。portable では古い番地が残るだけで、WDL はそれを読まない（読めば Undefined で断る）。
        for (int i = 0; i < 3; ++i)
            for (size_t k : fwd) {
                const PReg &q = predOut(k).p[i];
                if (q.k != s.p[i].k || (q.k == 1 && q.v != s.p[i].v)) { s.p[i] = PReg{2, 0}; break; }
            }
        if (!b.header && b.preds.size() == 1) return s;
        const int nslots = 3 + (int)kFpMax + (int)s.stk.size();
        for (int id = 0; id < nslots; ++id) {
            uint32_t *mine = slotRef(s, id);
            if (!mine) continue;
            bool same = true, ok = true;
            Ty t = tyOf(*mine);
            for (size_t k : fwd) {
                const uint32_t v = *slotRef(predOut(k), id);
                same &= v == *mine;
                t = unify(t, tyOf(v), ok);
            }
            if (!ok) fail(Fallback::TypeConfusion, "merge of different value types (slot " + std::to_string(id) + ")");
            if (same && !b.header) continue;
            if (b.header && t == Ty::Bool) t = Ty::Ptr; // 戻りの辺がポインタを持ってきても受けられるように
            Ins phi;
            phi.op = Op::Phi;
            phi.ty = t;
            phi.res = fn_.newValue(t);
            phi.args.assign(b.preds.size(), kNoValue);
            for (size_t k : fwd)
                phi.args[k] = convertAtEnd(blocks_[b.preds[k].src].ir, *slotRef(predOut(k), id), t);
            Block &irb = fn_.blocks[b.ir];
            fn_.values[phi.res].block = (int32_t)b.ir;
            fn_.values[phi.res].index = (uint32_t)irb.phis.size();
            fn_.values[phi.res].phi = true;
            if (b.header) pending_.push_back(PendingPhi{bi, (uint32_t)irb.phis.size(), id, t});
            *mine = phi.res;
            irb.phis.push_back(std::move(phi));
        }
        return s;
    }

    void fillBackEdges()
    {
        for (const PendingPhi &pp : pending_) {
            BlockInfo &b = blocks_[pp.bi];
            for (size_t k = 0; k < b.preds.size(); ++k) {
                if (!b.preds[k].back) continue;
                BlockInfo &src = blocks_[b.preds[k].src];
                State &st = src.out[b.preds[k].e];
                uint32_t *v = slotRef(st, pp.slot);
                if (!v) fail(Fallback::ShapeMismatch, "back edge lacks a slot", nodes_[b.nodes[0]].pc);
                const uint32_t c = convertAtEnd(src.ir, *v, pp.ty);
                fn_.blocks[b.ir].phis[pp.phiIndex].args[k] = c;
            }
        }
        for (BlockInfo &b : blocks_) {
            if (!b.header) continue;
            for (size_t k = 0; k < b.preds.size(); ++k)
                if (b.preds[k].back) {
                    curPc_ = nodes_[b.nodes[0]].pc;
                    const State &back = blocks_[b.preds[k].src].out[b.preds[k].e];
                    sameShape(b.entry, back, "loop back edge");
                    for (int i = 0; i < 3; ++i) {
                        const PReg &h = b.entry.p[i], &q = back.p[i];
                        if (h.k == 2) continue;                       // 頭で使えない値は戻りでも使わない
                        if (h.k != q.k || (h.k == 1 && h.v != q.v))
                            fail(Fallback::ShapeMismatch, "loop back edge: p" + std::to_string(i + 1) + " kind");
                    }
                }
        }
    }

    // ---- 命令 ---------------------------------------------------------------------------------------
    void liftAll()
    {
        for (uint32_t i = 0; i < rpo_.size(); ++i) {
            const uint32_t bi = rpo_[i];
            BlockInfo &b = blocks_[bi];
            cur_ = b.ir;
            curPc_ = nodes_[b.nodes[0]].pc;
            fn_.blocks[b.ir].pc = curPc_ - base_;
            State s;
            if (i == 0) {
                for (PReg &r : s.p) { r.k = 0; r.v = ptrConst(0); }
                s.wtp = in_.workTable;
            } else {
                s = mergeEntry(bi);
            }
            if (s.wtp != ctxs_[nodes_[b.nodes[0]].cs].wtp)
                fail(Fallback::WtpMismatch, "lifter wtp model differs from the path context");
            if (b.header) b.entry = s;
            liftBlock(bi, s);
            b.done = true;
        }
        fillBackEdges();
    }

    void liftBlock(uint32_t bi, State s)
    {
        BlockInfo &b = blocks_[bi];
        Block &irb = fn_.blocks[b.ir];
        uint32_t cond = kNoValue;
        State other;            // 2 本目の辺の状態
        for (size_t ni = 0; ni < b.nodes.size(); ++ni) {
            const Node &n = nodes_[b.nodes[ni]];
            curPc_ = n.pc;
            const unsigned char *p = (const unsigned char *)(uintptr_t)n.pc + 4;
            const bool last = ni + 1 == b.nodes.size();
            auto u64 = [&](int k) { return etbc_read_u64(p + 8 * k); };
            switch (n.op) {
            case ETBC_NOP: break;
            case ETBC_RET:
                if (n.nsucc == 0) {
                    if (!s.stk.empty()) fail(Fallback::RetMismatch, "top-level RET with a non-empty interpreter stack");
                } else {
                    const Slot r = stkPop(s);
                    if (r.k != 3 || r.x != nodes_[n.succ[0]].pc) fail(Fallback::RetMismatch, "RET does not pop its return address");
                }
                break;
            case ETBC_JMP_NC: break;
            case ETBC_JMP_IF_P1_Z: case ETBC_JMP_IF_P1_NZ:
                cond = asBool(s.p[0]);
                other = s;
                break;
            case ETBC_MOV_FPTOP_DV: fpPush(s, loadCell(u64(0))); break;
            case ETBC_MOV_P1_DV: case ETBC_MOV_P2_DV: case ETBC_MOV_P3_DV:
                s.p[n.op - ETBC_MOV_P1_DV] = PReg{0, ptrConst(u64(0))};
                break;
            case ETBC__RESET_WTP: s.wtp = u64(0); break;
            case ETBC_PUSH_P1: stkPush(s, Slot{1, valOf(s.p[0]), 0}); break;
            case ETBC_PUSH_P1PTR_AS_VALUE: stkPush(s, Slot{1, loadVia(s.p[0]), 0}); break;
            case ETBC_POP_P1: case ETBC_POP_P2: case ETBC_POP_P3: {
                const Slot x = stkPop(s);
                s.p[n.op - ETBC_POP_P1] = slotToPReg(x);
                break;
            }
            case ETBC_POP_VALUE_TO_ADDR: {
                const Slot x = stkPop(s);
                storeCell(u64(0), slotValue(x, Ty::F64));
                break;
            }
            case ETBC_MOVE_STACK: {
                const int32_t amt = etbc_read_i32(p);
                if (amt % 8) fail(Fallback::VarparmShape, "MOVE_STACK by " + std::to_string(amt));
                if (amt < 0) for (int32_t k = 0; k < -amt / 8; ++k) stkPush(s, Slot{});
                else for (int32_t k = 0; k < amt / 8; ++k) stkPop(s);
                break;
            }
            case ETBC_STORE_P1_TO_STACK_AT_OFFS: {
                const int32_t off = etbc_read_i32(p);
                if (off < 0 || off % 8 || (size_t)(off / 8) >= s.stk.size())
                    fail(Fallback::VarparmShape, "STORE_P1_TO_STACK_AT_OFFS " + std::to_string(off));
                Slot &x = s.stk[s.stk.size() - 1 - (size_t)(off / 8)];
                if (s.p[0].k == 0) x = Slot{1, s.p[0].v, 0};
                else x = Slot{};       // 頁に触るだけの書き込み（積み場の番地）。あとで上書きされる
                break;
            }
            case ETBC_MOVE_STACKPTR_TO_P1: case ETBC_MOVE_STACKPTR_TO_P2: case ETBC_MOVE_STACKPTR_TO_P3:
                s.p[n.op - ETBC_MOVE_STACKPTR_TO_P1] = PReg{1, (uint32_t)s.stk.size()};
                break;
            case ETBC_SET_P2_FROM_P1: s.p[1] = s.p[0]; break;
            case ETBC_SET_P3_FROM_P1: s.p[2] = s.p[0]; break;
            case ETBC_COPY_VALUE_AT_P1_TO_ADDR: storeCell(u64(0), loadVia(s.p[0])); break;
            case ETBC_SET_P1_FROM_WTP: case ETBC_SET_P2_FROM_WTP: case ETBC_SET_P3_FROM_WTP:
                s.p[n.op - ETBC_SET_P1_FROM_WTP] = PReg{0, ptrConst(s.wtp)};
                break;
            case ETBC_POP_FPSTACK_TO_PTR: storeCell(u64(0), fpPop(s)); break;
            case ETBC_POP_FPSTACK_TOSTACK: stkPush(s, Slot{1, fpPop(s), 0}); break;
            case ETBC_PUSH_VAL_AT_P1_TO_FPSTACK: case ETBC_PUSH_VAL_AT_P2_TO_FPSTACK: case ETBC_PUSH_VAL_AT_P3_TO_FPSTACK:
                fpPush(s, loadVia(s.p[n.op - ETBC_PUSH_VAL_AT_P1_TO_FPSTACK]));
                break;
            case ETBC_POP_FPSTACK_TO_WTP:
                storeCell(s.wtp, fpPop(s));
                s.wtp += 8;
                break;
            case ETBC_SET_P1_Z: s.p[0] = PReg{0, boolConst(false)}; break;
            case ETBC_SET_P1_NZ: s.p[0] = PReg{0, boolConst(true)}; break;
            case ETBC_LOOP_LOADCNT: {
                const uint32_t c = emit(Op::LoopCount, Ty::I32, {fpPop(s)});
                cond = emit(Op::ILt1, Ty::Bool, {c});
                other = s;                         // 続ける側（succ[1] = 次の命令）
                stkPush(other, Slot{1, c, 0});
                stkPush(other, Slot{2, 0, other.wtp});
                // s は飛ばす側（succ[0] = target）。積まない
                break;
            }
            case ETBC_LOOP_END: {
                const Slot w = stkPop(s);
                if (w.k != 2) fail(Fallback::TypeConfusion, "LOOP_END without a saved wtp");
                const Slot c = stkPop(s);
                const uint32_t cv = slotValue(c, Ty::I32);
                s.wtp = w.x;
                const uint32_t c2 = emit(Op::IDec, Ty::I32, {cv});
                cond = emit(Op::IGt0, Ty::Bool, {c2});
                other = s;                         // 抜ける側（succ[1]）: 2 段降ろした
                stkPush(s, Slot{1, c2, 0});        // 戻る側（succ[0]）: 数を減らして wtp はそのまま
                stkPush(s, w);
                break;
            }
            case ETBC_WHILE_SETUP: stkPush(s, Slot{1, i32Const(kLoopMax), 0}); break;
            case ETBC_WHILE_BEGIN: stkPush(s, Slot{2, 0, s.wtp}); break;
            case ETBC_WHILE_END: {
                const Slot w = stkPop(s);
                if (w.k != 2) fail(Fallback::TypeConfusion, "WHILE_END without a saved wtp");
                s.wtp = w.x;
                Slot &c = stkTop(s);
                const uint32_t c2 = emit(Op::IDec, Ty::I32, {slotValue(c, Ty::I32)});
                cond = emit(Op::IGt0, Ty::Bool, {c2});
                c.v = c2;                          // 続ける側（succ[0] = 次）
                other = s;
                stkPop(other);                     // 打ち切る側（succ[1] = endpt）
                break;
            }
            case ETBC_WHILE_CHECK_RV: {
                cond = asBool(s.p[0]);
                other = s;                         // 終わる側（succ[1] = 次）: 数を降ろす
                slotValue(stkTop(other), Ty::I32);
                stkPop(other);
                break;
            }
            case ETBC_BNOT: s.p[0] = PReg{0, emit(Op::BNot, Ty::Bool, {asBool(s.p[0])})}; break;
            case ETBC_EQUAL: case ETBC_EQUAL_EXACT: case ETBC_NOTEQUAL: case ETBC_NOTEQUAL_EXACT:
            case ETBC_ABOVE: case ETBC_BELOWEQ: {
                const uint32_t top = fpPop(s), top2 = fpPop(s);
                const Op op = n.op == ETBC_EQUAL ? Op::CmpEqClose : n.op == ETBC_EQUAL_EXACT ? Op::CmpEq
                            : n.op == ETBC_NOTEQUAL ? Op::CmpNeClose : n.op == ETBC_NOTEQUAL_EXACT ? Op::CmpNe
                            : n.op == ETBC_ABOVE ? Op::CmpLt : Op::CmpGe;
                s.p[0] = PReg{0, emit(op, Ty::Bool, {top, top2})};
                break;
            }
            case ETBC_ADD: case ETBC_SUB: case ETBC_MUL: case ETBC_DIV: {
                const uint32_t top = fpPop(s);
                uint32_t &top2 = fpTop(s);
                const Op op = n.op == ETBC_ADD ? Op::FAdd : n.op == ETBC_SUB ? Op::FSub : n.op == ETBC_MUL ? Op::FMul : Op::FDiv;
                // + * は portable が機械の 1 つめにした方を左に（NaN が 2 つのときのペイロード。portableNaNOrder）
                const PortableNaNOrder &no = portableNaNOrder();
                const bool topFirst = n.op == ETBC_ADD ? no.addTopFirst : n.op == ETBC_MUL ? no.mulTopFirst : false;
                top2 = topFirst ? emit(op, Ty::F64, {top, top2}) : emit(op, Ty::F64, {top2, top});
                break;
            }
            case ETBC_AND: case ETBC_OR: case ETBC_XOR: {
                const uint32_t top = fpPop(s);
                uint32_t &top2 = fpTop(s);
                const Op op = n.op == ETBC_AND ? Op::IAnd : n.op == ETBC_OR ? Op::IOr : Op::IXor;
                top2 = emit(op, Ty::F64, {top, top2});
                break;
            }
            case ETBC_OR0: { uint32_t &t = fpTop(s); t = emit(Op::IOr0, Ty::F64, {t}); break; }
            case ETBC_ADD_OP: case ETBC_SUB_OP: case ETBC_MUL_OP: case ETBC_DIV_OP:
            case ETBC_ADD_OP_FAST: case ETBC_SUB_OP_FAST: case ETBC_MUL_OP_FAST: case ETBC_DIV_OP_FAST: {
                const uint32_t v = fpPop(s);
                const uint32_t old = loadVia(s.p[1]);
                const int k = n.op;
                const Op op = (k == ETBC_ADD_OP || k == ETBC_ADD_OP_FAST) ? Op::FAdd
                            : (k == ETBC_SUB_OP || k == ETBC_SUB_OP_FAST) ? Op::FSub
                            : (k == ETBC_MUL_OP || k == ETBC_MUL_OP_FAST) ? Op::FMul : Op::FDiv;
                // + * は portable の _FAST が機械の 1 つめにした方を左に（フィルタの在る方は NaN が 0 になるので
                // どちらでもよいが、同じにしておく）
                const PortableNaNOrder &no = portableNaNOrder();
                const bool valueFirst = op == Op::FAdd ? no.addOpValueFirst : op == Op::FMul ? no.mulOpValueFirst : false;
                uint32_t r = valueFirst ? emit(op, Ty::F64, {v, old}) : emit(op, Ty::F64, {old, v});
                if (k == ETBC_ADD_OP || k == ETBC_SUB_OP || k == ETBC_MUL_OP || k == ETBC_DIV_OP)
                    r = emit(Op::Filter, Ty::F64, {r});
                storeVia(s.p[1], r);
                s.p[0] = s.p[1];
                break;
            }
            case ETBC_AND_OP: case ETBC_OR_OP: case ETBC_XOR_OP: {
                const uint32_t v = fpPop(s);
                const uint32_t old = loadVia(s.p[1]);
                const Op op = n.op == ETBC_AND_OP ? Op::IAnd : n.op == ETBC_OR_OP ? Op::IOr : Op::IXor;
                storeVia(s.p[1], emit(op, Ty::F64, {old, v}));
                s.p[0] = s.p[1];
                break;
            }
            case ETBC_UMINUS: { uint32_t &t = fpTop(s); t = emit(Op::FNeg, Ty::F64, {t}); break; }
            case ETBC_ASSIGN: {
                const uint32_t v = emit(Op::Filter, Ty::F64, {loadVia(s.p[0])});
                storeVia(s.p[1], v);
                s.p[0] = s.p[1];
                break;
            }
            case ETBC_ASSIGN_FAST: storeVia(s.p[1], loadVia(s.p[0])); s.p[0] = s.p[1]; break;
            case ETBC_ASSIGN_FAST_FROMFP: storeVia(s.p[1], fpPop(s)); s.p[0] = s.p[1]; break;
            case ETBC_ASSIGN_FROMFP:
                storeVia(s.p[1], emit(Op::Filter, Ty::F64, {fpPop(s)}));
                s.p[0] = s.p[1];
                break;
            case ETBC_MOD: {
                const uint32_t a = fpPop(s);
                uint32_t &t = fpTop(s);
                t = emit(Op::IMod, Ty::F64, {t, a});
                break;
            }
            case ETBC_MOD_OP: {
                const uint32_t a = fpPop(s);
                const uint32_t old = loadVia(s.p[1]);
                storeVia(s.p[1], emit(Op::IMod, Ty::F64, {old, a}));
                s.p[0] = s.p[1];
                break;
            }
            case ETBC_SHR: case ETBC_SHL: {
                const uint32_t top = fpPop(s);
                uint32_t &top2 = fpTop(s);
                top2 = emit(n.op == ETBC_SHR ? Op::IShr : Op::IShl, Ty::F64, {top2, top});
                break;
            }
            case ETBC_SQR: { uint32_t &t = fpTop(s); t = emit(Op::FSqr, Ty::F64, {t}); break; }
            case ETBC_MIN: case ETBC_MAX: {
                const uint32_t a = asPtr(s.p[0]), c = asPtr(s.p[1]);
                s.p[0] = PReg{0, emit(n.op == ETBC_MIN ? Op::PtrMin : Op::PtrMax, Ty::Ptr, {a, c})};
                break;
            }
            case ETBC_MIN_FP: case ETBC_MAX_FP: {
                const uint32_t a = fpPop(s);
                uint32_t &t = fpTop(s);
                t = emit(n.op == ETBC_MIN_FP ? Op::FMin2 : Op::FMax2, Ty::F64, {t, a});
                break;
            }
            case ETBC_ABS: { uint32_t &t = fpTop(s); t = emit(Op::FAbs, Ty::F64, {t}); break; }
            case ETBC_SIGN: { uint32_t &t = fpTop(s); t = emit(Op::FSign, Ty::F64, {t}); break; }
            case ETBC_INVSQRT: { uint32_t &t = fpTop(s); t = emit(Op::InvSqrt, Ty::F64, {t}); break; }
            case ETBC_FXCH: {
                if (s.fp.size() < 2) fail(Fallback::FpUnderflow, "FXCH with < 2 values");
                std::swap(s.fp[s.fp.size() - 1], s.fp[s.fp.size() - 2]);
                break;
            }
            case ETBC_POP_FPSTACK: fpPop(s); break;
            case ETBC_FCALL: stkPush(s, Slot{3, 0, n.next}); break;
            case ETBC_BOOLTOFP: fpPush(s, emit(Op::BoolToF, Ty::F64, {asBool(s.p[0])})); break;
            case ETBC_FPTOBOOL: s.p[0] = PReg{0, emit(Op::Truthy, Ty::Bool, {fpPop(s)})}; break;
            case ETBC_FPTOBOOL_REV: s.p[0] = PReg{0, emit(Op::Falsy, Ty::Bool, {fpPop(s)})}; break;
            case ETBC_CFUNC_1PDD: { uint32_t &t = fpTop(s); t = emit(Op::CallF1, Ty::F64, {t}, u64(0)); break; }
            case ETBC_CFUNC_2PDD: {
                const uint32_t top = fpPop(s);
                uint32_t &top2 = fpTop(s);
                top2 = emit(Op::CallF2, Ty::F64, {top2, top}, u64(0));
                break;
            }
            case ETBC_CFUNC_2PDDS: {
                const uint32_t v = fpPop(s);
                const uint32_t old = loadVia(s.p[1]);
                storeVia(s.p[1], emit(Op::CallF2, Ty::F64, {old, v}, u64(0)));
                s.p[0] = s.p[1];
                break;
            }
            case ETBC_MEGABUF: s.p[0] = PReg{0, emit(Op::MemAddr, Ty::Ptr, {fpPop(s)}, in_.ramPtr)}; break;
            case ETBC_GMEGABUF: s.p[0] = PReg{0, emit(Op::GMemAddr, Ty::Ptr, {fpPop(s)}, u64(0))}; break;
            case ETBC_GENERIC1PARM:
                s.p[0] = PReg{0, emit(Op::CallG, Ty::Ptr, {asPtr(s.p[0])}, u64(1), u64(0))};
                break;
            case ETBC_GENERIC2PARM: {
                const uint32_t a = asPtr(s.p[1]), c = asPtr(s.p[0]);
                s.p[0] = PReg{0, emit(Op::CallG, Ty::Ptr, {a, c}, u64(1), u64(0))};
                break;
            }
            case ETBC_GENERIC3PARM: {
                const uint32_t a = asPtr(s.p[2]), c = asPtr(s.p[1]), d = asPtr(s.p[0]);
                s.p[0] = PReg{0, emit(Op::CallG, Ty::Ptr, {a, c, d}, u64(1), u64(0))};
                break;
            }
            case ETBC_GENERIC1PARM_RETD: fpPush(s, emit(Op::CallGD, Ty::F64, {asPtr(s.p[0])}, u64(1), u64(0))); break;
            case ETBC_GENERIC2PARM_RETD:
                if (s.p[0].k == 1) {
                    std::vector<uint32_t> args = varparmArgs(s);
                    const uint64_t count = args.size();
                    fpPush(s, emit(Op::CallVarparm, Ty::F64, std::move(args), u64(1), u64(0), count));
                } else {
                    const uint32_t a = asPtr(s.p[1]), c = asPtr(s.p[0]);
                    fpPush(s, emit(Op::CallGD, Ty::F64, {a, c}, u64(1), u64(0)));
                }
                break;
            case ETBC_GENERIC2XPARM_RETD:
                if (s.p[0].k == 1) {
                    std::vector<uint32_t> args = varparmArgs(s);
                    const uint64_t count = args.size();
                    fpPush(s, emit(Op::CallVarparmX, Ty::F64, std::move(args), u64(2), u64(0), u64(1), count));
                } else {
                    const uint32_t a = asPtr(s.p[1]), c = asPtr(s.p[0]);
                    fpPush(s, emit(Op::CallGXD, Ty::F64, {a, c}, u64(2), u64(0), u64(1)));
                }
                break;
            case ETBC_GENERIC3PARM_RETD: {
                const uint32_t a = asPtr(s.p[2]), c = asPtr(s.p[1]), d = asPtr(s.p[0]);
                fpPush(s, emit(Op::CallGD, Ty::F64, {a, c, d}, u64(1), u64(0)));
                break;
            }
            case ETBC_USERSTACK_PUSH: emit(Op::UStackPush, Ty::Void, {asPtr(s.p[0])}, u64(0), u64(1), u64(2)); break;
            case ETBC_USERSTACK_POP: emit(Op::UStackPop, Ty::Void, {asPtr(s.p[0])}, u64(0), u64(1), u64(2)); break;
            case ETBC_USERSTACK_POPFAST:
                s.p[0] = PReg{0, emit(Op::UStackPopFast, Ty::Ptr, {}, u64(0), u64(1), u64(2))};
                break;
            case ETBC_USERSTACK_PEEK:
                s.p[0] = PReg{0, emit(Op::UStackPeek, Ty::Ptr, {fpPop(s)}, u64(0), u64(1), u64(2))};
                break;
            case ETBC_USERSTACK_PEEK_INT:
                s.p[0] = PReg{0, emit(Op::UStackPeekInt, Ty::Ptr, {}, u64(0), u64(1), u64(2), u64(3))};
                break;
            case ETBC_USERSTACK_PEEK_TOP: s.p[0] = PReg{0, emit(Op::UStackPeekTop, Ty::Ptr, {}, u64(0))}; break;
            case ETBC_USERSTACK_EXCH: emit(Op::UStackExch, Ty::Void, {asPtr(s.p[0])}, u64(0)); break;
            default:
                fail(Fallback::UnknownOpcode, std::string("opcode ") + etbc_name(n.op) + " not lifted");
            }
            if (!last && n.nsucc != 1) fail(Fallback::ShapeMismatch, "branch inside a block");
        }
        const Node &lastNode = nodes_[b.nodes.back()];
        if (lastNode.nsucc == 0) {
            irb.term = Term::Ret;
        } else if (lastNode.nsucc == 1) {
            irb.term = Term::Br;
            irb.succ[0] = blocks_[b.succ[0]].ir;
            b.out[0] = std::move(s);
        } else {
            if (cond == kNoValue) fail(Fallback::ShapeMismatch, "conditional without a condition");
            irb.term = Term::CondBr;
            irb.cond = cond;
            irb.succ[0] = blocks_[b.succ[0]].ir;
            irb.succ[1] = blocks_[b.succ[1]].ir;
            // 辺 0・1 の状態。JMP_IF_* は両方同じ。LOOP_LOADCNT・WHILE_* は other が片方。
            switch (lastNode.op) {
            case ETBC_LOOP_LOADCNT: b.out[0] = std::move(s); b.out[1] = std::move(other); break;   // 飛ばす / 回す
            case ETBC_LOOP_END: b.out[0] = std::move(s); b.out[1] = std::move(other); break;       // 戻る / 抜ける
            case ETBC_WHILE_END: b.out[0] = std::move(s); b.out[1] = std::move(other); break;      // 続ける / 打ち切る
            case ETBC_WHILE_CHECK_RV: b.out[0] = std::move(s); b.out[1] = std::move(other); break; // 戻る / 終わる
            default: b.out[0] = s; b.out[1] = std::move(s); break;
            }
        }
    }

    /// varparm: p1 = 積み場の番地（MOVE_STACKPTR_TO_P1）、p2 = 数（MOV_P2_DV）。引数は p1 から上へ 8 バイトずつ。
    std::vector<uint32_t> varparmArgs(State &s)
    {
        if (s.p[0].v != s.stk.size()) fail(Fallback::VarparmShape, "varparm array is not at the stack top");
        uint64_t count = 0;
        if (s.p[1].k != 0 || !fn_.constAddr(s.p[1].v, count)) fail(Fallback::VarparmShape, "varparm count not a constant");
        if (count > s.stk.size()) fail(Fallback::VarparmShape, "varparm count " + std::to_string(count) + " > stack");
        std::vector<uint32_t> args;
        args.reserve((size_t)count);
        for (uint64_t k = 0; k < count; ++k) {
            const Slot &x = s.stk[s.stk.size() - 1 - (size_t)k];
            const uint32_t v = slotValue(x, Ty::Ptr, Ty::Bool);
            args.push_back(tyOf(v) == Ty::Ptr ? v : emit(Op::BoolToPtr, Ty::Ptr, {v}));
        }
        return args;
    }

    // ---- 片付け --------------------------------------------------------------------------------------
    void cleanup()
    {
        const size_t nv = fn_.values.size();
        std::vector<uint32_t> repl(nv);
        for (uint32_t v = 0; v < nv; ++v) repl[v] = v;
        auto find = [&](uint32_t v) {
            while (repl[v] != v) { repl[v] = repl[repl[v]]; v = repl[v]; }
            return v;
        };
        std::vector<uint8_t> deadPhi(nv, 0);
        for (bool changed = true; changed;) {
            changed = false;
            for (Block &b : fn_.blocks)
                for (Ins &phi : b.phis) {
                    if (deadPhi[phi.res]) continue;
                    uint32_t same = kNoValue;
                    bool trivial = true;
                    for (uint32_t a : phi.args) {
                        const uint32_t f = find(a);
                        if (f == phi.res || f == same) continue;
                        if (same != kNoValue) { trivial = false; break; }
                        same = f;
                    }
                    if (trivial && same != kNoValue) {
                        repl[phi.res] = same;
                        deadPhi[phi.res] = 1;
                        changed = true;
                    }
                }
        }
        // 使われている値
        std::vector<uint32_t> uses(nv, 0);
        auto useArgs = [&](Ins &in) { for (uint32_t &a : in.args) { a = find(a); ++uses[a]; } };
        for (Block &b : fn_.blocks) {
            for (Ins &phi : b.phis) if (!deadPhi[phi.res]) useArgs(phi);
            for (Ins &in : b.ins) useArgs(in);
            if (b.term == Term::CondBr) { b.cond = find(b.cond); ++uses[b.cond]; }
        }
        // 番号を詰める（consts → 各ブロックの phi・命令）
        std::vector<uint32_t> renum(nv, kNoValue);
        std::vector<ValueInfo> values;
        auto take = [&](Ins &in) {
            if (in.res == kNoValue) return;
            renum[in.res] = (uint32_t)values.size();
            values.push_back(ValueInfo{in.ty});
            in.res = renum[in.res];
        };
        std::vector<Ins> consts;
        for (Ins &c : fn_.consts) if (uses[c.res]) { take(c); consts.push_back(c); }
        fn_.consts = std::move(consts);
        for (Block &b : fn_.blocks) {
            std::vector<Ins> phis;
            for (Ins &phi : b.phis) if (!deadPhi[phi.res]) { take(phi); phis.push_back(std::move(phi)); }
            b.phis = std::move(phis);
            for (Ins &in : b.ins) take(in);
        }
        for (Block &b : fn_.blocks) {
            for (Ins &phi : b.phis) for (uint32_t &a : phi.args) a = renum[a];
            for (Ins &in : b.ins) for (uint32_t &a : in.args) a = renum[a];
            if (b.term == Term::CondBr) b.cond = renum[b.cond];
        }
        fn_.values = std::move(values);
        for (Block &b : fn_.blocks)
            for (Ins &phi : b.phis)
                for (uint32_t a : phi.args)
                    if (a == kNoValue) throw LiftError{Fallback::VerifyFailed, "phi operand missing", base_ + b.pc};
    }
};

} // namespace

namespace {
#if defined(EEL_TARGET_PORTABLE)
/// 1 = 後の方（top・降ろした値）が残った、0 = 先の方、-1 = どちらでもない
int probeNaNPair(int op, bool opAssign)
{
    const uint64_t first = 0x7ff8000000000001ull, second = 0xfff800000000beefull;
    double x, y, o = 0;
    std::memcpy(&x, &first, 8);
    std::memcpy(&y, &second, 8);
    std::vector<unsigned char> code;
    auto put = [&](const void *p, size_t n) { code.insert(code.end(), (const unsigned char *)p, (const unsigned char *)p + n); };
    auto opc = [&](int v) { put(&v, 4); };
    auto ptr = [&](const void *p) { const uint64_t v = (uint64_t)(uintptr_t)p; put(&v, 8); };
    if (opAssign) {
        // 升 x に += / *= y（_FAST）。結果は x に
        opc(ETBC_MOV_P2_DV); ptr(&x); opc(ETBC_MOV_FPTOP_DV); ptr(&y); opc(op);
    } else {
        // x を積み、y を積み（top）、1 つにして o へ
        opc(ETBC_MOV_FPTOP_DV); ptr(&x); opc(ETBC_MOV_FPTOP_DV); ptr(&y); opc(op); opc(ETBC_POP_FPSTACK_TO_PTR); ptr(&o);
    }
    opc(ETBC_RET);
    static EEL_F *blocks[NSEEL_RAM_BLOCKS];
    EEL_F wt[64 + 48] = {};
    codeHandleType h;
    std::memset(&h, 0, sizeof h);
    h.code = code.data();
    h.workTable = wt;
    h.ramPtr = blocks;
    NSEEL_code_execute(&h);
    uint64_t r;
    std::memcpy(&r, opAssign ? (const void *)&x : (const void *)&o, 8);
    // 静かにしたもの（どちらも静かな NaN なので同じ）と比べる
    return r == second ? 1 : r == first ? 0 : -1;
}
#endif
} // namespace

const PortableNaNOrder &portableNaNOrder()
{
    static const PortableNaNOrder order = [] {
        PortableNaNOrder o;
#if defined(EEL_TARGET_PORTABLE)
        struct { const char *name; int op; bool opAssign; bool *out; } probes[] = {
            {"ADD", ETBC_ADD, false, &o.addTopFirst}, {"MUL", ETBC_MUL, false, &o.mulTopFirst},
            {"ADD_OP_FAST", ETBC_ADD_OP_FAST, true, &o.addOpValueFirst},
            {"MUL_OP_FAST", ETBC_MUL_OP_FAST, true, &o.mulOpValueFirst},
        };
        for (const auto &p : probes) {
            const int r = probeNaNPair(p.op, p.opAssign);
            *p.out = r == 1;
            if (r < 0) o.note += std::string(o.note.empty() ? "" : ", ") + p.name + ": neither NaN";
        }
        o.probed = true;
#endif
        return o;
    }();
    return order;
}

LiftResult lift(const LiftInput &in, const LiftOptions &opt)
{
    Lifter l(in, opt);
    return l.run();
}

} // namespace etvm
