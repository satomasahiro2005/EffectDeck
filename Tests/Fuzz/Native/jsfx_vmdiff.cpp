// jsfx_vmdiff.cpp（Tests/Fuzz/Native）
// 的 jsfxvmdiff: レジスタ型 VM（NSEEL_EXEC_REG = Sources/JSFXVM の threaded code）と portable を、同じ JSFX で
// 1 歩ずつ並べて回し、1 ビットまで比べる（docs/jsfx-regvm-design.md §12.7）。
//
// 同じソースから effect を 2 つ作る: A は portable（GLUE_CALL_CODE そのもの）、B は vm-reg。ysfx をじかに使う
// （ETJSFX は出力の NaN を拭き、締切を時刻で測って外すので、照合には使えない）。歩みは
//   @init（ysfx_init）・ブロック（つまみ・trigger・再生位置・MIDI を入れて ysfx_process_double。中で @slider・
//   @block・@sample）・状態の保存（@serialize の書き）・状態の読み込み（@serialize の読み。値を崩したものも）
// の並び。歩みごとに
//   1. プロセスで共有される状態 G を写す: rand の列（下の注）、nseel_ramalloc_onfail、_global.* の全部、
//      gmem（ソースに "gmem" の字があるときだけ。名前付きなら VM の gram の塊、無名なら既定の 1M 語）
//   2. A の歩み → G_A を写す → G を戻す → B の歩み → G_B を写す
//   3. 比べる: G_A と G_B、出力（double の bit）、出てきた MIDI、つまみの変化・自動化・見える印、変数の全部
//      （ysfx_enum_vars）、EEL のメモリ（確保した塊の有無と中身）、ysfx の口から見えない升（定数・関数の局所・
//      #字。etvm::link の順）、各 handle のユーザーの積み場の位置、@serialize のバイト
//   4. 続きは G_A から（一致していれば G_B と同じ）
// rand: 設計は MT の状態を写す口（パッチに nseel_rand_state_save/restore）を足すとしたが、歩みごとに
// NSEEL_rand_reset で A と B の両方を同じ最初の状態から始める（パッチの版を増やさない。照合としては同じ）。
//
// 断る理由（Fallback）の無い handle が threaded code にならないのも落ち（中間表現の命令に知らないものが出た）。
// 回ごとに違う値を読みうるソース（time・time_precise の字があるもの）は比べない。時間切れは run.sh が -fork で
// 落ちと数えない（入れ子の loop は長い）。
//
// 変異: libFuzzer の既定の変異に、EEL の式の文法から作った文を節へ差し込む変異を混ぜる（設計 §12.7 の
// 構造を知った変異）。演算子・入れ子の loop / while・op=・megabuf の端数・負・大きな添字・?: の左辺・
// min / max の左辺・関数（local・instance・名前空間）・varparm（mem_set_values など）・ユーザーの積み場・
// spl(n)・gmem・_global.* を混ぜる。
#include "ysfx.h"
#include "WDL/eel2/ns-eel.h"
#include "WDL/eel2/ns-eel-int.h"
#include "ETVM.h"
#include "ETVMLink.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <ratio>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>

extern "C" size_t LLVMFuzzerMutate(uint8_t *data, size_t size, size_t maxSize);

namespace {
constexpr uint32_t kMaxChannels = 8;
constexpr uint32_t kMaxFrames = 64;

[[noreturn]] void broken(const std::string &what)
{
    std::fprintf(stderr, "fuzz oracle: jsfxvmdiff: %s\n", what.c_str());
    std::abort();
}

struct Rng {
    uint64_t state;
    uint64_t next()
    {
        uint64_t z = (state += 0x9E3779B97F4A7C15ull);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
    uint32_t below(uint32_t n) { return n ? (uint32_t)(next() % n) : 0; }
    bool oneIn(uint32_t n) { return below(n) == 0; }
    double unit() { return (double)(next() >> 11) * 0x1.0p-53; }
};

uint64_t fnv1a(const uint8_t *data, size_t size)
{
    uint64_t h = 0xCBF29CE484222325ull;
    for (size_t i = 0; i < size; ++i) { h ^= data[i]; h *= 0x100000001B3ull; }
    return h;
}
uint64_t bitsOf(double v) { uint64_t b; std::memcpy(&b, &v, 8); return b; }

const std::string &sourcePath()
{
    static const std::string path = [] {
        const char *dir = std::getenv("TMPDIR");
        return std::string(dir && *dir ? dir : "/tmp") + "/effectdeck-jsfxvmdiff-" + std::to_string((long)getpid()) +
               ".jsfx";
    }();
    return path;
}
void removeSource() { std::remove(sourcePath().c_str()); }

// ---- プロセスで共有される状態 G -------------------------------------------------------------------------
struct Global {
    uint64_t onfail = 0;
    std::vector<std::pair<EEL_F *, uint64_t>> globals;
    bool gmem = false;
    std::vector<double> gmemDefault;                      // 空なら確保されていなかった
    void **gram = nullptr;                                // 名前付き gmem（VM の gram_blocks）
    std::vector<std::pair<int, std::vector<double>>> gramBlocks;
};

Global capture(bool gmem, void **gram)
{
    Global g;
    g.onfail = bitsOf(nseel_ramalloc_onfail);
    for (nseel_globalVarItem *p = nseel_globalreg_list; p; p = p->_next) g.globals.push_back({&p->data, bitsOf(p->data)});
    g.gmem = gmem;
    g.gram = gram;
    if (gmem) {
        if (EEL_F *d = nseel_gmembuf_default) g.gmemDefault.assign(d, d + NSEEL_SHARED_GRAM_SIZE);
        if (gram && *gram) {
            EEL_F **blocks = (EEL_F **)*gram;
            for (int i = 0; i < NSEEL_RAM_BLOCKS; ++i)
                if (blocks[i]) g.gramBlocks.push_back({i, std::vector<double>(blocks[i], blocks[i] + NSEEL_RAM_ITEMSPERBLOCK)});
        }
    }
    return g;
}

void restore(const Global &g)
{
    std::memcpy(&nseel_ramalloc_onfail, &g.onfail, 8);
    for (nseel_globalVarItem *p = nseel_globalreg_list; p; p = p->_next) {
        uint64_t v = 0; // 写したあとに足された項目は作られたとき（0）に戻す
        for (const auto &[ptr, bits] : g.globals) if (ptr == &p->data) { v = bits; break; }
        std::memcpy(&p->data, &v, 8);
    }
    if (!g.gmem) return;
    if (EEL_F *d = nseel_gmembuf_default) {
        if (g.gmemDefault.empty()) std::memset(d, 0, sizeof(EEL_F) * NSEEL_SHARED_GRAM_SIZE);
        else std::memcpy(d, g.gmemDefault.data(), sizeof(EEL_F) * NSEEL_SHARED_GRAM_SIZE);
    }
    if (g.gram && *g.gram) {
        EEL_F **blocks = (EEL_F **)*g.gram;
        for (int i = 0; i < NSEEL_RAM_BLOCKS; ++i) {
            if (!blocks[i]) continue;
            const std::vector<double> *saved = nullptr;
            for (const auto &[k, v] : g.gramBlocks) if (k == i) { saved = &v; break; }
            if (saved) std::memcpy(blocks[i], saved->data(), sizeof(EEL_F) * NSEEL_RAM_ITEMSPERBLOCK);
            else std::memset(blocks[i], 0, sizeof(EEL_F) * NSEEL_RAM_ITEMSPERBLOCK); // 新しい塊は calloc（0）
        }
    }
}

std::string compareGlobal(const Global &a, const Global &b)
{
    if (a.onfail != b.onfail) return "nseel_ramalloc_onfail";
    if (a.globals.size() != b.globals.size()) return "_global count";
    for (size_t i = 0; i < a.globals.size(); ++i)
        if (a.globals[i] != b.globals[i]) return "_global value #" + std::to_string(i);
    if (a.gmemDefault != b.gmemDefault) {
        if (a.gmemDefault.size() != b.gmemDefault.size()) return "gmem (default) allocation";
        for (size_t i = 0; i < a.gmemDefault.size(); ++i)
            if (bitsOf(a.gmemDefault[i]) != bitsOf(b.gmemDefault[i])) return "gmem[" + std::to_string(i) + "] (default)";
    }
    if (a.gramBlocks.size() != b.gramBlocks.size()) return "gmem block count";
    for (size_t i = 0; i < a.gramBlocks.size(); ++i) {
        if (a.gramBlocks[i].first != b.gramBlocks[i].first) return "gmem block index";
        if (std::memcmp(a.gramBlocks[i].second.data(), b.gramBlocks[i].second.data(),
                        sizeof(EEL_F) * NSEEL_RAM_ITEMSPERBLOCK) != 0)
            return "gmem block " + std::to_string(a.gramBlocks[i].first);
    }
    return std::string();
}

// ---- 1 つの effect -------------------------------------------------------------------------------------
struct Inst {
    ysfx_t *fx = nullptr;
    void *vm = nullptr;
    std::vector<void *> handles;
    std::vector<int> sections;
    std::vector<uint64_t> staticCells; // etvm::link の順（Static・Const）
    bool portableUB = false;           // portable 自身が決まらない読み書きをする handle がある（下の注）
    // 1 歩の観測
    std::vector<uint64_t> out;
    std::vector<uint8_t> midi;
    std::vector<uint64_t> sliders;
    std::vector<uint8_t> state;
    bool stateOk = false;
    ~Inst() { if (fx) ysfx_free(fx); }
};

bool create(Inst &in, int mode)
{
    ysfx_config_t *config = ysfx_config_new();
    in.fx = ysfx_new(config);
    ysfx_config_free(config);
    if (!ysfx_load_file(in.fx, sourcePath().c_str(), 0) || !ysfx_compile(in.fx, 0)) return false;
    if (!ysfx_set_eel_exec_mode(in.fx, mode)) broken("ysfx_set_eel_exec_mode failed for mode " + std::to_string(mode));
    const uint32_t n = ysfx_get_eel_handles(in.fx, &in.vm, nullptr, nullptr, 0);
    in.handles.resize(n);
    in.sections.resize(n);
    ysfx_get_eel_handles(in.fx, &in.vm, in.handles.data(), in.sections.data(), n);
    // ユーザーの積み場は newDataBlock（malloc、0 にしない）の NSEEL_STACK_SIZE 語。書く前に読む stack_exch・
    // stack_peek は portable どうしでも違う値を読むので、A と B の両方を 0 から始める（実行系の意味ではない）。
    for (void *h : in.handles) {
        const codeHandleType *hd = (const codeHandleType *)h;
        if (!hd || !hd->want_stack || !hd->stack) continue;
        const UINT_PTR size = (UINT_PTR)(NSEEL_STACK_SIZE * sizeof(EEL_F));
        std::memset((void *)((UINT_PTR)hd->stack & ~(size - 1)), 0, size);
    }
    const etvm::LinkReport rep = etvm::link(in.vm, in.handles.data(), in.sections.data(), n);
    for (uint64_t a : rep.cellOrder) {
        const etvm::CellInfo &c = rep.cells.at(a);
        if (c.cls == etvm::CellClass::Static || c.cls == etvm::CellClass::Const) in.staticCells.push_back(a);
    }
    // 持ち上げは成功するか理由を言う。理由のうち、portable 自身が決まらない読み書きをする形（書いていない
    // 積み場の段・p レジスタを読む、64 段・64 KiB を越える、番地 0・比べた結果を番地として読む、opcode 0）は
    // 比べない: portable は解釈の積み場の外を読み（ASan が GLUE_CALL_CODE で止まる）、vm-reg はその handle を
    // vm-goto-fpreg で回すが、積み場の並びが違うので同じ値を読む保証は無い（設計 §1 の非目標）。
    for (const etvm::HandleReport &hr : rep.handles) {
        if (!hr.present) continue;
        switch (hr.lift.reason) {
        case etvm::Fallback::Undefined: case etvm::Fallback::TypeConfusion: case etvm::Fallback::FpOverflow:
        case etvm::Fallback::FpUnderflow: case etvm::Fallback::StackOverflow: case etvm::Fallback::StackUnderflow:
        case etvm::Fallback::Opcode0: case etvm::Fallback::NullDeref: case etvm::Fallback::BoolDeref:
            in.portableUB = true;
            break;
        default:
            if ((size_t)hr.lift.reason >= (size_t)etvm::Fallback::Count) broken("lift: reason out of range");
            break;
        }
    }
    return true;
}

std::vector<std::pair<std::string, uint64_t>> vars(Inst &in)
{
    std::vector<std::pair<std::string, uint64_t>> v;
    ysfx_enum_vars(in.fx, [](const char *name, ysfx_real *var, void *user) -> int {
        static_cast<std::vector<std::pair<std::string, uint64_t>> *>(user)->push_back({name, bitsOf(*var)});
        return 1;
    }, &v);
    return v;
}

uint64_t ustackPos(const void *h)
{
    const codeHandleType *hd = (const codeHandleType *)h;
    return hd && hd->want_stack && hd->stack ? ((uint64_t)(uintptr_t)hd->stack & (uint64_t)(NSEEL_STACK_SIZE * sizeof(EEL_F) - 1))
                                              : ~0ull;
}

/// A と B の歩みのあとの状態を比べる（違えば理由）。
std::string compareInst(Inst &a, Inst &b)
{
    if (a.out != b.out) {
        size_t i = 0;
        while (i < a.out.size() && i < b.out.size() && a.out[i] == b.out[i]) ++i;
        return "output (first index " + std::to_string(i) + ")";
    }
    if (a.midi != b.midi) return "midi out";
    if (a.sliders != b.sliders) return "slider masks";
    if (a.stateOk != b.stateOk || a.state != b.state) return "@serialize bytes";
    const auto va = vars(a), vb = vars(b);
    if (va.size() != vb.size()) return "var count";
    for (size_t i = 0; i < va.size(); ++i)
        if (va[i] != vb[i]) return "var " + va[i].first;
    const auto *ra = ((compileContext *)a.vm)->ram_state, *rb = ((compileContext *)b.vm)->ram_state;
    for (int i = 0; i < NSEEL_RAM_BLOCKS; ++i) {
        if (!ra->blocks[i] != !rb->blocks[i]) return "ram block allocation " + std::to_string(i);
        if (ra->blocks[i] && std::memcmp(ra->blocks[i], rb->blocks[i], sizeof(EEL_F) * NSEEL_RAM_ITEMSPERBLOCK) != 0)
            return "ram block " + std::to_string(i);
    }
    if (a.staticCells.size() != b.staticCells.size()) return "static cell count";
    for (size_t i = 0; i < a.staticCells.size(); ++i)
        if (std::memcmp((const void *)(uintptr_t)a.staticCells[i], (const void *)(uintptr_t)b.staticCells[i], 8) != 0)
            return "static cell #" + std::to_string(i);
    if (a.handles.size() != b.handles.size()) return "handle count";
    for (size_t i = 0; i < a.handles.size(); ++i)
        if (ustackPos(a.handles[i]) != ustackPos(b.handles[i])) return "user stack position (handle " + std::to_string(i) + ")";
    return std::string();
}

struct Run {
    Inst a, b;
    bool gmem = false;
    void **gram() const { return (void **)((compileContext *)a.vm)->gram_blocks; }

    template <class F> void step(const std::string &what, F fn)
    {
        const Global g0 = capture(gmem, gram());
        for (Inst *in : {&a, &b}) { in->out.clear(); in->midi.clear(); in->sliders.clear(); in->state.clear(); in->stateOk = false; }
        // JSFXVMDIFF_TRACE=1: 歩みごとに A・B の時間を出す（時間切れの入力がどちらで遅いかを見る）
        static const bool trace = std::getenv("JSFXVMDIFF_TRACE") != nullptr;
        const auto t0 = std::chrono::steady_clock::now();
        if (trace) std::fprintf(stderr, "jsfxvmdiff: %s: portable...\n", what.c_str());
        NSEEL_rand_reset();
        fn(a);
        const Global ga = capture(gmem, gram());
        restore(g0);
        const auto t1 = std::chrono::steady_clock::now();
        if (trace) std::fprintf(stderr, "jsfxvmdiff: %s: vm-reg...\n", what.c_str());
        NSEEL_rand_reset();
        fn(b);
        const Global gb = capture(gmem, gram());
        if (trace)
            std::fprintf(stderr, "jsfxvmdiff: %s: portable %.1f ms, vm-reg %.1f ms\n", what.c_str(),
                         std::chrono::duration<double, std::milli>(t1 - t0).count(),
                         std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t1).count());
        std::string why = compareGlobal(ga, gb);
        if (why.empty()) why = compareInst(a, b);
        if (!why.empty()) broken(what + ": portable and vm-reg differ: " + why);
        // 続きは G_A から（ここでは G_B と同じ）
    }
};

struct BlockPlan {
    uint32_t frames = 1;
    std::vector<std::pair<uint32_t, double>> sliders;
    int trigger = -1;
    ysfx_time_info_t time{};
    std::vector<std::vector<uint8_t>> midi;
    std::vector<double> in;
};

double sampleValue(Rng &r)
{
    switch (r.below(20)) {
    case 0: return NAN;
    case 1: return INFINITY;
    case 2: return -INFINITY;
    case 3: return 1e-310;
    case 4: return -0.0;
    case 5: return 1e300;
    case 6: return -2147483649.0;
    default: return r.unit() * 2 - 1;
    }
}

void runBlock(Inst &in, const BlockPlan &p, uint32_t ins, uint32_t outs)
{
    for (const auto &[i, v] : p.sliders) ysfx_slider_set_value(in.fx, i, v, true);
    if (p.trigger >= 0) ysfx_send_trigger(in.fx, (uint32_t)p.trigger);
    ysfx_set_time_info(in.fx, &p.time);
    for (const auto &m : p.midi) {
        ysfx_midi_event_t ev{0, (uint32_t)(m[0] % p.frames), 3, m.data() + 1};
        ysfx_send_midi(in.fx, &ev);
    }
    double inBuf[kMaxChannels][kMaxFrames], outBuf[kMaxChannels][kMaxFrames];
    const double *inPtr[kMaxChannels];
    double *outPtr[kMaxChannels];
    for (uint32_t c = 0; c < kMaxChannels; ++c) {
        for (uint32_t i = 0; i < kMaxFrames; ++i) { inBuf[c][i] = p.in[c * kMaxFrames + i]; outBuf[c][i] = 0; }
        inPtr[c] = inBuf[c];
        outPtr[c] = outBuf[c];
    }
    ysfx_process_double(in.fx, inPtr, outPtr, ins, outs, p.frames);
    for (uint32_t c = 0; c < outs; ++c)
        for (uint32_t i = 0; i < p.frames; ++i) in.out.push_back(bitsOf(outBuf[c][i]));
    for (ysfx_midi_event_t ev; ysfx_receive_midi(in.fx, &ev);) {
        in.midi.push_back((uint8_t)ev.bus);
        in.midi.push_back((uint8_t)ev.offset);
        in.midi.insert(in.midi.end(), ev.data, ev.data + ev.size);
    }
    for (uint8_t g = 0; g < ysfx_max_slider_groups; ++g) {
        in.sliders.push_back(ysfx_fetch_slider_changes(in.fx, g));
        in.sliders.push_back(ysfx_fetch_slider_automations(in.fx, g));
        in.sliders.push_back(ysfx_get_slider_visibility(in.fx, g));
    }
}

bool mentions(const std::string &lower, const char *word) { return lower.find(word) != std::string::npos; }

// ---- 構造を知った変異（EEL の式の文法） -------------------------------------------------------------------
struct Gen {
    Rng r;
    std::string out;
    int budget = 60;

    const char *var()
    {
        static const char *const v[] = {"a", "b", "c", "x", "y", "z", "i", "j", "k", "n", "s0", "s1", "spl0", "spl1",
                                        "buf", "acc", "this.q", "ns.v", "_global.g", "slider1", "srate", "num_ch"};
        return v[r.below(sizeof v / sizeof *v)];
    }
    const char *lit()
    {
        static const char *const l[] = {"0", "1", "-1", "0.5", "2", "3", "7", "1e-310", "1e300", "0.00001", "0.000009",
                                        "65535.99999", "65536", "131072", "-0", "2147483648", "-2147483649", "1.5",
                                        "4294967296", "0x7fffffff", "$pi", "-2.75", "1000000", "8388608"};
        return l[r.below(sizeof l / sizeof *l)];
    }
    void expr(int depth)
    {
        if (--budget < 0 || depth <= 0) { out += r.oneIn(2) ? var() : lit(); return; }
        static const char *const bin[] = {"+", "-", "*", "/", "%", "&", "|", "~", "^", "<<", ">>", "==", "!=", "===",
                                          "!==", "<", ">", "<=", ">=", "&&", "||"};
        static const char *const f1[] = {"sin", "cos", "tan", "sqrt", "abs", "sign", "floor", "ceil", "exp", "log",
                                         "log10", "invsqrt", "atan", "asin", "acos", "rand"};
        switch (r.below(16)) {
        case 0: case 1: case 2: case 3:
            out += "("; expr(depth - 1); out += bin[r.below(sizeof bin / sizeof *bin)]; expr(depth - 1); out += ")"; break;
        case 4: out += r.oneIn(2) ? "-" : "!"; out += "("; expr(depth - 1); out += ")"; break;
        case 5: out += f1[r.below(sizeof f1 / sizeof *f1)]; out += "("; expr(depth - 1); out += ")"; break;
        case 6: out += r.oneIn(2) ? "min(" : "max("; expr(depth - 1); out += ","; expr(depth - 1); out += ")"; break;
        case 7: out += r.oneIn(2) ? "pow(" : "atan2("; expr(depth - 1); out += ","; expr(depth - 1); out += ")"; break;
        case 8: mem(depth); break;
        case 9: out += "("; expr(depth - 1); out += " ? "; expr(depth - 1); out += " : "; expr(depth - 1); out += ")"; break;
        case 10: out += "("; stmt(depth - 1); out += "; "; expr(depth - 1); out += ")"; break;
        case 11:
            out += "loop("; out += r.oneIn(3) ? lit() : std::to_string(r.below(9)); out += ", "; stmt(depth - 1); out += ")";
            break;
        case 12: out += "f1("; expr(depth - 1); out += ", "; expr(depth - 1); out += ")"; break;
        case 13: {
            static const char *const st[] = {"stack_peek(", "spl(", "slider(", "stack_push(", "stack_pop("};
            out += st[r.below(5)]; expr(depth - 1); out += ")"; break;
        }
        case 14: out += r.oneIn(2) ? "ns.f2(" : "f2("; expr(depth - 1); out += ")"; break;
        default: out += "("; lvalue(depth - 1); out += " "; assignOp(); out += " "; expr(depth - 1); out += ")"; break;
        }
    }
    void mem(int depth)
    {
        static const char *const bases[] = {"buf", "buf", "gmem", "0", "65530", "-3"};
        out += bases[r.below(sizeof bases / sizeof *bases)];
        out += "[";
        expr(depth - 1);
        out += "]";
    }
    void lvalue(int depth)
    {
        switch (r.below(6)) {
        case 0: mem(depth); break;
        case 1: out += "("; expr(depth - 1); out += " ? "; out += var(); out += " : "; out += var(); out += ")"; break;
        case 2: out += r.oneIn(2) ? "min(" : "max("; out += var(); out += ", "; out += var(); out += ")"; break;
        default: out += var(); break;
        }
    }
    void assignOp()
    {
        static const char *const ops[] = {"=", "=", "+=", "-=", "*=", "/=", "%=", "|=", "&=", "^=", "~="};
        out += ops[r.below(sizeof ops / sizeof *ops)];
    }
    void stmt(int depth)
    {
        switch (r.below(10)) {
        case 0:
            out += "while("; out += "(j += 1) < "; out += std::to_string(1 + r.below(12)); out += " && ("; stmt(depth - 1);
            out += "; 1))";
            break;
        case 1:
            out += r.oneIn(2) ? "mem_set_values(buf, " : "mem_get_values(buf, ";
            for (uint32_t k = 0, n = 1 + r.below(5); k < n; ++k) { if (k) out += ", "; out += var(); }
            out += ")";
            break;
        case 2: out += "stack_exch("; out += var(); out += ")"; break;
        case 3: out += "memcpy(buf, buf + "; expr(1); out += ", "; out += std::to_string(r.below(20)); out += ")"; break;
        default: lvalue(depth); out += " "; assignOp(); out += " "; expr(depth); break;
        }
    }
    void functions()
    {
        out += "function f1(p, q) local(t) (t = p * q + this.q; t += 1; t);\n";
        out += "function f2(p) instance(v) (v += p; v * 0.5);\n";
    }
};

/// src に、節（@init・@slider・@block・@sample）の頭の直後へ作った文を差し込む。節が無ければ作る。
std::string insertGenerated(const std::string &src, Rng &r)
{
    Gen g{Rng{r.next()}, std::string()};
    const int stmts = 1 + (int)r.below(4);
    for (int k = 0; k < stmts; ++k) { g.stmt(1 + (int)r.below(4)); g.out += ";\n"; }
    static const char *const sections[] = {"@sample", "@init", "@block", "@slider"};
    const char *sec = sections[r.below(4)];
    std::string s = src;
    if (s.empty() || s.find("desc:") == std::string::npos) s = "desc:fuzz\nslider1:0<0,1,0.1>s\n" + s;
    auto insertAfterHeader = [&s](const char *header, const std::string &text) {
        const size_t at = s.find(std::string("\n") + header);
        if (at == std::string::npos) { s += std::string("\n") + header + "\n" + text; return; }
        const size_t eol = s.find('\n', at + 1);
        if (eol == std::string::npos) s += "\n" + text;
        else s.insert(eol + 1, text);
    };
    insertAfterHeader(sec, g.out);
    // 作った文が f1・f2 を呼ぶなら、@init に関数を置く（ysfx は @init を先にコンパイルする）
    if ((g.out.find("f1(") != std::string::npos || g.out.find("f2(") != std::string::npos) &&
        s.find("function f1") == std::string::npos) {
        Gen fg{Rng{r.next()}, std::string()};
        fg.functions();
        insertAfterHeader("@init", fg.out);
    }
    return s;
}
} // namespace

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    ETVM_Install();
    // JSFXVMDIFF_SECTIONS=0x10 のように、vm-reg にする節を絞れる（ysfx_section_type_t のビット。調べるとき）
    if (const char *m = std::getenv("JSFXVMDIFF_SECTIONS")) ETVM_SetSectionMask((uint32_t)std::strtoul(m, nullptr, 0));
    std::atexit(removeSource);
    return 0;
}

extern "C" size_t LLVMFuzzerCustomMutator(uint8_t *data, size_t size, size_t maxSize, unsigned int seed)
{
    Rng r{seed * 0x9E3779B97F4A7C15ull + size};
    if (r.below(3) != 0) return LLVMFuzzerMutate(data, size, maxSize);
    const std::string s = insertGenerated(std::string((const char *)data, size), r);
    if (s.size() > maxSize) return LLVMFuzzerMutate(data, size, maxSize);
    std::memcpy(data, s.data(), s.size());
    return s.size();
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    std::string lower((const char *)data, size);
    for (char &c : lower) c = (char)std::tolower((unsigned char)c);
    if (mentions(lower, "time")) return 0; // time()・time_precise() は時計
    {
        FILE *f = std::fopen(sourcePath().c_str(), "wb");
        if (!f) { std::fprintf(stderr, "jsfxvmdiff harness: cannot write the source\n"); std::abort(); }
        if (size) std::fwrite(data, 1, size, f);
        std::fclose(f);
    }
    Rng r{fnv1a(data, size)};
    static const double rates[] = {48000, 44100, 96000, 22050};
    const double rate = rates[r.below(4)];
    const uint32_t blockSize = 1 + r.below(kMaxFrames);

    Run run;
    run.gmem = mentions(lower, "gmem");
    NSEEL_rand_reset();
    const etvm::Coverage before = etvm::coverage();
    const bool okA = create(run.a, NSEEL_EXEC_PORTABLE);
    const bool okB = create(run.b, NSEEL_EXEC_REG);
    if (okA != okB) broken("only one of the two effects compiled");
    if (!okA) return 0;
    if (run.a.portableUB != run.b.portableUB) broken("lift results differ between the two effects");
    if (run.a.portableUB) return 0;
    {
        const etvm::Coverage after = etvm::coverage();
        for (int s = 0; s < 8; ++s)
            if (after.buildFailed[s] != before.buildFailed[s])
                broken("a lifted handle could not be turned into threaded code: " + after.firstBuildError);
    }
    const uint32_t ins = std::min<uint32_t>(std::max<uint32_t>(ysfx_get_num_inputs(run.a.fx), 1), kMaxChannels);
    const uint32_t outs = std::min<uint32_t>(std::max<uint32_t>(ysfx_get_num_outputs(run.a.fx), 1), kMaxChannels);

    run.step("@init", [&](Inst &in) {
        ysfx_set_sample_rate(in.fx, rate);
        ysfx_set_block_size(in.fx, blockSize);
        ysfx_init(in.fx);
    });
    const uint32_t blocks = 2 + r.below(5);
    double pos = 0;
    for (uint32_t b = 0; b < blocks; ++b) {
        BlockPlan p;
        p.frames = 1 + r.below(blockSize);
        for (uint32_t i = 0; i < ysfx_max_sliders; ++i) {
            if (!ysfx_slider_exists(run.a.fx, i) || !r.oneIn(3)) continue;
            ysfx_slider_range_t range{};
            ysfx_slider_get_range(run.a.fx, i, &range);
            double v = range.min + (range.max - range.min) * r.unit();
            if (r.oneIn(8)) v = range.max + 1 + r.unit() * 100;
            if (r.oneIn(8)) v = range.min - 1 - r.unit() * 100;
            p.sliders.push_back({i, v});
        }
        if (r.oneIn(4)) p.trigger = (int)r.below(10);
        p.time.tempo = 60 + r.below(120);
        p.time.playback_state = r.oneIn(2) ? ysfx_playback_playing : ysfx_playback_paused;
        p.time.time_position = pos;
        p.time.beat_position = pos * p.time.tempo / 60;
        p.time.time_signature[0] = 4;
        p.time.time_signature[1] = 4;
        if (r.oneIn(3))
            for (uint32_t m = 0, n = 1 + r.below(3); m < n; ++m)
                p.midi.push_back({(uint8_t)r.below(256), (uint8_t)(0x80 | r.below(0x70)), (uint8_t)r.below(128),
                                  (uint8_t)r.below(128)});
        p.in.resize((size_t)kMaxChannels * kMaxFrames);
        for (double &v : p.in) v = sampleValue(r);
        run.step("block " + std::to_string(b), [&](Inst &in) { runBlock(in, p, ins, outs); });
        pos += p.frames / rate;
        if (r.oneIn(3)) {
            // 状態の保存（@serialize の書き）→ 読み込み（同じもの、ときどき値を崩したもの）
            ysfx_state_t *saved = nullptr;
            run.step("save state", [&](Inst &in) {
                ysfx_state_t *s = ysfx_save_state(in.fx);
                in.stateOk = s != nullptr;
                if (s) {
                    in.state.assign(s->data, s->data + s->data_size);
                    for (uint32_t i = 0; i < s->slider_count; ++i) {
                        uint8_t raw[12];
                        std::memcpy(raw, &s->sliders[i].index, 4);
                        std::memcpy(raw + 4, &s->sliders[i].value, 8);
                        in.state.insert(in.state.end(), raw, raw + 12);
                    }
                    if (&in == &run.a) saved = s; else ysfx_state_free(s);
                }
            });
            if (saved) {
                if (r.oneIn(2) && saved->data_size >= 8)
                    for (int k = 0; k < 3; ++k) {
                        const double v = sampleValue(r);
                        std::memcpy(saved->data + 8 * r.below((uint32_t)(saved->data_size / 8)), &v, 8);
                    }
                run.step("load state", [&](Inst &in) { (void)ysfx_load_state(in.fx, saved); });
                ysfx_state_free(saved);
            }
        }
    }
    return 0;
}
