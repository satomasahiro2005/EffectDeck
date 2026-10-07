// ETJSFXBench.cpp — JSFX の実行系の速さを比べる台（docs/jsfx-bench.md）。
//
// 1 本のスクリプトを、登録した実行系（kVariants）で同じ入力に通して 1 ブロックずつ測る。
//   - 作る → @init・@slider → 0.5 秒ぶん回して温める → 5 秒ぶん（938 ブロック）を測る
//   - 実行系は chunkBlocks ごとに入れ替える（A B A B …、頭も毎回ずらす）。温度と周波数の
//     揺れが片方にだけ乗らないように
//   - 出力は全部の実行系で照合する。基準は最初の実行系（ETJSFX を通る EEL）。cpp は許す差まで、
//     exact の印の付いたもの（これから足す vm）は 1 ビットも違ってはいけない
// **新しい実行系は kVariants に 1 行足す。**ETJSFX を通るものは hostVariant に「作った直後に
// 呼ぶ口」を渡す（実行系の切り替えはそこで。今は何もしない）。
#include "ETJSFXBench.h"

#if ET_JSFX_BENCH
#include "ETJSFXBenchEngine.h"
#include "ETJSFXHost.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <sys/stat.h>
#include <sys/utsname.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <sys/sysctl.h>
#endif

/// ETJSFX を通る実行系の名前。EEL を JIT で建てた CLI は "wdl-jit" を渡す（Tools/jsfx-bench/run.sh）。
#ifndef ET_JSFX_BENCH_EEL
#define ET_JSFX_BENCH_EEL "portable"
#endif

namespace {
using namespace etbench;

constexpr double kSampleRate = 48000;
constexpr uint32_t kFrames = 256;
constexpr uint32_t kChannels = 2;
/// 名前を挙げなかったときに回すもの（Debug/JSFXBench）。cpp の写しはこの名前で引く。
const char *const kScripts[] = {"gain", "filter_drive", "stereo_delay", "slow", "biquad", "fir", "math"};

// ---- 時計 -------------------------------------------------------------------------------------
#if defined(__APPLE__)
double ticksToNs()
{
    static double scale = [] { mach_timebase_info_data_t tb{}; mach_timebase_info(&tb); return (double)tb.numer / tb.denom; }();
    return scale;
}
inline uint64_t nowTicks() { return mach_absolute_time(); }
const char *kClockName = "mach_absolute_time";
#else
double ticksToNs() { return 1.0; }
inline uint64_t nowTicks()
{
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
const char *kClockName = "steady_clock";
#endif

// ---- 実行系 -----------------------------------------------------------------------------------
struct Script { std::string name, path; };

/// ETJSFX_Create → ETJSFX_Processor の process。アプリが音のスレッドで呼ぶのと同じ口。
struct HostEngine final : Engine {
    ETJSFX *host{};
    ETExternalProcessor proc{};
    ~HostEngine() override { if (host) ETJSFX_Destroy(host); }
    void process(float *planar, uint32_t channels, uint32_t frames, double sampleTime) override
    { proc.process(proc.context, planar, channels, frames, kSampleRate, sampleTime); }
    bool hostStats(uint32_t &worst, uint32_t &trips, bool &bypassed) override
    {
        worst = ETJSFX_DeadlineWorstPermille(host); trips = ETJSFX_DeadlineTrips(host);
        bypassed = !ETJSFX_IsRunning(host); return true;
    }
    bool recover() override
    {
        if (ETJSFX_IsRunning(host)) return false;
        ETJSFX_ClearDiagnostic(host); return true;
    }
};

using HostSetup = bool (*)(ETJSFX *host, std::string &error);
using Factory = std::unique_ptr<Engine> (*)(const Script &, std::string &error);

template <HostSetup Setup>
std::unique_ptr<Engine> hostVariant(const Script &script, std::string &error)
{
    char message[512] = {};
    auto engine = std::make_unique<HostEngine>();
    engine->host = ETJSFX_Create(script.path.c_str(), kSampleRate, kFrames, message, sizeof message);
    if (!engine->host) { error = message[0] ? message : "ETJSFX_Create failed"; return nullptr; }
    if constexpr (Setup != nullptr) { if (!Setup(engine->host, error)) return nullptr; }
    engine->proc = ETJSFX_Processor(engine->host);
    return engine;
}
/// EEL の実行系を選ぶ（WDL の ns-eel.h の NSEEL_EXEC_*）。portable も 0 をはっきり選ぶ（アプリの既定は変わりうる）。
template <int Mode>
bool selectExecutor(ETJSFX *host, std::string &error)
{
    if (ETJSFX_SetEELExecutor(host, Mode)) return true;
    error = "this EEL build has no such executor (JIT build?)";
    return false;
}
std::unique_ptr<Engine> cppVariant(const Script &script, std::string &error)
{
    auto engine = makeCppPort(script.name, kSampleRate, kFrames);
    if (!engine) error = "no C++ port for this script";
    return engine;
}

enum class Check : uint8_t { reference, tolerance, exact };
struct Variant {
    const char *name;
    bool host;        // ETJSFX を通る（締切の数字が在る）
    Check check;      // 基準との照合の仕方（最初の 1 行は基準）
    double tolerance; // Check::tolerance のときに許す差（float の出力の絶対値）
    Factory make;
};
/// **ここに 1 行足せば実行系が増える。**最初の行が照合の基準。
/// ETJSFX を通るものは、作った直後に呼ぶ口（bool (ETJSFX *, std::string &)）で実行系を切り替える。
/// vm-* の番号は ns-eel.h の NSEEL_EXEC_*（JIT の建て方では作れない＝not run）。
const Variant kVariants[] = {
    {ET_JSFX_BENCH_EEL, true, Check::reference, 0, hostVariant<selectExecutor<0>>},
    {"vm-block", true, Check::exact, 0, hostVariant<selectExecutor<1>>},
    {"vm-goto", true, Check::exact, 0, hostVariant<selectExecutor<2>>},
    {"vm-goto-fpreg", true, Check::exact, 0, hostVariant<selectExecutor<3>>},
    {"cpp", false, Check::tolerance, 1e-6, cppVariant},
};

// ---- 入力 -------------------------------------------------------------------------------------
inline uint64_t mix64(uint64_t x)
{
    x += 0x9e3779b97f4a7c15ull; x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebull; return x ^ (x >> 31);
}
/// 何番目のブロックかだけで決まる入力（正弦 2 本 + ゆっくりした揺れ + 白い雑音）。
void fillInput(float *planar, uint64_t block)
{
    for (uint32_t i = 0; i < kFrames; ++i) {
        const uint64_t n = block * kFrames + i;
        const double t = (double)n / kSampleRate;
        const double env = 0.6 + 0.4 * std::sin(2 * 3.141592653589793 * 0.5 * t);
        for (uint32_t ch = 0; ch < kChannels; ++ch) {
            const double noise = (double)(mix64(n * 2 + ch) >> 11) * (1.0 / 9007199254740992.0) * 2 - 1;
            const double tone = ch == 0 ? 0.4 * std::sin(2 * 3.141592653589793 * 220 * t)
                                        : 0.35 * std::sin(2 * 3.141592653589793 * 331 * t + 0.3);
            planar[ch * kFrames + i] = (float)(env * tone + 0.05 * noise);
        }
    }
}

// ---- 時間制約の方針 ---------------------------------------------------------------------------
struct Policy {
    std::string requested = "none", obtained = "none";
    int setResult = 0, getResult = 0;
    uint32_t period = 0, computation = 0, constraint = 0; bool preemptible = false;
};
Policy applyRealtimePolicy(bool want)
{
    Policy p;
#if defined(__APPLE__)
    if (!want) return p;
    p.requested = "time-constraint";
    const double nsPerTick = ticksToNs();
    const double budgetNs = kFrames / kSampleRate * 1e9;
    thread_time_constraint_policy_data_t policy{};
    policy.period = (uint32_t)(budgetNs / nsPerTick);
    policy.computation = (uint32_t)(budgetNs * 0.5 / nsPerTick);
    policy.constraint = (uint32_t)(budgetNs / nsPerTick);
    policy.preemptible = 1;
    p.setResult = thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY,
                                    (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    thread_time_constraint_policy_data_t got{};
    mach_msg_type_number_t count = THREAD_TIME_CONSTRAINT_POLICY_COUNT;
    boolean_t getDefault = 0;
    p.getResult = thread_policy_get(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY,
                                    (thread_policy_t)&got, &count, &getDefault);
    if (p.setResult == KERN_SUCCESS && p.getResult == KERN_SUCCESS && !getDefault) {
        p.obtained = "time-constraint";
        p.period = got.period; p.computation = got.computation; p.constraint = got.constraint;
        p.preemptible = got.preemptible;
    } else {
        p.obtained = getDefault ? "default (time-constraint not in effect)" : "failed";
    }
#else
    (void)want;
    if (want) { p.requested = "time-constraint"; p.obtained = "unsupported (not Apple)"; }
#endif
    return p;
}

// ---- 結果 -------------------------------------------------------------------------------------
struct VariantResult {
    std::string name, error;
    bool created = false, host = false;
    Check check = Check::reference;
    double tolerance = 0;
    std::vector<uint64_t> ticks;          // 測ったブロックごと
    double medianNs = 0, p90Ns = 0, p99Ns = 0, maxNs = 0, meanNs = 0;
    uint32_t hostWorst = 0, hostTrips = 0, recoveries = 0;
    uint64_t hash = 1469598103934665603ull;
    // 照合（基準に対して）
    std::string against;
    double maxAbsDiff = 0;
    uint64_t mismatched = 0;
    int64_t firstMismatchBlock = -1;
    bool checkPass = true;
};
struct ScriptResult {
    std::string name, path, reference;
    std::vector<VariantResult> variants;
};

double percentile(const std::vector<uint64_t> &sorted, double p)
{
    if (sorted.empty()) return 0;
    size_t rank = (size_t)std::ceil(p * sorted.size());
    if (rank < 1) rank = 1;
    if (rank > sorted.size()) rank = sorted.size();
    return (double)sorted[rank - 1];
}

std::string format(const char *fmt, ...)
{
    char buffer[1024];
    va_list args; va_start(args, fmt); std::vsnprintf(buffer, sizeof buffer, fmt, args); va_end(args);
    return buffer;
}
std::string jsonString(const std::string &s)
{
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { out += '\\'; out += (char)c; }
        else if (c < 0x20) out += format("\\u%04x", c);
        else out += (char)c;
    }
    return out + "\"";
}
std::string jsonNumber(double v)
{
    if (!std::isfinite(v)) return "null";
    return format("%.6g", v);
}

#if defined(__APPLE__)
std::string sysctlString(const char *name)
{
    size_t size = 0;
    if (sysctlbyname(name, nullptr, &size, nullptr, 0) != 0 || !size) return "";
    std::string value(size, '\0');
    if (sysctlbyname(name, value.data(), &size, nullptr, 0) != 0) return "";
    while (!value.empty() && value.back() == '\0') value.pop_back();
    return value;
}
#endif

const char *optimizeLevel()
{
#if defined(__OPTIMIZE_SIZE__)
    return "Os/Oz";
#elif defined(__OPTIMIZE__)
    return "O1+";
#else
    return "O0";
#endif
}

std::vector<std::string> split(const char *list)
{
    std::vector<std::string> out;
    if (!list) return out;
    std::string s = list, item;
    for (char c : s) {
        if (c == ',') { if (!item.empty()) out.push_back(item); item.clear(); }
        else if (c != ' ') item += c;
    }
    if (!item.empty()) out.push_back(item);
    return out;
}
bool fileExists(const std::string &path) { struct stat st{}; return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode); }
} // namespace

struct ETJSFXBenchReport {
    ETJSFXBenchOptions options{};
    std::string scriptDir, buildConfig, gitSHA, compilerFlags, error;
    std::string model, machine, cpu, osName, osVersion, osBuild;
    Policy policy;
    uint32_t warmupBlocks = 0, measuredBlocks = 0;
    double wallSeconds = 0;
    std::string startedAt;
    std::vector<ScriptResult> scripts;
};

namespace {
void describeDevice(ETJSFXBenchReport &r)
{
    struct utsname u{};
    if (uname(&u) == 0) { r.osName = u.sysname; r.osBuild = u.release; r.machine = u.machine; }
#if defined(__APPLE__)
    // iOS は hw.machine が機種（iPhone17,3）、macOS は hw.model（MacBookPro17,1）。
    std::string machine = sysctlString("hw.machine"), model = sysctlString("hw.model");
#if TARGET_OS_IPHONE
    r.model = machine.empty() ? model : machine;
    r.osName = "iOS";
#else
    r.model = model.empty() ? machine : model;
    r.osName = "macOS";
#endif
    r.cpu = sysctlString("machdep.cpu.brand_string");
    r.osVersion = sysctlString("kern.osproductversion");
    r.osBuild = sysctlString("kern.osversion");
#else
    r.model = r.machine;
    r.osVersion = r.osBuild;
#endif
}

void runScript(ETJSFXBenchReport &report, const Script &script, const std::vector<const Variant *> &variants)
{
    ScriptResult result;
    result.name = script.name; result.path = script.path;
    const uint32_t warm = report.warmupBlocks, total = report.warmupBlocks + report.measuredBlocks;
    const uint32_t chunk = report.options.chunkBlocks;
    const size_t blockSamples = (size_t)kFrames * kChannels;

    std::vector<std::unique_ptr<Engine>> engines;
    for (const Variant *v : variants) {
        VariantResult vr;
        vr.name = v->name; vr.host = v->host; vr.check = v->check; vr.tolerance = v->tolerance;
        std::string error;
        auto engine = v->make(script, error);
        vr.created = engine != nullptr;
        vr.error = error;
        if (vr.created) vr.ticks.reserve(report.measuredBlocks);
        engines.push_back(std::move(engine));
        result.variants.push_back(std::move(vr));
    }
    // 照合の基準は、作れたものの最初（ふつうは ETJSFX を通る EEL）。
    int reference = -1;
    for (size_t i = 0; i < engines.size(); ++i) if (engines[i]) { reference = (int)i; break; }
    if (reference >= 0) result.reference = result.variants[reference].name;

    std::vector<int> live;
    for (size_t i = 0; i < engines.size(); ++i) if (engines[i]) live.push_back((int)i);
    std::vector<float> input((size_t)chunk * blockSamples);
    std::vector<std::vector<float>> outputs(engines.size(), std::vector<float>((size_t)chunk * blockSamples));

    uint32_t chunkIndex = 0;
    for (uint32_t start = 0; start < total; start += chunk, ++chunkIndex) {
        const uint32_t count = std::min(chunk, total - start);
        for (uint32_t b = 0; b < count; ++b) fillInput(input.data() + b * blockSamples, start + b);
        // 頭をずらしながら回す（A B / B A / …）。
        for (size_t r = 0; r < live.size(); ++r) {
            const int v = live[(r + chunkIndex) % live.size()];
            Engine &engine = *engines[v];
            VariantResult &vr = result.variants[v];
            for (uint32_t b = 0; b < count; ++b) {
                float *buffer = outputs[v].data() + b * blockSamples;
                std::memcpy(buffer, input.data() + b * blockSamples, blockSamples * sizeof(float));
                const double sampleTime = (double)(start + b) * kFrames / kSampleRate;
                const uint64_t t0 = nowTicks();
                engine.process(buffer, kChannels, kFrames, sampleTime);
                const uint64_t t1 = nowTicks();
                if (start + b >= warm) vr.ticks.push_back(t1 - t0);
                // 締切を 3 回続けて超えるとホストが外す。外れたまま測らない（回数は残す）。
                if (vr.host && engine.recover()) ++vr.recoveries;
            }
        }
        // 照合と指紋。
        for (int v : live) {
            VariantResult &vr = result.variants[v];
            const float *out = outputs[v].data();
            for (size_t i = 0; i < (size_t)count * blockSamples; ++i) {
                uint32_t bits; std::memcpy(&bits, out + i, 4);
                for (int k = 0; k < 4; ++k) { vr.hash ^= (bits >> (8 * k)) & 0xff; vr.hash *= 1099511628211ull; }
            }
            if (v == reference || reference < 0) continue;
            const float *ref = outputs[reference].data();
            for (size_t i = 0; i < (size_t)count * blockSamples; ++i) {
                if (std::memcmp(out + i, ref + i, 4) == 0) continue;
                const double diff = std::fabs((double)out[i] - (double)ref[i]);
                if (!(diff <= vr.maxAbsDiff)) vr.maxAbsDiff = std::isnan(diff) ? INFINITY : diff;
                if (!vr.mismatched) vr.firstMismatchBlock = start + (int64_t)(i / blockSamples);
                ++vr.mismatched;
            }
        }
        // 時間制約のスレッドを止まらずに回し続けると、カーネルが普通の優先度へ落とす。
        // チャンクごとに少しだけ寝る（測る区間の外）。
        if (report.policy.obtained == "time-constraint") std::this_thread::sleep_for(std::chrono::microseconds(200));
    }

    const double nsPerTick = ticksToNs();
    for (size_t i = 0; i < engines.size(); ++i) {
        VariantResult &vr = result.variants[i];
        if (!engines[i]) { vr.checkPass = false; continue; }
        std::vector<uint64_t> sorted = vr.ticks;
        std::sort(sorted.begin(), sorted.end());
        long double sum = 0; for (uint64_t t : sorted) sum += t;
        vr.medianNs = percentile(sorted, 0.5) * nsPerTick;
        vr.p90Ns = percentile(sorted, 0.9) * nsPerTick;
        vr.p99Ns = percentile(sorted, 0.99) * nsPerTick;
        vr.maxNs = sorted.empty() ? 0 : sorted.back() * nsPerTick;
        vr.meanNs = sorted.empty() ? 0 : (double)(sum / sorted.size()) * nsPerTick;
        bool bypassed = false;
        engines[i]->hostStats(vr.hostWorst, vr.hostTrips, bypassed);
        if ((int)i == reference) { vr.against = ""; vr.checkPass = true; continue; }
        vr.against = result.reference;
        if (reference < 0) continue;
        vr.checkPass = vr.check == Check::exact ? vr.mismatched == 0
                     : vr.check == Check::tolerance ? vr.maxAbsDiff <= vr.tolerance
                     : true;
    }
    engines.clear();
    report.scripts.push_back(std::move(result));
}

const VariantResult *find(const ScriptResult &s, const std::string &name)
{
    for (const auto &v : s.variants) if (v.name == name && v.created) return &v;
    return nullptr;
}
} // namespace

extern "C" {

void ETJSFXBench_DefaultOptions(ETJSFXBenchOptions *o)
{
    if (!o) return;
    *o = ETJSFXBenchOptions{};
    o->seconds = 5; o->warmupSeconds = 0.5; o->chunkBlocks = 16; o->realtimePolicy = true;
    o->cpuWarmupMilliseconds = 500;
}

ETJSFXBenchReport *ETJSFXBench_Run(const ETJSFXBenchOptions *options)
{
    auto *report = new ETJSFXBenchReport;
    ETJSFXBench_DefaultOptions(&report->options);
    if (options) report->options = *options;
    ETJSFXBenchOptions &o = report->options;
    if (!(o.seconds > 0)) o.seconds = 5;
    if (!(o.warmupSeconds >= 0)) o.warmupSeconds = 0.5;
    if (!o.chunkBlocks) o.chunkBlocks = 16;
    report->scriptDir = o.scriptDir ? o.scriptDir : "";
    report->buildConfig = o.buildConfig ? o.buildConfig : "";
    report->gitSHA = o.gitSHA ? o.gitSHA : "";
    report->compilerFlags = o.compilerFlags ? o.compilerFlags : "";
    // 文字列の持ち主は呼び出し側。報告には写しだけ持ち、options の指す先は返した後に使わない。
    o.scriptDir = o.scripts = o.variants = o.buildConfig = o.gitSHA = o.compilerFlags = nullptr;
    report->measuredBlocks = (uint32_t)std::ceil(o.seconds * kSampleRate / kFrames);
    report->warmupBlocks = (uint32_t)std::ceil(o.warmupSeconds * kSampleRate / kFrames);
    describeDevice(*report);
    {
        std::time_t now = std::time(nullptr); char stamp[32] = {};
        std::strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", std::gmtime(&now));
        report->startedAt = stamp;
    }

    std::vector<const Variant *> variants;
    const auto wanted = split(options ? options->variants : nullptr);
    for (const Variant &v : kVariants)
        if (wanted.empty() || std::find(wanted.begin(), wanted.end(), v.name) != wanted.end()) variants.push_back(&v);
    for (const auto &w : wanted) {
        bool known = false;
        for (const Variant &v : kVariants) known |= w == v.name;
        if (!known) report->error += "unknown variant: " + w + "; ";
    }
    std::vector<std::string> names = split(options ? options->scripts : nullptr);
    if (names.empty()) for (const char *n : kScripts) names.push_back(n);
    std::vector<Script> scripts;
    for (const auto &n : names) {
        Script s{n, report->scriptDir + "/" + n + ".jsfx"};
        if (!fileExists(s.path)) { report->error += "missing script: " + s.path + "; "; continue; }
        scripts.push_back(s);
    }

    report->policy = applyRealtimePolicy(o.realtimePolicy);
    // 測る前に CPU を回して周波数を上げておく。冷えたまま始めると最初のスクリプトだけ
    // 2〜3 倍遅く出る（M1 で gain が 11 us と 4 us）。
    if (o.cpuWarmupMilliseconds > 0) {
        const uint64_t until = nowTicks() + (uint64_t)(o.cpuWarmupMilliseconds * 1e6 / ticksToNs());
        volatile double sink = 1;
        while (nowTicks() < until) for (int i = 0; i < 4096; ++i) sink = sink * 1.0000001 + 1e-9;
    }
    const uint64_t began = nowTicks();
    for (const auto &s : scripts) runScript(*report, s, variants);
    report->wallSeconds = (nowTicks() - began) * ticksToNs() * 1e-9;
    return report;
}

bool ETJSFXBench_Passed(const ETJSFXBenchReport *r)
{
    if (!r || !r->error.empty() || r->scripts.empty()) return false;
    for (const auto &s : r->scripts)
        for (const auto &v : s.variants) if (!v.created || !v.checkPass) return false;
    return true;
}

char *ETJSFXBench_Table(const ETJSFXBenchReport *r)
{
    if (!r) return nullptr;
    const double budgetNs = kFrames / kSampleRate * 1e9;
    std::string t;
    t += format("JSFX bench  %s %s (%s)  %s  config=%s  git=%s  eel=%s\n", r->model.c_str(), r->osVersion.c_str(),
                r->osBuild.c_str(), r->cpu.c_str(), r->buildConfig.c_str(), r->gitSHA.c_str(), ET_JSFX_BENCH_EEL);
    t += format("  %.0f Hz, %u frames x %u ch, budget %.1f us/block; warmup %u + measured %u blocks, chunk %u; "
                "policy %s; harness %s; wall %.1f s\n",
                kSampleRate, kFrames, kChannels, budgetNs / 1000, r->warmupBlocks, r->measuredBlocks,
                r->options.chunkBlocks, r->policy.obtained.c_str(), optimizeLevel(), r->wallSeconds);
    if (!r->compilerFlags.empty()) t += "  flags: " + r->compilerFlags + "\n";
    if (!r->error.empty()) t += "  ERROR: " + r->error + "\n";
    t += format("%-13s %-13s %9s %9s %9s %9s %8s %7s %7s %6s %8s %8s  %s\n", "script", "variant", "med_us", "p90_us",
                "p99_us", "max_us", "ns/smp", "%bud", "%b_p99", "host_pm", "vs_ref", "x_cpp", "check");
    for (const auto &s : r->scripts) {
        const VariantResult *ref = find(s, s.reference);
        const VariantResult *cpp = find(s, "cpp");
        for (const auto &v : s.variants) {
            if (!v.created) {
                t += format("%-13s %-13s  not run: %s\n", s.name.c_str(), v.name.c_str(), v.error.c_str());
                continue;
            }
            std::string host = v.host ? format("%u", v.hostWorst) : "-";
            std::string vsRef = ref && v.medianNs > 0 ? format("%.2fx", ref->medianNs / v.medianNs) : "-";
            std::string xCpp = cpp && cpp->medianNs > 0 ? format("%.2fx", v.medianNs / cpp->medianNs) : "-";
            std::string check;
            if (v.against.empty()) check = "reference";
            else if (v.mismatched == 0) check = "bit-exact";
            else check = format("maxdiff %.3g (%llu smp)", v.maxAbsDiff, (unsigned long long)v.mismatched);
            if (!v.against.empty()) check += v.checkPass ? " ok" : " FAIL";
            if (v.recoveries) check += format(" bypassed x%u", v.recoveries);
            t += format("%-13s %-13s %9.1f %9.1f %9.1f %9.1f %8.2f %6.2f%% %6.2f%% %6s %8s %8s  %s\n",
                        s.name.c_str(), v.name.c_str(), v.medianNs / 1000, v.p90Ns / 1000, v.p99Ns / 1000,
                        v.maxNs / 1000, v.meanNs / kFrames, v.medianNs / budgetNs * 100, v.p99Ns / budgetNs * 100,
                        host.c_str(), vsRef.c_str(), xCpp.c_str(), check.c_str());
        }
    }
    t += ETJSFXBench_Passed(r) ? "RESULT ok\n" : "RESULT FAIL\n";
    char *out = static_cast<char *>(std::malloc(t.size() + 1));
    if (out) std::memcpy(out, t.c_str(), t.size() + 1);
    return out;
}

char *ETJSFXBench_JSON(const ETJSFXBenchReport *r, const char *extra)
{
    if (!r) return nullptr;
    const double budgetNs = kFrames / kSampleRate * 1e9;
    std::string j = "{\n";
    if (extra && *extra) j += std::string("  ") + extra + ",\n";
    j += "  \"schema\": 1,\n";
    j += "  \"startedAt\": " + jsonString(r->startedAt) + ",\n";
    j += "  \"device\": {\"model\": " + jsonString(r->model) + ", \"machine\": " + jsonString(r->machine) +
         ", \"cpu\": " + jsonString(r->cpu) + ", \"os\": " + jsonString(r->osName) + ", \"osVersion\": " +
         jsonString(r->osVersion) + ", \"osBuild\": " + jsonString(r->osBuild) + "},\n";
    j += "  \"buildConfig\": " + jsonString(r->buildConfig) + ",\n";
    j += "  \"gitSHA\": " + jsonString(r->gitSHA) + ",\n";
    j += "  \"compilerFlags\": " + jsonString(r->compilerFlags) + ",\n";
#if defined(__clang__)
    j += "  \"compiler\": " + jsonString(__VERSION__) + ",\n";
#endif
    j += std::string("  \"harnessOptimize\": ") + jsonString(optimizeLevel()) + ",\n";
    j += std::string("  \"eel\": ") + jsonString(ET_JSFX_BENCH_EEL) + ",\n";
    j += std::string("  \"clock\": ") + jsonString(kClockName) + ",\n";
    j += format("  \"sampleRate\": %.0f, \"blockFrames\": %u, \"channels\": %u, \"budgetNs\": %s,\n", kSampleRate,
                kFrames, kChannels, jsonNumber(budgetNs).c_str());
    j += format("  \"seconds\": %s, \"warmupSeconds\": %s, \"warmupBlocks\": %u, \"measuredBlocks\": %u, "
                "\"chunkBlocks\": %u, \"cpuWarmupMilliseconds\": %s,\n", jsonNumber(r->options.seconds).c_str(),
                jsonNumber(r->options.warmupSeconds).c_str(), r->warmupBlocks, r->measuredBlocks,
                r->options.chunkBlocks, jsonNumber(r->options.cpuWarmupMilliseconds).c_str());
    j += "  \"policy\": {\"requested\": " + jsonString(r->policy.requested) + ", \"obtained\": " +
         jsonString(r->policy.obtained) + format(", \"setResult\": %d, \"getResult\": %d, \"period\": %u, "
         "\"computation\": %u, \"constraint\": %u, \"preemptible\": %s},\n", r->policy.setResult,
         r->policy.getResult, r->policy.period, r->policy.computation, r->policy.constraint,
         r->policy.preemptible ? "true" : "false");
    j += "  \"wallSeconds\": " + jsonNumber(r->wallSeconds) + ",\n";
    j += "  \"error\": " + jsonString(r->error) + ",\n";
    j += "  \"scripts\": [\n";
    for (size_t si = 0; si < r->scripts.size(); ++si) {
        const auto &s = r->scripts[si];
        const VariantResult *ref = find(s, s.reference);
        const VariantResult *cpp = find(s, "cpp");
        j += "    {\"name\": " + jsonString(s.name) + ", \"reference\": " + jsonString(s.reference) +
             ", \"variants\": [\n";
        for (size_t vi = 0; vi < s.variants.size(); ++vi) {
            const auto &v = s.variants[vi];
            j += "      {\"name\": " + jsonString(v.name) + ", \"created\": " + (v.created ? "true" : "false") +
                 ", \"error\": " + jsonString(v.error);
            if (v.created) {
                j += ", \"medianNs\": " + jsonNumber(v.medianNs) + ", \"p90Ns\": " + jsonNumber(v.p90Ns) +
                     ", \"p99Ns\": " + jsonNumber(v.p99Ns) + ", \"maxNs\": " + jsonNumber(v.maxNs) +
                     ", \"meanNs\": " + jsonNumber(v.meanNs) + ", \"meanNsPerSample\": " + jsonNumber(v.meanNs / kFrames) +
                     ", \"medianPermille\": " + jsonNumber(v.medianNs / budgetNs * 1000) +
                     ", \"p99Permille\": " + jsonNumber(v.p99Ns / budgetNs * 1000) +
                     ", \"maxPermille\": " + jsonNumber(v.maxNs / budgetNs * 1000);
                if (v.host)
                    j += format(", \"hostWorstPermille\": %u, \"hostTrips\": %u", v.hostWorst, v.hostTrips);
                j += format(", \"bypassRecoveries\": %u, \"outputHash\": \"%016llx\"", v.recoveries,
                            (unsigned long long)v.hash);
                j += ", \"vsReference\": " + (ref && v.medianNs > 0 ? jsonNumber(ref->medianNs / v.medianNs) : std::string("null"));
                j += ", \"vsCpp\": " + (cpp && cpp->medianNs > 0 ? jsonNumber(v.medianNs / cpp->medianNs) : std::string("null"));
                const char *mode = v.against.empty() ? "reference" : v.check == Check::exact ? "exact" : "tolerance";
                j += std::string(", \"check\": {\"mode\": \"") + mode + "\", \"against\": " + jsonString(v.against) +
                     ", \"tolerance\": " + jsonNumber(v.tolerance) + ", \"maxAbsDiff\": " + jsonNumber(v.maxAbsDiff) +
                     format(", \"mismatchedSamples\": %llu, \"firstMismatchBlock\": %lld, \"pass\": %s}",
                            (unsigned long long)v.mismatched, (long long)v.firstMismatchBlock,
                            v.checkPass ? "true" : "false");
            }
            j += vi + 1 < s.variants.size() ? "},\n" : "}\n";
        }
        j += si + 1 < r->scripts.size() ? "    ]},\n" : "    ]}\n";
    }
    j += "  ],\n";
    j += std::string("  \"passed\": ") + (ETJSFXBench_Passed(r) ? "true" : "false") + "\n}\n";
    char *out = static_cast<char *>(std::malloc(j.size() + 1));
    if (out) std::memcpy(out, j.c_str(), j.size() + 1);
    return out;
}

void ETJSFXBench_Free(ETJSFXBenchReport *r) { delete r; }
void ETJSFXBench_FreeString(char *s) { std::free(s); }

} // extern "C"
#endif
