// jsfx_threads.cpp（Tests/Fuzz/Native、Tests/Fuzz/tsan.sh が ThreadSanitizer で建てて回す）
// 1 つの JSFX を、アプリと同じ口（ETJSFXHost.h）で、スレッドを分けて同時に叩く。
//
//   音       ブロックを続けて process（64 フレーム・2ch）。ときどき締切を 3 回続けて超えさせて
//            自動バイパスに落とす（標本化率を大きく渡すと持ち時間が 0 に近い）
//   つまみ   SetSlider（gain・taps を決まった組から）・ClearDiagnostic・SendTrigger・読むだけの口
//   保守     Reconfigure・SaveState → LoadState・SetEELExecutor（--mode reg のとき: vm-reg ⇄ 既定 ⇄ portable、
//            ETVM_SetPasses・ETVM_SetEngine・ETVM_Install も混ぜる）
//   画       RunGFX → CopyGFX・マウス・窓の状態
//
// 約束（docs/jsfx-regvm-design.md §18）:
//   - ThreadSanitizer が何も言わない（tsan.sh が TSAN_OPTIONS で落とす）
//   - 音のブロックの出力は、素通し（running でないブロック）か、つまみの組ごとに 1 本のスレッドで
//     先に作った正解のどれかと 1 ビットまで同じ。@block が状態を毎回 0 に戻すので、出力は入力と
//     つまみの組だけで決まる。実行系（portable・既定・vm-reg）は 1 ビットも違わない
//   - --mode reg では vm-reg のプログラムが実際に付いて回った（ETVM の数え）
//
//   --mode multi は別のもの: 4 本のスレッドがそれぞれ自分の effect を作って vm-reg にして回して消すのを
//   繰り返す（effect をまたいで共有される ETVM の builder の大域。プログラムを作るのは 4 本で同時、
//   Create・Destroy だけは 1 本ずつ: WDL の compile・free の数えは錠なしの大域）。
//
//   jsfx_threads [--mode reg|default|multi] [--seconds N] [--seed N]

#include "ETJSFXHost.h"
#include "ETExternalProcessor.h"
#include "ETVM.h"
#include "ETVMLink.h"
#include "WDL/eel2/ns-eel.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

namespace {

constexpr uint32_t kFrames = 64, kChannels = 2, kMaxFrames = 256;
constexpr double kRate = 48000;
const double kGains[] = {0.25, 0.5, 0.75, 1.0};
const double kTaps[] = {1, 2, 3, 4};

// vm-reg の段 S3 の形（loop kernel・while + 比べ・megabuf・関数の局所・cell OP= 定数）を一通り踏む。
// 出力は gain・taps と入力だけで決まる（ph・acc は @block で毎回作り直す）。
const char kSource[] = R"(desc:vm thread stress
slider1:0.5<0,1,0.25>gain
slider2:2<1,4,1>taps
in_pin:left
in_pin:right
out_pin:left
out_pin:right
@init
function mix(a, b) local(t) (t = a * 0.5; t + b * 0.25;);
n = 64; i = 0;
loop(n, buf[i] = sin(i * 0.1) * 0.5; i += 1);
c = 0; i = 0;
loop(n, c = mix(c, buf[i]); i += 1);
k = 0;
loop(16, k += 0.25);
@slider
g = slider1;
taps = slider2 | 0;
@block
ph = 0;
acc = 0; j = 0;
while (j < taps) (acc += buf[j]; j += 1;);
sv = g * 4 + taps;
@sample
ph += 1;
spl0 = spl0 * g + c + acc + ph * 0.0009765625;
spl1 = spl1 * g - c + k * 0.001 + (ph & 7) * 0.01;
@serialize
file_var(0, sv);
@gfx 32 32
gfx_r = 1; gfx_g = 0.5; gfx_b = 0.25;
gfx_rect(0, 0, 8, 8);
gcount += 1;
)";

[[noreturn]] void fail(const char *what, const std::string &detail = {})
{
    std::fprintf(stderr, "jsfx_threads: %s%s%s\n", what, detail.empty() ? "" : " ", detail.c_str());
    std::exit(1);
}

std::string writeSource()
{
    char path[] = "/tmp/jsfx_threads_XXXXXX.jsfx";
    const int fd = mkstemps(path, 5);
    if (fd < 0) fail("mkstemps");
    const size_t n = sizeof kSource - 1;
    if (write(fd, kSource, n) != (ssize_t)n) fail("write");
    close(fd);
    return path;
}

void fillInput(std::vector<float> &planar)
{
    planar.resize((size_t)kChannels * kFrames);
    for (uint32_t i = 0; i < kFrames; ++i) {
        planar[i] = -0.5f + 0.015625f * (float)i;
        planar[kFrames + i] = 0.125f;
    }
}

bool same(const std::vector<float> &a, const std::vector<float> &b)
{ return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0; }

/// つまみの組ごとの正解。1 本のスレッドで、既定の実行系で 1 ブロックずつ。
std::vector<std::vector<float>> references(const std::string &path)
{
    char error[4096] = {};
    ETJSFX *h = ETJSFX_Create(path.c_str(), kRate, kMaxFrames, error, sizeof error);
    if (!h) fail("Create (reference)", error);
    ETExternalProcessor p = ETJSFX_Processor(h);
    std::vector<std::vector<float>> refs;
    double time = 0;
    for (double g : kGains)
        for (double t : kTaps) {
            ETJSFX_SetSlider(h, 0, g);
            ETJSFX_SetSlider(h, 1, t);
            std::vector<float> planar;
            fillInput(planar);
            if (p.process(p.context, planar.data(), kChannels, kFrames, kRate, time) != 0) fail("process (reference)");
            time += kFrames / kRate;
            if (!ETJSFX_IsRunning(h)) fail("reference host left running");
            refs.push_back(planar);
        }
    ETJSFX_Destroy(h);
    std::vector<float> input;
    fillInput(input);
    for (const auto &r : refs) if (same(r, input)) fail("a reference equals the input");
    return refs;
}

/// --mode multi: 別々の effect を別々のスレッドで同時に作る・vm-reg を作る・回す・消す
/// （ETVM の builder の大域と、WDL の compile の大域）。どの effect も 1 本のスレッドの中だけで使う。
int multi(const std::string &path, const std::vector<std::vector<float>> &refs, double seconds, uint64_t seed)
{
    std::vector<float> input;
    fillInput(input);
    std::atomic<uint64_t> hosts{}, blocks{};
    std::mutex lifecycle;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    std::vector<std::thread> threads;
    for (int t = 0; t < 4; ++t)
        threads.emplace_back([&, t] {
            std::mt19937_64 r(seed * 11 + (uint64_t)t);
            std::vector<float> planar;
            while (std::chrono::steady_clock::now() < deadline) {
                char error[4096] = {};
                ETJSFX *h;
                {   // 作る・消すは 1 本ずつ（WDL の compile・free と RAM の数えはプロセスで 1 つの大域を
                    // 錠なしで足し引きする。vm-reg と関係ない。docs/jsfx-regvm-design.md §18）
                    std::lock_guard<std::mutex> lock(lifecycle);
                    h = ETJSFX_Create(path.c_str(), kRate, kMaxFrames, error, sizeof error);
                }
                if (!h) fail("Create (multi)", error);
                if (r() % 4 && !ETJSFX_SetEELExecutor(h, NSEEL_EXEC_REG)) fail("vm-reg を選べない (multi)");
                const ETExternalProcessor p = ETJSFX_Processor(h);
                double time = 0;
                for (int b = 0; b < 8; ++b) {
                    const uint32_t gi = (uint32_t)(r() % 4), ti = (uint32_t)(r() % 4);
                    ETJSFX_SetSlider(h, 0, kGains[gi]);
                    ETJSFX_SetSlider(h, 1, kTaps[ti]);
                    fillInput(planar);
                    if (p.process(p.context, planar.data(), kChannels, kFrames, kRate, time) != 0) fail("process (multi)");
                    time += kFrames / kRate;
                    if (!same(planar, input) && !same(planar, refs[gi * 4 + ti])) fail("multi: output differs from its reference");
                    blocks.fetch_add(1);
                    if (b == 3 && !ETJSFX_SetEELExecutor(h, r() % 2 ? NSEEL_EXEC_REG : NSEEL_EXEC_DEFAULT))
                        fail("SetEELExecutor (multi)");
                }
                {
                    std::lock_guard<std::mutex> lock(lifecycle);
                    ETJSFX_Destroy(h);
                }
                hosts.fetch_add(1);
            }
        });
    for (auto &t : threads) t.join();
    std::printf("jsfx_threads --mode multi: hosts %llu, blocks %llu\n", (unsigned long long)hosts,
                (unsigned long long)blocks);
    return hosts ? 0 : 1;
}

struct Counts {
    std::atomic<uint64_t> blocks{}, matched{}, passthrough{}, forced{}, regBlocks{};
    std::atomic<uint64_t> sliders{}, clears{}, reconfigs{}, saves{}, loads{}, switches{}, gfx{};
};

} // namespace

int main(int argc, char **argv)
{
    std::string mode = "reg";
    double seconds = 20;
    uint64_t seed = 1;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--mode" && i + 1 < argc) mode = argv[++i];
        else if (a == "--seconds" && i + 1 < argc) seconds = std::atof(argv[++i]);
        else if (a == "--seed" && i + 1 < argc) seed = std::strtoull(argv[++i], nullptr, 10);
        else fail("usage: jsfx_threads [--mode reg|default|multi] [--seconds N] [--seed N]");
    }
    if (mode != "reg" && mode != "default" && mode != "multi") fail("--mode は reg・default・multi");
    const bool reg = mode == "reg";
    ETVM_Install();
    const std::string path = writeSource();
    const auto refs = references(path);
    if (mode == "multi") {
        const int status = multi(path, refs, seconds, seed);
        unlink(path.c_str());
        return status;
    }
    std::vector<float> input;
    fillInput(input);

    char error[4096] = {};
    ETJSFX *h = ETJSFX_Create(path.c_str(), kRate, kMaxFrames, error, sizeof error);
    if (!h) fail("Create", error);
    etvm::resetCoverage();
    if (reg && !ETJSFX_SetEELExecutor(h, NSEEL_EXEC_REG)) fail("vm-reg を選べない");
    const ETExternalProcessor proc = ETJSFX_Processor(h);

    Counts n;
    std::atomic<bool> done{false};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);

    std::thread audio([&] {
        std::mt19937_64 r(seed);
        std::vector<float> planar;
        double time = 0;
        uint32_t forcing = 0;
        while (std::chrono::steady_clock::now() < deadline) {
            fillInput(planar);
            if (!forcing && r() % 400 == 0) forcing = 4;
            // 持ち時間 frames / rate を 0 に近くして、締切を超えたと数えさせる（3 回続けば自動バイパス）
            const double rate = forcing ? 1e12 : kRate;
            if (forcing) { --forcing; n.forced.fetch_add(1); }
            const bool wasReg = ETJSFX_EELExecutor(h) == NSEEL_EXEC_REG;
            if (proc.process(proc.context, planar.data(), kChannels, kFrames, rate, time) != 0) fail("process != 0");
            time += kFrames / kRate;
            n.blocks.fetch_add(1);
            if (same(planar, input)) { n.passthrough.fetch_add(1); continue; }
            bool ok = false;
            for (const auto &ref : refs) if (same(planar, ref)) { ok = true; break; }
            if (!ok) {
                std::string got;
                char buf[64];
                for (uint32_t i = 0; i < 4; ++i) { std::snprintf(buf, sizeof buf, " %.9g", planar[i]); got += buf; }
                fail("output matches no reference:", got);
            }
            n.matched.fetch_add(1);
            if (wasReg) n.regBlocks.fetch_add(1);
        }
        done.store(true);
    });

    std::thread control([&] {
        std::mt19937_64 r(seed * 3 + 1);
        while (!done.load()) {
            switch (r() % 8) {
            case 0: case 1: case 2:
                ETJSFX_SetSlider(h, 0, kGains[r() % 4]);
                ETJSFX_SetSlider(h, 1, kTaps[r() % 4]);
                n.sliders.fetch_add(1);
                break;
            case 3:
                if (!ETJSFX_IsRunning(h) && ETJSFX_ClearDiagnostic(h)) n.clears.fetch_add(1);
                break;
            case 4: (void)ETJSFX_SendTrigger(h, (uint32_t)(r() % ETJSFX_MaxTriggers())); break;
            case 5: {
                uint32_t index = 0; const char *name = nullptr; double v = 0, lo = 0, hi = 0, step = 0;
                uint8_t shape = 0; bool visible = false;
                (void)ETJSFX_SliderInfo(h, (uint32_t)(r() % 2), &index, &name, &v, &lo, &hi, &step, &shape, &visible);
                (void)ETJSFX_GetSlider(h, 0);
                break;
            }
            case 6:
                (void)ETJSFX_ConsumeSliderChange(h); (void)ETJSFX_ConsumeLatencyChange(h);
                (void)ETJSFX_DeadlineTrips(h); (void)ETJSFX_Diagnostic(h);
                break;
            default: break;
            }
            // 画面の操作くらいの間を置く（つまみを毎ブロック渡すと @slider のブロックが締切から外れ続ける）
            std::this_thread::sleep_for(std::chrono::microseconds(r() % 50));
        }
    });

    std::thread maintenance([&] {
        std::mt19937_64 r(seed * 5 + 2);
        const int modes[] = {NSEEL_EXEC_REG, NSEEL_EXEC_DEFAULT, NSEEL_EXEC_PORTABLE, NSEEL_EXEC_REG};
        while (!done.load()) {
            switch (r() % (reg ? 6 : 3)) {
            case 0:
                if (ETJSFX_Reconfigure(h, kRate, r() % 2 ? kMaxFrames : 128)) n.reconfigs.fetch_add(1);
                break;
            case 1: {
                uint8_t *bytes = nullptr; size_t size = 0;
                if (ETJSFX_SaveState(h, &bytes, &size)) {
                    n.saves.fetch_add(1);
                    if (ETJSFX_LoadState(h, bytes, size)) n.loads.fetch_add(1);
                    else fail("LoadState refused SaveState's bytes");
                    ETJSFX_FreeBytes(bytes);
                }
                break;
            }
            case 2: break;
            case 3: case 4:
                if (!ETJSFX_SetEELExecutor(h, modes[r() % 4])) fail("SetEELExecutor refused");
                n.switches.fetch_add(1);
                break;
            default:
                // 作り方を変えてから作り直す（どの組でも 1 ビットも違わない。§17.1）。参照の解釈は遅いので稀に
                ETVM_Install();
                ETVM_SetPasses(r() % 3 == 0 ? 0u : ETVM_PASSES_ALL);
                ETVM_SetEngine(r() % 8 == 0 ? ETVM_ENGINE_REFERENCE : ETVM_ENGINE_THREADED);
                if (!ETJSFX_SetEELExecutor(h, NSEEL_EXEC_REG)) fail("SetEELExecutor refused");
                n.switches.fetch_add(1);
                break;
            }
            // 保守の合間に音が回るように（続けて入ると音のブロックは素通しばかりになる）。ときどき間を置かずに続ける
            if (r() % 4) std::this_thread::sleep_for(std::chrono::microseconds(r() % 1000));
        }
    });

    std::thread gfx([&] {
        std::mt19937_64 r(seed * 7 + 3);
        std::vector<uint8_t> pixels(64 * 64 * 4);
        while (!done.load()) {
            const uint32_t w = 16 + (uint32_t)(r() % 48), hh = 16 + (uint32_t)(r() % 48);
            ETJSFX_GFXWindowState(h, true, true, r() % 2 == 0);
            if (ETJSFX_RunGFX(h, w, hh, 1.0)) n.gfx.fetch_add(1);
            uint32_t cw = 0, ch = 0, stride = 0;
            (void)ETJSFX_CopyGFX(h, pixels.data(), pixels.size(), &cw, &ch, &stride);
            ETJSFX_GFXMouse(h, 0, (int32_t)(r() % 32), (int32_t)(r() % 32), (uint32_t)(r() % 2), 0, 0);
            std::this_thread::sleep_for(std::chrono::microseconds(r() % 500));
        }
    });

    audio.join();
    control.join();
    maintenance.join();
    gfx.join();
    ETJSFX_Destroy(h);
    unlink(path.c_str());

    const etvm::Coverage cov = etvm::coverage();
    std::printf("jsfx_threads --mode %s: blocks %llu (matched %llu, passthrough %llu, forced-overrun %llu, "
                "vm-reg %llu) | sliders %llu, clears %llu, reconfigs %llu, save/load %llu/%llu, "
                "executor switches %llu, gfx %llu | vm-reg programs attached @init %llu @slider %llu "
                "@block %llu @sample %llu\n",
                mode.c_str(), (unsigned long long)n.blocks, (unsigned long long)n.matched,
                (unsigned long long)n.passthrough, (unsigned long long)n.forced, (unsigned long long)n.regBlocks,
                (unsigned long long)n.sliders, (unsigned long long)n.clears, (unsigned long long)n.reconfigs,
                (unsigned long long)n.saves, (unsigned long long)n.loads, (unsigned long long)n.switches,
                (unsigned long long)n.gfx, (unsigned long long)cov.attached[1], (unsigned long long)cov.attached[2],
                (unsigned long long)cov.attached[3], (unsigned long long)cov.attached[4]);
    if (n.matched == 0 || n.reconfigs == 0 || n.saves == 0 || n.gfx == 0) fail("a thread made no progress");
    if (reg && (n.regBlocks == 0 || n.switches == 0 || cov.attached[4] == 0)) fail("vm-reg never ran");
    return 0;
}
