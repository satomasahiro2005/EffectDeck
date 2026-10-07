// Tools/jsfx-bench/main.cpp — ETJSFXBench を机の上で回す口（Tools/jsfx-bench/run.sh が建てる）。
//
//   jsfx-bench --dir Debug/JSFXBench [--seconds 5] [--warmup 0.5] [--chunk 16]
//              [--scripts gain,fir] [--variants portable,cpp] [--json out.json]
//              [--config <字>] [--sha <字>] [--flags <字>] [--no-rt] [--spin <ミリ秒>]
//              [--profile-out ops.json]
//   jsfx-bench --diff [--diff-blocks 48] <file.jsfx|dir> ...
//
// --diff は速さではなく、EEL の実行系ごとの結果が portable と 1 ビットまで同じかを見る（diff.cpp）。
// --profile-out は -DNSEEL_VM_PROFILE で建てたものだけ。回した命令の数と続いた 2 つの組を JSON に書く。
//
// 表を stdout に出し、--json に JSON を書く。照合が落ちたら終了値 1。
// JIT（-DET_JSFX_BENCH_JIT_PROBE）で建てたものは、先に「書いた頁を実行できるか」を確かめる
// （WDL と同じく mmap RW → mprotect RX）。OS が断ったら何が断られたかを出して 3 で終わる。
#include "ETJSFXBench.h"

#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <vector>

#if defined(NSEEL_VM_PROFILE)
#include "WDL/eel2/ns-eel.h"
#endif

int ETJSFXBenchDiffMain(const std::vector<std::string> &paths, uint32_t blocks);

#if defined(ET_JSFX_BENCH_JIT_PROBE)
#include <sys/mman.h>
#if defined(__APPLE__)
#include <libkern/OSCacheControl.h>
#endif
#endif

namespace {
const char *gStage = "start";

void onFault(int sig, siginfo_t *info, void *)
{
    char line[256];
    int n = std::snprintf(line, sizeof line, "jsfx-bench: signal %d (%s) at %p during %s\n", sig,
                          sig == SIGBUS ? "SIGBUS" : sig == SIGSEGV ? "SIGSEGV" : sig == SIGILL ? "SIGILL" : "?",
                          info ? info->si_addr : nullptr, gStage);
    if (n > 0) (void)!write(2, line, (size_t)n);
    _exit(4);
}

#if defined(ET_JSFX_BENCH_JIT_PROBE)
/// WDL の nseel-compiler.c と同じ手順で 1 頁だけ作って呼ぶ（mov w0,#42; ret）。
bool probeJIT(std::string &what)
{
#if defined(__aarch64__)
    const size_t size = (size_t)sysconf(_SC_PAGESIZE);
    void *page = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (page == MAP_FAILED) { what = std::string("mmap(RW) failed: ") + std::strerror(errno); return false; }
    const uint32_t code[2] = {0x52800540u, 0xd65f03c0u};
    std::memcpy(page, code, sizeof code);
    if (mprotect(page, size, PROT_READ | PROT_EXEC) != 0) {
        what = std::string("mprotect(RW->RX) failed: ") + std::strerror(errno); return false;
    }
#if defined(__APPLE__)
    sys_icache_invalidate(page, size);
#else
    __builtin___clear_cache((char *)page, (char *)page + size);
#endif
    gStage = "calling a page made executable with mprotect (JIT probe)";
    const int got = reinterpret_cast<int (*)()>(page)();
    gStage = "bench";
    munmap(page, size);
    if (got != 42) { what = "probe returned " + std::to_string(got); return false; }
    what = "mmap RW + mprotect RX + call: ok (page size " + std::to_string(size) + ")";
    return true;
#else
    what = "probe only written for aarch64";
    return true;
#endif
}
#endif
} // namespace

int main(int argc, char **argv)
{
    struct sigaction sa{};
    sa.sa_sigaction = onFault; sa.sa_flags = SA_SIGINFO;
    sigaction(SIGBUS, &sa, nullptr); sigaction(SIGSEGV, &sa, nullptr); sigaction(SIGILL, &sa, nullptr);

    ETJSFXBenchOptions o;
    ETJSFXBench_DefaultOptions(&o);
    std::string dir = "Debug/JSFXBench", json, scripts, variants, config, sha, flags, profileOut;
    bool diff = false;
    uint32_t diffBlocks = 48;
    std::vector<std::string> diffPaths;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&](const char *name) -> std::string {
            if (i + 1 >= argc) { std::fprintf(stderr, "jsfx-bench: %s needs a value\n", name); std::exit(2); }
            return argv[++i];
        };
        if (a == "--dir") dir = next("--dir");
        else if (a == "--seconds") o.seconds = std::atof(next("--seconds").c_str());
        else if (a == "--warmup") o.warmupSeconds = std::atof(next("--warmup").c_str());
        else if (a == "--chunk") o.chunkBlocks = (uint32_t)std::atoi(next("--chunk").c_str());
        else if (a == "--scripts") scripts = next("--scripts");
        else if (a == "--variants") variants = next("--variants");
        else if (a == "--json") json = next("--json");
        else if (a == "--config") config = next("--config");
        else if (a == "--sha") sha = next("--sha");
        else if (a == "--flags") flags = next("--flags");
        else if (a == "--no-rt") o.realtimePolicy = false;
        else if (a == "--spin") o.cpuWarmupMilliseconds = std::atof(next("--spin").c_str());
        else if (a == "--profile-out") profileOut = next("--profile-out");
        else if (a == "--diff") diff = true;
        else if (a == "--diff-blocks") diffBlocks = (uint32_t)std::atoi(next("--diff-blocks").c_str());
        else if (diff && a.size() && a[0] != '-') diffPaths.push_back(a);
        else { std::fprintf(stderr, "jsfx-bench: unknown argument %s\n", a.c_str()); return 2; }
    }
    if (diff) {
        gStage = "diff";
        if (diffPaths.empty()) { std::fprintf(stderr, "jsfx-bench: --diff needs files or directories\n"); return 2; }
        return ETJSFXBenchDiffMain(diffPaths, diffBlocks);
    }
#if defined(NSEEL_VM_PROFILE)
    NSEEL_vm_profile_reset();
#else
    if (!profileOut.empty()) { std::fprintf(stderr, "jsfx-bench: --profile-out needs a -DNSEEL_VM_PROFILE build\n"); return 2; }
#endif
    std::string probe = "not built";
#if defined(ET_JSFX_BENCH_JIT_PROBE)
    gStage = "JIT probe";
    if (!probeJIT(probe)) {
        std::fprintf(stderr, "jsfx-bench: JIT refused by the OS: %s\n", probe.c_str());
        return 3;
    }
    std::printf("JIT probe: %s\n", probe.c_str());
#endif
    o.scriptDir = dir.c_str();
    o.scripts = scripts.empty() ? nullptr : scripts.c_str();
    o.variants = variants.empty() ? nullptr : variants.c_str();
    o.buildConfig = config.c_str(); o.gitSHA = sha.c_str(); o.compilerFlags = flags.c_str();

    gStage = "bench";
    ETJSFXBenchReport *report = ETJSFXBench_Run(&o);
    char *table = ETJSFXBench_Table(report);
    std::fputs(table, stdout); std::fflush(stdout);
    std::string extra = "\"runner\": \"cli\", \"jitProbe\": \"" + probe + "\"";
    char *text = ETJSFXBench_JSON(report, extra.c_str());
    if (!json.empty()) {
        FILE *f = std::fopen(json.c_str(), "wb");
        if (!f) { std::fprintf(stderr, "jsfx-bench: cannot write %s\n", json.c_str()); return 2; }
        std::fputs(text, f); std::fclose(f);
        std::printf("json: %s\n", json.c_str());
    }
#if defined(NSEEL_VM_PROFILE)
    if (!profileOut.empty()) {
        FILE *f = std::fopen(profileOut.c_str(), "wb");
        if (!f) { std::fprintf(stderr, "jsfx-bench: cannot write %s\n", profileOut.c_str()); return 2; }
        const int nops = NSEEL_vm_profile_nops();
        const unsigned long long *ops = NSEEL_vm_profile_ops(), *pairs = NSEEL_vm_profile_pairs();
        std::fprintf(f, "{\n  \"scripts\": \"%s\", \"variants\": \"%s\", \"seconds\": %g, \"warmupSeconds\": %g,\n",
                     scripts.c_str(), variants.c_str(), o.seconds, o.warmupSeconds);
        std::fprintf(f, "  \"names\": [");
        for (int i = 0; i < nops; ++i) std::fprintf(f, "%s\"%s\"", i ? ", " : "", NSEEL_vm_profile_opname(i));
        std::fprintf(f, "],\n  \"ops\": [");
        for (int i = 0; i < nops; ++i) std::fprintf(f, "%s%llu", i ? ", " : "", ops[i]);
        std::fprintf(f, "],\n  \"pairs\": [");
        bool first = true;
        for (int a = 0; a < nops; ++a)
            for (int b = 0; b < nops; ++b)
                if (pairs[a * nops + b]) {
                    std::fprintf(f, "%s[%d, %d, %llu]", first ? "" : ", ", a, b, pairs[a * nops + b]);
                    first = false;
                }
        std::fprintf(f, "]\n}\n");
        std::fclose(f);
        std::printf("profile: %s\n", profileOut.c_str());
    }
#endif
    const bool passed = ETJSFXBench_Passed(report);
    ETJSFXBench_FreeString(table); ETJSFXBench_FreeString(text); ETJSFXBench_Free(report);
    return passed ? 0 : 1;
}
