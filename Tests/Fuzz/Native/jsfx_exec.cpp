// jsfx_exec.cpp（Tests/Fuzz/Native）
// 的 jsfxexec: 任意の JSFX ソースを、アプリと同じ口（ETJSFXHost.h の C API）で最後まで回す。
// 専用の走らせ役は作らない。ETJSFXHost.cpp と ysfx（Patches/ysfx-effectdeck-ios.diff を当てた写し）を
// そのまま建てて、ETJSFXHost.swift が呼ぶ順に呼ぶ。
//
//   1. 入力をそのままファイルに書き、ETJSFX_Create に渡す（門 → ysfx_load_file → compile →
//      標本化率・ブロック長 → @init）。断られたら理由の文面があることだけ見て終わる
//   2. 1/3 で、作った直後に作り物の状態を ETJSFX_LoadState（起動時の復元。状態は
//      バックアップから来るので外の字。つまみの NaN・Inf はここからだけ入れる）
//   3. readParameters（SliderInfo・列挙の名前・正規化）、ETJSFX_Processor、メニューの口、
//      入れた直後の snapshotState（SaveState）
//   4. つまみを数本（setParameter と同じく有限の値を範囲に収めて）→ ブロックを数回
//      （2ch 以上。NaN・±Inf・非正規化数・FLT_MAX・-0 を混ぜる）。間に trigger と
//      ConsumeLatencyChange / ConsumeSliderChange（pollRuntimeChanges）
//   5. 1/4 で ETJSFX_Reconfigure（経路の切り替え）→ Processor を取り直して 1 ブロック
//   6. SaveState → LoadState（同じバイト）→ 1 ブロック → 値を崩した状態で LoadState → 1 ブロック
//   7. @gfx があれば小さい画で RunGFX → CopyGFX → マウス・キー・窓の状態 → もう 1 枚
//   8. ETJSFX_Destroy
//   9. 1/4 で実行系の差分: 同じソースを 2 つ作り、アプリの既定の実行系（ETJSFX_EELExecutor）と
//      portable（GLUE_CALL_CODE そのもの）に同じつまみと同じブロックを渡して、出力が 1 ビットまで同じか。
//      既定が portable の建て方では何もしない。締切を一度でも超えたら比べない（外れたかが時刻で変わる）。
//      プロセスで共有されて前の回の残りが見えるもの（名前の無い gmem・time()・time_precise()）を
//      ソースが書いていたら比べない。範囲の外の番地が指す 1 語（nseel_ramalloc_onfail）は回ごとに 0 に戻す
//
// 標本化率・ブロック長・つまみの値・画の大きさは入力の FNV-1a から決める（同じ入力は同じ回り方）。
// 入力の全体が JSFX のソースになるので、種（.jsfx）はそのまま読める。
//
// **止まらないスクリプトは EEL2 と libFuzzer に任せる。**loop() / while() は EEL2 が
// 1 回あたり 1048576 周で打ち切る（ns-eel.h の NSEEL_LOOPFUNC_SUPPORT_MAXLEN。アプリと同じ値で
// 建てる）。入れ子や @sample の中の loop はそれでも長くなるので、1 入力は libFuzzer の -timeout、
// 確保は -rss_limit_mb / -malloc_limit_mb が止める。run.sh はこの的を -fork で回して
// 時間切れを落ちとして数えない（入力は build/fuzz/<名前>/jsfxexec/timeout-* に残る）。
// アプリでは @init の止まらないものは ETJSFXLoader の見張り、音の方は締切の自動バイパスが受け持つ。
// 自動バイパスに落ちたら、札の Re-enable と同じく ETJSFX_ClearDiagnostic で戻して回し続ける。
//
// 約束:
//   - Create が断ったときは理由の文面がある
//   - running で渡したブロックは 0 を返し、出力に NaN・Inf・非正規化数が無い（ETJSFXHost.h）
//   - SaveState が返したバイトは枠（12 + 12n + payload）どおりで、そのまま LoadState が受ける
//     （受けないとアプリは次の起動で段を建てられない。ETJSFXHost.swift の restoreFailed）
//   - ASan / UBSan が何も言わない

#include "ETJSFXHost.h"
#include "ETExternalProcessor.h"
#include "WDL/eel2/ns-eel.h"

#include <algorithm>
#include <cctype>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>
#include <vector>
#include <unistd.h>

// nseel-ram.c。範囲の外のメモリの読み書きが全部ここに来る（プロセスで 1 語）。
extern "C" EEL_F nseel_ramalloc_onfail;

namespace {
constexpr size_t kErrorCapacity = 4096;   // ETJSFXHost.swift と同じ
constexpr uint32_t kMaxCanvas = 256;      // 画の一辺（点）。速さのため小さく取る
constexpr uint32_t kStateMagic = 0x534A4445;

[[noreturn]] void broken(const char *what, const std::string &detail = {})
{
    std::fprintf(stderr, "fuzz oracle: %s%s%s\n", what, detail.empty() ? "" : " ", detail.c_str());
    std::abort();
}

[[noreturn]] void harness(const char *what)
{
    std::fprintf(stderr, "jsfxexec harness: %s\n", what);
    std::abort();
}

/// 入力から決める乱数（splitmix64）。
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

/// ETJSFX_Create はパスを取る。プロセスごとに 1 つのファイルを書き直して使う
/// （-fork の子は別のプロセスなので重ならない）。
const std::string &sourcePath()
{
    static const std::string path = [] {
        const char *dir = std::getenv("TMPDIR");
        std::string p = std::string(dir && *dir ? dir : "/tmp") + "/effectdeck-jsfxexec-" +
                        std::to_string((long)getpid()) + ".jsfx";
        return p;
    }();
    return path;
}

void removeSource() { std::remove(sourcePath().c_str()); }

void writeSource(const uint8_t *data, size_t size)
{
    static bool registered = false;
    if (!registered) { std::atexit(removeSource); registered = true; }
    FILE *f = std::fopen(sourcePath().c_str(), "wb");
    if (!f) harness("could not open the temporary source file");
    if (size && std::fwrite(data, 1, size, f) != size) { std::fclose(f); harness("short write"); }
    if (std::fclose(f) != 0) harness("could not close the temporary source file");
}

/// Swift の min / max（ETJSFXHost.swift の setParameter が使う形。NaN の扱いが std と違う）。
double swiftMax(double x, double y) { return y >= x ? y : x; }
double swiftMin(double x, double y) { return y < x ? y : x; }

struct Parameter {
    uint32_t index{};
    double value{}, minimum{}, maximum{1}, step{};
    uint8_t shape{};
    bool visible{true};
};

/// ETJSFXHost.swift の readParameters と normalizedValue。名前は String(cString:) で読むので strlen する。
std::vector<Parameter> readParameters(ETJSFX *h)
{
    std::vector<Parameter> out;
    const uint32_t count = ETJSFX_SliderCount(h);
    for (uint32_t ordinal = 0; ordinal < count; ++ordinal) {
        Parameter p;
        const char *name = nullptr;
        if (!ETJSFX_SliderInfo(h, ordinal, &p.index, &name, &p.value, &p.minimum, &p.maximum,
                               &p.step, &p.shape, &p.visible)) continue;
        if (name) (void)std::strlen(name);
        const uint32_t enums = ETJSFX_SliderEnumCount(h, p.index);
        for (uint32_t item = 0; item < enums; ++item)
            if (const char *e = ETJSFX_SliderEnumName(h, p.index, item)) (void)std::strlen(e);
        (void)ETJSFX_SliderToNormalized(h, p.index, p.value);
        out.push_back(p);
    }
    return out;
}

/// ETJSFXHost.swift の setParameter / setNormalizedParameter。**有限の値だけ、範囲に収めて渡す。**
void setSomeSliders(ETJSFX *h, std::vector<Parameter> &params, Rng &r)
{
    if (params.empty()) return;
    const uint32_t n = 1 + r.below(std::min<uint32_t>(4, (uint32_t)params.size()));
    for (uint32_t k = 0; k < n; ++k) {
        Parameter &p = params[r.below((uint32_t)params.size())];
        double value;
        switch (r.below(6)) {
        case 0: value = p.minimum; break;
        case 1: value = p.maximum; break;
        case 2: value = p.value + p.step; break;
        case 3: value = p.minimum + (p.maximum - p.minimum) * r.unit(); break;
        default: value = ETJSFX_SliderFromNormalized(h, p.index, r.unit()); break;
        }
        if (!std::isfinite(value)) continue;
        const double clamped = swiftMin(swiftMax(value, p.minimum), p.maximum);
        ETJSFX_SetSlider(h, p.index, clamped);
        p.value = clamped;
    }
}

float sampleValue(Rng &r)
{
    switch (r.below(24)) {
    case 0: return std::numeric_limits<float>::quiet_NaN();
    case 1: return std::numeric_limits<float>::infinity();
    case 2: return -std::numeric_limits<float>::infinity();
    case 3: return 1e-40f;                 // 非正規化数
    case 4: return -1e-45f;
    case 5: return FLT_MAX;
    case 6: return -FLT_MAX;
    case 7: return -0.0f;
    default: return (float)(r.unit() * 2 - 1);
    }
}

struct Stream {
    double sampleRate{48000};
    uint32_t maxFrames{512};
    double time{};               // 鎖が渡す音の時刻（AudioIO の elapsed）
    std::vector<float> planar;
};

/// 出力の約束（ETJSFXHost.h）: NaN・Inf・非正規化数は 0 にして返す。scrub は 0 のビットにする。
void checkScrubbed(const float *planar, size_t count)
{
    for (size_t i = 0; i < count; ++i) {
        uint32_t bits; std::memcpy(&bits, planar + i, 4);
        const uint32_t exponent = bits & 0x7f800000u;
        if (exponent == 0x7f800000u || (exponent == 0 && bits != 0))
            broken("running のブロックの出力に NaN・Inf・非正規化数が残った",
                   "sample " + std::to_string(i) + " bits " + std::to_string(bits));
    }
}

/// 鎖の 1 ブロック（ETPipeline.c と同じく ETExternalProcessor_Process を通す）。
void runBlock(ETJSFX *h, const ETExternalProcessor &processor, Stream &s, Rng &r, bool specials)
{
    // 自動バイパスに落ちていれば、札の Re-enable と同じく戻す。
    if (!ETJSFX_IsRunning(h)) (void)ETJSFX_ClearDiagnostic(h);
    static const uint32_t channelChoices[] = {2, 2, 2, 2, 3, 4, 6, 8, 64};
    const uint32_t channels = channelChoices[r.below(sizeof channelChoices / sizeof channelChoices[0])];
    const uint32_t frames = 1 + r.below(std::min<uint32_t>(s.maxFrames, 256));
    s.planar.assign((size_t)channels * frames, 0.0f);
    for (float &v : s.planar) v = sampleValue(r);
    if (specials && s.planar.size() >= 4) {
        s.planar[0] = std::numeric_limits<float>::quiet_NaN();
        s.planar[1] = std::numeric_limits<float>::infinity();
        s.planar[2] = -std::numeric_limits<float>::infinity();
        s.planar[3] = 1e-40f;
    }
    const bool running = ETJSFX_IsRunning(h);
    const int32_t status = ETExternalProcessor_Process(&processor, s.planar.data(), channels, frames,
                                                       s.sampleRate, s.time);
    if (status != 0)
        broken("正しい大きさのブロックで process が 0 以外を返した", std::to_string(status));
    if (running) checkScrubbed(s.planar.data(), s.planar.size());
    // たまに 1 ブロック飛ばした時刻にする（段を切った・無音で休んだ。溜めた trigger を捨てる側）。
    s.time += frames / s.sampleRate * (r.oneIn(8) ? 2 : 1);
    (void)ETExternalProcessor_Latency(&processor);
    (void)ETExternalProcessor_TailTime(&processor);
}

/// pollRuntimeChanges の 1 回。
void poll(ETJSFX *h, std::vector<Parameter> &params)
{
    (void)ETJSFX_ConsumeLatencyChange(h);
    if (ETJSFX_ConsumeSliderChange(h)) params = readParameters(h);
    (void)std::strlen(ETJSFX_Diagnostic(h));
    (void)ETJSFX_DeadlineTrips(h);
    (void)ETJSFX_DeadlineWorstPermille(h);
}

void maybeTrigger(ETJSFX *h, Rng &r)
{
    if (ETJSFX_UsesTrigger(h) && r.oneIn(2)) (void)ETJSFX_SendTrigger(h, r.below(ETJSFX_MaxTriggers()));
}

/// snapshotState の中身。成功したら枠を見て返す。
bool saveState(ETJSFX *h, std::vector<uint8_t> &out)
{
    uint8_t *bytes = nullptr; size_t size = 0;
    if (!ETJSFX_SaveState(h, &bytes, &size)) {
        if (bytes || size) broken("SaveState が失敗したのにバイトを返した");
        return false;
    }
    if (!bytes || size < 12) broken("SaveState の結果が 12 バイトに満たない", std::to_string(size));
    uint32_t magic, n, payload;
    std::memcpy(&magic, bytes, 4); std::memcpy(&n, bytes + 4, 4); std::memcpy(&payload, bytes + 8, 4);
    if (magic != kStateMagic || 12ull + 12ull * n + payload != size)
        broken("SaveState の枠が合わない", "n " + std::to_string(n) + " payload " + std::to_string(payload) +
               " size " + std::to_string(size));
    out.assign(bytes, bytes + size);
    ETJSFX_FreeBytes(bytes);
    return true;
}

double specialValue(Rng &r, double around)
{
    switch (r.below(10)) {
    case 0: return std::numeric_limits<double>::quiet_NaN();
    case 1: return std::numeric_limits<double>::infinity();
    case 2: return -std::numeric_limits<double>::infinity();
    case 3: return 1e300;
    case 4: return -1e300;
    case 5: return 4.9e-324;
    case 6: return 2147483648.0;
    case 7: return -2147483649.0;
    default: return around * (r.unit() * 4 - 2);
    }
}

void put32(std::vector<uint8_t> &v, size_t at, uint32_t x) { std::memcpy(v.data() + at, &x, 4); }

/// バックアップから来る状態の形（枠は正しく、中身は何でも）。
std::vector<uint8_t> forgedState(const std::vector<Parameter> &params, Rng &r)
{
    const uint32_t n = r.below(std::min<uint32_t>(8, (uint32_t)params.size() + 2) + 1);
    const uint32_t payload = r.oneIn(3) ? 0 : r.below(64) * 8;
    std::vector<uint8_t> v(12 + (size_t)n * 12 + payload);
    put32(v, 0, kStateMagic); put32(v, 4, n); put32(v, 8, payload);
    for (uint32_t i = 0; i < n; ++i) {
        const uint32_t index = !params.empty() && !r.oneIn(4) ? params[r.below((uint32_t)params.size())].index
                                                              : r.below(300);
        const double value = specialValue(r, 1000);
        put32(v, 12 + (size_t)i * 12, index);
        std::memcpy(v.data() + 12 + (size_t)i * 12 + 4, &value, 8);
    }
    uint8_t *p = v.data() + 12 + (size_t)n * 12;
    for (uint32_t i = 0; i < payload; i += 8) {
        const double value = specialValue(r, 1 << 20);
        std::memcpy(p + i, &value, 8);   // file_var / file_mem は 8 バイトずつ読む
    }
    return v;
}

/// 保存したものを崩す（つまみの値と payload のバイト。枠は合わせたまま）。
std::vector<uint8_t> mangled(std::vector<uint8_t> v, Rng &r)
{
    uint32_t n, payload;
    std::memcpy(&n, v.data() + 4, 4); std::memcpy(&payload, v.data() + 8, 4);
    for (uint32_t i = 0; i < n; ++i)
        if (r.oneIn(2)) {
            const double value = specialValue(r, 1000);
            std::memcpy(v.data() + 12 + (size_t)i * 12 + 4, &value, 8);
        }
    const size_t head = 12 + (size_t)n * 12;
    switch (r.below(4)) {
    case 0:   // 短くする
        payload = payload ? r.below(payload) : 0;
        v.resize(head + payload);
        break;
    case 1: { // 伸ばす
        const uint32_t more = 8 * (1 + r.below(16));
        for (uint32_t i = 0; i < more; i += 8) {
            const double value = specialValue(r, 1 << 20);
            const uint8_t *b = reinterpret_cast<const uint8_t *>(&value);
            v.insert(v.end(), b, b + 8);
        }
        payload += more;
        break;
    }
    default:  // 中身を書き換える
        for (uint32_t k = 0; payload && k < 4; ++k) v[head + r.below(payload)] = (uint8_t)r.next();
        break;
    }
    put32(v, 8, payload);
    return v;
}

void restore(ETJSFX *h, const std::vector<uint8_t> &state)
{
    (void)ETJSFX_LoadState(h, state.data(), state.size());
}

int32_t menuCallback(void *context, const char *menu, int32_t, int32_t)
{
    if (menu) (void)std::strlen(menu);
    return context ? (int32_t)static_cast<Rng *>(context)->below(8) : 0;
}

/// ETJSFXHost.swift の renderGFX（RunGFX → CopyGFX）と、見た目の大きさの決め方。
void renderFrame(ETJSFX *h, Rng &r, uint32_t canvasW, uint32_t canvasH)
{
    const double requested = ETJSFX_GFXWantsRetina(h) ? (double)(1 + r.below(3)) : 1.0;
    const double dimensionLimit = std::min(2048.0 / canvasW, 2048.0 / canvasH);
    const double byteLimit = std::sqrt(16.0 * 1024 * 1024 / ((double)canvasW * canvasH * 4));
    const double scale = std::max(0.01, std::min({requested, dimensionLimit, byteLimit}));
    const uint32_t width = std::max<uint32_t>(1, (uint32_t)(canvasW * scale));
    const uint32_t height = std::max<uint32_t>(1, (uint32_t)(canvasH * scale));
    if (!ETJSFX_RunGFX(h, width, height, scale)) return;
    std::vector<uint8_t> pixels((size_t)width * height * 4);
    uint32_t w = 0, hh = 0, stride = 0;
    if (ETJSFX_CopyGFX(h, pixels.data(), pixels.size(), &w, &hh, &stride) &&
        (w != width || hh != height || stride != width * 4))
        broken("CopyGFX の大きさが RunGFX と違う");
}

void runGFX(ETJSFX *h, Rng &r)
{
    if (!ETJSFX_HasGFX(h)) return;
    uint32_t prefW = 0, prefH = 0;
    ETJSFX_PreferredGFXSize(h, &prefW, &prefH);
    (void)ETJSFX_GFXFrameRate(h);
    uint32_t w = prefW && !r.oneIn(3) ? std::min(prefW, kMaxCanvas) : 1 + r.below(kMaxCanvas);
    uint32_t hgt = prefH && !r.oneIn(3) ? std::min(prefH, kMaxCanvas) : 1 + r.below(kMaxCanvas);
    // 自動バイパスのあいだ RunGFX は描かない（ASan の下ではブロックが締切を超えやすい）。Re-enable と同じく戻す。
    if (!ETJSFX_IsRunning(h)) (void)ETJSFX_ClearDiagnostic(h);
    ETJSFX_GFXWindowState(h, true, true, r.oneIn(2));
    renderFrame(h, r, w, hgt);
    // 画面を押して、キーを打って、もう 1 枚（ETJSFXHost.swift の gfxQueue に積むもの）。
    const int32_t x = (int32_t)r.below(w + 32) - 16, y = (int32_t)r.below(hgt + 32) - 16;
    ETJSFX_GFXMouse(h, 0, x, y, 1u << r.below(3), r.oneIn(4) ? 1.0 : 0.0, 0);
    static const uint32_t keys[] = {'a', 'Z', '0', 8, 9, 13, 27, 127, 0x3042, 0x1F600};
    ETJSFX_GFXKey(h, r.below(16), keys[r.below(sizeof keys / sizeof keys[0])], true);
    if (r.oneIn(2)) { w = 1 + r.below(kMaxCanvas); hgt = 1 + r.below(kMaxCanvas); }
    renderFrame(h, r, w, hgt);
    ETJSFX_GFXMouse(h, 0, x, y, 0, 0, 0);
    ETJSFX_GFXWindowState(h, false, r.oneIn(2), false);
}

void exercise(ETJSFX *h, Stream &s, Rng &r)
{
    std::vector<Parameter> params = readParameters(h);

    // 起動時の復元（ETJSFX_Create の直後に LoadState）。
    if (r.oneIn(3)) { restore(h, forgedState(params, r)); params = readParameters(h); }

    if (const char *name = ETJSFX_Name(h)) (void)std::strlen(name);
    if (const char *author = ETJSFX_Author(h)) (void)std::strlen(author);
    ETExternalProcessor processor = ETJSFX_Processor(h);
    ETJSFX_SetGFXMenuCallback(h, menuCallback, &r);
    std::vector<uint8_t> saved;
    (void)saveState(h, saved);   // 入れた直後の snapshotState

    setSomeSliders(h, params, r);
    const uint32_t blocks = 2 + r.below(3);
    for (uint32_t b = 0; b < blocks; ++b) {
        maybeTrigger(h, r);
        runBlock(h, processor, s, r, b == 0);
        poll(h, params);
        if (r.oneIn(3)) setSomeSliders(h, params, r);
    }

    if (r.oneIn(4)) {   // 経路が替わった（標本化率・ブロック長）
        static const double rates[] = {44100, 48000, 96000, 22050, 192000};
        static const uint32_t sizes[] = {64, 128, 256, 512, 1024};
        s.sampleRate = rates[r.below(5)];
        s.maxFrames = sizes[r.below(5)];
        (void)ETJSFX_Reconfigure(h, s.sampleRate, s.maxFrames);
        processor = ETJSFX_Processor(h);   // アプリは入れ直す
        processor.reset(processor.context);
        s.time = 0;
        runBlock(h, processor, s, r, true);
        poll(h, params);
    }

    if (saveState(h, saved)) {
        if (!ETJSFX_LoadState(h, saved.data(), saved.size()))
            broken("SaveState が返したバイトを LoadState が受けない", std::to_string(saved.size()));
        runBlock(h, processor, s, r, false);
        poll(h, params);
        restore(h, mangled(saved, r));
        maybeTrigger(h, r);
        runBlock(h, processor, s, r, true);
        poll(h, params);
    }

    runGFX(h, r);
    ETJSFX_SetGFXMenuCallback(h, nullptr, nullptr);
}

/// 回ごとに違う値を読みうるソースか（差分を取らない）。名前の無い gmem はプロセスで 1 つの塊で
/// 前の回の書き込みが残り、time()・time_precise() は時計。EEL は大文字小文字を区別しないので小文字で探す。
/// 字面で広めに外す（コメントの中の字でも外す。外しすぎは差分の回が減るだけ）。
bool readsProcessState(const uint8_t *data, size_t size)
{
    std::string s(reinterpret_cast<const char *>(data), size);
    for (char &c : s) c = (char)std::tolower((unsigned char)c);
    return s.find("gmem") != std::string::npos || s.find("time") != std::string::npos;
}

/// 9. 実行系の差分。rand() は全部の VM で 1 つの列なので、2 つを並べずに 1 つずつ最初から回す。
void differential(double sampleRate, uint32_t maxFrames, uint64_t seed)
{
    std::vector<std::vector<float>> outs[2];
    for (int pass = 0; pass < 2; ++pass) {
        NSEEL_rand_reset();
        nseel_ramalloc_onfail = 0;
        char error[kErrorCapacity] = {};
        ETJSFX *h = ETJSFX_Create(sourcePath().c_str(), sampleRate, maxFrames, error, sizeof error);
        if (!h) {
            if (pass == 1) broken("差分: 同じソースの 2 つめだけ Create が断った", error);
            return;
        }
        if (pass == 0 && ETJSFX_EELExecutor(h) == NSEEL_EXEC_PORTABLE) { ETJSFX_Destroy(h); return; }
        if (pass == 1 && !ETJSFX_SetEELExecutor(h, NSEEL_EXEC_PORTABLE)) harness("portable を選べない");
        Rng r{seed};
        std::vector<Parameter> params = readParameters(h);
        ETExternalProcessor processor = ETJSFX_Processor(h);
        double time = 0;
        std::vector<float> planar;
        for (uint32_t b = 0; b < 4 && ETJSFX_IsRunning(h); ++b) {
            if (r.oneIn(2)) setSomeSliders(h, params, r);
            const uint32_t frames = 1 + r.below(std::min<uint32_t>(maxFrames, 256));
            planar.assign((size_t)2 * frames, 0.0f);
            for (float &v : planar) v = sampleValue(r);
            if (ETExternalProcessor_Process(&processor, planar.data(), 2, frames, sampleRate, time) != 0)
                broken("差分: process が 0 以外を返した");
            outs[pass].push_back(planar);
            time += frames / sampleRate;
        }
        const bool tripped = ETJSFX_DeadlineTrips(h) != 0;
        ETJSFX_Destroy(h);
        if (tripped) return;
    }
    const size_t n = std::min(outs[0].size(), outs[1].size());
    for (size_t b = 0; b < n; ++b)
        if (outs[0][b].size() != outs[1][b].size() ||
            std::memcmp(outs[0][b].data(), outs[1][b].data(), outs[0][b].size() * sizeof(float)) != 0)
            broken("差分: 既定の実行系と portable の出力が違う", "block " + std::to_string(b));
}
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    Rng r{fnv1a(data, size)};
    static const double rates[] = {48000, 44100, 96000, 22050, 192000};
    static const uint32_t sizes[] = {512, 256, 128, 64, 1024};
    Stream s;
    s.sampleRate = rates[r.below(5)];
    s.maxFrames = sizes[r.below(5)];

    writeSource(data, size);
    char error[kErrorCapacity] = {};
    ETJSFX *h = ETJSFX_Create(sourcePath().c_str(), s.sampleRate, s.maxFrames, error, sizeof error);
    if (!h) {
        const size_t length = strnlen(error, sizeof error);
        if (length == 0) broken("Create が理由なしで断った");
        if (length == sizeof error) broken("Create の理由が NUL で終わっていない");
        return 0;
    }
    const double firstRate = s.sampleRate;
    const uint32_t firstFrames = s.maxFrames;
    exercise(h, s, r);
    ETJSFX_Destroy(h);
    if (r.oneIn(4) && !readsProcessState(data, size)) differential(firstRate, firstFrames, r.next());
    return 0;
}
