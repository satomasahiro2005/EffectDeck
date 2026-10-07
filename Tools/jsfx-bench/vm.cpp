// Tools/jsfx-bench/vm.cpp — JSFX のレジスタ型 VM（Sources/JSFXVM、docs/jsfx-regvm-design.md）を見る口。
//
//   jsfx-bench --vm-dump [--vm-ir] [--vm-json out.json] <file.jsfx|dir> ...
//       ysfx で読んでコンパイルし、全部の handle（@gfx・@serialize も）を持ち上げる。handle ごとに
//       持ち上がったか（だめなら理由と位置）・ブロック・命令・升の数を出し、節ごとの割合と理由の表を出す。
//       --vm-ir は中間表現と、そこから並べた threaded code（段 S2）も出す（升は変数名・const(値)・temp・
//       static・volatile で）。節ごとに threaded code にできた handle とハンドラの数・畳んだ数も数える。
//   jsfx-bench --vm-opgrid
//       設計 §12.1: 命令 1 つ（とその前後の最小限）のバイトコードを手で組み、値の格子（±0・非正規化数・
//       closefactor のきわ・2^31・2^63・±Inf・NaN の 2 つのペイロード・-NaN …）の全部の組で、
//       portable（NSEEL_code_execute = WDL の GLUE_CALL_CODE そのもの）と、持ち上げた中間表現の参照の
//       解釈・threaded code（段 S2）を回し、出力の升を 1 ビットまで比べる。megabuf は VM を 2 つ作って、書いた先（塊と位置、
//       または nseel_ramalloc_onfail）を比べる。
#include "ysfx.h"
#include "WDL/eel2/ns-eel.h"
#include "WDL/eel2/ns-eel-int.h"

#include "ETVMBytecode.h"
#include "ETVMLink.h"
#include "ETVMExec.h"
#include "ETVMOpt.h"
#include "ETVM.h"

#include <algorithm>
#include <cfloat>
#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <map>
#include <string>
#include <sys/stat.h>
#include <vector>
#include <chrono>

namespace {
const char *const kSectionNames[] = {"?", "init", "slider", "block", "sample", "gfx", "serialize", "?"};

void listInputs(const std::string &path, std::vector<std::string> &out)
{
    struct stat st{};
    if (stat(path.c_str(), &st) != 0) { std::fprintf(stderr, "jsfx-bench --vm-dump: missing %s\n", path.c_str()); return; }
    if (!S_ISDIR(st.st_mode)) { out.push_back(path); return; }
    DIR *d = opendir(path.c_str());
    if (!d) return;
    std::vector<std::string> names;
    while (dirent *e = readdir(d)) {
        std::string name = e->d_name;
        if (name == "." || name == "..") continue;
        struct stat cs{};
        const std::string full = path + "/" + name;
        if (stat(full.c_str(), &cs) == 0 && S_ISREG(cs.st_mode)) names.push_back(full);
    }
    closedir(d);
    std::sort(names.begin(), names.end());
    out.insert(out.end(), names.begin(), names.end());
}

std::string jsonEscape(const std::string &s)
{
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if ((unsigned char)c < 0x20) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", c); o += b; }
        else o += c;
    }
    return o;
}

std::string cellNamer(uint64_t a, void *user) { return etvm::describeCell(*(const etvm::LinkReport *)user, a); }
} // namespace

int ETJSFXBenchVMDumpMain(const std::vector<std::string> &paths, bool printIR, const std::string &jsonPath)
{
#if !defined(EEL_TARGET_PORTABLE)
    (void)paths; (void)printIR; (void)jsonPath;
    std::fprintf(stderr, "jsfx-bench --vm-dump: needs the portable build (bytecode)\n");
    return 2;
#else
    std::vector<std::string> files;
    for (const auto &p : paths) listInputs(p, files);
    uint64_t handles[8] = {}, lifted[8] = {}, blocks[8] = {}, insns[8] = {}, nodes[8] = {};
    uint64_t thBuilt[8] = {}, thHandlers[8] = {}, thIR[8] = {}, thFolded[8] = {}, thDirect[8] = {}, thFused[8] = {},
             thCoalesced[8] = {}, thCopies[8] = {}, thDead[8] = {};
    std::string thFirstError;
    // 段 S3: loop / while / cmpbr / opimm / opto / membi / fuse2 / constbr / multidirect
    uint64_t s3[8][10] = {};
    etvm::OptStats optStats[8];
    const uint32_t passes = ETVM_GetPasses();
    std::map<std::string, uint64_t> reasons[8];
    uint64_t cellClasses[5] = {}, filesCompiled = 0, filesAllLifted = 0, filesNoConst = 0;
    double linkMsTotal = 0, linkMsMax = 0;
    std::string linkMsMaxFile;
    std::string jsonFiles;
    for (const auto &file : files) {
        const char *base = std::strrchr(file.c_str(), '/');
        base = base ? base + 1 : file.c_str();
        ysfx_config_t *config = ysfx_config_new();
        ysfx_t *fx = ysfx_new(config);
        ysfx_config_free(config);
        if (!ysfx_load_file(fx, file.c_str(), 0) || !ysfx_compile(fx, 0)) {
            std::printf("%-34s not compiled\n", base);
            ysfx_free(fx);
            continue;
        }
        ++filesCompiled;
        void *vm = nullptr;
        const uint32_t n = ysfx_get_eel_handles(fx, &vm, nullptr, nullptr, 0);
        std::vector<void *> hs(n);
        std::vector<int> secs(n);
        ysfx_get_eel_handles(fx, &vm, hs.data(), secs.data(), n);
        // つなぎ（全部の handle の持ち上げと升の分類）にかかる時間（設計 §10.2 の予算を見るため）
        const auto t0 = std::chrono::steady_clock::now();
        const etvm::LinkReport rep = etvm::link(vm, hs.data(), secs.data(), n);
        const etvm::CellFacts facts = etvm::cellFacts(rep);
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        linkMsTotal += ms;
        if (ms > linkMsMax) { linkMsMax = ms; linkMsMaxFile = base; }
        uint64_t cls[5] = {};
        for (const auto &[addr, c] : rep.cells) { ++cls[(int)c.cls]; ++cellClasses[(int)c.cls]; }
        if (rep.allAnalysed) ++filesAllLifted; else ++filesNoConst;
        std::printf("%-34s link %7.3f ms  cells var %" PRIu64 " const %" PRIu64 " static %" PRIu64 " temp %" PRIu64
                    " volatile %" PRIu64 "%s\n", base, ms, cls[0], cls[1], cls[2], cls[3], cls[4],
                    rep.allAnalysed ? "" : "  (a handle fell back: no const cells)");
        std::string jsonHandles;
        for (const etvm::HandleReport &hr : rep.handles) {
            if (!hr.present) continue;
            const int sec = hr.section >= 0 && hr.section < 8 ? hr.section : 7;
            ++handles[sec];
            nodes[sec] += hr.lift.nodes;
            char label[32];
            std::snprintf(label, sizeof label, "%s%s", kSectionNames[sec],
                          sec == 1 ? ("#" + std::to_string(hr.index)).c_str() : "");
            if (hr.lift.ok()) {
                ++lifted[sec];
                blocks[sec] += hr.lift.fn.blocks.size();
                insns[sec] += hr.lift.fn.instructionCount();
                std::string why;
                etvm::ThreadedStats ts;
                // 段 S3: アプリの実行系（ETVMLink.cpp の buildPrograms）と同じ順に、中間表現の最適化 → 並べる
                etvm::Function opt = hr.lift.fn;
                etvm::OptStats os;
                etvm::optimize(opt, passes, facts, &os);
                optStats[sec] += os;
                etvm::ThreadedProgram *tp = etvm::buildThreaded(opt, why, &ts, passes);
                if (tp) {
                    ++thBuilt[sec]; thHandlers[sec] += ts.handlers; thIR[sec] += ts.irInstructions;
                    thFolded[sec] += ts.foldedLoads; thDirect[sec] += ts.directDest; thFused[sec] += ts.fused;
                    thCoalesced[sec] += ts.coalesced; thCopies[sec] += ts.copies; thDead[sec] += ts.dead;
                    s3[sec][0] += ts.loopFused; s3[sec][1] += ts.whileFused; s3[sec][2] += ts.cmpBr;
                    s3[sec][3] += ts.opImm; s3[sec][4] += ts.opTo; s3[sec][5] += ts.memBI; s3[sec][6] += ts.fuse2;
                    s3[sec][7] += ts.constBr; s3[sec][8] += ts.multiDirect; s3[sec][9] += ts.loopKernel;
                } else if (thFirstError.empty()) thFirstError = std::string(base) + ": " + why;
                std::printf("  %-12s lifted   nodes %6zu blocks %5zu insns %6zu  threaded %s %zu handlers\n", label,
                            hr.lift.nodes, hr.lift.fn.blocks.size(), hr.lift.fn.instructionCount(),
                            tp ? "ok" : ("FAIL " + why).c_str(), ts.handlers);
                if (printIR) {
                    std::fputs(etvm::print(opt, cellNamer, (void *)&rep).c_str(), stdout);
                    if (tp) std::fputs(etvm::disassembleThreaded(tp, cellNamer, (void *)&rep).c_str(), stdout);
                }
                if (tp) etvm::freeThreaded(tp);
            } else {
                // ETVM_DUMP_BC=1: 断った handle のバイトコードを頭から並べて出す（跳び先は数えない。調べるとき）
                static const bool dumpBC = std::getenv("ETVM_DUMP_BC") != nullptr;
                etvm::LiftInput li;
                if (dumpBC && etvm::liftInputFromHandle(hs[&hr - rep.handles.data()], li) && !li.codeRanges.empty()) {
                    const uint64_t base = (uint64_t)(uintptr_t)li.code;
                    uint64_t end = base;
                    for (const auto &r : li.codeRanges) if (base >= r.first && base < r.second) end = r.second;
                    for (uint64_t at = base; at + 4 <= end;) {
                        const int op = etbc_read_i32((const unsigned char *)(uintptr_t)at);
                        const int ib = etbc_imm_bytes(op);
                        std::printf("      bc %5" PRIu64 " %-28s", at - base, etbc_name(op));
                        if (ib == 8) std::printf(" 0x%" PRIx64, etbc_read_u64((const unsigned char *)(uintptr_t)(at + 4)));
                        if (ib == 4) std::printf(" %+d", etbc_read_i32((const unsigned char *)(uintptr_t)(at + 4)));
                        std::printf("\n");
                        if (ib < 0) break;
                        at += 4 + (uint64_t)ib;
                    }
                }
                ++reasons[sec][etvm::fallbackName(hr.lift.reason)];
                std::printf("  %-12s FALLBACK %s at pc %" PRIu64 ": %s\n", label, etvm::fallbackName(hr.lift.reason),
                            hr.lift.pc, hr.lift.detail.c_str());
            }
            char item[512];
            std::snprintf(item, sizeof item, "%s{\"section\": \"%s\", \"index\": %d, \"lifted\": %s, \"reason\": \"%s\", "
                          "\"detail\": \"%s\", \"nodes\": %zu, \"blocks\": %zu, \"insns\": %zu}",
                          jsonHandles.empty() ? "" : ", ", kSectionNames[sec], hr.index, hr.lift.ok() ? "true" : "false",
                          etvm::fallbackName(hr.lift.reason), jsonEscape(hr.lift.detail).c_str(), hr.lift.nodes,
                          hr.lift.ok() ? hr.lift.fn.blocks.size() : (size_t)0,
                          hr.lift.ok() ? hr.lift.fn.instructionCount() : (size_t)0);
            jsonHandles += item;
        }
        char head[256];
        std::snprintf(head, sizeof head, "%s    {\"file\": \"%s\", \"cells\": {\"var\": %" PRIu64 ", \"const\": %" PRIu64
                      ", \"static\": %" PRIu64 ", \"temp\": %" PRIu64 ", \"volatile\": %" PRIu64 "}, \"handles\": [",
                      jsonFiles.empty() ? "" : ",\n", jsonEscape(base).c_str(), cls[0], cls[1], cls[2], cls[3], cls[4]);
        jsonFiles += head + jsonHandles + "]}";
        ysfx_free(fx);
    }
    std::printf("\ncoverage (files compiled %" PRIu64 ", every handle lifted in %" PRIu64 ")\n", filesCompiled, filesAllLifted);
    std::printf("  %-10s %8s %8s %8s %10s %10s\n", "section", "handles", "lifted", "%", "blocks", "insns");
    uint64_t th = 0, tl = 0;
    std::string jsonSections;
    for (int sec = 1; sec <= 6; ++sec) {
        th += handles[sec]; tl += lifted[sec];
        const double pct = handles[sec] ? 100.0 * (double)lifted[sec] / (double)handles[sec] : 100.0;
        std::printf("  %-10s %8" PRIu64 " %8" PRIu64 " %7.1f%% %10" PRIu64 " %10" PRIu64 "\n", kSectionNames[sec],
                    handles[sec], lifted[sec], pct, blocks[sec], insns[sec]);
        std::string rs;
        for (const auto &[why, cnt] : reasons[sec]) {
            std::printf("      fallback %-18s %" PRIu64 "\n", why.c_str(), cnt);
            rs += (rs.empty() ? "" : ", ") + std::string("\"") + why + "\": " + std::to_string(cnt);
        }
        char item[2048];
        std::snprintf(item, sizeof item, "%s\"%s\": {\"handles\": %" PRIu64 ", \"lifted\": %" PRIu64 ", \"blocks\": %" PRIu64
                      ", \"insns\": %" PRIu64 ", \"nodes\": %" PRIu64 ", \"fallbacks\": {%s}, \"threaded\": {\"built\": %" PRIu64
                      ", \"ir\": %" PRIu64 ", \"handlers\": %" PRIu64 ", \"dead\": %" PRIu64 ", \"foldedLoads\": %" PRIu64
                      ", \"directDest\": %" PRIu64 ", \"fused\": %" PRIu64 ", \"coalesced\": %" PRIu64 ", \"copies\": %" PRIu64
                      ", \"s3\": {\"constCells\": %zu, \"folded\": %zu, \"cseLoads\": %zu, \"csePure\": %zu, "
                      "\"forwarded\": %zu, \"deadStores\": %zu, \"loopFused\": %" PRIu64 ", \"whileFused\": %" PRIu64
                      ", \"cmpBr\": %" PRIu64 ", \"opImm\": %" PRIu64 ", \"opTo\": %" PRIu64 ", \"memBI\": %" PRIu64
                      ", \"fuse2\": %" PRIu64 ", \"constBr\": %" PRIu64 ", \"loopKernel\": %" PRIu64 "}}}",
                      jsonSections.empty() ? "" : ", ", kSectionNames[sec], handles[sec], lifted[sec], blocks[sec],
                      insns[sec], nodes[sec], rs.c_str(), thBuilt[sec], thIR[sec], thHandlers[sec], thDead[sec],
                      thFolded[sec], thDirect[sec], thFused[sec], thCoalesced[sec], thCopies[sec],
                      optStats[sec].constCells, optStats[sec].folded, optStats[sec].cseLoads, optStats[sec].csePure,
                      optStats[sec].forwarded, optStats[sec].deadStores, s3[sec][0], s3[sec][1], s3[sec][2], s3[sec][3],
                      s3[sec][4], s3[sec][5], s3[sec][6], s3[sec][7], s3[sec][9]);
        jsonSections += item;
    }
    std::printf("  %-10s %8" PRIu64 " %8" PRIu64 " %7.1f%%\n", "all", th, tl, th ? 100.0 * (double)tl / (double)th : 100.0);
    std::printf("\nthreaded code (lifted handles -> handlers)\n");
    std::printf("  %-10s %8s %8s %9s %7s %7s %7s %7s %7s %7s %7s\n", "section", "built", "IR", "handlers", "h/IR",
                "dead", "folded", "direct", "fused", "coal", "copies");
    uint64_t tb = 0;
    for (int sec = 1; sec <= 6; ++sec) {
        tb += thBuilt[sec];
        std::printf("  %-10s %8" PRIu64 " %8" PRIu64 " %9" PRIu64 " %7.2f %7" PRIu64 " %7" PRIu64 " %7" PRIu64 " %7" PRIu64
                    " %7" PRIu64 " %7" PRIu64 "\n", kSectionNames[sec], thBuilt[sec], thIR[sec], thHandlers[sec],
                    thIR[sec] ? (double)thHandlers[sec] / (double)thIR[sec] : 0.0, thDead[sec], thFolded[sec],
                    thDirect[sec], thFused[sec], thCoalesced[sec], thCopies[sec]);
    }
    std::printf("\nstage S3 (ETVM_PASSES = 0x%05x)\n", passes);
    std::printf("  %-10s %6s %6s %6s %6s %6s %6s %6s %6s | %6s %6s %6s %6s %6s %6s %6s %6s %6s\n", "section",
                "const", "fold", "cseLd", "cseOp", "fwd", "dead", "vfail", "multi", "loop", "while", "cmpbr", "opimm",
                "opto", "membi", "fuse2", "constb", "lkern");
    for (int sec = 1; sec <= 6; ++sec) {
        const etvm::OptStats &o = optStats[sec];
        std::printf("  %-10s %6zu %6zu %6zu %6zu %6zu %6zu %6zu %6" PRIu64 " | %6" PRIu64 " %6" PRIu64 " %6" PRIu64
                    " %6" PRIu64 " %6" PRIu64 " %6" PRIu64 " %6" PRIu64 " %6" PRIu64 " %6" PRIu64 "\n", kSectionNames[sec],
                    o.constCells, o.folded, o.cseLoads, o.csePure, o.forwarded, o.deadStores, o.verifyFailed,
                    s3[sec][8], s3[sec][0], s3[sec][1], s3[sec][2], s3[sec][3], s3[sec][4], s3[sec][5], s3[sec][6],
                    s3[sec][7], s3[sec][9]);
    }
    std::printf("  threaded built for %" PRIu64 " of %" PRIu64 " lifted handles%s%s\n", tb, tl,
                thFirstError.empty() ? "" : "; first failure: ", thFirstError.c_str());
    std::printf("  cells: var %" PRIu64 " const %" PRIu64 " static %" PRIu64 " temp %" PRIu64 " volatile %" PRIu64 "\n",
                cellClasses[0], cellClasses[1], cellClasses[2], cellClasses[3], cellClasses[4]);
    std::printf("  link (lift every handle + classify cells): total %.2f ms, max %.3f ms (%s)\n", linkMsTotal, linkMsMax,
                linkMsMaxFile.c_str());
    if (!jsonPath.empty()) {
        FILE *f = std::fopen(jsonPath.c_str(), "wb");
        if (!f) { std::fprintf(stderr, "jsfx-bench: cannot write %s\n", jsonPath.c_str()); return 2; }
        std::fprintf(f, "{\n  \"filesCompiled\": %" PRIu64 ", \"filesAllLifted\": %" PRIu64 ", \"linkMsTotal\": %.3f, "
                     "\"linkMsMax\": %.3f, \"linkMsMaxFile\": \"%s\",\n  \"sections\": {%s},\n"
                     "  \"passes\": %u,\n  \"cells\": {\"var\": %" PRIu64 ", \"const\": %" PRIu64 ", \"static\": %" PRIu64 ", \"temp\": %" PRIu64
                     ", \"volatile\": %" PRIu64 "},\n  \"files\": [\n%s\n  ]\n}\n",
                     filesCompiled, filesAllLifted, linkMsTotal, linkMsMax, jsonEscape(linkMsMaxFile).c_str(),
                     jsonSections.c_str(), passes, cellClasses[0], cellClasses[1], cellClasses[2], cellClasses[3], cellClasses[4],
                     jsonFiles.c_str());
        std::fclose(f);
        std::printf("json: %s\n", jsonPath.c_str());
    }
    // 割合は数えるだけ（断るのは正しい振る舞い）。照合は --vm-opgrid と --diff。
    return filesCompiled && tb == tl ? 0 : 1;
#endif
}

// ---- §12.1 命令の格子 ----------------------------------------------------------------------------------
#if defined(EEL_TARGET_PORTABLE)
namespace {
uint64_t bitsOf(double v) { uint64_t b; std::memcpy(&b, &v, 8); return b; }
double fromBits(uint64_t b) { double v; std::memcpy(&v, &b, 8); return v; }

std::vector<double> valueGrid()
{
    const double ulp5 = std::nextafter(1e-5, 1.0) - 1e-5;
    std::vector<double> g = {
        0.0, -0.0, fromBits(1), -fromBits(1),                       // ±最小の非正規化数
        fromBits(0x000fffffffffffffull), -fromBits(0x000fffffffffffffull), // ±最大の非正規化数
        DBL_MIN, -DBL_MIN, 1e-5, 1e-5 + ulp5, 1e-5 - ulp5, -1e-5, -(1e-5 - ulp5),
        0.5, 1.0, -1.0, 1.5, -1.5, 2.0, 3.0, 7.25, -2.75,
        2147483647.0, 2147483648.0, 2147483649.0, -2147483648.0, -2147483649.0, 4294967296.0,
        9223372036854775808.0, -9223372036854775808.0, 9007199254740993.0, 1e30, -1e30, 1048577.0,
        INFINITY, -INFINITY,
        fromBits(0x7ff8000000000001ull), fromBits(0x7ff80000deadbeefull), fromBits(0xfff8000000000000ull),
        fromBits(0x7ff0000000000001ull), // signalling NaN
        DBL_MAX, -DBL_MAX, 65535.99999, 65536.0, 131071.0,
    };
    return g;
}

struct Asm {
    std::vector<unsigned char> b;
    void op(int o) { put(&o, 4); }
    void i32(int32_t v) { put(&v, 4); }
    void u64(uint64_t v) { put(&v, 8); }
    void ptr(const void *p) { u64((uint64_t)(uintptr_t)p); }
    void put(const void *p, size_t n) { const unsigned char *c = (const unsigned char *)p; b.insert(b.end(), c, c + n); }
    size_t here() const { return b.size(); }
    /// 4 バイトの跳び先を後で埋める（命令の直後の即値の位置 at、跳び先 target）。
    void patch(size_t at, size_t target) { const int32_t off = (int32_t)target - (int32_t)(at + 4); std::memcpy(&b[at], &off, 4); }
    size_t jmp(int o) { op(o); const size_t at = here(); i32(0); return at; }
};

struct Machine {
    double wt[64 + 48] = {};
    NSEEL_VMCTX vm = nullptr;
    void *rt = nullptr;
    Machine()
    {
        vm = NSEEL_VM_alloc();
        NSEEL_VM_setramsize(vm, 128 * 65536);
        rt = ((compileContext *)vm)->ram_state->blocks;
    }
    ~Machine() { NSEEL_VM_free(vm); }
};

/// portable で回す（GLUE_CALL_CODE そのもの）。
void runPortable(const Asm &a, Machine &m)
{
    codeHandleType h;
    std::memset(&h, 0, sizeof h);
    h.code = (void *)a.b.data();
    h.workTable = m.wt;
    h.ramPtr = m.rt;
    NSEEL_code_execute(&h);
}

/// 持ち上げて回す。side 1 = 参照の解釈、2 = threaded code（いまの ETVM_PASSES。升の性質は知らない）、
/// 3 = 2 + 段 S3 の中間表現の最適化（どの升も読み直してよく、書かれない升は Const として建てるときに値を読む）。
/// だめなら理由。
std::string runLifted(const Asm &a, Machine &m, int side)
{
    const bool threaded = side >= 2;
    etvm::LiftInput in;
    in.code = a.b.data();
    in.workTable = (uint64_t)(uintptr_t)m.wt;
    in.ramPtr = (uint64_t)(uintptr_t)m.rt;
    in.codeRanges.push_back({(uint64_t)(uintptr_t)a.b.data(), (uint64_t)(uintptr_t)a.b.data() + a.b.size()});
    etvm::LiftResult r = etvm::lift(in);
    static const bool debug = std::getenv("ETVM_OPGRID_DEBUG") != nullptr;
    if (debug) {
        std::fprintf(stderr, "-- lift %s %s at %" PRIu64 "\n", etvm::fallbackName(r.reason), r.detail.c_str(), r.pc);
        if (r.ok()) std::fputs(etvm::print(r.fn).c_str(), stderr);
        else
            for (size_t at = 0; at + 4 <= a.b.size();) {
                const int op = etbc_read_i32(a.b.data() + at);
                const int ib = etbc_imm_bytes(op);
                std::fprintf(stderr, "   %4zu %s", at, etbc_name(op));
                if (ib == 8) std::fprintf(stderr, " 0x%" PRIx64, etbc_read_u64(a.b.data() + at + 4));
                std::fprintf(stderr, "\n");
                if (ib < 0) break;
                at += 4 + (size_t)ib;
            }
    }
    if (!r.ok()) return std::string(etvm::fallbackName(r.reason)) + ": " + r.detail;
    if (side == 3) {
        etvm::CellFacts facts;
        bool anyIndirect = false;
        for (const etvm::Block &bl : r.fn.blocks)
            for (const etvm::Ins &in : bl.ins)
                anyIndirect |= in.op == etvm::Op::Store || in.op == etvm::Op::UStackPop || in.op == etvm::Op::UStackExch ||
                               in.op == etvm::Op::CallG || in.op == etvm::Op::CallGD || in.op == etvm::Op::CallVarparm;
        for (const etvm::Block &bl : r.fn.blocks)
            for (const etvm::Ins &in : bl.ins)
                if (in.op == etvm::Op::LoadCell || in.op == etvm::Op::StoreCell) facts.cells[in.imm[0]] |= etvm::CellFacts::Cacheable;
        for (auto &[addr, k] : facts.cells) {
            bool stored = anyIndirect;
            for (const etvm::Block &bl : r.fn.blocks)
                for (const etvm::Ins &in : bl.ins) stored |= in.op == etvm::Op::StoreCell && in.imm[0] == addr;
            if (!stored) k |= etvm::CellFacts::Const;
        }
        std::string w;
        if (!etvm::optimize(r.fn, ETVM_GetPasses(), facts, nullptr, &w)) return "optimize: " + w;
        if (debug) std::fputs(etvm::print(r.fn).c_str(), stderr);
    }
    if (threaded) {
        std::string why;
        etvm::ThreadedProgram *p = etvm::buildThreaded(r.fn, why, nullptr, ETVM_GetPasses());
        if (!p) return "threaded: " + why;
        if (debug) std::fputs(etvm::disassembleThreaded(p).c_str(), stderr);
        etvm::runThreaded(p, 1, nullptr, nullptr, nullptr);
        etvm::freeThreaded(p);
        return std::string();
    }
    etvm::InterpState st;
    etvm::interpret(r.fn, st);
    return std::string();
}

struct Tally {
    uint64_t cases = 0, bad = 0, liftFail = 0;
    uint64_t badTh = 0; // threaded code（段 S2）と portable
    uint64_t badOpt = 0; // threaded code + 段 S3 の中間表現の最適化（升を Const に）と portable
    std::string first, firstTh, firstOpt;
};

/// 升 X・Y・Z・O と印 M を使う 1 つの組を両方で回し、升を比べる。
struct Cells { double x, y, z, o, m; };

template <class Build>
void check(const char *name, std::map<std::string, Tally> &t, const std::vector<double> &grid, int arity, Build build)
{
    Tally &ta = t[name];
    const size_t ny = arity >= 2 ? grid.size() : 1;
    Machine mach; // megabuf を使わない組は 1 つで足りる（rt は読まない）
    for (size_t i = 0; i < grid.size(); ++i)
        for (size_t j = 0; j < ny; ++j) {
            // 0 = portable、1 = 中間表現の参照の解釈、2 = threaded code、3 = threaded + 段 S3 の最適化（Const 升）
            Cells c[4];
            bool lifted = true;
            for (int side = 0; side < 4 && lifted; ++side) {
                c[side] = Cells{grid[i], grid[j % grid.size()], grid[i], 0.0, 12345.678};
                std::memset(mach.wt, 0, sizeof mach.wt);
                Asm a;
                build(a, c[side]);
                if (side == 0) runPortable(a, mach);
                else {
                    const std::string why = runLifted(a, mach, side);
                    if (!why.empty()) {
                        if (!ta.liftFail++ && ta.first.empty()) ta.first = "lift: " + why;
                        lifted = false;
                    }
                }
            }
            if (!lifted) continue;
            ++ta.cases;
            const uint64_t pc[4] = {bitsOf(c[0].x), bitsOf(c[0].y), bitsOf(c[0].z), bitsOf(c[0].o)};
            // 2 つの入力がどちらも NaN のときも 1 ビットまで（+ * のペイロードは、持ち上げが portable の機械の
            // オペランドの順を調べて合わせる。etvm::portableNaNOrder）
            for (int side = 1; side < 4; ++side) {
                const uint64_t ic[4] = {bitsOf(c[side].x), bitsOf(c[side].y), bitsOf(c[side].z), bitsOf(c[side].o)};
                bool same = true;
                for (int k = 0; k < 4; ++k)
                    if (pc[k] != ic[k]) same = false;
                uint64_t &bad = side == 1 ? ta.bad : side == 2 ? ta.badTh : ta.badOpt;
                std::string &first = side == 1 ? ta.first : side == 2 ? ta.firstTh : ta.firstOpt;
                if (!same && !bad++) {
                    char b[400];
                    std::snprintf(b, sizeof b, "x=%a y=%a: portable x,y,z,o=%016" PRIx64 ",%016" PRIx64 ",%016" PRIx64
                                  ",%016" PRIx64 " / %s %016" PRIx64 ",%016" PRIx64 ",%016" PRIx64 ",%016" PRIx64,
                                  grid[i], grid[j % grid.size()], pc[0], pc[1], pc[2], pc[3],
                                  side == 1 ? "ir" : side == 2 ? "threaded" : "threaded+s3", ic[0], ic[1], ic[2], ic[3]);
                    first = b;
                }
            }
        }
}

/// megabuf: 書いた先（塊と位置、または onfail）を比べる。
std::string megabufTarget(Machine &m, double mark)
{
    if (bitsOf(nseel_ramalloc_onfail) == bitsOf(mark)) return "onfail";
    EEL_F **blocks = (EEL_F **)m.rt;
    for (int bl = 0; bl < NSEEL_RAM_BLOCKS; ++bl) {
        if (!blocks[bl]) continue;
        for (int k = 0; k < NSEEL_RAM_ITEMSPERBLOCK; ++k)
            if (bitsOf(blocks[bl][k]) == bitsOf(mark)) return std::to_string(bl) + ":" + std::to_string(k);
    }
    return "none";
}
} // namespace
#endif

int ETJSFXBenchVMOpGridMain()
{
#if !defined(EEL_TARGET_PORTABLE)
    std::fprintf(stderr, "jsfx-bench --vm-opgrid: needs the portable build (bytecode)\n");
    return 2;
#else
    const std::vector<double> grid = valueGrid();
    std::map<std::string, Tally> t;
    // 2 つ積んで 1 つの命令 → O へ（BOOL を返すものは BOOLTOFP で）
    struct Bin { const char *name; int op; bool boolean; };
    const Bin bins[] = {
        {"ADD", ETBC_ADD, false}, {"SUB", ETBC_SUB, false}, {"MUL", ETBC_MUL, false}, {"DIV", ETBC_DIV, false},
        {"AND", ETBC_AND, false}, {"OR", ETBC_OR, false}, {"XOR", ETBC_XOR, false}, {"MOD", ETBC_MOD, false},
        {"SHL", ETBC_SHL, false}, {"SHR", ETBC_SHR, false}, {"MIN_FP", ETBC_MIN_FP, false}, {"MAX_FP", ETBC_MAX_FP, false},
        {"EQUAL", ETBC_EQUAL, true}, {"EQUAL_EXACT", ETBC_EQUAL_EXACT, true}, {"NOTEQUAL", ETBC_NOTEQUAL, true},
        {"NOTEQUAL_EXACT", ETBC_NOTEQUAL_EXACT, true}, {"ABOVE", ETBC_ABOVE, true}, {"BELOWEQ", ETBC_BELOWEQ, true},
    };
    for (const Bin &bn : bins)
        check(bn.name, t, grid, 2, [&](Asm &a, Cells &c) {
            a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.x);
            a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.y);
            a.op(bn.op);
            if (bn.boolean) a.op(ETBC_BOOLTOFP);
            a.op(ETBC_POP_FPSTACK_TO_PTR); a.ptr(&c.o);
            a.op(ETBC_RET);
        });
    struct Un { const char *name; int op; int kind; }; // kind 0 = 値, 1 = BOOL を返す, 2 = BNOT
    const Un uns[] = {
        {"UMINUS", ETBC_UMINUS, 0}, {"SQR", ETBC_SQR, 0}, {"ABS", ETBC_ABS, 0}, {"SIGN", ETBC_SIGN, 0},
        {"INVSQRT", ETBC_INVSQRT, 0}, {"OR0", ETBC_OR0, 0}, {"FPTOBOOL", ETBC_FPTOBOOL, 1},
        {"FPTOBOOL_REV", ETBC_FPTOBOOL_REV, 1}, {"BNOT", ETBC_BNOT, 2},
    };
    for (const Un &u : uns)
        check(u.name, t, grid, 1, [&](Asm &a, Cells &c) {
            a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.x);
            if (u.kind == 2) a.op(ETBC_FPTOBOOL);
            a.op(u.op);
            if (u.kind != 0) a.op(ETBC_BOOLTOFP);
            a.op(ETBC_POP_FPSTACK_TO_PTR); a.ptr(&c.o);
            a.op(ETBC_RET);
        });
    // 升への演算（p2 = Z）。p1 = p2 になるので、続けて p1 の値も O へ
    struct OpAssign { const char *name; int op; };
    const OpAssign opas[] = {
        {"ADD_OP", ETBC_ADD_OP}, {"SUB_OP", ETBC_SUB_OP}, {"MUL_OP", ETBC_MUL_OP}, {"DIV_OP", ETBC_DIV_OP},
        {"ADD_OP_FAST", ETBC_ADD_OP_FAST}, {"SUB_OP_FAST", ETBC_SUB_OP_FAST}, {"MUL_OP_FAST", ETBC_MUL_OP_FAST},
        {"DIV_OP_FAST", ETBC_DIV_OP_FAST}, {"AND_OP", ETBC_AND_OP}, {"OR_OP", ETBC_OR_OP}, {"XOR_OP", ETBC_XOR_OP},
        {"MOD_OP", ETBC_MOD_OP},
    };
    for (const OpAssign &oa : opas)
        check(oa.name, t, grid, 2, [&](Asm &a, Cells &c) {
            a.op(ETBC_MOV_P2_DV); a.ptr(&c.z);
            a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.y);
            a.op(oa.op);
            a.op(ETBC_PUSH_VAL_AT_P1_TO_FPSTACK);
            a.op(ETBC_POP_FPSTACK_TO_PTR); a.ptr(&c.o);
            a.op(ETBC_RET);
        });
    // 代入（フィルタの有無）
    check("ASSIGN", t, grid, 1, [&](Asm &a, Cells &c) {
        a.op(ETBC_MOV_P1_DV); a.ptr(&c.x); a.op(ETBC_MOV_P2_DV); a.ptr(&c.o); a.op(ETBC_ASSIGN); a.op(ETBC_RET);
    });
    check("ASSIGN_FAST", t, grid, 1, [&](Asm &a, Cells &c) {
        a.op(ETBC_MOV_P1_DV); a.ptr(&c.x); a.op(ETBC_MOV_P2_DV); a.ptr(&c.o); a.op(ETBC_ASSIGN_FAST); a.op(ETBC_RET);
    });
    check("ASSIGN_FROMFP", t, grid, 1, [&](Asm &a, Cells &c) {
        a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.x); a.op(ETBC_MOV_P2_DV); a.ptr(&c.o); a.op(ETBC_ASSIGN_FROMFP); a.op(ETBC_RET);
    });
    check("ASSIGN_FAST_FROMFP", t, grid, 1, [&](Asm &a, Cells &c) {
        a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.x); a.op(ETBC_MOV_P2_DV); a.ptr(&c.o); a.op(ETBC_ASSIGN_FAST_FROMFP);
        a.op(ETBC_RET);
    });
    // min / max（参照を返す）: 選ばれた升へ印を書く（-0 と +0・NaN でどちらを選ぶか）
    for (int mm = 0; mm < 2; ++mm)
        check(mm ? "MAX" : "MIN", t, grid, 2, [&](Asm &a, Cells &c) {
            a.op(ETBC_MOV_P1_DV); a.ptr(&c.x); a.op(ETBC_MOV_P2_DV); a.ptr(&c.y);
            a.op(mm ? ETBC_MAX : ETBC_MIN);
            a.op(ETBC_PUSH_VAL_AT_P1_TO_FPSTACK); a.op(ETBC_POP_FPSTACK_TO_PTR); a.ptr(&c.o);
            a.op(ETBC_SET_P2_FROM_P1); a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.m); a.op(ETBC_ASSIGN_FAST_FROMFP);
            a.op(ETBC_RET);
        });
    // C の関数（同じ関数ポインタを呼ぶ）
    struct C1 { const char *name; double (*f)(double); };
    using D1 = double (*)(double);
    const C1 c1s[] = {{"CFUNC_1PDD sin", static_cast<D1>(&::sin)}, {"CFUNC_1PDD exp", static_cast<D1>(&::exp)},
                      {"CFUNC_1PDD log", static_cast<D1>(&::log)}, {"CFUNC_1PDD floor", static_cast<D1>(&::floor)}};
    for (const C1 &cf : c1s)
        check(cf.name, t, grid, 1, [&](Asm &a, Cells &c) {
            a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.x); a.op(ETBC_CFUNC_1PDD); a.ptr((const void *)cf.f);
            a.op(ETBC_POP_FPSTACK_TO_PTR); a.ptr(&c.o); a.op(ETBC_RET);
        });
    struct C2 { const char *name; double (*f)(double, double); };
    using D2 = double (*)(double, double);
    const C2 c2s[] = {{"CFUNC_2PDD pow", static_cast<D2>(&::pow)}, {"CFUNC_2PDD atan2", static_cast<D2>(&::atan2)}};
    for (const C2 &cf : c2s)
        check(cf.name, t, grid, 2, [&](Asm &a, Cells &c) {
            a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.x); a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.y);
            a.op(ETBC_CFUNC_2PDD); a.ptr((const void *)cf.f);
            a.op(ETBC_POP_FPSTACK_TO_PTR); a.ptr(&c.o); a.op(ETBC_RET);
        });
    check("CFUNC_2PDDS pow", t, grid, 2, [&](Asm &a, Cells &c) {
        a.op(ETBC_MOV_P2_DV); a.ptr(&c.z); a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.y);
        a.op(ETBC_CFUNC_2PDDS); a.ptr((const void *)static_cast<D2>(&::pow)); a.op(ETBC_RET);
    });
    // loop: X 回（(int)・1 未満は飛ばす・1048576 で打ち切る）。Z に 1 ずつ足す
    static const double kOne = 1.0;
    check("LOOP", t, grid, 1, [&](Asm &a, Cells &c) {
        c.z = 0;
        a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.x);
        const size_t skip = a.jmp(ETBC_LOOP_LOADCNT);
        const size_t top = a.here();
        a.op(ETBC_MOV_P2_DV); a.ptr(&c.z); a.op(ETBC_MOV_FPTOP_DV); a.ptr(&kOne); a.op(ETBC_ADD_OP_FAST);
        const size_t back = a.jmp(ETBC_LOOP_END);
        a.patch(back, top);
        a.patch(skip, a.here());
        a.op(ETBC_RET);
    });
    // while: X が真の間（1048576 回で打ち切る）。Z に 1 ずつ足す
    check("WHILE", t, grid, 1, [&](Asm &a, Cells &c) {
        c.z = 0;
        a.op(ETBC_WHILE_SETUP);
        const size_t top = a.here();
        a.op(ETBC_WHILE_BEGIN);
        a.op(ETBC_MOV_P2_DV); a.ptr(&c.z); a.op(ETBC_MOV_FPTOP_DV); a.ptr(&kOne); a.op(ETBC_ADD_OP_FAST);
        a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.x); a.op(ETBC_FPTOBOOL);
        const size_t end = a.jmp(ETBC_WHILE_END);
        const size_t again = a.jmp(ETBC_WHILE_CHECK_RV);
        a.patch(again, top);
        a.patch(end, a.here());
        a.op(ETBC_RET);
    });
    // 分かれて合流（浮動小数の積み場の phi）: X が真なら Y、偽なら Z
    for (int nz = 0; nz < 2; ++nz)
        check(nz ? "JMP_IF_P1_NZ merge" : "JMP_IF_P1_Z merge", t, grid, 2, [&](Asm &a, Cells &c) {
            a.op(ETBC_MOV_FPTOP_DV); a.ptr(&c.x); a.op(ETBC_FPTOBOOL);
            const size_t j = a.jmp(nz ? ETBC_JMP_IF_P1_NZ : ETBC_JMP_IF_P1_Z);
            a.op(ETBC_MOV_FPTOP_DV); a.ptr(nz ? &c.z : &c.y);
            const size_t over = a.jmp(ETBC_JMP_NC);
            a.patch(j, a.here());
            a.op(ETBC_MOV_FPTOP_DV); a.ptr(nz ? &c.y : &c.z);
            a.patch(over, a.here());
            a.op(ETBC_POP_FPSTACK_TO_PTR); a.ptr(&c.o);
            a.op(ETBC_RET);
        });
    // megabuf（VM を 2 つ。書いた先を比べる）
    {
        Tally &ta = t["MEGABUF"];
        for (double x : grid) {
            std::string where[4];
            bool lifted = true;
            for (int side = 0; side < 4; ++side) {
                Machine mach;
                nseel_ramalloc_onfail = 0;
                double cx = x, mark = 777.25;
                Asm a;
                a.op(ETBC_MOV_FPTOP_DV); a.ptr(&cx); a.op(ETBC_MEGABUF); a.op(ETBC_SET_P2_FROM_P1);
                a.op(ETBC_MOV_FPTOP_DV); a.ptr(&mark); a.op(ETBC_ASSIGN_FAST_FROMFP); a.op(ETBC_RET);
                if (side == 0) runPortable(a, mach);
                else {
                    const std::string why = runLifted(a, mach, side);
                    if (!why.empty()) { lifted = false; if (!ta.liftFail++) ta.first = "lift: " + why; break; }
                }
                where[side] = megabufTarget(mach, mark);
            }
            nseel_ramalloc_onfail = 0;
            if (!lifted) continue;
            ++ta.cases;
            if (where[0] != where[1] && !ta.bad++) {
                char b[160];
                std::snprintf(b, sizeof b, "x=%a: portable %s / ir %s", x, where[0].c_str(), where[1].c_str());
                ta.first = b;
            }
            if (where[0] != where[3] && !ta.badOpt++) {
                char b[160];
                std::snprintf(b, sizeof b, "x=%a: portable %s / threaded+s3 %s", x, where[0].c_str(), where[3].c_str());
                ta.firstOpt = b;
            }
            if (where[0] != where[2] && !ta.badTh++) {
                char b[160];
                std::snprintf(b, sizeof b, "x=%a: portable %s / threaded %s", x, where[0].c_str(), where[2].c_str());
                ta.firstTh = b;
            }
        }
    }
    uint64_t total = 0, bad = 0, badTh = 0, badOpt = 0, fails = 0;
    const etvm::PortableNaNOrder &no = etvm::portableNaNOrder();
    std::printf("portable NaN+NaN operand order (first operand of the machine op): ADD %s, MUL %s, ADD_OP_FAST %s, "
                "MUL_OP_FAST %s%s%s\n", no.addTopFirst ? "top" : "top2", no.mulTopFirst ? "top" : "top2",
                no.addOpValueFirst ? "value" : "cell", no.mulOpValueFirst ? "value" : "cell", no.note.empty() ? "" : "; ",
                no.note.c_str());
    std::printf("jsfx-bench --vm-opgrid: %zu values; portable (GLUE_CALL_CODE) vs lifted IR (reference interpreter) "
                "and vs threaded code (passes 0x%05x; threaded+s3 also treats unwritten cells as Const)\n", grid.size(),
                ETVM_GetPasses());
    for (const auto &[name, ta] : t) {
        total += ta.cases; bad += ta.bad; badTh += ta.badTh; badOpt += ta.badOpt; fails += ta.liftFail;
        std::printf("  %-22s %6" PRIu64 " cases  %s", name.c_str(), ta.cases,
                    ta.bad || ta.badTh || ta.badOpt || ta.liftFail ? "MISMATCH" : "ok");
        if (!ta.first.empty()) std::printf("  %s", ta.first.c_str());
        if (!ta.firstTh.empty()) std::printf("  %s", ta.firstTh.c_str());
        if (!ta.firstOpt.empty()) std::printf("  %s", ta.firstOpt.c_str());
        std::printf("\n");
    }
    std::printf("total %" PRIu64 " cases, mismatched: ir %" PRIu64 ", threaded %" PRIu64 ", threaded+s3 %" PRIu64
                "; %" PRIu64 " not lifted\n", total, bad, badTh, badOpt, fails);
    const bool failed = bad || badTh || badOpt || fails;
    std::printf(failed ? "RESULT FAIL\n" : "RESULT ok\n");
    return failed ? 1 : 0;
#endif
}
