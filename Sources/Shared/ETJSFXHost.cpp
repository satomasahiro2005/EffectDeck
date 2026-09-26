#include "ETJSFXHost.h"
#include "ysfx.h"
#include "WDL/eel2/ns-eel.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr size_t kMaxSource = 1024 * 1024;
/// 保存した状態の上限（枠 12 + 12n を含む全体）。**LoadState と同じ数で断る。**
/// Patches/ysfx-effectdeck-ios.diff の k_effectdeck_serialize_limit も 16 MiB で、
/// @serialize はそこで書くのを止める。
constexpr size_t kMaxState = 16 * 1024 * 1024;
constexpr uint32_t kMaxGFX = 2048;
constexpr size_t kMaxFramebuffer = 16 * 1024 * 1024;
constexpr size_t kMaxMenuPayload = 64 * 1024;
constexpr unsigned int kGlobalEEL = 64 * 1024 * 1024;
constexpr size_t kGlobalFramebuffer = 64 * 1024 * 1024;
/// pdc_delay の上限（サンプル）。192 kHz で 1 秒。
/// 後段は「チャンネル数 × 遅延 × 4 バイト」の補償用の遅延線を確保して 0 で埋める。
/// 上限が無いとスクリプトの書いた数がそのまま確保の大きさになる。
constexpr uint32_t kMaxLatency = 192000;
/// @slider のブロックを締切から外すのは、続けて超えた回数がこれ以下のあいだだけ。
constexpr uint32_t kSliderGrace = 16;
std::atomic<size_t> gFramebufferBytes{};
constexpr uint32_t kStateMagic = 0x534A4445;
enum class Mode : uint8_t { running, maintenance, automaticBypass };
enum class Diagnostic : uint8_t { none, deadlineOverrun };

void errorCopy(char *dst, size_t cap, const char *s)
{ if (dst && cap) std::snprintf(dst, cap, "%s", s ? s : ""); }
void errorCopy(char *dst, size_t cap, const std::string &s) { errorCopy(dst, cap, s.c_str()); }

bool forbiddenSource(const std::string &source, std::string &reason)
{
    size_t start = 0; uint32_t lineNo = 1;
    while (start <= source.size()) {
        size_t end = source.find('\n', start);
        if (end == std::string::npos) end = source.size();
        std::string line = source.substr(start, end - start);
        size_t first = line.find_first_not_of(" \t\r");
        if (first != std::string::npos) {
            std::string text = line.substr(first);
            if (text.rfind("import ", 0) == 0 || text.rfind("import\t", 0) == 0) {
                reason = "Unsupported import at line " + std::to_string(lineNo) + "."; return true;
            }
            if (text.rfind("filename:", 0) == 0 || text.rfind("data:", 0) == 0) {
                reason = "Unsupported external resource at line " + std::to_string(lineNo) + "."; return true;
            }
        }
        size_t include = line.find("include(");
        if (include != std::string::npos && line.substr(0, include).find("//") == std::string::npos) {
            reason = "Unsupported include() at line " + std::to_string(lineNo) + "."; return true;
        }
        if (end == source.size()) break;
        start = end + 1; ++lineNo;
    }
    return false;
}

bool sourceWithinBudgets(const std::string &source, std::string &reason)
{
    uint32_t depth=0,maxDepth=0,inlineBlocks=0;size_t literal=0;
    bool quoted=false,escaped=false,lineComment=false;
    for(size_t i=0;i<source.size();++i){char c=source[i];
        if(lineComment){if(c=='\n')lineComment=false;continue;}
        if(!quoted&&c=='/'&&i+1<source.size()&&source[i+1]=='/'){lineComment=true;++i;continue;}
        if(quoted){
            if(escaped)escaped=false;else if(c=='\\')escaped=true;else if(c=='"')quoted=false;
            if(++literal>64*1024){reason="String literal exceeds the 64 KiB limit.";return false;}
            continue;
        }
        if(c=='"'){quoted=true;literal=0;continue;}
        if(c=='<'&&i+1<source.size()&&source[i+1]=='?'&&++inlineBlocks>1024){reason="Too many inline EEL blocks.";return false;}
        if(c=='('||c=='['||c=='{'){if(++depth>maxDepth)maxDepth=depth;if(maxDepth>256){reason="Source nesting exceeds 256 levels.";return false;}}
        else if((c==')'||c==']'||c=='}')&&depth) --depth;
    }
    if(quoted){reason="Unterminated string literal.";return false;}
    return true;
}

/// `trigger` という識別子が本文に出るか。コメントと文字列は飛ばす。
///
/// 前後が識別子の文字でないことだけ見る。`triggerCount` のような別の名前を
/// 拾わないため。取りこぼすより多めに拾うほうが安全（札が出るだけ）。
bool sourceUsesTrigger(const std::string &source)
{
    static const std::string word = "trigger";
    bool quoted = false, escaped = false, lineComment = false;
    for (size_t i = 0; i < source.size(); ++i) {
        char c = source[i];
        if (lineComment) { if (c == '\n') lineComment = false; continue; }
        if (!quoted && c == '/' && i + 1 < source.size() && source[i + 1] == '/') {
            lineComment = true; ++i; continue;
        }
        if (quoted) {
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') quoted = false;
            continue;
        }
        if (c == '"') { quoted = true; continue; }
        if (c != word[0] || source.compare(i, word.size(), word) != 0) continue;
        const char before = i == 0 ? ' ' : source[i - 1];
        const size_t after = i + word.size();
        const char next = after < source.size() ? source[after] : ' ';
        auto part = [](char ch) {
            return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
                || (ch >= '0' && ch <= '9') || ch == '_' || ch == '.';
        };
        if (!part(before) && !part(next)) return true;
    }
    return false;
}

void put32(uint8_t *&o, uint32_t v)
{ o[0] = (uint8_t)v; o[1] = (uint8_t)(v >> 8); o[2] = (uint8_t)(v >> 16); o[3] = (uint8_t)(v >> 24); o += 4; }
uint32_t get32(const uint8_t *p)
{ return p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
void put64(uint8_t *&o, uint64_t v)
{ for (unsigned i = 0; i < 8; ++i) *o++ = (uint8_t)(v >> (8 * i)); }
uint64_t get64(const uint8_t *p)
{ uint64_t v = 0; for (unsigned i = 0; i < 8; ++i) v |= (uint64_t)p[i] << (8 * i); return v; }
uint64_t toBits(double v) { uint64_t b; std::memcpy(&b, &v, 8); return b; }
double fromBits(uint64_t b) { double v; std::memcpy(&v, &b, 8); return v; }

/// 出す前に拭く。**NaN・Inf・非正規化数を 0 にする。**
///
/// EEL の割り算は素の `/` で 0 除算を止めない（0/0 = NaN、x/0 = Inf、log(0) = -Inf）。
/// そのまま後段へ渡すと EffeTune の IIR は帰還（biquad の y1/y2・s1/s2）に NaN を
/// 抱えて戻らない。この JSFX を外しても、後段を作り直すまで無音か雑音になる。
/// LocalLink.m の受け口が同じ理由で拭いている。
/// 指数部だけ見る。255 が Inf と NaN、0 が 0 と非正規化数。分岐の無い 1 周で、確保もしない。
void scrub(float *planar, size_t count)
{
    for (size_t i = 0; i < count; ++i) {
        uint32_t bits; std::memcpy(&bits, planar + i, 4);
        const uint32_t exponent = bits & 0x7f800000u;
        bits = (exponent == 0 || exponent == 0x7f800000u) ? 0u : bits;
        std::memcpy(planar + i, &bits, 4);
    }
}

/// pdc_delay をサンプル数へ。負と NaN は 0、上限は kMaxLatency（Inf もここ）。
/// **uint32 へ変換する前に切る。**2^32 以上をそのまま変換すると未定義。
uint32_t latencyOf(ysfx_t *fx)
{
    const double d = std::ceil(ysfx_get_pdc_delay(fx));
    if (!(d > 0)) return 0;
    return d < (double)kMaxLatency ? (uint32_t)d : kMaxLatency;
}

struct StateFree { void operator()(ysfx_state_t *s) const { ysfx_state_free(s); } };
}

struct ETJSFX {
    ysfx_config_t *config{};
    ysfx_t *effect{};
    uint32_t maxFrames{};
    double sampleRate{48000};
    std::vector<uint32_t> sliders;
    std::atomic<uint8_t> mode{(uint8_t)Mode::maintenance};
    std::atomic<bool> audioActive{}, gfxActive{};
    /// 保守（SaveState / LoadState / Reconfigure / Destroy）と GFX の入力を 1 本ずつにする。
    /// **音のスレッドは取らない。**音は従来どおり mode と audioActive で外す。
    std::mutex exclusive;
    /// 入口を通った呼び出しの数（音のスレッドは数えない）。Destroy はこれが 0 に
    /// なるまで delete しない。
    std::atomic<uint32_t> users{};
    /// Destroy が ysfx を解放した。exclusive の中でだけ読み書きする。
    bool dying{};
    std::atomic<uint64_t> processedFrames{};
    std::atomic<uint32_t> latency{}, deadlineOverruns{};
    /// @slider のブロックが続けて締切を超えた回数。締切内のブロックで 0 に戻る。
    std::atomic<uint32_t> sliderOverruns{};
    /// 次の process で @slider が走る見込み。締切の判定から外すのに使う。
    /// 立てるのは ysfx_init / ysfx_load_state の直後と、SaveState が値を渡したとき。
    std::atomic<bool> sliderComputePending{};
    /// 測るためだけの数。**閾値は動かさない。**実機の数字が無いうちに 0.5 や 32 を
    /// 決めても測り直しになるので、まず採れる状態にする。
    /// deadlineWorst は「1 ブロックの持ち時間に対する割合」の最大値を 1/1000 で持つ。
    std::atomic<uint32_t> deadlineTrips{}, deadlineWorst{};
    std::atomic<uint32_t> pendingTriggers{};
    /// 本文に `trigger` が出たか。作るときに 1 度だけ見る。
    bool usesTrigger{};
    std::atomic<bool> latencyChanged{};
    std::atomic<bool> sliderChanged{};
    std::atomic<uint8_t> diagnostic{(uint8_t)Diagnostic::none};
    std::atomic<uint64_t> pendingValues[ysfx_max_sliders]{}, cachedValues[ysfx_max_sliders]{};
    std::atomic<bool> pendingSliders[ysfx_max_sliders]{};
    std::atomic<bool> cachedVisibility[ysfx_max_sliders]{};
    std::vector<uint8_t> framebuffer;
    uint32_t gfxWidth{}, gfxHeight{}, gfxStride{};
    size_t gfxAccounted{};
    ETJSFXMenuCallback menuCallback{};
    void *menuContext{};
    std::string log;
};

static void logger(intptr_t data, ysfx_log_level level, const char *message)
{
    auto *h = reinterpret_cast<ETJSFX *>(data);
    if (!h || !message || level < ysfx_log_warning) return;
    if (!h->log.empty()) h->log += '\n'; h->log += message;
}

static bool beginMaintenance(ETJSFX *h)
{
    if (!h) return false;
    uint8_t prior = h->mode.exchange((uint8_t)Mode::maintenance, std::memory_order_acq_rel);
    while (h->audioActive.load(std::memory_order_acquire) || h->gfxActive.load(std::memory_order_acquire))
        std::this_thread::yield();
    return prior != (uint8_t)Mode::automaticBypass;
}
static void endMaintenance(ETJSFX *h, bool healthy)
{ h->mode.store((uint8_t)(healthy ? Mode::running : Mode::automaticBypass), std::memory_order_release); }

namespace {
/// 入口を通ったことを数える。Destroy はこれが抜けるまで delete しない。
struct Use {
    ETJSFX *h;
    explicit Use(ETJSFX *host) : h(host) { h->users.fetch_add(1, std::memory_order_acq_rel); }
    ~Use() { h->users.fetch_sub(1, std::memory_order_release); }
    Use(const Use &) = delete; Use &operator=(const Use &) = delete;
};
/// 保守の入口。**1 本ずつ通す。**
///
/// mode だけでは排他にならない。2 本目は prior=maintenance を見て健康だと思い込み、
/// 先に終わった方が running へ戻して、もう片方の @init / @serialize の最中に音が入る
/// （自動バイパスもそこで解ける）。@serialize は file 0 の buffer を共有するので、
/// 2 本の SaveState が互いの buffer へ書く。
/// 抜けるときは endMaintenance → 錠を放す → Use を抜ける、の順（メンバの逆順）。
struct Maintenance {
    Use use;
    std::unique_lock<std::mutex> lock;
    bool live{}, healthy{};
    explicit Maintenance(ETJSFX *h) : use(h), lock(h->exclusive), live(!h->dying)
    { if (live) healthy = beginMaintenance(h); }
    ~Maintenance() { if (live) endMaintenance(use.h, healthy); }
    Maintenance(const Maintenance &) = delete; Maintenance &operator=(const Maintenance &) = delete;
};
}

/// VM の値を控える。**渡す前の値（pendingSliders）が在るつまみは上書きしない。**
///
/// そちらの方が新しい。RunGFX はつまみを渡さない（applySliders の頭）ので、
/// 音が止まっているあいだに画面で動かした値を次の @gfx の 1 枚が古い値へ戻し、
/// 保存されるまでカードの表示が戻っていた。
/// 控えたあとにもう一度見るのは、SetSlider と行き違ったとき。SetSlider は
/// 印を立ててから cachedValues を書くので、ここで印が見えなければ向こうの
/// 書き込みの方が後に来る（どちらも seq_cst）。
static void cacheSliders(ETJSFX *h)
{
    for (uint32_t i : h->sliders) {
        if (!h->pendingSliders[i].load()) {
            h->cachedValues[i].store(toBits(ysfx_slider_get_value(h->effect, i)));
            if (h->pendingSliders[i].load()) h->cachedValues[i].store(h->pendingValues[i].load());
        }
        uint8_t group=ysfx_fetch_slider_group_index(i);
        bool visible=(ysfx_get_slider_visibility(h->effect,group)&ysfx_slider_mask(i,group))!=0;
        if(h->cachedVisibility[i].exchange(visible)!=visible)
            h->sliderChanged.store(true,std::memory_order_release);
    }
}
static void cacheSliderNotifications(ETJSFX *h)
{
    bool changed=false;
    for(uint8_t group=0;group<ysfx_max_slider_groups;++group)
        changed|=(ysfx_fetch_slider_changes(h->effect,group)|
                  ysfx_fetch_slider_automations(h->effect,group))!=0;
    if(changed)h->sliderChanged.store(true,std::memory_order_release);
}
/// つまみの値を渡す。**値が変わったものが 1 本でも在れば true。**
///
/// notify=true なので ysfx は must_compute_slider を立て、同じ process の中で
/// @slider を走らせる。@slider の中身は人が書いたコード（係数表の作り直し、
/// バッファのクリア、FFT 窓の再計算）で、長さに上限が無い。
/// ysfx 自身がその場所に「@slider は @sample/@block と同時に走ってはいけない」と
/// TODO を残している＝上流も未解決。
/// だから、走ったブロックは締切の判定から外す（下の process を読むこと）。
/// 同じ値は ysfx が @slider を立てない（ysfx_slider_set_value）。走らないものを
/// 「走った」と数えると、同じ値を送り続けるだけで締切から外れ続ける。
///
/// **呼ぶのは音のスレッドの process と、音を外した保守の中だけ。**GFX スレッドから
/// 呼ぶと、音のスレッドが @slider の途中に居るとき、こちらの must_compute_slider=true を
/// 向こうの false が消して、最後の値で @slider が走らない。
static bool applySliders(ETJSFX *h)
{
    bool wrote = false;
    for (uint32_t i : h->sliders)
        if (h->pendingSliders[i].exchange(false, std::memory_order_acq_rel)) {
            const double value = fromBits(h->pendingValues[i].load());
            if (ysfx_slider_get_value(h->effect, i) != value) wrote = true;
            ysfx_slider_set_value(h->effect, i, value, true);
        }
    return wrote;
}

static int32_t process(void *ctx, float *planar, uint32_t channels, uint32_t frames,
                       double sampleRate, double)
{
    auto *h = static_cast<ETJSFX *>(ctx);
    if (!h || !h->effect || !planar || !channels || channels > ysfx_max_channels ||
        !frames || frames > h->maxFrames) return -1;
    if (h->mode.load(std::memory_order_acquire) != (uint8_t)Mode::running) return 0;
    bool expected = false;
    if (!h->audioActive.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return 0;
    if (h->mode.load(std::memory_order_acquire) != (uint8_t)Mode::running) {
        h->audioActive.store(false, std::memory_order_release); return 0;
    }
    auto began = std::chrono::steady_clock::now();
    bool slidersRan = false;
    // C の関数ポインタ越しに呼ばれる。**例外を外へ出さない**（出ると terminate）。
    // 投げなければ try は何もしない（確保も錠も無い）。
    try {
        // **@slider が走ったブロックは締切で測らない。**
        // 立てる経路は 2 本ある: ここと、ysfx_init / ysfx_load_state の直後（再設定・
        // 状態復元）や SaveState が値を渡したとき。自前のフラグで 2 本目を拾う。
        slidersRan = applySliders(h) ||
            h->sliderComputePending.exchange(false, std::memory_order_acq_rel);
        uint32_t triggers = h->pendingTriggers.exchange(0, std::memory_order_acq_rel);
        for (uint32_t i = 0; i < ysfx_max_triggers; ++i)
            if (triggers & (1u << i)) ysfx_send_trigger(h->effect, i);
        uint64_t position = h->processedFrames.load(std::memory_order_relaxed);
        ysfx_time_info_t t{}; t.playback_state = ysfx_playback_playing; t.tempo = 120;
        t.time_position = (double)position / sampleRate;
        t.beat_position = t.time_position * t.tempo / 60.0;
        t.time_signature[0] = 4; t.time_signature[1] = 4; ysfx_set_time_info(h->effect, &t);
        const float *ins[ysfx_max_channels]{}; float *outs[ysfx_max_channels]{};
        for (uint32_t ch = 0; ch < channels; ++ch) ins[ch] = outs[ch] = planar + ch * frames;
        ysfx_process_float(h->effect, ins, outs, channels, channels, frames);
        h->processedFrames.fetch_add(frames, std::memory_order_relaxed); cacheSliders(h);cacheSliderNotifications(h);
        uint32_t latency = latencyOf(h->effect);
        if (latency != h->latency.exchange(latency)) h->latencyChanged.store(true);
    } catch (...) {}
    scrub(planar, (size_t)channels * frames);
    double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - began).count();
    {   // 最大値を残す。使ったのは持ち時間の何割か。
        double budget = (double)frames / sampleRate;
        uint32_t ratio = budget > 0 ? (uint32_t)(elapsed / budget * 1000.0) : 0;
        uint32_t seen = h->deadlineWorst.load(std::memory_order_relaxed);
        while (ratio > seen &&
               !h->deadlineWorst.compare_exchange_weak(seen, ratio,
                                                       std::memory_order_relaxed)) {}
    }
    // @slider が走ったブロックは測らない。**カウンタにも触らない。**0 に戻すと、
    // つまみを 1 ブロックおきに動かすだけで本当に重いスクリプトでも判定が永久に成立しなくなる。
    //
    // **ただし外すのは続けて kSliderGrace 回まで。**@slider が 1 ブロックより重いと、
    // つまみを回し続けるあいだ毎ブロックが @slider のブロックになり、外すだけでは
    // 何回超えても判定に入らない。締切内のブロックが 1 つ挟まれば数え直す
    // （UI の更新はブロックより疎いので、普通のドラッグでは @slider の無いブロックが挟まる）。
    const bool over = elapsed > (double)frames / sampleRate;
    bool counted = over;
    if (!over) h->sliderOverruns.store(0, std::memory_order_relaxed);
    else if (slidersRan)
        counted = h->sliderOverruns.fetch_add(1, std::memory_order_relaxed) + 1 > kSliderGrace;
    if (counted) {
        h->deadlineTrips.fetch_add(1, std::memory_order_relaxed);
        if (h->deadlineOverruns.fetch_add(1) + 1 >= 3) {
            h->diagnostic.store((uint8_t)Diagnostic::deadlineOverrun, std::memory_order_release);
            h->mode.store((uint8_t)Mode::automaticBypass, std::memory_order_release);
        }
    } else if (!over && !slidersRan) h->deadlineOverruns.store(0);
    h->audioActive.store(false, std::memory_order_release);
    return 0;
}
static void reset(void *ctx) { if (auto *h = static_cast<ETJSFX *>(ctx)) h->processedFrames.store(0); }
static uint32_t latency(void *ctx) { auto *h = static_cast<ETJSFX *>(ctx); return h ? h->latency.load() : 0; }
static double tail(void *) { return std::numeric_limits<double>::infinity(); }

namespace {
struct DestroyHost { void operator()(ETJSFX *h) const { ETJSFX_Destroy(h); } };

ETJSFX *create(const char *path, double rate, uint32_t maxFrames, char *error, size_t cap)
{
    std::ifstream file(path, std::ios::binary);
    if (!file) { errorCopy(error, cap, "Could not open JSFX source."); return nullptr; }
    std::string source((std::istreambuf_iterator<char>(file)), {}), reason;
    if (source.size() > kMaxSource) { errorCopy(error, cap, "JSFX source exceeds the 1 MB limit."); return nullptr; }
    if (forbiddenSource(source, reason)) { errorCopy(error, cap, reason); return nullptr; }
    if (!sourceWithinBudgets(source, reason)) { errorCopy(error, cap, reason); return nullptr; }
    std::unique_ptr<ETJSFX, DestroyHost> h{new ETJSFX}; h->maxFrames = maxFrames; h->sampleRate = rate;
    h->usesTrigger = sourceUsesTrigger(source);
    NSEEL_RAM_limitmem = kGlobalEEL;
    h->config = ysfx_config_new();
    if (!h->config) { errorCopy(error, cap, "Could not create EEL2 runtime."); return nullptr; }
    ysfx_set_user_data(h->config, reinterpret_cast<intptr_t>(h.get())); ysfx_set_log_reporter(h->config, logger);
    h->effect = ysfx_new(h->config); auto began = std::chrono::steady_clock::now();
    if (!h->effect || !ysfx_load_file(h->effect, path, 0) || !ysfx_compile(h->effect, 0)) {
        errorCopy(error, cap, h->log.empty() ? "Could not compile JSFX." : h->log); return nullptr;
    }
    if (std::chrono::duration<double>(std::chrono::steady_clock::now() - began).count() > 2) {
        errorCopy(error, cap, "JSFX exceeded the 2 second compile limit."); return nullptr;
    }
    for (uint32_t i = 0; i < ysfx_max_sliders; ++i) if (ysfx_slider_exists(h->effect, i)) {
        if (ysfx_slider_is_path(h->effect, i)) { errorCopy(error, cap, "File sliders are not supported."); return nullptr; }
        h->sliders.push_back(i);
    }
    ysfx_set_midi_capacity(h->effect, 0, false); ysfx_set_sample_rate(h->effect, rate);
    ysfx_set_block_size(h->effect, maxFrames); ysfx_init(h->effect); cacheSliders(h.get());
    h->sliderComputePending.store(true, std::memory_order_release);
    h->latency.store(latencyOf(h->effect));
    h->mode.store((uint8_t)Mode::running, std::memory_order_release); return h.release();
}
}

/// **extern "C" の口から例外を出さない。**Swift の枠を越えて terminate になる。
/// 包むのは確保しうる口だけ（作る・保守・GFX）。値を読むだけの口は投げない。
ETJSFX *ETJSFX_Create(const char *path, double rate, uint32_t maxFrames, char *error, size_t cap)
{
    if (!path || !*path || !maxFrames) { errorCopy(error, cap, "Invalid JSFX path or block size."); return nullptr; }
    try { return create(path, rate, maxFrames, error, cap); }
    catch (const std::bad_alloc &) { errorCopy(error, cap, "Not enough memory to load JSFX."); }
    catch (...) { errorCopy(error, cap, "Could not load JSFX."); }
    return nullptr;
}

/// **走っている呼び出しを待ってから消す。**
///
/// 保守（SaveState / Reconfigure / LoadState）と GFX の入力は exclusive を取るので、
/// ここで錠を取れた時点で抜けている。後から来たものは dying を見て何もしない。
/// RunGFX は mode が maintenance のまま戻らないので入らない。最後に users が
/// 0 になるのを待つ（錠待ちで並んでいたものが抜けるまで）。
/// **Destroy が返った後に呼ばれたものは守れない。**呼び出し側が先に流すこと。
void ETJSFX_Destroy(ETJSFX *h)
{
    if (!h) return;
    {
        std::lock_guard<std::mutex> lock(h->exclusive);
        h->dying = true; beginMaintenance(h);   // mode は maintenance のまま戻さない
        if (h->effect) ysfx_free(h->effect);
        if (h->config) ysfx_config_free(h->config);
        gFramebufferBytes.fetch_sub(h->gfxAccounted); h->gfxAccounted = 0;
    }
    while (h->users.load(std::memory_order_acquire)) std::this_thread::yield();
    delete h;
}
ETExternalProcessor ETJSFX_Processor(ETJSFX *h)
{ ETExternalProcessor d{}; d.context=h; d.process=process; d.reset=reset; d.latency=latency; d.tailTime=tail; d.maxFrames=h?h->maxFrames:0; d.maxChannels=ysfx_max_channels; return d; }

bool ETJSFX_Reconfigure(ETJSFX *h, double rate, uint32_t maxFrames)
{
    if (!h || !maxFrames) return false;
    try {
        Maintenance m(h); if (!m.live || !h->effect) return false;
        h->sampleRate=rate; h->maxFrames=maxFrames; ysfx_set_sample_rate(h->effect,rate);
        ysfx_set_block_size(h->effect,maxFrames); ysfx_init(h->effect); h->processedFrames.store(0);
        h->sliderComputePending.store(true,std::memory_order_release);
        cacheSliders(h); return true;
    } catch (...) { return false; }
}

bool ETJSFX_SaveState(ETJSFX *h, uint8_t **bytes, size_t *size)
{
    if (!h || !bytes || !size) return false; *bytes=nullptr; *size=0;
    try {
        Maintenance m(h); if (!m.live) return false;
        if (applySliders(h)) h->sliderComputePending.store(true, std::memory_order_release);
        // @serialize の大きさは書いている最中に止まる（パッチの k_effectdeck_serialize_limit）。
        // 超えたら ysfx_save_state が nullptr を返す。
        std::unique_ptr<ysfx_state_t, StateFree> s{ysfx_save_state(h->effect)};
        if (!s || s->slider_count > ysfx_max_sliders) return false;
        // **LoadState と同じ数で断る。**payload だけ見ていると、枠（12 + 12n）のぶん
        // 上限を超えたものが保存でき、読み戻しで断られる。
        const size_t total = 12 + (size_t)s->slider_count * 12 + s->data_size;
        if (s->data_size > kMaxState || total > kMaxState) return false;
        // 最終の大きさで 1 度だけ確保して直に書く（途中の vector を挟まない）。
        auto *out = static_cast<uint8_t *>(std::malloc(total)); if (!out) return false;
        uint8_t *p = out;
        put32(p,kStateMagic); put32(p,s->slider_count); put32(p,(uint32_t)s->data_size);
        for(uint32_t i=0;i<s->slider_count;++i){put32(p,s->sliders[i].index);put64(p,toBits(s->sliders[i].value));}
        if (s->data_size) std::memcpy(p, s->data, s->data_size);
        *bytes=out; *size=total; return true;
    } catch (...) { return false; }
}

bool ETJSFX_LoadState(ETJSFX *h,const uint8_t *bytes,size_t size)
{
    if(!h||!bytes||size<12||size>kMaxState||get32(bytes)!=kStateMagic)return false;
    uint32_t n=get32(bytes+4),payload=get32(bytes+8); if(n>ysfx_max_sliders||12ull+12ull*n+payload!=size)return false;
    try {
        std::vector<ysfx_state_slider_t> values(n); const uint8_t *p=bytes+12;
        for(uint32_t i=0;i<n;++i,p+=12){values[i].index=get32(p);values[i].value=fromBits(get64(p+4));}
        ysfx_state_t s{};s.sliders=values.data();s.slider_count=n;s.data=const_cast<uint8_t*>(p);s.data_size=payload;
        Maintenance m(h); if(!m.live)return false;
        bool ok=ysfx_load_state(h->effect,&s);if(ok)ysfx_init(h->effect);
        if(ok)h->sliderComputePending.store(true,std::memory_order_release);
        cacheSliders(h);return ok;
    } catch (...) { return false; }
}
void ETJSFX_FreeBytes(void *p){std::free(p);}
const char *ETJSFX_Name(const ETJSFX *h){return h&&h->effect?ysfx_get_name(h->effect):nullptr;}
const char *ETJSFX_Author(const ETJSFX *h){return h&&h->effect?ysfx_get_author(h->effect):nullptr;}
const char *ETJSFX_Diagnostic(const ETJSFX *h)
{
    if (!h) return "";
    switch ((Diagnostic)h->diagnostic.load(std::memory_order_acquire)) {
    case Diagnostic::deadlineOverrun: return "Repeated audio deadline overruns; JSFX was bypassed.";
    default: return "";
    }
}
uint32_t ETJSFX_SliderCount(const ETJSFX *h){return h?(uint32_t)h->sliders.size():0;}

bool ETJSFX_SliderInfo(ETJSFX *h,uint32_t ordinal,uint32_t *index,const char **name,double *value,double *minimum,double *maximum,double *step,uint8_t *shape,bool *visible)
{
    if(!h||ordinal>=h->sliders.size())return false;uint32_t i=h->sliders[ordinal];ysfx_slider_curve_t c{};
    if(!ysfx_slider_get_curve(h->effect,i,&c))return false;if(index)*index=i;if(name)*name=ysfx_slider_get_name(h->effect,i);
    if(value)*value=fromBits(h->cachedValues[i].load());if(minimum)*minimum=c.min;if(maximum)*maximum=c.max;
    if(step)*step=c.inc;if(shape)*shape=c.shape;if(visible){uint8_t g=ysfx_fetch_slider_group_index(i);*visible=(ysfx_get_slider_visibility(h->effect,g)&ysfx_slider_mask(i,g))!=0;}return true;
}
uint32_t ETJSFX_SliderEnumCount(ETJSFX *h,uint32_t i)
{ return h&&h->effect&&i<ysfx_max_sliders?ysfx_slider_get_enum_size(h->effect,i):0; }
const char *ETJSFX_SliderEnumName(ETJSFX *h,uint32_t i,uint32_t ordinal)
{ return h&&h->effect&&i<ysfx_max_sliders?ysfx_slider_get_enum_name(h->effect,i,ordinal):nullptr; }
double ETJSFX_SliderToNormalized(ETJSFX *h,uint32_t i,double value)
{
    ysfx_slider_curve_t c{};
    return h&&h->effect&&i<ysfx_max_sliders&&ysfx_slider_get_curve(h->effect,i,&c)
        ? ysfx_ysfx_value_to_normalized(value,&c):0;
}
double ETJSFX_SliderFromNormalized(ETJSFX *h,uint32_t i,double value)
{
    ysfx_slider_curve_t c{};
    return h&&h->effect&&i<ysfx_max_sliders&&ysfx_slider_get_curve(h->effect,i,&c)
        ? ysfx_normalized_to_ysfx_value(std::clamp(value,0.0,1.0),&c):0;
}
// 印を先、cachedValues を後に書く（cacheSliders を読むこと）。
void ETJSFX_SetSlider(ETJSFX *h,uint32_t i,double v){if(!h||i>=ysfx_max_sliders)return;h->pendingValues[i].store(toBits(v));h->pendingSliders[i].store(true);h->cachedValues[i].store(toBits(v));}
double ETJSFX_GetSlider(ETJSFX *h,uint32_t i){return h&&i<ysfx_max_sliders?fromBits(h->cachedValues[i].load()):0;}
bool ETJSFX_SendTrigger(ETJSFX *h,uint32_t i)
{
    if(!h||i>=ysfx_max_triggers)return false;
    // **running でなければ捨てる。**process は running 以外だと掃き出しの前に
    // return するので、溜めたぶんは再開した最初の 1 ブロックで一斉に発火する。
    // 画面には何も出ないので、押しても効かないのか溜まっているのか区別できない。
    // running から外れるのは自動バイパスだけでなく maintenance（状態保存・再設定）も在り、
    // そちらは日常的に踏む。
    if(h->mode.load(std::memory_order_acquire)!=(uint8_t)Mode::running)return false;
    h->pendingTriggers.fetch_or(1u<<i,std::memory_order_release);return true;
}
uint32_t ETJSFX_MaxTriggers(void){return ysfx_max_triggers;}
bool ETJSFX_UsesTrigger(const ETJSFX *h){return h&&h->usesTrigger;}
bool ETJSFX_ClearDiagnostic(ETJSFX *h)
{
    if(!h)return false;
    // 順序が要る。診断を消す → 回数を 0 に戻す → automaticBypass だけを running へ。
    //
    // **回数を戻さないと 1 ブロックで元に戻る。**0 に戻すのは process の else だけで、
    // automaticBypass 中は頭の早期 return で process が走らないので 3 のまま凍っている。
    // 戻した直後に 1 回超えれば 4 >= 3 が即成立する。
    //
    // **maintenance を running に書き換えてはいけない。**再設定や状態復元の最中に
    // process が入って ysfx_init と同時に走る。CAS が外れたら false を返すだけにする。
    //
    // **外れたら診断を戻す。**保守は入る前が automaticBypass なら automaticBypass へ
    // 戻る。診断だけ消えると、素通しのまま札も Re-enable も出なくなる。
    const uint8_t was=h->diagnostic.exchange((uint8_t)Diagnostic::none,std::memory_order_acq_rel);
    h->deadlineOverruns.store(0,std::memory_order_release);
    uint8_t expected=(uint8_t)Mode::automaticBypass;
    if(h->mode.compare_exchange_strong(expected,(uint8_t)Mode::running,std::memory_order_acq_rel))
        return true;
    if(expected==(uint8_t)Mode::maintenance)h->diagnostic.store(was,std::memory_order_release);
    return false;
}
bool ETJSFX_IsRunning(const ETJSFX *h){return h&&h->mode.load(std::memory_order_acquire)==(uint8_t)Mode::running;}
uint32_t ETJSFX_DeadlineTrips(const ETJSFX *h){return h?h->deadlineTrips.load(std::memory_order_relaxed):0;}
uint32_t ETJSFX_DeadlineWorstPermille(const ETJSFX *h){return h?h->deadlineWorst.load(std::memory_order_relaxed):0;}
bool ETJSFX_ConsumeLatencyChange(ETJSFX *h){return h&&h->latencyChanged.exchange(false);}
bool ETJSFX_ConsumeSliderChange(ETJSFX *h){return h&&h->sliderChanged.exchange(false);}

bool ETJSFX_HasGFX(const ETJSFX *h){return h&&h->effect&&ysfx_has_section(h->effect,ysfx_section_gfx);}
bool ETJSFX_GFXWantsRetina(ETJSFX *h){return h&&h->effect&&ysfx_gfx_wants_retina(h->effect);}
static int32_t showMenu(void *opaque,const char *menu,int32_t x,int32_t y)
{
    auto *h=static_cast<ETJSFX *>(opaque);
    if(!h){return 0;}
    if(!menu){return 0;}
    if(!h->menuCallback){return 0;}
    size_t n=strnlen(menu,kMaxMenuPayload+1);
    if(n>kMaxMenuPayload){return 0;}
    return h->menuCallback(h->menuContext,menu,x,y);
}
void ETJSFX_SetGFXMenuCallback(ETJSFX *h,ETJSFXMenuCallback callback,void *context)
{if(h){h->menuCallback=callback;h->menuContext=context;}}
void ETJSFX_PreferredGFXSize(ETJSFX *h,uint32_t *w,uint32_t *height){uint32_t d[2]{};if(h&&h->effect)ysfx_get_gfx_dim(h->effect,d);if(w)*w=d[0];if(height)*height=d[1];}
uint32_t ETJSFX_GFXFrameRate(ETJSFX *h){return h&&h->effect?ysfx_get_requested_framerate(h->effect):30;}
bool ETJSFX_RunGFX(ETJSFX *h,uint32_t width,uint32_t height,double scale)
{
    if(!h||!width||!height||width>kMaxGFX||height>kMaxGFX)return false;
    size_t stride=(size_t)width*4,bytes=stride*height;if(bytes>kMaxFramebuffer)return false;
    Use use(h);
    // **mode を先に見る。**Destroy の後は ysfx が解放済みで、HasGFX も読めない。
    if(h->mode.load()!=(uint8_t)Mode::running)return false;
    bool expected=false;if(!h->gfxActive.compare_exchange_strong(expected,true))return false;
    struct Release{std::atomic<bool> &flag;~Release(){flag.store(false);}} release{h->gfxActive};
    if(h->mode.load()!=(uint8_t)Mode::running||!ETJSFX_HasGFX(h))return false;
    try{
        if(h->gfxWidth!=width||h->gfxHeight!=height){
            size_t global=gFramebufferBytes.load(std::memory_order_relaxed),old=h->gfxAccounted;
            if(bytes>old){size_t add=bytes-old;do{if(global>kGlobalFramebuffer-add)return false;}while(!gFramebufferBytes.compare_exchange_weak(global,global+add));}
            try{h->framebuffer.resize(bytes);}catch(...){if(bytes>old)gFramebufferBytes.fetch_sub(bytes-old);return false;}
            if(old>bytes)gFramebufferBytes.fetch_sub(old-bytes);h->gfxAccounted=bytes;
            h->gfxWidth=width;h->gfxHeight=height;h->gfxStride=(uint32_t)stride;}
        ysfx_gfx_config_t c{};c.user_data=h;c.pixel_width=width;c.pixel_height=height;c.pixel_stride=h->gfxStride;c.pixels=h->framebuffer.data();c.scale_factor=std::max(1.0,scale);c.show_menu=showMenu;
        // **つまみはここで渡さない**（applySliders の頭）。音が止まっているあいだは
        // 250 ms 後の SaveState が渡すので、@gfx にもそこで届く。
        ysfx_gfx_setup(h->effect,&c);
        bool dirty=ysfx_gfx_run(h->effect);cacheSliders(h);cacheSliderNotifications(h);return dirty;
    }catch(...){return false;}
}
bool ETJSFX_CopyGFX(ETJSFX *h,uint8_t *bgra,size_t cap,uint32_t *w,uint32_t *height,uint32_t *stride)
{if(!h||!bgra)return false;Use use(h);if(h->gfxActive.load()||cap<h->framebuffer.size())return false;std::memcpy(bgra,h->framebuffer.data(),h->framebuffer.size());if(w)*w=h->gfxWidth;if(height)*height=h->gfxHeight;if(stride)*stride=h->gfxStride;return true;}
/// GFX の入力。**保守と同じ錠を取る。**ysfx_init（再設定）や @serialize と同時に
/// gfx の状態へ書かない。queue に積まれたまま Destroy と重なったものは dying を見て捨てる。
template<class F> static void gfxInput(ETJSFX *h,F &&apply)
{
    if(!h)return;
    try{Use use(h);std::lock_guard<std::mutex> lock(h->exclusive);if(!h->dying&&h->effect)apply();}catch(...){}
}
void ETJSFX_GFXMouse(ETJSFX *h,uint32_t m,int32_t x,int32_t y,uint32_t b,double w,double hw){gfxInput(h,[&]{ysfx_gfx_update_mouse(h->effect,m,x,y,b,w,hw);});}
void ETJSFX_GFXKey(ETJSFX *h,uint32_t m,uint32_t k,bool p){gfxInput(h,[&]{ysfx_gfx_add_key(h->effect,m,k,p);});}
void ETJSFX_GFXWindowState(ETJSFX *h,bool f,bool v,bool o){gfxInput(h,[&]{ysfx_gfx_set_window_state(h->effect,f,v,o);});}
