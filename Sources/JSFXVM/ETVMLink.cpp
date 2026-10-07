// ETVMLink.cpp — VM 全体のつなぎ（升の分類）、NSEEL_EXEC_REG の実行系（段 S2 の threaded code・段 S1 の参照の解釈）、数え。
#include "ETVMLink.h"

#include "ETVM.h"
#include "ETVMExec.h"
#include "ETVMOps.h"
#include "WDL/eel2/ns-eel.h"
#include "ysfx.h"

#include <atomic>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <set>

namespace etvm {

const char *cellClassName(CellClass c)
{
    switch (c) {
    case CellClass::Var: return "var";
    case CellClass::Const: return "const";
    case CellClass::Static: return "static";
    case CellClass::Temp: return "temp";
    case CellClass::Volatile: return "volatile";
    }
    return "?";
}

namespace {
struct Range { uint64_t lo, hi; };

void addBlocks(const llBlock *b, std::vector<Range> &out)
{
    for (; b; b = b->next) {
        const uint64_t lo = (uint64_t)(uintptr_t)(b + 1);
        out.push_back({lo, lo + (uint64_t)b->sizeused});
    }
}

bool inRanges(const std::vector<Range> &rs, uint64_t a)
{
    for (const Range &r : rs) if (a >= r.lo && a + 8 <= r.hi) return true;
    return false;
}

int collectVar(const char *name, EEL_F *val, void *ctx)
{
    auto *m = static_cast<std::map<uint64_t, std::string> *>(ctx);
    m->emplace((uint64_t)(uintptr_t)val, name);
    return 1;
}

uint64_t tempEnd(const codeHandleType *h)
{
    // 作業表は (workTable_size + MIN_COMPUTABLE_SIZE 32 + COMPUTABLE_EXTRA_SPACE 16) 個（nseel-compiler.c）
    return (uint64_t)(uintptr_t)h->workTable + (uint64_t)(h->workTable_size + 32 + 16) * sizeof(EEL_F);
}

/// ポインタの値が指しうる升（番地）と、RAM・出所の分からないもの。
struct PointsTo {
    std::set<uint64_t> cells;
    bool unknown = false;
    bool operator==(const PointsTo &o) const { return cells == o.cells && unknown == o.unknown; }
};

struct Analyser {
    LinkReport &rep;
    CellInfo &cell(uint64_t a)
    {
        auto it = rep.cells.find(a);
        if (it == rep.cells.end()) {
            it = rep.cells.emplace(a, CellInfo{}).first;
            rep.cellOrder.push_back(a);
        }
        return it->second;
    }

    void run(const Function &fn)
    {
        std::vector<PointsTo> pts(fn.values.size());
        for (const Ins &c : fn.consts)
            if (c.op == Op::PtrConst && c.imm[0]) { pts[c.res].cells.insert(c.imm[0]); cell(c.imm[0]); }
        auto ptrResult = [&](const Ins &in) {
            PointsTo p;
            switch (in.op) {
            case Op::Phi: case Op::PtrMin: case Op::PtrMax:
                for (uint32_t a : in.args) { p.cells.insert(pts[a].cells.begin(), pts[a].cells.end()); p.unknown |= pts[a].unknown; }
                break;
            case Op::MemAddr: case Op::GMemAddr: case Op::BoolToPtr:
                break; // RAM・gmem・1/0 は VM の升に重ならない
            default:
                p.unknown = true; // API・ユーザーの積み場の返すポインタ
                break;
            }
            return p;
        };
        for (bool changed = true; changed;) {
            changed = false;
            for (const Block &b : fn.blocks) {
                for (const Ins &in : b.phis) {
                    PointsTo p = ptrResult(in);
                    if (!(p == pts[in.res])) { pts[in.res] = std::move(p); changed = true; }
                }
                for (const Ins &in : b.ins) {
                    if (in.ty != Ty::Ptr) continue;
                    PointsTo p = ptrResult(in);
                    if (!(p == pts[in.res])) { pts[in.res] = std::move(p); changed = true; }
                }
            }
        }
        for (const Block &b : fn.blocks)
            for (const Ins &in : b.ins) {
                switch (in.op) {
                case Op::LoadCell: cell(in.imm[0]).loaded = true; break;
                case Op::StoreCell: cell(in.imm[0]).storedDirect = true; break;
                case Op::Load: case Op::UStackPush:
                    for (uint64_t c : pts[in.args[0]].cells) cell(c).loaded = true;
                    break;
                case Op::PtrMin: case Op::PtrMax:
                    for (uint32_t a : in.args) for (uint64_t c : pts[a].cells) cell(c).loaded = true;
                    break;
                case Op::Store: case Op::UStackPop: case Op::UStackExch:
                    for (uint64_t c : pts[in.args[0]].cells) cell(c).storedIndirect = true;
                    if (pts[in.args[0]].unknown) ++rep.unknownStores;
                    break;
                case Op::CallG: case Op::CallGD: case Op::CallGXD: case Op::CallVarparm: case Op::CallVarparmX:
                    for (uint32_t a : in.args) for (uint64_t c : pts[a].cells) cell(c).escaped = true;
                    break;
                default: break;
                }
            }
    }
};
} // namespace

LinkReport link(void *vm, void *const *handles, const int *sections, uint32_t count, const LiftOptions &opt)
{
    LinkReport rep;
    std::map<uint64_t, std::string> vars;
    std::vector<Range> statics, temps;
    if (vm) {
        NSEEL_VM_enumallvars((NSEEL_VMCTX)vm, collectVar, &vars);
        addBlocks(((compileContext *)vm)->ctx_pblocks, statics);
    }
    int initIndex = 0;
    for (uint32_t i = 0; i < count; ++i) {
        HandleReport hr;
        hr.section = sections[i];
        hr.index = sections[i] == 1 ? initIndex++ : 0;
        const codeHandleType *h = (const codeHandleType *)handles[i];
        if (h) {
            addBlocks(h->blocks_data, statics);
            if (h->workTable) temps.push_back({(uint64_t)(uintptr_t)h->workTable, tempEnd(h)});
        }
        LiftInput in;
        if (h && liftInputFromHandle(handles[i], in)) {
            hr.present = true;
            hr.lift = lift(in, opt);
            if (!hr.lift.ok()) rep.allAnalysed = false;
        }
        rep.handles.push_back(std::move(hr));
    }
    Analyser an{rep};
    for (const HandleReport &hr : rep.handles)
        if (hr.present && hr.lift.ok()) an.run(hr.lift.fn);
    for (auto &[addr, c] : rep.cells) {
        auto v = vars.find(addr);
        if (v != vars.end()) { c.cls = CellClass::Var; c.name = v->second; }
        else if (inRanges(temps, addr)) c.cls = CellClass::Temp;
        else if (inRanges(statics, addr))
            c.cls = (rep.allAnalysed && !c.storedDirect && !c.storedIndirect && !c.escaped) ? CellClass::Const : CellClass::Static;
        else c.cls = CellClass::Volatile;
    }
    return rep;
}

std::string describeCell(const LinkReport &rep, uint64_t addr)
{
    auto it = rep.cells.find(addr);
    if (it == rep.cells.end()) return std::string();
    const CellInfo &c = it->second;
    char buf[96];
    switch (c.cls) {
    case CellClass::Var: return c.name;
    case CellClass::Const: {
        double v;
        std::memcpy(&v, (const void *)(uintptr_t)addr, 8);
        std::snprintf(buf, sizeof buf, "const(%.17g)", v);
        return buf;
    }
    case CellClass::Static: return c.escaped ? "static!esc" : "static";
    case CellClass::Temp: return c.escaped ? "temp!esc" : "temp";
    case CellClass::Volatile: return "volatile";
    }
    return std::string();
}

uint64_t stateHash(void *vm, void *const *handles, const int *sections, uint32_t count)
{
    const LinkReport rep = link(vm, handles, sections, count);
    uint64_t h = 1469598103934665603ull;
    auto mix = [&](uint64_t x) {
        for (int i = 0; i < 8; ++i) { h ^= (x >> (8 * i)) & 0xff; h *= 1099511628211ull; }
    };
    for (uint64_t a : rep.cellOrder) {
        const CellInfo &c = rep.cells.at(a);
        if (c.cls != CellClass::Static && c.cls != CellClass::Const) continue;
        uint64_t bits;
        std::memcpy(&bits, (const void *)(uintptr_t)a, 8);
        mix(bits);
    }
    for (uint32_t i = 0; i < count; ++i) {
        const codeHandleType *hd = (const codeHandleType *)handles[i];
        mix(hd && hd->want_stack && hd->stack
                ? ((uint64_t)(uintptr_t)hd->stack & (uint64_t)(NSEEL_STACK_SIZE * sizeof(EEL_F) - 1))
                : ~0ull);
    }
    mix(rep.cellOrder.size());
    return h;
}

// ---- NSEEL_EXEC_REG の実行系 ------------------------------------------------------------------------------
// 既定は段 S2 の threaded code（ETVMSelect.cpp・ETVMHandlers.cpp）。ETVM_SetEngine(ETVM_ENGINE_REFERENCE) で
// 段 S1 の参照の解釈（照合のため。遅い）。作るときに選び、プログラムが自分の種類を持つ。
namespace {
struct Program {
    int engine = ETVM_ENGINE_THREADED;
    Function fn;               // 参照の解釈のとき
    InterpState st;
    ThreadedProgram *threaded = nullptr;
    ~Program() { if (threaded) freeThreaded(threaded); }
};

void runProgram(void *prog, unsigned int nframes, NSEEL_FRAME_CALLBACK pre, NSEEL_FRAME_CALLBACK post, void *ctx)
{
    Program *p = (Program *)prog;
    if (p->threaded) {
        runThreaded(p->threaded, nframes, pre, post, ctx);
        return;
    }
    for (unsigned int i = 0; i < nframes; ++i) {
        if (pre) pre(ctx, i);
        interpret(p->fn, p->st);
        if (post) post(ctx, i);
    }
}

void freeProgram(void *prog) { delete (Program *)prog; }

const NSEEL_exec_backend kBackend = {runProgram, freeProgram};
std::atomic<uint32_t> gMask{ETVM_SECTIONS_DEFAULT};
std::atomic<int> gEngine{ETVM_ENGINE_THREADED};
std::mutex gCoverageMutex;
Coverage gCoverage;

void buildPrograms(void *vm, void *const *handles, const int *sections, uint32_t count)
{
    LinkReport rep = link(vm, handles, sections, count);
    const uint32_t mask = gMask.load(std::memory_order_relaxed);
    const int engine = gEngine.load(std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(gCoverageMutex);
    for (uint32_t i = 0; i < count; ++i) {
        if (!handles[i]) continue;
        HandleReport &hr = rep.handles[i];
        const int sec = sections[i] >= 0 && sections[i] < 8 ? sections[i] : 0;
        if (hr.present) {
            ++gCoverage.handles[sec];
            if (hr.lift.ok()) ++gCoverage.lifted[sec];
            else ++gCoverage.reasons[sec][(size_t)hr.lift.reason];
        }
        Program *p = nullptr;
        if (hr.present && hr.lift.ok() && (mask & (1u << sec))) {
            p = new Program;
            p->engine = engine;
            if (engine == ETVM_ENGINE_REFERENCE) {
                p->fn = std::move(hr.lift.fn);
                p->st.vals.resize(p->fn.values.size());
            } else {
                std::string why;
                ThreadedStats ts;
                p->threaded = buildThreaded(hr.lift.fn, why, &ts);
                if (!p->threaded) {
                    // 並べられない（知らない命令）。プログラムを付けない＝ vm-goto-fpreg で回る。
                    ++gCoverage.buildFailed[sec];
                    if (gCoverage.firstBuildError.empty()) gCoverage.firstBuildError = why;
                    delete p;
                    p = nullptr;
                } else {
                    gCoverage.irInstructions[sec] += ts.irInstructions;
                    gCoverage.threadedHandlers[sec] += ts.handlers;
                }
            }
        }
        NSEEL_code_attach_program(handles[i], p);
        if (p) ++gCoverage.attached[sec];
    }
}
} // namespace

Coverage coverage()
{
    std::lock_guard<std::mutex> lock(gCoverageMutex);
    return gCoverage;
}

void resetCoverage()
{
    std::lock_guard<std::mutex> lock(gCoverageMutex);
    gCoverage = Coverage();
}

} // namespace etvm

extern "C" void ETVM_Install(void)
{
    NSEEL_set_exec_backend(&etvm::kBackend);
    ysfx_set_eel_program_builder(etvm::buildPrograms);
}

extern "C" void ETVM_SetSectionMask(uint32_t mask) { etvm::gMask.store(mask, std::memory_order_relaxed); }
extern "C" uint32_t ETVM_GetSectionMask(void) { return etvm::gMask.load(std::memory_order_relaxed); }
extern "C" void ETVM_SetEngine(int engine)
{
    etvm::gEngine.store(engine == ETVM_ENGINE_REFERENCE ? ETVM_ENGINE_REFERENCE : ETVM_ENGINE_THREADED,
                        std::memory_order_relaxed);
}
extern "C" int ETVM_GetEngine(void) { return etvm::gEngine.load(std::memory_order_relaxed); }
